//
//  MCHomeView.swift
//  MoonCast home for iPad, the handheld's Switch-style home (HandheldHomeActivity): one row of big game tiles,
//  round buttons, a hint bar; All games, Consoles and Settings pages; the dialog card with Cancel picked first.
//

import SwiftUI
import PhotosUI

enum MCPage: String { case home = "Home", games = "All games", consoles = "Consoles", settings = "Settings" }

struct MCRoot: View {
    @ObservedObject var store = MCStore.shared
    @ObservedObject var focus = MCFocus.shared
    @AppStorage("hh_theme") private var theme = "dark"
    @State private var page: MCPage = .home
    @State private var gamesTab = "all"
    @State private var sortAz = false
    @State private var group = "ipad"
    @State private var settingsRev = 0
    @State private var pickingArt: String?
    @State private var photo: PhotosPickerItem?
    @State private var artRev = 0
    @State private var enterTick = 0
    @State private var padTest = false
    @State private var licence: MCLicences.Part?
    @AppStorage("hh_screen_size") private var screenSize = "auto"
    @AppStorage("hh_rotate") private var rotate = true

    private let settings = MCSettings()
    /// Set by the controller: asks for text (a PC's address) with the system's keyboard dialog.
    var askText: (String, String, @escaping (String) -> Void) -> Void = { _, _, _ in }
    /// Set by the controller: Sony's sign-in page; true when signed in.
    var signInPsn: (@escaping (Bool) -> Void) -> Void = { _ in }
    /// Set by the controller: Microsoft's code page inside MoonCast, in a fresh private session (so any account can be picked).
    var openXboxLink: (String) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let _ = screenSize
            let m = MCMetrics(size: geo.size)
            let p = MCPalette(theme: theme)
            let _ = store.revision + artRev + settingsRev
            ZStack {
                p.bg.ignoresSafeArea()
                wash(m, p).ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar(m, p)
                        .frame(height: m.px(96))
                        .padding(.horizontal, m.px(m.edge))
                        .padding(.top, m.px(24))
                    Group {
                        switch page {
                        case .home: homePage(m, p)
                        case .games: gamesPage(m, p)
                        case .consoles: consolesPage(m, p)
                        case .settings: settingsPage(m, p)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    foot(m, p)
                        .frame(height: m.px(110))
                        .padding(.horizontal, m.px(m.edge))
                }
                if padTest { MCPadTestView(m: m, p: p) { padTest = false } }
                if let l = licence { MCLicenceView(part: l, m: m, p: p) { licence = nil } }
                if let s = store.tvSession {
                    MCTvControllerView(s: s, m: m, p: p, playHere: {
                        let g = s.game
                        s.end(quit: false)
                        store.tvSession = nil
                        // a moment for the PC / PS5 / Xbox to let the TV's session go
                        DispatchQueue.main.asyncAfter(deadline: .now() + (g.ps != nil ? 3 : 1)) { store.play(g, here: true) }
                    }, close: { store.tvSession = nil })
                }
                if let d = store.dialog { dialogView(d, m, p) }
                if let b = store.busy { busyView(b, m, p) }
            }
            .preferredColorScheme(theme == "light" ? .light : .dark)
        }
        .mcCollectFrames()
        .onAppear { hookButtons(); testStart(); askUsage() }
        .onChange(of: store.dialog?.id) { _, _ in
            if let d = store.dialog {
                focus.scope = "dialog"
                let i = d.opts.firstIndex { $0.picked } ?? 0
                focus.preferred["dialog"] = "d:\(i)"
                focus.id = "d:\(i)"
            } else {
                focus.scope = "page"
                focus.id = nil
                DispatchQueue.main.async { focus.settle() }
            }
        }
        .photosPicker(isPresented: Binding(get: { pickingArt != nil }, set: { if !$0 && photo == nil { pickingArt = nil } }),
                      selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item = item, let key = pickingArt else { return }
            item.loadTransferable(type: Data.self) { result in
                DispatchQueue.main.async {
                    if case .success(let data?) = result, let img = UIImage(data: data) { MCArt.save(key, img) }
                    pickingArt = nil
                    photo = nil
                    artRev += 1
                }
            }
        }
    }

    // MARK: navigation

    /// Test runs only: MC_PAGE opens a page (home, games, consoles, settings), MC_GROUP a settings group,
    /// MC_THEME sets the theme, so every screen can be checked from a script.
    private func testStart() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let t = env["MC_THEME"] { theme = t }
        if let g = env["MC_GROUP"] { group = g }
        // MC_ACTION opens one thing: network, padtest, playwhere
        switch env["MC_ACTION"] ?? "" {
        case "network": DispatchQueue.main.asyncAfter(deadline: .now() + 3) { store.networkTest() }
        case "padtest": padTest = true
        case "licence": licence = MCLicences.parts[0]
        case "playwhere": DispatchQueue.main.asyncAfter(deadline: .now() + 2) { playWhere() }
        default: break
        }
        // MC_STEPS="4:id=rb:Settings;6:id=set:picture;8:dlg=1": at N seconds press an item by its focus id, or pick
        // option N of the open dialog, so whole flows can be walked through from a script
        for step in (env["MC_STEPS"] ?? "").split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let t = Double(parts[0]) else { continue }
            let what = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                // "first" is the page's first item
                func key(_ k: Substring) -> String { k == "first" ? (focus.preferred["page"] ?? "") : String(k) }
                if what.hasPrefix("id=") { focus.actions[key(what.dropFirst(3))]?() }
                else if what.hasPrefix("menu=") { focus.menus[key(what.dropFirst(5))]?() }
                else if what.hasPrefix("dlg="), let i = Int(what.dropFirst(4)), let d = store.dialog, i < d.opts.count {
                    store.dialog = nil
                    d.opts[i].run()
                }
            }
        }
        if let pg = env["MC_PAGE"], let target = [MCPage.home, .games, .consoles, .settings].first(where: { $0.rawValue.lowercased().hasPrefix(pg.lowercased()) || (pg == "games" && $0 == .games) }) {
            go(target)
        }
        #endif
    }

    /// An official build asks once, a moment after the home opens, whether to send the anonymous check-in
    /// (No thanks picked first); after a yes it goes at most once a day.
    private func askUsage() {
        if MCUsage.enabled { MCUsage.checkIn(); return }
        guard MCUsage.shouldAsk else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard store.dialog == nil, MCUsage.shouldAsk else { return }
            store.dialog = MCDialog(title: MCUsage.question, message: MCUsage.explain,
                                    opts: [.init(title: "No thanks", picked: true) { MCUsage.answer(false) },
                                           .init(title: "Yes, send") { MCUsage.answer(true) }])
        }
    }

    private func go(_ p: MCPage) {
        page = p
        enterTick += 1
        focus.id = nil
        DispatchQueue.main.async { focus.settle() }
    }

    private func hookButtons() {
        focus.pageButton = { b in
            if store.busy != nil { return true }
            if store.dialog != nil {
                if b == .b { closeDialog(cancel: true) }
                return true
            }
            switch b {
            case .b:
                if page != .home { go(.home) }
                return true
            case .l, .r:
                if page == .games {
                    let tabs = gameTabs().map { $0.0 }
                    if let i = tabs.firstIndex(of: gamesTab) {
                        gamesTab = tabs[(i + (b == .r ? 1 : tabs.count - 1)) % tabs.count]
                        focus.id = nil
                        DispatchQueue.main.async { focus.settle() }
                    }
                } else if page == .settings {
                    let g = groups.map { $0.0 }
                    if let i = g.firstIndex(of: group) { group = g[(i + (b == .r ? 1 : g.count - 1)) % g.count] }
                }
                return true
            case .x:
                if page == .games { sortAz.toggle(); return true }
                return false
            default:
                return false
            }
        }
    }

    // MARK: shell

    private func topBar(_ m: MCMetrics, _ p: MCPalette) -> some View {
        HStack(spacing: m.px(20)) {
            if page == .home {
                Image("MoonCastLogo").resizable().scaledToFit().frame(width: m.px(84), height: m.px(84))
                HStack(spacing: m.px(14)) {
                    RoundedRectangle(cornerRadius: m.px(5)).stroke(p.ink, lineWidth: m.px(3)).frame(width: m.px(32), height: m.px(22))
                    Text(MCTvFinder.target.map { "Playing on \($0.name)" + (MCTvFinder.isHere($0) ? "" : " (not found)") }
                         ?? "Playing on this \(MCDevice.name)")
                        .mcFont(26, m).foregroundColor(p.ink).lineLimit(1)
                }
                .padding(.horizontal, m.px(30))
                .frame(height: m.px(84))
                .background(Capsule().fill(p.panel))
                .onTapGesture { playWhere() }
            } else {
                Button { go(.home) } label: {
                    Image(systemName: "chevron.left").font(.system(size: m.px(36), weight: .bold)).foregroundColor(p.ink)
                        .frame(width: max(m.px(84), 44), height: max(m.px(84), 44))
                        .background(Circle().fill(p.panel))
                }
                .accessibilityLabel("Back")
                Text(page.rawValue).mcFont(44, m, weight: .heavy).foregroundColor(p.ink)
            }
            Spacer()
        }
    }

    private func foot(_ m: MCMetrics, _ p: MCPalette) -> some View {
        HStack(spacing: m.px(14)) {
            if focus.padActive {
                Image(systemName: "gamecontroller.fill").font(.system(size: m.px(30))).foregroundColor(p.sub)
                Text(focus.padName).mcFont(28, m).foregroundColor(p.sub)
            }
            Spacer()
            if focus.padActive {
                ForEach(hints(), id: \.0) { k, l in
                    HStack(spacing: m.px(14)) {
                        Text(k).mcFont(22, m, weight: .heavy).foregroundColor(p.bg)
                            .padding(.horizontal, m.px(k.count > 1 ? 14 : 0))
                            .frame(minWidth: m.px(46), minHeight: m.px(46))
                            .background(Capsule().fill(p.ink))
                        Text(l).mcFont(28, m).foregroundColor(p.ink)
                    }
                    .padding(.leading, m.px(26))
                    .onTapGesture { tapHint(k) }
                }
            }
        }
        .overlay(Rectangle().fill(p.line).frame(height: 1), alignment: .top)
    }

    private func hints() -> [(String, String)] {
        if store.dialog != nil { return [("B", "Cancel"), ("A", "OK")] }
        switch page {
        case .home: return [("X", "Options"), ("A", "Start")]
        case .games: return [("L R", "Tabs"), ("X", sortAz ? "Recent first" : "A to Z"), ("B", "Back"), ("A", "Start")]
        case .consoles: return [("B", "Back"), ("A", "Open")]
        case .settings: return [("L R", "Groups"), ("B", "Back"), ("A", "OK")]
        }
    }

    private func tapHint(_ k: String) {
        switch k {
        case "A": focus.press(.a)
        case "B": focus.press(.b)
        case "X": focus.press(.x)
        case "L R": focus.press(.r)
        default: break
        }
    }

    /// The colour of the focused game, washed over the background.
    private func wash(_ m: MCMetrics, _ p: MCPalette) -> some View {
        // Settings → Theme → Background: Static keeps the theme's plain colour
        let c = UserDefaults.standard.string(forKey: "hh_background") == "static" ? nil : focusedGame().map { g -> Color in MCArt.tint(g.key) ?? Covers.tint(g.seed) }
        return GeometryReader { g in
            if let c = c {
                RadialGradient(colors: [c.opacity(0.26), c.opacity(0)], center: UnitPoint(x: 0.3, y: 0.4),
                               startRadius: 0, endRadius: max(g.size.width, g.size.height) * 0.6)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: focus.id)
    }

    private func focusedGame() -> MCGame? {
        guard let id = focus.id, id.hasPrefix("g:") else { return nil }
        let key = String(id.dropFirst(2))
        return (store.homePcs() + store.allGames()).first { $0.key == key }
    }

    // MARK: Home

    private func homePage(_ m: MCMetrics, _ p: MCPalette) -> some View {
        // one tile per PC (press: its games), then the consoles
        let games = store.homePcs() + store.homeGames()
        // PCs found on the network but not paired yet: a tile each, so pairing is one press from Home
        let unpaired = games.isEmpty ? store.hosts.filter { store.online($0) && !store.paired($0) } : []
        let gap: CGFloat = 32
        let usableW = m.designWidth - 2 * m.edge
        // on its side the tiles take the height left after the bars, the name line and the round buttons
        let free = m.designHeight - 120 - 110 - 128 - 230 - 40
        let ts: CGFloat = m.portrait ? min((usableW - gap) / 2, m.designHeight * 0.34) : min(max(380, free), 520)
        var titles = Dictionary(games.map { ("g:\($0.key)", $0.title) }, uniquingKeysWith: { a, _ in a })
        titles["g:all"] = "All games"
        titles["g:add"] = "Add a PC"
        unpaired.forEach { titles["g:pair:\($0.uuid)"] = "Pair \($0.name)" }
        let firstId = games.first.map { "g:\($0.key)" } ?? unpaired.first.map { "g:pair:\($0.uuid)" } ?? "g:add"
        // with a pad the name follows the ring; on touch it's the first tile's (what you'd start)
        let name = focus.padActive ? focus.id.flatMap { titles[$0] } : titles[firstId]
        focus.preferred["page"] = firstId
        return VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0).frame(maxHeight: m.px(80))
            Text(name ?? " ").mcFont(34, m).foregroundColor(p.ring).lineLimit(1)
                .padding(.leading, m.px(m.edge)).frame(height: m.px(48))
                .animation(nil, value: name)
                .modifier(MCRise(order: 0, tick: enterTick))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: m.px(gap)) {
                        ForEach(unpaired, id: \.uuid) { h in
                            tile(nil, kind: "pair:\(h.uuid)", label: "Pair \(h.name)", size: ts, m, p) { store.pair(h) }
                        }
                        if games.isEmpty && unpaired.isEmpty {
                            tile(nil, kind: "add", label: "Add a PC", size: ts, m, p) { go(.consoles) }
                        }
                        ForEach(games) { g in
                            if g.key.hasPrefix("pchost:"), let h = g.host {
                                tile(g, kind: "pchost", label: g.title, size: ts, m, p) { openPc(h) }
                            } else {
                                tile(g, kind: "game", label: g.title, size: ts, m, p) { store.play(g) }
                            }
                        }
                        tile(nil, kind: "all", label: "All games", size: ts, m, p) { gamesTab = "all"; go(.games) }
                    }
                    .padding(.horizontal, m.px(m.edge))
                    .padding(.vertical, m.px(20))
                }
                .onChange(of: focus.id) { _, id in
                    if let id = id, id.hasPrefix("g:"), focus.padActive { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            .frame(height: m.px(ts + 40))
            .modifier(MCRise(order: 1, tick: enterTick))
            if games.isEmpty {
                Text(unpaired.isEmpty ? "Looking for PCs running Sunshine on this network. Or add one by its address in Consoles."
                                      : "Press a PC to pair it: a PIN shows here, and you type it into Sunshine on the PC.")
                    .mcFont(26, m, weight: .medium).foregroundColor(p.sub)
                    .padding(.leading, m.px(m.edge)).padding(.top, m.px(8))
                    .modifier(MCRise(order: 2, tick: enterTick))
            }
            roundButtons(m, p)
                .padding(.top, m.px(m.portrait ? 64 : 50))
                .frame(maxWidth: .infinity)
                .modifier(MCRise(order: 3, tick: enterTick))
            Spacer(minLength: 0)
        }
    }

    private func roundButtons(_ m: MCMetrics, _ p: MCPalette) -> some View {
        let items: [(String, String, Color, () -> Void)] = [
            ("Consoles", "square.stack.3d.up.fill", MCPalette.cyan, { go(.consoles) }),
            ("Play on TV", "tv", MCPalette.amber, { playWhere() }),
            ("Controllers", "gamecontroller.fill", MCPalette.blue, { store.controllersDialog() }),
            ("Network", "wifi", MCPalette.green, { store.networkTest() }),
            ("Settings", "gearshape.fill", p.sub, { go(.settings) }),
        ]
        // a narrow screen (a phone held upright) gets two rows of three, as on the handheld
        let rows = m.designWidth < 5 * 112 + 4 * 60 + 2 * m.edge ? [Array(items.prefix(3)), Array(items.dropFirst(3))] : [items]
        return VStack(spacing: m.px(40)) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .top, spacing: m.px(m.portrait ? 60 : 96)) {
                    ForEach(rows[r], id: \.0) { label, icon, color, run in
                        VStack(spacing: m.px(18)) {
                            Image(systemName: icon).font(.system(size: m.px(50), weight: .semibold)).foregroundColor(color)
                                .frame(width: m.px(112), height: m.px(112))
                                .background(Circle().fill(p.panel))
                                .mcFocusable("rb:\(label)", corner: m.px(56), ring: p.ring, action: run)
                            Text(label).mcFont(27, m).foregroundColor(p.label).lineLimit(1).fixedSize()
                        }
                        .frame(minWidth: m.px(150))
                        .accessibilityLabel(label)
                    }
                }
            }
        }
    }

    /// A square game tile: art (box art for PC games), its source, Running, and the name at the bottom.
    private func tile(_ g: MCGame?, kind: String, label: String, size: CGFloat, _ m: MCMetrics, _ p: MCPalette,
                      action: @escaping () -> Void) -> some View {
        let s = m.px(size)
        let corner = m.px(m.tileCorner)
        let id = g.map { "g:\($0.key)" } ?? "g:\(kind)"
        let custom = g.flatMap { MCArt.image($0.key) }
        let box = custom == nil ? g?.app.flatMap { store.boxArt($0) } : nil
        // GeForce Experience's placeholder covers carry no name: show it, as Moonlight does
        let placeholder = box.map { b in let w = Int(b.size.width * b.scale), h = Int(b.size.height * b.scale)
                                    return (w == 130 && h == 180) || (w == 628 && h == 888) } ?? false
        let k = min(size / 380, 1.5)
        return ZStack(alignment: .topLeading) {
            Group {
                if let img = custom ?? box {
                    Image(uiImage: img).resizable().scaledToFill()
                } else if let g = g {
                    CoverArt(colors: Covers.colors(g.seed))
                } else if kind.hasPrefix("pair:") {
                    CoverArt(colors: Covers.colors(label))
                        .overlay(Image(systemName: "link").font(.system(size: s * 0.22, weight: .bold)).foregroundColor(.white.opacity(0.9)))
                } else if kind == "all" {
                    p.tile.overlay(allGrid(s, p))
                } else {
                    CoverArt(colors: Covers.colors("add"))
                }
            }
            .frame(width: s, height: s)
            .clipped()
            if custom != nil {
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.69)], startPoint: .top, endPoint: .bottom)
            }
            if kind == "add" {
                Text("+").font(.system(size: s * 0.3, weight: .semibold)).foregroundColor(.white)
                    .frame(width: s, height: s)
            }
            if kind == "pchost" && custom == nil {
                Image(systemName: "desktopcomputer").font(.system(size: s * 0.3, weight: .semibold)).foregroundColor(.white.opacity(0.9))
                    .frame(width: s, height: s * 0.86)
            }
            if g != nil && (box == nil || placeholder) || kind == "add" || kind.hasPrefix("pair:") {
                Text(label).font(.system(size: m.px(36), weight: .heavy)).foregroundColor(.white).lineLimit(3)
                    .shadow(color: .black.opacity(0.35), radius: m.px(5), y: m.px(2))
                    .padding(.horizontal, m.px(26 * k)).padding(.bottom, m.px(24 * k))
                    .frame(width: s, height: s, alignment: .bottomLeading)
            }
            if let g = g {
                let bs: CGFloat = size >= 500 ? 24 : size >= 360 ? 20 : 17
                let mm: CGFloat = size >= 360 ? 18 : 12
                HStack {
                    Text(g.src).font(.system(size: m.px(bs), weight: .heavy)).foregroundColor(.white)
                        .padding(.horizontal, m.px(14)).frame(height: m.px(bs * 2))
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                    Spacer()
                    if g.running {
                        HStack(spacing: m.px(8)) {
                            Circle().fill(MCPalette.live).frame(width: m.px(12), height: m.px(12))
                            Text("Running").font(.system(size: m.px(bs), weight: .heavy)).foregroundColor(Color(hex: 0x111111))
                        }
                        .padding(.horizontal, m.px(14)).frame(height: m.px(bs * 2))
                        .background(Capsule().fill(Color.white))
                    }
                }
                .padding(m.px(mm))
                .frame(width: s, alignment: .top)
            }
        }
        .frame(width: s, height: s)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .shadow(color: .black.opacity(page == .home ? 0.3 : 0), radius: m.px(10), y: m.px(6))
        .id(id)
        .mcFocusable(id, corner: corner, ring: p.ring,
                     menu: g.map { g in kind == "pchost" ? { if let h = g.host { pcMenu(h) } } : { gameMenu(g) } }, action: action)
        .accessibilityLabel(label)
    }

    private func allGrid(_ w: CGFloat, _ p: MCPalette) -> some View {
        let s = w * 36 / 380, g = w * 12 / 380
        return VStack(spacing: g) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: g) {
                    ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: s / 6).fill(p.sub).frame(width: s, height: s) }
                }
            }
        }
    }

    /// A PC's tile on Home: its games, in All games (offline: wake it; not paired: pair it).
    private func openPc(_ h: TemporaryHost) {
        if !store.online(h) { pcMenu(h); return }
        gamesTab = "pc:\(h.uuid)"
        sortAz = false
        go(.games)
    }

    private func gameMenu(_ g: MCGame) {
        var opts: [MCDialog.Opt] = [.init(title: g.running ? "Resume" : "Start", picked: true) { store.play(g) }]
        if g.running, let h = g.host {
            opts.append(.init(title: "Quit game", sub: "Anything not saved is lost", danger: true) {
                confirm("Quit \(g.title)?", "Anything not saved in it is lost.", yes: "Quit") { store.quit(h) }
            })
        }
        opts.append(.init(title: "Change picture", sub: "Use a photo for this tile") { pickingArt = g.key })
        if MCArt.image(g.key) != nil {
            opts.append(.init(title: "Use the original picture") { MCArt.remove(g.key); artRev += 1 })
        }
        if let h = g.host, let id = g.app?.id {
            opts.append(.init(title: "Hide this game", sub: "Show it again from Consoles → \(h.name)") { store.setHidden(h, id, true) })
        }
        opts.append(.init(title: "Cancel") {})
        store.dialog = MCDialog(title: g.title, opts: opts)
    }

    // MARK: All games

    private func gameTabs() -> [(String, String)] {
        [("all", "All")] + store.hosts.filter { store.paired($0) }.map { ("pc:\($0.uuid)", $0.name) }
    }

    private func gamesPage(_ m: MCMetrics, _ p: MCPalette) -> some View {
        var games = store.allGames()
        if gamesTab.hasPrefix("pc:") { games = games.filter { $0.key.hasPrefix(gamesTab + ":") } }
        if sortAz {
            games.sort { $0.title.lowercased() < $1.title.lowercased() }
        } else {
            let r = MCRecents.list()
            let rank = Dictionary(r.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            games.sort {
                let a = rank[$0.key] ?? Int.max, b = rank[$1.key] ?? Int.max
                return a != b ? a < b : $0.title.lowercased() < $1.title.lowercased()
            }
        }
        let gap: CGFloat = 28
        let usableW = m.designWidth - 2 * m.edge
        let cols = max(2, Int((usableW + gap) / (300 + gap)))
        let ts = (usableW - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let rows = stride(from: 0, to: games.count, by: cols).map { Array(games[$0..<min($0 + cols, games.count)]) }
        focus.preferred["page"] = games.first.map { "g:\($0.key)" }
        return VStack(alignment: .leading, spacing: m.px(24)) {
            HStack(spacing: m.px(16)) {
                ForEach(gameTabs(), id: \.0) { key, label in
                    Text(label).mcFont(28, m, weight: .heavy)
                        .foregroundColor(gamesTab == key ? p.bg : p.ink)
                        .padding(.horizontal, m.px(30)).frame(height: m.px(64))
                        .background(Capsule().fill(gamesTab == key ? p.ink : p.panel))
                        .onTapGesture { gamesTab = key }
                }
                Spacer()
                Text(sortAz ? "A to Z" : "Recent first").mcFont(26, m).foregroundColor(p.sub)
                    .onTapGesture { sortAz.toggle() }
            }
            .padding(.horizontal, m.px(m.edge))
            .padding(.top, m.px(24))
            if games.isEmpty {
                Text(store.hosts.contains { store.paired($0) } ? "No games yet. They show up once the PC sends its list."
                                                               : "No PC paired yet. Add one in Consoles.")
                    .mcFont(30, m).foregroundColor(p.sub).padding(.horizontal, m.px(m.edge))
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: m.px(gap)) {
                            ForEach(rows.indices, id: \.self) { i in
                                HStack(spacing: m.px(gap)) {
                                    ForEach(rows[i]) { g in tile(g, kind: "game", label: g.title, size: ts, m, p) { store.play(g) } }
                                }
                            }
                        }
                        .padding(.horizontal, m.px(m.edge))
                        .padding(.vertical, m.px(16))
                    }
                    .onChange(of: focus.id) { _, id in
                        if let id = id, focus.padActive { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
    }

    // MARK: Consoles

    private func consolesPage(_ m: MCMetrics, _ p: MCPalette) -> some View {
        let pcs = store.hosts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        focus.preferred["page"] = pcs.first.map { "pc:\($0.uuid)" } ?? "add:pc"
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: m.px(14)) {
                    header("PCs", m, p)
                    if pcs.isEmpty {
                        Text("Looking for PCs with Sunshine on this network…").mcFont(28, m).foregroundColor(p.sub)
                    }
                    ForEach(pcs, id: \.uuid) { h in
                        row("pc:\(h.uuid)", icon: "PC", color: MCPalette.cyan, title: h.name, sub: pcStatus(h), right: pcRight(h), m, p) { pcMenu(h) }
                    }
                    let ps5s = MCPs5Store.list()
                    if !ps5s.isEmpty {
                        header("PlayStation", m, p)
                        ForEach(ps5s, id: \.host) { c in
                            row("ps:\(c.host)", icon: "PS", color: MCPalette.blue, title: c.name, sub: ps5Line(c), right: "Linked", m, p) { ps5Menu(c) }
                        }
                    }
                    let xbs = MCXbox.consoles
                    if !xbs.isEmpty {
                        header("Xbox", m, p)
                        ForEach(xbs, id: \.id) { c in
                            row("xb:\(c.id)", icon: "XB", color: MCPalette.green, title: c.name,
                                sub: c.type + (c.powerState.isEmpty ? "" : " · \(c.powerState == "On" ? "On" : c.powerState == "ConnectedStandby" ? "Sleeping" : c.powerState)"),
                                right: nil, m, p) { xboxMenu(c) }
                        }
                    }
                    header("Add", m, p)
                    row("add:pc", icon: "plus", color: MCPalette.green, title: "Add a PC by its address",
                        sub: "When it isn't found by itself (another network, a VPN)", right: nil, m, p) {
                        askText("Add a PC", "The PC's IP address or name") { store.addPc($0) }
                    }
                    row("add:ps", icon: "PS", color: MCPalette.blue, title: "Add a PlayStation 5", sub: "Sign in to PSN and link it with the console's 8-digit code", right: nil, m, p) {
                        linkPs5()
                    }
                    row("add:xb", icon: "XB", color: MCPalette.green, title: MCXbox.signedIn ? "Refresh Xbox consoles" : "Add your Xbox",
                        sub: MCXbox.signedIn ? "Signed in as \(MCXbox.gamertag ?? "your account")" : "Sign in with your Microsoft account", right: nil, m, p) {
                        if MCXbox.signedIn { refreshXboxes(loud: true) } else { xboxSignIn() }
                    }
                }
                .padding(.horizontal, m.px(m.edge))
                .padding(.vertical, m.px(24))
            }
            .onChange(of: focus.id) { _, id in if let id = id, focus.padActive { proxy.scrollTo(id) } }
        }
    }

    private func pcStatus(_ h: TemporaryHost) -> String {
        if h.state == State.unknown { return "Checking…" }
        if !store.online(h) { return "Off or asleep" }
        if !store.paired(h) { return "Not paired: press to pair" }
        if let cur = store.apps(h).first(where: { $0.id == h.currentGame }), h.currentGame != "0" { return "Running \(cur.name ?? "a game")" }
        let n = store.apps(h).count
        return "Online · \(n) game\(n == 1 ? "" : "s")"
    }

    private func pcRight(_ h: TemporaryHost) -> String? {
        store.online(h) ? (store.paired(h) ? "Paired" : "Pair") : nil
    }

    private func pcMenu(_ h: TemporaryHost) {
        var opts: [MCDialog.Opt] = []
        if store.online(h) && !store.paired(h) {
            opts.append(.init(title: "Pair", sub: "Shows a PIN to enter in Sunshine", picked: true) { store.pair(h) })
        }
        if !store.online(h), h.mac != nil, h.mac != "00:00:00:00:00:00" {
            opts.append(.init(title: "Wake it up", sub: "Sends Wake-on-LAN", picked: true) { store.wake(h) })
        }
        if store.online(h) && store.paired(h) {
            if let cur = store.apps(h).first(where: { $0.id == h.currentGame }), h.currentGame != "0" {
                opts.append(.init(title: "Quit \(cur.name ?? "the game")", danger: true) {
                    confirm("Quit \(cur.name ?? "the game")?", "Anything not saved in it is lost.", yes: "Quit") { store.quit(h) }
                })
            }
            opts.append(.init(title: "Show its games", picked: !opts.contains { $0.picked }) { DispatchQueue.main.async { openPc(h) } })
            opts.append(.init(title: "Refresh the games") { store.fetchApps(h, force: true) })
        }
        opts.append(.init(title: "Away address", sub: h.externalAddress.map { "Now \($0)" } ?? "To reach it from another network or a VPN") {
            askText("Away address for \(h.name)", "IP address or name, empty to clear") { store.setAwayAddress(h, $0) }
        })
        let hidden = store.hidden(h)
        if !hidden.isEmpty {
            opts.append(.init(title: "Hidden games", sub: "\(hidden.count) hidden") { hiddenGames(h) })
        }
        opts.append(.init(title: "Remove this PC", sub: "Pair again to bring it back", danger: true) {
            confirm("Remove \(h.name)?", "Its games leave this \(MCDevice.name) until you pair again.", yes: "Remove") { store.remove(h) }
        })
        opts.insert(.init(title: "Cancel", picked: !opts.contains { $0.picked }) {}, at: 0)
        var lines = [h.activeAddress.map { "Address: \($0)" }, h.externalAddress.map { "Away: \($0)" }].compactMap { $0 }
        if lines.count == 2 && h.externalAddress == h.activeAddress { lines.removeLast() }
        store.dialog = MCDialog(title: h.name, message: lines.isEmpty ? nil : lines.joined(separator: "\n"), opts: opts)
    }

    // MARK: Play on TV: where games go (this iPad or a MoonCast TV)

    private func playWhere() {
        store.busy = "Looking for MoonCast TVs on this Wi-Fi…"
        Task { @MainActor in
            let tvs = await MCTvFinder.sweep()
            store.busy = nil
            settingsRev += 1
            let device = MCDevice.name
            let cur = MCTvFinder.target
            var opts: [MCDialog.Opt] = [.init(title: "This \(device)", sub: "Games play here", picked: cur == nil) {
                MCTvFinder.target = nil; settingsRev += 1
            }]
            for tv in tvs {
                let here = MCTvFinder.isHere(tv)
                opts.append(.init(title: tv.name + (cur?.id == tv.id ? "  ✓" : ""),
                                  sub: here ? "On this Wi-Fi · this \(device) becomes its controller" : "Not on this network",
                                  picked: cur?.id == tv.id) {
                    MCTvFinder.target = tv; settingsRev += 1
                })
            }
            store.dialog = MCDialog(title: "Where to play",
                                    message: tvs.isEmpty ? "No MoonCast TV answered. Open MoonCast on the TV, on the same Wi-Fi as this \(device)." : nil,
                                    opts: opts + [.init(title: "Cancel") {}])
        }
    }

    // MARK: Xbox (Microsoft's device-code sign-in, as on the handheld)

    private func xboxSignIn() {
        store.busy = "Getting a code…"
        Task { @MainActor in
            do {
                let dc = try await MCXbox.startSignIn()
                store.busy = nil
                var waiting = true
                store.dialog = MCDialog(title: "Sign in to Xbox",
                                        message: "Open \(dc.url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: "")) (here or on another device), enter this code and sign in with your Xbox account.",
                                        big: dc.userCode,
                                        opts: [.init(title: "Open the page", picked: true) {
                                                   UIPasteboard.general.string = dc.userCode
                                                   openXboxLink(dc.userCode)
                                                   // the dialog closes on a press: put it back while we wait
                                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if waiting { xboxWaiting(dc) } }
                                               },
                                               .init(title: "Cancel") { waiting = false }])
                let end = Date().addingTimeInterval(Double(dc.expiresIn))
                while Date() < end {
                    try await Task.sleep(nanoseconds: UInt64(max(2, dc.interval)) * 1_000_000_000)
                    if !waiting && store.dialog == nil { return }
                    if try await MCXbox.pollSignIn(dc) {
                        waiting = false
                        store.dialog = nil
                        refreshXboxes(loud: true)
                        return
                    }
                }
            } catch {
                store.busy = nil
                settingsRev += 1
                store.dialog = MCDialog(title: error is MCXbox.NotAllowed ? "Not an Xbox account" : "Xbox sign-in didn't finish",
                                        message: error.localizedDescription, opts: [.init(title: "OK") {}])
            }
        }
    }

    private func xboxWaiting(_ dc: MCXbox.DeviceCode) {
        store.dialog = MCDialog(title: "Waiting for Microsoft…", message: "Enter the code on the page, then come back here. (It's copied.)",
                                big: dc.userCode, opts: [.init(title: "Cancel", picked: true) {}])
    }

    private func refreshXboxes(loud: Bool) {
        if loud { store.busy = "Finding your Xbox consoles…" }
        Task { @MainActor in
            let list = (try? await MCXbox.refreshConsoles()) ?? MCXbox.consoles
            store.busy = nil
            settingsRev += 1
            if loud {
                store.dialog = MCDialog(title: list.isEmpty ? "No Xbox found" : "Xbox ready",
                                        message: list.isEmpty ? "This account has no console with remote features on. On the Xbox: Settings → Devices & connections → Remote features."
                                                              : list.map(\.name).joined(separator: ", ") + " on Home now.",
                                        opts: [.init(title: "OK") {}])
            }
        }
    }

    private func xboxMenu(_ c: MCXbox.Console) {
        store.dialog = MCDialog(title: c.name, message: c.type, opts: [
            .init(title: "Cancel", picked: true) {},
            .init(title: "Play", sub: "Wakes it if it's sleeping") { store.onXboxStream?(c) },
            .init(title: "Wake it up", sub: "Needs Sleep power mode on the Xbox") { Task { try? await MCXbox.wake(c.id) } },
            .init(title: "Turn it off", danger: true) { Task { try? await MCXbox.turnOff(c.id) } },
        ])
    }

    private func ps5Line(_ c: MCPs5Console) -> String {
        guard let st = store.ps5Status[c.host] else { return "\(c.host) · checking…" }
        switch st.power {
        case .on: return st.runningApp.map { "On · playing \($0)" } ?? "On"
        case .rest: return "Rest mode · starts when you play"
        case .notFound: return "Not on this network (\(c.host))"
        }
    }

    // MARK: linking a PS5 (Ps5 registration on the handheld): PSN sign-in once -> pick the PS5 -> its 8-digit code

    private func linkPs5() {
        guard MCPsn.signedIn else {
            store.dialog = MCDialog(title: "Sign in to PlayStation Network",
                                    message: "Once, to link your PS5 to this \(MCDevice.name). Your password goes to Sony only; MoonCast keeps a sign-in token in the \(MCDevice.name)'s Keychain.",
                                    opts: [.init(title: "Cancel", picked: true) {},
                                           .init(title: "Sign in") { signInPsn { ok in
                                               if ok { linkPs5() } else {
                                                   store.dialog = MCDialog(title: "Not signed in", message: "The sign-in didn't finish. Try again.", opts: [.init(title: "OK") {}])
                                               } } }])
            return
        }
        store.busy = "Looking for PlayStations on this network…"
        DispatchQueue.global(qos: .userInitiated).async {
            let found = MCPs5Probe.discover()
            DispatchQueue.main.async {
                store.busy = nil
                var opts: [MCDialog.Opt] = [.init(title: "Cancel", picked: found.isEmpty) {}]
                for (i, f) in found.enumerated() {
                    opts.append(.init(title: f.name, sub: "\(f.host) · \(f.on ? "On" : "Rest mode")", picked: i == 0) { enterCode(f.host, f.name) })
                }
                opts.append(.init(title: "Enter its address", sub: "When it isn't found") {
                    askText("The PS5's address", "IP address, like 192.168.1.20") { a in
                        let h = a.trimmingCharacters(in: .whitespaces)
                        if !h.isEmpty { enterCode(h, "the PS5") }
                    }
                })
                store.dialog = MCDialog(title: "Which PlayStation?",
                                        message: found.isEmpty ? "None answered. Make sure it's on or in rest mode (not fully off) and on this network."
                                                               : "Pick yours. Then on it open Settings → System → Remote Play → Link Device to see the code.",
                                        opts: opts)
            }
        }
    }

    private func enterCode(_ host: String, _ name: String) {
        askText("Type the code from \(name)", "8 digits") { raw in
            let code = raw.filter(\.isNumber)
            guard code.count == 8, let pin = UInt32(code), let acc = MCPsn.accountId, let accData = Data(base64Encoded: acc) else {
                store.dialog = MCDialog(title: "The code has 8 digits", message: "On the PS5: Settings → System → Remote Play → Link Device.",
                                        opts: [.init(title: "Try again", picked: true) { enterCode(host, name) }, .init(title: "Cancel") {}])
                return
            }
            store.busy = "Linking with \(name)…"
            MCPs5Session.registerHost(host, accountId: accData, pin: pin) { r in
                store.busy = nil
                guard let r = r, let key = r["registKey"] as? String, let morning = r["morning"] as? String else {
                    store.dialog = MCDialog(title: "That didn't work",
                                            message: "Check the code (it changes every few minutes) and that the PS5 still shows Link Device.",
                                            opts: [.init(title: "Try again", picked: true) { enterCode(host, name) }, .init(title: "Cancel") {}])
                    return
                }
                let nick = (r["nickname"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
                MCPs5Store.add(MCPs5Console(name: nick, host: host, registKey: key, morning: morning))
                store.probePs5s(force: true)
                settingsRev += 1
                store.dialog = MCDialog(title: "\(nick) added", message: "It's on Home now. Press it to play; it wakes from rest mode by itself.",
                                        opts: [.init(title: "OK") {}])
            }
        }
    }

    private func ps5Menu(_ c: MCPs5Console) {
        store.dialog = MCDialog(title: c.name, message: "Address: \(c.host)", opts: [
            .init(title: "Cancel", picked: true) {},
            .init(title: "Play", sub: "Wakes it if it's in rest mode") { store.onPs5Stream?(c) },
            .init(title: "Wake it up", sub: "From rest mode") { MCPs5Session.wakeHost(c.host, registKey: c.registKey) },
            .init(title: "Remove this PS5", sub: "Link it again to bring it back", danger: true) {
                confirm("Remove \(c.name)?", "You'll need the console's code to link it again.", yes: "Remove") {
                    MCPs5Store.remove(c.host); settingsRev += 1
                }
            },
        ])
    }

    /// About → Open-source licences: every project, grouped; one opens its full text.
    private func licences(group g: String? = nil) {
        let groups = ["The app", "PS5", "Xbox", "More"]
        guard let g = g else {
            store.dialog = MCDialog(title: "Open-source licences", message: "MoonCast is free software (\(MCLicences.sourceLicence)). These are the projects inside it.",
                                    opts: [.init(title: "Done", picked: true) {}] + groups.map { name in
                                        let n = MCLicences.parts.filter { $0.group == name }.count
                                        return .init(title: name, sub: "\(n) project\(n == 1 ? "" : "s")") { DispatchQueue.main.async { licences(group: name) } }
                                    })
            return
        }
        store.dialog = MCDialog(title: g, opts: [.init(title: "‹ Licences", picked: true) { DispatchQueue.main.async { licences() } }] +
                                MCLicences.parts.filter { $0.group == g }.map { part in
                                    .init(title: part.name, sub: "\(part.licence) · \(part.what)") { licence = part }
                                })
    }

    private func hiddenGames(_ h: TemporaryHost) {
        let ids = store.hidden(h)
        let names = Dictionary(store.apps(h).map { ($0.id ?? "", $0.name ?? "") }, uniquingKeysWith: { a, _ in a })
        var opts: [MCDialog.Opt] = [.init(title: "Done", picked: true) {}]
        if ids.count > 1 {
            opts.append(.init(title: "Show all", sub: "\(ids.count) games") { ids.forEach { store.setHidden(h, $0, false) } })
        }
        for id in ids.sorted() {
            opts.append(.init(title: "Show \(names[id] ?? "game \(id) (not on the PC now)")") { store.setHidden(h, id, false) })
        }
        store.dialog = MCDialog(title: "Hidden on \(h.name)", message: "Pick one to show it again.", opts: opts)
    }

    private func header(_ t: String, _ m: MCMetrics, _ p: MCPalette) -> some View {
        Text(t.uppercased()).mcFont(24, m, weight: .heavy).foregroundColor(p.sub).padding(.top, m.px(18)).padding(.leading, m.px(8))
    }

    /// An icon for each setting, as the handheld's rows have.
    static let icons: [String: String] = [
        "s:res": "rectangle.expand.vertical", "s:fps": "speedometer", "s:rate": "gauge.with.dots.needle.67percent", "s:codec": "film",
        "s:hdr": "sun.max", "s:ull": "bolt", "s:fsr": "sparkles", "s:fsrsharp": "wand.and.rays", "s:pacing": "metronome", "s:stats": "chart.bar", "s:opt": "wand.and.stars",
        "s:spk": "speaker.wave.2", "s:pcaudio": "hifispeaker", "s:feel": "music.note",
        "s:size": "textformat.size", "s:rotate": "rotate.right", "s:touch": "hand.point.up.left", "s:osc": "gamecontroller",
        "s:multi": "person.2", "s:swap": "arrow.left.arrow.right", "s:mouse": "computermouse",
        "s:ps:res": "rectangle.expand.vertical", "s:ps:fps": "speedometer", "s:ps:rate": "gauge.with.dots.needle.67percent",
        "s:ps:codec": "film", "s:ps:disc": "moon.zzz", "s:ps:swap": "arrow.left.arrow.right", "s:theme": "paintpalette",
        "s:profile": "house", "s:profname": "pencil", "s:ps:fsr": "sparkles", "s:xb:fsr": "sparkles", "s:ps:sharp": "wand.and.rays", "s:xb:sharp": "wand.and.rays",
        "s:ps:shape": "aspectratio", "s:xb:shape": "aspectratio", "s:ps:hdr": "sun.max", "s:bg": "circle.lefthalf.striped.horizontal", "s:444": "circle.grid.cross", "s:range": "circle.lefthalf.filled", "s:shape": "aspectratio", "s:osctrans": "square.on.square.dashed",
        "s:dz": "smallcircle.filled.circle", "s:motion": "gyroscope", "s:xb:dz": "smallcircle.filled.circle",
        "s:ps:awayres": "rectangle.expand.vertical", "s:ps:awayrate": "gauge.with.dots.needle.67percent",
        "s:xb:res": "rectangle.expand.vertical", "s:xb:rate": "gauge.with.dots.needle.67percent", "s:xb:rumble": "waveform",
        "s:xb:swap": "arrow.left.arrow.right", "s:xb:coop": "person.2", "s:usage": "chart.line.uptrend.xyaxis",
    ]

    private func row(_ id: String, icon: String, color: Color, title: String, sub: String?, right: String?, switchOn: Bool? = nil,
                     _ m: MCMetrics, _ p: MCPalette, action: @escaping () -> Void) -> some View {
        HStack(spacing: m.px(26)) {
            Group {
                if icon.count <= 2 && icon.uppercased() == icon {
                    Text(icon).mcFont(24, m, weight: .heavy).foregroundColor(color)
                } else {
                    Image(systemName: icon).font(.system(size: m.px(30), weight: .bold)).foregroundColor(color)
                }
            }
            .frame(width: m.px(72), height: m.px(72))
            .background(RoundedRectangle(cornerRadius: m.px(18)).fill(color.opacity(0.16)))
            VStack(alignment: .leading, spacing: m.px(6)) {
                Text(title).mcFont(32, m).foregroundColor(p.ink).lineLimit(1)
                if let sub = sub { Text(sub).mcFont(24, m, weight: .medium).foregroundColor(p.sub).lineLimit(2) }
            }
            Spacer(minLength: m.px(20))
            if let right = right { Text(right).mcFont(26, m).foregroundColor(p.sub) }
            if let on = switchOn {
                // the handheld's switch: 96 x 52, cyan when on
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? p.ring : p.line).frame(width: m.px(96), height: m.px(52))
                    Circle().fill(Color.white).frame(width: m.px(40), height: m.px(40)).padding(.horizontal, m.px(6))
                }
                .animation(.easeOut(duration: 0.15), value: on)
            }
        }
        .padding(.horizontal, m.px(28))
        .frame(minHeight: max(m.px(112), 56))
        .background(RoundedRectangle(cornerRadius: m.px(20)).fill(p.panel))
        .id(id)
        .mcFocusable(id, corner: m.px(20), ring: p.ring, action: action)
    }

    // MARK: Settings

    private var groups: [(String, String)] {
        [("ipad", MCDevice.name), ("picture", "Picture"), ("sound", "Sound"), ("pads", "Controllers"),
         ("ps", "PlayStation"), ("xbox", "Xbox"), ("theme", "Theme"), ("about", "About")]
    }

    private func settingsPage(_ m: MCMetrics, _ p: MCPalette) -> some View {
        focus.preferred["page"] = "set:\(group)"
        // narrow (a phone held upright): the groups become a row of tabs over full-width settings
        if m.designWidth < 1100 {
            return AnyView(VStack(alignment: .leading, spacing: m.px(20)) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: m.px(12)) {
                            ForEach(groups, id: \.0) { key, label in
                                Text(label).mcFont(28, m, weight: .heavy).foregroundColor(group == key ? p.bg : p.ink)
                                    .padding(.horizontal, m.px(30)).frame(height: max(m.px(72), 44))
                                    .background(Capsule().fill(group == key ? p.ink : p.panel))
                                    .id("set:\(key)")
                                    .mcFocusable("set:\(key)", corner: m.px(36), ring: p.ring) { group = key }
                            }
                        }
                        .padding(.horizontal, m.px(m.edge)).padding(.vertical, m.px(8))
                    }
                    .onChange(of: group) { _, g in withAnimation { proxy.scrollTo("set:\(g)", anchor: .center) } }
                }
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: m.px(14)) { settingRows(m, p) }
                            .padding(.horizontal, m.px(m.edge)).padding(.bottom, m.px(24))
                    }
                    .onChange(of: focus.id) { _, id in if let id = id, id.hasPrefix("s:"), focus.padActive { proxy.scrollTo(id) } }
                }
            }
            .padding(.top, m.px(16)))
        }
        return AnyView(HStack(alignment: .top, spacing: m.px(36)) {
            VStack(alignment: .leading, spacing: m.px(10)) {
                ForEach(groups, id: \.0) { key, label in
                    Text(label).mcFont(30, m).foregroundColor(group == key ? p.bg : p.ink)
                        .padding(.horizontal, m.px(28))
                        .frame(maxWidth: .infinity, minHeight: max(m.px(84), 48), alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: m.px(18)).fill(group == key ? p.ink : Color.clear))
                        .mcFocusable("set:\(key)", corner: m.px(18), ring: p.ring) { group = key }
                }
            }
            .frame(width: m.px(m.portrait ? 300 : 360))
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: m.px(14)) { settingRows(m, p) }
                        .padding(.bottom, m.px(24))
                }
                .onChange(of: focus.id) { _, id in if let id = id, id.hasPrefix("s:"), focus.padActive { proxy.scrollTo(id) } }
            }
        }
        .padding(.horizontal, m.px(m.edge))
        .padding(.top, m.px(24)))
    }

    @ViewBuilder
    private func settingRows(_ m: MCMetrics, _ p: MCPalette) -> some View {
        let v = settings.load()
        switch group {
        case "picture":
            let profs = MCSettings.profiles
            choice("s:profile", "Streaming profile", "Each keeps its own picture, sound, PlayStation and Xbox settings. Away suits a slow or far network; the custom ones are yours to name",
                   profs.map(MCSettings.profileName), profs.firstIndex(of: MCSettings.profile) ?? 0, m, p) { i in settings.switchProfile(to: profs[i]) }
            if MCSettings.profile.hasPrefix("c") {
                row("s:profname", icon: "pencil", color: p.sub, title: "Rename this profile", sub: "Now \"\(MCSettings.profileName(MCSettings.profile))\"", right: nil, m, p) {
                    askText("Name this profile", "A name, like Hotel or Office") { n in MCSettings.renameProfile(MCSettings.profile, n); settingsRev += 1 }
                }
            }
            let native = MCSettings.native
            let res: [(String, (Int, Int))] = [("720p", (1280, 720)), ("1080p", (1920, 1080)), ("1440p", (2560, 1440)), ("4K", (3840, 2160)),
                                               ("Native \(native.0)×\(native.1)", native)]
            choice("s:res", "Resolution", "Native matches this screen. Higher needs a faster network", res.map { $0.0 },
                   res.firstIndex { $0.1.0 == v.width && $0.1.1 == v.height } ?? -1,
                   other: "\(v.width)×\(v.height)", m, p) { i in
                settings.save { $0.width = res[i].1.0; $0.height = res[i].1.1; $0.bitrate = MCRoot.defaultBitrate($0.width, $0.height, $0.framerate) }
            }
            let maxFps = UIScreen.main.maximumFramesPerSecond
            let fps = [30, 60, 90, 120].filter { $0 <= max(60, maxFps) }
            let topFps = max(60, maxFps)
            choice("s:fps", "Frame rate", "60 is smooth. 120 needs a ProMotion screen and a fast PC", fps.map { "\($0) fps" } + ["Custom…"],
                   fps.firstIndex(of: v.framerate) ?? -1, other: "\(v.framerate) fps", m, p) { i in
                if i == fps.count {
                    askText("Custom frame rate", "15 to \(topFps) fps") { t in
                        guard let n = Int(t.trimmingCharacters(in: .whitespaces)) else { return }
                        settings.save { $0.framerate = max(15, min(topFps, n)); $0.bitrate = MCRoot.defaultBitrate($0.width, $0.height, $0.framerate) }
                        settingsRev += 1
                    }
                    return
                }
                settings.save { $0.framerate = fps[i]; $0.bitrate = MCRoot.defaultBitrate($0.width, $0.height, $0.framerate) }
            }
            let auto = MCRoot.defaultBitrate(v.width, v.height, v.framerate)
            let rates = [5, 10, 15, 20, 30, 40, 50, 80, 100, 150].map { $0 * 1000 }
            choice("s:rate", "Bitrate", "Auto suits the resolution and frame rate. Higher looks better on a fast network",
                   ["Auto (\(auto / 1000) Mbps)"] + rates.map { "\($0 / 1000) Mbps" } + ["Custom…"],
                   v.bitrate == auto ? 0 : (rates.firstIndex(of: v.bitrate).map { $0 + 1 } ?? -1),
                   other: String(format: "%.1f Mbps", Double(v.bitrate) / 1000), m, p) { i in
                if i == rates.count + 1 {
                    askText("Custom bitrate", "0.5 to 150 Mbps") { t in
                        guard let n = Double(t.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) else { return }
                        settings.save { $0.bitrate = Int((max(0.5, min(150, n)) * 2).rounded()) * 500 }
                        settingsRev += 1
                    }
                    return
                }
                settings.save { $0.bitrate = i == 0 ? auto : rates[i - 1] }
            }
            choice("s:codec", "Video codec", "HEVC and AV1 look better at the same bitrate", ["Auto", "H.264", "HEVC", "AV1"],
                   Int(v.codec), m, p) { i in settings.save { $0.codec = UInt32(i) } }
            toggle("s:444", "YUV 4:4:4 (HEVC)", "Full colour detail: sharper text and coloured edges. Needs HEVC and a PC whose Sunshine offers 4:4:4; not with Super resolution",
                   UserDefaults.standard.bool(forKey: "mc_yuv444"), m, p) {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "mc_yuv444"), forKey: "mc_yuv444") }
            let fsrOn = UserDefaults.standard.string(forKey: "mc_super_resolution") == "fsr1"
            choice("s:fsr", "Super resolution", "AMD FSR 1.0 sharpens a lower resolution up to this screen. For PC, PS5 and Xbox; not with HDR",
                   ["Off", "FSR 1.0"], fsrOn ? 1 : 0, m, p) { i in UserDefaults.standard.set(i == 1 ? "fsr1" : "off", forKey: "mc_super_resolution") }
            if fsrOn {
                let sharp = [0, 20, 40, 60, 80, 100]
                choice("s:fsrsharp", "Sharpening", "How crisp FSR makes edges. Lower it if you see halos", sharp.map { "\($0)%" },
                       sharp.firstIndex(of: UserDefaults.standard.object(forKey: "mc_fsr_sharpness") as? Int ?? 60) ?? 3, m, p) { i in
                    UserDefaults.standard.set(sharp[i], forKey: "mc_fsr_sharpness") }
            }
            toggle("s:hdr", "HDR", "Only when the PC, the game and this screen support it", v.hdr, m, p) { settings.save { $0.hdr.toggle() } }
            let ud = UserDefaults.standard
            toggle("s:range", "Full range colour", "Experimental. Deeper blacks if the PC sends them; looks washed out or crushed if not",
                   ud.bool(forKey: "mc_full_range"), m, p) { ud.set(!ud.bool(forKey: "mc_full_range"), forKey: "mc_full_range") }
            let shapes = ["fit", "zoom", "fill", "stretch"]
            choice("s:shape", "Picture shape", "Fit shows all of it. Zoom halves the bars, trimming the sides only slightly. Fill crops the edges to fill the screen. Stretch fills it and changes the shape",
                   ["Fit", "Zoom", "Fill", "Stretch"], shapes.firstIndex(of: MCPictureShape.current) ?? 0, m, p) { i in ud.set(shapes[i], forKey: "mc_picture_shape") }
            choice("s:pacing", "Frame pacing", "Trade a little delay for smoother motion", ["Lowest delay", "Smoothest"],
                   v.pacing ? 1 : 0, m, p) { i in settings.save { $0.pacing = i == 1 } }
            toggle("s:ull", "Ultra low latency", "Shows each PC frame the moment it's decoded and keeps sound close behind on PS5 and Xbox. A rough Wi-Fi can stutter more",
                   UserDefaults.standard.bool(forKey: "mc_ultra_low_latency"), m, p) {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "mc_ultra_low_latency"), forKey: "mc_ultra_low_latency")
            }
            let levels = ["off", "lite", "detailed"]
            choice("s:stats", "Stats while playing", "Lite: the main numbers in a row at the top. Detailed: every number in a panel at the top left. For PC, PS5 and Xbox",
                   ["Off", "Lite", "Detailed"], levels.firstIndex(of: MCStatsLevel.current) ?? 0, m, p) { i in MCStatsLevel.set(levels[i]) }
            toggle("s:opt", "Let the PC set game settings", "Sunshine and GeForce change the game's resolution to match", v.optimize, m, p) {
                settings.save { $0.optimize.toggle() }
            }
        case "sound":
            let ch = [2, 6, 8]
            choice("s:spk", "Speakers", "Stereo for the built-in speakers and headphones", ["Stereo", "5.1", "7.1"],
                   ch.firstIndex(of: v.audio) ?? 0, m, p) { i in settings.save { $0.audio = ch[i] } }
            toggle("s:pcaudio", "Also play sound on the PC", "Useful when someone's in the room with it", v.audioOnPC, m, p) {
                settings.save { $0.audioOnPC.toggle() }
            }
            toggle("s:feel", "Menu sounds", "Soft sounds as you move around the menus. Games aren't affected", MCFeel.enabled, m, p) {
                UserDefaults.standard.set(!MCFeel.enabled, forKey: "hh_feel_sounds")
            }
        case "ipad":
            let sizes = ["auto", "compact", "normal", "large"]
            choice("s:size", "Screen size", "Auto fits this screen. Compact and Large make everything bigger", ["Auto", "Compact", "Normal", "Large"],
                   sizes.firstIndex(of: screenSize) ?? 0, m, p) { i in screenSize = sizes[i] }
            toggle("s:rotate", "Screen turns with the device", "Off keeps it on its side", rotate, m, p) {
                rotate.toggle()
                MCLaunch.updateOrientation()
            }
            let dim = UserDefaults.standard.object(forKey: "hh_dim_on_tv") as? Bool ?? true
            toggle("s:dim", "Dim the screen on a TV", "While this \(MCDevice.name) is the controller for a TV", dim, m, p) {
                UserDefaults.standard.set(!dim, forKey: "hh_dim_on_tv")
            }
            let touch = ["off", "mouse", "touch"]
            let curTouch = UserDefaults.standard.string(forKey: "mc_touch_default") ?? "touch"
            choice("s:touch", "Touch screen", "In PC games. Touch clicks where you tap, Mouse makes the screen a trackpad, Off ignores the screen",
                   ["Off", "Mouse", "Touch"], touch.firstIndex(of: curTouch) ?? 0, m, p) { i in
                UserDefaults.standard.set(touch[i], forKey: "mc_touch_default")
                // Moonlight's own setting: Touch also allows pinch to zoom and turns the on-screen controller off
                settings.save { $0.absoluteTouch = i == 2 }
            }
            choice("s:osc", "On-screen controller", "Auto shows it when no controller is connected", ["Off", "Auto", "Simple", "Full"],
                   min(v.onscreen, 3), m, p) { i in settings.save { $0.onscreen = i } }
            if v.onscreen != 0 {
                let see = [0, 15, 30, 50, 70, 85]
                choice("s:osctrans", "Controller transparency", "How much of the game shows through the on-screen controller",
                       see.map { "\($0)%" }, see.firstIndex(of: UserDefaults.standard.integer(forKey: "mc_osc_transparency")) ?? 0, m, p) { i in
                    UserDefaults.standard.set(see[i], forKey: "mc_osc_transparency") }
            }
        case "pads":
            row("s:padtest", icon: "gamecontroller", color: MCPalette.blue, title: "Test a controller",
                sub: "See every button, stick and trigger live, and try the rumble", right: nil, m, p) { padTest = true }
            row("s:padpair", icon: "plus.circle", color: MCPalette.green, title: "Pair a controller",
                sub: "Put the pad in pairing mode, then pick it in the \(MCDevice.name)'s Settings → Bluetooth", right: nil, m, p) {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            toggle("s:multi", "More than one player", "On a PC each pad is its own player", v.multi, m, p) { settings.save { $0.multi.toggle() } }
            toggle("s:swap", "Swap A and B", "For Nintendo-style layouts", v.swapAB, m, p) { settings.save { $0.swapAB.toggle() } }
            let dzs = [0, 3, 5, 7, 10, 15]
            choice("s:dz", "Stick deadzone", "Raise it if a worn stick drifts in PC games", dzs.map { $0 == 0 ? "Off" : "\($0)%" },
                   dzs.firstIndex(of: UserDefaults.standard.object(forKey: "mc_stick_deadzone") as? Int ?? 7) ?? 3, m, p) { i in
                UserDefaults.standard.set(dzs[i], forKey: "mc_stick_deadzone") }
            let motion = UserDefaults.standard.object(forKey: "mc_motion") as? Bool ?? true
            toggle("s:motion", "Motion", "Lets PC games use the controller's gyro, as on a DualSense or DualShock", motion, m, p) {
                UserDefaults.standard.set(!motion, forKey: "mc_motion") }
            toggle("s:mouse", "Mouse and trackpad", "Use a connected mouse or the Magic Keyboard's trackpad in PC games", v.btMouse, m, p) {
                settings.save { $0.btMouse.toggle() }
            }
            info("s:combo", "Quick menu", "Select + Start + LB + RB, or swipe from the left edge", m, p)
        case "ps":
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
                    sub: "Sign in once to link a PS5 to this \(MCDevice.name)", right: "Sign in", m, p) {
                    signInPsn { _ in settingsRev += 1 }
                }
            }
            row("s:ps:add", icon: "plus.circle", color: MCPalette.blue, title: "Add a PlayStation 5", sub: "Link it with the 8-digit code on its screen", right: nil, m, p) {
                linkPs5()
            }
            choice("s:ps:res", "Resolution", "The PS5 streams up to 1080p", ["720p", "1080p"], MCPs5Store.height >= 1080 ? 1 : 0, m, p) { i in
                d.set(i == 1 ? 1080 : 720, forKey: "ps5_resolution") }
            choice("s:ps:fps", "Frame rate", "60 fps is smoother; 30 fps lets a weak link keep up", ["30 fps", "60 fps"], MCPs5Store.fps >= 60 ? 1 : 0, m, p) { i in
                d.set(i == 1 ? 60 : 30, forKey: "ps5_fps") }
            let rates = [0, 10, 15, 20, 30, 50, 80, 100]
            choice("s:ps:rate", "Bitrate", "Auto: 30 Mbps at 1080p, 15 at 720p. 80–100 Mbps needs a strong 5 GHz or 6 GHz Wi-Fi", rates.map { $0 == 0 ? "Auto" : "\($0) Mbps" } + ["Custom…"],
                   rates.firstIndex(of: MCPs5Store.bitrate) ?? -1, other: "\(MCPs5Store.bitrate) Mbps", m, p) { i in
                if i == rates.count { customPs5Rate("ps5_bitrate") } else { d.set(rates[i], forKey: "ps5_bitrate") } }
            choice("s:ps:codec", "Video codec", "HEVC looks better at the same bitrate", ["H.264", "HEVC"], MCPs5Store.h265 ? 1 : 0, m, p) { i in
                d.set(i == 1, forKey: "ps5_h265") }
            let disc = ["ask", "rest", "keep"]
            choice("s:ps:disc", "When I disconnect", "What happens to the PS5 after you leave a game", ["Ask", "Rest mode", "Keep it on"],
                   disc.firstIndex(of: MCPs5Store.onDisconnect) ?? 0, m, p) { i in d.set(disc[i], forKey: "ps5_on_disconnect") }
            toggle("s:ps:swap", "Swap Cross and Circle", "For the Japanese layout", MCPs5Store.swapCrossCircle, m, p) {
                d.set(!MCPs5Store.swapCrossCircle, forKey: "ps5_swap_cross_circle") }
            row("s:ps:pin", icon: "lock", color: p.sub, title: "Console PIN", sub: "Signs in for you when the PS5 asks for its 4-digit login PIN",
                right: MCPs5Store.loginPin.isEmpty ? "Not set" : "••••", m, p) {
                askText("Console PIN", "4 digits, empty to turn it off") { v in
                    UserDefaults.standard.set(v.filter(\.isNumber).prefix(4).description, forKey: "ps5_login_pin"); settingsRev += 1 }
            }
            header("Picture", m, p)
            consolePicture("ps", "ps5", m, p)
            let hdrOn = d.bool(forKey: "ps5_hdr")
            toggle("s:ps:hdr", "HDR", MCPs5Store.h265 ? "HDR from the PS5 (HEVC 10-bit) on this HDR screen. Super resolution stays off with it" : "Needs Video codec HEVC",
                   hdrOn, m, p) { d.set(!hdrOn, forKey: "ps5_hdr") }
            info("s:ps:pace", "Frame pacing", "The PS5 picture is shown the moment it's decoded on this \(MCDevice.name)", m, p)
            header("Away from home", m, p)
            choice("s:ps:awayres", "Resolution", "Over PlayStation Network. Lower keeps a weak link smooth", ["540p", "720p", "1080p"],
                   [540, 720, 1080].firstIndex(of: MCPs5Store.awayHeight) ?? 1, m, p) { i in d.set([540, 720, 1080][i], forKey: "ps5_away_resolution") }
            let awayRates = [0, 5, 8, 10, 15]
            choice("s:ps:awayrate", "Bitrate", "Auto: 10 Mbps", awayRates.map { $0 == 0 ? "Auto" : "\($0) Mbps" } + ["Custom…"],
                   awayRates.firstIndex(of: MCPs5Store.awayBitrate) ?? -1, other: "\(MCPs5Store.awayBitrate) Mbps", m, p) { i in
                if i == awayRates.count { customPs5Rate("ps5_away_bitrate") } else { d.set(awayRates[i], forKey: "ps5_away_bitrate") } }
            info("s:ps:btn", "PS button", "L2 + Start on pads without one", m, p)
            info("s:ps:touch", "Touchpad", "Select + Start, or touch the screen while playing", m, p)
        case "xbox":
            let d = UserDefaults.standard
            if MCXbox.signedIn {
                row("s:xb:acct", icon: "person.crop.circle", color: MCPalette.green, title: "Xbox network",
                    sub: MCXbox.gamertag.map { "Signed in as \($0)" } ?? "Signed in, no Xbox profile. Sign out and use your Xbox account", right: "Sign out", m, p) {
                    confirm("Sign out of Xbox?", "Your Xbox consoles leave this \(MCDevice.name) until you sign in again.", yes: "Sign out") {
                        MCXbox.signOut(); settingsRev += 1
                    }
                }
            } else {
                row("s:xb:acct", icon: "person.crop.circle", color: MCPalette.green, title: "Xbox network",
                    sub: "Sign in once to play your Xbox here, at home or away", right: "Sign in", m, p) { xboxSignIn() }
            }
            let res = [0, 720, 1080, 1081]
            choice("s:xb:res", "Picture", "The Xbox sets quality from this", ["Auto", "720p", "1080p", "1080p high"],
                   res.firstIndex(of: MCXbox.resolution) ?? 0, m, p) { i in d.set(res[i], forKey: "xbox_resolution") }
            let caps = [0, 5, 10, 15, 20, 30]
            choice("s:xb:rate", "Bitrate", "Auto lets the Xbox decide. A cap keeps a weak Wi-Fi from stuttering", caps.map { $0 == 0 ? "Auto" : "\($0) Mbps" },
                   caps.firstIndex(of: MCXbox.maxMbps) ?? 0, m, p) { i in d.set(caps[i], forKey: "xbox_bitrate") }
            let rumbles = ["off", "weak", "medium", "strong"]
            choice("s:xb:rumble", "Rumble", "How strongly the controller shakes", ["Off", "Weak", "Medium", "Strong"],
                   rumbles.firstIndex(of: d.string(forKey: "xbox_rumble") ?? "strong") ?? 3, m, p) { i in d.set(rumbles[i], forKey: "xbox_rumble") }
            toggle("s:xb:swap", "Swap A and B", "For Nintendo-style layouts", MCXbox.swapAB, m, p) { d.set(!MCXbox.swapAB, forKey: "xbox_swap_ab") }
            toggle("s:xb:coop", "Two players", "A second controller plays as player 2", MCXbox.coop, m, p) { d.set(!MCXbox.coop, forKey: "xbox_coop") }
            header("Picture", m, p)
            consolePicture("xb", "xbox", m, p)
            info("s:xb:hdr", "HDR", "Not available: Xbox Remote Play streams without HDR", m, p)
            info("s:xb:pace", "Frame pacing", "The Xbox paces its own stream", m, p)
            let xdz = [0, 3, 5, 8, 10, 15]
            choice("s:xb:dz", "Stick deadzone", "Raise it if a worn stick drifts", xdz.map { $0 == 0 ? "Off" : "\($0)%" },
                   xdz.firstIndex(of: d.object(forKey: "xbox_deadzone") as? Int ?? 8) ?? 3, m, p) { i in d.set(xdz[i], forKey: "xbox_deadzone") }
        case "theme":
            let themes = ["dark", "light", "oled"]
            choice("s:theme", "Theme", "Dark is charcoal with white type, Light the reverse. OLED is true black: deeper, and easier on an OLED screen's battery",
                   ["Dark", "Light", "OLED"], themes.firstIndex(of: theme) ?? 0, m, p) { i in theme = themes[i] }
            let bgs = ["game", "static"]
            choice("s:bg", "Background", "Follows the game tints it with the selected game's colour. Static keeps the theme's own colour",
                   ["Follows the game", "Static"], bgs.firstIndex(of: UserDefaults.standard.string(forKey: "hh_background") ?? "game") ?? 0, m, p) { i in
                UserDefaults.standard.set(bgs[i], forKey: "hh_background") }
        default:
            let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            info("s:ver", "MoonCast for \(MCDevice.name)", "Version \(ver) (\(build))", m, p)
            row("s:lic", icon: "doc.text", color: p.sub, title: "Open-source licences",
                sub: "The \(MCLicences.parts.count) projects MoonCast is built on, and their licences", right: nil, m, p) { licences() }
            row("s:src", icon: "chevron.left.forwardslash.chevron.right", color: p.sub, title: "Source code",
                sub: "github.com/MoonCastDev · \(MCLicences.sourceLicence)", right: nil, m, p) {
                if let u = URL(string: MCLicences.source) { UIApplication.shared.open(u) }
            }
            if MCUsage.available {
                toggle("s:usage", "Anonymous usage check-in", "Once a day: version, device model, and whether PC, PS5 or Xbox was played",
                       MCUsage.enabled, m, p) { MCUsage.answer(!MCUsage.enabled) }
            }
        }
    }

    /// A console's own Super resolution, Sharpening and Picture shape; "Same as Picture" until set.
    @ViewBuilder
    private func consolePicture(_ id: String, _ kind: String, _ m: MCMetrics, _ p: MCPalette) -> some View {
        let d = UserDefaults.standard
        let srs = ["same", "off", "fsr1"]
        let sr = d.string(forKey: "\(kind)_super_resolution") ?? "same"
        choice("s:\(id):fsr", "Super resolution", "Same as Picture, or its own: AMD FSR 1.0 sharpens a lower resolution up to this screen",
               ["Same as Picture", "Off", "FSR 1.0"], srs.firstIndex(of: sr) ?? 0, m, p) { i in d.set(srs[i], forKey: "\(kind)_super_resolution") }
        if MCFsr.enabled(kind) {
            let sharp = [-1, 0, 20, 40, 60, 80, 100]
            let cur = d.object(forKey: "\(kind)_fsr_sharpness") as? Int ?? -1
            choice("s:\(id):sharp", "Sharpening", "How crisp FSR makes edges", sharp.map { $0 < 0 ? "Same as Picture" : "\($0)%" },
                   sharp.firstIndex(of: cur) ?? 0, m, p) { i in
                if sharp[i] < 0 { d.removeObject(forKey: "\(kind)_fsr_sharpness") } else { d.set(sharp[i], forKey: "\(kind)_fsr_sharpness") } }
        }
        let shapes = ["same", "fit", "zoom", "fill", "stretch"]
        choice("s:\(id):shape", "Picture shape", "Same as Picture, or its own: Fit, Zoom, Fill or Stretch",
               ["Same as Picture", "Fit", "Zoom", "Fill", "Stretch"], shapes.firstIndex(of: d.string(forKey: "\(kind)_picture_shape") ?? "same") ?? 0, m, p) { i in
            d.set(shapes[i], forKey: "\(kind)_picture_shape") }
    }

    /// Settings → PlayStation → Bitrate → Custom: 2 to 100 Mbps (the PS5 takes up to 100, as PXPlay uses).
    private func customPs5Rate(_ key: String) {
        askText("Custom bitrate", "2 to 100 Mbps") { t in
            guard let n = Double(t.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) else { return }
            UserDefaults.standard.set(Int(max(2, min(100, n)).rounded()), forKey: key)
            settingsRev += 1
        }
    }

    private func choice(_ id: String, _ title: String, _ sub: String, _ opts: [String], _ cur: Int, other: String? = nil,
                        _ m: MCMetrics, _ p: MCPalette, pick: @escaping (Int) -> Void) -> some View {
        let value = cur >= 0 && cur < opts.count ? opts[cur] : (other ?? "")
        return row(id, icon: MCRoot.icons[id] ?? "slider.horizontal.3", color: p.sub, title: title, sub: sub, right: value, m, p) {
            store.dialog = MCDialog(title: title, message: sub, opts: opts.enumerated().map { i, o in
                .init(title: o + (i == cur ? "  ✓" : ""), picked: i == cur) { pick(i); settingsRev += 1 }
            })
        }
    }

    private func toggle(_ id: String, _ title: String, _ sub: String, _ on: Bool, _ m: MCMetrics, _ p: MCPalette,
                        flip: @escaping () -> Void) -> some View {
        row(id, icon: MCRoot.icons[id] ?? "switch.2", color: p.sub, title: title, sub: sub, right: nil, switchOn: on, m, p) {
            flip(); settingsRev += 1
        }
    }

    private func info(_ id: String, _ title: String, _ sub: String, _ m: MCMetrics, _ p: MCPalette) -> some View {
        row(id, icon: "info.circle", color: p.sub, title: title, sub: sub, right: nil, m, p) {}
    }

    /// Moonlight's default (from Moonlight Qt): by resolution, and frame rate up to 60, square root above.
    static func defaultBitrate(_ w: Int, _ h: Int, _ fps: Int) -> Int {
        let f = Float(fps)
        let fpsFactor = (f <= 60 ? f : sqrtf(f / 60) * 60) / 30
        let table: [(Int, Float)] = [(640 * 360, 1), (854 * 480, 2), (1280 * 720, 5), (1920 * 1080, 10), (2560 * 1440, 20), (3840 * 2160, 40)]
        let px = w * h
        var res: Float = table.last!.1
        for (i, e) in table.enumerated() {
            if px == e.0 { res = e.1; break }
            if px < e.0 {
                res = i == 0 ? e.1 : Float(px - table[i - 1].0) / Float(e.0 - table[i - 1].0) * (e.1 - table[i - 1].1) + table[i - 1].1
                break
            }
        }
        return min(Int((res * fpsFactor).rounded()) * 1000, 150000)
    }

    // MARK: dialogs

    private func confirm(_ title: String, _ msg: String, yes: String, run: @escaping () -> Void) {
        // a new dialog after the menu closes
        DispatchQueue.main.async {
            store.dialog = MCDialog(title: title, message: msg, opts: [.init(title: "Cancel", picked: true) {},
                                                                       .init(title: yes, danger: true, run: run)])
        }
    }

    private func closeDialog(cancel: Bool) {
        guard let d = store.dialog else { return }
        store.dialog = nil
        if cancel, let c = d.opts.first(where: { $0.title == "Cancel" || $0.title == "Done" }) { c.run() }
    }

    private func dialogView(_ d: MCDialog, _ m: MCMetrics, _ p: MCPalette) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { closeDialog(cancel: true) }
            VStack(alignment: .leading, spacing: m.px(18)) {
                Text(d.title).mcFont(38, m, weight: .heavy).foregroundColor(p.ink).fixedSize(horizontal: false, vertical: true)
                if let msg = d.message { Text(msg).mcFont(26, m, weight: .medium).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true) }
                if let big = d.big {
                    Text(big).font(.system(size: m.px(96), weight: .heavy, design: .monospaced)).foregroundColor(p.ring)
                        .frame(maxWidth: .infinity).padding(.vertical, m.px(10))
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: m.px(10)) {
                        ForEach(d.opts.indices, id: \.self) { i in
                            let o = d.opts[i]
                            HStack {
                                VStack(alignment: .leading, spacing: m.px(4)) {
                                    Text(o.title).mcFont(30, m).foregroundColor(o.danger ? MCPalette.red : p.ink)
                                    if let s = o.sub { Text(s).mcFont(22, m, weight: .medium).foregroundColor(p.sub) }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, m.px(26))
                            .frame(minHeight: max(m.px(88), 48))
                            .background(RoundedRectangle(cornerRadius: m.px(16)).fill(p.tile.opacity(0.6)))
                            .mcFocusable("d:\(i)", scope: "dialog", corner: m.px(16), ring: p.ring) {
                                store.dialog = nil
                                o.run()
                            }
                        }
                    }
                    .padding(m.px(8))
                }
                .frame(maxHeight: m.px(m.designHeight * 0.5))
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(m.px(40))
            .frame(width: min(m.px(820), m.size.width - 40))
            .background(RoundedRectangle(cornerRadius: m.px(28)).fill(p.panel))
        }
    }

    private func busyView(_ text: String, _ m: MCMetrics, _ p: MCPalette) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            HStack(spacing: m.px(24)) {
                ProgressView().scaleEffect(1.3)
                Text(text).mcFont(30, m).foregroundColor(p.ink)
            }
            .padding(m.px(40))
            .background(RoundedRectangle(cornerRadius: m.px(28)).fill(p.panel))
        }
    }
}

