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

/// The app's navigation: follows Settings → Screen turns with the device (off = on its side only).
final class MCNav: UINavigationController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        (UserDefaults.standard.object(forKey: "hh_rotate") as? Bool ?? true) ? .all : .landscape
    }
}

final class MCHomeController: UIHostingController<MCRoot> {

    init() {
        super.init(rootView: MCRoot())
        var root = MCRoot()
        root.askText = { [weak self] title, placeholder, done in self?.ask(title, placeholder, done) }
        rootView = root
        MCStore.shared.onStream = { [weak self] cfg in self?.stream(cfg) }
        MCStore.shared.onPs5Stream = { [weak self] c in
            MCPad.shared.detach()
            self?.navigationController?.pushViewController(MCPs5StreamController(console: c), animated: true)
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
        navigationController?.pushViewController(vc, animated: true)
    }

    private func ask(_ title: String, _ placeholder: String, _ done: @escaping (String) -> Void) {
        let a = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        a.addTextField { t in
            t.placeholder = placeholder
            t.keyboardType = .URL
            t.autocapitalizationType = .none
            t.autocorrectionType = .no
        }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Add", style: .default) { _ in done(a.textFields?.first?.text ?? "") })
        present(a, animated: true)
    }
}
