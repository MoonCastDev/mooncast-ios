//
//  MCPs5.swift
//  MoonCast: PS5 consoles on the iPad (Ps5Store.kt) and the PS5 stream screen (Ps5StreamActivity.kt): wake, connect
//  with retries while the console comes up, DualSense input from any controller, the Quick menu.
//

import SwiftUI
import GameController

/// A registered PS5: its address and the two keys registration gave.
struct MCPs5Console: Codable, Equatable {
    var name: String
    var host: String
    var registKey: String
    var morning: String
}

enum MCPs5Store {
    private static let key = "mc_ps5_consoles"

    static func list() -> [MCPs5Console] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MCPs5Console].self, from: d)) ?? []
    }

    static func save(_ l: [MCPs5Console]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(l), forKey: key)
    }

    static func add(_ c: MCPs5Console) {
        save(list().filter { $0.host != c.host } + [c])
    }

    /// The PS5 answers on its Remote Play port (9295) within a second.
    static func reachable(_ host: String) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "9295", &hints, &res) == 0, let ai = res else { return false }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        _ = connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 1000) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    static func remove(_ host: String) {
        save(list().filter { $0.host != host })
    }

    /// Test runs only: MC_PS5_ADD="name|host|registKey|morning" adds a console without registering.
    static func testAdd() {
        #if DEBUG
        guard let v = ProcessInfo.processInfo.environment["MC_PS5_ADD"] else { return }
        let p = v.split(separator: "|").map(String.init)
        if p.count == 4 { add(MCPs5Console(name: p[0], host: p[1], registKey: p[2], morning: p[3])) }
        #endif
    }

    // the PS5 group in Settings
    static var height: Int { UserDefaults.standard.object(forKey: "ps5_resolution") as? Int ?? 1080 }
    static var fps: Int { UserDefaults.standard.object(forKey: "ps5_fps") as? Int ?? 60 }
    /// 0 = Auto (30 Mbps at 1080p, 15 at 720p, as on Android)
    static var bitrate: Int { UserDefaults.standard.object(forKey: "ps5_bitrate") as? Int ?? 0 }
    static var h265: Bool { UserDefaults.standard.object(forKey: "ps5_h265") as? Bool ?? true }
    static var onDisconnect: String { UserDefaults.standard.string(forKey: "ps5_on_disconnect") ?? "ask" }
    static var swapCrossCircle: Bool { UserDefaults.standard.bool(forKey: "ps5_swap_cross_circle") }
    static var loginPin: String { UserDefaults.standard.string(forKey: "ps5_login_pin") ?? "" }
    // Away from home (over PSN): lighter by default, as Android's Away profile
    static var awayHeight: Int { UserDefaults.standard.object(forKey: "ps5_away_resolution") as? Int ?? 720 }
    /// 0 = Auto (10 Mbps)
    static var awayBitrate: Int { UserDefaults.standard.object(forKey: "ps5_away_bitrate") as? Int ?? 0 }
}

/// The PS5 stream screen.
final class MCPs5StreamController: UIViewController, MCPs5SessionDelegate, MCQuickActions {
    let console: MCPs5Console
    private var session: MCPs5Session?
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let corner = UILabel()
    private var cornerTimer: Timer?
    private var connected = false
    private var closed = false
    private var tries = 0
    private var menuOpen = false
    private var statsOn = UserDefaults.standard.bool(forKey: "ps5_stats")
    private var comboFired = false
    private var remote: (String, String, Data)?
    private var fsr: MCFsrView?
    private var remoteDecided = false

    init(console: MCPs5Console) {
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
        setStatus("Waking \(console.name)…")
        UIApplication.shared.isIdleTimerDisabled = true
        hookPads()
        NotificationCenter.default.addObserver(self, selector: #selector(hookPads), name: .GCControllerDidConnect, object: nil)
        connect()
        cornerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateCorner() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        session?.videoLayer.frame = view.bounds
        status.frame = CGRect(x: 40, y: view.bounds.midY + 10, width: view.bounds.width - 80, height: 80)
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY - 30)
    }

    private func setStatus(_ s: String?) {
        status.text = s
        status.isHidden = s == nil
        spinner.isHidden = s == nil
    }

    // MARK: connecting

