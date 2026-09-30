import Foundation
import Network

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String            // without the query string
    public let query: [String: String]
    public let headers: [String: String]   // lower-cased names
    public let body: Data

    /// The body decoded as a JSON object ([:] when absent or not an object).
    public var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    /// Streaming response (no Content-Length): called once with a writer
    /// that returns false after the client has gone away.
    public var stream: (@Sendable (_ write: @escaping @Sendable (Data) -> Bool) -> Void)?

    public static func streaming(contentType: String,
                                 _ body: @escaping @Sendable (_ write: @escaping @Sendable (Data) -> Bool) -> Void) -> HTTPResponse {
        var r = HTTPResponse(contentType: contentType, body: Data())
        r.stream = body
        return r
    }

    public init(status: Int = 200, contentType: String = "application/json", body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data + Data("\n".utf8))
    }

    public static func error(_ message: String, status: Int = 400) -> HTTPResponse {
        json(["error": message], status: status)
    }
}

/// A small HTTP/1.1 server (one request per connection). Binds to all
/// interfaces by default; pass `bindAddress: "127.0.0.1"` for loopback only.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest, @escaping @Sendable (HTTPResponse) -> Void) -> Void

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "smkvm.http")

    public init(port: UInt16, bindAddress: String? = nil, handler: @escaping Handler) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let p = NWEndpoint.Port(rawValue: port)!
        if let bindAddress {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: p)
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: p)
        }
        self.handler = handler
    }

    public func start(onState: (@Sendable (String) -> Void)? = nil) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onState?("ready")
            case .failed(let e): onState?("failed: \(e)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
    }

    public func stop() { listener.cancel() }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, Data())
    }

    private func receive(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.handler(req) { resp in self.send(conn, resp) }
            } else if done || err != nil || buf.count > 16 << 20 {
                conn.cancel()
            } else {
                self.receive(conn, buf)
            }
        }
    }

    /// A complete request, or nil if more bytes are needed.
    static func parse(_ buf: Data) -> HTTPRequest? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard buf.count - bodyStart >= length else { return nil }
        let target = String(parts[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(parts[0]), path: comps?.percentEncodedPath.removingPercentEncoding ?? target,
                           query: query, headers: headers, body: buf[bodyStart..<bodyStart + length])
    }

    private func send(_ conn: NWConnection, _ r: HTTPResponse) {
        if let stream = r.stream {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: \(r.contentType)\r\nCache-Control: no-store\r\n"
                + "Connection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            let alive = LockedFlag(true)
            conn.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled: alive.set(false)
                default: break
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                stream { data in
                    guard alive.get() else { return false }
                    // Back-pressure: wait for each chunk to be handed to TCP.
                    let sent = DispatchSemaphore(value: 0)
                    conn.send(content: data, completion: .contentProcessed { err in
                        if err != nil { alive.set(false) }
                        sent.signal()
                    })
                    if sent.wait(timeout: .now() + 10) == .timedOut { alive.set(false) }
                    return alive.get()
                }
                conn.cancel()
            }
            return
        }
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 404: "Not Found", 409: "Conflict",
                      500: "Internal Server Error", 503: "Service Unavailable"][r.status] ?? "Status"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\n"
        head += "Content-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        conn.send(content: Data(head.utf8) + r.body, completion: .contentProcessed { _ in conn.cancel() })
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ v: Bool) { value = v }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}
