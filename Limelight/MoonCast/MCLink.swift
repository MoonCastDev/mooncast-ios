//
//  MCLink.swift
//  MoonCast: Settings → PC → Automatic bitrate (on by default, per profile), as docs/auto-bitrate-design.md
//  (MoonCastDev/moonlight-android#139) has it, with the same values as Android's AutoBitrate.kt where the design
//  doesn't give one. For every host, network and PC codec.
//
//  The client measures and decides, once a second, from what every GameStream host sends: packets missing by RTP
//  sequence (lost before the device), frames FEC couldn't save, the Mbps that arrived and the round-trip time. A second
//  is congested (over 2% missing, or a frame given up on), strained (some loss, or RTT over its lowest by more than
//  max(15 ms, that lowest)) or good; under 100 packets a second (a still picture) says nothing. Congested 3 s (5 s
//  within 2 minutes of a change) steps down to 80% of what arrived net of FEC and headers, never below the floor for
//  the resolution and frame rate (5 Mbps at 720p60, 10 at 1080p60, 20 at 1440p and 4K); 60 s of good (while at least
//  40% of the rate arrives) below the ceiling (the bitrate set) steps up 20%. A step-up that turns congested within a
//  minute goes back and doubles the wait before the next (60 s → 15 min), kept per network with how often it failed.
//  What was learnt is only the link limit: the bitrate setting itself never changes.
//
//  Changes go the best way the host offers (MCHostCaps, probed at start; nothing is judged until the probe is done):
//  A live, C reconnect and resume (any GameStream host; 2 a minute, step-ups 1 a minute, none while the Quick menu is
//  open: it asks again shortly), D a one-button suggestion when the budget is used (at most every 2 minutes).
//
//  Memory stays on the device, per PC + network (a hash of the Wi-Fi's subnet, Ethernet, Mobile; a stream away from
//  home is its own entry per place), at most 64 entries, 24 h each. Off: nothing changes from before.
//

import Network
import UIKit
import CryptoKit

// MARK: host capabilities

/// What a host can do for Automatic bitrate, found by probing (a small table: probe → capability → how to call). A
/// host no row answers for gets reconnect-and-resume.
enum MCHostCaps {
    struct LiveBitrate {
        let name: String
        /// Asks for a stream bitrate of [kbps] mid-stream; true when the host took it. Blocks.
        let set: (Int) -> Bool
    }

    struct Probe {
        let name: String
        /// The live call for this stream, or nil when the host doesn't offer it. Blocks; not on the main thread.
        let run: (TemporaryHost) -> LiveBitrate?
    }

    /// Polaris (papi-ux/polaris de8d152, src/nvhttp.cpp; docs/live-tuning.md): GET /polaris/v1/session/status gives the
    /// stream's scope (app_session_id, session_generation, owned_by_client), whether its encoder takes runtime changes
    /// (adaptive_runtime_update_supported: not VAAPI, QSV, AMF or software) and bitrate_units; POST
    /// /polaris/v1/session/bitrate takes the ENCODER's rate (our request less FEC, audio and overhead, as the handshake
    /// split it), for the session's sole owner. Another host's call is a new row.
    static let probes: [Probe] = [
        Probe(name: "polaris /polaris/v1/session/bitrate") { h in
            guard let st = MCBridge.polarisJSON(h, path: "/polaris/v1/session/status", body: nil) else { return nil }
            let id = st["app_session_id"] as? String ?? ""
            let gen = (st["session_generation"] as? NSNumber)?.int64Value ?? 0
            let owned = st["owned_by_client"] as? Bool ?? true
            let runtime = (st["adaptive_runtime_update_supported"] as? Bool) == true
            let u = st["bitrate_units"] as? [String: Any]
            let split = (u?["split_kbps"] as? NSNumber)?.doubleValue ?? 0
            let asked = (u?["requested_kbps"] as? NSNumber)?.doubleValue ?? 0
            let req = split > 0 ? split : asked
            let enc = (u?["encoder_kbps"] as? NSNumber)?.doubleValue ?? 0
            // the share of a request the encoder gets, as the handshake split it
            let share = req > 0 && enc > 0 ? min(1.0, max(0.3, enc / req)) : 0.8
            // the host capped our request: never ask its encoder for more than it gave
            let hostCap = split > 0 && asked > split ? Int(enc) : 0
            MCLink.log("MoonCast: auto bitrate: Polaris session: generation \(gen), owned \(owned), runtime bitrate \(runtime), encoder \(Int(enc)) of \(Int(req)) kbps")
            guard !id.isEmpty, gen > 0, owned, runtime else { return nil }
            return LiveBitrate(name: "Polaris session bitrate") { kbps in
                var e = Int(Double(kbps) * share)
                if hostCap > 0 { e = min(e, hostCap) }
                e = min(500_000, max(1000, e))
                let a = MCBridge.polarisJSON(h, path: "/polaris/v1/session/bitrate",
                                             body: ["bitrate_kbps": e, "app_session_id": id, "session_generation": gen])
                let ok = (a?["status"] as? Bool) == true
                MCLink.log("MoonCast: auto bitrate: Polaris: \(kbps) kbps = \(e) kbps at the encoder: " +
                           (ok ? "target \(a?["bitrate_kbps"] ?? "?") kbps" : "refused (\(a?["error"] ?? a?["state"] ?? "no answer"))"))
                return ok
            }
        },
    ]

