import AppKit
import SMKVMCore

/// One console window bound to one KVM session.
final class ConsoleWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private(set) var host: Host
    private var status = "connecting…"
    private var screensLogged = 0
    private let client: KVMClient
    private let view = ConsoleView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
    private var sized = false

    init(host: Host, password: String) {
        self.host = host
        self.client = KVMClient(host: host.address, user: host.user, password: password,
                                kind: host.consoleKind)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "\(host.title) — connecting…"
        w.tabbingMode = .preferred
        w.tabbingIdentifier = "console"
        w.contentView = view
        w.contentMinSize = NSSize(width: 320, height: 240)
        super.init(window: w)
        w.delegate = self
        w.center()
        wire()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func wire() {
        view.onKey = { [client] code, down in client.sendKey(macKeyCode: code, down: down) }
        view.onPointer = { [client] x, y, b in client.sendPointer(x: x, y: y, buttons: b) }
        client.onFrame = { [weak self] fb in self?.frame(fb) }
        client.onStatus = { [weak self] s in
            self?.status = s
            self?.updateTitle()
        }
        applyScreenLog()
    }

    private func updateTitle() {
        var t = "\(host.title) — \(status)"
        if host.logScreens { t += " · \(screensLogged) screen\(screensLogged == 1 ? "" : "s") logged" }
        window?.title = t
    }

    var logScreens: Bool { host.logScreens }

    func toggleScreenLog() {
        host.logScreens.toggle()
        // Keep the saved host (and any edits made meanwhile) in step.
        if var saved = HostStore.shared.host(host.id) {
            saved.logScreens = host.logScreens
            HostStore.shared.upsert(saved)
        }
        applyScreenLog()
    }

    private func applyScreenLog() {
        guard host.logScreens else {
            client.screenLogger = nil
            updateTitle()
            return
        }
        let logger = ScreenLogger(directory: host.screenLogDirectory)
        logger.onSaved = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.screensLogged += 1
                    self.updateTitle()
                }
            }
        }
        client.screenLogger = logger
        updateTitle()
    }

    func showScreenLog() {
        let dir = host.screenLogDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func start() {
        window?.makeFirstResponder(view)
        client.start()
    }

    func sendCtrlAltDel() { client.sendCtrlAltDel() }

    func sendKey(_ hid: UInt8) { client.sendChord([hid]) }

    /// Power actions other than "on" ask first — they hit a live machine.
    func power(_ action: PowerAction, title: String) {
        guard let window else { return }
        if action == .on { client.sendPower(action); return }
        let alert = NSAlert()
        alert.messageText = "\(title) \(host.title)?"
        alert.informativeText = "This acts on the server immediately, like pressing its power or reset button."
        alert.alertStyle = .warning
        alert.addButton(withTitle: title)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [client] r in
            if r == .alertFirstButtonReturn { client.sendPower(action) }
        }
    }

    func windowDidResignKey(_ note: Notification) {
        // Don't leave keys stuck down on the host when focus moves away.
        client.releaseAll()
    }

    private func frame(_ fb: FrameSnapshot) {
        view.show(fb)
        // First frame (and resolution changes): size the window to 1:1 if it fits.
        let size = NSSize(width: fb.width, height: fb.height)
        guard let window, fb.width > 0,
              !sized || window.contentAspectRatio != size else { return }
        sized = true
        window.contentAspectRatio = size
        let screen = window.screen?.visibleFrame.size ?? size
        let s = min(1, (screen.width - 40) / size.width, (screen.height - 60) / size.height)
        window.setContentSize(NSSize(width: size.width * s, height: size.height * s))
    }

    func windowWillClose(_ note: Notification) {
        client.stop()
        onClose?()
    }
}
