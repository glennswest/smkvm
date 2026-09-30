import Foundation

public enum KVMError: Error, CustomStringConvertible {
    case tlsUnsupported(Int)
    case noATENSecurity([UInt8])
    case refused(String)
    case authFailed(UInt32)
    case vncAuthFailed(String)
    case protocolError(String)

    public var description: String {
        switch self {
        case .tlsUnsupported(let p):
            return "BMC wants KVM over TLS on port \(p) — disable \"KVM SSL\" in the BMC web UI"
        case .noATENSecurity(let t): return "not an ATEN iKVM server (security types \(t))"
        case .refused(let s): return "BMC refused the session: \(s)"
        case .authFailed(let r): return "KVM authentication failed (\(r))"
        case .vncAuthFailed(let s): return "VNC password rejected\(s.isEmpty ? "" : ": \(s)")"
        case .protocolError(let s): return "protocol error: \(s)"
        }
    }

    /// Errors that won't be fixed by reconnecting.
    var isFatal: Bool {
        switch self {
        case .tlsUnsupported, .noATENSecurity, .vncAuthFailed: return true
        default: return false
        }
    }
}

/// Power actions available over the KVM connection.
public enum PowerAction: UInt8, Sendable {
    case off = 0, on = 1, reset = 2, softOff = 3
}

/// How to reach a host's console.
public enum ConsoleKind: Sendable, Equatable {
    /// Supermicro/ATEN iKVM: web login → session key → ATEN RFB on 5900.
    case aten
    /// A standard VNC server (e.g. Dell iDRAC's built-in one) on `port`,
    /// VNC password authentication.
    case vnc(port: Int)
}

/// One KVM session to one BMC. ATEN: HTTP login → session key → ATEN RFB;
/// VNC: standard RFB. The session runs on its own thread and reconnects
/// (with a fresh key for ATEN) when the link drops. Callbacks are delivered
/// on the main thread.
public final class KVMClient: @unchecked Sendable {
    public var onFrame: (@MainActor (FrameSnapshot) -> Void)?
    public var onStatus: (@MainActor (String) -> Void)?
    /// Diagnostic log (protocol details). Called on the session thread.
    public var log: ((String) -> Void)?
    /// Server message 0x37 body length: 2 on early firmware, 3 on later X9 (protocol.md §6).
    public var mouseInfoLength = 2
    /// Send the 0x15 keep-alive every 3 s (protocol.md §5.5).
    public var keepAliveEnabled = true
    /// Receives every decoded update (not the coalesced UI frames). May be
    /// set or cleared at any time.
    public var screenLogger: ScreenLogger? {
        get { lock.lock(); defer { lock.unlock() }; return _screenLogger }
        set { lock.lock(); _screenLogger = newValue; lock.unlock() }
    }
    private var _screenLogger: ScreenLogger?

    public let host: String
    public let kind: ConsoleKind
    let user: String
    let password: String

    private let lock = NSLock()
    private var running = false
    private var socket: Socket?
    private var thread: Thread?
    private var timer: DispatchSourceTimer?

    // Session state (session thread, except where noted under lock).
    let fb = Framebuffer(width: 0, height: 0)
    var screenOff = false
    var lastRx = Date()
    private var heldKeys = Set<UInt8>()     // lock
    private var buttons: UInt8 = 0          // lock
    private var frameQueued = false         // lock
    private var latest: FrameSnapshot?      // lock
    private var current: FrameSnapshot?     // lock
    private var frameSeq = 0                // lock
    private var statusText = "idle"         // lock

    public init(host: String, user: String, password: String, kind: ConsoleKind = .aten) {
        self.host = host
        self.kind = kind
        self.user = user
        self.password = password
    }

