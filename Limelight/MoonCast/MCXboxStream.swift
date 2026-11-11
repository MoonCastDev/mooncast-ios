//
//  MCXboxStream.swift
//  MoonCast: the Xbox stream screen (XboxStreamActivity): signs in for the stream, wakes the console, plays it over
//  WebRTC and turns this iPad's controllers into Xbox pads. Retries a console that's still waking for about a minute.
//

import UIKit
import GameController
import WebRTC

final class MCXboxStreamController: UIViewController, MCXboxRtc.Listener, MCQuickActions {
    let console: MCXbox.Console
    private var rtc: MCXboxRtc?
    private let video = RTCMTLVideoView()
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var corner: MCStatsPill?
    /// Until when the Quick menu's Xbox button press is being sent
    private var buttonPulse = Date.distantPast
    private var timer: Timer?
    private var connected = false
    private var closed = false
    private var tries = 0
    /// The first picture arrived (stats show frames); until then a start can still be retried or timed out
    private var picture = false
    private var firstFailAt: Date?
    private var retrying = false
    private var ending = false
    private var pictureDeadline = Date.distantFuture
    private var menuOpen = false
    private var comboFired = false
    private var statsOn: Bool { MCStatsLevel.current != "off" }
    private var last = MCXboxRtc.Stats()
    private var fsr: MCFsrView?
    private var fsrRenderer: MCFsrRtcRenderer?

