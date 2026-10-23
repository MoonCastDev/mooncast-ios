//
//  MCQuickMenu.swift
//  MoonCast: the Quick menu over a PC stream (QuickMenu.kt's Switch look): the game, live numbers, then Keyboard,
//  Streaming status, Touch screen, Controllers, Task Manager, Disconnect and Quit game. Select + Start + LB + RB or
//  a swipe from the left edge opens it; B or a tap outside goes back to the game.
//

import SwiftUI
import GameController

@objc(MCQuickMenu)
final class MCQuickMenu: NSObject {
    private static var host: UIHostingController<MCQuickMenuView>?

    @objc static func show(in vc: UIViewController) {
        guard host == nil, let actions = vc as? MCQuickActions else { return }
        actions.mcMenuOpen(true)
        let model = MCQuickModel(actions: actions)
        let h = UIHostingController(rootView: MCQuickMenuView(model: model))
        h.view.backgroundColor = .clear
        h.view.frame = vc.view.bounds
        h.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.addChild(h)
        vc.view.addSubview(h.view)
        h.didMove(toParent: vc)
        host = h
        MCFocus.shared.pushScope("qm")
        MCPad.shared.attach()
        model.onClose = { close(actions); MCQuickMenu.model = nil }
        MCQuickMenu.model = model
    }

    private static var model: MCQuickModel?

    /// Test runs only: MC_QM_STEPS="8:open,11:1,14:close,18:open,22:5" (seconds after the stream starts: open the
    /// menu, press item N, close it), so the menu can be checked from a script.
    @objc static func runTestSteps(in vc: UIViewController) {
        #if DEBUG
        guard let steps = ProcessInfo.processInfo.environment["MC_QM_STEPS"] else { return }
        for step in steps.split(separator: ",") {
            let parts = step.split(separator: ":")
            guard parts.count == 2, let t = Double(parts[0]) else { continue }
            let what = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak vc] in
                guard let vc = vc else { return }
                switch what {
                case "open": show(in: vc)
                case "close": if let a = vc as? MCQuickActions { close(a) }
                default: if let i = Int(what) { model?.press?(i) }
                }
            }
        }
        #endif
    }

    static func close(_ actions: MCQuickActions) {
        guard let h = host else { return }
        host = nil
        MCPad.shared.detach()
        MCFocus.shared.popScope()
        h.willMove(toParent: nil)
        h.view.removeFromSuperview()
        h.removeFromParent()
        actions.mcMenuOpen(false)
    }
}

final class MCQuickModel: ObservableObject {
    let actions: MCQuickActions
    var onClose: () -> Void = {}
    /// Presses item N (test runs)
    var press: ((Int) -> Void)?
    @Published var stats: [(String, String)] = []
    @Published var rev = 0
    private var timer: Timer?

    init(actions: MCQuickActions) {
        self.actions = actions
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        let d = actions.mcStats()
        let fps = (d["fps"] as? NSNumber)?.floatValue
        let rtt = (d["rtt"] as? NSNumber)?.intValue ?? -1
        let loss = (d["loss"] as? NSNumber)?.floatValue
        let lostFrames = (d["lostFrames"] as? NSNumber)?.intValue
        let mbps = (d["mbps"] as? NSNumber)?.floatValue ?? 0
        let codec = d["codec"] as? String ?? ""
        stats = [
            (fps.map { String(format: "%.0f", $0) } ?? "…", "fps"),
            (rtt >= 0 ? "\(rtt) ms" : "…", "delay"),
            (String(format: mbps < 10 ? "%.1f" : "%.0f", mbps), "Mbps"),
            (lostFrames.map { "\($0)" } ?? loss.map { String(format: "%.1f%%", $0) } ?? "…", "lost"),
            (codec.isEmpty ? "…" : codec.replacingOccurrences(of: "HEVC", with: "H.265"), "codec"),
        ]
    }

    func close() {
        timer?.invalidate()
        onClose()
    }
}

struct MCQuickMenuView: View {
    @ObservedObject var model: MCQuickModel
    @ObservedObject var focus = MCFocus.shared
    @AppStorage("hh_theme") private var theme = "dark"

    private struct Item {
        let icon: String
        let label: String
        let detail: String?
        var danger = false
        let run: () -> Void
    }

    private static let touchLabels = ["Off", "Mouse", "Touch"]

    private func items() -> [Item] {
        let a = model.actions
        let pads = GCController.controllers().count
        if a.mcKind?() == "ps5" {
            return [
                Item(icon: "info.circle", label: "Streaming status", detail: a.mcStatsOn() ? "On" : "Off") { a.mcToggleStats(); model.rev += 1 },
                Item(icon: "gamecontroller", label: "Controllers", detail: pads == 1 ? "1 connected" : "\(pads) connected") {},
                Item(icon: "playstation.logo", label: "PS button", detail: "Pads without one: L2 + Start") { model.close(); a.mcPsButton?() },
                Item(icon: "arrow.left", label: "Disconnect", detail: "Ask, rest mode or keep it on (Settings → PlayStation)") { model.close(); a.mcDisconnect() },
                Item(icon: "moon.zzz", label: "Rest mode", detail: "Puts the PS5 to sleep", danger: true) { model.close(); a.mcRestMode?() },
            ]
        }
        return [
            Item(icon: "keyboard", label: "Keyboard", detail: "On-screen") { a.mcToggleKeyboard(); model.close() },
            Item(icon: "info.circle", label: "Streaming status", detail: a.mcStatsOn() ? "On" : "Off") { a.mcToggleStats(); model.rev += 1 },
            Item(icon: "hand.point.up.left", label: "Touch screen", detail: Self.touchLabels[Int(a.mcTouchMode()) % 3]) {
                a.mcSetTouchMode((a.mcTouchMode() + 1) % 3); model.rev += 1
            },
            Item(icon: "gamecontroller", label: "Controllers", detail: pads == 1 ? "1 connected" : "\(pads) connected") {},
            Item(icon: "list.bullet.rectangle", label: "Task Manager", detail: "Windows: Ctrl + Shift + Esc") { a.mcTaskManager(); model.close() },
            Item(icon: "arrow.left", label: "Disconnect", detail: "The game keeps running") { model.close(); a.mcDisconnect() },
            Item(icon: "xmark", label: "Quit game", detail: nil, danger: true) {
                let address = a.mcHostAddress()
                model.close()
                a.mcDisconnect()
                MCStore.shared.quitGame(atAddress: address)
            },
        ]
    }

