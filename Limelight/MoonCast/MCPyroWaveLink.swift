//
//  MCPyroWaveLink.swift
//  MoonCast: PyroWave at what this network carries. PyroWave asks for hundreds of Mbps; a Wi-Fi link that carries
//  less loses the end of every frame before it reaches the app (an iPhone 12 on home Wi-Fi took ~120 Mbps of a
//  194 Mbps stream, and nine frames in ten were lost). Stock Sunshine/Polaris has no throughput test, so the stream
//  itself is the measure: after its first seconds, packets missing by RTP sequence above 2% for 3 seconds in a row
//  mean the link is full, and what arrived then is what it carries. That's remembered for this PC on this network
//  (its subnet), and the stream starts again (Polaris resumes the game) at 80% of it, net of FEC and headers, in
//  4:2:0 when that's too little for 4:4:4. The PyroWave style's Recommended bitrate shows the same limit. A bitrate
//  set by hand is kept unless you agree to step down when asked (once per PC and network).
//

import UIKit

@objc(MCPyroWaveLink)
final class MCPyroWaveLink: NSObject {
    /// The share of the link's measured capacity PyroWave asks for.
    static let share = 0.8
    /// On the wire over the stream's bitrate: FEC and the packets' own headers.
    static let wireOverhead = 1.1
    /// Packets missing by sequence, as a share of those sent, that say the link is full.
    static let lossThreshold = 0.02
    /// Seconds in a row over the threshold before acting, and seconds ignored at the start.
    static let lossSeconds = 3
    static let settleSeconds = 3.0

    private static var d: UserDefaults { .standard }

