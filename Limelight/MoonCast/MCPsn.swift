//
//  MCPsn.swift
//  MoonCast: PlayStation Network sign-in (Psn.kt): Sony's sign-in page -> code -> token -> account id, which links a
//  PS5 to this iPad. The tokens stay in the Keychain. And the PS5's own status probe (Ps5Store.probe / discover).
//

import UIKit
import WebKit
import Security

enum MCPsn {
    private static let clientId = "ba495a24-818c-472b-b12d-ff231c1b5745"
    private static let clientSecret = "mvaiZkRsAsI1IBkY"
    private static let tokenUrl = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"
    static let redirect = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    private static let scope = "psn:clientapp%20referenceDataService:countryConfig.read" +
        "%20pushNotification:webSocket.desktop.connect%20sessionManager:remotePlaySession.system.update"
    private static let duidPrefix = "0000000700410080"

    static var signedIn: Bool { accountId != nil }
    static var accountId: String? { UserDefaults.standard.string(forKey: "psn_account_id") }
    static var onlineId: String? { UserDefaults.standard.string(forKey: "psn_online_id") }

    static func signOut() {
        ["psn_account_id", "psn_online_id", "psn_token_at"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        MCKeychain.delete("psn_token"); MCKeychain.delete("psn_refresh")
    }

    /// This install's client device id, stable so a refreshed token stays valid.
    private static var duid: String {
        if let d = UserDefaults.standard.string(forKey: "psn_duid") { return d }
        var b = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &b)
        let d = duidPrefix + b.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(d, forKey: "psn_duid")
        return d
    }

    static var authorizeUrl: URL {
        URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize?service_entity=urn:service-entity:psn" +
            "&response_type=code&client_id=\(clientId)&redirect_uri=\(redirect)&scope=\(scope)" +
            "&request_locale=en_US&ui=pr&service_logo=ps&layout_type=popup&smcid=remoteplay" +
            "&duid=\(duid)&prompt=always&PlatformPrivacyWs1=minimal&")!
    }

    private static var basic: String { "Basic " + Data("\(clientId):\(clientSecret)".utf8).base64EncodedString() }

    private static func form(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private static func post(_ body: String) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: tokenUrl)!)
        r.httpMethod = "POST"
        r.setValue(basic, forHTTPHeaderField: "Authorization")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(body.utf8)
        let (d, _) = try await URLSession.shared.data(for: r)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    private static func saveToken(_ j: [String: Any]) {
        if let t = j["access_token"] as? String { MCKeychain.set("psn_token", t) }
        if let r = j["refresh_token"] as? String, !r.isEmpty { MCKeychain.set("psn_refresh", r) }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "psn_token_at")
    }

    /// Code -> token -> account id (user_id as 8 little-endian bytes, base64), as chiaki wants it.
    static func finishSignIn(code: String) async throws {
        let tok = try await post("grant_type=authorization_code&code=\(form(code))&redirect_uri=\(form(redirect))")
        guard let token = tok["access_token"] as? String else { throw URLError(.userAuthenticationRequired) }
        saveToken(tok)
        var r = URLRequest(url: URL(string: tokenUrl + "/" + form(token))!)
        r.setValue(basic, forHTTPHeaderField: "Authorization")
        let (d, _) = try await URLSession.shared.data(for: r)
        let info = (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard let uidStr = info["user_id"] as? String, let uid = UInt64(uidStr) else { throw URLError(.cannotParseResponse) }
        let le = (0..<8).map { UInt8((uid >> (8 * UInt64($0))) & 0xff) }
        UserDefaults.standard.set(Data(le).base64EncodedString(), forKey: "psn_account_id")
        UserDefaults.standard.set(info["online_id"] as? String ?? "", forKey: "psn_online_id")
    }

    /// The token, renewed when it's near its ~1 h expiry (for play away from home).
    static func freshToken() async -> String? {
        guard let tok = MCKeychain.get("psn_token") else { return nil }
        let at = UserDefaults.standard.double(forKey: "psn_token_at")
        guard Date().timeIntervalSince1970 - at > 50 * 60, let refresh = MCKeychain.get("psn_refresh") else { return tok }
        if let j = try? await post("grant_type=refresh_token&refresh_token=\(form(refresh))&scope=\(scope)&redirect_uri=\(form(redirect))") {
            saveToken(j)
        }
        return MCKeychain.get("psn_token") ?? tok
    }
}

