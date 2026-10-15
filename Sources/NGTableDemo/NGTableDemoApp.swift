#if os(macOS)
import AppKit

/// Runs the demo as a regular app window, with a main menu so Copy, Select
/// All and Quit work from the keyboard.
@main
@MainActor
enum NGTableDemoApp {
    static func main() {
        let app = NSApplication.shared
        // A single-window demo: no window tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMainMenu()
        // The application holds its delegate weakly.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide NGTableDemo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit NGTableDemo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenu: appMenu, title: "NGTableDemo")

        // Standard editing for the search field; the table handles Copy and Select All.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenu: editMenu, title: "Edit")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(submenu: windowMenu, title: "Window")
        NSApplication.shared.windowsMenu = windowMenu
        return mainMenu
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "NGTable"
        window.contentViewController = NGTableDemoViewController()
        window.setContentSize(NSSize(width: 1200, height: 700))
        window.minSize = NSSize(width: 700, height: 400)
        window.center()
        window.setFrameAutosaveName("NGTableDemoWindow")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
#else
/// The demo is a Mac app (the iPad's is Demos/NGTableDemos.xcodeproj); on iOS the
/// package's tests build it too.
@main
enum NGTableDemoApp {
    static func main() {
        print("NGTableDemo runs on the Mac; see Demos/NGTableDemos.xcodeproj for the iPad.")
    }
}
#endif