    var body: some View {
        GeometryReader { geo in
            let upright = geo.size.height > geo.size.width
            let m = MCMetrics(size: geo.size)
            let p = MCPalette(light: theme == "light")
            let _ = model.rev
            ZStack(alignment: upright ? .bottom : .trailing) {
                Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { model.close() }
                panel(m, p)
                    .padding(.top, geo.safeAreaInsets.top)
                    .padding(.bottom, geo.safeAreaInsets.bottom)
                    .frame(width: upright ? geo.size.width : m.px(680),
                           height: upright ? geo.size.height * 0.62 : geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
                    .background(UnevenRoundedRectangle(topLeadingRadius: upright ? m.px(36) : 0, topTrailingRadius: upright ? m.px(36) : 0)
                        .fill(p.panel.opacity(0.94)))
            }
            .ignoresSafeArea()
        }
        .mcCollectFrames(root: "qm")
        .onAppear {
            let list = items()
            model.press = { i in if i < list.count { items()[i].run() } }
            MCFocus.shared.preferred["qm"] = "qm:0"
            MCFocus.shared.id = "qm:0"
            MCFocus.shared.pageButton = { b in
                if b == .b || b == .menu { model.close(); return true }
                return false
            }
        }
    }

    private func panel(_ m: MCMetrics, _ p: MCPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.actions.mcTitle()).mcFont(36, m, weight: .heavy).foregroundColor(p.ink).lineLimit(2)
            Text((model.actions.mcKind?() == "ps5" ? "PlayStation 5 · " : "") + "Select + Start + LB + RB opens this menu").mcFont(24, m).foregroundColor(p.sub).lineLimit(2)
                .padding(.top, m.px(8))
            HStack(spacing: m.px(8)) {
                ForEach(model.stats.indices, id: \.self) { i in
                    let s = model.stats[i]
                    VStack(spacing: m.px(4)) {
                        Text(s.0).font(.system(size: m.px(s.0.count <= 4 ? 34 : s.0.count <= 6 ? 28 : 22), weight: .heavy))
                            .foregroundColor(p.ink).lineLimit(1).minimumScaleFactor(0.6)
                        Text(s.1).mcFont(20, m, weight: .semibold).foregroundColor(p.sub)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, m.px(18))
                    .background(RoundedRectangle(cornerRadius: m.px(10)).fill(p.bg))
                }
            }
            .padding(.top, m.px(30)).padding(.bottom, m.px(20))
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: m.px(10)) {
                        let list = items()
                        ForEach(list.indices, id: \.self) { i in
                            let it = list[i]
                            HStack(spacing: m.px(22)) {
                                Image(systemName: it.icon).font(.system(size: m.px(24), weight: .bold)).foregroundColor(.white)
                                    .frame(width: m.px(52), height: m.px(52))
                                    .background(RoundedRectangle(cornerRadius: m.px(12)).fill(it.danger ? MCPalette.red : Color(hex: 0x5B6170)))
                                VStack(alignment: .leading, spacing: m.px(4)) {
                                    Text(it.label).mcFont(28, m, weight: .heavy).foregroundColor(it.danger ? MCPalette.red : p.ink)
                                    if let d = it.detail { Text(d).mcFont(21, m, weight: .semibold).foregroundColor(p.sub) }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, m.px(24))
                            .frame(minHeight: max(m.px(100), 52))
                            .background(RoundedRectangle(cornerRadius: m.px(16)).fill(focus.id == "qm:\(i)" ? p.bg : Color.clear))
                            .id("qm:\(i)")
                            .mcFocusable("qm:\(i)", scope: "qm", corner: m.px(16), ring: p.ring, action: it.run)
                        }
                    }
                    .padding(m.px(8))
                }
                .onChange(of: focus.id) { _, id in if let id = id, id.hasPrefix("qm:") { proxy.scrollTo(id) } }
            }
            HStack(spacing: m.px(12)) {
                Spacer()
                ForEach([("A", "OK"), ("B", "Back to the game")], id: \.0) { k, l in
                    Text(k).mcFont(24, m, weight: .heavy).foregroundColor(p.bg)
                        .frame(width: m.px(46), height: m.px(46)).background(Circle().fill(p.ink))
                        .padding(.leading, m.px(20))
                    Text(l).mcFont(24, m).foregroundColor(p.ink)
                        .onTapGesture { if k == "B" { model.close() } }
                }
            }
            .padding(.top, m.px(24))
        }
        .padding(.horizontal, m.px(44))
        .padding(.vertical, m.px(40))
    }
}
