import Foundation
import SMKVMCore

/// A saved BMC. The password lives in PasswordStore, keyed by user@host.
struct Host: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var address: String
    var user: String
    /// Save a PNG of the screen each time it is cleared (ScreenLogger).
    var logScreens = false
    /// "aten" (Supermicro iKVM) or "vnc" (standard VNC, e.g. Dell iDRAC).
    var type = "aten"
    /// VNC server port (iDRAC's built-in VNC server defaults to 5901).
    var vncPort = 5901

    var consoleKind: ConsoleKind { type == "vnc" ? .vnc(port: vncPort) : .aten }

    var title: String { name.isEmpty ? address : name }

    /// ~/Pictures/SMKVM/<host>/
    var screenLogDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        let safe = title.replacingOccurrences(of: "/", with: "_")
        return pictures.appendingPathComponent("SMKVM", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
    }

    init(name: String, address: String, user: String) {
        self.name = name
        self.address = address
        self.user = user
    }

    // Hosts saved before a field existed decode with its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decode(String.self, forKey: .address)
        user = try c.decode(String.self, forKey: .user)
        logScreens = try c.decodeIfPresent(Bool.self, forKey: .logScreens) ?? false
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "aten"
        vncPort = try c.decodeIfPresent(Int.self, forKey: .vncPort) ?? 5901
    }
}

/// The saved host list, persisted in UserDefaults.
@MainActor
final class HostStore {
    static let shared = HostStore()
    static let changed = Notification.Name("HostStoreChanged")
    private static let key = "hosts"

    private(set) var hosts: [Host] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([Host].self, from: data) {
            hosts = list
        }
    }

    func upsert(_ h: Host) {
        if let i = hosts.firstIndex(where: { $0.id == h.id }) { hosts[i] = h } else { hosts.append(h) }
        hosts.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        save()
    }

    func host(_ id: UUID) -> Host? { hosts.first { $0.id == id } }

    func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
