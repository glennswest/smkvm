import Foundation

/// Minimal Redfish client for power control on BMCs whose console protocol
/// has no power message (e.g. Dell iDRAC over VNC).
public final class Redfish: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let base: URL
    private let auth: String
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    public init?(host: String, user: String, password: String) {
        guard let u = URL(string: "https://\(host)") else { return nil }
        base = u
        auth = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    /// BMC certificates are self-signed.
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)
        req.httpMethod = method
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// The first system's path, e.g. /redfish/v1/Systems/System.Embedded.1.
    private func systemPath() async throws -> String {
        let (code, data) = try await call("GET", "/redfish/v1/Systems")
        guard code == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let members = obj["Members"] as? [[String: Any]],
              let path = members.first?["@odata.id"] as? String
        else { throw RedfishError.http(code, "no systems") }
        return path
    }

    public func reset(_ action: PowerAction) async throws {
        let type: String
        switch action {
        case .on: type = "On"
        case .off: type = "ForceOff"
        case .reset: type = "ForceRestart"
        case .softOff: type = "GracefulShutdown"
        }
        let sys = try await systemPath()
        let (code, data) = try await call("POST", "\(sys)/Actions/ComputerSystem.Reset", body: ["ResetType": type])
        guard (200..<300).contains(code) else {
            throw RedfishError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }
}

public enum RedfishError: Error, CustomStringConvertible {
    case http(Int, String)
    public var description: String {
        switch self { case .http(let c, let s): return "Redfish HTTP \(c): \(s)" }
    }
}
