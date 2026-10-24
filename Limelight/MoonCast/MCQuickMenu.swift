//
//  MCQuickMenu.swift
//  MoonCast: the Quick menu over a PC stream (QuickMenu.kt's Switch look): the game, live numbers, then Keyboard,
//  Streaming status, Controllers, Task Manager, Power, Disconnect and Quit game (Touch screen is in Settings). Select + Start +
//  LB + RB or a swipe from the left edge opens it; B or a tap outside goes back to the game.
//

import SwiftUI
import GameController
import Network

@objc(MCQuickMenu)
final class MCQuickMenu: NSObject {
    private static var host: UIHostingController<MCQuickMenuView>?
    /// The menu is on screen (the stats card stays under it).
    @objc static var isOpen: Bool { host != nil }

    @objc static func show(in vc: UIViewController) {
        guard host == nil, let actions = vc as? MCQuickActions else { return }
        actions.mcMenuOpen(true)
        let model = MCQuickModel(actions: actions)
        let h = UIHostingController(rootView: MCQuickMenuView(model: model))
        h.view.backgroundColor = .clear
        h.view.frame = vc.view.bounds
        h.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.addChild(h)
        vc.view.addSubview(h.view)
        h.didMove(toParent: vc)
        host = h
        MCFocus.shared.pushScope("qm")
        MCPad.shared.attach()
        model.onClose = { close(actions); MCQuickMenu.model = nil }
        MCQuickMenu.model = model
    }

    private static var model: MCQuickModel?

    /// Test runs only: MC_QM_STEPS="8:open,11:1,14:close,18:open,22:5" (seconds after the stream starts: open the
    /// menu, press item N, close it), so the menu can be checked from a script.
    @objc static func runTestSteps(in vc: UIViewController) {
        #if DEBUG
        guard let steps = ProcessInfo.processInfo.environment["MC_QM_STEPS"] else { return }
        for step in steps.split(separator: ",") {
            let parts = step.split(separator: ":")
            guard parts.count == 2, let t = Double(parts[0]) else { continue }
            let what = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak vc] in
                guard let vc = vc else { return }
                switch what {
                case "open": show(in: vc)
                case "close": if let a = vc as? MCQuickActions { close(a) }
                default: if let i = Int(what) { model?.press?(i) }
                }
            }
        }
        #endif
    }

    static func close(_ actions: MCQuickActions) {
        guard let h = host else { return }
        host = nil
        MCPad.shared.detach()
        MCFocus.shared.popScope()
        h.willMove(toParent: nil)
        h.view.removeFromSuperview()
        h.removeFromParent()
        actions.mcMenuOpen(false)
    }
}

final class MCQuickModel: ObservableObject {
    let actions: MCQuickActions
    var onClose: () -> Void = {}
    /// What an item just did, shown in place of its subtitle for a moment (the menu stays open)
    @Published var flashes: [String: String] = [:]

    func flash(_ label: String, _ text: String) {
        flashes[label] = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.flashes[label] == text { self?.flashes[label] = nil }
        }
    }

    /// "main", "power" (Hibernate, Restart, Shut down) or "confirm:<what>"
    @Published var page = "main" {
        didSet { MCFocus.shared.id = "qm:0" }
    }
    /// Presses item N (test runs)
    var press: ((Int) -> Void)?
    @Published var stats: [(String, String)] = []
    @Published var rev = 0
    private var timer: Timer?

    init(actions: MCQuickActions) {
        self.actions = actions
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        let d = actions.mcStats()
        let fps = (d["fps"] as? NSNumber)?.floatValue
        let rtt = (d["rtt"] as? NSNumber)?.intValue ?? -1
        let loss = (d["loss"] as? NSNumber)?.floatValue
        let lostFrames = (d["lostFrames"] as? NSNumber)?.intValue
        let mbps = (d["mbps"] as? NSNumber)?.floatValue ?? 0
        let codec = d["codec"] as? String ?? ""
        stats = [
            (fps.map { String(format: "%.0f", $0) } ?? "…", "fps"),
            (rtt >= 0 ? "\(rtt) ms" : "…", "delay"),
            (String(format: mbps < 10 ? "%.1f" : "%.0f", mbps), "Mbps"),
            (lostFrames.map { "\($0)" } ?? loss.map { String(format: "%.1f%%", $0) } ?? "…", "lost"),
            (codec.isEmpty ? "…" : MCQuickModel.shortCodec(codec), "codec"),
        ]
    }

    /// "HEVC Main 10 SDR (4:4:4)" → "HEVC 10-bit 4:4:4": short enough for a stat tile.
    static func shortCodec(_ c: String) -> String {
        c.replacingOccurrences(of: " Main 10 SDR", with: " 10-bit").replacingOccurrences(of: " Main 10 HDR", with: " HDR")
            .replacingOccurrences(of: " 10-bit SDR", with: " 10-bit").replacingOccurrences(of: " 10-bit HDR", with: " HDR")
            .replacingOccurrences(of: " (4:4:4)", with: " 4:4:4")
    }

    func close() {
        timer?.invalidate()
        onClose()
    }
}

