//
//  MCAway.swift
//  MoonCast: is a PC stream "away" (over the internet) or at home (Network.kt), and what changes for an away
//  stream (AwayStream.kt).
//

import UIKit
import Darwin

/// Home or away for a PC stream, decided once at stream start from the address the PC is reached on:
///
///  1. The address is on-link on one of this device's own networks (Wi-Fi, Ethernet, cellular; not a VPN tunnel):
///     home. On-link is "inside one of the interfaces' own subnets" (its address and netmask), the iOS stand-in for
///     Android's "a route without a gateway".
///  2. The networks were read and none has it on-link: away. That covers a public address, a mobile network, and a
///     private address reached through a gateway (a site-to-site WireGuard/VPN or another subnet).
///  3. The networks can't be read: the address decides. Loopback, private (RFC 1918), link-local and IPv6 ULA are home;
///     anything else (public, CGNAT 100.64/10 as Tailscale uses) is away. A name that didn't resolve is away when it
///     is the PC's saved internet address and not its home one.
enum MCNetwork {
    enum Kind: String { case loopback, linkLocal, privateNet, ula, cgnat, publicNet }

    /// What kind of address [a] (4 or 16 bytes) is.
    static func kindOf(_ a: [UInt8]) -> Kind {
        if a.count == 16 {
            // an IPv4-mapped IPv6 address (::ffff:a.b.c.d) is its IPv4 address
            if a[0..<10].allSatisfy({ $0 == 0 }) && a[10] == 0xff && a[11] == 0xff { return kindOf(Array(a[12..<16])) }
            if a[0..<15].allSatisfy({ $0 == 0 }) && a[15] == 1 { return .loopback }
            if a[0] == 0xfe && (a[1] & 0xc0) == 0x80 { return .linkLocal }   // fe80::/10
            if (a[0] & 0xfe) == 0xfc { return .ula }                          // fc00::/7
            return .publicNet
        }
        guard a.count == 4 else { return .publicNet }
        switch (a[0], a[1]) {
        case (127, _): return .loopback
        case (169, 254): return .linkLocal
        case (10, _): return .privateNet
        case (172, 16...31): return .privateNet
        case (192, 168): return .privateNet
        case (100, 64...127): return .cgnat
        default: return .publicNet
        }
    }

    /// Addresses that only exist on a local network. CGNAT isn't one: it is a carrier's or a VPN's (Tailscale).
    static func isLocalKind(_ k: Kind) -> Bool { k == .loopback || k == .linkLocal || k == .privateNet || k == .ula }

    /// The rule. [onLink]: nil when the networks couldn't be read; [kind]: nil when the address didn't resolve.
    /// True means away.
    static func decide(onLink: Bool?, kind: Kind?, savedInternet: Bool) -> Bool {
        if kind == .loopback { return false }
        if onLink == true { return false }
        if onLink == false { return true }
        guard let k = kind else { return savedInternet }
        return !isLocalKind(k)
    }

    struct Verdict { let away: Bool; let why: String }

    /// The address part of "addr", "addr:port" or "[v6]:port".
    static func bare(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return (MCBridge.splitAddress(s)?["address"] as? String ?? s).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// Whether a stream to [host] (the address the PC is reached on) is away. Blocks for a name lookup: call it off
    /// the main thread.
    static func isAway(host: String?, pc: TemporaryHost?) -> Verdict {
        guard let h = bare(host) else { return Verdict(away: false, why: "no address") }
        let savedInternet = pc != nil && bare(pc?.localAddress)?.caseInsensitiveCompare(h) != .orderedSame &&
            bare(pc?.externalAddress)?.caseInsensitiveCompare(h) == .orderedSame
        guard let addr = resolve(h) else {
            return Verdict(away: decide(onLink: nil, kind: nil, savedInternet: savedInternet),
                           why: "\(h) didn't resolve" + (savedInternet ? ", saved internet address" : ""))
        }
        let kind = kindOf(addr)
        let link = onLink(addr)
        return Verdict(away: decide(onLink: link, kind: kind, savedInternet: savedInternet),
                       why: "\(h) (\(kind.rawValue), " + (link == true ? "on this network" : link == false ? "not on this network" : "networks unknown") + ")")
    }

    /// The first address [h] resolves to, as 4 or 16 bytes.
    static func resolve(_ h: String) -> [UInt8]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(h, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if let bytes = bytesOf(ai.pointee.ai_addr) { return bytes }
            p = ai.pointee.ai_next
        }
        return nil
    }