    init(console: MCXbox.Console) {
        self.console = console
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(wentToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        view.backgroundColor = .black
        // the view is sized for Settings → Picture → Picture shape in viewDidLayoutSubviews
        video.videoContentMode = .scaleToFill
        view.clipsToBounds = true
        video.frame = MCPictureShape.frame(in: view.bounds, aspect: 16.0 / 9.0, kind: "xbox")
        view.addSubview(video)
        // Settings → Picture → Super resolution
        if MCFsr.enabled("xbox") {
            let v = MCFsrView(frame: view.bounds, sharpness: MCFsr.sharpness("xbox"))
            v.shapeKind = "xbox"
            if v.ready {
                v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                v.isHidden = true
                view.addSubview(v)
                fsr = v
                fsrRenderer = MCFsrRtcRenderer(fsr: v, plain: video)
            }
        }
        status.textColor = .white
        status.font = .systemFont(ofSize: 22, weight: .bold)
        status.textAlignment = .center
        status.numberOfLines = 0
        spinner.color = .white
        spinner.startAnimating()
        [status, spinner].forEach { view.addSubview($0) }
        corner = MCStatsPill.attach(to: view)
        let swipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped(_:)))
        swipe.edges = .left
        view.addGestureRecognizer(swipe)
        UIApplication.shared.isIdleTimerDisabled = true
        hookPads()
        NotificationCenter.default.addObserver(self, selector: #selector(hookPads), name: .GCControllerDidConnect, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        begin()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        video.frame = MCPictureShape.frame(in: view.bounds, aspect: 16.0 / 9.0, kind: "xbox")
        status.frame = CGRect(x: 40, y: view.bounds.midY + 10, width: view.bounds.width - 80, height: 80)
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY - 30)
    }

    private func setStatus(_ s: String?) {
        status.text = s
        status.isHidden = s == nil
        spinner.isHidden = s == nil
    }

    // MARK: session

    private func begin() {
        tries += 1
        retrying = false
        connected = false
        pictureDeadline = Date().addingTimeInterval(60)
        setStatus(tries == 1 ? "Waking \(console.name)…" : "\(console.name) is still waking up…")
        Task {
            try? await MCXbox.wake(console.id)
            do {
                let auth = try await MCXbox.streamAuth()
                await MainActor.run { self.startRtc(auth) }
            } catch {
                await MainActor.run {
                    if !MCXbox.signedIn { self.endSession("Sign in to Xbox first: Settings → Xbox.") }
                    else { self.xboxFailed(Self.describe(error)) }
                }
            }
        }
    }

    private static func describe(_ e: Error) -> String {
        (e as? MCXbox.HttpError).map { "HTTP \($0.code): \($0.body.prefix(160))" } ?? e.localizedDescription
    }

    /// Settings → Xbox → Picture. No bitrate is sent; the Xbox picks quality from the device type this implies:
    /// 720 = Android, 1080 = Windows, 1081 = Tizen. Auto: 1080, or 720 on a weak link; a 1440p-or-larger panel asks for
    /// the high-quality profile, like Native.
    private var resolution: Int {
        if MCXbox.resolution != 0 { return MCXbox.resolution }
        let b = UIScreen.main.nativeBounds
        return MCNetworkId.weakLink ? 720 : min(b.width, b.height) >= 1440 ? 1081 : 1080
    }

    private func startRtc(_ auth: MCXbox.StreamAuth) {
        guard !closed else { return }
        rtc?.stop()
        let r = MCXboxRtc(consoleId: console.id, auth: auth, resolution: resolution,
                          coop: MCXbox.coop, maxMbps: MCXbox.maxMbps, renderer: fsrRenderer ?? video)
        r.listener = self
        rtc = r
        r.start()
    }

    func xboxStatus(_ text: String) { DispatchQueue.main.async { if !self.connected { self.setStatus(text) } } }

    func xboxConnected() {
        connected = true
        setStatus(nil)
        MCRecents.touch("xb:\(console.id)")
        MCQuickMenu.runTestSteps(in: self)
    }

    /// Microsoft answers "Xccs : ErrorCallingWNS : Send command failed : State WaitingForServerToRegister" (and similar)
    /// while the console is in standby and hasn't registered with Xbox network's streaming service yet.
    private func notReady(_ reason: String) -> Bool {
        let r = reason.lowercased()
        if ["waitingforservertoregister", "errorcallingwns", "xccs", "connectedstandby", "not registered", "notready", "not ready"].contains(where: { r.contains($0) }) { return true }
        // "offline" / "unavailable" also appear in this phone's own network errors ("The Internet connection appears to be offline."):
        // those fail fast with their text instead of 60 s of "Waking your Xbox"
        if ["internet connection", "network connection", "timed out", "could not connect", "cannot find host"].contains(where: { r.contains($0) }) { return false }
        return ["offline", "unavailable"].contains { r.contains($0) }
    }

    /// The session failed: before the first picture, retry a console that isn't ready (wake every 5 s, about 60 s).
    func xboxFailed(_ reason: String) {
        DispatchQueue.main.async { [self] in
            guard !closed, !ending else { return }
            NSLog("MoonCast: xbox failed: \(reason)")
            let first = firstFailAt ?? Date()
            firstFailAt = first
            if !picture && notReady(reason) && Date().timeIntervalSince(first) < 60 {
                if retrying { return }
                retrying = true
                rtc?.stop(); rtc = nil
                setStatus("Waking your Xbox…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if !self.closed && !self.ending { self.begin() } }
                return
            }
            endSession(notReady(reason) ? "Your Xbox didn't answer. Turn it on, or check Settings > Devices & connections > Remote features on the Xbox."
                       : reason.contains("no picture") ? "Your Xbox connected but sent no picture. Turn the Xbox off and on, then try again."
                       : "The Xbox stream stopped. \(reason)")
        }
    }

    /// Stop the console session (so it isn't left running) and say why in plain words.
    private func endSession(_ msg: String) {
        guard !closed, !ending else { return }
        ending = true
        pictureDeadline = .distantFuture
        rtc?.stop(); rtc = nil
        setStatus(nil)
        let a = UIAlertController(title: console.name, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in self.leave() })
        present(a, animated: true)
    }

    /// Leaving MoonCast ends the Xbox stream (its WebRTC view can't go into picture in picture).
    @objc private func wentToBackground() { leave() }

    private func leave() {
        guard !closed else { return }
        closed = true
        timer?.invalidate()
        MCRumble.shared.stop()
        rtc?.stop()
        rtc = nil
        UIApplication.shared.isIdleTimerDisabled = false
        GCController.controllers().forEach { $0.extendedGamepad?.valueChangedHandler = nil }
        navigationController?.popToRootViewController(animated: true)
    }

    private func tick() {
        // a start that never reaches the picture (the console accepts the session but sends nothing): end it, say so
        if !picture && !retrying && !closed && Date() > pictureDeadline {
            endSession("Your Xbox didn't start the picture in time. Try again, or turn the Xbox off and on.")
        }
        rtc?.stats { [weak self] s in
            guard let self = self else { return }
            self.last = s
            if s.fps > 0 { self.picture = true; self.pictureDeadline = .distantFuture }
            guard self.statsOn, self.connected else { self.corner?.isHidden = true; return }
            self.corner?.level = MCStatsLevel.current
            var d: [AnyHashable: Any] = ["fps": s.fps, "rtt": s.rttMs, "mbps": s.mbps, "loss": s.lossPct, "codec": "H.264"]
            if s.width > 0 { d["size"] = "\(s.width)x\(s.height)" }
            self.corner?.show(stats: d)
            if let c = self.corner, !MCQuickMenu.isOpen { self.view.bringSubviewToFront(c) }
        }
    }

    // MARK: controllers → Xbox pads

    @objc private func hookPads() {
        for c in GCController.controllers() { c.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in self?.padsChanged() } }
    }

    private func padsChanged() {
        guard let r = rtc else { return }
        let pads = GCController.controllers().compactMap { $0.extendedGamepad }
        // with the Quick menu open the pad is the menu's; a press of the menu's Xbox button goes through
        if menuOpen { if Date() > buttonPulse { r.pads = [] }; return }
        if let g = pads.first, (g.buttonOptions?.isPressed ?? false) && g.buttonMenu.isPressed && g.leftShoulder.isPressed && g.rightShoulder.isPressed {
            if !comboFired { comboFired = true; DispatchQueue.main.async { self.openMenu() } }
            r.pads = []
            return
        }
        comboFired = false
        let swap = MCXbox.swapAB
        r.pads = pads.prefix(MCXbox.coop ? 2 : 1).enumerated().map { i, g in
            var f = MCXboxRtc.PadFrame(index: i)
            f.nexus = g.buttonHome?.isPressed ?? false
            f.menu = g.buttonMenu.isPressed
            f.view = g.buttonOptions?.isPressed ?? false
            f.a = swap ? g.buttonB.isPressed : g.buttonA.isPressed
            f.b = swap ? g.buttonA.isPressed : g.buttonB.isPressed
            f.x = g.buttonX.isPressed; f.y = g.buttonY.isPressed
            f.up = g.dpad.up.isPressed; f.down = g.dpad.down.isPressed; f.left = g.dpad.left.isPressed; f.right = g.dpad.right.isPressed
            f.lb = g.leftShoulder.isPressed; f.rb = g.rightShoulder.isPressed
            f.ls = g.leftThumbstickButton?.isPressed ?? false; f.rs = g.rightThumbstickButton?.isPressed ?? false
            (f.lx, f.ly) = MCXbox.dead(g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value)
            (f.rx, f.ry) = MCXbox.dead(g.rightThumbstick.xAxis.value, g.rightThumbstick.yAxis.value)
            f.lt = g.leftTrigger.value; f.rt = g.rightTrigger.value
            return f
        }
    }

    // MARK: Quick menu

    @objc private func edgeSwiped(_ r: UIScreenEdgePanGestureRecognizer) { if r.state == .began { openMenu() } }

    private func openMenu() {
        guard connected, !menuOpen else { return }
        MCQuickMenu.show(in: self)
    }

    func mcStats() -> [AnyHashable: Any] {
        var d: [AnyHashable: Any] = ["mbps": max(0, last.mbps), "codec": "H.264"]
        if last.fps >= 0 { d["fps"] = last.fps }
        if last.rttMs >= 0 { d["rtt"] = Int(last.rttMs) }
        if last.lossPct >= 0 { d["loss"] = last.lossPct }
        return d
    }
    func mcTitle() -> String { console.name }
    func mcHostAddress() -> String { console.id }
    func mcStatsOn() -> Bool { statsOn }
    func mcToggleStats() { MCStatsLevel.cycle(); tick() }
    func mcTouchMode() -> Int32 { 0 }
    func mcSetTouchMode(_ mode: Int32) {}
    func mcToggleKeyboard() {}
    func mcTaskManager() {}
    func mcMenuOpen(_ open: Bool) { menuOpen = open; if open { rtc?.pads = [] } else { hookPads() } }
    func mcKind() -> String { "xbox" }
    func mcDisconnect() { leave() }

    /// The Xbox button: opens the guide.
    func mcPsButton() {
        guard let r = rtc else { return }
        var f = MCXboxRtc.PadFrame(); f.nexus = true
        buttonPulse = Date().addingTimeInterval(0.3)
        r.pads = [f]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { r.pads = [MCXboxRtc.PadFrame()] }
    }

    /// Turn off the Xbox (ends the game).
    func mcRestMode() {
        Task { try? await MCXbox.turnOff(console.id) }
        leave()
    }
}
