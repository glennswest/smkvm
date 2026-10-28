import Accelerate
import CoreVideo
import Foundation
@preconcurrency import WebRTC

/// JetKVM session errors.
public enum JetKVMError: Error, CustomStringConvertible {
    case loginFailed(String)
    case signaling(String)
    case closed(String)
    case takenOver

    public var description: String {
        switch self {
        case .loginFailed(let s): return "JetKVM login failed: \(s)"
        case .signaling(let s): return "signaling: \(s)"
        case .closed(let s): return "session closed: \(s)"
        case .takenOver: return "another client took the console (browser or cloud session)"
        }
    }

    /// Errors that won't be fixed by reconnecting.
    var isFatal: Bool {
        switch self {
        case .loginFailed, .takenOver: return true
        default: return false
        }
    }
}

/// Pure input-mapping helpers for the JetKVM HID RPC (unit-tested).
public enum JetKVMInput {
    /// USB HID boot-keyboard report from the set of held HID usages:
    /// usages E0–E7 fold into the modifier byte, the rest fill up to 6 slots.
    public static func keyboardReport(held: Set<UInt8>) -> (modifier: UInt8, keys: [UInt8]) {
        var modifier: UInt8 = 0
        var keys: [UInt8] = []
        for k in held.sorted() {
            if (0xE0...0xE7).contains(k) {
                modifier |= 1 << (k - 0xE0)
            } else if keys.count < 6 {
                keys.append(k)
            }
        }
        return (modifier, keys)
    }

    /// RFB-style buttons (1 left, 2 middle, 4 right) → USB HID
    /// (1 left, 2 right, 4 middle). Wheel bits (8/16) must be stripped first.
    public static func hidButtons(rfb: UInt8) -> UInt8 {
        (rfb & 1) | (rfb & 2) << 1 | (rfb & 4) >> 1
    }

    /// Framebuffer coordinate → HID absolute range 0–32767.
    public static func absCoord(_ v: Int, extent: Int) -> Int {
        guard extent > 1 else { return 0 }
        return min(32767, max(0, v * 32767 / (extent - 1)))
    }
}

/// One WebRTC console session to a JetKVM: local-auth login, signaling over
/// `/webrtc/signaling/client`, H.264 video decoded into the shared
/// `Framebuffer`, input as JSON-RPC over the `rpc` data channel.
/// `run()` blocks (it is called on the KVMClient session thread) until the
/// session ends; `close()` may be called from any thread.
final class JetKVMSession: NSObject, @unchecked Sendable {
    var log: ((String) -> Void)?

    private let host: String
    private let password: String
    private let fb: Framebuffer
    private let onUpdate: () -> Void
    private let onStatus: (String) -> Void

    private let lock = NSLock()
    private let endSem = DispatchSemaphore(value: 0)
    private var ended = false
    private var endError: Error?
    private var answered = false
    private var iceConnected = false
    private var pendingCandidates: [RTCIceCandidate] = []
    private var rpcID = 0
    private var videoStateID = 0
    private(set) var framesPainted = 0
    private var lastMoveAt = Date.distantPast      // lock
    private var lastSentButtons: UInt8 = 0         // lock
    private var pendingMove: (Int, Int, UInt8)?    // lock

    private var urlSession: URLSession!
    private var ws: URLSessionWebSocketTask?
    private var factory: RTCPeerConnectionFactory?
    private var pc: RTCPeerConnection?
    private var rpc: RTCDataChannel?
    private var hid: RTCDataChannel?   // binary pointer path (unreliable)
    private var renderer: JetKVMRenderer?
    // The track wrapper must stay alive: its dealloc detaches the renderer.
    private var videoTrack: RTCVideoTrack?
    private var timer: DispatchSourceTimer?

    private static let sslOnce: Void = { RTCInitializeSSL() }()

    init(host: String, password: String, fb: Framebuffer,
         onUpdate: @escaping () -> Void, onStatus: @escaping (String) -> Void) {
        self.host = host
        self.password = password
        self.fb = fb
        self.onUpdate = onUpdate
        self.onStatus = onStatus
        super.init()
        urlSession = URLSession(configuration: .ephemeral)
    }

