import Foundation
#if canImport(Darwin)
import Darwin
#endif

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

/// A small HTTP/1.1 server (one request per connection) on plain BSD
/// sockets. Binds to all interfaces by default; pass `bindAddress:
/// "127.0.0.1"` for loopback only.
///
/// (An NWListener version stalled ~2 s per 15 KB response to remote
/// clients — Network.framework's own TCP stack — while the kernel stack is
/// instant, so this uses the kernel directly.)
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest, @escaping @Sendable (HTTPResponse) -> Void) -> Void

    private let fd: Int32
    private let handler: Handler
    private let stopped = LockedFlag(false)

    public init(port: UInt16, bindAddress: String? = nil, handler: @escaping Handler) throws {
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw SocketError.io(String(cString: strerror(errno))) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = bindAddress.map { inet_addr($0) } ?? INADDR_ANY
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok, Darwin.listen(s, 64) == 0 else {
            let e = String(cString: strerror(errno))
            Darwin.close(s)
            throw SocketError.io("port \(port): \(e)")
        }
        fd = s
        self.handler = handler
    }

    public func start(onState: (@Sendable (String) -> Void)? = nil) {
        onState?("ready")
        let t = Thread { [self] in acceptLoop() }
        t.name = "smkvm http"
        t.start()
    }

    public func stop() {
        stopped.set(true)
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private func acceptLoop() {
        while !stopped.get() {
            let c = Darwin.accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return
            }
            var one: Int32 = 1
            setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(c) }
        }
    }

    private func serve(_ c: Int32) {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var req: HTTPRequest?
        while req == nil {
            let n = recv(c, &chunk, chunk.count, 0)
            if n <= 0 || buf.count > 16 << 20 { Darwin.close(c); return }
            buf.append(contentsOf: chunk[0..<n])
            req = Self.parse(buf)
        }
        handler(req!) { resp in
            DispatchQueue.global(qos: .userInitiated).async { Self.respond(c, resp) }
        }
    }

    private static func write(_ c: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = send(c, p.baseAddress! + off, p.count - off, 0)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    private static func respond(_ c: Int32, _ r: HTTPResponse) {
        defer {
            Darwin.shutdown(c, SHUT_WR)
            Darwin.close(c)
        }
        if let stream = r.stream {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: \(r.contentType)\r\nCache-Control: no-store\r\n"
                + "Connection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
            guard write(c, Data(head.utf8)) else { return }
            stream { data in write(c, data) }
            return
        }
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                      409: "Conflict", 500: "Internal Server Error", 503: "Service Unavailable"][r.status] ?? "Status"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\n"
        head += "Content-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        _ = write(c, Data(head.utf8) + r.body)
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
                           query: query, headers: headers, body: Data(buf[bodyStart..<bodyStart + length]))
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ v: Bool) { value = v }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}
