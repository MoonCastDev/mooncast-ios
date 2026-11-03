//
//  MCLink.swift
//  MoonCast: Settings → PC → Automatic bitrate (on by default, per profile). A PC stream's bitrate follows what the
//  network carries, for every codec (H.264, HEVC, AV1, PyroWave): it steps down when packets go missing before they
//  reach the app (moonlight-common-c's RTP sequence count: the Wi-Fi link is full) and back up, toward the bitrate
//  set in Settings and never above it, once the link has been clean for a minute.
//
//  The measure is the stream itself: packets missing by RTP sequence above 2% for 3 s in a row (above 5% for 5 s
//  within two minutes of a change, so a dip after one isn't taken for the link) mean the link is full, and what
//  arrived then is what it carries. That's remembered for this PC on this network (its subnet; a day at most) and
//  applies from the next start too. A step down goes to 80% of it, net of FEC and headers; a step up adds a fifth,
//  at most once a minute, and an up-step that starts losing within a minute goes back and waits twice as long before
//  trying again (up to 15 minutes), so the bitrate doesn't seesaw.
//
//  Polaris takes a new bitrate mid-stream (POST /polaris/v1/session/bitrate from the paired stream owner; its
//  encoders apply it live, PyroWave from the next frame), so the stream carries on. Other hosts, and a PyroWave
//  stream that has to change to 4:2:0, reconnect at the new rate (the game keeps running; Polaris and Sunshine
//  resume it), at most twice a minute and an up-step at most once a minute.
//
//  Off: the bitrate set is the bitrate streamed, nothing is learnt or capped.
//

import UIKit

@objc(MCLink)
final class MCLink: NSObject {
    static let share = 0.8
    /// On the wire over the stream's bitrate: FEC and the packets' own headers.
    static let wireOverhead = 1.1
    static let lossThreshold = 0.02
    static let lossSeconds = 3
    static let cautiousLossThreshold = 0.05
    static let cautiousLossSeconds = 5
    /// A change in the last this many seconds makes the next step down need [cautiousLossThreshold].
    static let cautiousWindow: TimeInterval = 120
    static let cleanThreshold = 0.005
    static let cleanSeconds = 60
    static let stepUp = 1.2
    static let maxBackoff: TimeInterval = 900
    static let maxAge: TimeInterval = 24 * 3600
    static let settleSeconds = 3.0

    private static var d: UserDefaults { .standard }

    /// Settings → PC → Automatic bitrate.
    @objc static var enabled: Bool { d.object(forKey: "mc_auto_bitrate") as? Bool ?? true }

    /// To the unified log and stderr (devicectl --console shows only stderr).
    static func log(_ line: String) {
        NSLog("%@", line)
        fputs(line + "\n", stderr)
    }

    // MARK: this network

    /// This device's Wi-Fi (or wired) IPv4 subnet, like "192.168.100.0/24"; nil off such a network.
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

    /// This PC on this network; off Wi-Fi and wired networks, the mobile network.
    static func key(_ host: TemporaryHost) -> String { "\(host.uuid)|\(subnet() ?? "mobile")" }

    // MARK: what's remembered

    /// What the link to [host] on this network was found to carry, kbps on the wire; nil when unknown or over a day old.
    static func capacity(_ host: TemporaryHost) -> Int? {
        guard let e = d.dictionary(forKey: "mc_pw_link")?[key(host)] as? [String: Any] else { return nil }
        if let at = e["at"] as? Double, Date().timeIntervalSince1970 - at > maxAge {
            log("MoonCast: auto bitrate: the remembered link (~\((e["kbps"] as? Int ?? 0) / 1000) Mbps) is over a day old: unknown again")
            return nil
        }
        return e["kbps"] as? Int
    }

    static func remember(_ host: TemporaryHost, wireKbps: Int) {
        var all = d.dictionary(forKey: "mc_pw_link") ?? [:]
        all[key(host)] = ["kbps": wireKbps, "at": Date().timeIntervalSince1970]
        d.set(all, forKey: "mc_pw_link")
    }

