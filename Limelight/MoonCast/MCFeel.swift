//
//  MCFeel.swift
//  MoonCast: soft sounds as you move around the menus (FeelSounds on the handheld), and a light tap on touch.
//

import AudioToolbox
import UIKit

enum MCFeel {
    enum Cue { case move, select, back }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "hh_feel_sounds") as? Bool ?? true }

    static func play(_ c: Cue) {
        guard enabled else { return }
        switch c {
        case .move: AudioServicesPlaySystemSound(1104)     // the keyboard tick
        case .select: AudioServicesPlaySystemSound(1105)
        case .back: AudioServicesPlaySystemSound(1155)
        }
    }
}