    private static func bytesOf(_ sa: UnsafeMutablePointer<sockaddr>?) -> [UInt8]? {
        guard let sa = sa else { return nil }
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) }
            }
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) }
            }
        default: return nil
        }
    }

    /// True when [addr] is inside the subnet of one of this device's own interfaces (not loopback, not a VPN tunnel:
    /// utun, ipsec, ppp, tun, tap), false when those were read and none has it, nil when none could be read.
    static func onLink(_ addr: [UInt8]) -> Bool? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var seen = false
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            let f = Int32(i.pointee.ifa_flags)
            let name = String(cString: i.pointee.ifa_name)
            guard f & IFF_UP != 0, f & IFF_LOOPBACK == 0,
                  !["utun", "ipsec", "ppp", "tun", "tap"].contains(where: { name.hasPrefix($0) }),
                  let mine = bytesOf(i.pointee.ifa_addr), let mask = bytesOf(i.pointee.ifa_netmask) else { continue }
            seen = true
            // an IPv4-mapped IPv6 address compares as IPv4
            let want = addr.count == 16 && addr[0..<10].allSatisfy({ $0 == 0 }) && addr[10] == 0xff && addr[11] == 0xff
                ? Array(addr[12..<16]) : addr
            guard mine.count == want.count, mask.count == want.count else { continue }
            if (0..<want.count).allSatisfy({ (mine[$0] & mask[$0]) == (want[$0] & mask[$0]) }) { return true }
        }
        return seen ? false : nil
    }
}

/// A PC stream started away from home: what changes for this one session. The saved settings and the chosen profile
/// are never changed.
///
///  - Home chosen and "Switch to Away automatically" on (the default): the stream uses the Away profile's resolution,
///    frame rate, bitrate, codec and HDR. When Away was never set up, Home's values stay (with a bitrate picked in
///    the Quick menu while away, if any).
///  - Whatever the profile: at most [capKbps], unless the Away profile itself sets a higher bitrate on purpose (then
///    that is respected). iOS has no PyroWave, so there is nothing else to turn off.
@objc(MCAwayStream)
final class MCAwayStream: NSObject {
    /// Away bitrate cap, kbps: the internet path rarely carries more than 20-50 Mbps.
    static let capKbps = 100_000

    struct Plan {
        let away: Bool
        /// Home was switched to the Away settings for this stream.
        let autoAway: Bool
        /// Highest bitrate the Quick menu offers, kbps (0: no cap).
        let capKbps: Int
        /// The note at stream start, or nil.
        let message: String?
        /// The bitrate this stream asked for, kbps.
        var kbps = 0
    }

    /// The plan of the PC stream running now (set at each start; a reconnect replaces it).
    static var current: Plan?

    /// Settings → Picture → Switch to Away automatically.
    static var autoAway: Bool { UserDefaults.standard.object(forKey: "mc_auto_away") as? Bool ?? true }

