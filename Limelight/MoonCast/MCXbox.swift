//
//  MCXbox.swift
//  MoonCast: Xbox sign-in and consoles (Xbox.kt): Microsoft's device-code sign-in, the Xbox Live tokens, the
//  console list, wake / turn off, and what a Remote Play stream needs. Tokens stay in the Keychain.
//

import Foundation
import WebKit
import UIKit

enum MCXbox {
    private static let clientId = "1f907974-e22b-4810-a9de-d9647380c97e"
    private static let scope = "xboxlive.signin openid profile offline_access"
    private static let msToken = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token"

    struct DeviceCode { let deviceCode: String; let userCode: String; let url: String; let expiresIn: Int; let interval: Int }
    struct Console: Codable, Equatable { let id: String; let name: String; let type: String; let powerState: String }
    /// The console's region server, its token, and the token for /connect.
    struct StreamAuth { let baseUri: String; let gsToken: String; let connectToken: String }

    struct HttpError: Error { let code: Int; let body: String }
    /// The Microsoft account signed in but Xbox network turned it away (no Xbox profile, a child account…).
    struct NotAllowed: LocalizedError { let errorDescription: String? }

    private static let d = UserDefaults.standard
    static var signedIn: Bool { MCKeychain.get("xbox_refresh") != nil }
    static var gamertag: String? { d.string(forKey: "xbox_gamertag") }

    static func signOut() {
        ["xbox_refresh", "xbox_access", "xbox_xbl", "xbox_web"].forEach(MCKeychain.delete)
        ["xbox_access_until", "xbox_xbl_until", "xbox_web_until", "xbox_gamertag", "xbox_consoles"].forEach { d.removeObject(forKey: $0) }
    }

    // MARK: HTTP

