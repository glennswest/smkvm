import AppKit
import SMKVMCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var hostsWindow: HostsWindowController?
    private var consoles: [ConsoleWindowController] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = makeMenu()
        showHosts(nil)
        connectFromArguments()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showHosts(nil) }
        return true
    }

    /// `--connect <name|address>` (repeatable) opens consoles at launch.
    private func connectFromArguments() {
        let args = ProcessInfo.processInfo.arguments
        for (i, a) in args.enumerated() where a == "--connect" && i + 1 < args.count {
            let want = args[i + 1]
            if let h = HostStore.shared.hosts.first(where: { $0.address == want || $0.name == want }) {
                open(h)
            }
        }
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
        let password = PasswordStore.password(host: host.address, user: host.user) ?? ""
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

    private var console: ConsoleWindowController? {
        NSApp.keyWindow?.windowController as? ConsoleWindowController
    }

    @objc func sendCtrlAltDel(_ sender: Any?) { console?.sendCtrlAltDel() }

    /// Keys a Mac keyboard lacks; the HID usage is the menu item's tag.
    @objc func sendSpecialKey(_ sender: NSMenuItem) { console?.sendKey(UInt8(sender.tag)) }

    @objc func powerAction(_ sender: NSMenuItem) {
        guard let action = PowerAction(rawValue: UInt8(sender.tag)) else { return }
        console?.power(action, title: sender.title.replacingOccurrences(of: "…", with: ""))
    }

    @objc func toggleScreenLog(_ sender: Any?) { console?.toggleScreenLog() }

    @objc func showScreenLog(_ sender: Any?) { console?.showScreenLog() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleScreenLog(_:)):
            item.state = console?.logScreens == true ? .on : .off
            return console != nil
        case #selector(showScreenLog(_:)):
            return console != nil
        case #selector(sendCtrlAltDel(_:)), #selector(sendSpecialKey(_:)), #selector(powerAction(_:)):
            return console != nil
        default:
            return true
        }
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

        let consoleItem = NSMenuItem()
        let consoleMenu = NSMenu(title: "Console")
        consoleMenu.addItem(withTitle: "Log Screen on Clear", action: #selector(toggleScreenLog(_:)),
                            keyEquivalent: "l")
        consoleMenu.addItem(withTitle: "Show Screen Log in Finder", action: #selector(showScreenLog(_:)),
                            keyEquivalent: "L")
        consoleItem.submenu = consoleMenu
        main.addItem(consoleItem)

        let keysItem = NSMenuItem()
        let keysMenu = NSMenu(title: "Keys")
        keysMenu.addItem(withTitle: "Send Ctrl-Alt-Del", action: #selector(sendCtrlAltDel(_:)),
                         keyEquivalent: "")
        for (title, hid) in [("Print Screen", 0x46), ("Scroll Lock", 0x47), ("Pause / Break", 0x48),
                             ("Insert", 0x49), ("F13", 0x68)] {
            let item = keysMenu.addItem(withTitle: "Send \(title)", action: #selector(sendSpecialKey(_:)),
                                        keyEquivalent: "")
            item.tag = hid
        }
        keysItem.submenu = keysMenu
        main.addItem(keysItem)

        let powerItem = NSMenuItem()
        let powerMenu = NSMenu(title: "Power")
        for (title, action) in [("Power On", PowerAction.on), ("Reset…", .reset),
                                ("Soft Shutdown (ACPI)…", .softOff), ("Power Off…", .off)] {
            let item = powerMenu.addItem(withTitle: title, action: #selector(powerAction(_:)),
                                         keyEquivalent: "")
            item.tag = Int(action.rawValue)
        }
        powerItem.submenu = powerMenu
        main.addItem(powerItem)

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
