//
//  MCXboxRtc.swift
//  MoonCast: Xbox Remote Play over Google's WebRTC (XboxRtc.kt): the xHome session signalling, the input / chat /
//  control / message channels and the input packet format follow XStreaming (github.com/Geocld/XStreaming,
//  AGPL-3.0), as on Android. Video goes to an RTCVideoRenderer (Metal view), audio straight to the speaker.
//

import Foundation
import WebRTC

final class MCXboxRtc: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    protocol Listener: AnyObject {
        func xboxStatus(_ text: String)
        func xboxConnected()
        func xboxFailed(_ reason: String)
    }

    /// One controller's state: axes -1...1 (Y up positive, as GameController reports it), triggers 0...1.
    struct PadFrame {
        var index = 0
        var nexus = false, menu = false, view = false
        var a = false, b = false, x = false, y = false
        var up = false, down = false, left = false, right = false
        var lb = false, rb = false, ls = false, rs = false
        var lx: Float = 0, ly: Float = 0, rx: Float = 0, ry: Float = 0, lt: Float = 0, rt: Float = 0
    }

    private static let accessKey = "4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E"
    private static let nanoVersion = "V3;WebrtcTransport.dll"
    private static let iceServers = ["stun:worldaz.relay.teams.microsoft.com:3478", "stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]
    private static var sslReady = false

    private let consoleId: String
    private let auth: MCXbox.StreamAuth
    private let resolution: Int
    private let coop: Bool
    private let maxMbps: Int
    private weak var renderer: RTCVideoRenderer?
    weak var listener: Listener?

    private let work = DispatchQueue(label: "MCXboxRtc")
    private var factory: RTCPeerConnectionFactory?
    private var pc: RTCPeerConnection?
    private var channels: [String: RTCDataChannel] = [:]
    private var sessionPath: String?
    private var localCandidates: [RTCIceCandidate] = []
    private var gatheringDone = false
    private var closed = false
    private var inputStarted = false
    private var inputSequence: UInt32 = 0
    private var messageCv = 0
    private var videoTrackSeen = false, audioTrackSeen = false, keyframeAsked = false
    private var videoFlowing = false
    private var keyframeTries = 0
    private var pendingFeedback = false
    private var timers: [DispatchSourceTimer] = []
    private(set) var connected = false
    private let start0 = CACurrentMediaTime()

    /// Latest state of each pad, sent 62.5 times a second once the input channel is ready.
    var pads: [PadFrame] = []

    init(consoleId: String, auth: MCXbox.StreamAuth, resolution: Int, coop: Bool, maxMbps: Int, renderer: RTCVideoRenderer) {
        self.consoleId = consoleId
        self.auth = auth
        self.resolution = resolution
        self.coop = coop
        self.maxMbps = maxMbps
        self.renderer = renderer
    }

    // MARK: lifecycle

    func start() {
        Task {
            do { try await run() } catch {
                if !closed { listener?.xboxFailed((error as? MCXbox.HttpError).map { "HTTP \($0.code): \($0.body.prefix(160))" } ?? error.localizedDescription) }
            }
        }
    }

    func stop() {
        work.async { [self] in
            guard !closed else { return }
            closed = true
            timers.forEach { $0.cancel() }
            timers.removeAll()
            if let p = sessionPath { Task { _ = try? await http("DELETE", p, nil) } }
            channels.values.forEach { $0.delegate = nil; $0.close() }
            pc?.close()
            pc = nil
            factory = nil
        }
    }

    // MARK: signalling (xHome: /v5/sessions/home/...)

    private var osName: String { resolution == 1080 ? "windows" : (resolution == 1081 || resolution == 1440) ? "tizen" : "android" }

    @discardableResult
    private func http(_ method: String, _ url: String, _ body: String?, deviceInfo: String? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        r.httpMethod = method
        r.setValue("Bearer \(auth.gsToken)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method == "POST" { r.setValue("application/json", forHTTPHeaderField: "Accept") }
        if let di = deviceInfo { r.setValue(di, forHTTPHeaderField: "X-MS-Device-Info") }
        if let body = body { r.httpBody = Data(body.utf8) }
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw MCXbox.HttpError(code: code, body: String(decoding: data, as: UTF8.self)) }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? ["_raw": String(decoding: data, as: UTF8.self)]
    }

    private func json(_ o: Any) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self) }

    private var deviceInfo: String {
        json(["appInfo": ["env": ["clientAppId": "www.xbox.com", "clientAppType": "browser", "clientAppVersion": "29.9.35",
                                  "clientSdkVersion": "10.6.8", "httpEnvironment": "prod", "sdkInstallId": ""]],
              "dev": ["hw": ["make": "Microsoft", "model": "unknown", "platformType": "desktop", "sdktype": "web"],
                      "os": ["name": osName, "ver": "22631.2715", "platform": "desktop"],
                      "displayInfo": ["dimensions": ["widthInPixels": 4096, "heightInPixels": 2160], "pixelDensity": ["dpiX": 1, "dpiY": 1]],
                      "browser": ["browserName": "edge", "browserVersion": "140.0.3485.66"]]])
    }

    private func range(_ a: Int, _ b: Int) -> [String: Int] { ["minVersion": a, "maxVersion": b] }

    private func run() async throws {
        let base = auth.baseUri.hasSuffix("/") ? String(auth.baseUri.dropLast()) : auth.baseUri
        listener?.xboxStatus("Starting a session on your Xbox…")
        let play = try await http("POST", "\(base)/v5/sessions/home/play", json([
            "clientSessionId": "", "titleId": "", "systemUpdateGroup": "",
            "settings": ["nanoVersion": Self.nanoVersion, "enableTextToSpeech": false, "highContrast": 0,
                         "locale": Locale.preferredLanguages.first ?? "en-US", "useIceConnection": false,
                         "timezoneOffsetMinutes": TimeZone.current.secondsFromGMT() / 60, "sdkType": "web", "osName": osName],
            "serverId": consoleId, "fallbackRegionNames": [String]()]), deviceInfo: deviceInfo)
        let parts = (play["sessionPath"] as? String ?? "").split(separator: "/")
        guard parts.count >= 4 else { throw MCXbox.HttpError(code: 0, body: "No session id") }
        let path = "\(base)/v5/sessions/home/\(parts[3])"
        sessionPath = path

        // wait until the console has the session ready ("ReadyToConnect" wants the user token first)
        var connectSent = false
        while !closed {
            let st = try await http("GET", "\(path)/state", nil)
            let s = st["state"] as? String ?? ""
            if s == "Provisioned" { break }
            if s == "ReadyToConnect" && !connectSent {
                try await http("POST", "\(path)/connect", json(["userToken": auth.connectToken])); connectSent = true
            }
            if s == "Failed" {
                throw MCXbox.HttpError(code: 0, body: ((st["errorDetails"] as? [String: Any])?["message"] as? String) ?? "The Xbox couldn't start the session")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if closed { return }
        let pulse = ((try? await http("GET", "\(path)/configuration", nil))?["keepAlivePulseInSeconds"] as? Int) ?? 20

        listener?.xboxStatus("Connecting…")
        try createPeer()
        let offer = try await createOffer()
        try await http("POST", "\(path)/sdp", json([
            "messageType": "offer", "sdp": offer,
            "configuration": ["chatConfiguration": ["bytesPerSample": 2, "expectedClipDurationMs": 20,
                                                    "format": ["codec": "opus", "container": "webm"], "numChannels": 1, "sampleFrequencyHz": 24000],
                              "chat": range(1, 1), "control": range(1, 3), "input": range(1, 8), "message": range(1, 1)]]))

        var answer: String?
        while !closed && answer == nil {
            answer = sdpFrom(try await http("GET", "\(path)/sdp", nil))
            if answer == nil { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        guard !closed, let ans = answer else { return }
        try await setRemote(ans)

        // local candidates (gathering is quick on a LAN; don't wait forever)
        for _ in 0..<50 where !gatheringDone { try await Task.sleep(nanoseconds: 100_000_000) }
        let cands: [[String: String]] = work.sync { localCandidates }.filter { !($0.sdp.contains("UDP") && $0.sdp.contains("tcptype")) }.map {
            ["candidate": $0.sdp.hasPrefix("a=") ? String($0.sdp.dropFirst(2)) : $0.sdp, "messageType": "iceCandidate",
             "sdpMLineIndex": "\($0.sdpMLineIndex)", "sdpMid": $0.sdpMid ?? "0"]
        }
        try await http("POST", "\(path)/ice", json(["messageType": "iceCandidate", "candidate": cands]))

        var remote: [[String: Any]] = []
        while !closed && remote.isEmpty {
            remote = iceFrom(try await http("GET", "\(path)/ice", nil))
            if remote.isEmpty { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        if closed { return }
        for o in expandTeredo(remote) {
            let c = (o["candidate"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if c.isEmpty || c == "a=end-of-candidates" || (c.contains("UDP") && c.contains("tcptype")) { continue }
            let mid = o["sdpMid"] as? String ?? "0"
            let idx = Int32((o["sdpMLineIndex"] as? String) ?? "0") ?? (o["sdpMLineIndex"] as? Int32 ?? 0)
            pc?.add(RTCIceCandidate(sdp: c.hasPrefix("a=") ? String(c.dropFirst(2)) : c, sdpMLineIndex: idx, sdpMid: mid)) { _ in }
        }
        if !connectSent { try await http("POST", "\(path)/connect", json(["userToken": auth.connectToken])) }

        // keep the session alive while we play
        repeating(every: Double(max(5, pulse))) { [weak self] in
            guard let self = self, !self.closed else { return }
            Task { _ = try? await self.http("POST", "\(path)/keepalive", "{}") }
        }
    }

    /// The Xbox often offers a Teredo IPv6 address (2001:0::/32): add the IPv4 host candidates hidden inside it, as
    /// XStreaming does, so an IPv4-only network can still reach the console.
    private func expandTeredo(_ list: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for (i, o) in list.enumerated() {
            out.append(o)
            let tok = (o["candidate"] as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            guard let ipIdx = tok.firstIndex(where: { $0.hasPrefix("2001:0:") || $0.hasPrefix("2001:0000:") }) else { continue }
            var a6 = in6_addr()
            guard inet_pton(AF_INET6, tok[ipIdx], &a6) == 1 else { continue }
            let b = withUnsafeBytes(of: a6) { Array($0) }
            let server4 = (4...7).map { "\(b[$0])" }.joined(separator: ".")
            let client4 = (12...15).map { "\(b[$0] ^ 0xff)" }.joined(separator: ".")
            let udp = ((Int(b[10]) << 8) | Int(b[11])) ^ 0xffff
            let port = ipIdx + 1 < tok.count ? Int(tok[ipIdx + 1]) ?? 9002 : 9002
            var adds = [(client4, udp), (server4, port), (client4, port)]
            if port != 3074 { adds += [(server4, 3074), (client4, 3074)] }
            for (k, (ip, pt)) in adds.enumerated() {
                out.append(["candidate": "a=candidate:\(i + 2 + k) 1 UDP 100 \(ip) \(pt) typ host ",
                            "sdpMid": o["sdpMid"] as? String ?? "0", "sdpMLineIndex": o["sdpMLineIndex"] as? String ?? "0"])
            }
        }
        return out
    }

    private func sdpFrom(_ j: [String: Any]) -> String? {
        if let ex = j["exchangeResponse"] as? String {
            if let d = ex.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = o["sdp"] as? String, !s.isEmpty { return s }
            return ex.isEmpty ? nil : ex
        }
        if let ex = j["exchangeResponse"] as? [String: Any] { return (ex["sdp"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return (j["sdp"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func iceFrom(_ j: [String: Any]) -> [[String: Any]] {
        let ex = j["exchangeResponse"] ?? j["candidate"]
        if let s = ex as? String, let d = s.data(using: .utf8) { return (try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? [] }
        return ex as? [[String: Any]] ?? []
    }

    // MARK: peer connection

    private func createPeer() throws {
        if !Self.sslReady { RTCInitializeSSL(); Self.sslReady = true }
        let f = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        factory = f
        let cfg = RTCConfiguration()
        cfg.iceServers = [RTCIceServer(urlStrings: Self.iceServers)]
        cfg.sdpSemantics = .unifiedPlan
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
        guard let p = f.peerConnection(with: cfg, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw MCXbox.HttpError(code: 0, body: "Couldn't create the connection")
        }
        pc = p
        let vi = RTCRtpTransceiverInit(); vi.direction = .recvOnly
        p.addTransceiver(of: .video, init: vi)
        let ai = RTCRtpTransceiverInit(); ai.direction = .sendRecv
        p.addTransceiver(of: .audio, init: ai)
        // the same channels and protocols as XStreaming's player
        for (name, proto) in [("input", "1.0"), ("chat", "chatV1"), ("control", "controlV1"), ("message", "messageV1")] {
            let c = RTCDataChannelConfiguration()
            c.isOrdered = true
            c.protocol = proto
            if let ch = p.dataChannel(forLabel: name, configuration: c) {
                ch.delegate = self
                channels[name] = ch
            }
        }
    }

    private func createOffer() async throws -> String {
        guard let p = pc else { throw MCXbox.HttpError(code: 0, body: "No connection") }
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            p.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, err in
                if let sdp = sdp { c.resume(returning: sdp) } else { c.resume(throwing: err ?? MCXbox.HttpError(code: 0, body: "Offer failed")) }
            }
        }
        // the Xbox answers H.264 at profile-level-id 42e02a: offer that level (libwebrtc treats 42e01f and 42e02a as one)
        let level = offer.sdp.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "profile-level-id=42e01f", with: "profile-level-id=42e02a")
        let munged = capBitrate(stereo(level))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.setLocalDescription(RTCSessionDescription(type: .offer, sdp: munged)) { err in
                if let err = err { c.resume(throwing: err) } else { c.resume() }
            }
        }
        return munged
    }

    private func setRemote(_ sdp: String) async throws {
        guard let p = pc else { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { err in
                if let err = err { c.resume(throwing: err) } else { c.resume() }
            }
        }
    }

    /// XStreaming's _setBitrate: b=AS (kbps, Mbps x 1024) in the video section after its i= / c= lines.
    private func capBitrate(_ sdp: String) -> String {
        guard maxMbps > 0 else { return sdp }
        var lines = sdp.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        guard let m = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else { return sdp }
        var i = m + 1
        while i < lines.count && (lines[i].hasPrefix("i=") || lines[i].hasPrefix("c=")) { i += 1 }
        let line = "b=AS:\(maxMbps * 1024)"
        if i < lines.count && lines[i].hasPrefix("b=AS:") { lines[i] = line } else { lines.insert(line, at: i) }
        return lines.joined(separator: "\r\n")
    }

    /// Opus in stereo with in-band FEC (XStreaming's forceStereoAudio).
    private func stereo(_ sdp: String) -> String {
        var lines = sdp.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        guard let opusLine = lines.first(where: { $0.hasPrefix("a=rtpmap:") && $0.lowercased().contains(" opus/") }),
              let pt = opusLine.dropFirst("a=rtpmap:".count).split(separator: " ").first,
              let i = lines.firstIndex(where: { $0.hasPrefix("a=fmtp:\(pt) ") }) else { return sdp }
        let keep = lines[i].dropFirst("a=fmtp:\(pt) ".count).split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("stereo=") && !$0.hasPrefix("minptime=") && !$0.hasPrefix("useinbandfec=") }
        lines[i] = "a=fmtp:\(pt) " + (keep + ["stereo=1", "minptime=10", "useinbandfec=1"]).joined(separator: ";")
        return lines.joined(separator: "\r\n")
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ p: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ p: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ p: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ p: RTCPeerConnection) {}
    func peerConnection(_ p: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ p: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { work.async { self.gatheringDone = true } }
    }
    func peerConnection(_ p: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { work.async { self.localCandidates.append(candidate) } }
    func peerConnection(_ p: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ p: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ p: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        work.async { [self] in
            if let v = rtpReceiver.track as? RTCVideoTrack {
                if let r = renderer { DispatchQueue.main.async { v.add(r) } }
                videoTrackSeen = true
            } else { audioTrackSeen = true }
            if videoTrackSeen && audioTrackSeen && !keyframeAsked { keyframeAsked = true; askKeyframe() }
        }
    }

    func peerConnection(_ p: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .connected:
            connected = true
            DispatchQueue.main.async { self.listener?.xboxConnected() }
        case .failed:
            if !closed { DispatchQueue.main.async { self.listener?.xboxFailed("The connection to the Xbox dropped") } }
        default: break
        }
    }

    // MARK: channels

    private func sendText(_ name: String, _ text: String) {
        channels[name]?.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    func dataChannelDidChangeState(_ ch: RTCDataChannel) {
        guard ch.readyState == .open else { return }
        work.async { [self] in
            if ch.label == "message" {
                sendText("message", json(["type": "Handshake", "version": "messageV1", "id": UUID().uuidString, "cv": "\(messageCv)"]))
                messageCv += 1
            }
        }
    }

    func dataChannel(_ ch: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        work.async { [self] in
            if ch.label == "message",
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["type"] as? String == "HandshakeAck", !inputStarted {
                onHandshake()
            }
        }
    }

    /// The Xbox accepted us: authorise, announce the pads, start input, describe this client.
    private func onHandshake() {
        sendText("control", json(["message": "authorizationRequest", "accessKey": Self.accessKey]))
        let slots = coop ? [0, 1] : [0]
        slots.forEach { sendText("control", json(["message": "gamepadChanged", "gamepadIndex": $0, "wasAdded": false])) }
        work.asyncAfter(deadline: .now() + 0.5) { [self] in
            slots.forEach { sendText("control", json(["message": "gamepadChanged", "gamepadIndex": $0, "wasAdded": true])) }
        }
        channels["input"]?.sendData(RTCDataBuffer(data: packet(clientMetadata: true), isBinary: true))
        inputStarted = true
        repeating(every: 0.016) { [weak self] in
            guard let self = self, !self.closed, let ch = self.channels["input"], ch.readyState == .open else { return }
            ch.sendData(RTCDataBuffer(data: self.packet(), isBinary: true))
        }
        repeating(every: 10, delay: 2) { [weak self] in self?.pendingFeedback = true }
        askKeyframe()
        repeating(every: 3, delay: 3) { [weak self] in self?.keyframeWatch() }

        let w = 1920, h = 1080
        let msgs: [(String, [String: Any])] = [
            ("/streaming/systemUi/configuration", ["version": [0, 2, 0], "systemUis": [10, 19, 31, 27, 32, -44, 40, 41, -43]]),
            ("/streaming/properties/clientappinstallidchanged", ["clientAppInstallId": UUID().uuidString]),
            ("/streaming/characteristics/orientationchanged", ["orientation": 0]),
            ("/streaming/characteristics/touchinputenabledchanged", ["touchInputEnabled": false]),
            ("/streaming/characteristics/clientdevicecapabilities", [:]),
            ("/streaming/characteristics/dimensionschanged", ["horizontal": w, "vertical": h, "preferredWidth": w, "preferredHeight": h,
                                                              "safeAreaLeft": 0, "safeAreaTop": 0, "safeAreaRight": w, "safeAreaBottom": h,
                                                              "supportsCustomResolution": true]),
        ]
        for (target, content) in msgs {
            sendText("message", json(["type": "Message", "content": json(content), "id": UUID().uuidString, "target": target, "cv": "\(messageCv)"]))
            messageCv += 1
        }
    }

    /// Until video flows, ask for a keyframe again every 3 s, up to 5 times.
    private func keyframeWatch() {
        guard !closed, !videoFlowing else { return }
        keyframeTries += 1
        if keyframeTries > 5 {
            DispatchQueue.main.async { self.listener?.xboxFailed("The Xbox connected but sent no picture.") }
            return
        }
        askKeyframe()
    }

    private func askKeyframe() { sendText("control", json(["message": "videoKeyframeRequested", "ifrRequested": false])) }

    private func repeating(every s: Double, delay: Double? = nil, _ f: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + (delay ?? s), repeating: s, leeway: .milliseconds(2))
        t.setEventHandler(handler: f)
        t.resume()
        timers.append(t)
    }

    /// XStreaming's input packet: report type, sequence, timestamp, then metadata or gamepad frames (little endian).
    private func packet(clientMetadata: Bool = false) -> Data {
        var d = Data()
        func u8(_ v: UInt8) { d.append(v) }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        let now = (CACurrentMediaTime() - start0) * 1000
        let frames = clientMetadata ? [] : (pads.isEmpty ? [PadFrame()] : pads)
        let feedback = !clientMetadata && pendingFeedback
        var type: UInt16 = 0
        if feedback { type |= 1 }
        if !frames.isEmpty { type |= 2 }
        if clientMetadata { type = 8 }
        u16(type)
        u32(inputSequence); inputSequence &+= 1
        f64(now)
        if feedback {
            pendingFeedback = false
            let n = UInt32(truncatingIfNeeded: Int(now)), sub = n &- 10
            u8(1)
            u32(UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000))); u32(sub); u32(sub); u32(n); u32(n); u32(n); u32(n)
        }
        if !frames.isEmpty {
            u8(UInt8(frames.count))
            for f in frames {
                u8(UInt8(f.index))
                var m: UInt16 = 0
                if f.nexus { m |= 2 }; if f.menu { m |= 4 }; if f.view { m |= 8 }
                if f.a { m |= 16 }; if f.b { m |= 32 }; if f.x { m |= 64 }; if f.y { m |= 128 }
                if f.up { m |= 256 }; if f.down { m |= 512 }; if f.left { m |= 1024 }; if f.right { m |= 2048 }
                if f.lb { m |= 4096 }; if f.rb { m |= 8192 }; if f.ls { m |= 16384 }; if f.rs { m |= 32768 }
                u16(m)
                func ax(_ v: Float) -> UInt16 { UInt16(bitPattern: Int16(max(-32767, min(32767, v * 32767)))) }
                func tr(_ v: Float) -> UInt16 { UInt16(max(0, min(1, v)) * 65535) }
                // GameController's Y is up-positive already (Android had to flip it)
                u16(ax(f.lx)); u16(ax(f.ly)); u16(ax(f.rx)); u16(ax(f.ry))
                u16(tr(f.lt)); u16(tr(f.rt))
                var ph: UInt32 = 0
                if f.up { ph |= 0x1 }; if f.down { ph |= 0x2 }; if f.left { ph |= 0x4 }; if f.right { ph |= 0x8 }
                if f.menu { ph |= 0x10 }; if f.view { ph |= 0x20 }; if f.ls { ph |= 0x40 }; if f.rs { ph |= 0x80 }
                if f.lb { ph |= 0x100 }; if f.rb { ph |= 0x200 }; if f.nexus { ph |= 0x400 }
                if f.a { ph |= 0x1000 }; if f.b { ph |= 0x2000 }; if f.x { ph |= 0x4000 }; if f.y { ph |= 0x8000 }
                if f.lt > 0 { ph |= 0x10000 }; if f.rt > 0 { ph |= 0x20000 }
                if f.lx != 0 { ph |= 0x40000 }; if f.ly != 0 { ph |= 0x80000 }; if f.rx != 0 { ph |= 0x100000 }; if f.ry != 0 { ph |= 0x200000 }
                u32(ph); u32(0)
            }
        }
        if clientMetadata { u8(0) }   // max touch points
        return d
    }

    // MARK: stats

    struct Stats { var fps = -1.0, rttMs = -1.0, mbps = -1.0, lossPct = -1.0, width = 0, height = 0 }
    private var lastBytes: Double = -1, lastAt: Double = 0

    func stats(_ cb: @escaping (Stats) -> Void) {
        guard let p = pc else { return }
        p.statistics { [weak self] report in
            guard let self = self else { return }
            var s = Stats()
            for st in report.statistics.values {
                let v = st.values
                if st.type == "inbound-rtp", v["kind"] as? String == "video" {
                    s.fps = (v["framesPerSecond"] as? NSNumber)?.doubleValue ?? s.fps
                    s.width = (v["frameWidth"] as? NSNumber)?.intValue ?? 0
                    s.height = (v["frameHeight"] as? NSNumber)?.intValue ?? 0
                    let lost = (v["packetsLost"] as? NSNumber)?.doubleValue ?? 0, got = (v["packetsReceived"] as? NSNumber)?.doubleValue ?? 0
                    if lost + got > 0 { s.lossPct = 100 * lost / (lost + got) }
                    if let bytes = (v["bytesReceived"] as? NSNumber)?.doubleValue {
                        let now = CACurrentMediaTime()
                        if self.lastBytes >= 0 && now > self.lastAt { s.mbps = (bytes - self.lastBytes) * 8 / ((now - self.lastAt) * 1e6) }
                        self.lastBytes = bytes; self.lastAt = now
                    }
                }
                if st.type == "candidate-pair", v["state"] as? String == "succeeded", (v["nominated"] as? NSNumber)?.boolValue == true {
                    s.rttMs = ((v["currentRoundTripTime"] as? NSNumber)?.doubleValue ?? -0.001) * 1000
                }
            }
            if s.fps > 0 || s.mbps > 0 { self.work.async { self.videoFlowing = true } }
            DispatchQueue.main.async { cb(s) }
        }
    }
}
