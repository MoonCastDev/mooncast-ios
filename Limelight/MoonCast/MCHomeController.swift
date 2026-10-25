//
//  MCHomeController.swift
//  MoonCast: hosts the home and starts Moonlight's stream screen, which comes back here when the stream ends.
//

import SwiftUI

/// The app's first screen, for AppDelegate (a generic hosting controller can't be seen from Objective-C).
@objc(MCLaunch)
final class MCLaunch: NSObject {
    /// The home in a navigation controller: Moonlight's stream screen pops back to it.
    @objc static func makeRoot() -> UIViewController {
        let nav = MCNav(rootViewController: MCHomeController())
        nav.setNavigationBarHidden(true, animated: false)
        return nav
    }

    /// Settings → Screen turns with the device changed: ask the window to apply it.
    static func updateOrientation() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        root.setNeedsUpdateOfSupportedInterfaceOrientations()
        if !(UserDefaults.standard.object(forKey: "hh_rotate") as? Bool ?? true) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
        }
    }
}

/// The app's navigation. The home follows Settings → Screen turns with the device (off = on its side only).
/// iPhone: games always play on their side, as on the handheld, so starting one turns the screen and leaving it
/// turns back. iPad: a game stays in the orientation it started in.
final class MCNav: UINavigationController, UINavigationControllerDelegate {
    /// While a game is about to open from an upright home: on its side only
    private var turning = false
    /// The home was upright when a game turned the screen: go back upright after it
    private var wasUpright = false

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    private var onHome: Bool { topViewController is MCHomeController }
    private var homeTurns: Bool { UserDefaults.standard.object(forKey: "hh_rotate") as? Bool ?? true }

    /// iPad: a game keeps the orientation it started in (iPadOS 26 doesn't turn an iPad's screen on request; asking
    /// put the game in a window instead), and Moonlight's player is laid out once, for that orientation
    private var gameMask: UIInterfaceOrientationMask = .landscape
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if onHome && !turning { return homeTurns ? (pad ? .all : .allButUpsideDown) : .landscape }
        return pad ? .all : .landscape
    }

    /// Opens a game's player: turns the screen on its side first, so the player is laid out for it from the start
    /// (a PC stream laid out upright kept an upright-sized picture in a corner after the turn).
    func pushGame(_ vc: UIViewController) {
        if pad, let o = view.window?.windowScene?.interfaceOrientation {
            gameMask = o == .portrait ? .portrait : o == .portraitUpsideDown ? .portraitUpsideDown
                : o == .landscapeLeft ? .landscapeLeft : o == .landscapeRight ? .landscapeRight : .landscape
            pushViewController(vc, animated: true)
            return
        }
        guard let scene = view.window?.windowScene, !scene.interfaceOrientation.isLandscape else {
            pushViewController(vc, animated: true)
            return
        }
        turning = true
        wasUpright = true
        setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.pushViewController(vc, animated: true)
            self.turning = false
        }
    }

    func navigationController(_ nav: UINavigationController, didShow vc: UIViewController, animated: Bool) {
        if pad { return }
        setNeedsUpdateOfSupportedInterfaceOrientations()
        // back home from a game: upright again if the home was upright before it, unless the device is now
        // clearly held on its side (lying flat on a table it reports face up, not upright)
        guard vc is MCHomeController, wasUpright else { return }
        wasUpright = false
        // a moment later: iOS still holds the game's on-its-side-only rule while the home appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self, self.homeTurns, let scene = self.view.window?.windowScene, scene.interfaceOrientation.isLandscape,
                  !UIDevice.current.orientation.isLandscape else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { e in NSLog("MoonCast: back upright failed: \(e)") }
        }
    }
}

final class MCHomeController: UIHostingController<MCRoot> {

    init() {
        super.init(rootView: MCRoot())
        var root = MCRoot()
        root.askText = { [weak self] title, placeholder, done in self?.ask(title, placeholder, done) }
        root.openXboxLink = { [weak self] code in
            let vc = MCXboxLinkController()
            vc.code = code
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .formSheet
            self?.present(nav, animated: true)
        }
        root.signInPsn = { [weak self] done in
            let vc = MCPsnSignInController()
            vc.done = done
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .formSheet
            self?.present(nav, animated: true)
        }
        rootView = root
        MCStore.shared.onStream = { [weak self] cfg in self?.stream(cfg) }
        MCStore.shared.onXboxStream = { [weak self] c in
            MCStore.shared.playing = MCStore.shared.allGames().first { $0.xb?.id == c.id }
            MCUsage.used("xbox")
            MCPad.shared.detach()
            (self?.navigationController as? MCNav)?.pushGame(MCXboxStreamController(console: c))
        }
        MCStore.shared.onPs5Stream = { [weak self] c in
            MCStore.shared.playing = MCStore.shared.allGames().first { $0.ps?.host == c.host }
            MCUsage.used("ps5")
            MCPad.shared.detach()
            (self?.navigationController as? MCNav)?.pushGame(MCPs5StreamController(console: c))
        }
        NotificationCenter.default.addObserver(self, selector: #selector(active), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inactive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        UserDefaults.standard.string(forKey: "hh_theme") == "light" ? .darkContent : .lightContent
    }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    private var onTop: Bool { navigationController?.topViewController === self }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        MCPad.shared.attach()
        MCStore.shared.resume()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        MCPad.shared.detach()
        MCStore.shared.pause()
    }

    @objc private func active() { if onTop { MCPad.shared.attach(); MCStore.shared.resume() } }
    @objc private func inactive() { if onTop { MCStore.shared.pause() } }

    private func stream(_ cfg: StreamConfiguration) {
        let vc = MCBridge.streamController(withConfig: cfg)
        MCPad.shared.detach()
        (navigationController as? MCNav)?.pushGame(vc)
    }

    private func ask(_ title: String, _ placeholder: String, _ done: @escaping (String) -> Void) {
        let a = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        // "digits" in the hint asks for a whole number, "Mbps" for one with a decimal point, else an address
        let decimal = placeholder.contains("Mbps")
        let digits = placeholder.contains("digits") || placeholder.contains("fps") || decimal
        a.addTextField { t in
            t.placeholder = placeholder
            // "A name…" asks for words (a profile's name), anything else for an address
            let words = placeholder.hasPrefix("A name")
            t.keyboardType = decimal ? .decimalPad : digits ? .numberPad : words ? .default : .URL
            t.autocapitalizationType = words ? .words : .none
            t.autocorrectionType = .no
        }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: digits || placeholder.hasPrefix("A name") ? "OK" : "Add", style: .default) { _ in done(a.textFields?.first?.text ?? "") })
        present(a, animated: true)
    }
}
