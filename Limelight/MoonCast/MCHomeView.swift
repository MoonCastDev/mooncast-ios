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
    @AppStorage("hh_screen_size") private var screenSize = "auto"
    @AppStorage("hh_rotate") private var rotate = true

    private let settings = MCSettings()
    /// Set by the controller: asks for text (a PC's address) with the system's keyboard dialog.
    var askText: (String, String, @escaping (String) -> Void) -> Void = { _, _, _ in }
    /// Set by the controller: Sony's sign-in page; true when signed in.
    var signInPsn: (@escaping (Bool) -> Void) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let m = MCMetrics(size: geo.size, scale: screenSize == "compact" ? 1.12 : screenSize == "large" ? 1.25 : 1)
            let p = MCPalette(light: theme == "light")
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
                if let d = store.dialog { dialogView(d, m, p) }
                if let b = store.busy { busyView(b, m, p) }
            }
            .preferredColorScheme(theme == "light" ? .light : .dark)
        }
        .mcCollectFrames()
        .onAppear { hookButtons(); testStart() }
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
        if let pg = env["MC_PAGE"], let target = [MCPage.home, .games, .consoles, .settings].first(where: { $0.rawValue.lowercased().hasPrefix(pg.lowercased()) || (pg == "games" && $0 == .games) }) {
            go(target)
        }
        #endif
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
                    Text("Playing on this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")")
                        .mcFont(26, m).foregroundColor(p.ink)
                }
                .padding(.horizontal, m.px(30))
                .frame(height: m.px(84))
                .background(Capsule().fill(p.panel))
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
        let c = focusedGame().map { g -> Color in MCArt.tint(g.key) ?? Covers.tint(g.seed) }
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
        return store.allGames().first { $0.key == key }
    }

    // MARK: Home

    private func homePage(_ m: MCMetrics, _ p: MCPalette) -> some View {
        let games = store.homeGames()
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
                            tile(g, kind: "game", label: g.title, size: ts, m, p) { store.play(g) }
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
            ("Controllers", "gamecontroller.fill", MCPalette.blue, { store.controllersDialog() }),
            ("Network", "wifi", MCPalette.green, { store.networkTest() }),
            ("Settings", "gearshape.fill", p.sub, { go(.settings) }),
        ]
        return HStack(alignment: .top, spacing: m.px(m.portrait ? 60 : 96)) {
            ForEach(items, id: \.0) { label, icon, color, run in
                VStack(spacing: m.px(18)) {
                    Image(systemName: icon).font(.system(size: m.px(50), weight: .semibold)).foregroundColor(color)
                        .frame(width: m.px(112), height: m.px(112))
                        .background(Circle().fill(p.panel))
                        .mcFocusable("rb:\(label)", corner: m.px(56), ring: p.ring, action: run)
                    Text(label).mcFont(27, m).foregroundColor(p.label)
                }
                .accessibilityLabel(label)
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
        .mcFocusable(id, corner: corner, ring: p.ring, menu: g.map { g in { gameMenu(g) } }, action: action)
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
                    header("Add", m, p)
                    row("add:pc", icon: "plus", color: MCPalette.green, title: "Add a PC by its address",
                        sub: "When it isn't found by itself (another network, a VPN)", right: nil, m, p) {
                        askText("Add a PC", "The PC's IP address or name") { store.addPc($0) }
                    }
                    row("add:ps", icon: "PS", color: MCPalette.blue, title: "Add a PlayStation 5", sub: "Sign in to PSN and link it with the console's 8-digit code", right: nil, m, p) {
                        linkPs5()
                    }
                    row("add:xb", icon: "XB", color: MCPalette.green, title: "Xbox", sub: "Coming to iPad in a later build", right: nil, m, p) {
                        store.dialog = MCDialog(title: "Xbox on iPad", message: "Xbox Remote Play is on its way to the iPad app. For now it plays PCs.",
                                                opts: [.init(title: "OK") {}])
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
            confirm("Remove \(h.name)?", "Its games leave this iPad until you pair again.", yes: "Remove") { store.remove(h) }
        })
        opts.insert(.init(title: "Cancel", picked: !opts.contains { $0.picked }) {}, at: 0)
        var lines = [h.activeAddress.map { "Address: \($0)" }, h.externalAddress.map { "Away: \($0)" }].compactMap { $0 }
        if lines.count == 2 && h.externalAddress == h.activeAddress { lines.removeLast() }
        store.dialog = MCDialog(title: h.name, message: lines.isEmpty ? nil : lines.joined(separator: "\n"), opts: opts)
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
                                    message: "Once, to link your PS5 to this iPad. Your password goes to Sony only; MoonCast keeps a sign-in token in the iPad's Keychain.",
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

    private func hiddenGames(_ h: TemporaryHost) {
        let ids = store.hidden(h)
        let names = Dictionary(store.apps(h).map { ($0.id ?? "", $0.name ?? "") }, uniquingKeysWith: { a, _ in a })
        var opts: [MCDialog.Opt] = [.init(title: "Done", picked: true) {}]
        for id in ids.sorted() {
            opts.append(.init(title: "Show \(names[id] ?? "game \(id)")") { store.setHidden(h, id, false) })
        }
        store.dialog = MCDialog(title: "Hidden on \(h.name)", message: "Pick one to show it again.", opts: opts)
    }

    private func header(_ t: String, _ m: MCMetrics, _ p: MCPalette) -> some View {
        Text(t.uppercased()).mcFont(24, m, weight: .heavy).foregroundColor(p.sub).padding(.top, m.px(18)).padding(.leading, m.px(8))
    }

    /// An icon for each setting, as the handheld's rows have.
    static let icons: [String: String] = [
        "s:res": "rectangle.expand.vertical", "s:fps": "speedometer", "s:rate": "gauge.with.dots.needle.67percent", "s:codec": "film",
        "s:hdr": "sun.max", "s:pacing": "metronome", "s:stats": "chart.bar", "s:opt": "wand.and.stars",
        "s:spk": "speaker.wave.2", "s:pcaudio": "hifispeaker", "s:feel": "music.note",
        "s:size": "textformat.size", "s:rotate": "rotate.right", "s:touch": "hand.point.up.left", "s:osc": "gamecontroller",
        "s:multi": "person.2", "s:swap": "arrow.left.arrow.right", "s:mouse": "computermouse",
        "s:ps:res": "rectangle.expand.vertical", "s:ps:fps": "speedometer", "s:ps:rate": "gauge.with.dots.needle.67percent",
        "s:ps:codec": "film", "s:ps:disc": "moon.zzz", "s:ps:swap": "arrow.left.arrow.right", "s:theme": "paintpalette",
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
        [("ipad", UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"), ("picture", "Picture"), ("sound", "Sound"), ("pads", "Controllers"),
         ("ps", "PlayStation"), ("theme", "Theme"), ("about", "About")]
    }

    private func settingsPage(_ m: MCMetrics, _ p: MCPalette) -> some View {
        focus.preferred["page"] = "set:\(group)"
        return HStack(alignment: .top, spacing: m.px(36)) {
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
        .padding(.top, m.px(24))
    }

    @ViewBuilder
    private func settingRows(_ m: MCMetrics, _ p: MCPalette) -> some View {
        let v = settings.load()
        switch group {
        case "picture":
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
            choice("s:fps", "Frame rate", "60 is smooth. 120 needs a ProMotion screen and a fast PC", fps.map { "\($0) fps" },
                   fps.firstIndex(of: v.framerate) ?? -1, other: "\(v.framerate) fps", m, p) { i in
                settings.save { $0.framerate = fps[i]; $0.bitrate = MCRoot.defaultBitrate($0.width, $0.height, $0.framerate) }
            }
            let auto = MCRoot.defaultBitrate(v.width, v.height, v.framerate)
            let rates = [5, 10, 15, 20, 30, 40, 50, 80, 100, 150].map { $0 * 1000 }
            choice("s:rate", "Bitrate", "Auto suits the resolution and frame rate. Higher looks better on a fast network",
                   ["Auto (\(auto / 1000) Mbps)"] + rates.map { "\($0 / 1000) Mbps" },
                   v.bitrate == auto ? 0 : (rates.firstIndex(of: v.bitrate).map { $0 + 1 } ?? -1),
                   other: String(format: "%.1f Mbps", Double(v.bitrate) / 1000), m, p) { i in
                settings.save { $0.bitrate = i == 0 ? auto : rates[i - 1] }
            }
            choice("s:codec", "Video codec", "H.265 and AV1 look better at the same bitrate", ["Auto", "H.264", "H.265", "AV1"],
                   Int(v.codec), m, p) { i in settings.save { $0.codec = UInt32(i) } }
            toggle("s:hdr", "HDR", "Only when the PC, the game and this screen support it", v.hdr, m, p) { settings.save { $0.hdr.toggle() } }
            choice("s:pacing", "Frame pacing", "Trade a little delay for smoother motion", ["Lowest delay", "Smoothest"],
                   v.pacing ? 1 : 0, m, p) { i in settings.save { $0.pacing = i == 1 } }
            toggle("s:stats", "Stats while playing", "Frame rate, delay and lost frames in a corner", v.stats, m, p) { settings.save { $0.stats.toggle() } }
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
            let touch = ["off", "mouse", "touch"]
            let curTouch = UserDefaults.standard.string(forKey: "mc_touch_default") ?? "off"
            choice("s:touch", "Touch screen", "In PC games. Mouse is a trackpad, Touch clicks where you tap. The Quick menu switches it while playing",
                   ["Off", "Mouse", "Touch"], touch.firstIndex(of: curTouch) ?? 0, m, p) { i in
                UserDefaults.standard.set(touch[i], forKey: "mc_touch_default")
                // Moonlight's own setting: Touch also allows pinch to zoom and turns the on-screen controller off
                settings.save { $0.absoluteTouch = i == 2 }
            }
            choice("s:osc", "On-screen controller", "Auto shows it when no controller is connected", ["Off", "Auto", "Simple", "Full"],
                   min(v.onscreen, 3), m, p) { i in settings.save { $0.onscreen = i } }
        case "pads":
            row("s:padtest", icon: "gamecontroller", color: MCPalette.blue, title: "Test a controller",
                sub: "See every button, stick and trigger live, and try the rumble", right: nil, m, p) { padTest = true }
            row("s:padpair", icon: "plus.circle", color: MCPalette.green, title: "Pair a controller",
                sub: "Put the pad in pairing mode, then pick it in the iPad's Settings → Bluetooth", right: nil, m, p) {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            toggle("s:multi", "More than one player", "On a PC each pad is its own player", v.multi, m, p) { settings.save { $0.multi.toggle() } }
            toggle("s:swap", "Swap A and B", "For Nintendo-style layouts", v.swapAB, m, p) { settings.save { $0.swapAB.toggle() } }
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
                    sub: "Sign in once to link a PS5 to this iPad", right: "Sign in", m, p) {
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
            let rates = [0, 10, 15, 20, 30]
            choice("s:ps:rate", "Bitrate", "Auto: 30 Mbps at 1080p, 15 at 720p", rates.map { $0 == 0 ? "Auto" : "\($0) Mbps" },
                   rates.firstIndex(of: MCPs5Store.bitrate) ?? 0, m, p) { i in d.set(rates[i], forKey: "ps5_bitrate") }
            choice("s:ps:codec", "Video codec", "H.265 looks better at the same bitrate", ["H.264", "H.265"], MCPs5Store.h265 ? 1 : 0, m, p) { i in
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
            info("s:ps:btn", "PS button", "L2 + Start on pads without one", m, p)
            info("s:ps:touch", "Touchpad", "Select + Start", m, p)
        case "theme":
            choice("s:theme", "Theme", "Dark is charcoal with white type; Light is the reverse", ["Dark", "Light"],
                   theme == "light" ? 1 : 0, m, p) { i in theme = i == 1 ? "light" : "dark" }
        default:
            let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            info("s:ver", "MoonCast for iPad", "Version \(ver) (\(build)). Early build: PC streaming", m, p)
            info("s:lic", "Open source", "Built on Moonlight for iOS (GPL-3.0). github.com/MoonCastDev/mooncast-ios", m, p)
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
