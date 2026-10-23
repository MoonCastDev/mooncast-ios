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
    private let corner = UILabel()
    private var timer: Timer?
    private var connected = false
    private var closed = false
    private var tries = 0
    private var menuOpen = false
    private var comboFired = false
    private var statsOn = UserDefaults.standard.bool(forKey: "xbox_stats")
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
        view.backgroundColor = .black
        video.videoContentMode = .scaleAspectFit
        video.frame = view.bounds
        video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(video)
        // Settings → Picture → Super resolution
        if MCFsr.enabled {
            let v = MCFsrView(frame: view.bounds, sharpness: MCFsr.sharpness)
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
        corner.textColor = UIColor(white: 0.93, alpha: 1)
        corner.font = .systemFont(ofSize: 13, weight: .semibold)
        corner.backgroundColor = UIColor(white: 0, alpha: 0.6)
        corner.isHidden = true
        [status, spinner, corner].forEach { view.addSubview($0) }
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
        setStatus(tries == 1 ? "Waking \(console.name)…" : "\(console.name) is still waking up…")
        Task {
            try? await MCXbox.wake(console.id)
            do {
                let auth = try await MCXbox.streamAuth()
                await MainActor.run { self.startRtc(auth) }
            } catch {
                await MainActor.run { self.xboxFailed("Couldn't sign in for the stream. \(error.localizedDescription)") }
            }
        }
    }

    private func startRtc(_ auth: MCXbox.StreamAuth) {
        guard !closed else { return }
        rtc?.stop()
        let r = MCXboxRtc(consoleId: console.id, auth: auth, resolution: MCXbox.resolution == 0 ? 1080 : MCXbox.resolution,
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
    }

    func xboxFailed(_ reason: String) {
        DispatchQueue.main.async { [self] in
            guard !closed else { return }
            // a console that isn't ready yet: wake it and try again, about a minute in all
            if !connected && tries < 6 {
                rtc?.stop(); rtc = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.begin() }
                return
            }
            setStatus(nil)
            let a = UIAlertController(title: console.name, message: reason, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in self.leave() })
            present(a, animated: true)
        }
    }

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
        rtc?.stats { [weak self] s in
            guard let self = self else { return }
            self.last = s
            guard self.statsOn, self.connected else { self.corner.isHidden = true; return }
            self.corner.text = String(format: "  %.0f fps   %@   %.1f Mbps   %.1f%% lost  ", max(0, s.fps),
                                      s.rttMs >= 0 ? String(format: "%.0f ms", s.rttMs) : "…", max(0, s.mbps), max(0, s.lossPct))
            self.corner.sizeToFit()
            self.corner.frame.origin = CGPoint(x: 12, y: 12)
            self.corner.isHidden = false
        }
    }

    // MARK: controllers → Xbox pads

    @objc private func hookPads() {
        for c in GCController.controllers() { c.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in self?.padsChanged() } }
    }

    private func padsChanged() {
        guard let r = rtc else { return }
        let pads = GCController.controllers().compactMap { $0.extendedGamepad }
        if menuOpen { r.pads = []; return }
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
            f.lx = g.leftThumbstick.xAxis.value; f.ly = g.leftThumbstick.yAxis.value
            f.rx = g.rightThumbstick.xAxis.value; f.ry = g.rightThumbstick.yAxis.value
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
    func mcToggleStats() { statsOn.toggle(); UserDefaults.standard.set(statsOn, forKey: "xbox_stats"); tick() }
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
        r.pads = [f]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { r.pads = [MCXboxRtc.PadFrame()] }
    }

    /// Turn off the Xbox (ends the game).
    func mcRestMode() {
        Task { try? await MCXbox.turnOff(console.id) }
        leave()
    }
}
