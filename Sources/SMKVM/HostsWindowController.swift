import AppKit

/// The host library: saved BMCs, add/edit/remove, connect.
final class HostsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let onConnect: (Host) -> Void
    private var editor: HostEditor?
    private var hosts: [Host] { HostStore.shared.hosts }

    init(onConnect: @escaping (Host) -> Void) {
        self.onConnect = onConnect
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Hosts"
        w.setFrameAutosaveName("Hosts")
        w.contentMinSize = NSSize(width: 360, height: 200)
        super.init(window: w)
        build()
        NotificationCenter.default.addObserver(forName: HostStore.changed, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.table.reloadData() }
        }
        if w.frame.origin == .zero { w.center() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        for (id, title, width) in [("name", "Name", 140.0), ("address", "BMC", 150.0), ("user", "User", 100.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.target = self
        table.doubleAction = #selector(connectSelected)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        let add = NSButton(title: "Add…", target: self, action: #selector(addHost))
        let edit = NSButton(title: "Edit…", target: self, action: #selector(editHost))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeHosts))
        let connect = NSButton(title: "Connect", target: self, action: #selector(connectSelected))
        connect.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [add, edit, remove, spacer, connect])

        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window!.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hosts.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let h = hosts[row]
        let text: String
        switch col?.identifier.rawValue {
        case "name": text = h.title
        case "address": text = h.address
        default: text = h.user
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    private var selected: [Host] {
        table.selectedRowIndexes.compactMap { $0 < hosts.count ? hosts[$0] : nil }
    }

    @objc private func connectSelected() {
        // Double-click on a row uses the clicked row; the button uses the selection.
        if table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
            onConnect(hosts[table.clickedRow]); return
        }
        let list = selected
        guard !list.isEmpty else { NSSound.beep(); return }
        list.forEach(onConnect)
    }

    @objc func addHost() { runEditor(nil) }

    @objc private func editHost() {
        guard let h = selected.first else { NSSound.beep(); return }
        runEditor(h)
    }

    @objc private func removeHosts() {
        selected.forEach { HostStore.shared.remove($0.id) }
    }

    private func runEditor(_ h: Host?) {
        let e = HostEditor(host: h) { [weak self] result in
            if let result { HostStore.shared.upsert(result) }
            self?.editor = nil
        }
        editor = e
        window?.beginSheet(e.window!)
    }
}
