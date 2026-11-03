//
//  MCLink.swift
//  MoonCast: Settings → PC → Automatic bitrate (on by default, per profile), as docs/auto-bitrate-design.md
//  (MoonCastDev/moonlight-android#139) has it, for every host, network and PC codec.
//
//  The client measures and decides, once a second, from what every GameStream host sends: packets missing by RTP
//  sequence (lost before the device), frames FEC couldn't save, the Mbps that arrived and the round-trip time. Each
//  second is good, strained (RTT rising, or a little loss) or congested (over 2% missing, or frames given up on).
//  Congested for 3 s (5 s within 2 minutes of a change) steps down to 80% of what arrived net of FEC and headers,
//  never below the floor for the resolution and frame rate; 60 s of good below the ceiling (the bitrate set: it's
//  never streamed above) steps up a fifth, and an up-step that turns congested within a minute goes back and
//  doubles the wait before the next (up to 15 minutes). The first 3 s are ignored.
//
//  A change goes the best way the host offers (MCHostCaps, probed at start, never by name): A live, B (host-managed,
//  none yet), C reconnect and resume (any GameStream host; at most 2 a minute, 1 for an up-step, none while the Quick
//  menu is open), D advise only (a one-button prompt) when the reconnect budget is used up. A failed live call falls
//  back to C for the rest of the stream.
//
//  The device can't keep up (frames waiting to be decoded, or PyroWave presenting fewer than arrive, with no loss):
//  the bitrate is left alone and one hint says so. Below the floor: one suggestion of a lower resolution. PyroWave:
//  4:2:0 when the cap is under ⅔ of what 4:4:4 needs, and below ~60 Mbps at 1080p60 (scaled) one suggestion of HEVC,
//  once per network.
//
//  Memory stays on the device: what each PC's link carried on each network (a hash of the Wi-Fi's subnet; Ethernet,
//  Mobile and Away apart), when, and how often step-ups failed; 24 h at most. Off: nothing changes from before.
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
        /// Whether the host answers this way (blocks; not on the main thread).
        let probe: (TemporaryHost) -> Bool
        /// Asks for [kbps] mid-stream (the launch request's units); true when the host took it. Blocks.
        let set: (TemporaryHost, Int) -> Bool
    }

    static let liveBitrate: [LiveBitrate] = [
        // Polaris: the paired stream owner sets a live bitrate (docs/live-tuning.md; nvhttp.cpp
        // /polaris/v1/session/bitrate), applied by its encoders mid-stream, PyroWave from the next frame
        // its encoder can change live only where status says adaptive_runtime_update_supported (VAAPI, QSV, AMF and
        // software encoders can't), and bitrate_kbps is the ENCODER's rate: status's bitrate_units says how the
        // host split our launch request (split_kbps) into the encoder's (encoder_kbps)
        LiveBitrate(name: "Polaris live bitrate",
                    probe: { h in
                        guard let st = MCBridge.polarisJSON(h, path: "/polaris/v1/session/status", body: nil), st["app_session_id"] != nil else { return false }
                        let live = (st["adaptive_runtime_update_supported"] as? Bool) == true
                        if !live { MCLink.log("MoonCast: auto bitrate: Polaris's encoder can't change bitrate live (\(st["adaptive_bitrate_reason"] ?? "no reason"))") }
                        return live
                    },
                    set: { h, kbps in
                        guard let st = MCBridge.polarisJSON(h, path: "/polaris/v1/session/status", body: nil),
                              let session = st["app_session_id"] as? String, !session.isEmpty,
                              let gen = (st["session_generation"] as? NSNumber)?.int64Value, gen > 0,
                              (st["adaptive_runtime_update_supported"] as? Bool) == true else { return false }
                        var encoder = kbps
                        if let u = st["bitrate_units"] as? [String: Any], let enc = (u["encoder_kbps"] as? NSNumber)?.doubleValue, enc > 0 {
                            if let split = (u["split_kbps"] as? NSNumber)?.doubleValue, split > 0 {
                                encoder = Int(Double(kbps) * enc / split)
                            }
                            // the host capped our request: never above the encoder rate it settled on
                            if u["cap_kbps"] is NSNumber { encoder = min(encoder, Int(enc)) }
                        }
                        let a = MCBridge.polarisJSON(h, path: "/polaris/v1/session/bitrate",
                                                     body: ["bitrate_kbps": max(1000, encoder), "session_generation": gen, "app_session_id": session])
                        let ok = (a?["status"] as? Bool) == true
                        MCLink.log("MoonCast: auto bitrate: Polaris: \(kbps) kbps requested = \(encoder) kbps at the encoder: " +
                                   (ok ? "target \(a?["bitrate_kbps"] ?? "?") kbps" : "refused (\(a?["error"] ?? a?["state"] ?? "no answer"))"))
                        return ok
                    }),
    ]

    /// The first live way this host answers to, or nil. Remembers what it found for Settings' row.
    static func probe(_ host: TemporaryHost) -> LiveBitrate? {
        let found = liveBitrate.first { $0.probe(host) }
        setMode(host, found != nil ? "live" : "reconnect")
        return found
    }

    static func setMode(_ host: TemporaryHost, _ mode: String) {
        var modes = UserDefaults.standard.dictionary(forKey: "mc_link_modes") ?? [:]
        modes[host.uuid] = mode
        UserDefaults.standard.set(modes, forKey: "mc_link_modes")
    }

    /// What Settings says this PC does: "Live", "Brief reconnects" (not probed yet, or no live way) or "Suggestions only".
    static func modeLabel(_ host: TemporaryHost?) -> String {
        guard let h = host, let m = UserDefaults.standard.dictionary(forKey: "mc_link_modes")?[h.uuid] as? String else { return "Brief reconnects" }
        return ["live": "Live", "advise": "Suggestions only"][m] ?? "Brief reconnects"
    }
}

