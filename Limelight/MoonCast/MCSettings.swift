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

    /// This screen in pixels, landscape.
    static var native: (Int, Int) {
        let b = UIScreen.main.nativeBounds.size
        return (Int(max(b.width, b.height)), Int(min(b.width, b.height)))
    }
}
