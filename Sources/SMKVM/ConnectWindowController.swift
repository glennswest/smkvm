import AppKit

/// Host / user / password form. Remembers recent hosts in UserDefaults and
/// passwords in the Keychain.
final class ConnectWindowController: NSWindowController, NSComboBoxDelegate {
    private let hostField = NSComboBox()
    private let userField = NSTextField()
    private let passField = NSSecureTextField()
    private let remember = NSButton(checkboxWithTitle: "Remember password in Keychain",
                                    target: nil, action: nil)
    private let onConnect: (String, String, String) -> Void

    private static let recentsKey = "recentHosts"   // [[host, user]]

    init(onConnect: @escaping (String, String, String) -> Void) {
        self.onConnect = onConnect
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Connect to BMC"
        super.init(window: w)
        build()
        w.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var recents: [[String]] {
        UserDefaults.standard.array(forKey: Self.recentsKey) as? [[String]] ?? []
    }

    private func build() {
        hostField.placeholderString = "192.168.11.10"
        hostField.addItems(withObjectValues: recents.map { $0[0] })
        hostField.delegate = self
        userField.placeholderString = "ADMIN"
        remember.state = .on

        let button = NSButton(title: "Connect", target: self, action: #selector(connect))
        button.keyEquivalent = "\r"

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Host:"), hostField],
            [NSTextField(labelWithString: "User:"), userField],
            [NSTextField(labelWithString: "Password:"), passField],
            [NSGridCell.emptyContentView, remember],
            [NSGridCell.emptyContentView, button],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 240
        grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = window!.contentView!
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        if let last = recents.first { fill(host: last[0], user: last[1]) }
    }

    private func fill(host: String, user: String) {
        hostField.stringValue = host
        userField.stringValue = user
        passField.stringValue = Keychain.password(host: host, user: user) ?? ""
    }

    func comboBoxSelectionDidChange(_ note: Notification) {
        let i = hostField.indexOfSelectedItem
        guard i >= 0, i < recents.count else { return }
        fill(host: recents[i][0], user: recents[i][1])
    }

    @objc private func connect() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let pass = passField.stringValue
        guard !host.isEmpty, !user.isEmpty else { NSSound.beep(); return }

        var r = recents.filter { $0[0] != host }
        r.insert([host, user], at: 0)
        UserDefaults.standard.set(Array(r.prefix(10)), forKey: Self.recentsKey)
        if remember.state == .on { Keychain.save(host: host, user: user, password: pass) }

        onConnect(host, user, pass)
    }
}
