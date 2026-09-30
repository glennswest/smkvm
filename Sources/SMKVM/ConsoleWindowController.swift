import AppKit
import SMKVMCore

/// One console window bound to one KVM session.
final class ConsoleWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let host: String
    private let client: KVMClient
    private let view = ConsoleView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
    private var sized = false

    init(host: String, user: String, password: String) {
        self.host = host
        self.client = KVMClient(host: host, user: user, password: password)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "\(host) — connecting…"
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
            guard let self else { return }
            self.window?.title = "\(self.host) — \(s)"
        }
    }

    func start() {
        window?.makeFirstResponder(view)
        client.start()
    }

    func sendCtrlAltDel() { client.sendCtrlAltDel() }

    private func frame(_ fb: Framebuffer) {
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