// MARK: the network

/// Which network this is, for the link memory: "wifi:<hash of its subnet>" (iOS gives an app the SSID and BSSID only
/// with the Wi-Fi-info entitlement and location access, and no gateway MAC), "ethernet:<hash>", "mobile", or "away"
/// for a stream over the internet.
enum MCNetworkId {
    private static let monitor: NWPathMonitor = {
        let m = NWPathMonitor()
        m.start(queue: DispatchQueue(label: "MoonCast path"))
        return m
    }()

    static func start() { _ = monitor }

    static func current(away: Bool = false) -> String {
        if away { return "away" }
        let path = monitor.currentPath
        if path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet) { return "mobile" }
        let kind = path.usesInterfaceType(.wiredEthernet) && !path.usesInterfaceType(.wifi) ? "ethernet" : "wifi"
        guard let net = subnet() else { return kind == "wifi" ? "mobile" : kind }
        let digest = SHA256.hash(data: Data(net.utf8))
        return kind + ":" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
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
        if id == "away" { return "away from home" }
        if id == "mobile" { return "mobile data" }
        return id.hasPrefix("ethernet") ? "this Ethernet" : "this Wi-Fi"
    }
}

// MARK: the controller

@objc(MCLink)
final class MCLink: NSObject {
    static let share = 0.8
    /// On the wire over the stream's bitrate: FEC and the packets' own headers.
    static let wireOverhead = 1.1
    static let congestedLoss = 0.02
    static let strainedLoss = 0.005
    static let lossSeconds = 3
    static let cautiousLossSeconds = 5
    static let cautiousWindow: TimeInterval = 120
    static let goodSeconds = 60
    static let stepUp = 1.2
    static let maxBackoff: TimeInterval = 900
    static let maxAge: TimeInterval = 24 * 3600
    static let settleSeconds = 3.0

    private static var d: UserDefaults { .standard }
    private static let store = "mc_link_v2"

    /// Settings → PC → Automatic bitrate.
    @objc static var enabled: Bool { d.object(forKey: "mc_auto_bitrate") as? Bool ?? true }

    /// To the unified log and stderr (devicectl --console shows only stderr).
    static func log(_ line: String) {
        NSLog("%@", line)
        fputs(line + "\n", stderr)
    }

    // MARK: limits

    /// The floor for a stream's size and frame rate: about 5 Mbps at 720p60, 10 at 1080p60, 20 at 1440p and 4K (3 for
    /// small or slow streams).
    static func floorKbps(_ w: Int, _ h: Int, _ fps: Int) -> Int {
        let r = Double(w * h * fps) / Double(1920 * 1080 * 60)
        if r < 0.3 { return 3000 }
        return min(20000, max(5000, Int(10000 * r) / 1000 * 1000))
    }

    /// Below this PyroWave looks worse than HEVC/AV1 at the same rate: ~60 Mbps at 1080p60, by pixels and frame rate.
    static func pyroHevcKbps(_ w: Int, _ h: Int, _ fps: Int) -> Int { Int(60000 * Double(w * h * fps) / Double(1920 * 1080 * 60)) }

