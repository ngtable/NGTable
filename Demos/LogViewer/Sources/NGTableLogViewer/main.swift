import AppKit
import NGTable

// The app: one window and a menu bar with the table's commands (Copy, Find,
// Export…) going to it through the responder chain.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: LogWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        let controller = LogWindowController()
        controller.showWindow(nil)
        controller.window?.center()
        self.controller = controller
        NSApp.activate()
    }

    private static func mainMenu() -> NSMenu {
        let menu = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            items.forEach(submenu.addItem)
            item.submenu = submenu
            menu.addItem(item)
        }
        submenu("Log Viewer", [NSMenuItem(title: "Quit Log Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        let export = NSMenuItem(title: "Export…", action: #selector(NGTableView.exportDocument(_:)), keyEquivalent: "e")
        submenu("File", [export, NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")])
        submenu("Edit", [NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                         NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")])
        return menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