struct MCQuickMenuView: View {
    @ObservedObject var model: MCQuickModel
    @ObservedObject var focus = MCFocus.shared
    @AppStorage("hh_theme") private var theme = "dark"

    private struct Item {
        let icon: String
        let label: String
        let detail: String?
        var danger = false
        let run: () -> Void
    }

    /// Move to <TV>: the stream here ends (the game keeps running), the TV plays it and this iPad becomes its
    /// controller, after a moment for the PC, PS5 or Xbox to let this session go (MoveToTv.kt).
    private func moveToTv(_ a: MCQuickActions) -> [Item] {
        guard let tv = MCTvFinder.lastTv, let g = MCStore.shared.playing else { return [] }
        let kind = a.mcKind?() ?? "pc"
        if kind == "xbox" && !tv.canXbox { return [] }
        return [Item(icon: "tv", label: "Move to \(tv.name)", detail: "This \(MCDevice.name) becomes its controller") {
            model.close()
            if let keep = a.mcLeaveKeepOn { keep() } else { a.mcDisconnect() }
            // the PC, PS5 or Xbox must have let this session go before the TV starts, or the TV waits for ever
            // (a PC after 0.5 s still had the iPad's session: the TV's start never went on)
            DispatchQueue.main.asyncAfter(deadline: .now() + (kind == "xbox" ? 1 : 3)) {
                MCStore.shared.tvSession = MCTvSession(tv: tv, game: g)
            }
        }]
    }

    /// Power (PC): Hibernate, Restart or Shut down, each asked again with Cancel first.
    private func powerItems(_ a: MCQuickActions) -> [Item]? {
        let words = ["hibernate": ("Hibernate", "moon.zzz", "Saves everything and turns the PC off. Wake it from MoonCast"),
                     "restart": ("Restart", "arrow.clockwise", "Unsaved progress is lost"),
                     "shutdown": ("Shut down", "power", "Unsaved progress is lost")]
        if model.page == "power" {
            return [Item(icon: "chevron.left", label: "Back", detail: nil) { model.page = "main" }] +
                ["hibernate", "restart", "shutdown"].map { k in
                    let w = words[k]!
                    return Item(icon: w.1, label: w.0, detail: w.2, danger: k != "hibernate") { model.page = "confirm:" + k }
                }
        }
        if model.page.hasPrefix("confirm:"), let w = words[String(model.page.dropFirst(8))] {
            let k = String(model.page.dropFirst(8))
            return [Item(icon: "xmark", label: "Cancel", detail: nil) { model.page = "power" },
                    Item(icon: w.1, label: w.0 + " the PC", detail: "Windows: MoonCast types it into Run for you", danger: true) {
                        model.close()
                        a.mcPower?(k)
                    }]
        }
        return nil
    }

    private func items() -> [Item] {
        let a = model.actions
        let pads = GCController.controllers().count
        if let p = powerItems(a) { return p }
        let move = moveToTv(a)
        if a.mcKind?() == "xbox" {
            return [
                Item(icon: "xbox.logo", label: "Xbox button", detail: "Opens the guide") { a.mcPsButton?(); model.flash("Xbox button", "Pressed") },
                Item(icon: "info.circle", label: "Streaming status", detail: MCStatsLevel.label(MCStatsLevel.current) + " · Off, Lite, Detailed") { a.mcToggleStats(); model.rev += 1 },
                Item(icon: "gamecontroller", label: "Controllers", detail: pads == 1 ? "1 connected" : "\(pads) connected") {},
            ] + move + [
                Item(icon: "arrow.left", label: "Disconnect", detail: "The game keeps running") { model.close(); a.mcDisconnect() },
                Item(icon: "power", label: "Turn off the Xbox", detail: "Ends the game", danger: true) { model.close(); a.mcRestMode?() },
            ]
        }
        if a.mcKind?() == "ps5" {
            return [
                Item(icon: "info.circle", label: "Streaming status", detail: MCStatsLevel.label(MCStatsLevel.current) + " · Off, Lite, Detailed") { a.mcToggleStats(); model.rev += 1 },
                Item(icon: "gamecontroller", label: "Controllers", detail: pads == 1 ? "1 connected" : "\(pads) connected") {},
                Item(icon: "playstation.logo", label: "PS button", detail: "Pads without one: L2 + Start") { a.mcPsButton?(); model.flash("PS button", "Pressed") },
            ] + move + [
                Item(icon: "arrow.left", label: "Disconnect", detail: "Ask, rest mode or keep it on (Settings → PlayStation)") { model.close(); a.mcDisconnect() },
                Item(icon: "moon.zzz", label: "Rest mode", detail: "Puts the PS5 to sleep", danger: true) { model.close(); a.mcRestMode?() },
            ]
        }
        return [
            Item(icon: "keyboard", label: "Keyboard", detail: "On-screen") { a.mcToggleKeyboard(); model.close() },
            Item(icon: "info.circle", label: "Streaming status", detail: MCStatsLevel.label(MCStatsLevel.current) + " · Off, Lite, Detailed") { a.mcToggleStats(); model.rev += 1 },
            Item(icon: "gamecontroller", label: "Controllers", detail: pads == 1 ? "1 connected" : "\(pads) connected") {},
            Item(icon: "list.bullet.rectangle", label: "Task Manager", detail: "Windows: Ctrl + Shift + Esc") { a.mcTaskManager(); model.flash("Task Manager", "Opened on the PC") },
            Item(icon: "power", label: "Power", detail: "Hibernate, restart or shut down the PC") { model.page = "power" },
        ] + move + [
            Item(icon: "arrow.left", label: "Disconnect", detail: "The game keeps running") { model.close(); a.mcDisconnect() },
            Item(icon: "xmark", label: "Quit game", detail: nil, danger: true) {
                let address = a.mcHostAddress()
                model.close()
                a.mcDisconnect()
                MCStore.shared.quitGame(atAddress: address)
            },
        ]
    }

