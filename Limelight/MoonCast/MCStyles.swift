//
//  MCStyles.swift
//  MoonCast: the play styles behind Settings' cards (SettingsCards.kt): the PC's four presets of its own (Battery,
//  Balanced, Sharpest, Fastest), each fine-tuned, renamed, given an icon and a colour, and the PS5's and the Xbox's
//  ready-made sets. Picking a style writes the same settings the Classic list does.
//

import SwiftUI
import AVFoundation

/// One PC play style. Its values are [MCPcStyles.defaults] with what was fine-tuned on top (mc_pcstyle_<id>).
struct MCPcStyle {
    let id: String
    let defName: String
    let icon: String
    /// nil: the theme's cyan
    let color: UInt32?
}

/// The PC play styles and the PC settings they set, in their own terms: "res" ("native" or "WxH"), "fps" ("native"
/// or a number), "kbps" (0 = Auto, the default for the size and frame rate), "codec" (0 Auto, 1 H.264, 2 HEVC,
/// 3 AV1), "hdr", "shape" (fit, zoom, fill, stretch), "pacing" (true = Smoothest), "fsr" ("off", "fsr1"),
/// "fsrSharp" (0-100), "range", "ull".
enum MCPcStyles {
    static let purple: UInt32 = 0x8B5CF6
    static let orange: UInt32 = 0xF29A2E

    static let all: [MCPcStyle] = [
        MCPcStyle(id: "battery", defName: "Battery", icon: "leaf", color: 0x2DBE5A),
        MCPcStyle(id: "balanced", defName: "Balanced", icon: "half", color: nil),
        MCPcStyle(id: "sharpest", defName: "Sharpest", icon: "star", color: purple),
        MCPcStyle(id: "fastest", defName: "Fastest", icon: "bolt", color: orange),
    ]

    static func style(_ id: String?) -> MCPcStyle? { all.first { $0.id == id } }

    /// The order values are written in: the size and frame rate before the bitrate (Auto follows them).
    static let keys = ["res", "fps", "kbps", "codec", "hdr", "shape", "pacing", "fsr", "fsrSharp", "range", "ull"]
    private static let strings: Set<String> = ["res", "fps", "shape", "fsr"]
    private static let ints: Set<String> = ["kbps", "codec", "fsrSharp"]

    /// The screen shows HDR10.
    static var screenHdr: Bool { AVPlayer.availableHDRModes.contains(.hdr10) }

    /// A style's own values before any fine-tuning: all four start at Native resolution and frame rate.
    static func defaults(_ id: String) -> [String: Any] {
        switch id {
        case "battery": return ["res": "native", "fps": "native", "kbps": 15000, "codec": 1, "hdr": false, "pacing": true, "ull": false]
        case "balanced": return ["res": "native", "fps": "native", "kbps": 40000, "codec": 2, "pacing": true, "ull": false]
        case "sharpest":
            var m: [String: Any] = ["res": "native", "fps": "native", "kbps": 80000, "codec": 2, "pacing": true, "ull": false]
            if screenHdr { m["hdr"] = true }
            return m
        default: return ["res": "native", "fps": "native", "kbps": 60000, "codec": 2, "pacing": false, "ull": true]
        }
    }

    static func stored(_ id: String) -> [String: Any] { UserDefaults.standard.dictionary(forKey: "mc_pcstyle_\(id)") ?? [:] }
    static func store(_ id: String, _ m: [String: Any]) { UserDefaults.standard.set(m, forKey: "mc_pcstyle_\(id)") }

    /// A style's values: its defaults, then what was fine-tuned.
    static func values(_ id: String) -> [String: Any] { defaults(id).merging(stored(id)) { $1 } }

    /// The same value for [key], whatever type it came back as from the store.
    static func same(_ key: String, _ a: Any?, _ b: Any?) -> Bool {
        guard let a = a, let b = b else { return a == nil && b == nil }
        if strings.contains(key) { return (a as? String) == (b as? String) }
        if ints.contains(key) { return (a as? NSNumber)?.intValue == (b as? NSNumber)?.intValue }
        return (a as? NSNumber)?.boolValue == (b as? NSNumber)?.boolValue
    }

    // MARK: the live settings, in the styles' terms

    private static var d: UserDefaults { .standard }

