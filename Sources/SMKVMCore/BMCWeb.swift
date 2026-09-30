import Foundation

public enum BMCWebError: Error, CustomStringConvertible {
    case unreachable(String)
    case loginFailed
    case noJNLP(String)
    case badJNLP(String)

    public var description: String {
        switch self {
        case .unreachable(let s): return "BMC web UI unreachable: \(s)"
        case .loginFailed: return "login failed — check user and password"
        case .noJNLP(let s): return "BMC did not return a KVM launch file (\(s)); is the console in HTML5 mode?"
        case .badJNLP(let s): return "unexpected KVM launch file: \(s)"
        }
    }
}

/// What the Java applet would have been started with: where the KVM service
/// is and the single-use RFB credentials.
public struct KVMTicket: Sendable {
    public var port: Int
    public var user: String
    public var password: String
    /// Later X9 firmware wraps the RFB port in mutual TLS (stunnel).
    public var tls: Bool
    public var arguments: [String]
}

/// The BMC's web UI: login.cgi → SID cookie, the jwsk JNLP → KVMTicket,
/// logout.cgi. Synchronous; call from a background thread.
public final class BMCWeb: NSObject, URLSessionDelegate, @unchecked Sendable {
    public let host: String
    private var base: URL?
    private var sid: String?
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 10
        // Old BMCs only speak TLS 1.0.
        c.tlsMinimumSupportedProtocolVersion = .TLSv10
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    public init(host: String) {
        self.host = host
    }

    /// BMCs use self-signed certificates; the credential exchange is
    /// equivalent to what the vendor's Java launcher accepts.
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func request(_ req: URLRequest) throws -> (HTTPURLResponse, Data) {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(HTTPURLResponse, Data), Error> = .failure(BMCWebError.unreachable("no response"))
        session.dataTask(with: req) { data, resp, err in
            if let err {
                result = .failure(err)
            } else if let http = resp as? HTTPURLResponse {
                result = .success((http, data ?? Data()))
            }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }

    private func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    public func login(user: String, password: String) throws {
        var lastError: Error = BMCWebError.unreachable(host)
        for scheme in ["http", "https"] {
            guard let b = URL(string: "\(scheme)://\(host)") else { continue }
            var req = URLRequest(url: b.appendingPathComponent("cgi/login.cgi"))
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("name=\(urlEncode(user))&pwd=\(urlEncode(password))".utf8)
            let resp: HTTPURLResponse, data: Data
            do {
                (resp, data) = try request(req)
            } catch {
                lastError = BMCWebError.unreachable(error.localizedDescription)
                continue
            }
            let body = String(decoding: data, as: UTF8.self)
            let sid = Self.sid(from: resp)
            if let sid, !body.contains("login_alert"), resp.statusCode == 200 {
                // Redirects (http→https) change the effective base.
                if let u = resp.url, let s = u.scheme, let h = u.host {
                    base = URL(string: "\(s)://\(h)\(u.port.map { ":\($0)" } ?? "")")
                } else {
                    base = b
                }
                self.sid = sid
                return
            }
            lastError = BMCWebError.loginFailed
            if resp.statusCode == 200 { break }   // reached the BMC; credentials were refused
        }
        throw lastError
    }

    /// The SID cookie with a value (some firmware first sends a clearing `SID=`).
    static func sid(from resp: HTTPURLResponse) -> String? {
        var fields: [String: String] = [:]
        for (k, v) in resp.allHeaderFields {
            if let k = k as? String, let v = v as? String { fields[k] = v }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields,
                                         for: resp.url ?? URL(string: "http://bmc")!)
        return cookies.last { $0.name == "SID" && !$0.value.isEmpty }?.value
    }

    private func get(_ path: String) throws -> (HTTPURLResponse, Data) {
        guard let base, let sid else { throw BMCWebError.loginFailed }
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)
        req.setValue("SID=\(sid); langSetFlag=0; language=English", forHTTPHeaderField: "Cookie")
        req.setValue(base.absoluteString + "/cgi/url_redirect.cgi?url_name=man_ikvm",
                     forHTTPHeaderField: "Referer")
        return try request(req)
    }

    /// Fetches the JNLP, which mints fresh single-use RFB credentials.
    public func fetchTicket() throws -> KVMTicket {
        var last = "no response"
        for attempt in 0..<2 {
            for name in ["ikvm", "man_ikvm"] {
                let (resp, data) = try get("/cgi/url_redirect.cgi?url_name=\(name)&url_type=jwsk")
                let body = String(decoding: data, as: UTF8.self)
                if body.contains("<jnlp") { return try Self.parseJNLP(body, host: host) }
                last = "HTTP \(resp.statusCode)"
            }
            // The session may not be ready straight after login.
            if attempt == 0 { Thread.sleep(forTimeInterval: 1) }
        }
        throw BMCWebError.noJNLP(last)
    }

    static func parseJNLP(_ xml: String, host: String) throws -> KVMTicket {
        let re = try NSRegularExpression(pattern: "<argument>(.*?)</argument>", options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        let args = re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map {
            unescape(ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Some firmware prepends arguments; anchor on the host argument when present.
        let i = args.firstIndex(of: host) ?? 0
        guard args.count >= i + 3 else { throw BMCWebError.badJNLP("\(args.count) arguments") }
        func arg(_ k: Int) -> String? { i + k < args.count ? args[i + k] : nil }
        let tls = arg(8) == "1"
        var port = 5900
        if tls, let p = arg(9).flatMap(Int.init), p > 0 {
            port = p
        } else if let p = arg(4).flatMap(Int.init), p > 0, p < 65536 {
            port = p
        }
        return KVMTicket(port: port, user: args[i + 1], password: args[i + 2], tls: tls, arguments: args)
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Ends the web session. Only after the KVM session ends: a web logout
    /// kicks the KVM session.
    public func logout() {
        guard sid != nil else { return }
        _ = try? get("/cgi/logout.cgi")
        sid = nil
    }
}
