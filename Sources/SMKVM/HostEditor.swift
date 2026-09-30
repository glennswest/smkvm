import AppKit
import SMKVMCore

/// Sheet for adding or editing a host.
final class HostEditor: NSWindowController {
    /// Credentials from the last Add/Save this run, offered for the next new host.
    nonisolated(unsafe) static var lastSaved: (user: String, password: String)?

    private let nameField = NSTextField()
    private let addressField = NSTextField()
    private let userField = NSTextField()
    private let passField = NSSecureTextField()
    private let typePopup = NSPopUpButton()
    private let portField = NSTextField()
    private var host: Host
    private let done: (Host?) -> Void

    init(host: Host?, done: @escaping (Host?) -> Void) {
        self.host = host ?? Host(name: "", address: "", user: "ADMIN")
        self.done = done
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: w)
        build(isNew: host == nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build(isNew: Bool) {
        nameField.placeholderString = "server1"
        addressField.placeholderString = "192.168.11.10"
        nameField.stringValue = host.name
        addressField.stringValue = host.address
        userField.stringValue = host.user
        typePopup.addItems(withTitles: ["Supermicro (ATEN iKVM)", "VNC (Dell iDRAC, others)"])
        typePopup.selectItem(at: host.type == "vnc" ? 1 : 0)
        typePopup.target = self
        typePopup.action = #selector(typeChanged)
        portField.stringValue = String(host.vncPort)
        portField.isEnabled = host.type == "vnc"
        if !isNew {
            passField.stringValue = PasswordStore.password(host: host.address, user: host.user) ?? ""
        } else if let last = HostEditor.lastSaved {
            // BMCs in one rack usually share credentials; start from the last ones.
            userField.stringValue = last.user
            passField.stringValue = last.password
        }

        let save = NSButton(title: isNew ? "Add" : "Save", target: self, action: #selector(ok))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(dismiss))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, save])

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "BMC address:"), addressField],
            [NSTextField(labelWithString: "User:"), userField],
            [NSTextField(labelWithString: "Password:"), passField],
            [NSTextField(labelWithString: "Console:"), typePopup],
            [NSTextField(labelWithString: "VNC port:"), portField],
            [NSGridCell.emptyContentView, buttons],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 230
        grid.rowSpacing = 8
        grid.cell(for: buttons)?.xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = window!.contentView!
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    @objc private func typeChanged() {
        portField.isEnabled = typePopup.indexOfSelectedItem == 1
    }

    @objc private func ok() {
        let address = addressField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty, !user.isEmpty else { NSSound.beep(); return }
        host.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        host.address = address
        host.user = user
        host.type = typePopup.indexOfSelectedItem == 1 ? "vnc" : "aten"
        host.vncPort = Int(portField.stringValue) ?? 5901
        PasswordStore.save(host: address, user: user, password: passField.stringValue)
        HostEditor.lastSaved = (user, passField.stringValue)
        finish(host)
    }

    @objc private func dismiss() { finish(nil) }

    private func finish(_ h: Host?) {
        if let w = window, let parent = w.sheetParent { parent.endSheet(w) }
        done(h)
    }
}
