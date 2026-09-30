import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var connect: ConnectWindowController?
    private var consoles: [ConsoleWindowController] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = makeMenu()
        showConnect(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    @objc func showConnect(_ sender: Any?) {
        if connect == nil {
            connect = ConnectWindowController { [weak self] host, user, password in
                self?.open(host: host, user: user, password: password)
            }
        }
        connect?.showWindow(nil)
        connect?.window?.makeKeyAndOrderFront(nil)
    }

    private func open(host: String, user: String, password: String) {
        let c = ConsoleWindowController(host: host, user: user, password: password)
        c.onClose = { [weak self, weak c] in
            self?.consoles.removeAll { $0 === c }
        }
        consoles.append(c)
        c.showWindow(nil)
        c.start()
        connect?.close()
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
        fileMenu.addItem(withTitle: "New Connection…", action: #selector(showConnect(_:)),
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

        return main
    }
}
