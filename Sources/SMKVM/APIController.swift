import AppKit
import SMKVMCore

/// The network API: lets a remote agent (or a browser) watch a console and
/// send keyboard/mouse input. No power control (owner decision). Every /api
/// request needs the bearer token (APIToken). All access goes through the
/// app's real console windows, so what the API does is visible on screen.
///
/// See docs/api.md for the endpoint reference.
@MainActor
final class APIController {
    private weak var app: AppDelegate?
    private var server: HTTPServer?
    let token: String
    let port: UInt16
    private(set) var state = "stopped"

    init(app: AppDelegate, port: UInt16) {
        self.app = app
        self.port = port
        self.token = APIToken.load()
    }

    func start() {
        let token = self.token
        do {
            let server = try HTTPServer(port: port) { [weak self] req, respond in
                // The page itself needs no token; it asks for one.
                if req.method == "GET" && (req.path == "/" || req.path == "/index.html") {
                    respond(HTTPResponse(contentType: "text/html; charset=utf-8", body: Data(WebUI.html.utf8)))
                    return
                }
                guard APIToken.matches(APIToken.presented(by: req), token) else {
                    respond(.error("missing or wrong token (Authorization: Bearer <token> or ?token=)", status: 401))
                    return
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { respond(.error("shutting down", status: 503)); return }
                        self.route(req, respond)
                    }
                }
            }
            server.start { [weak self] s in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.state = s } }
            }
            self.server = server
        } catch {
            state = "failed: \(error)"
        }
    }

    // MARK: routing

    private func route(_ req: HTTPRequest, _ respond: @escaping @Sendable (HTTPResponse) -> Void) {
        let parts = req.path.split(separator: "/").map(String.init)   // ["api", "hosts", name, action, …]
        guard parts.first == "api" else { respond(.error("not found", status: 404)); return }
        if parts.count == 1 { respond(.json(Self.reference)); return }
        guard parts[1] == "hosts" else { respond(.error("not found", status: 404)); return }
        if parts.count == 2 { respond(.json(hostList())); return }

        guard let host = findHost(parts[2]) else {
            respond(.error("no host '\(parts[2])' (see GET /api/hosts)", status: 404)); return
        }
        let action = parts.count > 3 ? parts[3] : ""
        let console = app?.console(for: host)

        switch (req.method, action) {
        case ("GET", ""), ("GET", "status"):
            respond(.json(describe(host, console)))
        case ("POST", "connect"):
            respond(.json(describe(host, app?.openConsole(host))))
        case ("POST", "disconnect"):
            console?.close()
            respond(.json(["host": host.title, "open": false]))
        case ("GET", "screens"):
            respond(listScreens(host, req, rest: Array(parts.dropFirst(4))))
        default:
            guard let console else {
                respond(.error("console for '\(host.title)' is not open; POST /api/hosts/\(host.title)/connect", status: 409))
                return
            }
            consoleAction(req, action, host, console, respond)
        }
    }

    private func consoleAction(_ req: HTTPRequest, _ action: String, _ host: Host, _ console: ConsoleWindowController,
                               _ respond: @escaping @Sendable (HTTPResponse) -> Void) {
        let client = console.client
        let body = req.json
        switch (req.method, action) {
        case ("GET", "screen.png"), ("GET", "screen.jpg"):
            let wait = Double(req.query["wait_change"] ?? "") ?? 0
            let after = Int(req.query["after"] ?? "")
            let png = action == "screen.png"
            let quality = Double(req.query["quality"] ?? "") ?? 0.8
            DispatchQueue.global(qos: .userInitiated).async {
                let (_, frame, _) = Self.frame(client, wait: wait, after: after)
                guard let frame, let data = png ? frame.pngData() : frame.jpegData(quality: quality) else {
                    respond(.error("no picture yet: \(client.currentStatus)", status: 503)); return
                }
                respond(HTTPResponse(contentType: png ? "image/png" : "image/jpeg", body: data))
            }
        case ("GET", "frame"):
            // Cheap poll: sequence number and whether it changed since ?after=.
            let wait = Double(req.query["wait_change"] ?? "") ?? 0
            let after = Int(req.query["after"] ?? "")
            DispatchQueue.global(qos: .userInitiated).async {
                let (seq, frame, changed) = Self.frame(client, wait: wait, after: after)
                respond(.json(["seq": seq, "changed": changed, "width": frame?.width ?? 0,
                               "height": frame?.height ?? 0, "status": client.currentStatus]))
            }
        case ("GET", "stream.mjpg"):
            let fps = min(max(Double(req.query["fps"] ?? "") ?? 10, 1), 30)
            let quality = Double(req.query["quality"] ?? "") ?? 0.6
            respond(.streaming(contentType: "multipart/x-mixed-replace; boundary=smkvmframe") { write in
                var lastSeq = -1
                var lastSent = Date.distantPast
                while client.isActive {
                    let (seq, frame) = client.currentFrame
                    if let frame, seq != lastSeq || Date().timeIntervalSince(lastSent) > 2,
                       let jpg = frame.jpegData(quality: quality) {
                        var part = Data("--smkvmframe\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpg.count)\r\n\r\n".utf8)
                        part += jpg + Data("\r\n".utf8)
                        guard write(part) else { return }
                        lastSeq = seq
                        lastSent = Date()
                    }
                    Thread.sleep(forTimeInterval: 1 / fps)
                }
            })
        case ("POST", "type"):
            guard let text = body["text"] as? String else { respond(.error("need {\"text\": \"…\"}")); return }
            let delay = (body["delay_ms"] as? Double ?? 15) / 1000
            let (strokes, bad) = TextKeys.strokes(for: text)
            DispatchQueue.global(qos: .userInitiated).async {
                for s in strokes {
                    if s.shift { client.sendHID(KeyMap.leftShift, down: true) }
                    client.sendHID(s.hid, down: true)
                    client.sendHID(s.hid, down: false)
                    if s.shift { client.sendHID(KeyMap.leftShift, down: false) }
                    Thread.sleep(forTimeInterval: delay)
                }
                respond(.json(["typed": strokes.count, "skipped": bad.map(String.init)]))
            }
        case ("POST", "key"):
            let specs: [String]
            if let one = body["keys"] as? String { specs = [one] }
            else if let many = body["keys"] as? [String] { specs = many }
            else { respond(.error("need {\"keys\": \"ctrl+alt+delete\"} or {\"keys\": [\"esc\", \"enter\"]}")); return }
            var chords: [[UInt8]] = []
            for spec in specs {
                guard let c = TextKeys.chord(spec) else { respond(.error("unknown key in '\(spec)'")); return }
                chords.append(c)
            }
            let hold = (body["hold_ms"] as? Double ?? 40) / 1000
            let gap = (body["delay_ms"] as? Double ?? 40) / 1000
            DispatchQueue.global(qos: .userInitiated).async {
                for c in chords {
                    c.forEach { client.sendHID($0, down: true) }
                    Thread.sleep(forTimeInterval: hold)
                    c.reversed().forEach { client.sendHID($0, down: false) }
                    Thread.sleep(forTimeInterval: gap)
                }
                respond(.json(["sent": specs]))
            }
        case ("POST", "mouse"):
            guard let x = body["x"] as? Double, let y = body["y"] as? Double else {
                respond(.error("need {\"x\": …, \"y\": …, \"action\": \"click|double|move|down|up\", \"button\": \"left|right|middle\"}"))
                return
            }
            let mask: UInt8 = ["right": 4, "middle": 2][body["button"] as? String ?? "left"] ?? 1
            let actionName = body["action"] as? String ?? "click"
            let ix = Int(x), iy = Int(y)
            DispatchQueue.global(qos: .userInitiated).async {
                switch actionName {
                case "move": client.sendPointer(x: ix, y: iy, buttons: 0)
                case "down": client.sendPointer(x: ix, y: iy, buttons: mask)
                case "up": client.sendPointer(x: ix, y: iy, buttons: 0)
                default:
                    let times = actionName == "double" ? 2 : 1
                    client.sendPointer(x: ix, y: iy, buttons: 0)
                    for _ in 0..<times {
                        Thread.sleep(forTimeInterval: 0.03)
                        client.sendPointer(x: ix, y: iy, buttons: mask)
                        Thread.sleep(forTimeInterval: 0.05)
                        client.sendPointer(x: ix, y: iy, buttons: 0)
                    }
                }
                respond(.json(["x": ix, "y": iy, "action": actionName]))
            }
        case ("POST", "screenlog"):
            let on = body["enabled"] as? Bool ?? true
            console.setScreenLog(on)
            respond(.json(["host": host.title, "logScreens": on]))
        default:
            respond(.error("unknown endpoint \(req.method) \(req.path) (see GET /api)", status: 404))
        }
    }

    /// Latest frame, optionally waiting (≤ `wait` s) for a visible change —
    /// relative to the frame at call time, or to sequence `after`.
    nonisolated private static func frame(_ client: KVMClient, wait: Double, after: Int?)
        -> (seq: Int, frame: FrameSnapshot?, changed: Bool) {
        let start = client.currentFrame
        guard wait > 0 else {
            return (start.seq, start.frame, after.map { start.seq != $0 } ?? false)
        }
        if let after, start.seq != after { return (start.seq, start.frame, true) }
        let deadline = Date().addingTimeInterval(min(wait, 120))
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            let now = client.currentFrame
            guard now.seq != start.seq, let f = now.frame else { continue }
            if let base = start.frame, ScreenLogger.nearlyIdentical(base, f) { continue }
            return (now.seq, f, true)
        }
        let now = client.currentFrame
        return (now.seq, now.frame, false)
    }

    // MARK: hosts

    private func findHost(_ key: String) -> Host? {
        let k = key.lowercased()
        return HostStore.shared.hosts.first {
            $0.title.lowercased() == k || $0.address.lowercased() == k || $0.name.lowercased() == k
        }
    }

    private func hostList() -> [[String: Any]] {
        HostStore.shared.hosts.map { describe($0, app?.console(for: $0)) }
    }

    private func describe(_ h: Host, _ c: ConsoleWindowController?) -> [String: Any] {
        var d: [String: Any] = ["name": h.title, "address": h.address,
                                "console": h.type == "vnc" ? "vnc:\(h.vncPort)" : "supermicro",
                                "logScreens": h.logScreens, "open": c != nil]
        if let c {
            let (seq, f) = c.client.currentFrame
            d["status"] = c.client.currentStatus
            d["seq"] = seq
            d["width"] = f?.width ?? 0
            d["height"] = f?.height ?? 0
        }
        return d
    }

    private func listScreens(_ host: Host, _ req: HTTPRequest, rest: [String]) -> HTTPResponse {
        let dir = host.screenLogDirectory
        if rest.count == 2 {
            // One file: /api/hosts/<h>/screens/<date>/<file>.png
            guard !rest.contains(where: { $0.contains("..") || $0.contains("/") }), rest[1].hasSuffix(".png"),
                  let data = try? Data(contentsOf: dir.appendingPathComponent(rest[0]).appendingPathComponent(rest[1]))
            else { return .error("no such screenshot", status: 404) }
            return HTTPResponse(contentType: "image/png", body: data)
        }
        let limit = Int(req.query["limit"] ?? "") ?? 50
        let fm = FileManager.default
        let days = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted(by: >)
        var items: [[String: String]] = []
        outer: for day in days {
            let files = ((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(day).path)) ?? [])
                .filter { $0.hasSuffix(".png") }.sorted(by: >)
            for f in files {
                let reason = f.split(separator: "-", maxSplits: 1).last.map { String($0.dropLast(4)) } ?? ""
                items.append(["date": day, "file": f, "reason": reason,
                              "url": "/api/hosts/\(host.title)/screens/\(day)/\(f)"])
                if items.count >= limit { break outer }
            }
        }
        return .json(["host": host.title, "screens": items])
    }

    static let reference: [String: Any] = [
        "auth": "Authorization: Bearer <token>, or ?token=<token>",
        "endpoints": [
            "GET  /api/hosts": "all hosts with console state",
            "GET  /api/hosts/{h}": "one host: open, status, seq, width, height",
            "POST /api/hosts/{h}/connect": "open the console (a tab in the app)",
            "POST /api/hosts/{h}/disconnect": "close the console",
            "GET  /api/hosts/{h}/screen.png": "current screen; ?wait_change=S waits up to S s for a visible change; ?after=SEQ returns once past SEQ",
            "GET  /api/hosts/{h}/screen.jpg": "same as JPEG; ?quality=0..1",
            "GET  /api/hosts/{h}/frame": "{seq, changed, width, height, status}; same wait_change/after",
            "GET  /api/hosts/{h}/stream.mjpg": "live MJPEG; ?fps=1..30&quality=0..1",
            "POST /api/hosts/{h}/type": "{\"text\": \"ls -l\\n\", \"delay_ms\": 15} — US layout; \\n = Enter",
            "POST /api/hosts/{h}/key": "{\"keys\": \"ctrl+alt+delete\"} or {\"keys\": [\"esc\",\"down\",\"enter\"]}; hold_ms, delay_ms",
            "POST /api/hosts/{h}/mouse": "{\"x\":100,\"y\":200,\"action\":\"click|double|move|down|up\",\"button\":\"left|right|middle\"} — framebuffer pixels",
            "POST /api/hosts/{h}/screenlog": "{\"enabled\": true}",
            "GET  /api/hosts/{h}/screens": "logged screenshots, newest first; ?limit=N",
            "GET  /api/hosts/{h}/screens/{date}/{file}": "one logged screenshot",
        ],
        "keys": "names: enter esc tab backspace space delete insert home end pgup pgdn up down left right f1..f24 printscreen scrolllock pause numlock capslock menu ctrl shift alt win rctrl rshift ralt rwin; or any single character",
    ]
}
