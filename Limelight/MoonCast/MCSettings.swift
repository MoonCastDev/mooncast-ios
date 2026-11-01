//
//  MCSettings.swift
//  MoonCast: the stream settings, kept in Moonlight's own store (DataManager) so its stream screen uses them.
//

import UIKit

final class MCSettings {
    private let dm = DataManager()

    struct Values {
        var bitrate: Int, framerate: Int, height: Int, width: Int, audio: Int, onscreen: Int
        var optimize: Bool, multi: Bool, swapAB: Bool, audioOnPC: Bool, codec: UInt32, pacing: Bool, hdr: Bool
        var btMouse: Bool, absoluteTouch: Bool, stats: Bool
    }

    func load() -> Values {
        let s = dm.getSettings()!
        return Values(bitrate: s.bitrate.intValue, framerate: s.framerate.intValue, height: s.height.intValue, width: s.width.intValue,
                      audio: s.audioConfig.intValue, onscreen: s.onscreenControls.intValue, optimize: s.optimizeGames,
                      multi: s.multiController, swapAB: s.swapABXYButtons, audioOnPC: s.playAudioOnPC,
                      codec: s.preferredCodec, pacing: s.useFramePacing, hdr: s.enableHdr,
                      btMouse: s.btMouseSupport, absoluteTouch: s.absoluteTouchMode, stats: s.statsOverlay)
    }

    func save(_ change: (inout Values) -> Void) {
        var v = load()
        change(&v)
        dm.saveSettings(withBitrate: v.bitrate, framerate: v.framerate, height: v.height, width: v.width,
                        audioConfig: v.audio, onscreenControls: v.onscreen, optimizeGames: v.optimize,
                        multiController: v.multi, swapABXYButtons: v.swapAB, audioOnPC: v.audioOnPC,
                        preferredCodec: v.codec, useFramePacing: v.pacing, enableHdr: v.hdr,
                        btMouseSupport: v.btMouse, absoluteTouchMode: v.absoluteTouch, statsOverlay: v.stats)
    }

    // MARK: PC bitrate (QuickBitrate.kt)

    /// The PC (Sunshine) bitrate steps in Mbps, shared by Settings and the Quick menu: fine steps up to 150, then
    /// bigger ones up to 1 Gbps. Anything else saved is a Custom bitrate. PS5 and Xbox keep their own limits.
    static let pcSteps = [10, 20, 30, 50, 80, 100, 150, 200, 300, 400, 500, 600, 800, 1000]
    /// The highest PC bitrate, in Mbps (Custom entry).
    static let pcMaxMbps = 1000
    /// Above this many Mbps, Settings shows [highHint].
    static let highMbps = 300
    static let highHint = "Needs a cable or Wi-Fi 6/7 close to the router; the PC's encoder and this device's decoder must keep up"

    /// The hint for a PC bitrate in kbps, or nil when it isn't high.
    static func highHint(kbps: Int) -> String? { kbps > highMbps * 1000 ? highHint : nil }

    // MARK: Home and Away profiles (Profile.kt): Settings → Picture → Streaming profile

    /// The profiles: Home, Away and three custom ones you can rename.
    static let profiles = ["home", "away", "c1", "c2", "c3"]

    /// The active profile.
    static var profile: String {
        let p = UserDefaults.standard.string(forKey: "mc_profile") ?? "home"
        return profiles.contains(p) ? p : "home"
    }

    /// A profile's name: Home, Away, or a custom one's own name ("Custom 1" until renamed).
    static func profileName(_ p: String) -> String {
        switch p {
        case "home": return "Home"
        case "away": return "Away"
        default:
            let n = UserDefaults.standard.string(forKey: "mc_profile_name_\(p)")?.trimmingCharacters(in: .whitespaces) ?? ""
            return n.isEmpty ? "Custom \(p.dropFirst())" : n
        }
    }

    static func renameProfile(_ p: String, _ name: String) {
        UserDefaults.standard.set(String(name.trimmingCharacters(in: .whitespaces).prefix(24)), forKey: "mc_profile_name_\(p)")
    }

    /// MoonCast's own settings that belong to a profile, next to Moonlight's picture and sound values.
    private static let profileKeys = ["mc_full_range", "mc_picture_shape", "mc_ultra_low_latency", "mc_super_resolution",
                                      "mc_fsr_sharpness", "mc_yuv444", "xbox_resolution", "xbox_bitrate",
                                      "ps5_resolution", "ps5_fps", "ps5_bitrate", "ps5_h265", "ps5_hdr",
                                      "ps5_super_resolution", "ps5_fsr_sharpness", "ps5_picture_shape",
                                      "xbox_super_resolution", "xbox_fsr_sharpness", "xbox_picture_shape"]

