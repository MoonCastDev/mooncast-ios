//
//  MCStore.swift
//  MoonCast: the home's data. Moonlight's own pieces do the work, as on Android: DiscoveryManager finds and polls
//  PCs, PairManager pairs, ConnectionHelper fetches the game lists, AppAssetManager the box art, and
//  StreamFrameViewController plays.
//

import SwiftUI
import GameController

/// One thing you can play. PCs only for now; PS5 and Xbox join later.
struct MCGame: Identifiable, Equatable {
    let key: String
    let title: String
    let src: String
    let seed: String
    let running: Bool
    let host: TemporaryHost?
    let app: TemporaryApp?
    var ps: MCPs5Console? = nil
    var xb: MCXbox.Console? = nil
    var id: String { key }

    static func == (a: MCGame, b: MCGame) -> Bool { a.key == b.key && a.title == b.title && a.running == b.running }
}

/// A question with options (Cancel first where it matters), shown as the handheld's dialog card.
struct MCDialog: Identifiable {
    struct Opt {
        let title: String
        var sub: String? = nil
        var danger = false
        var picked = false
        let run: () -> Void
    }
    let id = UUID()
    let title: String
    var message: String? = nil
    var big: String? = nil
    var opts: [Opt]
}

final class MCStore: NSObject, ObservableObject, DiscoveryCallback, PairCallback, AppAssetCallback {
    static let shared = MCStore()

    @Published private(set) var hosts: [TemporaryHost] = []
    /// Bumped when anything in the hosts changes (they're Objective-C objects SwiftUI can't watch).
    @Published private(set) var revision = 0
    @Published var dialog: MCDialog?
    @Published var busy: String?

    /// Set by the home's controller: starts Moonlight's stream screen.
    var onStream: ((StreamConfiguration) -> Void)?
    /// Set by the home's controller: starts the PS5 stream screen.
    var onPs5Stream: ((MCPs5Console) -> Void)?
    /// Set by the home's controller: starts the Xbox stream screen.
    var onXboxStream: ((MCXbox.Console) -> Void)?
    /// Each PS5's own answer to the Remote Play probe (on, rest mode, the game it runs), by address.
    @Published private(set) var ps5Status: [String: MCPs5Probe.Status] = [:]
    private var lastPs5Probe = Date.distantPast
    private var probing = false