/// The few secrets MoonCast keeps (PSN tokens), in the Keychain.
enum MCKeychain {
    private static func q(_ k: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "me.mooncast.ios", kSecAttrAccount as String: k]
    }
    static func set(_ k: String, _ v: String) {
        SecItemDelete(q(k) as CFDictionary)
        var a = q(k)
        a[kSecValueData as String] = Data(v.utf8)
        a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(a as CFDictionary, nil)
    }
    static func get(_ k: String) -> String? {
        var a = q(k)
        a[kSecReturnData as String] = true
        a[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(a as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ k: String) { SecItemDelete(q(k) as CFDictionary) }
}

/// Sony's sign-in page; finishes on the Remote Play redirect with ?code=.
final class MCPsnSignInController: UIViewController, WKNavigationDelegate {
    var done: (Bool) -> Void = { _ in }
    private let web = WKWebView(frame: .zero, configuration: {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .nonPersistent()   // a fresh sign-in every time, nothing kept in the web view
        return c
    }())
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "PlayStation Network"
        view.backgroundColor = .systemBackground
        web.navigationDelegate = self
        web.frame = view.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(web)
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        web.load(URLRequest(url: MCPsn.authorizeUrl))
    }

    @objc private func cancel() { finish(false) }

    private func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        dismiss(animated: true) { self.done(ok) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, url.absoluteString.hasPrefix(MCPsn.redirect) else { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value ?? ""
        if code.isEmpty { finish(false); return }
        Task { @MainActor in
            do { try await MCPsn.finishSignIn(code: code); finish(true) } catch { finish(false) }
        }
    }
}

/// The PS5's own answer to Remote Play's SRCH probe: on, rest mode, and the game it's running.
enum MCPs5Probe {
    enum Power { case on, rest, notFound }
    struct Status { var power: Power; var runningApp: String?; var name: String? }
    struct Found { let host: String; let name: String; let on: Bool }

    private static let srch = Array("SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n".utf8)

    private static func parse(_ data: [UInt8]) -> (Bool, String?, String?) {
        let s = String(decoding: data, as: UTF8.self)
        let lines = s.split(whereSeparator: \.isNewline).map(String.init)
        func field(_ k: String) -> String? { lines.first { $0.hasPrefix(k + ":") }.map { String($0.dropFirst(k.count + 1)).trimmingCharacters(in: .whitespaces) } }
        return ((lines.first ?? "").contains(" 200"), field("running-app-name"), field("host-name"))
    }

    /// One console, by address. Blocking, under a second and a half.
    static func probe(_ host: String) -> Status {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return Status(power: .notFound) }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 700_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(9302).bigEndian
        guard inet_pton(AF_INET, host, &a.sin_addr) == 1 else { return Status(power: .notFound) }
        var buf = [UInt8](repeating: 0, count: 2048)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, srch, srch.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 {
                let (on, app, name) = parse(Array(buf[0..<n]))
                return Status(power: on ? .on : .rest, runningApp: app, name: name)
            }
        }
        return Status(power: .notFound)
    }

    /// Every PlayStation on this network. iPadOS needs a special entitlement to broadcast, so this asks each address
    /// of the iPad's own /24 in turn (about 2 s).
    static func discover() -> [Found] {
        guard let (base, me) = localSubnet() else { return [] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out: [String: Found] = [:]
        for round in 0..<2 {
            for i in 1...254 where base | UInt32(i) != me {
                var a = sockaddr_in()
                a.sin_family = sa_family_t(AF_INET)
                a.sin_port = in_port_t(9302).bigEndian
                a.sin_addr.s_addr = (base | UInt32(i)).bigEndian
                _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, srch, srch.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            }
            let end = Date().addingTimeInterval(round == 0 ? 1.2 : 0.8)
            var buf = [UInt8](repeating: 0, count: 2048)
            while Date() < end {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) } }
                guard n > 0 else { continue }
                var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
                let host = String(cString: ip)
                let (on, _, name) = parse(Array(buf[0..<n]))
                out[host] = Found(host: host, name: name ?? "PS5", on: on)
            }
        }
        return out.values.sorted { $0.host < $1.host }
    }

    /// The Wi-Fi interface's /24 network and own address (host byte order).
    private static func localSubnet() -> (UInt32, UInt32)? {
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0 else { return nil }
        defer { freeifaddrs(ifs) }
        var p = ifs
        while let i = p {
            let name = String(cString: i.pointee.ifa_name)
            if let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), name.hasPrefix("en") {
                let addr = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                return (addr & 0xFFFF_FF00, addr)
            }
            p = i.pointee.ifa_next
        }
        return nil
    }
}