    /// Runs the probes in order; the first that answers wins. Remembers the PC's mode for Settings.
    static func probe(_ host: TemporaryHost) -> LiveBitrate? {
        for p in probes {
            if let c = p.run(host) {
                MCLink.log("MoonCast: auto bitrate: host offers live bitrate (\(p.name))")
                setMode(host, "live")
                return c
            }
            MCLink.log("MoonCast: auto bitrate: probe \(p.name): not for this stream")
        }
        setMode(host, "reconnect")
        return nil
    }

    static func setMode(_ host: TemporaryHost, _ mode: String) {
        var modes = UserDefaults.standard.dictionary(forKey: "mc_link_modes") ?? [:]
        modes[host.uuid] = mode
        UserDefaults.standard.set(modes, forKey: "mc_link_modes")
    }

    /// What Settings says this PC does: Live, Brief reconnects or Suggestions only; before it has streamed, that it's
    /// found when you play.
    static func modeLabel(_ host: TemporaryHost?) -> String {
        guard let h = host, let m = UserDefaults.standard.dictionary(forKey: "mc_link_modes")?[h.uuid] as? String else {
            return "Live or brief reconnects, found when you play"
        }
        return ["live": "Live", "advise": "Suggestions only"][m] ?? "Brief reconnects"
    }
}

// MARK: the network

/// Which network this is, for the link memory: "wifi:<hash of its subnet>" (iOS gives an app the SSID and BSSID only
/// with the Wi-Fi-info entitlement and location access, and neither the gateway's MAC nor its address), "ethernet:…",
/// or "mobile". A stream away from home adds "|away" to the network it's played from.
enum MCNetworkId {
    private static let monitor: NWPathMonitor = {
        let m = NWPathMonitor()
        m.start(queue: DispatchQueue(label: "MoonCast path"))
        return m
    }()

    static func start() { _ = monitor }

    static func current() -> String {
        let path = monitor.currentPath
        if path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet) { return "mobile" }
        let kind = path.usesInterfaceType(.wiredEthernet) && !path.usesInterfaceType(.wifi) ? "ethernet" : "wifi"
        guard let net = subnet() else { return kind == "wifi" ? "mobile" : kind }
        let digest = SHA256.hash(data: Data(net.utf8))
        return kind + ":" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// This device's IPv4 subnet on its Wi-Fi or wired interface, like "192.168.100.0/24".
    static func subnet() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        var found: String?
        while let i = p {
            defer { p = i.pointee.ifa_next }
            let name = String(cString: i.pointee.ifa_name)
            guard name.hasPrefix("en"), let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  let m = i.pointee.ifa_netmask, Int32(i.pointee.ifa_flags) & IFF_UP != 0 else { continue }
            let addr = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let net = UInt32(bigEndian: addr & mask)
            let bits = UInt32(bigEndian: mask).nonzeroBitCount
            let s = "\(net >> 24).\((net >> 16) & 255).\((net >> 8) & 255).\(net & 255)/\(bits)"
            if name == "en0" { return s }
            if found == nil { found = s }
        }
        return found
    }

    static func label(_ id: String) -> String {
        if id == "mobile" { return "mobile data" }
        return id.hasPrefix("ethernet") ? "this Ethernet" : "this Wi-Fi"
    }
}

