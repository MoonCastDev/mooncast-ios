//
//  MCSettingsCards.swift
//  MoonCast: Settings as one card per device (SettingsCards.kt on the handheld): a card for each paired PC, each PS5,
//  each Xbox and this iPad/iPhone, each showing what's set today; Controllers, TVs, About and Classic settings (the
//  list as it was) are chips below. A card opens tabs: the PC's Fine-tune · Play style · Away from home · Power & wake
//  (it opens on Fine-tune), the consoles' Play style · Fine-tune · …, this device's Screen · Sound · Look.
//  On a narrow screen (an iPhone held upright) the cards and play styles wrap into two columns and Fine-tune stacks.
//

import SwiftUI

/// Where Settings' cards are.
struct MCCardsState {
    /// The Classic list is showing.
    var classic = false
    /// "home" (the cards), "pc:<uuid>" ("pc:any" with no PC paired), "ps:<host>", "xb:<id>", "dev", "pads", "tvs", "about"
    var screen = "home"
    var tab = ""
    /// The card last opened, where focus goes back to on the cards.
    var lastCard: String?
    /// The PC play style whose own page shows (hold or X on its card), on the Play style tab.
    var editing: String?
    /// The PC play style last opened or renamed, where focus goes back to on the style cards.
    var lastStyle: String?
    /// Change icon or Colour on a style's page: "icon", "color" or nil.
    var strip: String?
}

/// Where Fine-tune's value rows read and write: the live settings, or one PC play style's own values.
struct MCVals {
    let get: (String) -> Any?
    let put: (String, Any) -> Void
    func s(_ k: String, _ d: String) -> String { get(k) as? String ?? d }
    func i(_ k: String, _ d: Int) -> Int { (get(k) as? NSNumber)?.intValue ?? d }
    func b(_ k: String) -> Bool { (get(k) as? NSNumber)?.boolValue ?? false }

    static let live = MCVals(get: MCPcStyles.liveValue, put: MCPcStyles.putLive)

    /// A style's values; a key it doesn't set shows what's live (picking the style leaves it as it is).
    static func style(_ st: MCPcStyle) -> MCVals {
        MCVals(get: { k in MCPcStyles.values(st.id)[k] ?? MCPcStyles.liveValue(k) }, put: { k, v in MCPcStyles.putStyle(st.id, k, v) })
    }
}

private struct MCTile {
    let id: String, title: String, state: String, on: Bool, icon: String, color: Color
    let click: () -> Void
    var details: (() -> Void)? = nil
}

extension MCRoot {
    // MARK: state

    func cardKind(_ s: String? = nil) -> String { String((s ?? cards.screen).split(separator: ":").first ?? "") }
    private func cardArg(_ s: String? = nil) -> String {
        let x = s ?? cards.screen
        return x.firstIndex(of: ":").map { String(x[x.index(after: $0)...]) } ?? ""
    }
    private func pcOf(_ s: String? = nil) -> TemporaryHost? { cardKind(s) == "pc" ? store.hosts.first { $0.uuid == cardArg(s) } : nil }
    private func psOf(_ s: String? = nil) -> MCPs5Console? { cardKind(s) == "ps" ? MCPs5Store.list().first { $0.host == cardArg(s) } : nil }
    private func xbOf(_ s: String? = nil) -> MCXbox.Console? { cardKind(s) == "xb" ? MCXbox.consoles.first { $0.id == cardArg(s) } : nil }

    func cardTabs(_ s: String) -> [(String, String)] {
        switch cardKind(s) {
        case "pc": return [("fine", "Fine-tune"), ("play", "Play style"), ("away", "Away from home")] + (pcOf(s) != nil ? [("power", "Power & wake")] : [])
        case "ps": return [("play", "Play style"), ("fine", "Fine-tune"), ("away", "Away from home"), ("power", "Power & sign-in")]
        case "xb": return [("play", "Play style"), ("fine", "Fine-tune"), ("sign", "Sign-in")]
        case "dev": return [("screen", "Screen"), ("sound", "Sound"), ("look", "Look")]
        default: return []
        }
    }

    /// The tab showing (the first when the one saved isn't there).
    var cardTab: String {
        let t = cardTabs(cards.screen)
        return t.contains { $0.0 == cards.tab } ? cards.tab : t.first?.0 ?? ""
    }

    private func refocus() {
        focus.id = nil
        DispatchQueue.main.async { focus.settle() }
    }

    func cardsOpen(_ s: String, tab: String? = nil) {
        if cards.screen == "home" { cards.lastCard = s }
        cards.screen = s
        cards.tab = tab ?? cardTabs(s).first?.0 ?? ""
        cards.editing = nil
        cards.strip = nil
        refocus()
    }

    func cardsShowTab(_ t: String) {
        guard cardTabs(cards.screen).contains(where: { $0.0 == t }) else { return }
        cards.tab = t
        cards.editing = nil
        cards.strip = nil
        refocus()
    }

    /// B: one level up. False on the cards: Settings closes.
    func cardsBack() -> Bool {
        if cards.classic { cards.classic = false; refocus(); return true }
        if let e = cards.editing { cards.lastStyle = e; cards.editing = nil; cards.strip = nil; refocus(); return true }
        if cards.screen != "home" { cards.screen = "home"; cards.tab = ""; refocus(); return true }
        return false
    }

    func cardsShoulder(_ step: Int) {
        let tabs = cardTabs(cards.screen).map { $0.0 }
        guard cards.screen != "home", tabs.count > 1, let i = tabs.firstIndex(of: cardTab) else { return }
        MCFeel.play(.move)
        cardsShowTab(tabs[(i + step + tabs.count) % tabs.count])
    }

    func cardsTitle() -> String {
        if cards.classic { return "Classic settings" }
        switch cardKind() {
        case "home": return "Settings"
        case "pc": return pcOf()?.name ?? "PC"
        case "ps": return psOf()?.name ?? "PlayStation"
        case "xb": return xbOf()?.name ?? "Xbox"
        case "dev": return "This \(MCDevice.name)"
        case "pads": return "Controllers"
        case "tvs": return "TVs"
        case "about": return "About"
        default: return "Settings"
        }
    }

    func cardsHints() -> [(String, String)] {
        var h: [(String, String)] = []
        let home = cards.screen == "home"
        if !home && cardTabs(cards.screen).count > 1 { h.append(("L R", "Tabs")) }
        let pcPlay = cardKind() == "pc" && cardTab == "play"
        if pcPlay && cards.editing != nil { h += [("Y", "Rename"), ("X", "Exact bitrate")] }
        else if pcPlay { h += [("Y", "Rename"), ("Hold A", "Fine-tune")] }
        else if !home && cardTab == "play" { h.append(("X", "Fine-tune")) }
        if !home && cardTab == "fine" {
            if cardKind() == "pc" { h.append(("Y", "Save into a style")) }
            h.append(("X", "Details"))
        }
        h.append(("B", "Back"))
        h.append(("A", home ? "Open" : pcPlay && cards.editing != nil ? "Change" : cardTab == "play" ? "Use" : "OK"))
        return h
    }

    /// X and Y on a card's screen. X on an item with details (a style card, a tile, the bitrate) is its menu.
    func cardsKey(_ b: MCButton) -> Bool {
        guard cards.screen != "home" else { return false }
        let hasMenu = focus.id.map { focus.menus[$0] != nil } ?? false
        if b == .x {
            if hasMenu { return false }
            if cardTab == "play" && cards.editing == nil { cardsShowTab("fine"); return true }
            return false
        }
        guard b == .y, cardKind() == "pc" else { return false }
        if cardTab == "play" {
            let focused = focus.id.flatMap { $0.hasPrefix("style:") ? MCPcStyles.style(String($0.dropFirst(6))) : nil }
            if let st = MCPcStyles.style(cards.editing) ?? focused { renameStyle(st) }
            return true
        }
        if cardTab == "fine" { saveIntoStyle(); return true }
        return false
    }

    /// Test runs: MC_CARD=pc|ps|xb|dev|pads|tvs|about|classic opens a card (pc, ps and xb: the first one),
    /// MC_TAB=finetune|styles|away|power|sign|screen|sound|look a tab, MC_STYLE=battery|balanced|sharpest|fastest a PC
    /// style's own page, MC_STRIP=icon|color its icon or colour strip.
    func cardsTestStart(_ env: [String: String]) {
        #if DEBUG
        if let st = env["MC_STYLE"], MCPcStyles.style(st) != nil {
            cardsOpen(cardKey("pc"), tab: "play")
            cards.editing = st
            cards.strip = env["MC_STRIP"]
            return
        }
        guard let c = env["MC_CARD"] else { return }
        if c == "classic" { cards.classic = true; return }
        let tab: String? = env["MC_TAB"].map { t in
            switch t { case "finetune", "fine-tune", "fine": return "fine"; case "styles", "style", "play": return "play"; default: return t }
        }
        cardsOpen(cardKey(c), tab: tab)
        #endif
    }

    /// The first card of a kind, as Settings lists it.
    private func cardKey(_ k: String) -> String {
        switch k {
        case "pc": return store.hosts.filter { store.paired($0) }.sorted { $0.name.lowercased() < $1.name.lowercased() }.first.map { "pc:\($0.uuid)" } ?? "pc:any"
        case "ps": return MCPs5Store.list().first.map { "ps:\($0.host)" } ?? "dev"
        case "xb": return MCXbox.consoles.first.map { "xb:\($0.id)" } ?? "dev"
        default: return k
        }
    }