    private static func request(_ url: String, _ method: String, _ body: String?, _ headers: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        r.httpMethod = method
        headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        if let body = body { r.httpBody = Data(body.utf8) }
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw HttpError(code: code, body: String(decoding: data, as: UTF8.self)) }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func form(_ kv: [(String, String)]) -> String {
        kv.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.1)" }.joined(separator: "&")
    }
    private static let formHeaders = ["Content-Type": "application/x-www-form-urlencoded"]
    private static let xblHeaders = ["x-xbl-contract-version": "1", "Content-Type": "application/json", "Cache-Control": "no-cache",
                                     "Origin": "https://www.xbox.com", "Referer": "https://www.xbox.com/"]
    private static func json(_ o: Any) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self) }

    // MARK: sign-in

    /// Step 1: a code to type at microsoft.com/link.
    static func startSignIn() async throws -> DeviceCode {
        let j = try await request("https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode", "POST",
                                  form([("client_id", clientId), ("scope", scope)]), formHeaders)
        return DeviceCode(deviceCode: j["device_code"] as? String ?? "", userCode: j["user_code"] as? String ?? "",
                          url: j["verification_uri"] as? String ?? "https://www.microsoft.com/link",
                          expiresIn: j["expires_in"] as? Int ?? 900, interval: j["interval"] as? Int ?? 5)
    }

    /// Step 2: one poll. true = signed in, false = still waiting. Throws when the code expired or was declined.
    static func pollSignIn(_ dc: DeviceCode) async throws -> Bool {
        do {
            let j = try await request(msToken, "POST", form([("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                                                             ("client_id", clientId), ("device_code", dc.deviceCode)]), formHeaders)
            saveUserToken(j)
            // Xbox network must take the account (it fetches the gamertag too). An account it turns away isn't kept,
            // so signing in again can pick another one; a network hiccup keeps it.
            do { _ = try await webAuth() } catch let e as HttpError where e.code == 401 || e.code == 403 {
                let xerr = ((try? JSONSerialization.jsonObject(with: Data(e.body.utf8))) as? [String: Any])?["XErr"] as? NSNumber
                signOut()
                throw NotAllowed(errorDescription: {
                    switch xerr?.int64Value {
                    case 2148916233: return "This Microsoft account has no Xbox profile. Sign in with the account you use on your Xbox."
                    case 2148916235: return "Xbox network isn't available in this account's country."
                    case 2148916236, 2148916237: return "This account needs age verification on xbox.com first."
                    case 2148916238: return "This is a child account. An adult in its family has to add it to a family group on xbox.com first."
                    default: return "Xbox network didn't accept this account. Sign in with the account you use on your Xbox."
                    }
                }())
            } catch { }
            return true
        } catch let e as HttpError {
            let err = ((try? JSONSerialization.jsonObject(with: Data(e.body.utf8))) as? [String: Any])?["error"] as? String ?? ""
            if err == "authorization_pending" || err == "slow_down" { return false }
            throw e
        }
    }

    private static func saveUserToken(_ j: [String: Any]) {
        if let a = j["access_token"] as? String { MCKeychain.set("xbox_access", a) }
        if let r = j["refresh_token"] as? String, !r.isEmpty { MCKeychain.set("xbox_refresh", r) }
        d.set(Date().timeIntervalSince1970 + Double(j["expires_in"] as? Int ?? 3600), forKey: "xbox_access_until")
    }

    private static func fresh(_ key: String) -> String? {
        d.double(forKey: key + "_until") - Date().timeIntervalSince1970 > 60 ? MCKeychain.get(key) : nil
    }

    private static func userToken() async throws -> String {
        if let t = fresh("xbox_access") { return t }
        guard let refresh = MCKeychain.get("xbox_refresh") else { throw HttpError(code: 401, body: "Not signed in to Xbox") }
        saveUserToken(try await request(msToken, "POST", form([("client_id", clientId), ("grant_type", "refresh_token"),
                                                               ("refresh_token", refresh), ("scope", scope)]), formHeaders))
        return MCKeychain.get("xbox_access") ?? ""
    }

    /// XSTS "NotAfter" as a time.
    private static func expiry(_ j: [String: Any]) -> Double {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return (j["NotAfter"] as? String).flatMap { f.date(from: String($0.prefix(19))) }?.timeIntervalSince1970 ?? Date().timeIntervalSince1970 + 3600
    }

    private static func xblUser() async throws -> String {
        if let t = fresh("xbox_xbl") { return t }
        let j = try await request("https://user.auth.xboxlive.com/user/authenticate", "POST", json([
            "Properties": ["AuthMethod": "RPS", "RpsTicket": "d=" + (try await userToken()), "SiteName": "user.auth.xboxlive.com"],
            "RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT"]), xblHeaders)
        let t = j["Token"] as? String ?? ""
        MCKeychain.set("xbox_xbl", t); d.set(expiry(j), forKey: "xbox_xbl_until")
        return t
    }

    private static func xsts(_ relyingParty: String) async throws -> [String: Any] {
        try await request("https://xsts.auth.xboxlive.com/xsts/authorize", "POST", json([
            "Properties": ["SandboxId": "RETAIL", "UserTokens": [try await xblUser()]],
            "RelyingParty": relyingParty, "TokenType": "JWT"]), xblHeaders)
    }

    /// "XBL3.0 x=<uhs>;<token>" for the console list and commands. Remembers the gamertag.
    private static func webAuth() async throws -> String {
        if let t = fresh("xbox_web") { return t }
        let j = try await xsts("http://xboxlive.com")
        let xui = ((j["DisplayClaims"] as? [String: Any])?["xui"] as? [[String: Any]])?.first ?? [:]
        let auth = "XBL3.0 x=\(xui["uhs"] as? String ?? "");\(j["Token"] as? String ?? "")"
        MCKeychain.set("xbox_web", auth); d.set(expiry(j), forKey: "xbox_web_until")
        if let g = xui["gtg"] as? String, !g.isEmpty { d.set(g, forKey: "xbox_gamertag") }
        return auth
    }

    /// The account region's Remote Play server and token, plus the console-transfer token for /connect.
    static func streamAuth() async throws -> StreamAuth {
        let gssv = (try await xsts("http://gssv.xboxlive.com/"))["Token"] as? String ?? ""
        let j = try await request("https://xhome.gssv-play-prod.xboxlive.com/v2/login/user", "POST",
                                  json(["token": gssv, "offeringId": "xhome"]),
                                  ["Content-Type": "application/json", "Cache-Control": "no-store, must-revalidate, no-cache", "x-gssv-client": "XboxComBrowser"])
        let regions = ((j["offeringSettings"] as? [String: Any])?["regions"] as? [[String: Any]]) ?? []
        let region = regions.first { $0["isDefault"] as? Bool == true } ?? regions.first ?? [:]
        let lpt = try await request("https://login.live.com/oauth20_token.srf", "POST", form([
            ("client_id", clientId), ("scope", "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN"),
            ("grant_type", "refresh_token"), ("refresh_token", MCKeychain.get("xbox_refresh") ?? "")]), formHeaders)
        return StreamAuth(baseUri: region["baseUri"] as? String ?? "", gsToken: j["gsToken"] as? String ?? "",
                          connectToken: lpt["access_token"] as? String ?? "")
    }

    // MARK: consoles

    private static func xccsHeaders(_ contract: String) async throws -> [String: String] {
        ["Authorization": try await webAuth(), "Accept-Language": "en-US", "x-xbl-contract-version": contract,
         "x-xbl-client-name": "XboxApp", "x-xbl-client-type": "UWA", "x-xbl-client-version": "39.39.22001.0",
         "skillplatform": "RemoteManagement", "Content-Type": "application/json"]
    }

    static var consoles: [Console] {
        guard let data = d.data(forKey: "xbox_consoles") else { return [] }
        return (try? JSONDecoder().decode([Console].self, from: data)) ?? []
    }

    @discardableResult
    static func refreshConsoles() async throws -> [Console] {
        let j = try await request("https://xccs.xboxlive.com/lists/devices?queryCurrentDevice=false&includeStorageDevices=true",
                                  "GET", nil, try await xccsHeaders("2"))
        let list = ((j["result"] as? [[String: Any]]) ?? []).map {
            Console(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "Xbox",
                    type: $0["consoleType"] as? String ?? "Xbox", powerState: $0["powerState"] as? String ?? "")
        }.filter { !$0.id.isEmpty }
        d.set(try? JSONEncoder().encode(list), forKey: "xbox_consoles")
        return list
    }

    private static func command(_ consoleId: String, _ type: String, _ command: String, _ params: [[String: Any]] = []) async throws {
        _ = try await request("https://xccs.xboxlive.com/commands", "POST", json([
            "destination": "Xbox", "type": type, "command": command, "sessionId": UUID().uuidString,
            "sourceId": "com.microsoft.smartglass", "parameters": params, "linkedXboxId": consoleId]), try await xccsHeaders("4"))
    }

    /// Wake from sleep (the console needs Sleep power mode and remote features on).
    static func wake(_ consoleId: String) async throws { try await command(consoleId, "Power", "WakeUp") }
    static func turnOff(_ consoleId: String) async throws { try await command(consoleId, "Power", "TurnOff") }
    /// Types into whatever text box is open on the console.
    static func sendText(_ consoleId: String, _ text: String) async throws {
        try await command(consoleId, "Shell", "InjectString", [["replacementString": text]])
    }

    // the Xbox group in Settings
    /// 720 = "android", 1080 = "windows", 1081 = "tizen" (the device type the Xbox sets quality from); 0 = Auto
    static var resolution: Int { d.object(forKey: "xbox_resolution") as? Int ?? 0 }
    /// Mbps cap, 0 = let the Xbox decide
    static var maxMbps: Int { d.object(forKey: "xbox_bitrate") as? Int ?? 0 }
    static var swapAB: Bool { d.bool(forKey: "xbox_swap_ab") }
    static var coop: Bool { d.bool(forKey: "xbox_coop") }
    /// Settings → Xbox → Stick deadzone, 0...1 (8% by default, as on the handheld)
    static var deadzone: Float { Float(d.object(forKey: "xbox_deadzone") as? Int ?? 8) / 100 }

    /// A stick inside the deadzone reads centred; outside it the travel is rescaled so the edge still reaches full.
    static func dead(_ x: Float, _ y: Float) -> (Float, Float) {
        let dz = deadzone, mag = (x * x + y * y).squareRoot()
        guard dz > 0 else { return (x, y) }
        guard mag >= dz else { return (0, 0) }
        let k = (min(mag, 1) - dz) / (1 - dz) / mag
        return (max(-1, min(1, x * k)), max(-1, min(1, y * k)))
    }
}


/// Microsoft's device-code page (microsoft.com/link) inside MoonCast, with the code filled in. A fresh, private web
/// session every time: Safari stayed signed in to the last Microsoft account, so signing in again couldn't pick another.
final class MCXboxLinkController: UIViewController {
    var code = ""
    private let web = WKWebView(frame: .zero, configuration: {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .nonPersistent()
        return c
    }())

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Xbox sign-in"
        view.backgroundColor = .systemBackground
        web.frame = view.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(web)
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        let otc = code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? code
        if let u = URL(string: "https://www.microsoft.com/link?otc=\(otc)") { web.load(URLRequest(url: u)) }
    }

    @objc private func close() { dismiss(animated: true) }
}