    /// To the unified log and stderr (devicectl --console shows only stderr).
    private static func log(_ line: String) {
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
            // en0 (Wi-Fi) first
            if name == "en0" { return s }
            if found == nil { found = s }
        }
        return found
    }

    static func key(_ host: TemporaryHost) -> String? { subnet().map { "\(host.uuid)|\($0)" } }

    // MARK: what's remembered

    /// The link's measured capacity for [host] on this network, kbps on the wire.
    static func capacity(_ host: TemporaryHost) -> Int? {
        guard let k = key(host), let e = d.dictionary(forKey: "mc_pw_link")?[k] as? [String: Any] else { return nil }
        return e["kbps"] as? Int
    }

    static func remember(_ host: TemporaryHost, wireKbps: Int) {
        guard let k = key(host) else { return }
        var all = d.dictionary(forKey: "mc_pw_link") ?? [:]
        all[k] = ["kbps": wireKbps, "at": Date().timeIntervalSince1970]
        d.set(all, forKey: "mc_pw_link")
    }

    /// The bitrate to ask for on a link that carries [wireKbps]: 80% of it, net of FEC and headers, whole Mbps.
    static func capKbps(_ wireKbps: Int) -> Int { max(10_000, Int(Double(wireKbps) * share / wireOverhead) / 1000 * 1000) }

    /// The limit to show beside the PyroWave style's Recommended bitrate: the one learnt most recently on this
    /// network (the style is shared by all PCs), kbps; nil when none is known here.
    static var displayCapKbps: Int? {
        guard let net = subnet(), let all = d.dictionary(forKey: "mc_pw_link") else { return nil }
        let here = all.filter { $0.key.hasSuffix("|\(net)") }.compactMap { $0.value as? [String: Any] }
        let latest = here.max { ($0["at"] as? Double ?? 0) < ($1["at"] as? Double ?? 0) }
        return (latest?["kbps"] as? Int).map(capKbps)
    }

    /// "down" (step down when the link is full) or "keep" (keep the bitrate set by hand), per PC and network.
    private static func decision(_ host: TemporaryHost) -> String? {
        key(host).flatMap { d.dictionary(forKey: "mc_pw_link_user")?[$0] as? String }
    }

    private static func setDecision(_ host: TemporaryHost, _ v: String) {
        guard let k = key(host) else { return }
        var all = d.dictionary(forKey: "mc_pw_link_user") ?? [:]
        all[k] = v
        d.set(all, forKey: "mc_pw_link_user")
    }

    /// The PyroWave style's bitrate was set by hand (not its Recommended one).
    static var userSetRate: Bool { !MCPcStyles.pyroRecommendedRate }

    /// Test runs: MC_PW_KBPS=<kbps> forces a PyroWave stream's bitrate (and the stream never steps down by itself).
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

    /// A PyroWave stream to [host] is starting with [cfg]: its bitrate within what this network carries, and 4:2:0
    /// when that's too little for 4:4:4.
    static func prepare(_ cfg: StreamConfiguration, host: TemporaryHost) -> Plan {
        guard MCPyroWave.wanted, MCPyroWave.deviceSupported, Int(cfg.serverCodecModeSupport) & 0x0080_0000 != 0 else { return Plan() }
        if let f = forcedKbps {
            cfg.bitRate = Int32(f)
            log("MoonCast: PyroWave: MC_PW_KBPS: \(f / 1000) Mbps")
            return Plan()
        }
        guard let wire = capacity(host) else { return Plan() }
        let cap = capKbps(wire)
        let byHand = userSetRate && decision(host) != "down"
        let capped = Int(cfg.bitRate) > cap && !byHand
        if capped { cfg.bitRate = Int32(cap) }
        // 4:4:4 carries twice the chroma of 4:2:0: below two thirds of the recommended (4:4:4) rate, 4:2:0 spends
        // the bits better
        let rec = Int(MCPyroWave.recommendedKbpsWidth(cfg.width, height: cfg.height, fps: cfg.frameRate))
        let allow444 = !capped || Int(cfg.bitRate) * 3 >= rec * 2
        log("MoonCast: PyroWave: this network carries ~\(wire / 1000) Mbps for \(host.name): \(cfg.bitRate / 1000) Mbps" +
              (capped ? " (capped)" : byHand ? " (set by hand)" : "") + (allow444 ? "" : ", 4:2:0"))
        guard capped else { return Plan() }
        let what = allow444 || !MCPyroWave.want444 ? "" : ", 4:2:0"
        return Plan(allow444: allow444, note: "Wi-Fi carries ~\(wire / 1000) Mbps here; PyroWave set to \(cfg.bitRate / 1000) Mbps\(what)")
    }

    // MARK: a stream running

    private static var timer: Timer?
    private static var stepDowns: [Date] = []

    /// Watches the PyroWave stream of [game] that just started at [kbps] for a full link.
    static func watch(_ game: MCGame, kbps: Int) {
        timer?.invalidate()
        guard let host = game.host else { return }
        let started = Date()
        var activeSince: Date?
        var last: (p: UInt64, b: UInt64, m: UInt64, t: Date)?
        var streak = 0
        var samples: [Int] = []
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            guard MCPyroWave.streamActive else {
                // never started (another codec played) or ended
                if activeSince != nil || -started.timeIntervalSinceNow > 30 { t.invalidate() }
                return
            }
            let tot = MCPyroWave.receiveTotals()
            let now = (p: tot["packets"]?.uint64Value ?? 0, b: tot["bytes"]?.uint64Value ?? 0, m: tot["missing"]?.uint64Value ?? 0, t: Date())
            if activeSince == nil { activeSince = now.t }
            defer { last = now }
            guard let l = last, now.t.timeIntervalSince(activeSince!) >= settleSeconds, now.p >= l.p else { return }
            let dt = now.t.timeIntervalSince(l.t)
            let dp = Double(now.p - l.p), dm = Double(now.m >= l.m ? now.m - l.m : 0)
            guard dt > 0.2, dp > 0 else { return }
            let wireKbps = Int(Double(now.b - l.b) * 8 / 1000 / dt)
            let loss = dm / (dp + dm)
            if loss > lossThreshold {
                streak += 1
                samples.append(wireKbps)
            } else {
                streak = 0
                samples = []
            }
            guard streak >= lossSeconds else { return }
            t.invalidate()
            let carried = samples.reduce(0, +) / samples.count
            linkFull(game, host: host, kbps: kbps, carriedKbps: carried, loss: loss)
        }
    }

    private static func linkFull(_ game: MCGame, host: TemporaryHost, kbps: Int, carriedKbps: Int, loss: Double) {
        remember(host, wireKbps: carriedKbps)
        let cap = capKbps(carriedKbps)
        log("MoonCast: PyroWave link full at \(kbps / 1000) Mbps: \(carriedKbps / 1000) Mbps arrived, \(Int(loss * 100))% missing; " +
            "this PC on this network now gets \(cap / 1000) Mbps")
        if forcedKbps != nil { return }
        // already at (or under) what the link carries: something else is losing packets
        guard Double(kbps) > Double(cap) * 1.05 else { return }
        stepDowns = stepDowns.filter { -$0.timeIntervalSinceNow < 60 }
        guard stepDowns.count < 2 else { return }
        if userSetRate {
            switch decision(host) {
            case "keep": return
            case "down": break
            default:
                ask(game, host: host, kbps: kbps, carried: carriedKbps, cap: cap)
                return
            }
        }
        restart(game, note: "Wi-Fi carries ~\(carriedKbps / 1000) Mbps here; PyroWave set to \(cap / 1000) Mbps")
    }

    /// A bitrate set by hand: asks once (per PC and network) whether to step down.
    private static func ask(_ game: MCGame, host: TemporaryHost, kbps: Int, carried: Int, cap: Int) {
        guard let vc = streamController() as? UIViewController else { return }
        let a = UIAlertController(title: "Wi-Fi carries ~\(carried / 1000) Mbps here",
                                  message: "PyroWave at \(kbps / 1000) Mbps is losing most frames on this network. Step down to \(cap / 1000) Mbps for \(host.name) here?",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Step down to \(cap / 1000) Mbps", style: .default) { _ in
            setDecision(host, "down")
            restart(game, note: "PyroWave set to \(cap / 1000) Mbps on this network")
        })
        a.addAction(UIAlertAction(title: "Keep \(kbps / 1000) Mbps", style: .cancel) { _ in setDecision(host, "keep") })
        vc.present(a, animated: true)
    }

    /// Disconnects (the game keeps running; Polaris resumes it) and starts again: the next start is capped.
    private static func restart(_ game: MCGame, note: String) {
        guard let a = streamController(), !MCQuickMenu.isOpen else { return }
        stepDowns.append(Date())
        MCToast.show(note, seconds: 4)
        a.mcDisconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MCStore.shared.play(game, here: true) }
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
