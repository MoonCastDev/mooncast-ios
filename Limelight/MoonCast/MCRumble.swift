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
    /// The pad that sent input last: the PS5's rumble goes to the pad being played (set from the PS5 player's pad handler).
    private weak var activePad: GCController?
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

    /// Remember the pad that is being played, so the console's rumble reaches it and not always the first one.
    func playing(_ pad: GCController?) { q.async { [self] in activePad = pad } }

    /// low / high motor strength 0...1 on the first pad (or the given player's, or with `pad: -1` the pad being played);
    /// stops by itself after `seconds`. A pad that can't rumble buzzes the device when "Rumble on this device" is on.
    func rumble(low: Float, high: Float, seconds: Double? = nil, pad index: Int = 0) {
        q.async { [self] in
            let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
            let target = index < 0 ? (activePad.flatMap { a in pads.first { $0 === a } } ?? pads.first) : (index < pads.count ? pads[index] : nil)
            let m = target.map { ensure($0) } ?? (left: nil, right: nil)
            if m.left == nil && m.right == nil {
                // only player 1's rumble falls back to the device, never a missing player 2
                if index <= 0 && MCDeviceRumble.enabled {
                    MCDeviceRumble.shared.buzz(max(low, high))
                    stopAt?.cancel()
                    if let s = seconds, max(low, high) > 0.01 {
                        let w = DispatchWorkItem { [weak self] in self?.rumble(low: 0, high: 0, pad: index) }
                        stopAt = w
                        q.asyncAfter(deadline: .now() + s, execute: w)
                    }
                }
                return
            }
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
            activePad = nil
        }
        MCDeviceRumble.stop()
    }
}

/// "Rumble on this device" (Settings → Controllers, off by default; the Android switch of the same name): the phone's or
/// tablet's own haptics stand in for a pad that can't rumble (or when no pad is connected for the PS5 and Xbox players).
@objc(MCDeviceRumble)
final class MCDeviceRumble: NSObject {
    static let shared = MCDeviceRumble()
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "mc_rumble_device") }
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private let q = DispatchQueue(label: "MCDeviceRumble")

    /// PC streams: the game's low / high motor strengths 0...1 (called from ControllerSupport when the pad has no motors)
    @objc(rumbleLow:high:) static func rumble(low: Float, high: Float) {
        guard enabled else { return }
        shared.buzz(max(low, high))
    }

    /// The buzz off and the engine let go (the stream closed).
    @objc static func stop() {
        shared.q.async { [s = shared] in
            try? s.player?.stop(atTime: 0); s.engine?.stop(); s.player = nil; s.engine = nil
        }
    }

    func buzz(_ v: Float) {
        q.async { [self] in
            if v <= 0.01 { try? player?.stop(atTime: CHHapticTimeImmediate); return }
            if player == nil {
                guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, let e = try? CHHapticEngine() else { return }
                e.isAutoShutdownEnabled = false
                e.resetHandler = { [weak self] in self?.q.async { try? self?.engine?.start() } }
                let ev = CHHapticEvent(eventType: .hapticContinuous,
                                       parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                                       relativeTime: 0, duration: 3600)
                guard (try? e.start()) != nil, let p = try? e.makeAdvancedPlayer(with: CHHapticPattern(events: [ev], parameters: [])) else { return }
                engine = e; player = p
            }
            try? player?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)], atTime: CHHapticTimeImmediate)
            try? engine?.start()   // no-op when running; revives it after a background / interruption
            try? player?.start(atTime: CHHapticTimeImmediate)
        }
    }
}
