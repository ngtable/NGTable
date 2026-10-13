#if os(macOS)
import AppKit

extension NGTableView {
    /// The header's context menu, like Finder's and Mail's: every column and
    /// group with a checkmark; a group's columns are listed indented under it.
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
        let grouping = point.flatMap(groupingItems(at:)) ?? []
        if !grouping.isEmpty {
            if !pinning.isEmpty { menu.addItem(.separator()) }
            for item in grouping { menu.addItem(item) }
        }
        guard allowsColumnHiding else { return menu }
        if pinning.isEmpty, !grouping.isEmpty { menu.addItem(.separator()) }
        if !pinning.isEmpty { menu.addItem(.separator()) }

        func addItem(id: String, title: String, indentation: Int) {
            let item = NSMenuItem(title: title, action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.indentationLevel = indentation
            item.state = switch NGColumnVisibility.state(of: id, in: columns, hiddenIDs: hiddenColumnIDs) {
            case .visible: .on
            case .partiallyVisible: .mixed
            case .hidden: .off
            }
            item.isEnabled = NGColumnVisibility.canToggle(id, in: columns, hiddenIDs: hiddenColumnIDs) && userCanChangeVisibility(of: id)
            menu.addItem(item)
        }

        for item in columns {
            switch item {
            case .column(let column):
                addItem(id: column.id, title: column.menuTitle, indentation: 0)
            case .group(let group):
                addItem(id: group.id, title: group.title, indentation: 0)
                for column in group.columns {
                    addItem(id: column.id, title: column.menuTitle, indentation: 1)
                }
            }
        }
        return menu
    }

    /// "Pin to the Left/Right Edge" and "Unpin" for the top-level item (column
    /// or group) of the column at a point of the header.
    private func pinningItems(at point: NSPoint) -> [NSMenuItem]? {
        guard allowsColumnPinning, let column = column(atViewportPoint: point)?.frame.column, column.isMovable,
              let item = columns.first(where: { $0.leafColumns.contains { $0.id == column.id } }) else { return nil }
        let isRightToLeft = userInterfaceLayoutDirection == .rightToLeft
        let choices: [(pin: NGColumnPin, title: String)] = [
            (.leading, isRightToLeft
                ? String(localized: "Pin to the Right Edge", bundle: .module, comment: "Header menu: freezes the column at the leading edge.")
                : String(localized: "Pin to the Left Edge", bundle: .module, comment: "Header menu: freezes the column at the leading edge.")),
            (.trailing, isRightToLeft
                ? String(localized: "Pin to the Left Edge", bundle: .module, comment: "Header menu: freezes the column at the leading edge.")
                : String(localized: "Pin to the Right Edge", bundle: .module, comment: "Header menu: freezes the column at the trailing edge.")),
            (.none, String(localized: "Unpin", bundle: .module, comment: "Header menu: lets a frozen column scroll again.")),
        ]
        return choices.filter { $0.pin != item.pin }.map { choice in
            let menuItem = NSMenuItem(title: choice.title, action: #selector(pinColumn(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = [item.id, String(describing: choice.pin)]
            return menuItem
        }
    }

    /// "Group by «Column»" (another level when grouped) and "Ungroup" for the
    /// column at a point of the header.
    private func groupingItems(at point: NSPoint) -> [NSMenuItem]? {
        guard allowsUserGrouping, let column = column(atViewportPoint: point)?.frame.column else { return nil }
        var items: [NSMenuItem] = []
        let current = rowGrouping?.columnIDs ?? []
        if !current.contains(column.id) {
            let format = current.isEmpty
                ? String(localized: "Group by “%@”", bundle: .module, comment: "Header menu: groups the rows by the column's values.")
                : String(localized: "Then Group by “%@”", bundle: .module, comment: "Header menu: adds a grouping level by the column.")
            let item = NSMenuItem(title: String(format: format, column.menuTitle), action: #selector(groupByColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.id
            items.append(item)
        }
        if !current.isEmpty {
            let item = NSMenuItem(title: String(localized: "Ungroup", bundle: .module, comment: "Header menu: shows the rows without groups."),
                                  action: #selector(ungroupRows(_:)), keyEquivalent: "")
            item.target = self
            items.append(item)
        }
        return items
    }

    @objc private func groupByColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setRowGrouping((rowGrouping?.columnIDs ?? []) + [id])
    }

    @objc private func ungroupRows(_ sender: NSMenuItem) {
        setRowGrouping([])
    }

    /// Groups as the user does from the header menu, and tells the delegate.
    func setRowGrouping(_ columnIDs: [String]) {
        rowGrouping = columnIDs.isEmpty ? nil : NGRowGrouping(columnIDs: columnIDs, startsCollapsed: rowGrouping?.startsCollapsed ?? false)
        delegate?.tableView(self, didChangeRowGrouping: rowGrouping)
    }

    @objc private func pinColumn(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count == 2,
              let pin = NGColumnPin.allCases.first(where: { String(describing: $0) == parts[1] }) else { return }
        setPin(pin, forItemID: parts[0])
    }

    /// Moves a top-level item (column or group id) to another region, as the
    /// user does from the header menu: saves the layout and tells the delegate.
    func setPin(_ pin: NGColumnPin, forItemID id: String) {
        guard let index = columns.firstIndex(where: { $0.id == id }), columns[index].pin != pin else { return }
        var items = columns
        switch items[index] {
        case .column(var column):
            column.pin = pin
            items[index] = .column(column)
        case .group(var group):
            group.pin = pin
            items[index] = .group(group)
        }
        // Back to the definition's region: no longer the user's.
        userPins[id] = definitionPins[id] == pin ? nil : pin
        applyReorderedColumns(items)
        autosaveLayoutState()
        delegate?.tableView(self, didReorderColumns: columns)
    }

    /// Whether the delegate lets the user show or hide a column, or every
    /// column of a group.
    private func userCanChangeVisibility(of id: String) -> Bool {
        guard let delegate else { return true }
        let affected = columns.first { $0.id == id }?.leafColumns ?? tableColumns.filter { $0.id == id }
        return affected.allSatisfy { delegate.tableView(self, userCanChangeVisibilityOf: $0) }
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              NGColumnVisibility.canToggle(id, in: columns, hiddenIDs: hiddenColumnIDs), userCanChangeVisibility(of: id) else { return }
        let before = hiddenColumnIDs
        hiddenColumnIDs = NGColumnVisibility.toggling(id, in: columns, hiddenIDs: hiddenColumnIDs)
        autosaveLayoutState()
        delegate?.tableView(self, didChangeHiddenColumns: hiddenColumnIDs)
        let changed = before.symmetricDifference(hiddenColumnIDs)
        delegate?.tableView(self, userDidChangeVisibilityOf: tableColumns.filter { changed.contains($0.id) })
    }
}
#endif
