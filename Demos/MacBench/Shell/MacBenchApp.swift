//
//  MacBenchApp.swift
//  NGTable Mac Bench
//
//  NGTable's benches on the Mac, in one window with a tab each:
//  - Живые данные: synthetic rows that change by themselves (row updates, sorting, grouping);
//  - Стенд: a real app's campaigns table (a copy of EasyCPA's) with synthetic campaigns;
//  - Фид: a live feed over the network from an ngfeed server (../ngfeed);
//  - Binance: Binance's public market data, live.
//  Feed and Binance can show NSTableView and SwiftUI's Table instead, for comparing engines.
//  Launch arguments open a tab and start it, e.g. for profiling: -BenchAutostart YES,
//  -FeedAutostart trading, -BinanceAutostart tickers.
//

import AppKit

@main
enum MacBenchApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = MacBenchDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMainMenu()
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    /// Quit, the edit commands (copy, select all, find) and the window's.
    private static func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            item.submenu = sub
            menu.addItem(item)
        }
        submenu("NGTable Mac Bench", [NSMenuItem(title: "Quit NGTable Mac Bench", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        submenu("Edit", [
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
            NSMenuItem(title: "Find", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f"),
        ])
        submenu("Window", [
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ])
        return menu
    }
}

final class MacBenchDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let sections: [(title: String, symbol: String, controller: () -> NSViewController)] = [
            ("Живые данные", "waveform.path.ecg", { LiveDataViewController() }),
            ("Стенд", "testtube.2", { BenchViewController() }),
            ("Фид", "antenna.radiowaves.left.and.right", { FeedViewController() }),
            ("Binance", "bitcoinsign.circle", { BinanceViewController() }),
        ]
        for section in sections {
            let item = NSTabViewItem(viewController: section.controller())
            item.label = section.title
            item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
            tabs.addTabViewItem(item)
        }
        // Launch arguments open a section (the section starts by itself).
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "BenchAutostart") { tabs.selectedTabViewItemIndex = 1 }
        if defaults.string(forKey: "FeedAutostart") != nil { tabs.selectedTabViewItemIndex = 2 }
        if defaults.string(forKey: "BinanceAutostart") != nil { tabs.selectedTabViewItemIndex = 3 }
        let window = NSWindow(contentViewController: tabs)
        window.title = "NGTable Mac Bench"
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.setFrameAutosaveName("NGTableMacBench.main")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
