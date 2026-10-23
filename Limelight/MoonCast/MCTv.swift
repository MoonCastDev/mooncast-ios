//
//  MCTv.swift
//  MoonCast: Play on a MoonCast TV, from the iPad (TvFinder, TvSender, PadServer on the handheld). The iPad finds
//  MoonCast TVs on the Wi-Fi (GET :8099/mc-native), sends a game (POST /play) and serves its controller to the TV
//  over a small WebSocket (ws://<ipad>:8099/pad?k=<padKey>) and, for a PS5, UDP to the TV's :8100.
//  The iPad is always the sender: it never receives games.
//

import Foundation
import Network
import UIKit
import CryptoKit

/// A MoonCast TV this iPad has seen.
struct MCTvBox: Codable, Equatable {
    var id: String
    var ip: String
    var name: String
    var pc: String
    var xbox: Bool
    var version: Int
    var seen: Double
    var paired: Bool
    var canXbox: Bool { version >= 2 }
}

enum MCTvFinder {
    static let port = 8099
    private static let d = UserDefaults.standard
    private static var here: [String: Date] = [:]
    private static let hereFor: TimeInterval = 150

    static var known: [MCTvBox] {
        guard let data = d.data(forKey: "mc_tvs"), let l = try? JSONDecoder().decode([MCTvBox].self, from: data) else { return [] }
        return l.sorted { (isHere($0) ? 1 : 0, $0.seen) > (isHere($1) ? 1 : 0, $1.seen) }
    }

    static func isHere(_ tv: MCTvBox) -> Bool { here[tv.id].map { -$0.timeIntervalSinceNow < hereFor } ?? false }

    /// Where games go when you press A: a TV, or nil for this iPad.
    static var target: MCTvBox? {
        get { known.first { $0.id == d.string(forKey: "mc_tv_target") } }
        set { d.set(newValue?.id ?? "", forKey: "mc_tv_target") }
    }

    private static func save(_ l: [MCTvBox]) { d.set(try? JSONEncoder().encode(Array(l.prefix(12))), forKey: "mc_tvs") }

    static func forget(_ id: String) {
        save(known.filter { $0.id != id })
        here[id] = nil
        if d.string(forKey: "mc_tv_target") == id { d.set("", forKey: "mc_tv_target") }
    }