    // MARK: lifecycle

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true
        let t = Thread { [self] in run() }
        t.name = "smkvm \(host)"
        thread = t
        t.start()
    }

    public func stop() {
        lock.lock()
        running = false
        let s = socket
        lock.unlock()
        s?.shutdown()
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func status(_ s: String) {
        log?("status: \(s)")
        lock.lock(); statusText = s; lock.unlock()
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onStatus?(s) }
        }
    }

    private func run() {
        var failures = 0
        while isRunning {
            var web: BMCWeb?
            do {
                switch kind {
                case .aten:
                    let w = BMCWeb(host: host)
                    web = w
                    status("logging in")
                    try w.login(user: user, password: password)
                    let ticket = try w.fetchTicket()
                    log?("JNLP arguments: \(ticket.arguments.count), port \(ticket.port), tls \(ticket.tls)")
                    if ticket.tls { throw KVMError.tlsUnsupported(ticket.port) }
                    status("connecting")
                    try withSocket(port: ticket.port, fallback: 5900) { s in
                        try handshake(s, ticket)
                        try runConnected { try readLoop(s) }
                    }
                case .vnc(let port):
                    status("connecting")
                    try withSocket(port: port, fallback: nil) { s in
                        try vncHandshake(s)
                        try runConnected { try vncReadLoop(s) }
                    }
                }
                failures = 0
            } catch {
                log?("session ended: \(error)")
                if !isRunning { break }
                failures += 1
                status("\(error)")
                if let e = error as? BMCWebError, case .loginFailed = e { web?.logout(); break }
                if let k = error as? KVMError, k.isFatal { web?.logout(); break }
            }
            web?.logout()
            guard isRunning else { break }
            // Back off: 2 s, 4 s, … up to 30 s.
            let delay = min(30.0, 2.0 * pow(2.0, Double(max(0, failures - 1))))
            let until = Date().addingTimeInterval(delay)
            while isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.2) }
            if isRunning { status("reconnecting") }
        }
        status("disconnected")
    }

    /// Connects (falling back to `fallback` if the first port fails), runs
    /// `body` with the socket registered for input/timers, and tears down.
    private func withSocket(port: Int, fallback: Int?, _ body: (Socket) throws -> Void) throws {
        let s: Socket
        do {
            s = try Socket(host: host, port: port)
        } catch where fallback != nil && fallback != port {
            log?("port \(port) failed (\(error)); trying \(fallback!)")
            s = try Socket(host: host, port: fallback!)
        }
        lock.lock()
        socket = s
        let stillRunning = running
        lock.unlock()
        defer {
            screenLogger?.sessionEnded()
            stopTimer()
            lock.lock(); socket = nil; lock.unlock()
            s.shutdown()
        }
        guard stillRunning else { return }
        try body(s)
    }

    private func runConnected(_ loop: () throws -> Void) throws {
        status("connected")
        lastRx = Date()
        startTimer()
        try loop()
    }

    // MARK: ATEN session

    private func handshake(_ s: Socket, _ t: KVMTicket) throws {
        let banner = try s.read(12)
        guard banner.starts(with: Array("RFB ".utf8)) else {
            throw KVMError.protocolError("bad banner \(hex(banner))")
        }
        try s.write(banner)   // echo verbatim (AST2400 sends 055.008)

        let n = Int(try s.u8())
        if n == 0 {
            let len = Int(try s.u32())
            let reason = String(decoding: try s.read(min(len, 4096)), as: UTF8.self)
            throw KVMError.refused(reason)
        }
        let types = try s.read(n)
        guard types.contains(0x10) else { throw KVMError.noATENSecurity(types) }
        try s.write([0x10])
        let blob = try s.read(24)
        log?("security blob \(hex(blob))")

        // The BMC wants ClientInit within ~100 ms of the auth result: pipeline it.
        try s.write(ATENMessages.credentials(user: t.user, password: t.password) + [1])
        let result = try s.u32()
        if result != 0 { throw KVMError.authFailed(result) }

        // ServerInit: size and pixel format are placeholders.
        _ = try s.read(2 + 2 + 16)
        let nameLen = Int(try s.u32())
        guard nameLen <= 4096 else { throw KVMError.protocolError("server name length \(nameLen)") }
        let name = String(decoding: try s.read(nameLen), as: UTF8.self)
        let trailer = try s.read(12)
        log?("server \"\(name)\" trailer \(hex(trailer))")
        if trailer[9] == 0 { status("connected (view only)") }

        try s.write(ATENMessages.updateRequest(incremental: false, width: max(fb.width, 1), height: max(fb.height, 1)))
    }

    private func readLoop(_ s: Socket) throws {
        while isRunning {
            let type = try s.u8()
            lastRx = Date()
            switch type {
            case 0x00:
                try framebufferUpdate(s)
            case 0x04:
                let b = try s.read(20)
                let flag = u32(b, 16)
                if flag == 1 {
                    let w = Int(u32(b, 8)), h = Int(u32(b, 12))
                    try s.skip(4 + w * h * 2)
                }
            case 0x16:
                _ = try s.u8()
                if keepAliveEnabled { try s.write(ATENMessages.keepAlive) }
            case 0x33: try s.skip(4)
            case 0x35: try s.skip(5)
            case 0x37: try s.skip(mouseInfoLength)
            case 0x39:
                let b = try s.read(264)
                let a = u32(b, 0), c = u32(b, 4)
                let text = String(decoding: b[8...].prefix { $0 != 0 }, as: UTF8.self)
                log?("session message \(a)/\(c): \(text)")
                if a == 1 && c == 4 { status("view only — another user has control") }
            case 0x3C: try s.skip(8)
            default:
                let peek = (try? s.read(16)) ?? []
                throw KVMError.protocolError(String(format: "unknown message 0x%02X, next bytes %@", type, hex(peek)))
            }
        }
    }

    private func framebufferUpdate(_ s: Socket) throws {
        _ = try s.u8()
        let rects = Int(try s.u16())
        var full = false, painted = false
        for _ in 0..<rects {
            let h = try s.read(20)
            let w = Int(u16(h, 4)), hh = Int(u16(h, 6))
            let enc = Int32(bitPattern: u32(h, 8))
            let len = Int(u32(h, 16))
            guard len <= 64 << 20 else { throw KVMError.protocolError("rect length \(len)") }
            let payload = try s.read(len)

            if w == 0xFD80 && hh == 0xFE20 {
                if !screenOff { status("no signal"); screenLogger?.signalLost() }
                screenOff = true
                continue
            }
            if screenOff { status("connected") }
            screenOff = false
            guard w > 0, hh > 0, w <= 4096, hh <= 4096, !payload.isEmpty else { continue }
            if w != fb.width || hh != fb.height {
                log?("resolution \(w)x\(hh), encoding 0x\(String(enc, radix: 16))")
                full = true
            }
            painted = true
            switch enc {
            case 0x59, 0x00:
                try HermonDecoder.decode(payload, width: w, height: hh, into: fb)
            case 0x57:
                try ast.decode(payload, width: w, height: hh, into: fb)
            default:
                throw DecodeError.unsupported("encoding 0x\(String(enc, radix: 16))")
            }
        }
        if painted { deliver() }
        // While the screen is off the 1 s timer polls; answering every
        // screen-off update straight away would spin at the BMC's reply rate.
        guard !screenOff else { return }
        try s.write(ATENMessages.updateRequest(incremental: !full,
                                               width: max(fb.width, 1), height: max(fb.height, 1)))
    }

    let ast = AST2100Decoder()

    /// Hands the newest frame to the UI, coalescing if the UI is behind.
    func deliver() {
        let snap = fb.snapshot()
        screenLogger?.feed(snap)
        lock.lock()
        latest = snap
        current = snap
        frameSeq += 1
        let schedule = !frameQueued
        frameQueued = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let f = latest
            latest = nil
            frameQueued = false
            lock.unlock()
            if let f { MainActor.assumeIsolated { onFrame?(f) } }
        }
    }

    /// The newest decoded frame and its sequence number (increments on
    /// every update). Safe from any thread.
    public var currentFrame: (seq: Int, frame: FrameSnapshot?) {
        lock.lock(); defer { lock.unlock() }
        return (frameSeq, current)
    }

    /// True between start() and stop().
    public var isActive: Bool { isRunning }

    /// The latest status line ("connected", "no signal", an error…).
    public var currentStatus: String {
        lock.lock(); defer { lock.unlock() }
        return statusText
    }

    // MARK: timers

    func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        var tick = 0
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            let idle = Date().timeIntervalSince(self.lastRx)
            // ATEN always answers an update request, so silence means a dead
            // link. A VNC server may stay quiet while the screen is static.
            let isATEN = self.kind == .aten
            let (poke, dead): (TimeInterval, TimeInterval) = isATEN ? (5, 15) : (20, 45)
            if isATEN && self.keepAliveEnabled && tick % 3 == 0 { self.send(ATENMessages.keepAlive) }
            if (isATEN && self.screenOff) || idle > poke {
                self.send(ATENMessages.updateRequest(incremental: false,
                                                     width: max(self.fb.width, 1), height: max(self.fb.height, 1)))
            }
            if idle > dead {
                self.log?("no data for \(Int(idle)) s; reconnecting")
                self.currentSocket?.shutdown()
            }
        }
        lock.lock(); timer = t; lock.unlock()
        t.resume()
    }

    func stopTimer() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }

    var currentSocket: Socket? {
        lock.lock(); defer { lock.unlock() }
        return socket
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let s = currentSocket else { return }
        do { try s.write(bytes) } catch { s.shutdown() }
    }

    // MARK: input (any thread)

    public func sendKey(macKeyCode: UInt16, down: Bool) {
        guard let hid = KeyMap.hid(forMacKeyCode: macKeyCode) else {
            log?("no HID mapping for mac keycode \(macKeyCode)")
            return
        }
        sendHID(hid, down: down)
    }

    public func sendHID(_ hid: UInt8, down: Bool) {
        lock.lock()
        if down { heldKeys.insert(hid) } else { heldKeys.remove(hid) }
        lock.unlock()
        send(keyMessage(hid, down))
    }

    private func keyMessage(_ hid: UInt8, _ down: Bool) -> [UInt8] {
        switch kind {
        case .aten:
            return ATENMessages.key(hid: hid, down: down)
        case .vnc:
            guard let sym = KeySyms.keysym(forHID: hid) else { return [] }
            return [4, down ? 1 : 0, 0, 0] + ATENMessages.be32(sym)
        }
    }

    /// Presses the keys in order, then releases them in reverse.
    public func sendChord(_ keys: [UInt8]) {
        keys.forEach { sendHID($0, down: true) }
        keys.reversed().forEach { sendHID($0, down: false) }
    }

    public func sendCtrlAltDel() {
        sendChord([KeyMap.leftControl, KeyMap.leftAlt, KeyMap.delete])
    }

    public func sendPointer(x: Int, y: Int, buttons: UInt8) {
        lock.lock(); self.buttons = buttons; lock.unlock()
        switch kind {
        case .aten: send(ATENMessages.pointer(x: x, y: y, buttons: buttons))
        case .vnc: send([5, buttons] + ATENMessages.be16(max(0, x)) + ATENMessages.be16(max(0, y)))
        }
    }

    /// Releases every key still held (e.g. when the window loses focus).
    public func releaseAll() {
        lock.lock()
        let keys = heldKeys
        heldKeys.removeAll()
        lock.unlock()
        keys.forEach { send(keyMessage($0, false)) }
    }

    /// ATEN: in-band power message. VNC hosts: Redfish, with the host's
    /// web credentials. Errors are reported through `onStatus`.
    public func sendPower(_ action: PowerAction) {
        switch kind {
        case .aten:
            send(ATENMessages.power(action.rawValue))
        case .vnc:
            guard let rf = Redfish(host: host, user: user, password: password) else { return }
            Task { [self] in
                do {
                    try await rf.reset(action)
                    log?("redfish power \(action) accepted")
                } catch {
                    status("power: \(error)")
                }
            }
        }
    }

    // MARK: helpers

    func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
    func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
}

func hex<S: Sequence>(_ b: S) -> String where S.Element == UInt8 {
    b.map { String(format: "%02x", $0) }.joined(separator: " ")
}
