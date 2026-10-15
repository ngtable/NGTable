#if os(macOS)
import AppKit

extension NGTableView {
    /// The header's context menu, like Finder's and Mail's: every column and
    /// group with a checkmark; a group's columns are listed indented under it
    /// (what the items do is in NGColumnMenus.swift).
    /// - Parameter point: Where the menu opens in the header (its column
    ///   gets the pinning items), or `nil`.
    func makeColumnVisibilityMenu(at point: NSPoint? = nil) -> NSMenu? {
        let pinning = point.flatMap(pinningItems(at:)) ?? []
        let views = namedViewsMenuItem()
        guard allowsColumnHiding || !pinning.isEmpty || views != nil, !columns.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let views {
            menu.addItem(views)
            menu.addItem(.separator())
        }
        for item in pinning { menu.addItem(item) }
        let grouping = point.map(groupingItems(at:)) ?? []
        if !grouping.isEmpty {
            if !pinning.isEmpty { menu.addItem(.separator()) }
            for item in grouping { menu.addItem(item) }
        }
        guard allowsColumnHiding else { return menu }
        if pinning.isEmpty, !grouping.isEmpty { menu.addItem(.separator()) }
        if !pinning.isEmpty { menu.addItem(.separator()) }

        for entry in columnVisibilityEntries() {
            let item = NSMenuItem(title: entry.title, action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.indentationLevel = entry.indentation
            item.state = switch entry.state {
            case .visible: .on
            case .partiallyVisible: .mixed
            case .hidden: .off
            }
            item.isEnabled = entry.isEnabled
            menu.addItem(item)
        }
        return menu
    }

    private func pinningItems(at point: NSPoint) -> [NSMenuItem]? {
        guard let (itemID, choices) = pinChoices(at: point) else { return nil }
        return choices.map { choice in
            let menuItem = NSMenuItem(title: choice.title, action: #selector(pinColumn(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = [itemID, String(describing: choice.pin)]
            return menuItem
        }
    }

    private func groupingItems(at point: NSPoint) -> [NSMenuItem] {
        groupingChoices(at: point).map { choice in
            let action = choice.columnIDs.isEmpty ? #selector(ungroupRows(_:)) : #selector(groupByColumn(_:))
            let item = NSMenuItem(title: choice.title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = choice.columnIDs
            return item
        }
    }

    /// Groups by the item's columns (the column added as a level).
    @objc private func groupByColumn(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String] else { return }
        setRowGrouping(ids)
    }

    @objc private func ungroupRows(_ sender: NSMenuItem) {
        setRowGrouping([])
    }

    @objc private func pinColumn(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count == 2,
              let pin = NGColumnPin.allCases.first(where: { String(describing: $0) == parts[1] }) else { return }
        setPin(pin, forItemID: parts[0])
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        toggleColumnVisibility(id: id)
    }
}
#endif