    /// The bitrate to ask for on a link that carries [wireKbps]: 80% of it, net of FEC and headers, whole Mbps.
    static func capKbps(_ wireKbps: Int) -> Int { max(1000, Int(Double(wireKbps) * share / wireOverhead) / 1000 * 1000) }

    /// What a link must carry for a stream at [kbps] to sit at 80% of it.
    static func wireFor(_ kbps: Int) -> Int { Int(Double(kbps) * wireOverhead / share) }

    // MARK: memory per network

    static func key(_ host: TemporaryHost, _ net: String) -> String { "\(host.uuid)|\(net)" }

    private static func entry(_ k: String) -> [String: Any]? {
        guard let e = d.dictionary(forKey: store)?[k] as? [String: Any] else { return nil }
        if let at = e["at"] as? Double, Date().timeIntervalSince1970 - at > maxAge { return nil }
        return e
    }

    private static func put(_ k: String, _ change: (inout [String: Any]) -> Void) {
        var all = d.dictionary(forKey: store) ?? [:]
        var e = all[k] as? [String: Any] ?? [:]
        change(&e)
        e["at"] = Date().timeIntervalSince1970
        all[k] = e
        d.set(all, forKey: store)
    }

    /// What the link to [host] on [net] carried, kbps on the wire; nil when unknown or over a day old.
    static func capacity(_ host: TemporaryHost, _ net: String) -> Int? { entry(key(host, net))?["kbps"] as? Int }

    static func remember(_ host: TemporaryHost, _ net: String, wireKbps: Int) { put(key(host, net)) { $0["kbps"] = wireKbps } }

    private static func noteFailedUp(_ host: TemporaryHost, _ net: String) {
        put(key(host, net)) { $0["failedUps"] = ($0["failedUps"] as? Int ?? 0) + 1 }
    }

    /// Once per network: false when [flag] was already shown here (and marks it shown).
    private static func once(_ flag: String, _ host: TemporaryHost, _ net: String) -> Bool {
        let k = "mc_link_once"
        var all = d.dictionary(forKey: k) ?? [:]
        let id = "\(flag)|\(key(host, net))"
        if all[id] != nil { return false }
        all[id] = Date().timeIntervalSince1970
        d.set(all, forKey: k)
        return true
    }

    /// This network's learnt limit for [host] (or, without one, the most recent on this network), as a bitrate, for
    /// Settings; nil when none or Automatic bitrate is off.
    static func displayCapKbps(_ host: TemporaryHost? = nil) -> Int? {
        guard enabled else { return nil }
        let net = MCNetworkId.current()
        if let h = host { return capacity(h, net).map(capKbps) }
        guard let all = d.dictionary(forKey: store) else { return nil }
        let fresh = Date().timeIntervalSince1970 - maxAge
        let here = all.filter { $0.key.hasSuffix("|\(net)") }.compactMap { $0.value as? [String: Any] }.filter { ($0["at"] as? Double ?? 0) >= fresh }
        let latest = here.max { ($0["at"] as? Double ?? 0) < ($1["at"] as? Double ?? 0) }
        return (latest?["kbps"] as? Int).map(capKbps)
    }

    /// Settings' Forget: this network's limits, for every PC.
    static func forgetThisNetwork() {
        let net = MCNetworkId.current()
        var all = d.dictionary(forKey: store) ?? [:]
        for k in all.keys where k.hasSuffix("|\(net)") { all.removeValue(forKey: k) }
        d.set(all, forKey: store)
        log("MoonCast: auto bitrate: forgot \(MCNetworkId.label(net))'s limit")
    }

    static func resetAll() {
        for k in [store, "mc_link_once", "mc_link_modes", "mc_pw_link", "mc_pw_link_user"] { d.removeObject(forKey: k) }
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
        var allow444 = true
        var note: String?
    }

    private static var ceiling = 0
    private static var forced = false
    private static var net = "mobile"

    /// The bitrate the stream runs at now and the learnt limit, for the stats (0: not automatic).
    @objc private(set) static var liveKbps = 0
    @objc private(set) static var liveLimitKbps = 0