    static func liveValue(_ key: String) -> Any? {
        let v = MCSettings().load()
        switch key {
        case "res": return MCSettings.nativeOn ? "native" : "\(v.width)x\(v.height)"
        case "fps": return MCSettings.nativeFps ? "native" : "\(v.framerate)"
        case "kbps": return v.bitrate == MCRoot.defaultBitrate(v.width, v.height, v.framerate) ? 0 : v.bitrate
        case "codec": return Int(v.codec)
        case "hdr": return v.hdr
        case "shape": return MCPictureShape.current
        case "pacing": return v.pacing
        case "fsr": return d.string(forKey: "mc_super_resolution") == "fsr1" ? "fsr1" : "off"
        case "fsrSharp": return d.object(forKey: "mc_fsr_sharpness") as? Int ?? 60
        case "range": return d.bool(forKey: "mc_full_range")
        case "ull": return d.bool(forKey: "mc_ultra_low_latency")
        default: return nil
        }
    }

    /// Writes one value into the live settings (the Classic list's keys). A bitrate on Auto stays Auto when the
    /// size or frame rate changes.
    static func putLive(_ key: String, _ value: Any) {
        let s = MCSettings()
        let was = s.load()
        let auto = was.bitrate == MCRoot.defaultBitrate(was.width, was.height, was.framerate)
        func keepAuto() { if auto { s.save { $0.bitrate = MCRoot.defaultBitrate($0.width, $0.height, $0.framerate) } } }
        switch key {
        case "res":
            let r = value as? String ?? "native"
            if r == "native" {
                let n = MCSettings.native
                s.save { $0.width = n.0; $0.height = n.1 }
                MCSettings.nativeOn = true
            } else {
                let wh = r.split(separator: "x").compactMap { Int($0) }
                guard wh.count == 2 else { return }
                s.save { $0.width = wh[0]; $0.height = wh[1] }
                MCSettings.nativeOn = false
            }
            keepAuto()
        case "fps":
            let f = value as? String ?? "native"
            MCSettings.nativeFps = f == "native"
            let n = f == "native" ? MCSettings.nativeHz : Int(f) ?? 60
            s.save { $0.framerate = n }
            keepAuto()
        case "kbps":
            let k = (value as? NSNumber)?.intValue ?? 0
            s.save { $0.bitrate = k > 0 ? k : MCRoot.defaultBitrate($0.width, $0.height, $0.framerate) }
        case "codec": s.save { $0.codec = UInt32((value as? NSNumber)?.intValue ?? 0) }
        case "hdr": s.save { $0.hdr = (value as? NSNumber)?.boolValue ?? false }
        case "pacing": s.save { $0.pacing = (value as? NSNumber)?.boolValue ?? false }
        case "shape": d.set(value as? String ?? "fit", forKey: "mc_picture_shape")
        case "fsr": d.set(value as? String ?? "off", forKey: "mc_super_resolution")
        case "fsrSharp": d.set((value as? NSNumber)?.intValue ?? 60, forKey: "mc_fsr_sharpness")
        case "range": d.set((value as? NSNumber)?.boolValue ?? false, forKey: "mc_full_range")
        case "ull": d.set((value as? NSNumber)?.boolValue ?? false, forKey: "mc_ultra_low_latency")
        default: break
        }
    }

    /// The style in use writes into the live settings as it is fine-tuned.
    static var inUseId: String? {
        get { d.string(forKey: "mc_style_pc") }
        set { d.set(newValue, forKey: "mc_style_pc") }
    }

    /// Sets one of a style's own values (and the live one while it's in use).
    static func putStyle(_ id: String, _ key: String, _ value: Any) {
        var m = stored(id)
        m[key] = value
        store(id, m)
        if inUseId == id { putLive(key, value) }
    }

    static func matches(_ id: String) -> Bool {
        values(id).allSatisfy { k, v in same(k, v, liveValue(k)) }
    }

    /// The style picked last or, when the settings match another one exactly, that one; else the closest.
    static func picked() -> MCPcStyle {
        if let p = style(inUseId), matches(p.id) { return p }
        if let m = all.first(where: { matches($0.id) }) { return m }
        if let p = style(inUseId) { return p }
        return all.max { a, b in score(a.id) < score(b.id) } ?? all[0]
    }

    private static func score(_ id: String) -> Int { values(id).filter { k, v in same(k, v, liveValue(k)) }.count }

    /// "Balanced", or "Balanced (changed)".
    static func nowLabel() -> String { let p = picked(); return matches(p.id) ? name(p) : "\(name(p)) (changed)" }

    /// Picks [st]: its values become the live settings.
    static func use(_ st: MCPcStyle) {
        let m = values(st.id)
        for k in keys { if let v = m[k] { putLive(k, v) } }
        inUseId = st.id
    }

    /// The live settings become [st]'s own values, and it is the one in use (Fine-tune's Y).
    static func saveInto(_ st: MCPcStyle) {
        var m: [String: Any] = [:]
        for k in keys { if let v = liveValue(k) { m[k] = v } }
        store(st.id, m)
        inUseId = st.id
    }

