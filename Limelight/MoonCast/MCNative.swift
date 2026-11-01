//
//  MCNative.swift
//  MoonCast: Resolution → Native, exact on Polaris (PreferenceConfiguration.nativeResolution and Game's fitScreen on
//  Android). Polaris, a Sunshine fork, makes its display at the size the client asks and keeps a disconnected session
//  resumable, so Native there is exactly the window the game plays in, and an iPad window that changes size mid-game
//  (Stage Manager, Split View, Slide Over) reconnects at the new size while the game keeps running. Any other host
//  (Sunshine, GFE) gets this screen's size on its side, as before, and a resized window only re-fits the picture.
//  An iPhone plays on its side, full screen, so there only the start size matters.
//

import UIKit

@objc(MCNativeRes)
final class MCNativeRes: NSObject {
    /// How long a window's size must hold still before the stream follows it (a resize sends a few changes).
    static let settleSeconds = 0.7
    /// Two sizes within this many pixels on both sides are the same screen (even rounding, a stray pixel).
    static let slack = 8

    /// The PC streamed last (or now) is Polaris: Settings words Native for it.
    static var exactHost: Bool {
        get { UserDefaults.standard.bool(forKey: "mc_native_exact_host") }
        set { UserDefaults.standard.set(newValue, forKey: "mc_native_exact_host") }
    }

    /// The window games play in, in pixels, as it is now (an upright iPad: upright).
    static func windowPixels() -> (Int, Int)? {
        guard let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) else { return nil }
        let k = w.screen.nativeScale
        let s = w.bounds.size
        guard s.width > 0, s.height > 0 else { return nil }
        return (Int((s.width * k).rounded()), Int((s.height * k).rounded()))
    }

    /// Native for a stream to a [polaris] host: Polaris on an iPad, the game's window exactly (only made even);
    /// otherwise this screen on its side (an iPhone always plays on its side, full screen).
    static func size(polaris: Bool) -> (Int, Int) {
        let screen = MCSettings.native
        guard UIDevice.current.userInterfaceIdiom == .pad, let w = windowPixels() else {
            return polaris ? (screen.0 & ~1, screen.1 & ~1) : screen
        }
        return polaris ? (w.0 & ~1, w.1 & ~1) : screen
    }

    static func sameScreen(_ a: (Int, Int), _ b: (Int, Int)) -> Bool {
        abs(a.0 - b.0) <= slack && abs(a.1 - b.1) <= slack
    }

    // MARK: the stream running now

    /// This stream is Polaris with Native on: it is the window's own size, and follows it.
    private(set) static var exactStream = false
    private static var streamSize = (0, 0)

    /// A PC stream is starting with [cfg] to [host]: Native's size goes in (Polaris: the window's exact size).
    static func prepare(_ cfg: StreamConfiguration, host: TemporaryHost?) {
        let polaris = host?.isPolaris ?? false
        exactHost = polaris
        exactStream = polaris && MCSettings.nativeOn
        if MCSettings.nativeOn {
            let s = size(polaris: polaris)
            cfg.width = Int32(s.0)
            cfg.height = Int32(s.1)
        }
        // Native frame rate: this screen's fastest
        if MCSettings.nativeFps { cfg.frameRate = Int32(MCSettings.nativeHz) }
        streamSize = (Int(cfg.width), Int(cfg.height))
        NSLog("MoonCast: stream \(cfg.width)x\(cfg.height), Native \(MCSettings.nativeOn), Polaris \(polaris)")
    }

    /// Native on a Polaris stream and the picture is the area's own shape: it takes the whole area whatever Picture
    /// shape says, so the even rounding leaves no hairline bars.
    static func fillsArea(_ area: CGSize, aspect: CGFloat) -> Bool {
        guard exactStream, area.height > 0, aspect > 0 else { return false }
        return abs(area.width / area.height - aspect) / aspect < 0.01
    }

    // MARK: a window resized mid-game

    private static var pending: DispatchWorkItem?
    private static var settling: (Int, Int)?
    private static var refits: [Date] = []

    /// The stream screen's size changed (StreamFrameViewController). Polaris with Native on: once the window's size
    /// holds still for [settleSeconds], and it is more than a few pixels off the stream's, disconnect (the game keeps
    /// running; Polaris pauses it) and start again at the new size. At most three such reconnects in 30 s.
    @objc static func streamResized(_ actions: MCQuickActions) {
        guard exactStream, UIDevice.current.userInterfaceIdiom == .pad else { return }
        settling = windowPixels()
        pending?.cancel()
        let w = DispatchWorkItem { [weak actions] in if let a = actions { check(a) } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds, execute: w)
    }

    private static func check(_ a: MCQuickActions) {
        guard exactStream, let now = windowPixels() else { return }
        if let s = settling, s != now {
            // still changing: wait until it holds still
            streamResized(a)
            return
        }
        let want = (now.0 & ~1, now.1 & ~1)
        guard !sameScreen(want, streamSize) else { return }
        refits = refits.filter { -$0.timeIntervalSinceNow < 30 }
        guard refits.count < 3 else {
            NSLog("MoonCast: size keeps changing: keeping this stream's size")
            return
        }
        guard let g = MCStore.shared.playing, g.host != nil, !MCQuickMenu.isOpen else { return }
        refits.append(Date())
        NSLog("MoonCast: matching this window: \(streamSize) -> \(want)")
        exactStream = false
        MCToast.show("Matching this screen…", seconds: 2)
        a.mcDisconnect()
        // a moment for Polaris to let this session go; it resumes the same game at the new size
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MCStore.shared.play(g, here: true) }
    }
}