// MARK: the controller

@objc(MCLink)
final class MCLink: NSObject {
    static let share = 0.8
    static let wireOverhead = 1.1
    static let loss = 0.02
    static let congestedSeconds = 3
    static let cautiousSeconds = 5
    static let cautiousWindow: TimeInterval = 120
    static let goodSeconds = 60
    static let stepUp = 1.2
    static let upHold: TimeInterval = 60
    static let upHoldMax: TimeInterval = 900
    static let upProve: TimeInterval = 60
    static let maxAge: TimeInterval = 24 * 3600
    static let settle: TimeInterval = 3
    static let deviceSeconds = 5
    /// Packets a second below this say too little to judge (a still picture).
    static let minPackets = 100.0
    static let reconnectsPerMinute = 2
    static let upReconnectsPerMinute = 1
    static let maxEntries = 64

    private static var d: UserDefaults { .standard }
    private static let store = "mc_link_v3"

    /// Settings → PC → Automatic bitrate.
    @objc static var enabled: Bool { d.object(forKey: "mc_auto_bitrate") as? Bool ?? true }

    /// To the unified log and stderr (devicectl --console shows only stderr).
    static func log(_ line: String) {
        NSLog("%@", line)
        fputs(line + "\n", stderr)
    }

    // MARK: rates

    private static func load(_ w: Int, _ h: Int, _ fps: Int) -> Double { Double(w * h * fps) / Double(1920 * 1080 * 60) }

    /// Never below this: about 5 Mbps at 720p60, 10 at 1080p60, 20 at 1440p and 4K (3 for small or slow streams).
    static func floorKbps(_ w: Int, _ h: Int, _ fps: Int) -> Int {
        min(20_000, max(3000, Int((10 * load(w, h, fps)).rounded(.up)) * 1000))
    }

    /// PyroWave under this (60 Mbps at 1080p60, scaled) looks better as HEVC/AV1.
    static func pyroHevcKbps(_ w: Int, _ h: Int, _ fps: Int) -> Int { Int(60_000 * load(w, h, fps)) }

    /// The bitrate for a link that carries [wireKbps]: 80% of it, net of FEC and headers, whole Mbps.
    static func capKbps(_ wireKbps: Int) -> Int { Int(Double(wireKbps) * share / wireOverhead) / 1000 * 1000 }

    // MARK: memory (the link limit only)

    /// For one PC on one network: [rate] the bitrate to stream at (0: none, the ceiling), [wire] what the link carried,
    /// [hold] the wait before a step-up and [fails] how many failed.
    struct Link { var rate: Int, wire: Int, at: Double, hold: TimeInterval, fails: Int }

    static func key(_ host: TemporaryHost, _ net: String, away: Bool) -> String { "\(host.uuid)|\(net)\(away ? "|away" : "")" }

    static func recall(_ k: String) -> Link? {
        guard let e = d.dictionary(forKey: store)?[k] as? [String: Any], let at = e["at"] as? Double,
              Date().timeIntervalSince1970 - at <= maxAge else { return nil }
        return Link(rate: e["rate"] as? Int ?? 0, wire: e["wire"] as? Int ?? 0, at: at,
                    hold: e["hold"] as? Double ?? upHold, fails: e["fails"] as? Int ?? 0)
    }

    static func remember(_ k: String, _ l: Link) {
        var all = d.dictionary(forKey: store) ?? [:]
        if all.count >= maxEntries, all[k] == nil,
           let oldest = all.min(by: { (($0.value as? [String: Any])?["at"] as? Double ?? 0) < (($1.value as? [String: Any])?["at"] as? Double ?? 0) })?.key {
            all.removeValue(forKey: oldest)
        }
        all[k] = ["rate": l.rate, "wire": l.wire, "at": Date().timeIntervalSince1970, "hold": l.hold, "fails": l.fails]
        d.set(all, forKey: store)
    }