    static func reset(_ st: MCPcStyle) {
        d.removeObject(forKey: "mc_pcstyle_\(st.id)")
        d.removeObject(forKey: "mc_pcstyle_icon_\(st.id)")
        d.removeObject(forKey: "mc_pcstyle_color_\(st.id)")
        if inUseId == st.id { use(st) }
    }

    // MARK: name, icon, colour

    static func name(_ st: MCPcStyle) -> String {
        let n = d.string(forKey: "mc_pcstyle_name_\(st.id)")?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? st.defName : n
    }

    static func rename(_ st: MCPcStyle, _ to: String) {
        let t = String(to.trimmingCharacters(in: .whitespaces).prefix(24))
        if t.isEmpty || t == st.defName { d.removeObject(forKey: "mc_pcstyle_name_\(st.id)") } else { d.set(t, forKey: "mc_pcstyle_name_\(st.id)") }
    }

    /// The icons a style can show (Change icon): its id, the symbol, the name.
    static let icons: [(String, String, String)] = [
        ("leaf", "leaf", "Leaf"), ("half", "circle.lefthalf.filled", "Half circle"), ("star", "sparkle", "Sparkle"),
        ("bolt", "bolt", "Bolt"), ("wave", "wave.3.right", "Wave"), ("flame", "flame", "Flame"), ("star5", "star", "Star"),
        ("heart", "heart", "Heart"), ("pad", "gamecontroller", "Gamepad"), ("monitor", "display", "Monitor"),
        ("moon", "moon", "Moon"), ("rocket", "paperplane", "Paper plane"),
    ]

    static func symbol(_ icon: String) -> String { icons.first { $0.0 == icon }?.1 ?? "circle" }

    static func icon(_ st: MCPcStyle) -> String {
        if let k = d.string(forKey: "mc_pcstyle_icon_\(st.id)"), icons.contains(where: { $0.0 == k }) { return k }
        return st.icon
    }

    static func setIcon(_ st: MCPcStyle, _ k: String) {
        if k == st.icon { d.removeObject(forKey: "mc_pcstyle_icon_\(st.id)") } else { d.set(k, forKey: "mc_pcstyle_icon_\(st.id)") }
    }

    /// The colours a style's icon can have (Colour); cyan is the theme's own (nil).
    static let colors: [(String, UInt32?)] = [("cyan", nil), ("green", 0x2DBE5A), ("purple", purple), ("orange", orange),
                                              ("red", 0xE9605A), ("pink", 0xEC5FA8), ("blue", 0x5C8DF6), ("yellow", 0xF2C94C)]

    /// The colour's name the style has picked, if it picked one.
    static func colorName(_ st: MCPcStyle) -> String? {
        d.string(forKey: "mc_pcstyle_color_\(st.id)").flatMap { n in colors.contains { $0.0 == n } ? n : nil }
    }

    static func color(_ st: MCPcStyle, _ p: MCPalette) -> Color {
        let c = colorName(st).flatMap { n in colors.first { $0.0 == n } }.map { $0.1 } ?? st.color
        return c.map { Color(hex: $0) } ?? p.ring
    }

    static func setColor(_ st: MCPcStyle, _ n: String) { d.set(n, forKey: "mc_pcstyle_color_\(st.id)") }

    // MARK: words

    static func mbps(_ kbps: Int) -> String { kbps % 1000 == 0 ? "\(kbps / 1000) Mbps" : String(format: "%.1f Mbps", Double(kbps) / 1000) }

    static func codecLabel(_ c: Int) -> String { ["Auto", "H.264", "HEVC", "AV1"][safe: c] ?? "Auto" }

    static func resLabel(_ r: String) -> String {
        if r == "native" { return "Native" }
        let steps = [("720p", "1280x720"), ("1080p", "1920x1080"), ("1440p", "2560x1440"), ("4K", "3840x2160")]
        return steps.first { $0.1 == r }?.0 ?? r.replacingOccurrences(of: "x", with: " × ")
    }

    /// The two lines on a style's card.
    static func lines(_ st: MCPcStyle) -> [String] {
        let m = values(st.id)
        let kbps = (m["kbps"] as? NSNumber)?.intValue ?? 0
        var l2 = [kbps == 0 ? "Auto bitrate" : mbps(kbps), codecLabel((m["codec"] as? NSNumber)?.intValue ?? 0)]
        if (m["hdr"] as? NSNumber)?.boolValue == true { l2.append("HDR") }
        if (m["ull"] as? NSNumber)?.boolValue == true { l2.append("lowest delay") }
        let f = m["fps"] as? String ?? "native"
        return ["\(resLabel(m["res"] as? String ?? "native")) · \(f == "native" ? "Native \(MCSettings.nativeHz)" : f) fps", l2.joined(separator: " · ")]
    }
}

