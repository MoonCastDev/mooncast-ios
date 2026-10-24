//
//  MCAbout.swift
//  MoonCast: Settings → About on the iPad, as on the handheld (Licences.kt, Usage.kt): the open-source projects
//  MoonCast is built on with each licence's full text (licences.txt, one section per licence), and the opt-in
//  anonymous daily check-in (TelemetryDeck).
//

import SwiftUI
import UIKit
import CryptoKit

enum MCLicences {
    struct Part {
        let group: String, name: String, what: String, licence: String, file: String, url: String
    }

    static let source = "https://github.com/MoonCastDev"
    static let sourceLicence = "GPL-3.0, PS5 and Xbox parts AGPL-3.0"

    static let parts: [Part] = [
        Part(group: "The app", name: "Moonlight for iOS", what: "The app MoonCast for iPad grew from: PC streaming, the on-screen controller", licence: "GPL-3.0", file: "gpl-3.0.txt", url: "https://github.com/moonlight-stream/moonlight-ios"),
        Part(group: "The app", name: "moonlight-common-c", what: "The PC streaming protocol", licence: "GPL-3.0", file: "gpl-3.0.txt", url: "https://github.com/moonlight-stream/moonlight-common-c"),
        Part(group: "The app", name: "AMD FidelityFX Super Resolution 1.0", what: "Super resolution: the upscaling and sharpening (FSR 1)", licence: "MIT", file: "fsr1.txt", url: "https://github.com/GPUOpen-Effects/FidelityFX-FSR"),
        Part(group: "The app", name: "ENet", what: "Inside moonlight-common-c: the network link", licence: "MIT", file: "enet.txt", url: "https://github.com/lsalzman/enet"),
        Part(group: "The app", name: "nanors", what: "Inside moonlight-common-c: repairing lost video", licence: "MIT", file: "nanors.txt", url: "https://github.com/sleepybishop/nanors"),
        Part(group: "The app", name: "FFmpeg", what: "Reading video stream settings", licence: "LGPL-2.1", file: "lgpl-2.1.txt", url: "https://ffmpeg.org"),
        Part(group: "The app", name: "SDL2", what: "Controller details", licence: "Zlib", file: "sdl2.txt", url: "https://www.libsdl.org"),
        Part(group: "The app", name: "Opus", what: "Sound from the PC and the PS5", licence: "BSD-3-Clause", file: "opus.txt", url: "https://opus-codec.org"),
        Part(group: "PS5", name: "chiaki-ng", what: "PS5 Remote Play, with MoonCast's changes (MoonCastDev/chiaki-ng-mooncast)", licence: "AGPL-3.0", file: "agpl-3.0.txt", url: "https://github.com/streetpea/chiaki-ng"),
        Part(group: "PS5", name: "OpenSSL", what: "Encryption for PCs and the PS5", licence: "Apache-2.0", file: "apache-2.0.txt", url: "https://www.openssl.org"),
        Part(group: "PS5", name: "curl", what: "Inside chiaki-ng: PSN sign-in and play away from home", licence: "curl", file: "curl.txt", url: "https://curl.se"),
        Part(group: "PS5", name: "libevent", what: "Inside chiaki-ng: the network loop for play away from home", licence: "BSD-3-Clause", file: "libevent.txt", url: "https://libevent.org"),
        Part(group: "PS5", name: "json-c", what: "Inside chiaki-ng: PSN messages", licence: "MIT", file: "json-c.txt", url: "https://github.com/json-c/json-c"),
        Part(group: "PS5", name: "miniupnpc", what: "Inside chiaki-ng: router port setup (UPnP)", licence: "BSD-3-Clause", file: "miniupnpc.txt", url: "https://github.com/miniupnp/miniupnp"),
        Part(group: "PS5", name: "Jerasure", what: "Inside chiaki-ng: repairing lost video", licence: "BSD-3-Clause", file: "jerasure.txt", url: "https://github.com/streetpea/jerasure"),
        Part(group: "PS5", name: "GF-Complete", what: "Inside chiaki-ng: the maths behind the repair", licence: "BSD-3-Clause", file: "gf-complete.txt", url: "https://github.com/streetpea/gf-complete"),
        Part(group: "PS5", name: "nanopb", what: "Inside chiaki-ng: messages with the console", licence: "Zlib", file: "nanopb.txt", url: "https://github.com/nanopb/nanopb"),
        Part(group: "Xbox", name: "XStreaming", what: "The Xbox Remote Play protocol MoonCast follows", licence: "AGPL-3.0", file: "agpl-3.0.txt", url: "https://github.com/Geocld/XStreaming"),
        Part(group: "Xbox", name: "WebRTC", what: "Xbox video and sound (the stasel/WebRTC build)", licence: "BSD-3-Clause", file: "webrtc.txt", url: "https://webrtc.org"),
        Part(group: "More", name: "Roboto", what: "Moonlight's font", licence: "Apache-2.0", file: "apache-2.0.txt", url: "https://github.com/googlefonts/roboto"),
    ]