    // MARK: lifecycle

    /// Logs in, runs the session, and blocks until it ends. Throws the error
    /// that ended it (nothing when `close()` ended it).
    func run() throws {
        _ = Self.sslOnce
        defer { teardown() }
        onStatus("logging in")
        let token = try login()
        onStatus("connecting")
        try openSignaling(token: token)
        startTimer()
        endSem.wait()
        lock.lock()
        let err = endError
        lock.unlock()
        if let err { throw err }
    }

    /// Ends the session (idempotent, any thread).
    func close() { end(nil) }

    private func end(_ error: Error?) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        endError = error
        lock.unlock()
        endSem.signal()
    }

    private var isEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    private func teardown() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
        ws?.cancel(with: .normalClosure, reason: nil)
        rpc?.close()
        hid?.close()
        if let r = renderer { videoTrack?.remove(r) }
        videoTrack = nil
        pc?.close()
        pc = nil
        factory = nil
        urlSession.invalidateAndCancel()
    }

    // MARK: HTTP login / first-time setup

    /// Logs in (POST /auth/login-local → authToken cookie). A device that
    /// has never been set up (GET /device/status isSetup=false) is set up
    /// first, local-password mode, with this host's password — so adding a
    /// factory-fresh JetKVM to the app just works. An empty password means
    /// noPassword mode: no login, no cookie.
    private func login() throws -> String? {
        if let status = try? request(path: "/device/status", method: "GET", body: nil),
           status.code == 200,
           let obj = try? JSONSerialization.jsonObject(with: status.body) as? [String: Any],
           obj["isSetup"] as? Bool == false {
            guard !password.isEmpty else {
                throw JetKVMError.loginFailed(
                    "device has never been set up — give this host a password and SMKVM will set it up")
            }
            onStatus("setting up device")
            log?("device not set up; performing first-time setup (local password mode)")
            let r = try request(path: "/device/setup", method: "POST",
                                body: ["localAuthMode": "password", "password": password])
            guard r.code == 200 else {
                throw JetKVMError.loginFailed("setup failed: HTTP \(r.code) \(r.text.prefix(120))")
            }
            // Setup answers with the authToken cookie, like a login.
            if let token = r.authToken { return token }
        }

        guard !password.isEmpty else {
            // No password means noPassword mode — but if the device is in
            // password mode, say so now instead of letting the signaling
            // socket fail with an opaque "bad response".
            if let probe = try? request(path: "/device", method: "GET", body: nil),
               probe.code == 401 {
                throw JetKVMError.loginFailed(
                    "the device has a password — edit this host and enter it")
            }
            return nil
        }
        let r = try request(path: "/auth/login-local", method: "POST",
                            body: ["password": password])
        guard r.code == 200 else {
            throw JetKVMError.loginFailed("HTTP \(r.code) \(r.text.prefix(120))")
        }
        guard let token = r.authToken else {
            throw JetKVMError.loginFailed("no authToken cookie in response")
        }
        return token
    }

    private struct HTTPResult {
        let code: Int
        let body: Data
        let authToken: String?
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    /// One synchronous JSON request to the device.
    private func request(path: String, method: String, body: [String: Any]?) throws -> HTTPResult {
        guard let url = URL(string: "http://\(host)\(path)") else {
            throw JetKVMError.loginFailed("bad address \(host)")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        urlSession.dataTask(with: req) { d, r, e in result = (d, r, e); sem.signal() }.resume()
        sem.wait()
        if let e = result.2 { throw JetKVMError.signaling(e.localizedDescription) }
        guard let http = result.1 as? HTTPURLResponse else {
            throw JetKVMError.signaling("no HTTP response")
        }
        let fields = (http.allHeaderFields as? [String: String]) ?? [:]
        let token = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .first(where: { $0.name == "authToken" })?.value
        return HTTPResult(code: http.statusCode, body: result.0 ?? Data(), authToken: token)
    }

    // MARK: signaling

    private func openSignaling(token: String?) throws {
        guard let url = URL(string: "ws://\(host)/webrtc/signaling/client") else {
            throw JetKVMError.signaling("bad address \(host)")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if let token { req.setValue("authToken=\(token)", forHTTPHeaderField: "Cookie") }
        let task = urlSession.webSocketTask(with: req)
        lock.lock(); ws = task; lock.unlock()
        task.resume()
        receiveNext(task)
    }

    private func receiveNext(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, !self.isEnded else { return }
            switch result {
            case .failure(let e):
                self.end(JetKVMError.signaling(e.localizedDescription))
            case .success(let msg):
                if case .string(let text) = msg { self.handleSignal(text) }
                self.receiveNext(task)
            }
        }
    }

    private func handleSignal(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let dict = obj as? [String: Any] else {
            log?("signal: unparseable message \(text.prefix(200))")
            return
        }
        if let err = dict["error"] {
            end(JetKVMError.signaling("device error: \(err)"))
            return
        }
        switch dict["type"] as? String {
        case "device-metadata":
            log?("device metadata: \(dict["data"].map { "\($0)" } ?? "")")
            startPeerConnection()
        case "answer":
            guard let b64 = dict["data"] as? String, let sdp = Self.decodeSD(b64) else {
                end(JetKVMError.signaling("bad answer"))
                return
            }
            acceptAnswer(sdp)
        case "new-ice-candidate":
            guard let d = dict["data"] as? [String: Any],
                  let c = d["candidate"] as? String, !c.isEmpty else { return }
            let mid = d["sdpMid"] as? String
            let index = (d["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
            let candidate = RTCIceCandidate(sdp: c, sdpMLineIndex: index, sdpMid: mid)
            pc?.add(candidate) { [weak self] e in
                if let e { self?.log?("remote candidate rejected: \(e.localizedDescription)") }
            }
        default:
            log?("signal: unhandled type \(dict["type"] ?? "?")")
        }
    }

    private func sendSignal(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        ws?.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] e in
            if let e { self?.end(JetKVMError.signaling(e.localizedDescription)) }
        }
    }

    /// base64(JSON {type, sdp}) — the wire format of `WebRTCSessionRequest.sd`.
    private static func encodeSD(_ sdp: RTCSessionDescription) -> String? {
        let obj = ["type": "offer", "sdp": sdp.sdp]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return data.base64EncodedString()
    }

    private static func decodeSD(_ b64: String) -> RTCSessionDescription? {
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sdp = obj["sdp"] as? String else { return nil }
        return RTCSessionDescription(type: .answer, sdp: sdp)
    }

    // MARK: peer connection

    private func startPeerConnection() {
        lock.lock()
        let already = pc != nil
        lock.unlock()
        guard !already else { return }

        let decoders = RTCDefaultVideoDecoderFactory()
        let encoders = RTCDefaultVideoEncoderFactory()
        let f = RTCPeerConnectionFactory(encoderFactory: encoders, decoderFactory: decoders)
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = f.peerConnection(with: config, constraints: constraints, delegate: self) else {
            end(JetKVMError.signaling("could not create peer connection"))
            return
        }
        lock.lock()
        factory = f
        pc = connection
        lock.unlock()

        // The data channel must exist before the offer so SCTP is negotiated.
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        guard let channel = connection.dataChannel(forLabel: "rpc", configuration: dcConfig) else {
            end(JetKVMError.signaling("could not create data channel"))
            return
        }
        channel.delegate = self
        lock.lock(); rpc = channel; lock.unlock()

        // Mouse moves ride a separate binary channel, like the device's own
        // UI: ordered but unreliable (a lost move is superseded by the next
        // one), no JSON to parse on the device, no head-of-line blocking
        // behind the reliable rpc channel.
        let hidConfig = RTCDataChannelConfiguration()
        hidConfig.isOrdered = true
        hidConfig.maxRetransmits = 0
        if let h = connection.dataChannel(forLabel: "hidrpc-unreliable-ordered", configuration: hidConfig) {
            h.delegate = self
            lock.lock(); hid = h; lock.unlock()
        }

        let recvOnly = { () -> RTCRtpTransceiverInit in
            let t = RTCRtpTransceiverInit()
            t.direction = .recvOnly
            return t
        }
        connection.addTransceiver(of: .video, init: recvOnly())
        // The device always attaches an audio track; offering audio keeps the
        // m-line order intact (and HDMI audio plays for free).
        connection.addTransceiver(of: .audio, init: recvOnly())

        connection.offer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            guard let sdp else {
                self.end(JetKVMError.signaling("offer: \(error?.localizedDescription ?? "?")"))
                return
            }
            connection.setLocalDescription(sdp) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.end(JetKVMError.signaling("setLocal: \(error.localizedDescription)"))
                    return
                }
                guard let sd = Self.encodeSD(sdp) else {
                    self.end(JetKVMError.signaling("could not encode offer"))
                    return
                }
                self.sendSignal(["type": "offer", "data": ["sd": sd]])
            }
        }
    }

    private func acceptAnswer(_ sdp: RTCSessionDescription) {
        guard let pc else { return }
        pc.setRemoteDescription(sdp) { [weak self] error in
            guard let self else { return }
            if let error {
                self.end(JetKVMError.signaling("setRemote: \(error.localizedDescription)"))
                return
            }
            self.lock.lock()
            self.answered = true
            let queued = self.pendingCandidates
            self.pendingCandidates.removeAll()
            self.lock.unlock()
            // The device drops client candidates until its answer is out;
            // flush the ones gathered meanwhile.
            for c in queued { self.sendCandidate(c) }
            self.attachRenderer()
        }
    }

    private func attachRenderer() {
        guard let pc else { return }
        let r = JetKVMRenderer { [weak self] frame in self?.paint(frame) }
        lock.lock(); renderer = r; lock.unlock()
        for t in pc.transceivers {
            if let track = t.receiver.track as? RTCVideoTrack {
                track.add(r)
                lock.lock(); videoTrack = track; lock.unlock()
                log?("video track attached (\(track.trackId))")
            }
        }
    }

    private func sendCandidate(_ c: RTCIceCandidate) {
        var data: [String: Any] = ["candidate": c.sdp, "sdpMLineIndex": Int(c.sdpMLineIndex)]
        if let mid = c.sdpMid { data["sdpMid"] = mid }
        sendSignal(["type": "new-ice-candidate", "data": data])
    }

    // MARK: keep-alive / watchdog

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        var tick = 0
        let started = Date()
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            self.rpcCall("ping", params: nil)
            if tick % 4 == 0 { self.wsPing() }
            if tick % 2 == 0 { self.logInboundStats() }
            self.lock.lock()
            let up = self.iceConnected
            self.lock.unlock()
            if !up && Date().timeIntervalSince(started) > 25 {
                self.end(JetKVMError.signaling("no connection after 25 s"))
            }
        }
        lock.lock(); timer = t; lock.unlock()
        t.resume()
    }

    /// Logs the inbound video RTP/decoder counters — the first place to look
    /// when the session is up but no frames arrive.
    private func logInboundStats() {
        guard let pc, log != nil else { return }
        pc.statistics { [weak self] report in
            guard let self else { return }
            for s in report.statistics.values where s.type == "inbound-rtp" {
                let v = s.values
                guard v["kind"] as? String == "video" else { continue }
                let n = { (key: String) in (v[key] as? NSNumber)?.intValue ?? 0 }
                let packets = n("packetsReceived")
                let frames = n("framesDecoded")
                let key = n("keyFramesDecoded")
                let dropped = n("framesDropped")
                let decoder = v["decoderImplementation"] as? String ?? "?"
                // Average jitter-buffer dwell per frame — the latency the
                // receiver adds on top of decode.
                let jbDelay = (v["jitterBufferDelay"] as? NSNumber)?.doubleValue ?? 0
                let jbCount = (v["jitterBufferEmittedCount"] as? NSNumber)?.doubleValue ?? 0
                let jbMs = jbCount > 0 ? Int(jbDelay / jbCount * 1000) : 0
                let codec = (v["codecId"] as? String).flatMap {
                    (report.statistics[$0]?.values["mimeType"]) as? String
                } ?? "?"
                self.log?("inbound video: \(codec) packets \(packets) framesDecoded \(frames) " +
                          "key \(key) dropped \(dropped) decoder \(decoder) jitterBuffer \(jbMs)ms")
            }
        }
    }

    private func wsPing() {
        ws?.sendPing { [weak self] e in
            if let e { self?.log?("ws ping failed: \(e.localizedDescription)") }
        }
    }

    // MARK: JSON-RPC over the data channel

    @discardableResult
    private func rpcCall(_ method: String, params: [String: Any]?) -> Int {
        lock.lock()
        rpcID += 1
        let id = rpcID
        let channel = rpc
        lock.unlock()
        guard let channel, channel.readyState == .open else { return id }
        var obj: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        if let params { obj["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return id }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
        return id
    }

    /// The HDMI input's state, from the videoInputState event or a
    /// getVideoState reply: drives the "no signal" status.
    private func handleVideoState(_ p: [String: Any]) {
        let error = p["error"] as? String ?? ""
        let ready = p["ready"] as? Bool ?? false
        if ready && error.isEmpty {
            let w = (p["width"] as? NSNumber)?.intValue ?? 0
            let h = (p["height"] as? NSNumber)?.intValue ?? 0
            let fps = (p["fps"] as? NSNumber)?.doubleValue ?? 0
            log?("video input \(w)x\(h) @ \(Int(fps)) fps")
            lock.lock()
            let painted = framesPainted > 0
            lock.unlock()
            onStatus(painted ? "connected" : "connecting")
        } else {
            onStatus("no video: \(error.isEmpty ? "input not ready" : error.replacingOccurrences(of: "_", with: " "))")
        }
    }

    // MARK: input (called from KVMClient, any thread)

    func sendKeyboard(held: Set<UInt8>) {
        let (modifier, keys) = JetKVMInput.keyboardReport(held: held)
        rpcCall("keyboardReport", params: ["modifier": Int(modifier), "keys": keys.map(Int.init)])
    }

    /// x/y in framebuffer coordinates, buttons RFB-style without wheel bits.
    /// Move-only reports are coalesced to ~250 Hz (macOS delivers mouseMoved
    /// at the mouse's polling rate; flooding the device's HID queue lags the
    /// cursor); button changes always go out immediately, and a trailing
    /// flush lands the final position.
    func sendAbsMouse(x: Int, y: Int, rfbButtons: UInt8) {
        let hx = JetKVMInput.absCoord(x, extent: fb.width)
        let hy = JetKVMInput.absCoord(y, extent: fb.height)
        let hb = JetKVMInput.hidButtons(rfb: rfbButtons)
        let now = Date()
        lock.lock()
        if hb == lastSentButtons && now.timeIntervalSince(lastMoveAt) < 0.004 {
            let flushScheduled = pendingMove != nil
            pendingMove = (hx, hy, hb)
            lock.unlock()
            if !flushScheduled {
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.006) { [weak self] in
                    self?.flushPendingMove()
                }
            }
            return
        }
        lastSentButtons = hb
        lastMoveAt = now
        pendingMove = nil
        lock.unlock()
        sendPointer(hx, hy, hb)
    }

    private func flushPendingMove() {
        lock.lock()
        guard let (hx, hy, hb) = pendingMove else { lock.unlock(); return }
        pendingMove = nil
        lastSentButtons = hb
        lastMoveAt = Date()
        lock.unlock()
        sendPointer(hx, hy, hb)
    }

    /// One absolute pointer report: the binary HID channel when it is open
    /// (TypePointerReport 0x03: x/y as big-endian Int32, then buttons),
    /// otherwise the JSON-RPC fallback.
    private func sendPointer(_ x: Int, _ y: Int, _ buttons: UInt8) {
        lock.lock()
        let channel = hid
        lock.unlock()
        guard let channel, channel.readyState == .open else {
            rpcCall("absMouseReport", params: ["x": x, "y": y, "buttons": Int(buttons)])
            return
        }
        var d = Data(capacity: 10)
        d.append(0x03)
        for v in [Int32(x), Int32(y)] {
            d.append(UInt8(truncatingIfNeeded: v >> 24))
            d.append(UInt8(truncatingIfNeeded: v >> 16))
            d.append(UInt8(truncatingIfNeeded: v >> 8))
            d.append(UInt8(truncatingIfNeeded: v))
        }
        d.append(buttons)
        channel.sendData(RTCDataBuffer(data: d, isBinary: true))
    }

    func sendWheel(_ wheelY: Int) {
        rpcCall("wheelReport", params: ["wheelY": wheelY, "wheelX": 0])
    }

    /// "power-short", "power-long" or "reset" — needs the ATX extension.
    func sendATXPower(_ action: String) {
        rpcCall("setATXPowerAction", params: ["action": action])
    }

    // MARK: video

    private func paint(_ frame: RTCVideoFrame) {
        let w = Int(frame.width), h = Int(frame.height)
        guard w > 0, h > 0, w <= 8192, h <= 8192 else { return }
        if w != fb.width || h != fb.height { log?("video \(w)x\(h)") }
        fb.resize(width: w, height: h)
        let ok = fb.withPixels { px, fw, fh -> Bool in
            guard fw == w, fh == h, let base = px.baseAddress else { return false }
            if let cv = frame.buffer as? RTCCVPixelBuffer {
                return Self.paintCVPixelBuffer(cv.pixelBuffer, into: base, width: w, height: h)
            }
            return Self.paintI420(frame.buffer.toI420(), into: base, width: w, height: h)
        }
        guard ok else {
            logOnce("unsupported frame format; frame dropped")
            return
        }
        lock.lock()
        framesPainted += 1
        let first = framesPainted == 1
        lock.unlock()
        if first { onStatus("connected") }
        onUpdate()
    }

    private var loggedOnce = Set<String>()
    private func logOnce(_ s: String) {
        lock.lock()
        let new = loggedOnce.insert(s).inserted
        lock.unlock()
        if new { log?(s) }
    }

    // vImage conversion state: BGRA byte order (permute [3,2,1,0] of ARGB)
    // read as little-endian UInt32 gives the Framebuffer's 0xAARRGGBB.
    private static let nv12Video = makeConversion(kvImage420Yp8_CbCr8, videoRange: true)
    private static let nv12Full = makeConversion(kvImage420Yp8_CbCr8, videoRange: false)
    private static let i420Video = makeConversion(kvImage420Yp8_Cb8_Cr8, videoRange: true)

    private static func makeConversion(_ type: vImageYpCbCrType, videoRange: Bool) -> vImage_YpCbCrToARGB {
        var info = vImage_YpCbCrToARGB()
        var range = videoRange
            ? vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235,
                                      CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 1)
            : vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255,
                                      CbCrRangeMax: 255, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
        // BT.709 (the SDK's kvImage_YpCbCrToARGBMatrix_ITU_R_709_2; that
        // global is a `var` to Swift 6 and so not concurrency-safe to touch).
        var matrix = vImage_YpCbCrToARGBMatrix(
            Yp: 1, Cr_R: 1.5748, Cr_G: -0.4681, Cb_G: -0.1873, Cb_B: 1.8556)
        vImageConvert_YpCbCrToARGB_GenerateConversion(
            &matrix, &range, &info,
            type, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
        return info
    }

    private static func paintCVPixelBuffer(_ pb: CVPixelBuffer, into dest: UnsafeMutablePointer<UInt32>,
                                           width: Int, height: Int) -> Bool {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = min(width, CVPixelBufferGetWidth(pb))
        let h = min(height, CVPixelBufferGetHeight(pb))
        let format = CVPixelBufferGetPixelFormatType(pb)
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let src = CVPixelBufferGetBaseAddress(pb) else { return false }
            let stride = CVPixelBufferGetBytesPerRow(pb)
            for row in 0..<h {
                memcpy(dest + row * width, src + row * stride, w * 4)
            }
            return true
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
                  let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return false }
            var srcY = vImage_Buffer(data: yBase, height: vImagePixelCount(h),
                                     width: vImagePixelCount(w),
                                     rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
            var srcC = vImage_Buffer(data: cBase, height: vImagePixelCount((h + 1) / 2),
                                     width: vImagePixelCount((w + 1) / 2),
                                     rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
            var dst = vImage_Buffer(data: dest, height: vImagePixelCount(h),
                                    width: vImagePixelCount(w), rowBytes: width * 4)
            var info = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? nv12Video : nv12Full
            var permute: [UInt8] = [3, 2, 1, 0]
            return vImageConvert_420Yp8_CbCr8ToARGB8888(
                &srcY, &srcC, &dst, &info, &permute, 255, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        default:
            return false
        }
    }

    private static func paintI420(_ buf: RTCI420BufferProtocol, into dest: UnsafeMutablePointer<UInt32>,
                                  width: Int, height: Int) -> Bool {
        let w = min(width, Int(buf.width))
        let h = min(height, Int(buf.height))
        var srcY = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: buf.dataY),
                                 height: vImagePixelCount(h), width: vImagePixelCount(w),
                                 rowBytes: Int(buf.strideY))
        var srcCb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: buf.dataU),
                                  height: vImagePixelCount((h + 1) / 2),
                                  width: vImagePixelCount((w + 1) / 2), rowBytes: Int(buf.strideU))
        var srcCr = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: buf.dataV),
                                  height: vImagePixelCount((h + 1) / 2),
                                  width: vImagePixelCount((w + 1) / 2), rowBytes: Int(buf.strideV))
        var dst = vImage_Buffer(data: dest, height: vImagePixelCount(h),
                                width: vImagePixelCount(w), rowBytes: width * 4)
        var info = i420Video
        var permute: [UInt8] = [3, 2, 1, 0]
        return vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
            &srcY, &srcCb, &srcCr, &dst, &info, &permute, 255, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }
}

