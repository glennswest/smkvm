import Foundation

/// BMC passwords, kept in a plain JSON file readable only by the user:
/// `~/Library/Application Support/SMKVM/passwords.json` (mode 0600), keyed
/// "user@host". Deliberately not the Keychain — its per-item access prompts
/// were more friction than these lab BMC credentials warrant.
public enum PasswordStore {
    public static var file: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SMKVM", isDirectory: true)
            .appendingPathComponent("passwords.json")
    }

    private static let lock = NSLock()

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    public static func password(host: String, user: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()["\(user)@\(host)"]
    }

    public static func save(host: String, user: String, password: String) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        map["\(user)@\(host)"] = password
        write(map)
    }

    public static func remove(host: String, user: String) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        guard map.removeValue(forKey: "\(user)@\(host)") != nil else { return }
        write(map)
    }

    private static func write(_ map: [String: String]) {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(map) else { return }
        // Create with 0600 before any bytes land, then replace atomically.
        let tmp = dir.appendingPathComponent(".passwords.json.tmp")
        fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try? fm.replaceItemAt(file, withItemAt: tmp)
        if !fm.fileExists(atPath: file.path) { try? fm.moveItem(at: tmp, to: file) }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