    /// licences.txt: "@@@ file" starts each licence's text.
    private static let texts: [String: String] = {
        guard let url = Bundle.main.url(forResource: "licences", withExtension: "txt"),
              let all = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for chunk in all.components(separatedBy: "@@@ ").dropFirst() {
            guard let nl = chunk.firstIndex(of: "\n") else { continue }
            out[String(chunk[..<nl])] = String(chunk[chunk.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }()

    static func text(_ p: Part) -> String { texts[p.file] ?? "See \(p.url)" }
}

/// One licence's full text. The pad steps through it a paragraph at a time; B or Done goes back.
struct MCLicenceView: View {
    let part: MCLicences.Part
    let m: MCMetrics
    let p: MCPalette
    let close: () -> Void
    @ObservedObject private var focus = MCFocus.shared

    var body: some View {
        let paras = MCLicences.text(part).components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        ZStack {
            p.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: m.px(14)) {
                HStack {
                    VStack(alignment: .leading, spacing: m.px(6)) {
                        Text(part.name).mcFont(40, m, weight: .heavy).foregroundColor(p.ink)
                        Text("\(part.licence)  ·  \(part.url)").mcFont(24, m).foregroundColor(p.ring)
                    }
                    Spacer()
                    Text("Done").mcFont(28, m).foregroundColor(p.ink)
                        .padding(.horizontal, m.px(30)).frame(height: m.px(72))
                        .background(Capsule().fill(p.panel))
                        .mcFocusable("lic:done", scope: "lic", corner: m.px(36), ring: p.ring, action: close)
                }
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: m.px(16)) {
                            ForEach(paras.indices, id: \.self) { i in
                                Text(paras[i]).font(.system(size: m.px(21), design: .monospaced)).foregroundColor(p.sub)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(m.px(8))
                                    .id("lic:\(i)")
                                    .mcFocusable("lic:\(i)", scope: "lic", corner: m.px(8), ring: p.ring.opacity(0.5)) {}
                            }
                        }
                        .padding(.vertical, m.px(10))
                    }
                    .onChange(of: focus.id) { _, id in
                        if let id = id, id.hasPrefix("lic:"), focus.padActive { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
            .padding(.horizontal, m.px(m.edge))
            .padding(.vertical, m.px(30))
        }
        .onAppear {
            focus.pushScope("lic")
            focus.preferred["lic"] = "lic:done"
            focus.pageButton = { b in
                if b == .b { close(); return true }
                return false
            }
        }
        .onDisappear { focus.popScope() }
    }
}

/// The anonymous usage check-in, opt-in (Usage.kt). At most once a day when the home opens, and only after a yes:
/// the app version, "ipad" or "iphone", the system version and device model, and whether PC, PS5 or Xbox was played since the
/// last check-in. Never names, addresses, games, accounts or sign-ins. The install is a random ID, sent hashed.
/// Only official builds carry an app ID (MC_TELEMETRY_APP_ID at build time): self-built copies never ask or send.
/// Debug builds send in test mode, which TelemetryDeck keeps out of the real numbers.
enum MCUsage {
    static let pref = "mc_usage_checkin"
    private static let idKey = "mc_usage_id", lastKey = "mc_usage_last", usedKey = "mc_usage_used_"
    private static let d = UserDefaults.standard

    static let question = "Help improve MoonCast?"
    static let explain = "Send an anonymous check-in once a day: the app version, the device model and system version, " +
        "and whether you played PC, PS5 or Xbox. Never names, games, accounts or addresses. You can change this in Settings, About."

    private static var appId: String { (Bundle.main.object(forInfoDictionaryKey: "MCTelemetryAppID") as? String ?? "").trimmingCharacters(in: .whitespaces) }
    private static var namespace: String { (Bundle.main.object(forInfoDictionaryKey: "MCTelemetryNamespace") as? String ?? "").trimmingCharacters(in: .whitespaces) }

    /// This build can send at all (official builds only).
    static var available: Bool { !appId.isEmpty && !appId.hasPrefix("$(") }
    static var shouldAsk: Bool { available && d.object(forKey: pref) == nil }
    static var enabled: Bool { available && d.bool(forKey: pref) }

    static func answer(_ yes: Bool) {
        d.set(yes, forKey: pref)
        if yes { checkIn() }
    }

    /// A stream of this kind started ("pc", "ps5" or "xbox"); goes with the next check-in.
    static func used(_ kind: String) { if enabled { d.set(true, forKey: usedKey + kind) } }

    /// Sends today's check-in if the user said yes and none went today. Never throws, never blocks.
    static func checkIn() {
        guard enabled else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        if d.string(forKey: lastKey) == today { return }
        let id = d.string(forKey: idKey) ?? { let n = UUID().uuidString; d.set(n, forKey: idKey); return n }()
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        var model = pad ? "iPad" : "iPhone"
        var sys = utsname()
        if uname(&sys) == 0 {
            model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        var payload: [String: String] = [
            "TelemetryDeck.AppInfo.version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "TelemetryDeck.Device.platform": pad ? "iPadOS" : "iOS",
            "TelemetryDeck.Device.operatingSystem": pad ? "iPadOS" : "iOS",
            "TelemetryDeck.Device.systemVersion": UIDevice.current.systemVersion,
            "TelemetryDeck.Device.modelName": model,
            "MoonCast.app": pad ? "ipad" : "iphone",
        ]
        for k in ["pc", "ps5", "xbox"] { payload["MoonCast.used.\(k)"] = d.bool(forKey: usedKey + k) ? "true" : "false" }
        var test = false
        #if DEBUG
        test = true
        #endif
        let signal: [String: Any] = [
            "appID": appId,
            "clientUser": SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined(),
            "sessionID": UUID().uuidString,
            "type": "MoonCast.dailyCheckIn",
            "isTestMode": test,
            "payload": payload,
        ]
        let url = URL(string: namespace.isEmpty || namespace.hasPrefix("$(") ? "https://nom.telemetrydeck.com/v2/"
                                                                              : "https://nom.telemetrydeck.com/v2/namespace/\(namespace)/")!
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [signal])
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                d.set(today, forKey: lastKey)
                for k in ["pc", "ps5", "xbox"] { d.removeObject(forKey: usedKey + k) }
                NSLog("MoonCast: usage check-in sent")
            } else {
                NSLog("MoonCast: usage check-in failed: \(err?.localizedDescription ?? "HTTP \(code)")")
            }
        }.resume()
    }
}
