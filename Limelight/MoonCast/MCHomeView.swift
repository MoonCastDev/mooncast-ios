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
    @State private var group = "picture"
    @State private var settingsRev = 0
    @State private var pickingArt: String?
    @State private var photo: PhotosPickerItem?
    @State private var artRev = 0

    private let settings = MCSettings()
    /// Set by the controller: asks for text (a PC's address) with the system's keyboard dialog.
    var askText: (String, String, @escaping (String) -> Void) -> Void = { _, _, _ in }

    var body: some View {
        GeometryReader { geo in
            let m = MCMetrics(size: geo.size)
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
                if let d = store.dialog { dialogView(d, m, p) }
                if let b = store.busy { busyView(b, m, p) }
            }
            .preferredColorScheme(theme == "light" ? .light : .dark)
        }
        .mcCollectFrames()
        .onAppear { hookButtons() }
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

    private func go(_ p: MCPage) {
        page = p
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
        let gap: CGFloat = 32
        let usableW = m.designWidth - 2 * m.edge
        let ts: CGFloat = m.portrait ? min((usableW - gap) / 2, m.designHeight * 0.34) : 380
        let titles = Dictionary(games.map { ("g:\($0.key)", $0.title) }, uniquingKeysWith: { a, _ in a })
        let name = focus.id.flatMap { titles[$0] } ?? (focus.padActive ? nil : games.first?.title)
        focus.preferred["page"] = games.first.map { "g:\($0.key)" } ?? "g:add"
        return VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0).frame(maxHeight: m.px(80))
            Text(name ?? " ").mcFont(34, m).foregroundColor(p.ring).lineLimit(1)
                .padding(.leading, m.px(m.edge)).frame(height: m.px(48))
                .animation(nil, value: name)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: m.px(gap)) {
                        if games.isEmpty {
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
            roundButtons(m, p)
                .padding(.top, m.px(m.portrait ? 64 : 60))
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
    }

    private func roundButtons(_ m: MCMetrics, _ p: MCPalette) -> some View {
        let items: [(String, String, Color, () -> Void)] = [
            ("Consoles", "square.stack.3d.up.fill", MCPalette.cyan, { go(.consoles) }),
            ("Controllers", "gamecontroller.fill", MCPalette.blue, { store.controllersDialog() }),
            ("Settings", "gearshape.fill", p.sub, { go(.settings) }),
        ]
        return HStack(alignment: .top, spacing: m.px(110)) {
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
        let k = min(size / 380, 1.5)
        return ZStack(alignment: .topLeading) {
            Group {
                if let img = custom ?? box {
                    Image(uiImage: img).resizable().scaledToFill()
                } else if let g = g {
                    CoverArt(colors: Covers.colors(g.seed))
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
            if g != nil && box == nil || kind == "add" {
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
                    header("Add", m, p)
                    row("add:pc", icon: "plus", color: MCPalette.green, title: "Add a PC by its address",
                        sub: "When it isn't found by itself (another network, a VPN)", right: nil, m, p) {
                        askText("Add a PC", "The PC's IP address or name") { store.addPc($0) }
                    }
                    row("add:ps", icon: "PS", color: MCPalette.blue, title: "PlayStation 5", sub: "Coming to iPad in a later build", right: nil, m, p) {
                        store.dialog = MCDialog(title: "PlayStation 5 on iPad", message: "PS5 Remote Play is on its way to the iPad app. For now it plays PCs.",
                                                opts: [.init(title: "OK") {}])
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

    private func row(_ id: String, icon: String, color: Color, title: String, sub: String?, right: String?, _ m: MCMetrics, _ p: MCPalette,
                     action: @escaping () -> Void) -> some View {
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
        }
        .padding(.horizontal, m.px(28))
        .frame(minHeight: max(m.px(112), 56))
        .background(RoundedRectangle(cornerRadius: m.px(20)).fill(p.panel))
        .id(id)
        .mcFocusable(id, corner: m.px(20), ring: p.ring, action: action)
    }

    // MARK: Settings

    private var groups: [(String, String)] {
        [("picture", "Picture"), ("sound", "Sound"), ("controls", "Controls"), ("theme", "Theme"), ("about", "About")]
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
        case "controls":
            choice("s:touch", "Touch screen", "In PC games. Mouse is a trackpad, Touch clicks where you tap", ["Mouse", "Touch"],
                   v.absoluteTouch ? 1 : 0, m, p) { i in settings.save { $0.absoluteTouch = i == 1 } }
            choice("s:osc", "On-screen controller", "Auto shows it when no controller is connected", ["Off", "Auto", "Simple", "Full"],
                   min(v.onscreen, 3), m, p) { i in settings.save { $0.onscreen = i } }
            toggle("s:multi", "More than one player", "On a PC each pad is its own player", v.multi, m, p) { settings.save { $0.multi.toggle() } }
            toggle("s:swap", "Swap A and B", "For Nintendo-style layouts", v.swapAB, m, p) { settings.save { $0.swapAB.toggle() } }
            toggle("s:mouse", "Mouse and trackpad", "Use a connected mouse or the Magic Keyboard's trackpad in PC games", v.btMouse, m, p) {
                settings.save { $0.btMouse.toggle() }
            }
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
        return row(id, icon: "slider.horizontal.3", color: p.sub, title: title, sub: sub, right: value, m, p) {
            store.dialog = MCDialog(title: title, message: sub, opts: opts.enumerated().map { i, o in
                .init(title: o + (i == cur ? "  ✓" : ""), picked: i == cur) { pick(i); settingsRev += 1 }
            })
        }
    }

    private func toggle(_ id: String, _ title: String, _ sub: String, _ on: Bool, _ m: MCMetrics, _ p: MCPalette,
                        flip: @escaping () -> Void) -> some View {
        row(id, icon: on ? "checkmark.circle.fill" : "circle", color: on ? p.ring : p.sub, title: title, sub: sub, right: on ? "On" : "Off", m, p) {
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