    private var disc: DiscoveryManager!
    private var assets: AppAssetManager!
    private let pairQueue = OperationQueue()
    private var clientCert: Data?
    private var started = false
    private var running = false
    private var listFetched: [String: Date] = [:]
    private var listBusy = Set<String>()
    private var lastGame: [String: String] = [:]
    private let art = NSCache<NSString, UIImage>()
    private var bumpQueued = false

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        CryptoManager.generateKeyPairUsingSSL()
        _ = IdManager.getUniqueId()
        clientCert = CryptoManager.readCertFromFile()
        hosts = MCBridge.savedHosts()
        MCPs5Store.testAdd()
        // a handheld streams at its own screen size unless you chose one (Moonlight's default is 720p)
        if !UserDefaults.standard.bool(forKey: "mc_res_init") {
            UserDefaults.standard.set(true, forKey: "mc_res_init")
            let n = MCSettings.native
            MCSettings().save { $0.width = n.0; $0.height = n.1; $0.bitrate = MCRoot.defaultBitrate(n.0, n.1, $0.framerate) }
        }
        disc = DiscoveryManager(hosts: hosts, andCallback: self)
        assets = AppAssetManager(callback: self)
    }

    /// The home is on screen: look for PCs and keep their state fresh.
    func resume() {
        start()
        guard !running else { return }
        running = true
        disc.resetDiscoveryState()
        disc.startDiscovery()
        hosts.filter { $0.pairState == PairState.paired }.forEach { assets.retrieveAssets(from: $0) }
        startTicking()
        bump()
    }

    /// A stream starts or the app goes to the background.
    func pause() {
        guard running else { return }
        running = false
        ticker?.invalidate()
        ticker = nil
        disc.stopDiscovery()
        assets.stopRetrieving()
    }

    private func bump() {
        if bumpQueued { return }
        bumpQueued = true
        DispatchQueue.main.async {
            self.bumpQueued = false
            self.revision += 1
        }
    }

    // MARK: games

    func paired(_ h: TemporaryHost) -> Bool { h.pairState == PairState.paired }
    func online(_ h: TemporaryHost) -> Bool { h.state == State.online }

    func apps(_ h: TemporaryHost) -> [TemporaryApp] {
        ((h.appList as? Set<TemporaryApp>) ?? []).sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
    }

    func hidden(_ h: TemporaryHost) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "mc_hidden_\(h.uuid)") ?? [])
    }

    func setHidden(_ h: TemporaryHost, _ appId: String, _ on: Bool) {
        var s = hidden(h)
        if on { s.insert(appId) } else { s.remove(appId) }
        UserDefaults.standard.set(Array(s), forKey: "mc_hidden_\(h.uuid)")
        bump()
    }

    /// Every game: every PC game that isn't hidden.
    func allGames() -> [MCGame] {
        var out: [MCGame] = []
        for c in MCXbox.consoles {
            out.append(MCGame(key: "xb:\(c.id)", title: c.name, src: "Xbox", seed: "xb", running: false, host: nil, app: nil, xb: c))
        }
        for c in MCPs5Store.list() {
            // as on Android: the tile is named after the game the PS5 is running, and shows Running
            let st = ps5Status[c.host]
            out.append(MCGame(key: "ps:\(c.host)", title: st?.runningApp ?? c.name, src: "PS5", seed: "ps",
                              running: st?.power == .on && st?.runningApp != nil, host: nil, app: nil, ps: c))
        }
        for h in hosts where paired(h) {
            let hide = hidden(h)
            for a in apps(h) where !hide.contains(a.id ?? "") {
                out.append(MCGame(key: "pc:\(h.uuid):\(a.id ?? "")", title: a.name ?? "", src: "PC", seed: a.name ?? "",
                                  running: online(h) && h.currentGame == a.id, host: h, app: a))
            }
        }
        return out
    }

    /// Home's row: what's running, the last few played, then the rest of the PC games A to Z, up to ten.
    func homeGames() -> [MCGame] {
        let all = allGames()
        let byKey = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let recent = MCRecents.list().compactMap { byKey[$0] }
        var ordered: [MCGame] = []
        func add(_ g: MCGame) { if !ordered.contains(where: { $0.key == g.key }) { ordered.append(g) } }
        all.filter { $0.running }.forEach(add)
        recent.prefix(5).forEach(add)
        // consoles always keep their place on Home
        all.filter { $0.ps != nil || $0.xb != nil }.forEach(add)
        let kept = ordered.count
        recent.forEach(add)
        all.sorted { $0.title.lowercased() < $1.title.lowercased() }.forEach(add)
        return Array(ordered.prefix(max(10, kept)))
    }

    func boxArt(_ app: TemporaryApp) -> UIImage? {
        guard let path = AppAssetManager.boxArtPath(for: app) else { return nil }
        if let img = art.object(forKey: path as NSString) { return img }
        guard let img = UIImage(contentsOfFile: path) else { return nil }
        art.setObject(img, forKey: path as NSString)
        return img
    }

    // MARK: playing

    func play(_ g: MCGame) {
        if let c = g.ps {
            onPs5Stream?(c)
            return
        }
        if let c = g.xb {
            onXboxStream?(c)
            return
        }
        guard let h = g.host, let a = g.app else { return }
        if !online(h) {
            pcOffline(h)
            return
        }
        let current = apps(h).first { $0.id == h.currentGame && h.currentGame != "0" }
        if let cur = current, cur.id != a.id {
            dialog = MCDialog(title: "Quit \(cur.name ?? "the game") and start \(a.name ?? "this one")?",
                              message: "\(h.name) is playing \(cur.name ?? "another game"). Anything not saved in it is lost.",
                              opts: [.init(title: "Cancel", picked: true) {},
                                     .init(title: "Quit and start", danger: true) { [weak self] in
                                         self?.quit(h) { ok in if ok { self?.stream(g) } }
                                     }])
            return
        }
        stream(g)
    }

    private func stream(_ g: MCGame) {
        guard let a = g.app else { return }
        MCRecents.touch(g.key)
        let cfg = MCBridge.streamConfig(for: a)
        onStream?(cfg)
    }

    func quit(_ h: TemporaryHost, then: ((Bool) -> Void)? = nil) {
        busy = "Quitting the game…"
        DispatchQueue.global(qos: .userInitiated).async {
            let err = MCBridge.quitApp(on: h, discovery: self.disc)
            DispatchQueue.main.async {
                self.busy = nil
                self.bump()
                if let err = err {
                    self.dialog = MCDialog(title: "Couldn't quit", message: err, opts: [.init(title: "OK") {}])
                }
                then?(err == nil)
            }
        }
    }

    /// The Quick menu's Quit game: the stream screen is closing, quit on the PC it played from.
    func quitGame(atAddress address: String) {
        guard let h = hosts.first(where: { $0.activeAddress == address || $0.address == address || $0.localAddress == address }) else { return }
        quit(h)
    }

    private func pcOffline(_ h: TemporaryHost) {
        var opts: [MCDialog.Opt] = [.init(title: "Cancel", picked: true) {}]
        if h.mac != nil && h.mac != "00:00:00:00:00:00" {
            opts.append(.init(title: "Wake it up", sub: "Sends Wake-on-LAN") { [weak self] in self?.wake(h) })
        }
        dialog = MCDialog(title: "\(h.name) is off or asleep", message: "Turn it on, or check it's on the same network.", opts: opts)
    }

    // MARK: PCs

    func wake(_ h: TemporaryHost) {
        DispatchQueue.global().async { WakeOnLanManager.wake(h) }
        dialog = MCDialog(title: "Wake-up sent", message: "\(h.name) may take a moment to come up.", opts: [.init(title: "OK") {}])
    }

    func remove(_ h: TemporaryHost) {
        disc.removeHost(fromDiscovery: h)
        MCBridge.remove(h)
        hosts.removeAll { $0 === h }
        bump()
    }

    func addPc(_ address: String) {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        busy = "Looking for \(a)…"
        DispatchQueue.global(qos: .userInitiated).async {
            self.disc.discoverHost(a) { host, error in
                DispatchQueue.main.async {
                    self.busy = nil
                    if let host = host {
                        if !self.hosts.contains(where: { $0.uuid == host.uuid }) { self.hosts.append(host) }
                        self.bump()
                        if host.pairState != PairState.paired { self.pair(host) }
                    } else {
                        self.dialog = MCDialog(title: "No PC found at \(a)", message: error ?? "Check the address and that Sunshine is running.",
                                               opts: [.init(title: "OK") {}])
                    }
                }
            }
        }
    }

    private var pairing: TemporaryHost?

    /// Pairs with a PC: shows the PIN to type into Sunshine.
    func pair(_ h: TemporaryHost) {
        busy = "Contacting \(h.name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            var tries = 0
            while h.state == State.unknown && tries < 10 { sleep(1); tries += 1 }
            if let err = MCBridge.refreshServerInfo(h, discovery: self.disc) {
                DispatchQueue.main.async {
                    self.busy = nil
                    self.dialog = MCDialog(title: "Couldn't reach \(h.name)", message: err, opts: [.init(title: "OK") {}])
                }
                return
            }
            if h.pairState == PairState.paired {
                DispatchQueue.main.async { self.busy = nil; self.fetchApps(h, force: true) }
                return
            }
            self.disc.stopDiscoveryBlocking()
            self.pairing = h
            let http = HttpManager(host: h)
            let op = PairManager(manager: http, clientCert: self.clientCert, callback: self)
            self.pairQueue.addOperation(op!)
        }
    }

    func startPairing(_ pin: String!) {
        DispatchQueue.main.sync {
            self.busy = nil
            let name = self.pairing?.name ?? "the PC"
            self.dialog = MCDialog(title: "Pair with \(name)",
                                   message: "Enter this PIN on the PC: in Sunshine's web page, open PIN and type it in.",
                                   big: pin,
                                   opts: [.init(title: "Cancel", picked: true) { [weak self] in
                                       self?.pairing = nil
                                       self?.disc.startDiscovery()
                                   }])
        }
    }

    func pairSuccessful(_ serverCert: Data!) {
        DispatchQueue.main.async {
            guard let h = self.pairing else { return }
            h.serverCert = serverCert
            h.pairState = PairState.paired
            self.pairing = nil
            self.dialog = nil
            self.disc.startDiscovery()
            self.fetchApps(h, force: true)
        }
    }

    func pairFailed(_ message: String!) {
        DispatchQueue.main.async {
            self.pairing = nil
            self.disc.startDiscovery()
            self.dialog = MCDialog(title: "Pairing didn't work", message: message, opts: [.init(title: "OK") {}])
        }
    }

    func alreadyPaired() {
        DispatchQueue.main.async {
            guard let h = self.pairing else { return }
            self.pairing = nil
            self.dialog = nil
            self.disc.startDiscovery()
            h.pairState = PairState.paired
            self.fetchApps(h, force: true)
        }
    }

    // MARK: Moonlight callbacks

    func updateAllHosts(_ list: [Any]!) {
        let copy = (list as? [TemporaryHost]) ?? []
        DispatchQueue.main.async {
            self.hosts = copy
            self.tick()
        }
    }

    /// Discovery changes the hosts in place (online, paired, the running game) without a callback: look every two
    /// seconds while the home is up, redraw when anything changed, and fetch a game list that's missing or stale.
    private var ticker: Timer?
    private var lastState = ""

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let state = hosts.map { "\($0.uuid)|\($0.state.rawValue)|\($0.pairState.rawValue)|\($0.currentGame ?? "")|\($0.appList.count)" }.joined(separator: ";")
        if state != lastState { lastState = state; bump() }
        testAutoPair()
        testAutoPlay()
        probePs5s()
        for h in hosts where paired(h) && online(h) {
            let age = listFetched[h.uuid].map { -$0.timeIntervalSinceNow } ?? .infinity
            // a game started or quit on the PC, or the list is old: fetch it again
            let changed = lastGame[h.uuid] != h.currentGame
            lastGame[h.uuid] = h.currentGame
            if age > 120 || h.appList.isEmpty && age > 10 || changed && age > 5 { fetchApps(h) }
        }
    }

    #if DEBUG
    private var autoPaired = false
    #endif

    /// Every 10 s while the home is up: how each PS5 is (a UDP probe each, off the main thread).
    func probePs5s(force: Bool = false) {
        let consoles = MCPs5Store.list()
        guard !consoles.isEmpty, !probing, force || -lastPs5Probe.timeIntervalSinceNow > 10 else { return }
        probing = true
        lastPs5Probe = Date()
        DispatchQueue.global(qos: .utility).async {
            var st: [String: MCPs5Probe.Status] = [:]
            for c in consoles { st[c.host] = MCPs5Probe.probe(c.host) }
            DispatchQueue.main.async {
                self.probing = false
                self.ps5Status = st
                self.bump()
            }
        }
    }

    #if DEBUG
    private var autoPlayed = false
    #endif

    /// Test runs only: MC_PLAY=<game name> starts that game once its PC is online.
    private func testAutoPlay() {
        #if DEBUG
        guard !autoPlayed, let want = ProcessInfo.processInfo.environment["MC_PLAY"], !want.isEmpty,
              let g = allGames().first(where: { $0.title.caseInsensitiveCompare(want) == .orderedSame }), let h = g.host, online(h) else { return }
        autoPlayed = true
        play(g)
        #endif
    }

    /// Test runs only: MC_AUTOPAIR=<part of a PC's name> pairs with it once it's found (with MC_PIN set, the PIN is
    /// known in advance and approved on the PC by script).
    private func testAutoPair() {
        #if DEBUG
        guard !autoPaired, let want = ProcessInfo.processInfo.environment["MC_AUTOPAIR"], !want.isEmpty,
              let h = hosts.first(where: { $0.name.localizedCaseInsensitiveContains(want) && online($0) && !paired($0) }) else { return }
        autoPaired = true
        pair(h)
        #endif
    }

    func fetchApps(_ h: TemporaryHost, force: Bool = false) {
        guard !listBusy.contains(h.uuid) else { return }
        listBusy.insert(h.uuid)
        listFetched[h.uuid] = Date()
        DispatchQueue.global(qos: .utility).async {
            let err = MCBridge.refreshAppList(h, discovery: self.disc)
            DispatchQueue.main.async {
                self.listBusy.remove(h.uuid)
                if err == nil, self.running { self.assets.retrieveAssets(from: h) }
                self.bump()
            }
        }
    }

    func receivedAsset(for app: TemporaryApp!) { bump() }

    // MARK: network test

    /// Delay to each PC (5 tries of its status page) and whether this network blocks streaming ports.
    func networkTest() {
        busy = "Testing the network…"
        let pcs = hosts.filter { online($0) }
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            for h in pcs {
                guard let addr = h.activeAddress else { continue }
                let host = addr.contains(":") && !addr.hasPrefix("[") && addr.split(separator: ":").count > 2 ? "[\(addr)]" : addr
                var times: [Double] = []
                for _ in 0..<5 {
                    guard let url = URL(string: "http://\(host)\(host.contains("]") || !host.contains(":") ? ":47989" : "")/serverinfo") else { break }
                    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
                    req.httpMethod = "GET"
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let sem = DispatchSemaphore(value: 0)
                    var ok = false
                    URLSession.shared.dataTask(with: req) { _, r, _ in ok = r != nil; sem.signal() }.resume()
                    _ = sem.wait(timeout: .now() + 3)
                    if ok { times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000) }
                }
                if times.isEmpty {
                    lines.append("\(h.name): no answer")
                } else {
                    let avg = times.reduce(0, +) / Double(times.count)
                    let worst = times.max() ?? avg
                    let verdict = avg < 10 ? "great" : avg < 30 ? "good" : avg < 60 ? "fair, may stutter" : "slow"
                    lines.append(String(format: "%@: %.0f ms (worst %.0f), %@", h.name, avg, worst, verdict))
                }
            }
            for c in MCPs5Store.list() {
                lines.append("\(c.name): \(MCPs5Store.reachable(c.host) ? "reachable on this network" : "not answering (asleep or off)")")
            }
            let ports = MCBridge.testNetworkPorts()
            lines.append(ports == 0 ? "This network lets streaming through" : ports < 0 ? "Couldn't check the network's ports"
                                                                                       : "This network blocks some streaming ports (away play may fail)")
            DispatchQueue.main.async {
                self.busy = nil
                self.dialog = MCDialog(title: "Network test", message: lines.isEmpty ? "No PC is online." : lines.joined(separator: "\n"),
                                       opts: [.init(title: "OK") {}])
            }
        }
    }

    /// The address to reach a PC from away (another network or a VPN).
    func setAwayAddress(_ h: TemporaryHost, _ address: String) {
        let a = address.trimmingCharacters(in: .whitespaces)
        h.externalAddress = a.isEmpty ? nil : a
        MCBridge.save(h)
        bump()
    }

    // MARK: controllers

    func controllersDialog() {
        let pads = GCController.controllers()
        let names = pads.map { c -> String in
            let b = c.battery.map { " · \(Int($0.batteryLevel * 100))%" } ?? ""
            return (c.vendorName ?? "Controller") + b
        }
        dialog = MCDialog(title: "Controllers",
                          message: names.isEmpty ? "None connected. Pair one in the iPad's Settings → Bluetooth, with the pad in pairing mode."
                                                 : names.joined(separator: "\n"),
                          opts: [.init(title: "OK") {}])
    }
}

/// What you played last, newest first (Recents.kt).
enum MCRecents {
    static func list() -> [String] { UserDefaults.standard.stringArray(forKey: "mc_recents") ?? [] }
    static func touch(_ key: String) {
        var l = list().filter { $0 != key }
        l.insert(key, at: 0)
        UserDefaults.standard.set(Array(l.prefix(30)), forKey: "mc_recents")
    }
}