// MARK: delegates

extension JetKVMSession: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log?("ice state \(newState.rawValue)")
        switch newState {
        case .connected, .completed:
            lock.lock(); iceConnected = true; lock.unlock()
        case .failed:
            end(JetKVMError.closed("ICE failed"))
        case .closed:
            end(JetKVMError.closed("connection closed"))
        case .disconnected:
            // Transient per spec, but on a LAN it means the link died.
            end(JetKVMError.closed("connection lost"))
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        lock.lock()
        let ready = answered
        if !ready { pendingCandidates.append(candidate) }
        lock.unlock()
        if ready { sendCandidate(candidate) }
    }
}

extension JetKVMSession: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        log?("data channel \(dataChannel.label) state \(dataChannel.readyState.rawValue)")
        guard dataChannel.readyState == .open else { return }
        if dataChannel.label.hasPrefix("hidrpc") {
            // HID RPC handshake: type 0x01, protocol version 0x01.
            dataChannel.sendData(RTCDataBuffer(data: Data([0x01, 0x01]), isBinary: true))
            return
        }
        // Ask for the input state up front; with no HDMI signal there will
        // never be a frame, and the status should say why.
        let id = rpcCall("getVideoState", params: nil)
        lock.lock()
        videoStateID = id
        lock.unlock()
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary,
              let obj = try? JSONSerialization.jsonObject(with: buffer.data),
              let dict = obj as? [String: Any] else { return }
        if let method = dict["method"] as? String {
            switch method {
            case "otherSessionConnected":
                end(JetKVMError.takenOver)
            case "videoInputState":
                handleVideoState(dict["params"] as? [String: Any] ?? [:])
            default:
                log?("rpc event \(method)")
            }
            return
        }
        if let id = (dict["id"] as? NSNumber)?.intValue {
            lock.lock()
            let isVideoState = id == videoStateID
            lock.unlock()
            if isVideoState, let result = dict["result"] as? [String: Any] {
                handleVideoState(result)
                return
            }
        }
        if let error = dict["error"] {
            log?("rpc error: \(error)")
        }
    }
}

/// Feeds decoded frames to the session.
private final class JetKVMRenderer: NSObject, RTCVideoRenderer {
    private let onFrame: (RTCVideoFrame) -> Void

    init(onFrame: @escaping (RTCVideoFrame) -> Void) {
        self.onFrame = onFrame
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        if let frame { onFrame(frame) }
    }
}