    /// The limit learnt on this network for [host] (at home or away); nil when none.
    static func limitHere(_ host: TemporaryHost?) -> Link? {
        guard let h = host else { return nil }
        let net = MCNetworkId.current()
        return [recall(key(h, net, away: false)), recall(key(h, net, away: true))].compactMap { $0 }.first { $0.rate > 0 }
    }

    /// For Settings without a PC: the most recent limit learnt on this network; nil when none or Automatic bitrate is off.
    static func displayCapKbps(_ host: TemporaryHost? = nil) -> Int? {
        guard enabled else { return nil }
        if let h = host { return limitHere(h)?.rate }
        let net = MCNetworkId.current()
        let all = d.dictionary(forKey: store) ?? [:]
        let here = all.filter { $0.key.components(separatedBy: "|").dropFirst().first == net }.compactMap { recall($0.key) }.filter { $0.rate > 0 }
        return here.max { $0.at < $1.at }?.rate
    }

    /// Settings' Forget: this network's limits, for every PC.
    static func forgetThisNetwork() {
        let net = MCNetworkId.current()
        var all = d.dictionary(forKey: store) ?? [:]
        let gone = all.keys.filter { $0.components(separatedBy: "|").dropFirst().first == net }
        gone.forEach { all.removeValue(forKey: $0) }
        d.set(all, forKey: store)
        log("MoonCast: auto bitrate: forgot \(gone.count) limit(s) on \(MCNetworkId.label(net))")
    }

    static func resetAll() {
        for k in [store, "mc_link_v2", "mc_link_once", "mc_link_modes", "mc_pw_link", "mc_pw_link_user"] { d.removeObject(forKey: k) }
    }

    /// Runs [show] once per network (for every PC) for [what].
    private static func oncePerNetwork(_ what: String, _ show: () -> Void) {
        var all = d.dictionary(forKey: "mc_link_once") ?? [:]
        let id = "\(what)|\(MCNetworkId.current())"
        guard all[id] == nil else { return }
        all[id] = Date().timeIntervalSince1970
        d.set(all, forKey: "mc_link_once")
        show()
    }

    /// Test runs: MC_PW_KBPS=<kbps> forces a PyroWave stream's bitrate (and no automatic changes then).
    static var forcedKbps: Int? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["MC_PW_KBPS"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        #else
        return nil
        #endif
    }

    // MARK: a stream starting

    struct Plan {
        var on = false
        var key: String?
        var ceiling = 0
        var start = 0
        var floor = 0
        var allow444 = true
        var note: String?
        var link: Link?
    }

    private static var plan = Plan()

    /// The bitrate the stream runs at now and the limit learnt here when it's under the ceiling, for the stats.
    @objc private(set) static var liveKbps = 0
    @objc private(set) static var liveLimitKbps = 0

