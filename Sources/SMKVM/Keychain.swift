import Foundation
import Security

/// Stores BMC passwords in the login keychain, one generic-password item per
/// host+user.
enum Keychain {
    private static let service = "smkvm.bmc"

    static func password(host: String, user: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(user)@\(host)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Updates the item in place when it exists (keeping its access list, so
    /// no new prompt), otherwise creates it — owned by this app, which can
    /// then read it without asking.
    static func save(host: String, user: String, password: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(user)@\(host)",
        ]
        let data = Data(password.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "SMKVM — \(user)@\(host)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
