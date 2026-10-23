//
//  MCFocus.swift
//  MoonCast: controller navigation for the home. Every item that can be picked reports where it is; the D-pad or
//  left stick moves to the nearest one in that direction (as Android's focus does on the handheld), A presses it,
//  X opens its menu, B goes back. Touch works as well: a tap presses, a long press opens the menu.
//

import SwiftUI
import GameController

/// The buttons the home listens to.
enum MCButton { case up, down, left, right, a, b, x, y, l, r, menu }

final class MCFocus: ObservableObject {
    static let shared = MCFocus()

    /// The focused item's id.
    @Published var id: String?
    /// A controller is connected: the ring and the button hints show.
    @Published var padActive = false
    /// The connected controller's name, for the hint bar.
    @Published var padName = ""

    /// Where each item is on screen, by scope (the page, or an open dialog).
    var frames: [String: CGRect] = [:]
    var scopes: [String: String] = [:]
    var actions: [String: () -> Void] = [:]
    var menus: [String: () -> Void] = [:]
    /// Only items in this scope can be reached (a dialog takes it while it's open).
    var scope = "page"
    /// What the page does with the buttons items don't use (B, L, R, Y, X).
    var pageButton: ((MCButton) -> Bool)?
    /// Where focus goes when a page or dialog opens.
    var preferred: [String: String] = [:]

    func register(_ id: String, scope: String, action: @escaping () -> Void, menu: (() -> Void)?) {
        actions[id] = action
        scopes[id] = scope
        if let menu = menu { menus[id] = menu } else { menus.removeValue(forKey: id) }
    }

    /// The focus is gone or out of scope: land on the scope's preferred item, or its top-left one.
    func settle() {
        if let id = id, frames[id] != nil, scopes[id] == scope { return }
        if let p = preferred[scope], frames[p] != nil { id = p; return }
        id = frames.filter { scopes[$0.key] == scope }
            .min { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }?.key
    }

    func press(_ b: MCButton) {
        switch b {
        case .up, .down, .left, .right:
            if id == nil || frames[id!] == nil || scopes[id!] != scope { settle(); return }
            if let next = nearest(from: id!, b) { id = next } else { _ = pageButton?(b) }
        case .a:
            if let id = id, scopes[id] == scope { actions[id]?() } else { settle() }
        case .x:
            // the page's own use of X (A to Z in All games) comes first, then the focused item's menu
            if pageButton?(b) == true { return }
            if let id = id, scopes[id] == scope, let m = menus[id] { m() }
        default:
            _ = pageButton?(b)
        }
    }

    /// The closest item in the direction: distance along it, plus twice the sideways offset.
    private func nearest(from: String, _ dir: MCButton) -> String? {
        guard let a = frames[from] else { return nil }
        var best: (String, CGFloat)?
        for (k, r) in frames where k != from && scopes[k] == scope {
            let primary: CGFloat, side: CGFloat
            switch dir {
            case .right: primary = r.minX - a.maxX + 1; side = abs(r.midY - a.midY)
                if r.midX <= a.midX + 1 { continue }
            case .left: primary = a.minX - r.maxX + 1; side = abs(r.midY - a.midY)
                if r.midX >= a.midX - 1 { continue }
            case .down: primary = r.minY - a.maxY + 1; side = abs(r.midX - a.midX)
                if r.midY <= a.midY + 1 { continue }
            case .up: primary = a.minY - r.maxY + 1; side = abs(r.midX - a.midX)
                if r.midY >= a.midY - 1 { continue }
            default: return nil
            }
            let score = max(primary, 0) + side * 2
            if best == nil || score < best!.1 { best = (k, score) }
        }
        return best?.0
    }
}

/// Reads every controller and turns it into MCButton presses, with repeat while a direction is held.
final class MCPad {
    static let shared = MCPad()
    private var attached = false
    private var held: MCButton?
    private var repeatTimer: Timer?
    private var stickDir: [ObjectIdentifier: MCButton] = [:]

