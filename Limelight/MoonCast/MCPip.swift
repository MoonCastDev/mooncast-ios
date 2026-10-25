//
//  MCPip.swift
//  MoonCast: Settings → iPad → Picture in picture. Leaving MoonCast during a PC or PS5 game keeps the stream in a
//  small floating window (AVPictureInPictureController over the player's AVSampleBufferDisplayLayer); closing the
//  window ends the stream and the game keeps running. Not for the Xbox (its WebRTC view draws with Metal) or while
//  Super resolution draws the picture.
//

import AVKit
import UIKit

@objc(MCPip)
final class MCPip: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    @objc static var enabled: Bool { UserDefaults.standard.bool(forKey: "mc_pip") && AVPictureInPictureController.isPictureInPictureSupported() }

    private var controller: AVPictureInPictureController?
    /// Called when the floating window was closed while MoonCast is in the background: end the stream.
    @objc var onClosedInBackground: (() -> Void)?

    @objc init(layer: AVSampleBufferDisplayLayer) {
        super.init()
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.requiresLinearPlayback = true
        c.delegate = self
        controller = c
    }

    /// The stream is in (or going into) the floating window: don't end it for going to the background.
    @objc var keepsStream: Bool { controller.map { $0.isPictureInPictureActive || $0.isPictureInPicturePossible } ?? false }
    @objc var active: Bool { controller?.isPictureInPictureActive ?? false }

    @objc func stop() {
        controller?.stopPictureInPicture()
        controller = nil
    }

    // A live stream: no timeline, never paused, nothing to skip.
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) { completion() }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        if UIApplication.shared.applicationState == .background { onClosedInBackground?() }
    }
}
