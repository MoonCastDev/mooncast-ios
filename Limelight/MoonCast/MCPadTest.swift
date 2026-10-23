//
//  MCPadTest.swift
//  MoonCast: Test a controller (PadTestActivity): every button, stick and trigger live, and the rumble.
//  Hold B for a second, or tap Done, to leave.
//

import SwiftUI
import GameController
import CoreHaptics

final class MCPadTestModel: ObservableObject {
    @Published var name = "No controller"
    @Published var pressed: Set<String> = []
    @Published var left = CGPoint.zero
    @Published var right = CGPoint.zero
    @Published var l2: Float = 0
    @Published var r2: Float = 0
    @Published var battery: String?
    var onLeave: () -> Void = {}
    private var bDown: Date?
    private var engine: CHHapticEngine?

    func attach() {
        guard let c = GCController.controllers().first(where: { $0.extendedGamepad != nil }), let g = c.extendedGamepad else { return }
        name = c.vendorName ?? "Controller"
        battery = c.battery.map { "\(Int($0.batteryLevel * 100))%" }
        g.valueChangedHandler = { [weak self] g, _ in self?.read(g) }
    }

    func detach() {
        GCController.controllers().forEach { $0.extendedGamepad?.valueChangedHandler = nil }
        engine?.stop()
    }

    private func read(_ g: GCExtendedGamepad) {
        var p: Set<String> = []
        let all: [(String, GCControllerButtonInput?)] = [
            ("A", g.buttonA), ("B", g.buttonB), ("X", g.buttonX), ("Y", g.buttonY),
            ("LB", g.leftShoulder), ("RB", g.rightShoulder), ("LS", g.leftThumbstickButton), ("RS", g.rightThumbstickButton),
            ("Up", g.dpad.up), ("Down", g.dpad.down), ("Left", g.dpad.left), ("Right", g.dpad.right),
            ("Start", g.buttonMenu), ("Select", g.buttonOptions), ("Home", g.buttonHome),
        ]
        for (k, b) in all where b?.isPressed == true { p.insert(k) }
        if let ds = g as? GCDualSenseGamepad, ds.touchpadButton.isPressed { p.insert("Touchpad") }
        pressed = p
        left = CGPoint(x: CGFloat(g.leftThumbstick.xAxis.value), y: CGFloat(-g.leftThumbstick.yAxis.value))
        right = CGPoint(x: CGFloat(g.rightThumbstick.xAxis.value), y: CGFloat(-g.rightThumbstick.yAxis.value))
        l2 = g.leftTrigger.value
        r2 = g.rightTrigger.value
        // hold B for a second to leave (B itself is one of the buttons being tested)
        if g.buttonB.isPressed {
            if bDown == nil { bDown = Date() } else if Date().timeIntervalSince(bDown!) > 1 { bDown = nil; DispatchQueue.main.async { self.onLeave() } }
        } else { bDown = nil }
    }

    func rumble() {
        guard let c = GCController.controllers().first, let h = c.haptics,
              let e = h.createEngine(withLocality: .default) else { return }
        engine = e
        try? e.start()
        let ev = CHHapticEvent(eventType: .hapticContinuous, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)],
                               relativeTime: 0, duration: 0.6)
        if let pattern = try? CHHapticPattern(events: [ev], parameters: []), let player = try? e.makePlayer(with: pattern) {
            try? player.start(atTime: 0)
        }
    }
}

struct MCPadTestView: View {
    @StateObject var model = MCPadTestModel()
    let m: MCMetrics
    let p: MCPalette
    let done: () -> Void

    var body: some View {
        ZStack {
            p.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: m.px(28)) {
                HStack {
                    VStack(alignment: .leading, spacing: m.px(6)) {
                        Text("Test a controller").mcFont(44, m, weight: .heavy).foregroundColor(p.ink)
                        Text(model.name + (model.battery.map { " · battery \($0)" } ?? "") + " · hold B to leave")
                            .mcFont(26, m).foregroundColor(p.sub)
                    }
                    Spacer()
                    Text("Rumble").mcFont(28, m, weight: .heavy).foregroundColor(p.ink)
                        .padding(.horizontal, m.px(30)).frame(height: m.px(72)).background(Capsule().fill(p.panel))
                        .onTapGesture { model.rumble() }
                    Text("Done").mcFont(28, m, weight: .heavy).foregroundColor(p.bg)
                        .padding(.horizontal, m.px(30)).frame(height: m.px(72)).background(Capsule().fill(p.ink))
                        .onTapGesture { done() }
                }
                HStack(alignment: .top, spacing: m.px(60)) {
                    stick("Left stick", model.left, model.pressed.contains("LS"))
                    VStack(spacing: m.px(20)) {
                        trigger("L2", model.l2)
                        trigger("R2", model.r2)
                    }
                    stick("Right stick", model.right, model.pressed.contains("RS"))
                }
                let buttons = ["A", "B", "X", "Y", "LB", "RB", "Up", "Down", "Left", "Right", "Select", "Start", "Home", "Touchpad", "LS", "RS"]
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: m.px(16)), count: 8), spacing: m.px(16)) {
                    ForEach(buttons, id: \.self) { b in
                        let on = model.pressed.contains(b)
                        Text(b).mcFont(26, m, weight: .heavy).foregroundColor(on ? p.bg : p.ink)
                            .frame(maxWidth: .infinity, minHeight: m.px(84))
                            .background(RoundedRectangle(cornerRadius: m.px(16)).fill(on ? p.ring : p.panel))
                    }
                }
                Spacer()
            }
            .padding(m.px(m.edge))
        }
        .onAppear {
            model.onLeave = done
            model.attach()
            MCFocus.shared.pushScope("test")
            MCFocus.shared.pageButton = { _ in true }
        }
        .onDisappear {
            model.detach()
            MCFocus.shared.popScope()
        }
    }

    private func stick(_ label: String, _ v: CGPoint, _ clicked: Bool) -> some View {
        let r = m.px(130)
        return VStack(spacing: m.px(14)) {
            ZStack {
                Circle().fill(p.panel).frame(width: r * 2, height: r * 2)
                Circle().stroke(p.line, lineWidth: 2).frame(width: r, height: r)
                Circle().fill(clicked ? p.ring : p.ink).frame(width: m.px(46), height: m.px(46))
                    .offset(x: v.x * (r - m.px(23)), y: v.y * (r - m.px(23)))
            }
            Text(label).mcFont(24, m).foregroundColor(p.sub)
            Text(String(format: "%.2f, %.2f", v.x, -v.y)).mcFont(22, m, weight: .medium).foregroundColor(p.sub)
        }
    }

    private func trigger(_ label: String, _ v: Float) -> some View {
        VStack(spacing: m.px(10)) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: m.px(12)).fill(p.panel).frame(width: m.px(70), height: m.px(200))
                RoundedRectangle(cornerRadius: m.px(12)).fill(p.ring).frame(width: m.px(70), height: m.px(200) * CGFloat(v))
            }
            Text("\(label) \(Int(v * 100))%").mcFont(22, m).foregroundColor(p.sub)
        }
    }
}
