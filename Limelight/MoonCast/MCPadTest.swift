//
//  MCPadTest.swift
//  MoonCast: Test a controller (PadTestActivity): every connected pad, each with every button, stick and trigger live, and the rumble.
//  Hold B for a second, or tap Done, to leave.
//

import SwiftUI
import GameController
import CoreHaptics

/// One connected pad's live state.
final class MCPadState: ObservableObject {
    let controller: GCController
    @Published var pressed: Set<String> = []
    @Published var left = CGPoint.zero
    @Published var right = CGPoint.zero
    @Published var l2: Float = 0
    @Published var r2: Float = 0
    let name: String
    let battery: String?
    let canRumble: Bool
    private var xyDown = false
    private var engine: CHHapticEngine?
    var onB: (Bool) -> Void = { _ in }

    init(_ c: GCController) {
        controller = c
        name = (c.vendorName ?? "Controller") + (c.productCategory.isEmpty ? "" : " (\(c.productCategory))")
        battery = c.battery.map { "\(Int($0.batteryLevel * 100))%" }
        canRumble = c.haptics != nil
        c.extendedGamepad?.valueChangedHandler = { [weak self] g, _ in self?.read(g) }
    }

    func detach() {
        controller.extendedGamepad?.valueChangedHandler = nil
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
        // X + Y on the pad tries its rumble, as on Android
        let xy = p.contains("X") && p.contains("Y")
        if xy && !xyDown { rumble() }
        xyDown = xy
        onB(p.contains("B"))
    }

    func rumble() {
        guard let h = controller.haptics, let e = h.createEngine(withLocality: .default) else {
            if MCDeviceRumble.enabled { MCDeviceRumble.shared.buzz(1); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MCDeviceRumble.shared.buzz(0) } }
            return
        }
        engine = e
        try? e.start()
        let ev = CHHapticEvent(eventType: .hapticContinuous, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)],
                               relativeTime: 0, duration: 0.6)
        if let pattern = try? CHHapticPattern(events: [ev], parameters: []), let player = try? e.makePlayer(with: pattern) {
            try? player.start(atTime: 0)
        }
    }
}

final class MCPadTestModel: ObservableObject {
    @Published var pads: [MCPadState] = []
    var onLeave: () -> Void = {}
    private var bDown: [ObjectIdentifier: Date] = [:]
    private var observers: [NSObjectProtocol] = []

    func attach() {
        refresh()
        let nc = NotificationCenter.default
        for n in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }

    /// Every connected pad, each live (the list follows pads coming and going).
    private func refresh() {
        pads.forEach { $0.detach() }
        pads = GCController.controllers().filter { $0.extendedGamepad != nil }.map { c in
            let s = MCPadState(c)
            let k = ObjectIdentifier(c)
            // hold B for a second to leave (B itself is one of the buttons being tested)
            s.onB = { [weak self] down in
                guard let self = self else { return }
                if !down { self.bDown[k] = nil; return }
                if let t = self.bDown[k] { if Date().timeIntervalSince(t) > 1 { self.bDown[k] = nil; DispatchQueue.main.async { self.onLeave() } } }
                else { self.bDown[k] = Date() }
            }
            return s
        }
    }

    func detach() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        pads.forEach { $0.detach() }
    }

    func rumbleAll() { pads.forEach { $0.rumble() } }
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
                        Text((model.pads.isEmpty ? "No controller connected. Pair one in Settings, Controllers."
                              : "\(model.pads.count) connected · press anything, or X + Y for a pad's rumble") + " · hold B to leave")
                            .mcFont(26, m).foregroundColor(p.sub)
                    }
                    Spacer()
                    Text("Rumble").mcFont(28, m, weight: .heavy).foregroundColor(p.ink)
                        .padding(.horizontal, m.px(30)).frame(height: m.px(72)).background(Capsule().fill(p.panel))
                        .onTapGesture { model.rumbleAll() }
                    Text("Done").mcFont(28, m, weight: .heavy).foregroundColor(p.bg)
                        .padding(.horizontal, m.px(30)).frame(height: m.px(72)).background(Capsule().fill(p.ink))
                        .onTapGesture { done() }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: m.px(48)) {
                        ForEach(model.pads.indices, id: \.self) { i in
                            MCPadCard(pad: model.pads[i], number: i + 1, count: model.pads.count, m: m, p: p)
                        }
                    }
                }
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
}

/// One pad: its name, sticks, triggers and every button.
struct MCPadCard: View {
    @ObservedObject var pad: MCPadState
    let number: Int
    let count: Int
    let m: MCMetrics
    let p: MCPalette

    var body: some View {
        VStack(alignment: .leading, spacing: m.px(24)) {
            Text((count > 1 ? "Pad \(number): " : "") + pad.name + (pad.battery.map { " · battery \($0)" } ?? "")
                 + (pad.canRumble ? " · rumble supported" : " · no rumble reported"))
                .mcFont(28, m, weight: .heavy).foregroundColor(p.ink)
            HStack(alignment: .top, spacing: m.px(60)) {
                stick("Left stick", pad.left, pad.pressed.contains("LS"))
                VStack(spacing: m.px(20)) {
                    trigger("L2", pad.l2)
                    trigger("R2", pad.r2)
                }
                stick("Right stick", pad.right, pad.pressed.contains("RS"))
            }
            let buttons = ["A", "B", "X", "Y", "LB", "RB", "Up", "Down", "Left", "Right", "Select", "Start", "Home", "Touchpad", "LS", "RS"]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: m.px(16)), count: 8), spacing: m.px(16)) {
                ForEach(buttons, id: \.self) { b in
                    let on = pad.pressed.contains(b)
                    Text(b).mcFont(26, m, weight: .heavy).foregroundColor(on ? p.bg : p.ink)
                        .frame(maxWidth: .infinity, minHeight: m.px(84))
                        .background(RoundedRectangle(cornerRadius: m.px(16)).fill(on ? p.ring : p.panel))
                }
            }
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
