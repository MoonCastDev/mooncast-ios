//
//  MCTheme.swift
//  MoonCast: the handheld's look (Sw.kt): its colours, the cover gradients and the design units.
//

import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// The two themes, as on Android (Settings → Theme).
struct MCPalette {
    let light: Bool
    var bg: Color { Color(hex: light ? 0xEBEBEB : 0x2B2D31) }
    var panel: Color { Color(hex: light ? 0xFFFFFF : 0x36393F) }
    var tile: Color { Color(hex: light ? 0xDADCE0 : 0x3E4249) }
    var line: Color { Color(hex: light ? 0xCDCFD4 : 0x474B53) }
    var ink: Color { Color(hex: light ? 0x2D2D2D : 0xFFFFFF) }
    var sub: Color { Color(hex: light ? 0x6E727A : 0xB5BAC3) }
    var label: Color { Color(hex: light ? 0x3A3D42 : 0xD9DCE1) }
    var ring: Color { Color(hex: light ? 0x00A9C2 : 0x2FD3E6) }

    static let cyan = Color(hex: 0x2FD3E6)
    static let amber = Color(hex: 0xF2B55C)
    static let blue = Color(hex: 0x5C8DF6)
    static let green = Color(hex: 0x2DBE5A)
    static let red = Color(hex: 0xE9605A)
    static let live = Color(hex: 0x2DBE5A)
}

/// The shared cover palette (Covers in Tv.kt): PlayStation blue, Xbox green, anything else by its name.
enum Covers {
    static let art: [[UInt32]] = [
        [0xF05A45, 0xA01E16, 0x4A0B08],
        [0x3D86FF, 0x1035A0, 0x071644],
        [0x3CCB63, 0x0E7A2C, 0x06300F],
        [0xF4C04E, 0xB87414, 0x4C2C06],
        [0xA06BF0, 0x5223A8, 0x1F0B47],
        [0x4FD6E3, 0x127C8A, 0x06323A],
        [0xF06BA8, 0xA3205E, 0x420A25],
        [0xB9C0CC, 0x5B6372, 0x22262E],
    ]

    /// Java's String.hashCode, so a game gets the same colour here as on the Android apps.
    static func javaHash(_ s: String) -> Int32 {
        var h: Int32 = 0
        for u in s.utf16 { h = h &* 31 &+ Int32(u) }
        return h
    }

    static func index(_ seed: String) -> Int {
        switch seed {
        case "ps": return 1
        case "xb": return 2
        default:
            let i = abs(Int(javaHash(seed) % Int32(art.count)))
            return (i == 1 || i == 2) ? i + 4 : i
        }
    }

    static func colors(_ seed: String) -> [Color] { art[index(seed)].map { Color(hex: $0) } }
    static func tint(_ seed: String) -> Color { Color(hex: art[index(seed)][1]) }
}

/// A cover for things without box art: the mockup's radial gradient.
struct CoverArt: View {
    let colors: [Color]
    var body: some View {
        GeometryReader { g in
            RadialGradient(stops: [.init(color: colors[0], location: 0), .init(color: colors[1], location: 0.55),
                                   .init(color: colors[2], location: 1)],
                           center: UnitPoint(x: 0.55, y: 0.28), startRadius: 0,
                           endRadius: max(g.size.width, g.size.height) * 1.05)
        }
    }
}

/// Design units: the Android layout is drawn for a 1080-high screen; one unit here is that share of this screen.
struct MCMetrics {
    let size: CGSize
    var portrait: Bool { size.height > size.width }
    var u: CGFloat { min(size.width, size.height) / 1080 }
    var designWidth: CGFloat { size.width / u }
    var designHeight: CGFloat { size.height / u }
    func px(_ v: CGFloat) -> CGFloat { v * u }
    var edge: CGFloat { portrait ? 40 : 96 }
    var tileCorner: CGFloat { 16 }
}

extension View {
    /// A system font at an Android design size and weight (700 bold, 800 heavy).
    func mcFont(_ size: CGFloat, _ m: MCMetrics, weight: Font.Weight = .bold) -> some View {
        font(.system(size: m.px(size), weight: weight))
    }
}