    /// A PC stream to [host] is starting with [cfg] ([away]: over the internet): it starts at min(ceiling, the limit
    /// learnt here); only this stream's [cfg] changes, the bitrate set stays the ceiling. PyroWave starts in 4:2:0
    /// when that's under ⅔ of what its 4:4:4 needs.
    static func prepare(_ cfg: StreamConfiguration, host: TemporaryHost, away: Bool) -> Plan {
        let pyro = MCPyroWave.wanted && MCPyroWave.deviceSupported && !away && Int(cfg.serverCodecModeSupport) & 0x0080_0000 != 0
        liveKbps = 0
        liveLimitKbps = 0
        let ceiling = Int(cfg.bitRate)
        let floor = min(ceiling, floorKbps(Int(cfg.width), Int(cfg.height), Int(cfg.frameRate)))
        plan = Plan(on: false, ceiling: ceiling, start: ceiling, floor: floor)
        if pyro, let f = forcedKbps {
            cfg.bitRate = Int32(f)
            log("MoonCast: auto bitrate: MC_PW_KBPS: \(f / 1000) Mbps, no automatic changes")
            return plan
        }
        guard enabled else {
            log("MoonCast: auto bitrate: off: \(ceiling / 1000) Mbps as set")
            return plan
        }
        let net = MCNetworkId.current()
        let k = key(host, net, away: away)
        let link = recall(k)
        plan.on = true
        plan.key = k
        plan.link = link
        guard let l = link, l.rate > 0, l.rate < ceiling else {
            log("MoonCast: auto bitrate: on, ceiling \(ceiling / 1000) Mbps, floor \(floor / 1000), network \(net)\(away ? " (away)" : ""), " +
                (link.map { $0.rate > 0 ? "limit \($0.rate / 1000) Mbps (at or above the ceiling)" : "no limit learnt" } ?? "no limit learnt"))
            return plan
        }
        let start = max(floor, l.rate)
        cfg.bitRate = Int32(start)
        plan.start = start
        liveLimitKbps = l.rate
        let rec = Int(MCPyroWave.recommendedKbpsWidth(cfg.width, height: cfg.height, fps: cfg.frameRate))
        plan.allow444 = !pyro || start * 3 >= rec * 2
        log("MoonCast: auto bitrate: network \(net) carries ~\(l.wire / 1000) Mbps: starting at \(start / 1000) Mbps (ceiling \(ceiling / 1000))" +
            (plan.allow444 ? "" : ", PyroWave 4:2:0 (under 2/3 of \(rec / 1000) Mbps)"))
        // a start that is Automatic bitrate's own reconnect already said so
        let own = lastChangeAt != nil && -lastChangeAt!.timeIntervalSinceNow < 15
        plan.note = own ? nil : "Network limit here: \(start / 1000) Mbps" + (plan.allow444 || !MCPyroWave.want444 ? "" : ", 4:2:0")
        return plan
    }

    // MARK: a stream running (process-wide: a reconnect makes a new stream)

    private static var timer: Timer?
    private static var reconnects: [Date] = []
    private static var upReconnects: [Date] = []
    private static var lastChangeAt: Date?
    private static var lastUpAt: Date?
    private static var lastUpFrom = 0
    /// A step-up that the controller made (rate, link entry) waits to be proven before the memory takes it.
    private static var unprovenUp: (kbps: Int, wire: Int)?
    private static var lastSuggestAt: Date?
    private static var runs = 0

    enum Health { case good, strained, congested }

    /// Watches the stream of [game] that just started with [cfg] and moves its bitrate with the network.
    static func watch(_ game: MCGame, cfg: StreamConfiguration) {
        if timer != nil { log("MoonCast: auto bitrate: run \(runs) replaced by a new stream") }
        timer?.invalidate()
        timer = nil
        let plan = self.plan
        guard plan.on, let host = game.host else { return }
        runs += 1
        let run = runs
        let w = Int(cfg.width), h = Int(cfg.height), fps = Int(cfg.frameRate)
        let rec = Int(MCPyroWave.recommendedKbpsWidth(cfg.width, height: cfg.height, fps: cfg.frameRate))
        var current = plan.start
        liveKbps = current
        var hold = plan.link?.hold ?? upHold
        var fails = plan.link?.fails ?? 0
        var live: MCHostCaps.LiveBitrate?
        var probed = false
        var probeDone = false
        let startedAt = Date()
        var firstPacketAt: Date?
        var settleUntil: Date?
        var last: [String: Double]?
        var lastT = Date()
        var congested = 0, good = 0, slow = 0
        var samples: [Int] = []
        var rttBase = Double.infinity
        var working = false
        var deviceHinted = false
        var lastLogAt = Date.distantPast
        log("MoonCast: auto bitrate: run \(run) watching \(game.title) at \(current / 1000) Mbps (ceiling \(plan.ceiling / 1000), floor \(plan.floor / 1000))")

        func resetGood(_ why: String) {
            if good > 0 { fputs("MoonCast: auto bitrate: run \(run): good \(good) -> 0 (\(why))\n", stderr) }
            good = 0
        }

        func store(rate: Int, wire: Int) {
            guard let k = plan.key else { return }
            remember(k, Link(rate: rate >= plan.ceiling ? 0 : rate, wire: wire, at: 0, hold: hold, fails: fails))
            liveLimitKbps = rate < plan.ceiling ? rate : 0
        }

        /// A change took: what the stream runs at now.
        func changed(_ from: Int, _ to: Int) {
            current = to
            liveKbps = to
            lastChangeAt = Date()
            settleUntil = Date().addingTimeInterval(settle)
            congested = 0
            samples = []
            resetGood("bitrate changed to \(to / 1000) Mbps")
            if to > from { lastUpAt = Date(); lastUpFrom = from }
        }

        func reconnectNow(_ note: String) {
            log("MoonCast: auto bitrate: tier C: reconnecting at \(current / 1000) Mbps")
            timer?.invalidate()
            timer = nil
            guard let a = streamController() else { return }
            MCToast.show(note, seconds: 3)
            a.mcDisconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MCStore.shared.play(game, here: true) }
        }

