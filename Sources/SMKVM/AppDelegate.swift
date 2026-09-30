import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hostsWindow: HostsWindowController?
    private var consoles: [ConsoleWindowController] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = makeMenu()
        showHosts(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showHosts(nil) }
        return true
    }

    @objc func showHosts(_ sender: Any?) {
        if hostsWindow == nil {
            hostsWindow = HostsWindowController { [weak self] host in self?.open(host) }
        }
        hostsWindow?.showWindow(nil)
    }

    @objc func addHost(_ sender: Any?) {
        showHosts(nil)
        hostsWindow?.addHost()
    }

    /// Opens a console for `host`, or brings its existing console forward.
    private func open(_ host: Host) {
        if let existing = consoles.first(where: { $0.host.id == host.id }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let password = Keychain.password(host: host.address, user: host.user) ?? ""
        let c = ConsoleWindowController(host: host, password: password)
        c.onClose = { [weak self, weak c] in
            self?.consoles.removeAll { $0 === c }
        }
        // New consoles join the frontmost console's tab group.
        if let front = consoles.last?.window, let w = c.window {
            front.addTabbedWindow(w, ordered: .above)
        }
        consoles.append(c)
        c.showWindow(nil)
        c.start()
    }

    @objc func sendCtrlAltDel(_ sender: Any?) {
        (NSApp.keyWindow?.windowController as? ConsoleWindowController)?.sendCtrlAltDel()
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About SMKVM",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit SMKVM", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Connection")
        fileMenu.addItem(withTitle: "Hosts", action: #selector(showHosts(_:)),
                         keyEquivalent: "0")
        fileMenu.addItem(withTitle: "Add Host…", action: #selector(addHost(_:)),
                         keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let keysItem = NSMenuItem()
        let keysMenu = NSMenu(title: "Keys")
        keysMenu.addItem(withTitle: "Send Ctrl-Alt-Del", action: #selector(sendCtrlAltDel(_:)),
                         keyEquivalent: "")
        keysItem.submenu = keysMenu
        main.addItem(keysItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}