    /// A PC stream to [host] is starting with [cfg] ([away]: over the internet): its bitrate set is the ceiling; it
    /// starts at min(ceiling, 80% of what this network carried); for PyroWave in 4:2:0 when that's too little for 4:4:4.
    static func prepare(_ cfg: StreamConfiguration, host: TemporaryHost, away: Bool) -> Plan {
        let pyro = MCPyroWave.wanted && MCPyroWave.deviceSupported && !away && Int(cfg.serverCodecModeSupport) & 0x0080_0000 != 0
        forced = false
        liveKbps = 0
        liveLimitKbps = 0
        net = MCNetworkId.current(away: away)
        if pyro, let f = forcedKbps {
            cfg.bitRate = Int32(f)
            forced = true
            log("MoonCast: auto bitrate: MC_PW_KBPS: \(f / 1000) Mbps, no automatic changes")
            return Plan()
        }
        guard enabled else { return Plan() }
        ceiling = Int(cfg.bitRate)
        guard let wire = capacity(host, net) else {
            log("MoonCast: auto bitrate: \(MCNetworkId.label(net)) (\(net)) not learnt for \(host.name): starting at the ceiling, \(ceiling / 1000) Mbps")
            return Plan()
        }
        let floor = floorKbps(Int(cfg.width), Int(cfg.height), Int(cfg.frameRate))
        let cap = max(floor, capKbps(wire))
        liveLimitKbps = capKbps(wire)
        let capped = ceiling > cap
        if capped { cfg.bitRate = Int32(cap) }
        let rec = Int(MCPyroWave.recommendedKbpsWidth(cfg.width, height: cfg.height, fps: cfg.frameRate))
        let allow444 = !pyro || !capped || Int(cfg.bitRate) * 3 >= rec * 2
        log("MoonCast: auto bitrate: \(MCNetworkId.label(net)) (\(net)) carries ~\(wire / 1000) Mbps for \(host.name): " +
            "\(cfg.bitRate / 1000) of \(ceiling / 1000) Mbps" + (capped ? " (capped)" : "") + (allow444 ? "" : ", PyroWave 4:2:0"))
        guard capped else { return Plan() }
        let what = allow444 || !MCPyroWave.want444 ? "" : ", 4:2:0"
        return Plan(allow444: allow444, note: "Network limit here: \(cfg.bitRate / 1000) Mbps\(what)")
    }

    // MARK: a stream running

    private static var timer: Timer?
    private static var reconnects: [Date] = []

    enum Health { case good, strained, congested }