        /// Tier C within the budget, else D (a suggestion, step-downs only). The Quick menu open: ask again shortly.
        func reconnectOrSuggest(_ from: Int, _ kbps: Int, _ note: String, down: Bool) {
            if MCQuickMenu.isOpen {
                log("MoonCast: auto bitrate: the Quick menu is open: asking again in a moment")
                if down { congested = congestedSeconds - 1 } else { good = goodSeconds - 1 }
                return
            }
            let now = Date()
            reconnects = reconnects.filter { now.timeIntervalSince($0) < 60 }
            upReconnects = upReconnects.filter { now.timeIntervalSince($0) < 60 }
            let budget = reconnects.count < reconnectsPerMinute && (down || upReconnects.count < upReconnectsPerMinute)
            guard budget else {
                if !down { log("MoonCast: auto bitrate: reconnect budget used: the step-up waits"); return }
                if let s = lastSuggestAt, now.timeIntervalSince(s) < cautiousWindow { return }
                lastSuggestAt = now
                log("MoonCast: auto bitrate: tier D: suggesting \(kbps / 1000) Mbps (reconnect budget used)")
                suggest("The network is struggling. Lower the bitrate to \(kbps / 1000) Mbps?", button: "Lower to \(kbps / 1000) Mbps") {
                    changed(from, kbps)
                    reconnectNow(note)
                }
                return
            }
            reconnects.append(now)
            if !down { upReconnects.append(now) }
            changed(from, kbps)
            reconnectNow(note)
        }

