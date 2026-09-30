import Foundation

/// A saved BMC. The password lives in the Keychain, keyed by host+user.
struct Host: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var address: String
    var user: String

    var title: String { name.isEmpty ? address : name }
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