    /// Decides home or away for a stream to [host] and changes [cfg] for an away stream; sets [current] and calls
    /// [done] on the main thread. The name lookup runs off the main thread, at most 2 s.
    static func prepare(_ cfg: StreamConfiguration, host: TemporaryHost?, done: @escaping (Plan) -> Void) {
        let lock = NSLock()
        var verdict: MCNetwork.Verdict?
        var finished = false
        let address = cfg.host
        func finish() {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            let v = verdict ?? MCNetwork.Verdict(away: false, why: "\(address ?? "?"): no answer in 2 s")
            lock.unlock()
            DispatchQueue.main.async {
                NSLog("MoonCast: away check: \(v.away ? "away" : "home"), \(v.why)")
                var plan = v.away ? awayPlan(cfg) : Plan(away: false, autoAway: false, capKbps: 0, message: nil)
                plan.kbps = Int(cfg.bitRate)
                current = plan
                done(plan)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var v = MCNetwork.isAway(host: address, pc: host)
            #if DEBUG
            // test runs: MC_AWAY=away or home forces the verdict
            if let f = ProcessInfo.processInfo.environment["MC_AWAY"], f == "away" || f == "home" {
                v = MCNetwork.Verdict(away: f == "away", why: "MC_AWAY=\(f) (\(v.why))")
            }
            #endif
            lock.lock(); verdict = v; lock.unlock()
            finish()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish() }
    }

    private static func awayPlan(_ cfg: StreamConfiguration) -> Plan {
        let mode = MCSettings.profile
        let auto = mode == "home" && autoAway
        let live = MCSettings().load()
        // the bitrate the Away profile sets on purpose (0: its Auto, the default for its size), which may go over the cap
        var awayKbps = mode == "away" && live.bitrate != MCRoot.defaultBitrate(live.width, live.height, live.framerate) ? live.bitrate : 0
        // Away never set up: Home's own values stay (only the cap applies), with a bitrate picked in the Quick menu
        // while away, if any
        let useAway = auto && MCSettings.awaySetUp
        if auto && !useAway, let k = MCSettings.awayValue("bitrate") as? Int, k > 0 {
            awayKbps = k
            cfg.bitRate = Int32(k)
        }
        if useAway {
            let w = MCSettings.awayValue("width") as? Int ?? 1280, h = MCSettings.awayValue("height") as? Int ?? 720
            if !MCSettings.nativeOn, w > 0, h > 0 { cfg.width = Int32(w); cfg.height = Int32(h) }
            let fps = MCSettings.awayValue("fps") as? Int ?? 60
            cfg.frameRate = Int32(min(fps, UIScreen.main.maximumFramesPerSecond))
            let k = MCSettings.awayValue("bitrate") as? Int ?? 0
            let auto = MCRoot.defaultBitrate(Int(cfg.width), Int(cfg.height), Int(cfg.frameRate))
            awayKbps = k > 0 && k != MCRoot.defaultBitrate(w, h, fps) ? k : 0
            cfg.bitRate = Int32(k > 0 ? k : auto)
            let codec = UInt32(MCSettings.awayValue("codec") as? Int ?? 0)
            let hdr = MCSettings.awayValue("hdr") as? Bool ?? false
            MCBridge.setVideoFormats(cfg, codec: codec, hdr: hdr, yuv444: false)
        }
        let cap = max(awayKbps, capKbps)
        let capped = Int(cfg.bitRate) > cap
        if capped { cfg.bitRate = Int32(cap) }
        // what the note names: the codec the Away settings chose, else the picture's size and frame rate
        let codecName = useAway ? ["H.264", "HEVC", "AV1"][safe: (MCSettings.awayValue("codec") as? Int ?? 0) - 1] : nil
        let what = codecName ?? "\(cfg.height)p\(cfg.frameRate)"
        NSLog("MoonCast: away stream: profile \(mode)" + (useAway ? " -> Away settings" : auto ? " (Away not set up: Home values)" : "") +
              ", \(cfg.width)x\(cfg.height) \(cfg.frameRate) fps, \(cfg.bitRate / 1000) Mbps" + (capped ? ", capped" : ""))
        let msg = useAway || capped
            ? "Away from home: \(what) at \(cfg.bitRate / 1000) Mbps" + (capped ? " (high bitrates are for your home network)" : "")
            : nil
        return Plan(away: true, autoAway: auto, capKbps: cap, message: msg)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

/// A short note over everything for a few seconds (Android's toast), e.g. at the start of an away stream.
enum MCToast {
    private static weak var shown: UIView?

    static func show(_ text: String, seconds: Double = 3.5) {
        DispatchQueue.main.async {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) else { return }
            shown?.removeFromSuperview()
            let label = UILabel()
            label.text = text
            label.numberOfLines = 3
            label.textAlignment = .center
            label.textColor = .white
            label.font = .systemFont(ofSize: UIDevice.current.userInterfaceIdiom == .pad ? 17 : 15, weight: .semibold)
            let box = UIView()
            box.backgroundColor = UIColor(white: 0.12, alpha: 0.92)
            box.layer.cornerRadius = 18
            box.isUserInteractionEnabled = false
            box.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            box.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(box)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
                label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20),
                label.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
                box.centerXAnchor.constraint(equalTo: window.centerXAnchor),
                box.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -28),
                box.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, multiplier: 0.86),
            ])
            shown = box
            box.alpha = 0
            UIView.animate(withDuration: 0.2) { box.alpha = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                UIView.animate(withDuration: 0.3, animations: { box.alpha = 0 }) { _ in box.removeFromSuperview() }
            }
        }
    }
}