    /// This iPad's address on the Wi-Fi.
    static var myIp: String? {
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0 else { return nil }
        defer { freeifaddrs(ifs) }
        var p = ifs
        while let i = p {
            if let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), String(cString: i.pointee.ifa_name).hasPrefix("en") {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { var s = $0.pointee.sin_addr; inet_ntop(AF_INET, &s, &buf, socklen_t(INET_ADDRSTRLEN)) }
                return String(cString: buf)
            }
            p = i.pointee.ifa_next
        }
        return nil
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.2
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c)
    }()

    /// One address: a MoonCast TV, or nil.
    static func ask(_ ip: String) async -> MCTvBox? {
        guard !ip.isEmpty, let url = URL(string: "http://\(ip):\(port)/mc-native") else { return nil }
        guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (j["mooncast_native"] as? Int) == 1 else { return nil }
        let id = (j["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "ip:\(ip)"
        let name = (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "MoonCast TV"
        return MCTvBox(id: id, ip: ip, name: name, pc: j["pc"] as? String ?? "", xbox: j["xbox"] as? Bool ?? false,
                       version: j["version"] as? Int ?? 1, seen: Date().timeIntervalSince1970, paired: j["paired"] as? Bool ?? true)
    }

    /// Asks every address of this /24 (about two seconds), the known TVs first.
    static func sweep() async -> [MCTvBox] {
        guard let me = myIp, let dot = me.lastIndex(of: ".") else { return known.filter(isHere) }
        let net = String(me[...dot])
        let order = Array(NSOrderedSet(array: known.map(\.ip).filter { $0.hasPrefix(net) } + (1...254).map { net + "\($0)" })) as? [String] ?? []
        let found = await withTaskGroup(of: MCTvBox?.self) { g -> [MCTvBox] in
            for ip in order where ip != me { g.addTask { await ask(ip) } }
            var out: [MCTvBox] = []
            for await t in g { if let t = t { out.append(t) } }
            return out
        }
        merge(found, wholeNetwork: true)
        return known
    }

    /// Test runs only: MC_TV=<address> makes that MoonCast TV the target before anything plays.
    static func testTarget() async {
        #if DEBUG
        guard let ip = ProcessInfo.processInfo.environment["MC_TV"], let tv = await ask(ip) else { return }
        merge([tv], wholeNetwork: false)
        target = tv
        #endif
    }

    private static func merge(_ found: [MCTvBox], wholeNetwork: Bool) {
        var byId: [String: MCTvBox] = [:]
        known.forEach { byId[$0.id] = $0 }
        for f in found {
            // a TV whose address now belongs to another TV moved: drop the stale address
            for (k, v) in byId where v.ip == f.ip && v.id != f.id { byId[k]?.ip = "" }
            byId[f.id] = f
            here[f.id] = Date()
        }
        if wholeNetwork { for (k, _) in byId where !found.contains(where: { $0.id == k }) { here[k] = nil } }
        save(Array(byId.values))
    }
}

/// What to send: a PC game, a PS5 or an Xbox.
enum MCTvSender {
    static func newPadKey() -> String {
        var b = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    private static func post(_ tv: MCTvBox, _ path: String, _ body: [String: Any], timeout: Double) async -> (Int, [String: Any])? {
        guard let url = URL(string: "http://\(tv.ip):\(MCTvFinder.port)\(path)") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: r) else { return nil }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    /// Nil when the TV took the game, else what went wrong (the TV's own words when it said).
    static func send(_ tv: MCTvBox, _ g: MCGame, padKey: String) async -> String? {
        if tv.ip.isEmpty { return "\(tv.name) isn't on this network. Open MoonCast on it, on the same Wi-Fi as this iPad." }
        if g.xb != nil && !tv.canXbox { return "Update MoonCast on \(tv.name) to send it an Xbox game." }
        var j: [String: Any] = ["deviceName": UIDevice.current.name, "padKey": padKey]
        if let ip = MCTvFinder.myIp { j["phoneIp"] = ip }
        if let a = g.app {
            j["appId"] = a.id ?? ""
            j["appName"] = a.name ?? g.title
            if !tv.paired { return "\(tv.name) isn't paired with your PC yet. Pair it with the PC on the TV first." }
        } else if let c = g.ps {
            j["ps5host"] = c.host; j["registKey"] = c.registKey; j["morning"] = c.morning; j["ps5"] = "true"
            // signed in to PSN: let the TV reach the console over the internet too (it still tries the LAN first)
            if let (tok, duid, acc) = await MCPsn.remoteFor(c.name) {
                j["psnToken"] = tok; j["duid"] = duid; j["accountId"] = acc.base64EncodedString()
            }
        } else if let x = g.xb {
            j["xboxId"] = x.id; j["xboxName"] = x.name
        }
        guard let (code, body) = await post(tv, "/play", j, timeout: 20) else {
            return "\(tv.name) didn't answer. Check MoonCast is open on it and it's on the same Wi-Fi as this iPad."
        }
        if code == 200 { return nil }
        let err = body["error"] as? String ?? ""
        if err.isEmpty { return "\(tv.name) didn't take the game (error \(code))." }
        if err.hasPrefix("no app id") { return "\(tv.name) has no paired PC. Pair it with your PC on the TV first." }
        if err == "ps5 launch failed" { return "\(tv.name) couldn't start the PlayStation." }
        return err.prefix(1).uppercased() + err.dropFirst() + (err.hasSuffix(".") ? "" : ".")
    }

    /// Ends the TV's stream (quit = also quit the game on the PC). False when the TV can't (older MoonCast).
    @discardableResult
    static func stop(_ tv: MCTvBox, padKey: String, quit: Bool) async -> Bool {
        guard !tv.ip.isEmpty, tv.version >= 3 else { return false }
        return await post(tv, "/stop", ["padKey": padKey, "quit": quit], timeout: 3)?.0 == 200
    }

    /// How the TV's stream is going: (state, error), or nil (older TV, no answer).
    static func status(_ tv: MCTvBox) async -> (String, String)? {
        guard !tv.ip.isEmpty, tv.version >= 6, let url = URL(string: "http://\(tv.ip):\(MCTvFinder.port)/status"),
              let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 2)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (j["state"] as? String ?? "", j["error"] as? String ?? "")
    }
}

/// The iPad's controller, served to the TV (PadServer.kt): ws://<ipad>:8099/pad?k=<padKey> sends
/// {"pads":[{"b":[17 buttons],"a":[4 axes]}]} in W3C order (b: A B X Y LB RB LT RT Select Start L3 R3 Up Down Left
/// Right Guide; a: LX LY RX RY, Y down-positive) at most 60 times a second when something changed, and every 500 ms
/// anyway. A PS5 relay ("mctv-ps5") also gets it over UDP to the TV's :8100 every 50 ms.
final class MCPadServer {
    static let shared = MCPadServer()
    private var listener: NWListener?
    private let q = DispatchQueue(label: "MCPadServer")
    private var keys = Set<String>()
    private final class Client { let c: NWConnection; let ip: String; let key: String; var kind: String?; init(_ c: NWConnection, _ ip: String, _ key: String) { self.c = c; self.ip = ip; self.key = key } }
    private var clients: [Client] = []
    private var b = [Float](repeating: 0, count: 17)
    private var a = [Float](repeating: 0, count: 4)
    private var dirty = true
    private var lastWs = Date.distantPast, lastUdp = Date.distantPast
    private var seq = 0
    private var timer: DispatchSourceTimer?
    private var udp: NWConnection?
    var onClients: ((Int) -> Void)?
    var running: Bool { listener != nil }
    var clientCount: Int { q.sync { clients.count } }

    func key(forTv id: String) -> String {
        let k = UserDefaults.standard.string(forKey: "mc_padkey_\(id)") ?? MCTvSender.newPadKey()
        UserDefaults.standard.set(k, forKey: "mc_padkey_\(id)")
        q.async { self.keys.insert(k) }
        start()
        return k
    }

    func start() {
        q.async { [self] in
            guard listener == nil, let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(MCTvFinder.port))!) else { return }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: q)
            listener = l
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 0.016, repeating: 0.016)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        q.async { [self] in
            b = .init(repeating: 0, count: 17); a = .init(repeating: 0, count: 4)
            let f = frame(stateJson())
            for c in clients {
                c.c.send(content: f + Data([0x88, 0]), completion: .contentProcessed { _ in c.c.cancel() })
            }
            clients.removeAll()
            listener?.cancel(); listener = nil
            timer?.cancel(); timer = nil
            udp?.cancel(); udp = nil
            keys.removeAll()
            onClients?(0)
        }
    }

    func update(_ buttons: [Float], _ axes: [Float]) {
        q.async { [self] in
            if buttons != b || axes != a { b = buttons; a = axes; dirty = true }
        }
    }

    private func num(_ v: Float) -> String { v == 0 ? "0" : v == 1 ? "1" : String(format: "%.3f", v) }
    private func stateJson() -> String { "{\"pads\":[{\"b\":[" + b.map(num).joined(separator: ",") + "],\"a\":[" + a.map(num).joined(separator: ",") + "]}]}" }

    private func frame(_ text: String) -> Data {
        let d = Data(text.utf8)
        var f = Data([0x81])
        if d.count < 126 { f.append(UInt8(d.count)) } else { f.append(126); f.append(UInt8(d.count >> 8)); f.append(UInt8(d.count & 0xff)) }
        return f + d
    }

    private func tick() {
        guard !clients.isEmpty else { return }
        let now = Date()
        let changed = dirty
        guard changed || now.timeIntervalSince(lastWs) >= 0.5 || now.timeIntervalSince(lastUdp) >= 0.05 else { return }
        dirty = false
        let json = stateJson()
        if changed || now.timeIntervalSince(lastWs) >= 0.5 {
            lastWs = now
            let f = frame(json)
            for c in clients { c.c.send(content: f, completion: .contentProcessed { [weak self] e in if e != nil { self?.drop(c) } }) }
        }
        if changed || now.timeIntervalSince(lastUdp) >= 0.05 {
            lastUdp = now
            seq += 1
            for c in clients where c.kind == "mctv-ps5" {
                let body = "{\"seq\":\(seq),\"k\":\"\(c.key)\"," + json.dropFirst()
                let u = NWConnection(host: NWEndpoint.Host(c.ip), port: 8100, using: .udp)
                u.start(queue: q)
                u.send(content: Data(body.utf8), completion: .contentProcessed { _ in u.cancel() })
            }
        }
    }

    private func drop(_ c: Client) {
        q.async { [self] in
            if let i = clients.firstIndex(where: { $0 === c }) { clients.remove(at: i); onClients?(clients.count) }
            c.c.cancel()
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: q)
        readHeader(c, Data())
    }

    private func readHeader(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, err in
            guard let self = self else { return }
            var buf = got
            if let data = data { buf.append(data) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.upgrade(c, String(decoding: buf[..<r.lowerBound], as: UTF8.self))
            } else if done || err != nil || buf.count > 8192 {
                c.cancel()
            } else {
                self.readHeader(c, buf)
            }
        }
    }

    private func upgrade(_ c: NWConnection, _ head: String) {
        let first = head.components(separatedBy: "\r\n").first ?? ""
        let path = first.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let given = URLComponents(string: "http://x" + path)?.queryItems?.first { $0.name == "k" }?.value ?? ""
        let wsKey = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }
            .map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) }
        guard path.hasPrefix("/pad"), let wk = wsKey, keys.contains(given) else {
            c.send(content: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
            return
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((wk + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        var ip = ""
        if case let .hostPort(host, _) = c.endpoint { ip = "\(host)".components(separatedBy: "%").first ?? "" }
        let client = Client(c, ip, given)
        clients.append(client)
        onClients?(clients.count)
        c.send(content: Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8) + frame(stateJson()),
               completion: .contentProcessed { _ in })
        readFrames(client, Data())
    }

    /// What the TV sends: its hello ({"hello":{"kind":...}}), pings, the close.
    private func readFrames(_ cl: Client, _ got: Data) {
        cl.c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else { return }
            var buf = got
            if let data = data { buf.append(data) }
            while buf.count >= 2 {
                let b0 = buf[buf.startIndex], b1 = buf[buf.startIndex + 1]
                var len = Int(b1 & 0x7f), off = 2
                if len == 126 { guard buf.count >= 4 else { break }; len = Int(buf[buf.startIndex + 2]) << 8 | Int(buf[buf.startIndex + 3]); off = 4 }
                else if len == 127 { self.drop(cl); return }
                let masked = b1 & 0x80 != 0
                guard buf.count >= off + (masked ? 4 : 0) + len else { break }
                let mask = masked ? Array(buf[(buf.startIndex + off)..<(buf.startIndex + off + 4)]) : [0, 0, 0, 0]
                let start = buf.startIndex + off + (masked ? 4 : 0)
                var payload = Array(buf[start..<(start + len)])
                for i in payload.indices { payload[i] ^= mask[i & 3] }
                buf = Data(buf[(start + len)...])
                switch b0 & 0x0f {
                case 0x8: self.drop(cl); return
                case 0x9: cl.c.send(content: Data([0x8A, UInt8(payload.count)]) + Data(payload), completion: .contentProcessed { _ in })
                case 0x1:
                    let t = String(decoding: payload, as: UTF8.self)
                    if let r = t.range(of: "\"kind\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
                        cl.kind = String(t[r]).components(separatedBy: "\"").dropLast().last
                        self.dirty = true
                    }
                default: break
                }
            }
            if done || err != nil { self.drop(cl) } else { self.readFrames(cl, buf) }
        }
    }
}