/// Your own picture for a tile (CustomArt.kt): kept in Application Support/tile-art.
enum MCArt {
    private static let cache = NSCache<NSString, UIImage>()
    private static var tints: [String: Color] = [:]

    private static func url(_ key: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tile-art")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent(name + ".jpg")
    }

    static func image(_ key: String) -> UIImage? {
        if let i = cache.object(forKey: key as NSString) { return i }
        guard let i = UIImage(contentsOfFile: url(key).path) else { return nil }
        cache.setObject(i, forKey: key as NSString)
        return i
    }

    static func save(_ key: String, _ img: UIImage) {
        // a square crop at 720 px is plenty for a tile
        let side = min(img.size.width, img.size.height)
        let s: CGFloat = min(720, side)
        let r = UIGraphicsImageRenderer(size: CGSize(width: s, height: s))
        let out = r.image { _ in
            let k = s / side
            img.draw(in: CGRect(x: -(img.size.width - side) / 2 * k, y: -(img.size.height - side) / 2 * k,
                                width: img.size.width * k, height: img.size.height * k))
        }
        try? out.jpegData(compressionQuality: 0.85)?.write(to: url(key))
        cache.setObject(out, forKey: key as NSString)
        tints.removeValue(forKey: key)
    }

    static func remove(_ key: String) {
        try? FileManager.default.removeItem(at: url(key))
        cache.removeObject(forKey: key as NSString)
        tints.removeValue(forKey: key)
    }

    /// The picture's average colour, for the background wash.
    static func tint(_ key: String) -> Color? {
        if let t = tints[key] { return t }
        guard let img = image(key), let cg = img.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let c = Color(.sRGB, red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255)
        tints[key] = c
        return c
    }
}

/// Screens build in: each part rises and fades in, 55 ms after the one before (the handheld's entrance).
struct MCRise: ViewModifier {
    let order: Int
    let tick: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 24)
            .onAppear { rise() }
            .onChange(of: tick) { _, _ in shown = false; rise() }
    }

    private func rise() {
        withAnimation(.easeOut(duration: 0.35).delay(0.055 * Double(order))) { shown = true }
    }
}