    /// Saves the picture and sound settings for the profile being left and brings back the other one's. The first
    /// time Away starts from 720p 60 fps at its Auto bitrate, a good start for a hotel or a phone's hotspot; a custom
    /// profile starts as a copy of the one you were on.
    func switchProfile(to want: String) {
        let d = UserDefaults.standard
        let was = MCSettings.profile
        guard want != was else { return }
        let v = load()
        var saved: [String: Any] = ["width": v.width, "height": v.height, "fps": v.framerate, "bitrate": v.bitrate, "codec": Int(v.codec),
                                    "hdr": v.hdr, "pacing": v.pacing, "audio": v.audio, "audioOnPC": v.audioOnPC]
        for k in MCSettings.profileKeys { saved[k] = d.object(forKey: k) ?? "" }
        d.set(saved, forKey: "mc_profile_\(was)")
        if let p = d.dictionary(forKey: "mc_profile_\(want)") {
            save {
                $0.width = p["width"] as? Int ?? $0.width; $0.height = p["height"] as? Int ?? $0.height
                $0.framerate = p["fps"] as? Int ?? $0.framerate; $0.bitrate = p["bitrate"] as? Int ?? $0.bitrate
                $0.codec = UInt32(p["codec"] as? Int ?? Int($0.codec)); $0.hdr = p["hdr"] as? Bool ?? $0.hdr
                $0.pacing = p["pacing"] as? Bool ?? $0.pacing; $0.audio = p["audio"] as? Int ?? $0.audio
                $0.audioOnPC = p["audioOnPC"] as? Bool ?? $0.audioOnPC
            }
            for k in MCSettings.profileKeys {
                if let o = p[k], !(o is String && (o as! String).isEmpty) { d.set(o, forKey: k) } else { d.removeObject(forKey: k) }
            }
        } else if want == "away" {
            save { $0.width = 1280; $0.height = 720; $0.framerate = 60; $0.bitrate = MCRoot.defaultBitrate(1280, 720, 60) }
        }
        d.set(want, forKey: "mc_profile")
    }

    /// This screen in pixels, landscape.
    static var native: (Int, Int) {
        let b = UIScreen.main.nativeBounds.size
        return (Int(max(b.width, b.height)), Int(min(b.width, b.height)))
    }
}

/// Settings → Picture → Picture shape (the handheld's ShapeBox): Fit keeps the whole picture with bars, Zoom halves
/// the bars and trims at most 1.5% from the sides (the rest as a slight stretch), Fill crops it to fill the screen, Stretch fills the
/// screen and changes the picture's shape. Used by the PC, PS5 and Xbox players.
@objc(MCPictureShape)
final class MCPictureShape: NSObject {
    /// "fit", "zoom", "fill" or "stretch".
    @objc static var current: String { UserDefaults.standard.string(forKey: "mc_picture_shape") ?? "fit" }

    /// The shape for "ps5" or "xbox": its own (Settings → PlayStation / Xbox), unless that's "Same as Picture".
    static func current(_ kind: String?) -> String {
        if let k = kind, let v = UserDefaults.standard.string(forKey: "\(k)_picture_shape"), v != "same" { return v }
        return current
    }

    /// The picture's size in an area of this size, for a stream of this aspect ratio (width / height).
    @objc static func size(in area: CGSize, aspect: CGFloat) -> CGSize { size(in: area, aspect: aspect, kind: nil) }

    static func size(in area: CGSize, aspect: CGFloat, kind: String?) -> CGSize {
        guard aspect > 0, area.width > 0, area.height > 0 else { return area }
        let wide = area.width > area.height * aspect
        let fit = wide ? CGSize(width: area.height * aspect, height: area.height) : CGSize(width: area.width, height: area.width / aspect)
        let fill = wide ? CGSize(width: area.width, height: area.width / aspect) : CGSize(width: area.height * aspect, height: area.height)
        switch current(kind) {
        case "stretch": return area
        case "fill": return fill
        case "zoom":
            // half the bars, but at most 1.5% cut from each side: consoles put their clock and HUD near the edge.
            // What's left of the halfway zoom is taken as a slight stretch (about 8% on an iPad with a 16:9 picture).
            let mid = CGSize(width: (fit.width + fill.width) / 2, height: (fit.height + fill.height) / 2)
            return wide ? CGSize(width: mid.width, height: min(mid.height, area.height / 0.97))
                        : CGSize(width: min(mid.width, area.width / 0.97), height: mid.height)
        default: return fit
        }
    }

    /// Where the picture goes in [bounds]: its size from [size(in:aspect:)], centred (the parts outside are cut off).
    static func frame(in bounds: CGRect, aspect: CGFloat, kind: String? = nil) -> CGRect {
        let s = size(in: bounds.size, aspect: aspect, kind: kind)
        return CGRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height)
    }
}
