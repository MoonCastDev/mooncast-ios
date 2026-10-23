//
//  MCTvController.swift
//  MoonCast: the iPad as a MoonCast TV's controller while a game plays there (TvControllerActivity): what's playing,
//  how the TV is doing, Play here instead / Stop / Quit game. The pad drives the game; Select + Start + LB + RB
//  switches it to these buttons and B gives it back.
//

import SwiftUI
import GameController

final class MCTvSession: ObservableObject {
    let tv: MCTvBox
    let game: MCGame
    let padKey: String
    @Published var state = "Sending…"
    @Published var error: String?
    @Published var links = 0
    @Published var menuMode = false
    private var closed = false
    private var comboFired = false

    init(tv: MCTvBox, game: MCGame) {
        self.tv = tv
        self.game = game
        self.padKey = MCPadServer.shared.key(forTv: tv.id)
    }

    func begin() {
        MCPadServer.shared.onClients = { [weak self] n in DispatchQueue.main.async { self?.links = n } }
        hookPads()
        Task { @MainActor in
            if let err = await MCTvSender.send(tv, game, padKey: padKey) { error = err; state = "Didn't start"; return }
            MCRecents.touch(game.key)
            state = "Starting on \(tv.name)…"
            let sentAt = Date()
            while !closed {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let (st, err) = await MCTvSender.status(tv) {
                    switch st {
                    case "playing", "streaming": state = "Playing on \(tv.name)"; error = nil
                    case "connecting", "starting":
                        state = "Starting on \(tv.name)…"
                        // Android TV won't let MoonCast take the screen from another app: say what to do
                        if -sentAt.timeIntervalSinceNow > 15 && links == 0 {
                            error = "Open MoonCast on \(tv.name). The TV took the game but can't show it while another app (YouTube, Netflix…) is in front."
                        }
                    case "failed", "error": state = "Stopped"; if !err.isEmpty { error = err }
                    case "idle", "home": if state.hasPrefix("Playing") { state = "Ended on \(tv.name)" }
                    default: break
                    }
                } else if links > 0 {
                    state = "Playing on \(tv.name)"
                }
            }
        }
    }

    func end(quit: Bool) {
        closed = true
        GCController.controllers().forEach { $0.extendedGamepad?.valueChangedHandler = nil }
        let tv = tv, key = padKey
        Task { await MCTvSender.stop(tv, padKey: key, quit: quit); MCPadServer.shared.stop() }
    }

    /// Pads -> W3C state for the TV (Y down-positive).
    @objc func hookPads() {
        for c in GCController.controllers() { c.extendedGamepad?.valueChangedHandler = { [weak self] g, _ in self?.read(g) } }
    }

    private func read(_ g: GCExtendedGamepad) {
        let select = g.buttonOptions?.isPressed ?? false
        if select && g.buttonMenu.isPressed && g.leftShoulder.isPressed && g.rightShoulder.isPressed {
            if !comboFired { comboFired = true; DispatchQueue.main.async { self.menuMode.toggle() } }
        } else if !select && !g.buttonMenu.isPressed { comboFired = false }
        if menuMode || comboFired {
            MCPadServer.shared.update(.init(repeating: 0, count: 17), .init(repeating: 0, count: 4))
            return
        }
        func p(_ x: GCControllerButtonInput?) -> Float { (x?.isPressed ?? false) ? 1 : 0 }
        let b: [Float] = [p(g.buttonA), p(g.buttonB), p(g.buttonX), p(g.buttonY), p(g.leftShoulder), p(g.rightShoulder),
                          g.leftTrigger.value, g.rightTrigger.value, p(g.buttonOptions), p(g.buttonMenu),
                          p(g.leftThumbstickButton), p(g.rightThumbstickButton),
                          p(g.dpad.up), p(g.dpad.down), p(g.dpad.left), p(g.dpad.right), p(g.buttonHome)]
        let a: [Float] = [g.leftThumbstick.xAxis.value, -g.leftThumbstick.yAxis.value, g.rightThumbstick.xAxis.value, -g.rightThumbstick.yAxis.value]
        MCPadServer.shared.update(b, a)
    }
}

struct MCTvControllerView: View {
    @ObservedObject var s: MCTvSession
    @ObservedObject var focus = MCFocus.shared
    let m: MCMetrics
    let p: MCPalette
    let playHere: () -> Void
    let close: () -> Void
    @AppStorage("hh_dim_on_tv") private var dimOnTv = true

    var body: some View {
        ZStack {
            (dimOnTv && !s.menuMode && s.error == nil ? Color.black : p.bg).ignoresSafeArea()
            VStack(alignment: .leading, spacing: m.px(22)) {
                Text(s.game.title).mcFont(52, m, weight: .heavy).foregroundColor(p.ink).lineLimit(2)
                Text(s.state).mcFont(30, m).foregroundColor(s.error == nil ? p.ring : MCPalette.red)
                if let e = s.error { Text(e).mcFont(26, m, weight: .medium).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true) }
                Text(s.links > 0 ? "This iPad is \(s.tv.name)'s controller" : "Waiting for \(s.tv.name) to connect to this iPad's controller…")
                    .mcFont(26, m, weight: .medium).foregroundColor(p.sub)
                HStack(spacing: m.px(20)) {
                    button("tvc:here", "Play here instead", main: true) { playHere() }
                    button("tvc:stop", "Stop", main: false) { s.end(quit: false); close() }
                    button("tvc:quit", "Quit game", main: false, danger: true) { s.end(quit: true); close() }
                }
                .padding(.top, m.px(20))
                Text(s.menuMode ? "The pad drives these buttons. B gives it back to the game."
                                : "Select + Start + LB + RB: use the pad for these buttons. The game keeps running when you stop.")
                    .mcFont(24, m, weight: .medium).foregroundColor(p.sub)
                Spacer()
            }
            .padding(m.px(m.edge))
            .padding(.top, m.px(60))
        }
        .mcCollectFrames(root: "tvc")
        .onAppear {
            focus.pushScope("tvc")
            focus.pageButton = { b in
                if s.menuMode && b == .b { s.menuMode = false; return true }
                return true   // the pad belongs to the game unless menu mode is on
            }
            focus.preferred["tvcmenu"] = "tvc:here"
            s.begin()
            NotificationCenter.default.addObserver(s, selector: #selector(MCTvSession.hookPads), name: .GCControllerDidConnect, object: nil)
        }
        .onDisappear { focus.popScope() }
        .onChange(of: s.menuMode) { _, on in
            focus.scope = on ? "tvcmenu" : "tvc"
            focus.id = on ? "tvc:here" : nil
            if !on { s.hookPads() }
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    private func button(_ id: String, _ label: String, main: Bool, danger: Bool = false, run: @escaping () -> Void) -> some View {
        Text(label).mcFont(30, m, weight: .heavy).foregroundColor(main ? p.bg : danger ? MCPalette.red : p.ink)
            .padding(.horizontal, m.px(36)).frame(height: max(m.px(88), 48))
            .background(Capsule().fill(main ? p.ink : p.panel))
            .mcFocusable(id, scope: "tvcmenu", corner: m.px(44), ring: p.ring, action: run)
    }
}