    var body: some View {
        GeometryReader { geo in
            let upright = geo.size.height > geo.size.width
            let m = MCMetrics(size: geo.size)
            let p = MCPalette(theme: theme)
            let _ = model.rev
            ZStack(alignment: upright ? .bottom : .trailing) {
                Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { model.close() }
                panel(m, p)
                    .padding(.top, geo.safeAreaInsets.top)
                    .padding(.bottom, geo.safeAreaInsets.bottom)
                    .frame(width: upright ? geo.size.width : m.px(680),
                           height: upright ? geo.size.height * 0.62 : geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
                    .background(UnevenRoundedRectangle(topLeadingRadius: upright ? m.px(36) : 0, topTrailingRadius: upright ? m.px(36) : 0)
                        .fill(p.panel.opacity(0.94)))
            }
            .ignoresSafeArea()
        }
        .mcCollectFrames(root: "qm")
        .onAppear {
            let list = items()
            model.press = { i in if i < list.count { items()[i].run() } }
            MCFocus.shared.preferred["qm"] = "qm:0"
            MCFocus.shared.id = "qm:0"
            MCFocus.shared.pageButton = { b in
                if b == .b && model.page != "main" { model.page = model.page == "power" ? "main" : "power"; return true }
                if b == .b || b == .menu { model.close(); return true }
                return false
            }
        }
    }

    private func panel(_ m: MCMetrics, _ p: MCPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.actions.mcTitle()).mcFont(36, m, weight: .heavy).foregroundColor(p.ink).lineLimit(2)
            Text((model.actions.mcKind?() == "ps5" ? "PlayStation 5 · " : model.actions.mcKind?() == "xbox" ? "Xbox · " : "") + "Select + Start + LB + RB opens this menu").mcFont(24, m).foregroundColor(p.sub).lineLimit(2)
                .padding(.top, m.px(8))
            HStack(spacing: m.px(8)) {
                ForEach(model.stats.indices, id: \.self) { i in
                    let s = model.stats[i]
                    VStack(spacing: m.px(4)) {
                        Text(s.0).font(.system(size: m.px(s.0.count <= 4 ? 34 : s.0.count <= 6 ? 28 : 22), weight: .heavy))
                            .foregroundColor(p.ink).lineLimit(1).minimumScaleFactor(0.6)
                        Text(s.1).mcFont(20, m, weight: .semibold).foregroundColor(p.sub)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, m.px(18))
                    .background(RoundedRectangle(cornerRadius: m.px(10)).fill(p.bg))
                }
            }
            .padding(.top, m.px(30)).padding(.bottom, m.px(20))
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: m.px(10)) {
                        let list = items()
                        ForEach(list.indices, id: \.self) { i in
                            let it = list[i]
                            HStack(spacing: m.px(22)) {
                                Image(systemName: it.icon).font(.system(size: m.px(24), weight: .bold)).foregroundColor(.white)
                                    .frame(width: m.px(52), height: m.px(52))
                                    .background(RoundedRectangle(cornerRadius: m.px(12)).fill(it.danger ? MCPalette.red : Color(hex: 0x5B6170)))
                                VStack(alignment: .leading, spacing: m.px(4)) {
                                    Text(it.label).mcFont(28, m, weight: .heavy).foregroundColor(it.danger ? MCPalette.red : p.ink)
                                    if let f = model.flashes[it.label] {
                                        Text(f).mcFont(21, m, weight: .semibold).foregroundColor(p.ring)
                                    } else if let d = it.detail {
                                        Text(d).mcFont(21, m, weight: .semibold).foregroundColor(p.sub)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, m.px(24))
                            .frame(minHeight: max(m.px(100), 52))
                            .background(RoundedRectangle(cornerRadius: m.px(16)).fill(focus.id == "qm:\(i)" ? p.bg : Color.clear))
                            .id("qm:\(i)")
                            .mcFocusable("qm:\(i)", scope: "qm", corner: m.px(16), ring: p.ring, action: it.run)
                        }
                    }
                    .padding(m.px(8))
                }
                .onChange(of: focus.id) { _, id in if let id = id, id.hasPrefix("qm:") { proxy.scrollTo(id) } }
            }
            HStack(spacing: m.px(12)) {
                Spacer()
                ForEach([("A", "OK"), ("B", "Back to the game")], id: \.0) { k, l in
                    Text(k).mcFont(24, m, weight: .heavy).foregroundColor(p.bg)
                        .frame(width: m.px(46), height: m.px(46)).background(Circle().fill(p.ink))
                        .padding(.leading, m.px(20))
                    Text(l).mcFont(24, m).foregroundColor(p.ink)
                        .onTapGesture { if k == "B" { model.close() } }
                }
            }
            .padding(.top, m.px(24))
        }
        .padding(.horizontal, m.px(44))
        .padding(.vertical, m.px(40))
    }
}