    /// The bitrate to ask for on a link that carries [wireKbps]: 80% of it, net of FEC and headers, whole Mbps.
    static func capKbps(_ wireKbps: Int) -> Int { max(5_000, Int(Double(wireKbps) * share / wireOverhead) / 1000 * 1000) }

    /// What a link must carry for a stream at [kbps] to sit at 80% of it.
    static func wireFor(_ kbps: Int) -> Int { Int(Double(kbps) * wireOverhead / share) }

    /// The limit learnt most recently on this network (any PC), as a bitrate, for Settings' labels; nil when none is
    /// known here or Automatic bitrate is off.
    static var displayCapKbps: Int? {
        guard enabled, let all = d.dictionary(forKey: "mc_pw_link") else { return nil }
        let net = subnet() ?? "mobile"
        let fresh = Date().timeIntervalSince1970 - maxAge
        let here = all.filter { $0.key.hasSuffix("|\(net)") }.compactMap { $0.value as? [String: Any] }
            .filter { ($0["at"] as? Double ?? 0) >= fresh }
        let latest = here.max { ($0["at"] as? Double ?? 0) < ($1["at"] as? Double ?? 0) }
        return (latest?["kbps"] as? Int).map(capKbps)
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

    /// The stream being set up (prepare) and then watched (watch).
    private static var ceiling = 0
    private static var forced = false
    private static var pyro = false

    /// The bitrate the stream runs at now and the link limit, for the stats (0 / nil: not automatic).
    @objc private(set) static var liveKbps = 0
    @objc static var liveLimitKbps: Int { guard let h = liveHost, let w = capacity(h) else { return 0 }; return capKbps(w) }
    private static weak var liveHost: TemporaryHost?

    /// A PC stream to [host] is starting with [cfg]: its bitrate within what this network carries (the bitrate set
    /// stays the ceiling), and for PyroWave 4:2:0 when that's too little for 4:4:4.
    static func prepare(_ cfg: StreamConfiguration, host: TemporaryHost) -> Plan {
        pyro = MCPyroWave.wanted && MCPyroWave.deviceSupported && Int(cfg.serverCodecModeSupport) & 0x0080_0000 != 0
        forced = false
        liveKbps = 0
        if pyro, let f = forcedKbps {
            cfg.bitRate = Int32(f)
            forced = true
            log("MoonCast: auto bitrate: MC_PW_KBPS: \(f / 1000) Mbps, no automatic changes")
            return Plan()
        }
        guard enabled else { return Plan() }
        ceiling = Int(cfg.bitRate)
        guard let wire = capacity(host) else { return Plan() }
        let cap = capKbps(wire)
        let capped = ceiling > cap
        if capped { cfg.bitRate = Int32(cap) }
        // 4:4:4 carries twice the chroma of 4:2:0: below two thirds of the recommended (4:4:4) rate, 4:2:0 spends
        // the bits better
        let rec = Int(MCPyroWave.recommendedKbpsWidth(cfg.width, height: cfg.height, fps: cfg.frameRate))
        let allow444 = !pyro || !capped || Int(cfg.bitRate) * 3 >= rec * 2
        log("MoonCast: auto bitrate: this network carries ~\(wire / 1000) Mbps for \(host.name): \(cfg.bitRate / 1000) of \(ceiling / 1000) Mbps" +
            (capped ? " (capped)" : "") + (allow444 ? "" : ", PyroWave 4:2:0"))
        guard capped else { return Plan() }
        let what = allow444 || !MCPyroWave.want444 ? "" : ", 4:2:0"
        return Plan(allow444: allow444, note: "Wi-Fi carries ~\(wire / 1000) Mbps here; bitrate set to \(cfg.bitRate / 1000) Mbps\(what)")
    }

    // MARK: a stream running

    private static var timer: Timer?
    private static var reconnects: [Date] = []

    /// Watches the stream of [game] that just started with [cfg] and moves its bitrate with the link.
    static func watch(_ game: MCGame, cfg: StreamConfiguration) {
        timer?.invalidate()
        timer = nil
        guard enabled, !forced, let host = game.host else { return }
        liveHost = host
        var current = Int(cfg.bitRate)
        liveKbps = current
        MCLinkStream.width = Int(cfg.width)
        MCLinkStream.height = Int(cfg.height)
        MCLinkStream.fps = Int(cfg.frameRate)
        let started = Date()
        var activeSince: Date?
        var lastChange = Date()
        var lastUp: Date?
        var beforeUp: Int?
        var backoff: TimeInterval = 60
        var last: (p: UInt64, b: UInt64, m: UInt64, t: Date)?
        var streak = 0, clean = 0
        var samples: [Int] = []
        var busy = false

        func apply(_ kbps: Int, up: Bool, note: String) {
            busy = true
            setBitrate(game, host: host, from: current, to: kbps, up: up, note: note) { ok in
                busy = false
                guard ok else { return }
                current = kbps
                liveKbps = kbps
                lastChange = Date()
                streak = 0
                clean = 0
                samples = []
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
            let tot = MCPyroWave.receiveTotals()
            let now = (p: tot["packets"]?.uint64Value ?? 0, b: tot["bytes"]?.uint64Value ?? 0, m: tot["missing"]?.uint64Value ?? 0, t: Date())
            if activeSince == nil { activeSince = now.t }
            defer { last = now }
            guard !busy, let l = last, now.t.timeIntervalSince(activeSince!) >= settleSeconds,
                  now.t.timeIntervalSince(lastChange) >= settleSeconds, now.p >= l.p else { return }
            let dt = now.t.timeIntervalSince(l.t)
            let dp = Double(now.p - l.p), dm = Double(now.m >= l.m ? now.m - l.m : 0)
            guard dt > 0.2, dp > 0 else { return }
            let wireKbps = Int(Double(now.b - l.b) * 8 / 1000 / dt)
            let loss = dm / (dp + dm)
            let cautious = now.t.timeIntervalSince(lastChange) < cautiousWindow
            if loss > (cautious ? cautiousLossThreshold : lossThreshold) {
                streak += 1
                samples.append(wireKbps)
            } else {
                streak = 0
                samples = []
            }
            clean = loss < cleanThreshold ? clean + 1 : 0

            // the link is full: step down
            if streak >= (cautious ? cautiousLossSeconds : lossSeconds) {
                let carried = samples.reduce(0, +) / samples.count
                remember(host, wireKbps: carried)
                var to = capKbps(carried)
                // an up-step that started losing goes back, and the next one waits twice as long
                if let up = lastUp, now.t.timeIntervalSince(up) < 60, let b = beforeUp {
                    to = min(to, b)
                    backoff = min(backoff * 2, maxBackoff)
                    log("MoonCast: auto bitrate: the step up to \(current / 1000) Mbps lost packets: back to \(to / 1000) Mbps, next try in \(Int(backoff)) s")
                }
                log("MoonCast: auto bitrate: link full at \(current / 1000) Mbps (\(cautious ? ">5% missing for 5 s" : ">2% missing for 3 s")): " +
                    "\(carried / 1000) Mbps arrived, \(Int(loss * 100))% missing; step down to \(to / 1000) Mbps")
                streak = 0
                samples = []
                guard Double(to) < Double(current) * 0.95 else { return }
                lastUp = nil
                apply(to, up: false, note: "Wi-Fi carries ~\(carried / 1000) Mbps here; bitrate \(to / 1000) Mbps (auto)")
                return
            }

            // clean for a minute below the bitrate set: step up, a fifth at a time
            if clean >= cleanSeconds, current < ceiling, now.t.timeIntervalSince(lastUp ?? .distantPast) >= backoff {
                clean = 0
                if wireFor(current) > (capacity(host) ?? 0) { remember(host, wireKbps: wireFor(current)) }
                let to = min(ceiling, Int(Double(current) * stepUp) / 1000 * 1000)
                guard to > current else { return }
                log("MoonCast: auto bitrate: clean for \(cleanSeconds) s at \(current / 1000) Mbps: step up to \(to / 1000) of \(ceiling / 1000) Mbps")
                beforeUp = current
                lastUp = now.t
                remember(host, wireKbps: wireFor(to))
                apply(to, up: true, note: "Wi-Fi is clean: bitrate \(to / 1000) Mbps (auto)")
            } else if clean >= cleanSeconds {
                clean = 0
                // at the bitrate set and clean: what's remembered can't be less than this
                if wireFor(current) > (capacity(host) ?? 0) { remember(host, wireKbps: wireFor(current)) }
                if now.t.timeIntervalSince(lastUp ?? .distantPast) > 60 { backoff = 60 }
            }
        }
    }

    /// Moves the running stream to [to] kbps: live on Polaris, else (or for a PyroWave stream that has to change to
    /// 4:2:0) by reconnecting at it. [done] says whether it took, on the main thread.
    private static func setBitrate(_ game: MCGame, host: TemporaryHost, from: Int, to: Int, up: Bool, note: String,
                                   done: @escaping (Bool) -> Void) {
        let fmt = Int(McActiveVideoFormat())
        let isPyro = fmt & 0xF0000 != 0
        let is444 = fmt & 0xCCC04 != 0
        let rec = Int(MCPyroWave.recommendedKbpsWidth(Int32(MCLinkStream.width), height: Int32(MCLinkStream.height), fps: Int32(MCLinkStream.fps)))
        let needs420 = isPyro && is444 && to * 3 < rec * 2
        if host.isPolaris && !needs420 {
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = liveBitrate(host, kbps: to)
                DispatchQueue.main.async {
                    if ok {
                        log("MoonCast: auto bitrate: \(from / 1000) -> \(to / 1000) Mbps live (Polaris)")
                        MCToast.show(note, seconds: 3)
                        done(true)
                    } else {
                        log("MoonCast: auto bitrate: Polaris didn't take a live bitrate; reconnecting at \(to / 1000) Mbps")
                        done(reconnect(game, up: up, note: note))
                    }
                }
            }
            return
        }
        if needs420 { log("MoonCast: auto bitrate: \(to / 1000) Mbps is too little for PyroWave 4:4:4: reconnecting in 4:2:0") }
        done(reconnect(game, up: up, note: note))
    }

    /// Polaris: the stream's owner sets a live bitrate (the same units as the request at launch: video, FEC, audio
    /// and overhead). Blocks.
    private static func liveBitrate(_ host: TemporaryHost, kbps: Int) -> Bool {
        guard let status = MCBridge.polarisJSON(host, path: "/polaris/v1/session/status", body: nil),
              let session = status["app_session_id"] as? String, !session.isEmpty,
              let generation = (status["session_generation"] as? NSNumber)?.int64Value, generation > 0 else {
            log("MoonCast: auto bitrate: no Polaris session status")
            return false
        }
        let answer = MCBridge.polarisJSON(host, path: "/polaris/v1/session/bitrate",
                                          body: ["bitrate_kbps": kbps, "session_generation": generation, "app_session_id": session])
        let ok = (answer?["status"] as? Bool) == true
        if !ok { log("MoonCast: auto bitrate: Polaris answered \(answer.map { "\($0)" } ?? "nothing")") }
        else if let applied = answer?["bitrate_kbps"] as? Int { log("MoonCast: auto bitrate: Polaris controller target \(applied) kbps") }
        return ok
    }

    /// Reconnects (the game keeps running and resumes): the new start is capped by what's remembered. At most two
    /// a minute, an up-step at most once a minute.
    private static func reconnect(_ game: MCGame, up: Bool, note: String) -> Bool {
        reconnects = reconnects.filter { -$0.timeIntervalSinceNow < 60 }
        guard reconnects.count < (up ? 1 : 2), let a = streamController(), !MCQuickMenu.isOpen else {
            log("MoonCast: auto bitrate: not reconnecting now (rate limit or the Quick menu is open)")
            return false
        }
        reconnects.append(Date())
        timer?.invalidate()
        MCToast.show(note, seconds: 4)
        a.mcDisconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MCStore.shared.play(game, here: true) }
        return true
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

/// The running stream's size and frame rate (for PyroWave's 4:4:4 test while it runs).
enum MCLinkStream {
    static var width = 0, height = 0, fps = 60
}