    /// Watches the stream of [game] that just started with [cfg] and moves its bitrate with the network.
    static func watch(_ game: MCGame, cfg: StreamConfiguration) {
        timer?.invalidate()
        timer = nil
        guard enabled, !forced, let host = game.host else { return }
        let w = Int(cfg.width), h = Int(cfg.height), fps = Int(cfg.frameRate)
        let floor = floorKbps(w, h, fps)
        let rec = Int(MCPyroWave.recommendedKbpsWidth(cfg.width, height: cfg.height, fps: cfg.frameRate))
        let net = self.net
        var current = Int(cfg.bitRate)
        liveKbps = current
        var live: MCHostCaps.LiveBitrate?
        var probed = false
        let started = Date()
        var activeSince: Date?
        var lastChange = Date()
        var lastUp: Date?
        var beforeUp: Int?
        var backoff: TimeInterval = 60
        var last: [String: Double]?
        var lastT = Date()
        var congested = 0, good = 0, deviceBound = 0
        var samples: [Int] = []
        var rttBase = Double.infinity
        var busy = false
        var hinted = Set<String>()

        func hint(_ flag: String, perNetwork: Bool, _ text: String) {
            guard !hinted.contains(flag) else { return }
            hinted.insert(flag)
            if perNetwork && !once(flag, host, net) { return }
            log("MoonCast: auto bitrate: hint (\(flag)): \(text)")
            MCToast.show(text, seconds: 5)
        }

        func moved(_ kbps: Int) {
            current = kbps
            liveKbps = kbps
            lastChange = Date()
            congested = 0
            good = 0
            samples = []
        }

        /// Tier A (live) when the host offers it, else C (reconnect and resume), else D (one-button prompt).
        func change(to kbps: Int, up: Bool, note: String?) {
            let fmt = Int(McActiveVideoFormat())
            let needs420 = fmt & 0xF0000 != 0 && fmt & 0xCCC04 != 0 && kbps * 3 < rec * 2
            if let l = live, !needs420 {
                busy = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = l.set(host, kbps)
                    DispatchQueue.main.async {
                        busy = false
                        if ok {
                            log("MoonCast: auto bitrate: \(current / 1000) -> \(kbps / 1000) Mbps live (tier A, \(l.name))")
                            if let n = note { MCToast.show(n, seconds: 3) }
                            moved(kbps)
                        } else {
                            // the rest of this stream goes the next way
                            log("MoonCast: auto bitrate: \(l.name) refused: tier C from now on")
                            live = nil
                            change(to: kbps, up: up, note: note)
                        }
                    }
                }
                return
            }
            if needs420 { log("MoonCast: auto bitrate: \(kbps / 1000) Mbps is too little for PyroWave 4:4:4: reconnecting in 4:2:0") }
            if up { remember(host, net, wireKbps: wireFor(kbps)) }
            if reconnect(game, up: up, note: note ?? "Bitrate \(kbps / 1000) Mbps (auto)") {
                moved(kbps)
            } else if !up {
                advise(game, host: host, kbps: kbps)
                lastChange = Date()
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            guard McVideoRunning() else {
                if activeSince != nil || -started.timeIntervalSinceNow > 30 {
                    t.invalidate()
                    liveKbps = 0
                }
                return
            }
            if !probed {
                probed = true
                DispatchQueue.global(qos: .utility).async {
                    let found = MCHostCaps.probe(host)
                    DispatchQueue.main.async {
                        live = found
                        log("MoonCast: auto bitrate: \(host.name): " + (found.map { "tier A, \($0.name)" } ?? "tier C, reconnect and resume"))
                    }
                }
            }
            let s = MCBridge.linkSignals().mapValues { $0.doubleValue }
            let nowT = Date()
            if activeSince == nil { activeSince = nowT }
            defer { last = s; lastT = nowT }
            guard !busy, let l = last, nowT.timeIntervalSince(activeSince!) >= settleSeconds,
                  nowT.timeIntervalSince(lastChange) >= settleSeconds else { return }
            let dt = nowT.timeIntervalSince(lastT)
            let dp = (s["packets"] ?? 0) - (l["packets"] ?? 0), dm = max(0, (s["missing"] ?? 0) - (l["missing"] ?? 0))
            guard dt > 0.2, dp > 0 else { return }
            let wireKbps = Int(((s["bytes"] ?? 0) - (l["bytes"] ?? 0)) * 8 / 1000 / dt)
            let loss = dm / (dp + dm)
            let lostFrames = max(0, (s["unrecoverable"] ?? 0) - (l["unrecoverable"] ?? 0))
            let rtt = s["rtt"] ?? -1
            if rtt > 0 && loss < strainedLoss { rttBase = min(rttBase, rtt) }
            let rttVar = s["rttVar"] ?? 0
            // a queue building: RTT well over its clean baseline, beyond its usual spread
            let rttRising = rtt > 0 && rttBase.isFinite && rtt > rttBase * 1.5 + max(10, 2 * rttVar)
            let health: Health
            let why: String
            if loss > congestedLoss { health = .congested; why = "loss" }
            else if lostFrames >= max(1, Double(fps) * 0.02) { health = .congested; why = "frames lost" }
            else if loss > strainedLoss { health = .strained; why = "some loss" }
            else if rttRising { health = .strained; why = "rtt rising" }
            else { health = .good; why = "" }

            // the device, not the network: frames waiting to be decoded, or PyroWave showing fewer than arrive
            let pres = MCPyroWave.lastPresentedFps
            let behind = (s["pending"] ?? 0) >= 3 || (pres >= 0 && pres < Double(fps) * 0.85)
            deviceBound = loss < strainedLoss && behind ? deviceBound + 1 : 0
            if deviceBound >= 5 {
                hint("device", perNetwork: false, "This device can't keep up at this setting: try a lower frame rate or the Battery style")
            }

            if health == .congested {
                congested += 1
                samples.append(wireKbps)
            } else {
                congested = 0
                samples = []
            }
            // a second strained only by RTT pauses the minute of good; loss restarts it
            if health == .good { good += 1 } else if why != "rtt rising" { good = 0 }
            #if DEBUG
            fputs(String(format: "MoonCast: auto bitrate: %@%@ · %.2f%% missing, %.0f frames lost, rtt %.0f (base %.0f, var %.0f) ms, %ld Mbps in, at %ld of %ld Mbps, good %ld/%ld\n",
                         health == .good ? "good" : health == .strained ? "strained" : "congested", why.isEmpty ? "" : " (\(why))",
                         loss * 100, lostFrames, rtt, rttBase.isFinite ? rttBase : -1, rttVar, wireKbps / 1000, current / 1000, ceiling / 1000,
                         good, goodSeconds), stderr)
            #endif
            let cautious = nowT.timeIntervalSince(lastChange) < cautiousWindow

            // congested: step down to 80% of what arrived, never below the floor
            if congested >= (cautious ? cautiousLossSeconds : lossSeconds) {
                let carried = samples.reduce(0, +) / samples.count
                remember(host, net, wireKbps: carried)
                liveLimitKbps = capKbps(carried)
                var to = capKbps(carried)
                if let up = lastUp, nowT.timeIntervalSince(up) < 60, let b = beforeUp {
                    to = min(to, b)
                    backoff = min(backoff * 2, maxBackoff)
                    noteFailedUp(host, net)
                    log("MoonCast: auto bitrate: the step up to \(current / 1000) Mbps turned congested: back to \(to / 1000) Mbps, next try in \(Int(backoff)) s")
                }
                lastUp = nil
                congested = 0
                samples = []
                if to < floor {
                    hint("floor", perNetwork: true, "\(MCNetworkId.label(net).capitalized) can't carry \(w)×\(h) well: try a lower resolution")
                    to = floor
                }
                log("MoonCast: auto bitrate: congested at \(current / 1000) Mbps (\(Int(loss * 100))% missing, \(Int(lostFrames)) frames lost, " +
                    "\(carried / 1000) Mbps arrived): step down to \(to / 1000) Mbps")
                if Int(McActiveVideoFormat()) & 0xF0000 != 0 && to < pyroHevcKbps(w, h, fps) {
                    hint("pyro-hevc", perNetwork: true, "PyroWave needs a cable or fast Wi-Fi: here HEVC looks better (another play style)")
                }
                guard Double(to) < Double(current) * 0.95 else { return }
                change(to: to, up: false, note: "Network busy: \(to / 1000) Mbps")
                return
            }

            // 60 s good below the ceiling: a fifth up, at most once per back-off
            guard good >= goodSeconds else { return }
            good = 0
            if wireFor(current) > (capacity(host, net) ?? 0) { remember(host, net, wireKbps: wireFor(current)) }
            guard current < ceiling, nowT.timeIntervalSince(lastUp ?? .distantPast) >= backoff else {
                if nowT.timeIntervalSince(lastUp ?? .distantPast) > 120 { backoff = 60 }
                return
            }
            let to = min(ceiling, Int(Double(current) * stepUp) / 1000 * 1000)
            guard to > current else { return }
            log("MoonCast: auto bitrate: good for \(goodSeconds) s at \(current / 1000) Mbps: step up to \(to / 1000) of \(ceiling / 1000) Mbps")
            beforeUp = current
            lastUp = nowT
            liveLimitKbps = max(liveLimitKbps, to)
            // quiet: no message for a step up unless it reconnects
            change(to: to, up: true, note: nil)
        }
    }

