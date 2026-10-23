//
//  MCSettings.swift
//  MoonCast: the stream settings, kept in Moonlight's own store (DataManager) so its stream screen uses them.
//

import UIKit
import AVFoundation

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

    // MARK: Home and Away profiles (Profile.kt): Settings → Picture → Streaming profile

    /// "home" or "away".
    static var profile: String { UserDefaults.standard.string(forKey: "mc_profile") == "away" ? "away" : "home" }

    /// MoonCast's own settings that belong to a profile, next to Moonlight's picture and sound values.
    private static let profileKeys = ["mc_full_range", "mc_picture_shape", "mc_ultra_low_latency", "mc_super_resolution",
                                      "mc_fsr_sharpness", "xbox_resolution", "xbox_bitrate"]

    /// Saves the picture and sound settings for the profile being left and brings back the other one's. The first
    /// time Away starts from 720p 60 fps at its Auto bitrate, a good start for a hotel or a phone's hotspot.
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

/// Settings → Picture → Picture shape (the handheld's ShapeBox): Fit keeps the whole picture with bars, Fill crops
/// it to fill the screen, Stretch fills the screen and changes the picture's shape. Used by the PC, PS5 and Xbox players.
@objc(MCPictureShape)
final class MCPictureShape: NSObject {
    /// "fit", "fill" or "stretch".
    @objc static var current: String { UserDefaults.standard.string(forKey: "mc_picture_shape") ?? "fit" }

    /// The picture's size in an area of this size, for a stream of this aspect ratio (width / height).
    @objc static func size(in area: CGSize, aspect: CGFloat) -> CGSize {
        guard aspect > 0, area.width > 0, area.height > 0 else { return area }
        let wide = area.width > area.height * aspect
        switch current {
        case "stretch": return area
        case "fill": return wide ? CGSize(width: area.width, height: area.width / aspect) : CGSize(width: area.height * aspect, height: area.height)
        default: return wide ? CGSize(width: area.height * aspect, height: area.height) : CGSize(width: area.width, height: area.width / aspect)
        }
    }

    @objc static var videoGravity: AVLayerVideoGravity {
        switch current {
        case "stretch": return .resize
        case "fill": return .resizeAspectFill
        default: return .resizeAspect
        }
    }
}