    private init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.hookAll() }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.hookAll() }
    }

    /// The home is on screen: listen to the pads.
    func attach() { attached = true; hookAll() }

    /// A stream is starting: hand the pads to Moonlight.
    func detach() {
        attached = false
        stopRepeat()
        for c in GCController.controllers() { unhook(c) }
    }

    private func hookAll() {
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil || $0.microGamepad != nil }
        MCFocus.shared.padActive = !pads.isEmpty
        MCFocus.shared.padName = pads.first.map { $0.vendorName ?? "Controller" } ?? ""
        guard attached else { return }
        pads.forEach(hook)
    }

    private func unhook(_ c: GCController) {
        guard let g = c.extendedGamepad else { return }
        [g.dpad.up, g.dpad.down, g.dpad.left, g.dpad.right, g.buttonA, g.buttonB, g.buttonX, g.buttonY,
         g.leftShoulder, g.rightShoulder, g.buttonMenu].forEach { $0.pressedChangedHandler = nil }
        g.leftThumbstick.valueChangedHandler = nil
    }

    private func hook(_ c: GCController) {
        guard let g = c.extendedGamepad else { return }
        func on(_ e: GCControllerButtonInput, _ b: MCButton, repeats: Bool = false) {
            e.pressedChangedHandler = { [weak self] _, _, pressed in
                guard let self = self, self.attached else { return }
                if pressed { self.fire(b, repeats: repeats) } else if self.held == b { self.stopRepeat() }
            }
        }
        on(g.dpad.up, .up, repeats: true); on(g.dpad.down, .down, repeats: true)
        on(g.dpad.left, .left, repeats: true); on(g.dpad.right, .right, repeats: true)
        on(g.buttonA, .a); on(g.buttonB, .b); on(g.buttonX, .x); on(g.buttonY, .y)
        on(g.leftShoulder, .l); on(g.rightShoulder, .r); on(g.buttonMenu, .menu)
        let key = ObjectIdentifier(c)
        g.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            guard let self = self, self.attached else { return }
            let dir: MCButton? = abs(x) < 0.55 && abs(y) < 0.55 ? nil : (abs(x) > abs(y) ? (x > 0 ? .right : .left) : (y > 0 ? .up : .down))
            if dir == self.stickDir[key] { return }
            self.stickDir[key] = dir
            if let d = dir { self.fire(d, repeats: true) } else { self.stopRepeat() }
        }
    }

    private func fire(_ b: MCButton, repeats: Bool) {
        stopRepeat()
        MCFocus.shared.press(b)
        guard repeats else { return }
        held = b
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: true) { _ in
                guard let self = self, let h = self.held else { return }
                MCFocus.shared.press(h)
            }
        }
    }

    private func stopRepeat() {
        held = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

private struct MCFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Makes a view pickable: it reports its place, shows the ring when focused, presses on tap, opens its menu on a
/// long press.
struct MCFocusable: ViewModifier {
    @ObservedObject var focus = MCFocus.shared
    let id: String
    var scope = "page"
    var corner: CGFloat
    var ring: Color
    var action: () -> Void
    var menu: (() -> Void)?

    func body(content: Content) -> some View {
        let on = focus.padActive && focus.id == id
        focus.register(id, scope: scope, action: action, menu: menu)
        return content
            .scaleEffect(on ? 1.04 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: corner + 7)
                    .stroke(ring, lineWidth: 5)
                    .padding(-7)
                    .opacity(on ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.14), value: on)
            .background(GeometryReader { g in
                Color.clear.preference(key: MCFrameKey.self, value: [id: g.frame(in: .global)])
            })
            .contentShape(Rectangle())
            .onTapGesture { focus.id = id; action() }
            .onLongPressGesture(minimumDuration: 0.45) {
                if let m = menu { focus.id = id; m() }
            }
            .accessibilityAddTraits(.isButton)
    }
}

extension View {
    func mcFocusable(_ id: String, scope: String = "page", corner: CGFloat = 16, ring: Color,
                     menu: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        modifier(MCFocusable(id: id, scope: scope, corner: corner, ring: ring, action: action, menu: menu))
    }

    /// At the root: collects every item's place for the focus.
    func mcCollectFrames() -> some View {
        onPreferenceChange(MCFrameKey.self) { f in
            MCFocus.shared.frames = f
            DispatchQueue.main.async { MCFocus.shared.settle() }
        }
    }
}