    /// Tier C: reconnects (the game keeps running and resumes); the new start is capped by what's remembered. At most
    /// two a minute, an up-step at most once a minute, none while the Quick menu is open.
    private static func reconnect(_ game: MCGame, up: Bool, note: String) -> Bool {
        reconnects = reconnects.filter { -$0.timeIntervalSinceNow < 60 }
        guard reconnects.count < (up ? 1 : 2), let a = streamController(), !MCQuickMenu.isOpen else {
            log("MoonCast: auto bitrate: reconnect budget used up (or the Quick menu is open)")
            return false
        }
        reconnects.append(Date())
        timer?.invalidate()
        log("MoonCast: auto bitrate: reconnecting (tier C): \(note)")
        MCToast.show(note, seconds: 3)
        a.mcDisconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MCStore.shared.play(game, here: true) }
        return true
    }

    /// Tier D: one button.
    private static var advising = false
    private static func advise(_ game: MCGame, host: TemporaryHost, kbps: Int) {
        guard !advising, let vc = streamController() as? UIViewController, vc.presentedViewController == nil else { return }
        advising = true
        log("MoonCast: auto bitrate: tier D, suggesting \(kbps / 1000) Mbps")
        let a = UIAlertController(title: "The network is struggling", message: "Lower the bitrate to \(kbps / 1000) Mbps? The game keeps running.",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Lower to \(kbps / 1000) Mbps", style: .default) { _ in
            advising = false
            reconnects = []
            _ = reconnect(game, up: false, note: "Bitrate \(kbps / 1000) Mbps (auto)")
        })
        a.addAction(UIAlertAction(title: "Not now", style: .cancel) { _ in advising = false })
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