    // MARK: pages

    private func narrow(_ m: MCMetrics) -> Bool { m.designWidth < 1100 }

    /// Text on the cyan fill: white on Light, near-black on Dark and OLED.
    private func onRing(_ p: MCPalette) -> Color { p.light ? .white : Color(hex: 0x0B2A30) }

    func cardsPage(_ m: MCMetrics, _ p: MCPalette) -> some View {
        let _ = settingsRev
        if cards.screen == "home" { return AnyView(cardsHome(m, p)) }
        let tabs = cardTabs(cards.screen)
        return AnyView(VStack(alignment: .leading, spacing: m.px(10)) {
            if tabs.count > 1 { tabRow(tabs, m, p) }
            cardBody(m, p).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, m.px(14)))
    }

    private func tabRow(_ tabs: [(String, String)], _ m: MCMetrics, _ p: MCPalette) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: m.px(14)) {
                ForEach(tabs, id: \.0) { id, label in
                    let on = id == cardTab
                    Text(label).mcFont(26, m, weight: .heavy).foregroundColor(on ? onRing(p) : p.ink).lineLimit(1)
                        .padding(.horizontal, m.px(30)).frame(height: max(m.px(64), 40))
                        .background(Capsule().fill(on ? p.ring : p.panel))
                        .mcFocusable("tab:\(id)", corner: m.px(32), ring: p.ring) { if !on { cardsShowTab(id) } }
                }
            }
            .padding(.horizontal, m.px(m.edge)).padding(.vertical, m.px(10))
        }
    }

    @ViewBuilder
    private func cardBody(_ m: MCMetrics, _ p: MCPalette) -> some View {
        let t = cardTab
        switch cardKind() {
        case "pc":
            switch t {
            case "fine": finePage("pc", m, p)
            case "play":
                if let st = MCPcStyles.style(cards.editing) { styleTunePage(st, m, p) } else { playPage("pc", m, p) }
            case "away": cardList(m, p, first: "s:profile") { pcAwayRows(m, p) }
            default: cardList(m, p, first: nil) { pcPowerRows(m, p) }
            }
        case "ps":
            switch t {
            case "play": playPage("ps", m, p)
            case "fine": finePage("ps", m, p)
            case "away": cardList(m, p, first: "s:profile") { psAwayRows(m, p) }
            default: cardList(m, p, first: "s:ps:psn") { psPowerRows(m, p) }
            }
        case "xb":
            switch t {
            case "play": playPage("xb", m, p)
            case "fine": finePage("xb", m, p)
            default: cardList(m, p, first: "s:xb:acct") { xbSignRows(m, p) }
            }
        case "dev":
            cardList(m, p, first: nil) { settingRows(m, p, group: t == "sound" ? "sound" : t == "look" ? "theme" : "ipad") }
        case "pads": cardList(m, p, first: "s:padtest") { settingRows(m, p, group: "pads") }
        case "tvs": cardList(m, p, first: "tv:playon") { tvRows(m, p) }
        default: cardList(m, p, first: "s:ver") { settingRows(m, p, group: "about") }
        }
    }

    /// A scrolling list of rows (the Classic list's rows), as wide as reads well. [first]: where focus starts
    /// (nil: the tab showing).
    private func cardList<C: View>(_ m: MCMetrics, _ p: MCPalette, first: String?, @ViewBuilder _ content: () -> C) -> some View {
        focus.preferred["page"] = first ?? "tab:\(cardTab)"
        let rows = content()
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: m.px(14)) { rows }
                    .frame(maxWidth: m.px(1400), alignment: .leading)
                    .padding(.horizontal, m.px(m.edge)).padding(.top, m.px(8)).padding(.bottom, m.px(30))
            }
            .onChange(of: focus.id) { _, id in if let id = id, !id.hasPrefix("tab:"), focus.padActive { withAnimation { proxy.scrollTo(id) } } }
        }
    }

    // MARK: the cards

    private func cardsHome(_ m: MCMetrics, _ p: MCPalette) -> some View {
        var list: [(String, AnyView)] = []
        let pcs = store.hosts.filter { store.paired($0) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        let gap: CGFloat = 30, e = m.edge
        let isNarrow = narrow(m)
        let count = (pcs.isEmpty ? 1 : pcs.count) + MCPs5Store.list().count + MCXbox.consoles.count + 1
        let per = CGFloat(min(count, 4))
        let cw: CGFloat = isNarrow ? (m.designWidth - 2 * e - gap) / 2 : min(470, max(360, (m.designWidth - 2 * e - gap * (per - 1)) / per))
        let ch: CGFloat = 440
        if pcs.isEmpty { list.append(("pc:any", AnyView(pcCard(nil, cw, ch, m, p)))) }
        pcs.forEach { h in list.append(("pc:\(h.uuid)", AnyView(pcCard(h, cw, ch, m, p)))) }
        MCPs5Store.list().forEach { c in list.append(("ps:\(c.host)", AnyView(psCard(c, cw, ch, m, p)))) }
        MCXbox.consoles.forEach { c in list.append(("xb:\(c.id)", AnyView(xbCard(c, cw, ch, m, p)))) }
        list.append(("dev", AnyView(devCard(cw, ch, m, p))))
        focus.preferred["page"] = "card:" + (list.first { $0.0 == cards.lastCard }?.0 ?? list[0].0)
        let help = "Open a card to change how that device plays. Each card shows what's set today." +
            (pcs.count > 1 ? " Your PCs share one set of PC settings." : "") + " Classic settings is the full list, as before."
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if isNarrow {
                        let rows = stride(from: 0, to: list.count, by: 2).map { Array(list[$0..<min($0 + 2, list.count)]) }
                        VStack(alignment: .leading, spacing: m.px(gap)) {
                            ForEach(rows.indices, id: \.self) { r in
                                HStack(spacing: m.px(gap)) { ForEach(rows[r], id: \.0) { $0.1 } }
                            }
                        }
                        .padding(.horizontal, m.px(e))
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: m.px(gap)) { ForEach(list, id: \.0) { $0.1 } }
                                .padding(.horizontal, m.px(e)).padding(.vertical, m.px(12))
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: m.px(18)) {
                            ForEach([("pads", "Controllers"), ("tvs", "TVs"), ("about", "About"), ("classic", "Classic settings")], id: \.0) { k, label in
                                chip("chip:\(k)", label, m, p) {
                                    if k == "classic" { cards.classic = true; refocus() } else { cardsOpen(k) }
                                }
                            }
                        }
                        .padding(.horizontal, m.px(e)).padding(.vertical, m.px(10))
                    }
                    .padding(.top, m.px(14))
                    Text(help).mcFont(24, m, weight: .semibold).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, m.px(e)).padding(.top, m.px(18)).padding(.bottom, m.px(30))
                }
                .padding(.top, m.px(isNarrow ? 16 : 30))
            }
            .onChange(of: focus.id) { _, id in if let id = id, id.hasPrefix("card:"), focus.padActive { withAnimation { proxy.scrollTo(id) } } }
        }
    }

    private func chip(_ id: String, _ label: String, main: Bool = false, _ m: MCMetrics, _ p: MCPalette, action: @escaping () -> Void) -> some View {
        Text(label).mcFont(26, m, weight: .heavy).foregroundColor(main ? p.bg : p.ink).lineLimit(1)
            .padding(.horizontal, m.px(30)).frame(height: max(m.px(64), 40))
            .background(Capsule().fill(main ? p.ink : p.panel))
            .id(id)
            .mcFocusable(id, corner: m.px(32), ring: p.ring, action: action)
    }

    private func deviceCard(_ key: String, badge: String, name: String, art: AnyView, lines: [(String, Bool)], foot: String, footRing: Bool,
                            _ w: CGFloat, _ h: CGFloat, _ m: MCMetrics, _ p: MCPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                art
                Text(badge).font(.system(size: m.px(20), weight: .heavy)).foregroundColor(.white)
                    .padding(.horizontal, m.px(14)).frame(height: m.px(40))
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                    .padding(.leading, m.px(22)).padding(.top, m.px(20))
                Text(name).font(.system(size: m.px(36), weight: .heavy)).foregroundColor(.white).lineLimit(1)
                    .shadow(color: .black.opacity(0.35), radius: m.px(5), y: m.px(2))
                    .padding(.horizontal, m.px(26)).padding(.bottom, m.px(22))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: m.px(160)).clipped()
            VStack(alignment: .leading, spacing: m.px(10)) {
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i].0).mcFont(25, m, weight: lines[i].1 ? .bold : .semibold).foregroundColor(lines[i].1 ? p.ink : p.sub).lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(foot.uppercased()).mcFont(20, m, weight: .heavy).foregroundColor(footRing ? p.ring : p.sub).lineLimit(1)
            }
            .padding(.horizontal, m.px(26)).padding(.vertical, m.px(22))
        }
        .frame(width: m.px(w), height: m.px(h))
        .background(RoundedRectangle(cornerRadius: m.px(24), style: .continuous).fill(p.panel))
        .clipShape(RoundedRectangle(cornerRadius: m.px(24), style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: m.px(8), y: m.px(4))
        .id("card:\(key)")
        .mcFocusable("card:\(key)", corner: m.px(24), ring: p.ring) { cardsOpen(key) }
        .accessibilityLabel(name)
    }

    private func shapeLabel(_ v: String) -> String { ["zoom": "Zoom", "fill": "Fill", "stretch": "Stretch", "same": "Same as PC"][v] ?? "Fit" }

    private func pcCard(_ h: TemporaryHost?, _ w: CGFloat, _ ht: CGFloat, _ m: MCMetrics, _ p: MCPalette) -> some View {
        let v = settings.load()
        let fps = MCSettings.nativeFps ? MCSettings.nativeHz : v.framerate
        let auto = v.bitrate == MCRoot.defaultBitrate(v.width, v.height, v.framerate)
        return deviceCard(h.map { "pc:\($0.uuid)" } ?? "pc:any", badge: "PC", name: h?.name ?? "PC games",
                          art: AnyView(CoverArt(colors: Covers.colors(h?.name ?? "PC"))),
                          lines: [("\(min(v.width, v.height))p · \(fps) fps", true),
                                  ("\(auto ? "Auto bitrate" : MCPcStyles.mbps(v.bitrate)) · \(MCPcStyles.codecLabel(Int(v.codec)))", true),
                                  ("HDR \(v.hdr ? "on" : "off") · \(shapeLabel(MCPictureShape.current))", false),
                                  (MCPcStyles.nowLabel(), false)],
                          foot: "Profile: \(MCSettings.profileName(MCSettings.profile))", footRing: true, w, ht, m, p)
    }

    private func psCard(_ c: MCPs5Console, _ w: CGFloat, _ h: CGFloat, _ m: MCMetrics, _ p: MCPalette) -> some View {
        let away = MCSettings.profile == "away"
        let d = UserDefaults.standard
        let rate = away ? MCPs5Store.awayBitrate : MCPs5Store.bitrate
        var own: [String] = []
        if let s = d.string(forKey: "ps5_picture_shape"), s != "same" { own.append(shapeLabel(s)) }
        if let f = d.string(forKey: "ps5_super_resolution"), f != "same" { own.append(f == "fsr1" ? "FSR" : "no FSR") }
        return deviceCard("ps:\(c.host)", badge: "PS5", name: c.name, art: AnyView(CoverArt(colors: Covers.colors("ps"))),
                          lines: [("\(away ? "Away: \(MCPs5Store.awayHeight)p" : "\(MCPs5Store.height)p") · \(MCPs5Store.fps) fps", true),
                                  ("\(rate == 0 ? "Auto bitrate" : "\(rate) Mbps") · \(MCPs5Store.h265 ? "HEVC" : "H.264")", true),
                                  (own.isEmpty ? "Picture same as PC" : "Own picture: " + own.joined(separator: " · "), false),
                                  (["rest": "Rest mode on exit", "keep": "Stays on after a game"][MCPs5Store.onDisconnect] ?? "Asks on exit", false)],
                          foot: MCPsn.signedIn ? "Signed in · PSN" : "PSN: not signed in", footRing: false, w, h, m, p)
    }

    private func xbPictureLabel(_ r: Int) -> String { [720: "720p picture", 1080: "1080p picture", 1081: "1080p high picture"][r] ?? "Auto picture" }

    private func xbCard(_ c: MCXbox.Console, _ w: CGFloat, _ h: CGFloat, _ m: MCMetrics, _ p: MCPalette) -> some View {
        let br = MCXbox.maxMbps
        return deviceCard("xb:\(c.id)", badge: "Xbox", name: c.name, art: AnyView(CoverArt(colors: Covers.colors("xb"))),
                          lines: [(xbPictureLabel(MCXbox.resolution), true), (br == 0 ? "Auto bitrate" : "Up to \(br) Mbps", true),
                                  ("Rumble \(UserDefaults.standard.string(forKey: "xbox_rumble") ?? "strong")", false),
                                  ("Swap A/B \(MCXbox.swapAB ? "on" : "off")", false)],
                          foot: !MCXbox.signedIn ? "Xbox: not signed in" : MCXbox.gamertag == nil ? "No Xbox profile" : "Signed in · Xbox",
                          footRing: false, w, h, m, p)
    }

    private func devCard(_ w: CGFloat, _ h: CGFloat, _ m: MCMetrics, _ p: MCPalette) -> some View {
        let d = UserDefaults.standard
        let touch = ["mouse": "Mouse", "off": "Touch off"][d.string(forKey: "mc_touch_default") ?? "touch"] ?? "Touch"
        let size = ["compact": "Compact", "normal": "Normal", "large": "Large"][screenSize] ?? "Auto"
        return deviceCard("dev", badge: MCDevice.name, name: "This \(MCDevice.name)",
                          art: AnyView(CoverArt(colors: [Color(hex: 0xB9C0CC), Color(hex: 0x8A9099), Color(hex: 0x3A3F47)])),
                          lines: [("\(["light": "Light", "oled": "OLED"][theme] ?? "Dark") theme", true),
                                  ("\(touch) · PiP \(d.bool(forKey: "mc_pip") ? "on" : "off")", false),
                                  ("Menu sounds \(MCFeel.enabled ? "on" : "off")", false),
                                  ("Screen size: \(size)", false)],
                          foot: "Screen · Sound · Look", footRing: false, w, h, m, p)
    }

    // MARK: Play style

    private func styleCard(_ id: String, icon: String, color: Color, name: String, lines: [String], note: String, inUse: Bool,
                           _ w: CGFloat, _ h: CGFloat, _ m: MCMetrics, _ p: MCPalette, hold: (() -> Void)?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            iconBox(icon, color, 76, m)
            Text(name).mcFont(32, m, weight: .heavy).foregroundColor(p.ink).lineLimit(1).padding(.top, m.px(20))
            ForEach(lines.indices, id: \.self) { i in
                Text(lines[i]).mcFont(22, m, weight: .semibold).foregroundColor(p.sub).lineLimit(2).padding(.top, m.px(i == 0 ? 10 : 6))
            }
            Spacer(minLength: 0)
            Text(inUse ? note.uppercased() : note).mcFont(20, m, weight: inUse ? .heavy : .semibold).foregroundColor(inUse ? p.ring : p.sub).lineLimit(2)
        }
        .padding(.leading, m.px(26)).padding(.trailing, m.px(22)).padding(.vertical, m.px(23))
        .frame(width: m.px(w), height: m.px(h), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: m.px(24), style: .continuous).fill(p.panel))
        .id("style:\(id)")
        .mcFocusable("style:\(id)", corner: m.px(24), ring: p.ring, menu: hold, hold: hold != nil, action: action)
        .accessibilityLabel(name)
    }

    private func iconBox(_ icon: String, _ color: Color, _ size: CGFloat, _ m: MCMetrics) -> some View {
        Image(systemName: MCPcStyles.symbol(icon)).font(.system(size: m.px(size * 0.4), weight: .semibold)).foregroundColor(color)
            .frame(width: m.px(size), height: m.px(size))
            .background(RoundedRectangle(cornerRadius: m.px(18)).fill(color.opacity(0.18)))
    }

    private func playPage(_ k: String, _ m: MCMetrics, _ p: MCPalette) -> some View {
        struct Card { let id: String, icon: String, color: Color, name: String, lines: [String], note: String, inUse: Bool
            let use: () -> Void; let hold: (() -> Void)? }
        var list: [Card] = []
        let nowName: String
        if k == "pc" {
            let picked = MCPcStyles.picked()
            let exact = MCPcStyles.matches(picked.id)
            nowName = MCPcStyles.name(picked) + (exact ? "" : " (changed)")
            for st in MCPcStyles.all {
                let inUse = st.id == picked.id
                // no taglines on the PC's cards: their values say it
                list.append(Card(id: st.id, icon: MCPcStyles.icon(st), color: MCPcStyles.color(st, p), name: MCPcStyles.name(st),
                                 lines: MCPcStyles.lines(st), note: inUse ? (exact ? "✓ In use" : "✓ In use, changed") : "", inUse: inUse,
                                 use: { usePcStyle(st) }, hold: { editStyle(st) }))
            }
        } else {
            let now = MCConsoleStyle.detect(k)
            let near = now == nil ? MCConsoleStyle.nearest(k) : nil
            nowName = now?.name ?? "\(near!.name) (changed)"
            for s in MCConsoleStyle.list(k) {
                let inUse = s.id == now?.id
                let nearOne = s.id == near?.id
                list.append(Card(id: s.id, icon: s.icon, color: s.color.map { Color(hex: $0) } ?? p.ring, name: s.name, lines: [s.l1, s.l2],
                                 note: inUse ? "✓ In use" : nearOne ? "✓ In use, changed" : s.note, inUse: inUse || nearOne,
                                 use: { s.use(k); MCToast.show("\(s.name): \(s.l1) · \(s.l2)"); settingsRev += 1 }, hold: nil))
            }
        }
        let what = ["pc": "PC", "ps": "PS5"][k] ?? "Xbox"
        var sub = (k == "pc" ? "Pick one. Hold it (or X) to fine-tune it, Y renames it. Now: " : "Pick one. Everything else follows; you can still fine-tune it. Now: ") + nowName
        if MCSettings.profile == "away" { sub += k == "ps" ? ". The Away profile is on: Away from home sets what the PS5 uses" : ", in the Away profile" }
        if k == "pc" && store.hosts.filter({ store.paired($0) }).count > 1 { sub += ". Shared by all your PCs" }
        if k == "ps" { sub += ". Picture shape and Super resolution stay the same as the PC until you change them" }
        sub += "."
        let gap: CGFloat = 24, e = m.edge
        let isNarrow = narrow(m)
        let n = CGFloat(k == "pc" ? list.count : list.count + 1)
        let cw: CGFloat = isNarrow ? (m.designWidth - 2 * e - gap) / 2 : max(300, (m.designWidth - 2 * e - gap * (n - 1)) / n)
        let ch: CGFloat = 320
        let focusOn = list.first { $0.id == cards.lastStyle && k == "pc" } ?? list.first { $0.inUse } ?? list.first
        focus.preferred["page"] = focusOn.map { "style:\($0.id)" }
        let cardViews = list.map { c in
            AnyView(styleCard(c.id, icon: c.icon, color: c.color, name: c.name, lines: c.lines, note: c.note, inUse: c.inUse, cw, ch, m, p,
                              hold: c.hold, action: c.use))
        }
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("How should \(what) games play?").mcFont(34, m, weight: .heavy).foregroundColor(p.ink)
                    .padding(.horizontal, m.px(e)).padding(.top, m.px(16))
                Text(sub).mcFont(23, m, weight: .semibold).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, m.px(e)).padding(.top, m.px(8))
                Group {
                    if isNarrow {
                        let rows = stride(from: 0, to: cardViews.count, by: 2).map { Array(cardViews.indices[$0..<min($0 + 2, cardViews.count)]) }
                        VStack(alignment: .leading, spacing: m.px(gap)) {
                            ForEach(rows.indices, id: \.self) { r in HStack(spacing: m.px(gap)) { ForEach(rows[r], id: \.self) { cardViews[$0] } } }
                        }
                        .padding(.horizontal, m.px(e))
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: m.px(gap)) { ForEach(cardViews.indices, id: \.self) { cardViews[$0] } }
                                .padding(.horizontal, m.px(e)).padding(.vertical, m.px(12))
                        }
                    }
                }
                .padding(.top, m.px(22))
                alsoRow(k, nowName, m, p).padding(.top, m.px(26)).padding(.bottom, m.px(30))
            }
        }
    }

    /// Also: the few things people change without opening Fine-tune.
    private func alsoRow(_ k: String, _ nowName: String, _ m: MCMetrics, _ p: MCPalette) -> some View {
        let d = UserDefaults.standard
        func cycle(_ key: String, _ values: [String], _ cur: String) {
            d.set(values[((values.firstIndex(of: cur) ?? -1) + 1) % values.count], forKey: key)
            settingsRev += 1
        }
        var chips: [(String, String, () -> Void)] = []
        switch k {
        case "pc":
            let shape = MCPictureShape.current
            chips.append(("chip:shape", "Picture shape · \(shapeLabel(shape))", { cycle("mc_picture_shape", ["fit", "zoom", "fill", "stretch"], shape) }))
            chips.append(("chip:stats", "Stats · \(MCStatsLevel.label(MCStatsLevel.current))", { MCStatsLevel.cycle(); settingsRev += 1 }))
        case "ps":
            let shape = d.string(forKey: "ps5_picture_shape") ?? "same"
            chips.append(("chip:shape", "Picture shape · \(shapeLabel(shape))", { cycle("ps5_picture_shape", ["same", "fit", "zoom", "fill", "stretch"], shape) }))
            let exit = MCPs5Store.onDisconnect
            chips.append(("chip:exit", "On exit · \(["rest": "Rest mode", "keep": "Keep it on"][exit] ?? "Ask")", { cycle("ps5_on_disconnect", ["ask", "rest", "keep"], exit) }))
        default:
            let shape = d.string(forKey: "xbox_picture_shape") ?? "same"
            chips.append(("chip:shape", "Picture shape · \(shapeLabel(shape))", { cycle("xbox_picture_shape", ["same", "fit", "zoom", "fill", "stretch"], shape) }))
            let r = d.string(forKey: "xbox_rumble") ?? "strong"
            chips.append(("chip:rumble", "Rumble · \(r.capitalized)", { cycle("xbox_rumble", ["off", "weak", "medium", "strong"], r) }))
        }
        // Home / Away: the same switch as Streaming profile
        chips.append(("chip:profile", "Home / Away · \(MCSettings.profileName(MCSettings.profile))", {
            settings.switchProfile(to: MCSettings.profile == "away" ? "home" : "away"); settingsRev += 1
        }))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: m.px(16)) {
                Text("Also:").mcFont(24, m).foregroundColor(p.sub).padding(.trailing, m.px(4))
                ForEach(chips, id: \.0) { id, label, run in chip(id, label, m, p, action: run) }
                chip("chip:fine", "Fine-tune \(nowName.replacingOccurrences(of: " (changed)", with: ""))…", main: true, m, p) { cardsShowTab("fine") }
            }
            .padding(.horizontal, m.px(m.edge)).padding(.vertical, m.px(10))
        }
    }

    private func usePcStyle(_ st: MCPcStyle) {
        MCPcStyles.use(st)
        let l = MCPcStyles.lines(st)
        MCToast.show("\(MCPcStyles.name(st)): \(l[0]) · \(l[1])")
        settingsRev += 1
    }

    private func editStyle(_ st: MCPcStyle) {
        cards.editing = st.id
        cards.lastStyle = st.id
        cards.strip = nil
        refocus()
    }

    private func renameStyle(_ st: MCPcStyle) {
        cards.lastStyle = st.id
        askText("Rename \(MCPcStyles.name(st))", "A name, up to 24 letters (empty: \(st.defName))") { n in
            MCPcStyles.rename(st, n)
            settingsRev += 1
        }
    }

    /// Y on the PC's Fine-tune: what's set now becomes one style's own values, and the style in use.
    private func saveIntoStyle() {
        store.dialog = MCDialog(title: "Save into a style", message: "The play style you pick takes the PC settings in use now, and becomes the one in use.",
                                opts: [.init(title: "Cancel", picked: true) {}] + MCPcStyles.all.map { st in
                                    .init(title: MCPcStyles.name(st), sub: "Its values become what's set now") {
                                        MCPcStyles.saveInto(st)
                                        cards.lastStyle = st.id
                                        MCToast.show("Saved into \(MCPcStyles.name(st))")
                                        settingsRev += 1
                                    }
                                })
    }

    /// A PC style's own page (hold, long touch or X on its card): its icon and name, Rename, Change icon and Colour,
    /// then its values (the live settings change too while it's in use) and Reset to default.
    private func styleTunePage(_ st: MCPcStyle, _ m: MCMetrics, _ p: MCPalette) -> some View {
        let inUse = MCPcStyles.inUseId == st.id
        let icon = MCPcStyles.icon(st)
        let color = MCPcStyles.color(st, p)
        let strip = cards.strip
        let curColor = MCPcStyles.colorName(st) ?? MCPcStyles.colors.first { $0.1 == st.color }?.0 ?? "cyan"
        focus.preferred["page"] = strip == "icon" ? "icon:\(icon)" : strip == "color" ? "color:\(curColor)" : "set:res"
        let vals = MCVals.style(st)
        var rows = pcValueRows(vals, style: st, m, p)
        rows.append(AnyView(vrow("reset", "Reset to default", "", m, p) {
            confirm("Reset \(MCPcStyles.name(st))?", "Values, icon and colour go back to the start. The name stays.", yes: "Reset") {
                MCPcStyles.reset(st)
                MCToast.show("\(MCPcStyles.name(st)) is back to its first values")
                settingsRev += 1
            }
        }))
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: m.px(22)) {
                        iconBox(icon, color, 76, m)
                        VStack(alignment: .leading, spacing: m.px(4)) {
                            Text(MCPcStyles.name(st)).mcFont(34, m, weight: .heavy).foregroundColor(p.ink).lineLimit(1)
                            Text("FINE-TUNE").mcFont(18, m, weight: .heavy).foregroundColor(p.sub)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: m.px(16)) {
                            chip("style:rename", "Rename", m, p) { renameStyle(st) }
                            chip("style:icon", strip == "icon" ? "Close icons" : "Change icon", m, p) {
                                cards.strip = strip == "icon" ? nil : "icon"; refocus()
                            }
                            chip("style:color", strip == "color" ? "Close colours" : "Colour", m, p) {
                                cards.strip = strip == "color" ? nil : "color"; refocus()
                            }
                        }
                        .padding(.vertical, m.px(10)).padding(.horizontal, m.px(4))
                    }
                    .padding(.top, m.px(12))
                    if let which = strip {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: m.px(14)) {
                                if which == "icon" {
                                    ForEach(MCPcStyles.icons, id: \.0) { k, sym, label in
                                        let on = k == icon
                                        Image(systemName: sym).font(.system(size: m.px(40), weight: .semibold)).foregroundColor(on ? onRing(p) : color)
                                            .frame(width: m.px(96), height: m.px(96))
                                            .background(RoundedRectangle(cornerRadius: m.px(18)).fill(on ? p.ring : p.panel))
                                            .mcFocusable("icon:\(k)", corner: m.px(18), ring: p.ring) {
                                                MCPcStyles.setIcon(st, k); cards.strip = nil; settingsRev += 1; refocus()
                                            }
                                            .accessibilityLabel(label)
                                    }
                                } else {
                                    ForEach(MCPcStyles.colors, id: \.0) { n, hex in
                                        let c = hex.map { Color(hex: $0) } ?? p.ring
                                        Image(systemName: MCPcStyles.symbol(icon)).font(.system(size: m.px(40), weight: .semibold)).foregroundColor(c)
                                            .frame(width: m.px(96), height: m.px(96))
                                            .background(RoundedRectangle(cornerRadius: m.px(18)).fill(c.opacity(0.18)))
                                            .overlay(RoundedRectangle(cornerRadius: m.px(18)).stroke(p.ink, lineWidth: n == curColor ? m.px(4) : 0))
                                            .mcFocusable("color:\(n)", corner: m.px(18), ring: p.ring) {
                                                MCPcStyles.setColor(st, n); cards.strip = nil; settingsRev += 1; refocus()
                                            }
                                            .accessibilityLabel(n.capitalized)
                                    }
                                }
                            }
                            .padding(.vertical, m.px(10)).padding(.horizontal, m.px(4))
                        }
                        .padding(.top, m.px(8))
                    }
                    Text((inUse ? "In use: changes apply now." : "Its own values. Picking it uses them.") + " B goes back.")
                        .mcFont(23, m, weight: .semibold).foregroundColor(p.sub).padding(.vertical, m.px(18))
                    valuePanel(rows, m, p)
                }
                .frame(maxWidth: m.px(1400), alignment: .leading)
                .padding(.horizontal, m.px(m.edge)).padding(.top, m.px(14)).padding(.bottom, m.px(30))
            }
            .onChange(of: focus.id) { _, id in if let id = id, id.hasPrefix("set:"), focus.padActive { withAnimation { proxy.scrollTo(id) } } }
        }
    }

    // MARK: Fine-tune

    private func onOff(_ b: Bool) -> String { b ? "On" : "Off" }

    private func finePage(_ k: String, _ m: MCMetrics, _ p: MCPalette) -> some View {
        let tiles = k == "pc" ? pcTiles() : k == "ps" ? consoleTiles("ps5") : consoleTiles("xbox")
        let rows: [AnyView] = k == "pc" ? pcValueRows(.live, style: nil, m, p) : k == "ps" ? psValueRows(m, p) : xbValueRows(m, p)
        let e = m.edge
        let isNarrow = narrow(m)
        let avail = m.designWidth - 2 * e
        let rightW = isNarrow ? avail : min(680, max(480, avail * 0.36))
        let leftW = isNarrow ? avail : avail - rightW - 40
        let gap: CGFloat = 22
        let cols = isNarrow ? 2 : min(4, max(2, Int((leftW + gap) / (230 + gap))))
        let tw = (leftW - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let th: CGFloat = 176
        focus.preferred["page"] = tiles.first.map { "tile:\($0.id)" }
        let withDetails = tiles.filter { $0.details != nil }.map { $0.title }.joined(separator: ", ")
        let note = "Now: \(k == "pc" ? MCPcStyles.nowLabel() : MCConsoleStyle.nowLabel(k)). Changing anything here makes it \"(changed)\"" +
            (k == "pc" ? "; Y saves it into one of the play styles." : ".") + (withDetails.isEmpty ? "" : " X on \(withDetails) shows more.") +
            (k == "pc" ? " Every other option is in Classic settings." : "")
        let grid = VStack(alignment: .leading, spacing: m.px(gap)) {
            let tr = stride(from: 0, to: tiles.count, by: cols).map { Array(tiles[$0..<min($0 + cols, tiles.count)]) }
            ForEach(tr.indices, id: \.self) { r in
                HStack(spacing: m.px(gap)) { ForEach(tr[r], id: \.id) { tileView($0, tw, th, m, p) } }
            }
            Text(note).mcFont(22, m, weight: .semibold).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
                .frame(width: m.px(leftW), alignment: .leading)
        }
        if isNarrow {
            return AnyView(ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: m.px(24)) {
                        grid
                        valuePanel(rows, m, p)
                    }
                    .padding(.horizontal, m.px(e)).padding(.top, m.px(16)).padding(.bottom, m.px(30))
                }
                .onChange(of: focus.id) { _, id in if let id = id, id.hasPrefix("set:") || id.hasPrefix("tile:"), focus.padActive { withAnimation { proxy.scrollTo(id) } } }
            })
        }
        return AnyView(HStack(alignment: .top, spacing: m.px(40)) {
            ScrollView(.vertical, showsIndicators: false) {
                grid.padding(.top, m.px(16)).padding(.bottom, m.px(30))
            }
            .frame(width: m.px(leftW))
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    valuePanel(rows, m, p).padding(.top, m.px(16)).padding(.bottom, m.px(30))
                }
                .onChange(of: focus.id) { _, id in if let id = id, id.hasPrefix("set:"), focus.padActive { withAnimation { proxy.scrollTo(id) } } }
            }
            .frame(width: m.px(rightW))
        }
        .padding(.horizontal, m.px(e)))
    }

    private func tileView(_ t: MCTile, _ w: CGFloat, _ h: CGFloat, _ m: MCMetrics, _ p: MCPalette) -> some View {
        let fg = t.on ? onRing(p) : p.ink
        return VStack(alignment: .leading, spacing: 0) {
            Image(systemName: t.icon).font(.system(size: m.px(34), weight: .semibold)).foregroundColor(t.on ? fg : t.color)
                .frame(height: m.px(42))
            Spacer(minLength: 0)
            Text(t.title).mcFont(25, m, weight: .heavy).foregroundColor(fg).lineLimit(2)
            Text(t.state).mcFont(20, m, weight: .semibold).foregroundColor(t.on ? fg : p.sub).lineLimit(2).padding(.top, m.px(4))
        }
        .padding(.leading, m.px(22)).padding(.trailing, m.px(18)).padding(.vertical, m.px(19))
        .frame(width: m.px(w), height: m.px(h), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: m.px(24), style: .continuous).fill(t.on ? p.ring : p.panel))
        .id("tile:\(t.id)")
        .mcFocusable("tile:\(t.id)", corner: m.px(24), ring: p.ring, menu: t.details, action: t.click)
        .accessibilityLabel("\(t.title), \(t.state)")
    }

    private func flip(_ key: String, _ def: Bool = false) {
        let d = UserDefaults.standard
        d.set(!(d.object(forKey: key) as? Bool ?? def), forKey: key)
        settingsRev += 1
    }

    private func pcTiles() -> [MCTile] {
        let v = settings.load(), d = UserDefaults.standard
        var t: [MCTile] = []
        t.append(MCTile(id: "hdr", title: "HDR", state: onOff(v.hdr) + (MCPcStyles.screenHdr ? "" : " · screen can't"), on: v.hdr, icon: "sun.max",
                        color: Color(hex: MCPcStyles.orange), click: { settings.save { $0.hdr.toggle() }; settingsRev += 1 }))
        // YUV 4:4:4 has no tile: it's gone on iOS (PyroWave's on Android)
        let ull = d.bool(forKey: "mc_ultra_low_latency")
        t.append(MCTile(id: "ull", title: "Ultra low latency", state: onOff(ull), on: ull, icon: "bolt", color: MCPalette.cyan,
                        click: { flip("mc_ultra_low_latency") }))
        let fsr = d.string(forKey: "mc_super_resolution") == "fsr1"
        let sharp = d.object(forKey: "mc_fsr_sharpness") as? Int ?? 60
        t.append(MCTile(id: "fsr", title: "Super resolution",
                        state: MCSettings.nativeOn ? onOff(fsr) + " · no effect at Native" : fsr ? "On · \(sharp)% sharp" : "Off · for lower resolutions",
                        on: fsr, icon: "sparkles", color: Color(hex: MCPcStyles.orange),
                        click: { d.set(fsr ? "off" : "fsr1", forKey: "mc_super_resolution"); settingsRev += 1 },
                        details: { sharpening("mc_fsr_sharpness", same: false) }))
        let range = d.bool(forKey: "mc_full_range")
        t.append(MCTile(id: "range", title: "Full range", state: onOff(range), on: range, icon: "circle.lefthalf.filled", color: MCPalette.green,
                        click: { flip("mc_full_range") }))
        let pip = d.bool(forKey: "mc_pip")
        t.append(MCTile(id: "pip", title: "Picture in picture", state: onOff(pip), on: pip, icon: "pip", color: MCPalette.blue, click: { flip("mc_pip") }))
        let lvl = MCStatsLevel.current
        t.append(MCTile(id: "stats", title: "Stats", state: MCStatsLevel.label(lvl), on: lvl != "off", icon: "waveform.path.ecg", color: MCPalette.red,
                        click: { MCStatsLevel.cycle(); settingsRev += 1 }))
        return t
    }

    /// "ps5" or "xbox".
    private func consoleTiles(_ kind: String) -> [MCTile] {
        let d = UserDefaults.standard
        let v = d.string(forKey: "\(kind)_super_resolution") ?? "same"
        let on = MCFsr.enabled(kind)
        var t = [MCTile(id: "fsr", title: "Super resolution", state: v == "fsr1" ? "On" : v == "off" ? "Off" : "Same as PC (\(onOff(on).lowercased()))",
                        on: on, icon: "sparkles", color: Color(hex: MCPcStyles.orange),
                        click: { d.set(["same": "off", "off": "fsr1"][v] ?? "same", forKey: "\(kind)_super_resolution"); settingsRev += 1 },
                        details: { sharpening("\(kind)_fsr_sharpness", same: true) })]
        if kind == "ps5" {
            let swap = MCPs5Store.swapCrossCircle
            t.append(MCTile(id: "swap", title: "Swap Cross and Circle", state: onOff(swap) + " · Japanese layout", on: swap, icon: "arrow.left.arrow.right",
                            color: MCPalette.blue, click: { flip("ps5_swap_cross_circle") }))
        } else {
            let swap = MCXbox.swapAB, coop = MCXbox.coop
            t.append(MCTile(id: "swap", title: "Swap A and B", state: onOff(swap) + " · Nintendo-style", on: swap, icon: "arrow.left.arrow.right",
                            color: MCPalette.green, click: { flip("xbox_swap_ab") }))
            t.append(MCTile(id: "coop", title: "Two players", state: onOff(coop), on: coop, icon: "person.2", color: MCPalette.blue, click: { flip("xbox_coop") }))
        }
        return t
    }

    /// Super resolution's details: how sharp. [same] adds "Same as PC" for a console's own setting.
    private func sharpening(_ key: String, same: Bool) {
        let d = UserDefaults.standard
        let steps = (same ? [-1] : []) + [0, 20, 40, 60, 80, 100]
        let cur = d.object(forKey: key) as? Int ?? (same ? -1 : 60)
        pick("Sharpening", "How crisp Super resolution makes edges. Lower it if you see halos.", steps.map { $0 < 0 ? "Same as PC" : "\($0)%" },
             steps.firstIndex(of: cur) ?? -1) { i in
            if steps[i] < 0 { d.removeObject(forKey: key) } else { d.set(steps[i], forKey: key) }
        }
    }

    /// A list of choices in a dialog, the one in use picked; picking one saves it.
    private func pick(_ title: String, _ body: String?, _ opts: [String], _ cur: Int, _ onPick: @escaping (Int) -> Void) {
        store.dialog = MCDialog(title: title, message: body, opts: opts.enumerated().map { i, o in
            .init(title: o + (i == cur ? "  ✓" : ""), picked: i == cur || (cur < 0 && i == 0)) { onPick(i); settingsRev += 1 }
        })
    }

    /// The value rows sit in one panel with a line between each.
    private func valuePanel(_ rows: [AnyView], _ m: MCMetrics, _ p: MCPalette) -> some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                if i > 0 { Rectangle().fill(p.line).frame(height: 1).padding(.horizontal, m.px(26)) }
                rows[i]
            }
        }
        .padding(.vertical, m.px(6))
        .background(RoundedRectangle(cornerRadius: m.px(24), style: .continuous).fill(p.panel))
    }

    /// A value row: its name on the left, its value on the right, an optional line under them; A opens its choices.
    private func vrow(_ key: String, _ title: String, _ value: String, sub: String? = nil, _ m: MCMetrics, _ p: MCPalette,
                      action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: m.px(10)) {
            HStack(spacing: m.px(20)) {
                Text(title).mcFont(28, m).foregroundColor(p.ink).lineLimit(1)
                Spacer(minLength: m.px(10))
                Text(value).mcFont(28, m, weight: .heavy).foregroundColor(p.ring).lineLimit(1).minimumScaleFactor(0.7)
            }
            if let s = sub { Text(s).mcFont(22, m, weight: .semibold).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, m.px(26)).padding(.vertical, m.px(22))
        .frame(maxWidth: .infinity, minHeight: max(m.px(92), 48), alignment: .leading)
        .id("set:\(key)")
        .mcFocusable("set:\(key)", corner: m.px(16), ring: p.ring, action: action)
    }

    private func fsrLine(_ atNative: Bool) -> String { atNative ? "No effect at Native resolution." : "Sharpens a lower resolution to fit this screen." }

    /// The PC's value rows over [v]: the live settings (Fine-tune), or a play style's own values ([style]'s page,
    /// which adds HDR, Super resolution, Sharpening, Full range and Ultra low latency).
    private func pcValueRows(_ v: MCVals, style: MCPcStyle?, _ m: MCMetrics, _ p: MCPalette) -> [AnyView] {
        var rows: [AnyView] = []
        let native = MCSettings.native
        let nativeS = "\(native.0)x\(native.1)"
        // Native first, then the fixed sizes, then Custom… (any width × height)
        let steps = [("720p", "1280x720"), ("1080p", "1920x1080"), ("1440p", "2560x1440"), ("4K", "3840x2160")].filter { $0.1 != nativeS }
        let resOpts = [("Native", "native")] + steps
        let res = v.s("res", "native")
        let customRes = !resOpts.contains { $0.1 == res }
        rows.append(AnyView(vrow("res", "Resolution", customRes ? "\(res.replacingOccurrences(of: "x", with: " × ")) (custom)" : resOpts.first { $0.1 == res }!.0, m, p) {
            let line = MCRoot.nativeLine(native)
            pick("Resolution", line, resOpts.map { $0.0 } + ["Custom…"], customRes ? resOpts.count : resOpts.firstIndex { $0.1 == res } ?? 0) { i in
                if i < resOpts.count { v.put("res", resOpts[i].1); return }
                askText("Custom resolution", "Width × height, like 1600x900") { raw in
                    let n = raw.lowercased().replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: " ", with: "")
                        .split(separator: "x").compactMap { Int($0) }
                    guard n.count == 2, n.allSatisfy({ (256...7680).contains($0) && $0 % 2 == 0 }) else {
                        store.dialog = MCDialog(title: "Two even numbers", message: "From 256 to 7680, like 1600x900.", opts: [.init(title: "OK") {}])
                        return
                    }
                    v.put("res", "\(max(n[0], n[1]))x\(min(n[0], n[1]))")
                    settingsRev += 1
                }
            }
        }))
        // frame rate: Native (this screen's refresh rate), the steps, then Custom…
        let hz = MCSettings.nativeHz
        let fpsSteps = [30, 60, 90, 120].filter { $0 <= hz }.map { "\($0)" }
        let fps = v.s("fps", "native")
        rows.append(AnyView(vrow("fps", "Frame rate", fps == "native" ? "Native (\(hz))" : fpsSteps.contains(fps) ? fps : "\(fps) (custom)", m, p) {
            let all = ["native"] + fpsSteps
            pick("Frame rate", "Native matches this screen (\(hz) Hz). 30 saves battery.", ["Native · \(hz) fps"] + fpsSteps.map { "\($0) fps" } + ["Custom…"],
                 all.firstIndex(of: fps) ?? all.count) { i in
                if i < all.count { v.put("fps", all[i]); return }
                askText("Custom frame rate", "15 to \(hz) fps") { t in
                    guard let n = Int(t.trimmingCharacters(in: .whitespaces)) else { return }
                    v.put("fps", "\(max(15, min(hz, n)))")
                    settingsRev += 1
                }
            }
        }))
        rows.append(AnyView(bitrateRow(v, m, p)))
        let codec = v.i("codec", 0)
        rows.append(AnyView(vrow("codec", "Video codec", MCPcStyles.codecLabel(codec), m, p) {
            pick("Video codec", "HEVC and AV1 look better at the same bitrate", ["Auto", "H.264", "HEVC", "AV1"], codec) { v.put("codec", $0) }
        }))
        if style != nil {
            let hdr = v.b("hdr")
            rows.append(AnyView(vrow("hdr", "HDR", onOff(hdr), sub: MCPcStyles.screenHdr ? nil : "This screen doesn't show HDR10", m, p) {
                v.put("hdr", !hdr); settingsRev += 1
            }))
        }
        let shapes = ["fit", "zoom", "fill", "stretch"]
        let shape = v.s("shape", MCPictureShape.current)
        rows.append(AnyView(vrow("shape", "Picture shape", shapeLabel(shape), m, p) {
            pick("Picture shape", "Fit shows all of it, Zoom trims a little, Fill crops, Stretch fills and changes the shape.", ["Fit", "Zoom", "Fill", "Stretch"],
                 shapes.firstIndex(of: shape) ?? 0) { v.put("shape", shapes[$0]) }
        }))
        let pacing = v.b("pacing")
        rows.append(AnyView(vrow("pacing", "Frame pacing", pacing ? "Smoothest" : "Lowest delay", m, p) {
            pick("Frame pacing", "Smoother motion costs a little delay.", ["Lowest delay", "Smoothest"], pacing ? 1 : 0) { v.put("pacing", $0 == 1) }
        }))
        guard style != nil else { return rows }
        let atNative = v.s("res", "native") == "native"
        let fsr = v.s("fsr", "off") == "fsr1"
        rows.append(AnyView(vrow("fsr", "Super resolution", fsr ? "FSR 1.0" : "Off", sub: fsrLine(atNative), m, p) {
            pick("Super resolution", fsrLine(atNative), ["Off", "FSR 1.0"], fsr ? 1 : 0) { v.put("fsr", $0 == 1 ? "fsr1" : "off") }
        }))
        if fsr {
            let sharp = v.i("fsrSharp", 60)
            let steps = [0, 20, 40, 60, 80, 100]
            rows.append(AnyView(vrow("fsrSharp", "Sharpening", "\(sharp)%", m, p) {
                pick("Sharpening", "Lower it if you see halos.", steps.map { "\($0)%" }, steps.firstIndex(of: sharp) ?? 3) { v.put("fsrSharp", steps[$0]) }
            }))
        }
        let range = v.b("range")
        rows.append(AnyView(vrow("range", "Full range", onOff(range), sub: "Deeper blacks, if this screen shows them.", m, p) { v.put("range", !range); settingsRev += 1 }))
        let ull = v.b("ull")
        rows.append(AnyView(vrow("ull", "Ultra low latency", onOff(ull), sub: "The decoder's lowest delay.", m, p) { v.put("ull", !ull); settingsRev += 1 }))
        return rows
    }

    /// Bitrate as a slider over Auto and the steps up to 1000 Mbps: left / right one step, a finger drags it, each step
    /// saved at once. A, X or a tap on the value types an exact one (0.5 to 1000 in 0.5 steps).
    private func bitrateRow(_ v: MCVals, _ m: MCMetrics, _ p: MCPalette) -> some View {
        let steps = [0] + MCSettings.pcSteps.map { $0 * 1000 }
        let kbps = v.i("kbps", 0)
        let at = steps.firstIndex(of: kbps) ?? steps.indices.min { abs(steps[$0] - kbps) < abs(steps[$1] - kbps) } ?? 0
        let value = kbps == 0 ? "Auto" : steps.contains(kbps) ? MCPcStyles.mbps(kbps) : "\(MCPcStyles.mbps(kbps)) (exact)"
        let exact = {
            askText("Exact bitrate", "0.5 to \(MCSettings.pcMaxMbps) Mbps") { t in
                guard let n = Double(t.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) else { return }
                v.put("kbps", Int((max(0.5, min(Double(MCSettings.pcMaxMbps), n)) * 2).rounded()) * 500)
                settingsRev += 1
            }
        }
        let move = { (to: Int) in
            let n = max(0, min(steps.count - 1, to))
            guard n != at else { return }
            v.put("kbps", steps[n])
            MCFeel.play(.move)
            settingsRev += 1
        }
        return VStack(alignment: .leading, spacing: m.px(10)) {
            HStack(spacing: m.px(20)) {
                Text("Bitrate").mcFont(28, m).foregroundColor(p.ink)
                Spacer(minLength: m.px(10))
                // a tap on the value types an exact bitrate, as A on the row does
                Text(value).mcFont(28, m, weight: .heavy).foregroundColor(p.ring).lineLimit(1)
                    .padding(.vertical, m.px(6)).padding(.leading, m.px(12))
                    .contentShape(Rectangle()).onTapGesture { exact() }
            }
            MCStepSlider(count: steps.count, at: at, fill: p.ring, track: p.line, thick: m.px(8), knob: m.px(15)) { move($0) }
                .frame(height: max(m.px(44), 30))
            Text("◀ ▶ to change · A: exact value").mcFont(20, m, weight: .semibold).foregroundColor(p.sub)
            if let h = MCSettings.highHint(kbps: kbps) {
                Text(h).mcFont(22, m, weight: .semibold).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, m.px(26)).padding(.vertical, m.px(22))
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("set:kbps")
        .mcFocusable("set:kbps", corner: m.px(16), ring: p.ring, menu: exact, adjust: { move(at + $0) }, action: exact)
    }

    private func psValueRows(_ m: MCMetrics, _ p: MCPalette) -> [AnyView] {
        let d = UserDefaults.standard
        var rows: [AnyView] = []
        rows.append(AnyView(vrow("ps5_resolution", "Resolution", "\(MCPs5Store.height)p", m, p) {
            pick("Resolution", "The PS5 streams up to 1080p", ["720p", "1080p"], MCPs5Store.height >= 1080 ? 1 : 0) { d.set($0 == 1 ? 1080 : 720, forKey: "ps5_resolution") }
        }))
        rows.append(AnyView(vrow("ps5_fps", "Frame rate", "\(MCPs5Store.fps) fps", m, p) {
            pick("Frame rate", "60 fps is smoother; 30 fps lets a weak link keep up", ["60 fps", "30 fps"], MCPs5Store.fps >= 60 ? 0 : 1) { d.set($0 == 0 ? 60 : 30, forKey: "ps5_fps") }
        }))
        let rates = [0, 10, 15, 20, 30, 50, 80, 100]
        let br = MCPs5Store.bitrate
        rows.append(AnyView(vrow("ps5_bitrate", "Bitrate", br == 0 ? "Auto" : "\(br) Mbps", m, p) {
            pick("Bitrate", "Auto: 30 Mbps at 1080p, 15 at 720p. 80–100 Mbps needs a strong 5 GHz or 6 GHz Wi-Fi",
                 rates.map { $0 == 0 ? "Auto" : "\($0) Mbps" } + ["Custom…"], rates.firstIndex(of: br) ?? rates.count) { i in
                if i == rates.count { customPs5Rate("ps5_bitrate") } else { d.set(rates[i], forKey: "ps5_bitrate") }
            }
        }))
        rows.append(AnyView(vrow("ps5_h265", "Video codec", MCPs5Store.h265 ? "HEVC" : "H.264", m, p) {
            pick("Video codec", "HEVC looks better at the same bitrate", ["H.264", "HEVC"], MCPs5Store.h265 ? 1 : 0) { d.set($0 == 1, forKey: "ps5_h265") }
        }))
        let hdr = d.bool(forKey: "ps5_hdr")
        rows.append(AnyView(vrow("ps5_hdr", "HDR", onOff(hdr), sub: MCPs5Store.h265 ? nil : "Needs Video codec HEVC", m, p) { d.set(!hdr, forKey: "ps5_hdr"); settingsRev += 1 }))
        rows.append(AnyView(consoleShapeRow("ps5", m, p)))
        return rows
    }

    private func consoleShapeRow(_ kind: String, _ m: MCMetrics, _ p: MCPalette) -> some View {
        let shapes = ["same", "fit", "zoom", "fill", "stretch"]
        let cur = UserDefaults.standard.string(forKey: "\(kind)_picture_shape") ?? "same"
        return vrow("\(kind)_picture_shape", "Picture shape", shapeLabel(cur), m, p) {
            pick("Picture shape", "Same as PC, or its own: Fit shows all of it, Fill fills the screen (edges cut off), Stretch fills it and changes the shape",
                 ["Same as PC", "Fit", "Zoom", "Fill", "Stretch"], shapes.firstIndex(of: cur) ?? 0) { UserDefaults.standard.set(shapes[$0], forKey: "\(kind)_picture_shape") }
        }
    }

    private func xbValueRows(_ m: MCMetrics, _ p: MCPalette) -> [AnyView] {
        let d = UserDefaults.standard
        var rows: [AnyView] = []
        let res = [0, 720, 1080, 1081]
        let names = ["Auto", "720p", "1080p", "1080p high"]
        rows.append(AnyView(vrow("xbox_resolution", "Picture", names[res.firstIndex(of: MCXbox.resolution) ?? 0], m, p) {
            pick("Picture", "The Xbox sets quality from this", names, res.firstIndex(of: MCXbox.resolution) ?? 0) { d.set(res[$0], forKey: "xbox_resolution") }
        }))
        let caps = [0, 5, 10, 15, 20, 30]
        rows.append(AnyView(vrow("xbox_bitrate", "Bitrate", MCXbox.maxMbps == 0 ? "Auto" : "\(MCXbox.maxMbps) Mbps", m, p) {
            pick("Bitrate", "Auto lets the Xbox decide. A cap keeps a weak Wi-Fi from stuttering", caps.map { $0 == 0 ? "Auto" : "\($0) Mbps" },
                 caps.firstIndex(of: MCXbox.maxMbps) ?? 0) { d.set(caps[$0], forKey: "xbox_bitrate") }
        }))
        let rumbles = ["off", "weak", "medium", "strong"]
        let r = d.string(forKey: "xbox_rumble") ?? "strong"
        rows.append(AnyView(vrow("xbox_rumble", "Rumble", r.capitalized, m, p) {
            pick("Rumble", "How strongly the controller shakes", rumbles.map { $0.capitalized }, rumbles.firstIndex(of: r) ?? 3) { d.set(rumbles[$0], forKey: "xbox_rumble") }
        }))
        let dzs = [0, 3, 5, 8, 10, 15]
        let dz = d.object(forKey: "xbox_deadzone") as? Int ?? 8
        rows.append(AnyView(vrow("xbox_deadzone", "Stick deadzone", dz == 0 ? "Off" : "\(dz)%", m, p) {
            pick("Stick deadzone", "Raise it if a character drifts on its own", dzs.map { $0 == 0 ? "Off" : "\($0)%" }, dzs.firstIndex(of: dz) ?? 3) { d.set(dzs[$0], forKey: "xbox_deadzone") }
        }))
        rows.append(AnyView(consoleShapeRow("xbox", m, p)))
        return rows
    }

    // MARK: the other tabs

    /// Streaming profile (Home or Away) and Away's automatic switch: Picture in the Classic list, Away from home here.
    @ViewBuilder
    func profileRows(_ m: MCMetrics, _ p: MCPalette) -> some View {
        let profs = MCSettings.profiles
        choice("s:profile", "Streaming profile", "Home: best quality on your network. Away: lighter settings for PlayStation Network and slower links",
               profs.map(MCSettings.profileName), profs.firstIndex(of: MCSettings.profile) ?? 0, m, p) { i in settings.switchProfile(to: profs[i]) }
        let autoAway = MCAwayStream.autoAway
        toggle("s:autoaway", "Switch to Away automatically", "When Home is chosen and the PC is reached over the internet, that stream uses the Away settings. Away from home there's never more than 100 Mbps",
               autoAway, m, p) { UserDefaults.standard.set(!autoAway, forKey: "mc_auto_away") }
    }

    @ViewBuilder
    private func pcAwayRows(_ m: MCMetrics, _ p: MCPalette) -> some View {
        profileRows(m, p)
        if let h = pcOf() {
            row("pc:away", icon: "location", color: p.sub, title: "Address for away",
                sub: "A name or address that reaches \(h.name) from the internet. Its home address stays too",
                right: h.externalAddress.flatMap(MCNetwork.bare) ?? "Not set", m, p) {
                askText("Away address for \(h.name)", "IP address or name, empty to clear") { store.setAwayAddress(h, $0); settingsRev += 1 }
            }
        }
        row("pc:net", icon: "wifi", color: p.sub, title: "Test the network", sub: "How fast and steady the link to your PC is, from here", right: nil, m, p) {
            store.networkTest()
        }
    }

    @ViewBuilder
    private func pcPowerRows(_ m: MCMetrics, _ p: MCPalette) -> some View {
        if let h = pcOf() {
            let on = store.online(h)
            info("pc:now", "Now", h.state == State.unknown ? "Checking…" : on ? "Online" : "Off or asleep", m, p)
            if let a = h.activeAddress { info("pc:addr", "Address", a, m, p) }
            if let x = h.externalAddress, x != h.activeAddress { info("pc:awayaddr", "Away", x, m, p) }
            if !on, h.mac != nil, h.mac != "00:00:00:00:00:00" {
                row("pc:wake", icon: "power", color: MCPalette.green, title: "Wake it", sub: "Needs Wake-on-LAN on the PC", right: nil, m, p) { store.wake(h) }
            }
            row("pc:remove", icon: "trash", color: MCPalette.red, title: "Remove", sub: "It disappears from this \(MCDevice.name); pair it again to bring it back", right: nil, m, p) {
                confirm("Remove \(h.name)?", "Its games leave this \(MCDevice.name) until you pair again.", yes: "Remove") {
                    store.remove(h); cards.screen = "home"; settingsRev += 1
                }
            }
        }
    }

    @ViewBuilder
    private func psAwayRows(_ m: MCMetrics, _ p: MCPalette) -> some View {
        let d = UserDefaults.standard
        profileRows(m, p)
        choice("s:ps:awayres", "Resolution", "Over PlayStation Network. Lower keeps a weak link smooth", ["540p", "720p", "1080p"],
               [540, 720, 1080].firstIndex(of: MCPs5Store.awayHeight) ?? 1, m, p) { i in d.set([540, 720, 1080][i], forKey: "ps5_away_resolution") }
        let awayRates = [0, 5, 8, 10, 15]
        choice("s:ps:awayrate", "Bitrate", "Auto: 10 Mbps", awayRates.map { $0 == 0 ? "Auto" : "\($0) Mbps" } + ["Custom…"],
               awayRates.firstIndex(of: MCPs5Store.awayBitrate) ?? -1, other: "\(MCPs5Store.awayBitrate) Mbps", m, p) { i in
            if i == awayRates.count { customPs5Rate("ps5_away_bitrate") } else { d.set(awayRates[i], forKey: "ps5_away_bitrate") } }
    }

    @ViewBuilder
    private func psPowerRows(_ m: MCMetrics, _ p: MCPalette) -> some View {
        let d = UserDefaults.standard
        if MCPsn.signedIn {
            row("s:ps:psn", icon: "person.crop.circle", color: MCPalette.blue, title: "PlayStation Network",
                sub: "Signed in" + (MCPsn.onlineId.flatMap { $0.isEmpty ? nil : " as \($0)" } ?? ""), right: "Sign out", m, p) {
                confirm("Sign out of PlayStation Network?", "You'll sign in again to link another PS5. Linked consoles keep working at home.", yes: "Sign out") {
                    MCPsn.signOut(); settingsRev += 1
                }
            }
        } else {
            row("s:ps:psn", icon: "person.crop.circle", color: MCPalette.blue, title: "PlayStation Network",
                sub: "Sign in once to link a PS5 to this \(MCDevice.name)", right: "Sign in", m, p) { signInPsn { _ in settingsRev += 1 } }
        }
        let disc = ["ask", "rest", "keep"]
        choice("s:ps:disc", "When I disconnect", "What happens to the PS5 after you leave a game", ["Ask", "Rest mode", "Keep it on"],
               disc.firstIndex(of: MCPs5Store.onDisconnect) ?? 0, m, p) { i in d.set(disc[i], forKey: "ps5_on_disconnect") }
        row("s:ps:pin", icon: "lock", color: p.sub, title: "Console PIN", sub: "Signs in for you when the PS5 asks for its 4-digit login PIN",
            right: MCPs5Store.loginPin.isEmpty ? "Not set" : "••••", m, p) {
            askText("Console PIN", "4 digits, empty to turn it off") { v in d.set(v.filter(\.isNumber).prefix(4).description, forKey: "ps5_login_pin"); settingsRev += 1 }
        }
        if let c = psOf() {
            row("ps:wake", icon: "power", color: MCPalette.green, title: "Wake it now", sub: "Wakes \(c.name) from rest mode; it takes about a minute", right: nil, m, p) {
                MCPs5Session.wakeHost(c.host, registKey: c.registKey)
                MCToast.show("Waking \(c.name). It takes about a minute.")
            }
            row("ps:remove", icon: "trash", color: MCPalette.red, title: "Remove this PS5", sub: "Link it again to bring it back", right: nil, m, p) {
                confirm("Remove \(c.name)?", "You'll need the console's code to link it again.", yes: "Remove") {
                    MCPs5Store.remove(c.host); cards.screen = "home"; settingsRev += 1
                }
            }
        }
        info("s:ps:btn", "PS button", "L2 + Start on pads without one", m, p)
        info("s:ps:touch", "Touchpad", "Select + Start, or touch the screen while playing", m, p)
    }

    @ViewBuilder
    private func xbSignRows(_ m: MCMetrics, _ p: MCPalette) -> some View {
        if MCXbox.signedIn {
            row("s:xb:acct", icon: "person.crop.circle", color: MCPalette.green, title: "Xbox network",
                sub: MCXbox.gamertag.map { "Signed in as \($0)" } ?? "Signed in, no Xbox profile. Sign out and use your Xbox account", right: "Sign out", m, p) {
                confirm("Sign out of Xbox?", "Your Xbox consoles leave this \(MCDevice.name) until you sign in again.", yes: "Sign out") {
                    MCXbox.signOut(); cards.screen = "home"; settingsRev += 1
                }
            }
        } else {
            row("s:xb:acct", icon: "person.crop.circle", color: MCPalette.green, title: "Xbox network",
                sub: "Sign in once to play your Xbox here, at home or away", right: "Sign in", m, p) { xboxSignIn() }
        }
        info("s:xb:pace", "Frame pacing", "The Xbox paces its own picture", m, p)
        info("s:xb:hdr", "HDR", "Not available on Xbox Remote Play", m, p)
    }

    @ViewBuilder
    private func tvRows(_ m: MCMetrics, _ p: MCPalette) -> some View {
        row("tv:playon", icon: "tv", color: MCPalette.amber, title: "Play on",
            sub: "This \(MCDevice.name) or a MoonCast TV on your Wi-Fi. On a TV, this \(MCDevice.name) is the controller",
            right: MCTvFinder.target?.name ?? "This \(MCDevice.name)", m, p) { playWhere() }
        let dim = UserDefaults.standard.object(forKey: "hh_dim_on_tv") as? Bool ?? true
        toggle("s:dim", "Dim the screen on a TV", "While this \(MCDevice.name) is the controller for a TV", dim, m, p) {
            UserDefaults.standard.set(!dim, forKey: "hh_dim_on_tv")
        }
    }
}

/// The bitrate slider's track: [count] snapping steps, the thumb at [at]; a finger picks the nearest step.
struct MCStepSlider: View {
    let count: Int
    let at: Int
    let fill: Color
    let track: Color
    let thick: CGFloat
    let knob: CGFloat
    let pick: (Int) -> Void

    var body: some View {
        GeometryReader { g in
            let l = knob, r = g.size.width - knob
            let x = count < 2 ? l : l + (r - l) * CGFloat(at) / CGFloat(count - 1)
            ZStack(alignment: .leading) {
                Capsule().fill(track).frame(width: max(0, r - l), height: thick).offset(x: l)
                Capsule().fill(fill).frame(width: max(0, x - l), height: thick).offset(x: l)
                Circle().fill(fill).frame(width: knob * 2, height: knob * 2).offset(x: x - knob)
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard count > 1, r > l else { return }
                let i = max(0, min(count - 1, Int(((v.location.x - l) / (r - l) * CGFloat(count - 1)).rounded())))
                if i != at { pick(i) }
            })
        }
    }
}