/// Power in the Quick menu (Game.java's hibernate): which command, and watching the PC go. Once the command is typed
/// the PC's port is checked every second; when it stops answering the stream ends with "<PC> is hibernating" (or
/// restarting, shutting down) instead of a connection error. A hibernate is remembered per PC (see MCStore.play).
@objc(MCPower)
final class MCPower: NSObject {
    private static var pending: (what: String, pc: String, at: Date)?

    @objc static func command(for what: String) -> String {
        switch what {
        case "hibernate": return "shutdown /h"
        case "restart": return "shutdown /r /t 0"
        default: return "shutdown /s /t 0"
        }
    }

    @objc static func started(what: String, address: String, appId: String, leave: @escaping () -> Void) {
        let store = MCStore.shared
        let h = store.host(atAddress: address)
        pending = (what, h?.name ?? "The PC", Date())
        if let h = h {
            if what == "hibernate" { UserDefaults.standard.set(["app": appId, "at": Date().timeIntervalSince1970], forKey: key(h)) }
            else { clearHibernated(h) }
        }
        guard let addr = MCBridge.splitAddress(address), let ip = addr["address"] as? String else { return }
        DispatchQueue.global(qos: .utility).async {
            sleep(5)
            for _ in 0..<90 {
                guard pending != nil else { return }
                if !answers(ip, port: 47989) {
                    DispatchQueue.main.async {
                        guard pending != nil else { return }
                        leave()
                        announce()
                    }
                    return
                }
                sleep(1)
            }
            pending = nil
        }
    }

    /// The connection ended: true (and the note shown) when it's because of a power command just sent.
    @objc static func consumeTermination() -> Bool {
        guard let p = pending, -p.at.timeIntervalSinceNow < 120 else { return false }
        announce()
        return true
    }

    private static func announce() {
        guard let p = pending else { return }
        pending = nil
        let doing = ["hibernate": "is hibernating", "restart": "is restarting"][p.what] ?? "is shutting down"
        let next = p.what == "restart" ? "It shows as online again when it's back." : "Wake it from Consoles when you want to play again."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MCStore.shared.dialog = MCDialog(title: "\(p.pc) \(doing)", message: next, opts: [.init(title: "OK") {}])
        }
    }

    private static func key(_ h: TemporaryHost) -> String { "mc_hibernated_\(h.uuid)" }

    /// The game a hibernate left running on this PC, for a week.
    static func hibernated(_ h: TemporaryHost) -> String? {
        guard let d = UserDefaults.standard.dictionary(forKey: key(h)), let at = d["at"] as? Double,
              Date().timeIntervalSince1970 - at < 7 * 86400 else { return nil }
        return d["app"] as? String
    }

    static func clearHibernated(_ h: TemporaryHost) { UserDefaults.standard.removeObject(forKey: key(h)) }

    /// A TCP connection to the PC's port within a second.
    private static func answers(_ ip: String, port: UInt16) -> Bool {
        let c = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let done = DispatchSemaphore(value: 0)
        var ok = false
        c.stateUpdateHandler = { st in
            switch st {
            case .ready: ok = true; done.signal()
            case .failed, .waiting: done.signal()
            default: break
            }
        }
        c.start(queue: .global(qos: .utility))
        _ = done.wait(timeout: .now() + 1)
        c.cancel()
        return ok
    }
}
