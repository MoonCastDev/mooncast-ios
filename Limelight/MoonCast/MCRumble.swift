//
//  MCRumble.swift
//  MoonCast: controller rumble for the PS5 and Xbox players, through the pad's own haptics (GCDeviceHaptics +
//  Core Haptics): the low-frequency motor on the left handle, the high-frequency one on the right, one continuous
//  player each whose intensity follows the console.
//

import GameController
import CoreHaptics

final class MCRumble {
    static let shared = MCRumble()
    private struct Motor { let engine: CHHapticEngine; let player: CHHapticAdvancedPatternPlayer }
    private var motors: [ObjectIdentifier: (left: Motor?, right: Motor?)] = [:]
    private var stopAt: DispatchWorkItem?
    private let q = DispatchQueue(label: "MCRumble")

    private func motor(_ h: GCDeviceHaptics, _ where: GCHapticsLocality) -> Motor? {
        guard h.supportedLocalities.contains(`where`), let e = h.createEngine(withLocality: `where`) else { return nil }
        e.isAutoShutdownEnabled = false
        e.resetHandler = { try? e.start() }
        do {
            try e.start()
            let ev = CHHapticEvent(eventType: .hapticContinuous,
                                   parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                CHHapticEventParameter(parameterID: .hapticSharpness, value: `where` == .rightHandle ? 0.8 : 0.2)],
                                   relativeTime: 0, duration: 3600)
            let p = try e.makeAdvancedPlayer(with: CHHapticPattern(events: [ev], parameters: []))
            return Motor(engine: e, player: p)
        } catch { return nil }
    }

    private func ensure(_ c: GCController) -> (left: Motor?, right: Motor?) {
        let k = ObjectIdentifier(c)
        if let m = motors[k] { return m }
        guard let h = c.haptics else { motors[k] = (nil, nil); return (nil, nil) }
        var m = (left: motor(h, .leftHandle), right: motor(h, .rightHandle))
        if m.left == nil && m.right == nil { m.left = motor(h, .default) }
        motors[k] = m
        return m
    }

    private func set(_ m: Motor?, _ v: Float) {
        guard let m = m else { return }
        if v <= 0.01 { try? m.player.stop(atTime: CHHapticTimeImmediate); return }
        try? m.player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)], atTime: CHHapticTimeImmediate)
        try? m.player.start(atTime: CHHapticTimeImmediate)
    }

    /// low / high motor strength 0...1 on the first pad (or the given player's); stops by itself after `seconds`.
    func rumble(low: Float, high: Float, seconds: Double? = nil, pad index: Int = 0) {
        q.async { [self] in
            let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
            guard index < pads.count else { return }
            let m = ensure(pads[index])
            if m.right == nil { set(m.left, max(low, high)) } else { set(m.left, low); set(m.right, high) }
            stopAt?.cancel()
            if let s = seconds {
                let w = DispatchWorkItem { [weak self] in self?.rumble(low: 0, high: 0, pad: index) }
                stopAt = w
                q.asyncAfter(deadline: .now() + s, execute: w)
            }
        }
    }

    /// Everything off and the engines let go (the stream screen closed).
    func stop() {
        q.async { [self] in
            for (_, m) in motors { [m.left, m.right].forEach { try? $0?.player.stop(atTime: 0); $0?.engine.stop() } }
            motors.removeAll()
        }
    }
}
