import Foundation
import Security

/// The web API's bearer token: 32 random bytes, hex, kept in
/// `~/Library/Application Support/SMKVM/api-token` (mode 0600) and created
/// on first use.
public enum APIToken {
    public static var file: URL {
        PasswordStore.file.deletingLastPathComponent().appendingPathComponent("api-token")
    }

    public static func load() -> String {
        if let s = try? String(contentsOf: file, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 32 { return t }
        }
        return regenerate()
    }

    @discardableResult
    public static func regenerate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: file.path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }

    /// Constant-time comparison.
    public static func matches(_ given: String?, _ token: String) -> Bool {
        guard let given else { return false }
        let a = Array(given.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// The token presented by a request: `Authorization: Bearer …` or `?token=`.
    public static func presented(by req: HTTPRequest) -> String? {
        if let h = req.headers["authorization"], h.lowercased().hasPrefix("bearer ") {
            return String(h.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return req.query["token"]
    }
}