/// A PS5 or Xbox play style: a ready-made set of its settings.
struct MCConsoleStyle {
    let id: String, name: String, l1: String, l2: String, note: String, icon: String
    let color: UInt32?
    let keys: [String: Any]

    /// "ps" or "xb".
    static func list(_ k: String) -> [MCConsoleStyle] {
        if k == "ps" {
            // the PS5 streams up to 1080p, 30 or 60 fps, and its own bitrate steps
            return [
                MCConsoleStyle(id: "battery", name: "Battery", l1: "720p · 60 fps", l2: "15 Mbps · H.264", note: "Longest play time", icon: "leaf", color: 0x2DBE5A,
                               keys: ["ps5_resolution": 720, "ps5_fps": 60, "ps5_bitrate": 15, "ps5_h265": false]),
                MCConsoleStyle(id: "balanced", name: "Balanced", l1: "1080p · 60 fps", l2: "Auto bitrate · HEVC", note: "Good everywhere at home", icon: "half", color: nil,
                               keys: ["ps5_resolution": 1080, "ps5_fps": 60, "ps5_bitrate": 0, "ps5_h265": true]),
                MCConsoleStyle(id: "sharpest", name: "Sharpest", l1: "1080p · 60 fps", l2: "50 Mbps · HEVC", note: "Best picture, good Wi-Fi", icon: "star", color: MCPcStyles.purple,
                               keys: ["ps5_resolution": 1080, "ps5_fps": 60, "ps5_bitrate": 50, "ps5_h265": true]),
                MCConsoleStyle(id: "fastest", name: "Fastest", l1: "1080p · 60 fps", l2: "30 Mbps · HEVC", note: "Lighter to send, steadier on a busy Wi-Fi", icon: "bolt", color: MCPcStyles.orange,
                               keys: ["ps5_resolution": 1080, "ps5_fps": 60, "ps5_bitrate": 30, "ps5_h265": true]),
            ]
        }
        // the Xbox sets its own quality from the picture and a bitrate cap
        return [
            MCConsoleStyle(id: "battery", name: "Battery", l1: "720p", l2: "Up to 10 Mbps", note: "Longest play time", icon: "leaf", color: 0x2DBE5A,
                           keys: ["xbox_resolution": 720, "xbox_bitrate": 10]),
            MCConsoleStyle(id: "balanced", name: "Balanced", l1: "Auto picture", l2: "Auto bitrate", note: "The Xbox decides", icon: "half", color: nil,
                           keys: ["xbox_resolution": 0, "xbox_bitrate": 0]),
            MCConsoleStyle(id: "sharpest", name: "Sharpest", l1: "1080p high", l2: "Auto bitrate", note: "Best picture, good Wi-Fi", icon: "star", color: MCPcStyles.purple,
                           keys: ["xbox_resolution": 1081, "xbox_bitrate": 0]),
        ]
    }

    /// What a key holds now, with the settings' defaults.
    static func read(_ key: String) -> Any {
        let d = UserDefaults.standard
        switch key {
        case "ps5_resolution": return MCPs5Store.height
        case "ps5_fps": return MCPs5Store.fps
        case "ps5_bitrate": return MCPs5Store.bitrate
        case "ps5_h265": return MCPs5Store.h265
        default: return d.object(forKey: key) ?? 0
        }
    }

    func matches() -> Bool {
        keys.allSatisfy { k, v in
            let now = MCConsoleStyle.read(k)
            if let b = v as? Bool, k.hasSuffix("h265") { return (now as? NSNumber)?.boolValue == b }
            return (now as? NSNumber)?.intValue == (v as? NSNumber)?.intValue
        }
    }

    func use(_ k: String) {
        keys.forEach { UserDefaults.standard.set($1, forKey: $0) }
        UserDefaults.standard.set(id, forKey: "mc_style_\(k)")
    }

    /// The style in use, or nil when the settings differ from every one.
    static func detect(_ k: String) -> MCConsoleStyle? { list(k).first { $0.matches() } }

    /// The style the settings started from: the last one picked, else the closest.
    static func nearest(_ k: String) -> MCConsoleStyle {
        let l = list(k)
        if let s = l.first(where: { $0.id == UserDefaults.standard.string(forKey: "mc_style_\(k)") }) { return s }
        return l.max { a, b in a.score() < b.score() } ?? l[0]
    }

    private func score() -> Int {
        keys.filter { k, v in (MCConsoleStyle.read(k) as? NSNumber)?.intValue == (v as? NSNumber)?.intValue }.count
    }

    static func nowLabel(_ k: String) -> String { detect(k)?.name ?? "\(nearest(k).name) (changed)" }
}