    /// Wakes the console, then connects; while it comes out of rest mode the first tries fail, so up to 8 tries
    /// 3 s apart, as on Android.
    private func connect() {
        MCPs5Session.wakeHost(console.host, registKey: console.registKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 1.5 : 3)) { [weak self] in self?.attempt() }
    }

    private func attempt() {
        guard !closed else { return }
        // at home the PS5 answers Remote Play's probe (even in rest mode); when it doesn't and PSN is signed in, play
        // over PlayStation Network
        if !remoteDecided {
            remoteDecided = true
            setStatus("Looking for \(console.name)…")
            let host = console.host, name = console.name
            Task.detached {
                let home = MCPs5Probe.probe(host).power != .notFound
                let r = home ? nil : await MCPsn.remoteFor(name)
                await MainActor.run {
                    self.remote = r
                    if !home && r == nil && !MCPsn.signedIn {
                        self.failed("\(name) isn't on this network. To play it away from home, sign in to PlayStation Network in Settings → PlayStation.")
                        return
                    }
                    self.attempt()
                }
            }
            return
        }
        tries += 1
        let away = remote != nil
        setStatus(away ? "Connecting to \(console.name) over PlayStation Network… (up to a minute)"
                       : tries == 1 ? "Connecting to \(console.name)…" : "Connecting to \(console.name)… (try \(tries))")
        session?.stop()
        let h = away ? MCPs5Store.awayHeight : MCPs5Store.height
        let rate = away ? (MCPs5Store.awayBitrate > 0 ? MCPs5Store.awayBitrate * 1000 : 10000)
                        : (MCPs5Store.bitrate > 0 ? MCPs5Store.bitrate * 1000 : (h >= 1080 ? 30000 : 15000))
        let s = MCPs5Session(host: console.host, registKey: console.registKey, morning: console.morning,
                             width: h >= 1080 ? 1920 : h >= 720 ? 1280 : 960, height: Int32(h), fps: Int32(MCPs5Store.fps), bitrate: Int32(rate), h265: MCPs5Store.h265)
        if let r = remote { s.psnToken = r.0; s.psnDuid = r.1; s.psnAccountId = r.2 }
        // Settings → Picture → Super resolution: 720p / 1080p up to the iPad's screen through FSR
        fsr?.removeFromSuperview(); fsr = nil
        if MCFsr.wanted(videoHeight: h) {
            let v = MCFsrView(frame: view.bounds, sharpness: MCFsr.sharpness)
            if v.ready {
                v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.insertSubview(v, at: 0)
                fsr = v
                s.fsrDecoder = MCFsrDecoder(view: v)
                s.videoLayer.isHidden = true
            }
        }
        s.delegate = self
        session = s
        s.videoLayer.frame = view.bounds
        view.layer.insertSublayer(s.videoLayer, at: 0)
        // over PSN start blocks while the hole is punched: keep the screen live
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = s.start()
            DispatchQueue.main.async {
                guard let self = self, !self.closed, let err = err, !err.isEmpty else { return }
                if away && self.tries < 2 {
                    self.attempt()
                } else {
                    self.failed(err)
                }
            }
        }
    }

    func ps5Connected() {
        connected = true
        setStatus(nil)
        MCRecents.touch("ps:\(console.host)")
    }

    func ps5Quit(_ reason: String) {
        guard !closed else { return }
        session?.videoLayer.removeFromSuperlayer()
        if !connected && tries < (remote == nil ? 8 : 2) && !reason.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.attempt() }
            return
        }
        if reason.isEmpty { leave(); return }
        failed(connected ? "The PS5 ended the session: \(reason)" : "Couldn't connect to \(console.name): \(reason)")
    }

    private func failed(_ msg: String) {
        setStatus(nil)
        let a = UIAlertController(title: console.name, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.leave() })
        present(a, animated: true)
    }

    func ps5LoginPinRequested(_ incorrect: Bool) {
        let saved = MCPs5Store.loginPin
        if !incorrect && saved.count == 4 { session?.setLoginPin(saved); return }
        let a = UIAlertController(title: incorrect ? "Wrong PIN, try again" : "Console login PIN",
                                  message: "The 4-digit PIN your PS5 asks for when it starts.", preferredStyle: .alert)
        a.addTextField { $0.keyboardType = .numberPad; $0.isSecureTextEntry = true }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.mcDisconnect() })
        a.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.session?.setLoginPin(a.textFields?.first?.text ?? "") })
        present(a, animated: true)
    }

    func ps5Rumble(_ left: UInt8, right: UInt8) {
        // rumble through Core Haptics comes later; most pads on iPad rumble via GCDeviceHaptics
    }

    private func leave() {
        guard !closed else { return }
        closed = true
        MCPs5Session.cancelPsn()
        cornerTimer?.invalidate()
        UIApplication.shared.isIdleTimerDisabled = false
        let s = session
        session = nil
        DispatchQueue.global().async { s?.stop() }
        navigationController?.popToRootViewController(animated: true)
    }

    // MARK: controller → DualSense

    @objc private func hookPads() {
        for c in GCController.controllers() {
            c.extendedGamepad?.valueChangedHandler = { [weak self] g, _ in self?.padChanged(g) }
        }
    }

    private func padChanged(_ g: GCExtendedGamepad) {
        guard let s = session, connected else { return }
        if menuOpen { s.setButtons(0, l2: 0, r2: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0); return }
        let select = g.buttonOptions?.isPressed ?? false
        let start = g.buttonMenu.isPressed
        // Select + Start + LB + RB: the Quick menu, as on the handheld
        if select && start && g.leftShoulder.isPressed && g.rightShoulder.isPressed {
            if !comboFired { comboFired = true; DispatchQueue.main.async { self.openMenu() } }
            s.setButtons(0, l2: 0, r2: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0)
            return
        }
        if !(select && start) && !(g.leftTrigger.isPressed && start) { comboFired = false }
        var b: UInt32 = 0
        func on(_ x: Bool, _ v: Int32) { if x { b |= UInt32(v) } }
        let swap = MCPs5Store.swapCrossCircle
        on(g.buttonA.isPressed, swap ? 1 << 1 : 1 << 0)     // Cross (Moon when swapped)
        on(g.buttonB.isPressed, swap ? 1 << 0 : 1 << 1)     // Moon
        on(g.buttonX.isPressed, 1 << 2)                    // Box
        on(g.buttonY.isPressed, 1 << 3)                    // Pyramid
        on(g.dpad.left.isPressed, 1 << 4); on(g.dpad.right.isPressed, 1 << 5)
        on(g.dpad.up.isPressed, 1 << 6); on(g.dpad.down.isPressed, 1 << 7)
        on(g.leftShoulder.isPressed, 1 << 8); on(g.rightShoulder.isPressed, 1 << 9)
        on(g.leftThumbstickButton?.isPressed ?? false, 1 << 10); on(g.rightThumbstickButton?.isPressed ?? false, 1 << 11)
        var l2 = UInt8(min(255, max(0, g.leftTrigger.value * 255)))
        let r2 = UInt8(min(255, max(0, g.rightTrigger.value * 255)))
        if let ds = g as? GCDualSenseGamepad {
            on(start, 1 << 12); on(select, 1 << 13)
            on(ds.touchpadButton.isPressed, 1 << 14)
            on(ds.buttonHome?.isPressed ?? false, 1 << 15)
        } else if g.leftTrigger.isPressed && start {
            // a pad without a PS button: L2 + Start is PS (Saleh's combo on Android)
            on(true, 1 << 15); l2 = 0
        } else if select && start {
            on(true, 1 << 14)                              // Select + Start = touchpad
        } else {
            on(start, 1 << 12); on(select, 1 << 13)
            on(g.buttonHome?.isPressed ?? false, 1 << 15)
        }
        func axis(_ v: Float) -> Int16 { Int16(max(-32767, min(32767, v * 32767))) }
        s.setButtons(b, l2: l2, r2: r2,
                     leftX: axis(g.leftThumbstick.xAxis.value), leftY: axis(-g.leftThumbstick.yAxis.value),
                     rightX: axis(g.rightThumbstick.xAxis.value), rightY: axis(-g.rightThumbstick.yAxis.value))
    }

    // MARK: Quick menu

    @objc private func edgeSwiped(_ r: UIScreenEdgePanGestureRecognizer) {
        if r.state == .began { openMenu() }
    }

    private func openMenu() {
        guard connected, !menuOpen else { return }
        MCQuickMenu.show(in: self)
    }

    private func updateCorner() {
        guard statsOn, connected, let d = session?.stats() else { corner.isHidden = true; return }
        let fps = (d["fps"] as? NSNumber)?.intValue ?? 0
        let rtt = (d["rtt"] as? NSNumber)?.intValue ?? -1
        let mbps = (d["mbps"] as? NSNumber)?.doubleValue ?? 0
        let lost = (d["lost"] as? NSNumber)?.intValue ?? 0
        corner.text = String(format: "  %d fps   %@   %.1f Mbps   %d lost  ", fps, rtt >= 0 ? "\(rtt) ms" : "…", mbps, lost)
        corner.sizeToFit()
        corner.frame.origin = CGPoint(x: 12, y: 12)
        corner.isHidden = false
    }

    func mcStats() -> [AnyHashable: Any] {
        var d = session?.stats() ?? [:]
        if let lost = d["lost"] { d["lostFrames"] = lost }
        d["loss"] = nil
        return d
    }
    func mcTitle() -> String { console.name }
    func mcHostAddress() -> String { console.host }
    func mcStatsOn() -> Bool { statsOn }
    func mcToggleStats() {
        statsOn.toggle()
        UserDefaults.standard.set(statsOn, forKey: "ps5_stats")
        updateCorner()
    }
    func mcTouchMode() -> Int32 { 0 }
    func mcSetTouchMode(_ mode: Int32) {}
    func mcToggleKeyboard() {}
    func mcTaskManager() {}
    func mcMenuOpen(_ open: Bool) {
        menuOpen = open
        if open { session?.setButtons(0, l2: 0, r2: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0) } else { hookPads() }
    }
    func mcKind() -> String { "ps5" }

    func mcPsButton() {
        guard let s = session else { return }
        s.setButtons(1 << 15, l2: 0, r2: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { s.setButtons(0, l2: 0, r2: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0) }
    }

    func mcRestMode() {
        session?.restMode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.leave() }
    }

    func mcDisconnect() {
        switch MCPs5Store.onDisconnect {
        case "rest": mcRestMode()
        case "keep": leave()
        default:
            let a = UIAlertController(title: "Leave \(console.name)", message: "Put the PS5 in rest mode, or keep it on?", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            a.addAction(UIAlertAction(title: "Keep it on", style: .default) { [weak self] _ in self?.leave() })
            a.addAction(UIAlertAction(title: "Rest mode", style: .default) { [weak self] _ in self?.mcRestMode() })
            present(a, animated: true)
        }
    }
}