        /// Best tier first: live (A), else a brief reconnect (C) or a suggestion (D).
        func apply(_ kbps: Int, note: String, down: Bool) {
            let from = current
            // PyroWave going under ⅔ of its recommended rate in 4:4:4: only a new start brings 4:2:0
            let fmt = Int(McActiveVideoFormat())
            let needs420 = down && fmt & 0xF0000 != 0 && fmt & 0xCCC04 != 0 && kbps * 3 < rec * 2
            if let c = live, !needs420 {
                working = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = c.set(kbps)
                    DispatchQueue.main.async {
                        working = false
                        guard timer != nil else { return }
                        if ok {
                            changed(from, kbps)
                            log("MoonCast: auto bitrate: now \(kbps / 1000) Mbps (live)")
                            if down { MCToast.show(note, seconds: 3) }
                        } else {
                            log("MoonCast: auto bitrate: live change refused: brief reconnects for the rest of this stream")
                            live = nil
                            reconnectOrSuggest(from, kbps, note, down: down)
                        }
                    }
                }
                return
            }
            reconnectOrSuggest(from, kbps, note + (needs420 ? ", 4:2:0" : ""), down: down)
        }

        func stepDown(_ carried: Int, _ lossNow: Double, _ lost: Double) {
            congested = 0
            samples = []
            resetGood("stepping down")
            var to = min(plan.ceiling, capKbps(carried))
            let now = Date()
            // a step-up that turned congested within a minute: back to where it was (lower if the link says so),
            // and twice the wait before the next one
            if let up = lastUpAt, now.timeIntervalSince(up) < upProve {
                to = min(lastUpFrom, max(to, plan.floor))
                hold = min(hold * 2, upHoldMax)
                fails += 1
                lastUpAt = nil
                unprovenUp = nil
                log("MoonCast: auto bitrate: the step-up from \(lastUpFrom / 1000) Mbps turned congested: back, next step-up after \(Int(hold)) s (\(fails) failed)")
            }
            if to < plan.floor {
                log("MoonCast: auto bitrate: the link carries less than the floor (\(plan.floor / 1000) Mbps at \(w)x\(h) \(fps) fps)")
                oncePerNetwork("floor") { MCToast.show("This network carries only ~\(carried / 1000) Mbps: a lower resolution will look better.", seconds: 5) }
                to = plan.floor
            }
            log(String(format: "MoonCast: auto bitrate: congested (%.0f%%%% missing, %.0f frames lost) at %ld Mbps: %ld Mbps arrived; limit here %ld Mbps",
                       lossNow * 100, lost, current / 1000, carried / 1000, to / 1000).replacingOccurrences(of: "%%", with: "%"))
            store(rate: to, wire: carried)
            // already at (or under) it: something else is losing packets
            guard Double(current) > Double(to) * 1.05 else { return }
            if Int(McActiveVideoFormat()) & 0xF0000 != 0 && to < pyroHevcKbps(w, h, fps) {
                oncePerNetwork("pyro") { MCToast.show("PyroWave needs more than this network carries: HEVC or AV1 will look better here.", seconds: 5) }
            }
            apply(to, note: "Network busy: \(to / 1000) Mbps", down: true)
        }

        func stepUpNow() {
            resetGood("a minute of good: stepping up")
            let to = min(plan.ceiling, max(current + 1000, Int(Double(current) * stepUp) / 1000 * 1000))
            log("MoonCast: auto bitrate: good for \(goodSeconds) s at \(current / 1000) Mbps: up to \(to / 1000) Mbps (ceiling \(plan.ceiling / 1000))")
            // the memory takes it once it has held for a minute
            unprovenUp = (to, Int(Double(to) * wireOverhead / share))
            apply(to, note: "Network clear: \(to / 1000) Mbps", down: false)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            guard McVideoRunning() else {
                if firstPacketAt != nil || -startedAt.timeIntervalSinceNow > 30 {
                    log("MoonCast: auto bitrate: run \(run) ends (video stopped)")
                    t.invalidate()
                    if timer === t { timer = nil }
                    liveKbps = 0
                }
                return
            }
            if !probed && live == nil {
                probed = true
                DispatchQueue.global(qos: .utility).async {
                    let found = MCHostCaps.probe(host)
                    DispatchQueue.main.async {
                        live = found
                        probeDone = true
                        log("MoonCast: auto bitrate: " + (found.map { "tier A: live (\($0.name))" } ?? "tier C: brief reconnects (no live bitrate call)"))
                    }
                }
            }
            let s = MCBridge.linkSignals().mapValues { $0.doubleValue }
            let now = Date()
            let p = s["packets"] ?? 0
            guard p > 0 else { return }
            if firstPacketAt == nil { firstPacketAt = now; settleUntil = now.addingTimeInterval(settle) }
            let l = last
            let first = l == nil || p < (l?["packets"] ?? 0)
            let dt = now.timeIntervalSince(lastT)
            last = s
            lastT = now
            guard !first, let l = l, now >= (settleUntil ?? now), !working, probeDone, dt >= 0.2 else { return }
            let dp = p - (l["packets"] ?? 0)
            let dm = max(0, (s["missing"] ?? 0) - (l["missing"] ?? 0))
            let du = max(0, (s["unrecoverable"] ?? 0) - (l["unrecoverable"] ?? 0))
            let db = (s["bytes"] ?? 0) - (l["bytes"] ?? 0)
            guard dp + dm >= minPackets * dt else { return }   // a still picture: nothing to judge
            let wireKbps = Int(db * 8 / 1000 / dt)
            let lossNow = dm / (dp + dm)
            let rtt = s["rtt"] ?? -1
            if rtt > 0 && rtt < rttBase { rttBase = rtt }
            let rttRising = rtt > 0 && rttBase.isFinite && rtt > rttBase + max(15, rttBase)

            // the device, not the network: decoding slower than the frames come (PyroWave's GPU decode, or frames
            // piling up waiting for the decoder), and nothing missing on the way
            let dec = MCPyroWave.lastDecodeMs
            let deviceBound = dm == 0 && fps > 0 && ((dec > 0 && dec > 1000 / Double(fps)) || (s["pending"] ?? 0) >= 3)
            slow = deviceBound ? slow + 1 : 0
            if slow >= deviceSeconds && !deviceHinted {
                deviceHinted = true
                log("MoonCast: auto bitrate: device-bound: decode \(dec) ms, \(Int(s["pending"] ?? 0)) frames waiting, no loss: bitrate stays")
                MCToast.show("This device can't keep up at this setting. A lower frame rate or the Battery style will be smoother.", seconds: 5)
            }

            let health: Health
            let why: String
            if lossNow > loss { health = .congested; why = "loss" }
            else if du > 0 && !deviceBound { health = .congested; why = "frames lost" }
            else if lossNow > 0 { health = .strained; why = "some loss" }
            else if rttRising { health = .strained; why = "rtt rising" }
            else { health = .good; why = "" }
            if health == .congested { congested += 1; samples.append(wireKbps) } else { congested = 0; samples = [] }
            // good while the stream uses its bitrate (a quiet picture proves nothing about the link)
            if health != .good { resetGood(why) } else if wireKbps * 10 >= current * 4 { good += 1 }
            #if DEBUG
            fputs(String(format: "MoonCast: auto bitrate: run %ld: %@%@ · %.2f%%%% missing, %.0f frames lost, rtt %.0f (base %.0f) ms, %ld Mbps in, at %ld of %ld Mbps, good %ld/%ld\n",
                         run, health == .good ? "good" : health == .strained ? "strained" : "congested", why.isEmpty ? "" : " (\(why))",
                         lossNow * 100, du, rtt, rttBase.isFinite ? rttBase : -1, wireKbps / 1000, current / 1000, plan.ceiling / 1000,
                         good, goodSeconds).replacingOccurrences(of: "%%", with: "%"), stderr)
            #endif
            if health != .good && now.timeIntervalSince(lastLogAt) > 5 {
                lastLogAt = now
                log(String(format: "MoonCast: auto bitrate: %@: %.1f%%%% missing, %.0f frames lost, rtt %.0f ms (base %.0f), %ld Mbps arrived at %ld Mbps",
                           health == .strained ? "strained" : "congested", lossNow * 100, du, rtt, rttBase.isFinite ? rttBase : 0,
                           wireKbps / 1000, current / 1000).replacingOccurrences(of: "%%", with: "%"))
            }
            let cautious = lastChangeAt.map { now.timeIntervalSince($0) < cautiousWindow } ?? false
            if congested >= (cautious ? cautiousSeconds : congestedSeconds) {
                stepDown(samples.reduce(0, +) / samples.count, lossNow, du)
                return
            }
            // a step-up that held for a minute is proven: the memory takes it, and the wait starts over
            if let up = lastUpAt, now.timeIntervalSince(up) >= upProve {
                lastUpAt = nil
                if let u = unprovenUp, u.kbps == current {
                    store(rate: u.kbps, wire: u.wire)
                    log("MoonCast: auto bitrate: the step-up to \(u.kbps / 1000) Mbps held: the limit here is now \(u.kbps >= plan.ceiling ? "gone (at the ceiling)" : "\(u.kbps / 1000) Mbps")")
                }
                unprovenUp = nil
            }
            if good >= goodSeconds && current < plan.ceiling && now.timeIntervalSince(max(lastChangeAt ?? startedAt, startedAt)) >= hold {
                stepUpNow()
            }
        }
    }

    /// Tier D: one button.
    private static func suggest(_ text: String, button: String, _ action: @escaping () -> Void) {
        guard let vc = streamController() as? UIViewController, vc.presentedViewController == nil else { return }
        let a = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: button, style: .default) { _ in action() })
        a.addAction(UIAlertAction(title: "Not now", style: .cancel))
        vc.present(a, animated: true)
    }

    /// The stream screen showing now.
    private static func streamController() -> MCQuickActions? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        var vc = windows.first { $0.isKeyWindow }?.rootViewController
        while let v = vc {
            if let q = v as? MCQuickActions { return q }
            if let p = v.presentedViewController { vc = p; continue }
            if let n = v as? UINavigationController { vc = n.topViewController; continue }
            if let c = v.children.last { vc = c; continue }
            return nil
        }
        return nil
    }
}
