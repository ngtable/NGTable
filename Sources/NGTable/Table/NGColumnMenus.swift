#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// What the header's context menu offers, for both platforms' menus (an
// NSMenu on the Mac, a UIMenu on the iPad): pinning the column's top-level
// item, grouping by the column, and every column and group to show or hide.
// The menus are built in NGColumnVisibilityMenu.swift (Mac) and
// NGTableMenus.swift (iPad); what the items do is here.

extension NGTableView {
    /// A column or group the menu shows or hides.
    struct ColumnVisibilityEntry {
        let id: String
        let title: String
        /// 1 for a group's columns, listed under it.
        let indentation: Int
        let state: NGColumnVisibility.State
        let isEnabled: Bool
    }

    /// Every column and group with its state; a group's columns follow it.
    func columnVisibilityEntries() -> [ColumnVisibilityEntry] {
        func entry(_ id: String, _ title: String, _ indentation: Int) -> ColumnVisibilityEntry {
            ColumnVisibilityEntry(id: id, title: title, indentation: indentation,
                                  state: NGColumnVisibility.state(of: id, in: columns, hiddenIDs: hiddenColumnIDs),
                                  isEnabled: NGColumnVisibility.canToggle(id, in: columns, hiddenIDs: hiddenColumnIDs) && userCanChangeVisibility(of: id))
        }
        var entries: [ColumnVisibilityEntry] = []
        for item in columns {
            switch item {
            case .column(let column):
                entries.append(entry(column.id, column.menuTitle, 0))
            case .group(let group):
                entries.append(entry(group.id, group.title, 0))
                entries += group.columns.map { entry($0.id, $0.menuTitle, 1) }
            }
        }
        return entries
    }

    /// "Pin to the Left/Right Edge" and "Unpin" for the top-level item
    /// (column or group) of the column at a point of the header.
    func pinChoices(at point: CGPoint) -> (itemID: String, choices: [(pin: NGColumnPin, title: String)])? {
        guard allowsColumnPinning, let column = column(atViewportPoint: point)?.frame.column, column.isMovable,
              let item = columns.first(where: { $0.leafColumns.contains { $0.id == column.id } }) else { return nil }
        let isRightToLeft = layoutDirection == .rightToLeft
        let choices: [(pin: NGColumnPin, title: String)] = [
            (.leading, isRightToLeft
                ? String(localized: "Pin to the Right Edge", bundle: .module, comment: "Header menu: freezes the column at the leading edge.")
                : String(localized: "Pin to the Left Edge", bundle: .module, comment: "Header menu: freezes the column at the leading edge.")),
            (.trailing, isRightToLeft
                ? String(localized: "Pin to the Left Edge", bundle: .module, comment: "Header menu: freezes the column at the leading edge.")
                : String(localized: "Pin to the Right Edge", bundle: .module, comment: "Header menu: freezes the column at the trailing edge.")),
            (.none, String(localized: "Unpin", bundle: .module, comment: "Header menu: lets a frozen column scroll again.")),
        ]
        return (item.id, choices.filter { $0.pin != item.pin })
    }

    /// "Group by «Column»" (another level when grouped) and "Ungroup" for the
    /// column at a point of the header, with the grouping each sets.
    func groupingChoices(at point: CGPoint) -> [(title: String, columnIDs: [String])] {
        guard allowsUserGrouping, let column = column(atViewportPoint: point)?.frame.column else { return [] }
        var choices: [(title: String, columnIDs: [String])] = []
        let current = rowGrouping?.columnIDs ?? []
        if !current.contains(column.id) {
            let format = current.isEmpty
                ? String(localized: "Group by “%@”", bundle: .module, comment: "Header menu: groups the rows by the column's values.")
                : String(localized: "Then Group by “%@”", bundle: .module, comment: "Header menu: adds a grouping level by the column.")
            choices.append((String(format: format, column.menuTitle), current + [column.id]))
        }
        if !current.isEmpty {
            choices.append((String(localized: "Ungroup", bundle: .module, comment: "Header menu: shows the rows without groups."), []))
        }
        return choices
    }

    /// Groups as the user does from the header menu, and tells the delegate.
    func setRowGrouping(_ columnIDs: [String]) {
        rowGrouping = columnIDs.isEmpty ? nil : NGRowGrouping(columnIDs: columnIDs, startsCollapsed: rowGrouping?.startsCollapsed ?? false)
        delegate?.tableView(self, didChangeRowGrouping: rowGrouping)
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
    func userCanChangeVisibility(of id: String) -> Bool {
        guard let delegate else { return true }
        let affected = columns.first { $0.id == id }?.leafColumns ?? tableColumns.filter { $0.id == id }
        return affected.allSatisfy { delegate.tableView(self, userCanChangeVisibilityOf: $0) }
    }

    /// Shows or hides a column or group as the user does from the menu.
    func toggleColumnVisibility(id: String) {
        guard NGColumnVisibility.canToggle(id, in: columns, hiddenIDs: hiddenColumnIDs), userCanChangeVisibility(of: id) else { return }
        let before = hiddenColumnIDs
        hiddenColumnIDs = NGColumnVisibility.toggling(id, in: columns, hiddenIDs: hiddenColumnIDs)
        autosaveLayoutState()
        delegate?.tableView(self, didChangeHiddenColumns: hiddenColumnIDs)
        let changed = before.symmetricDifference(hiddenColumnIDs)
        delegate?.tableView(self, userDidChangeVisibilityOf: tableColumns.filter { changed.contains($0.id) })
    }

    /// Picks the summary row's scope as the user does from its menu, and
    /// tells the delegate.
    func setSummaryScopeByUser(_ scope: NGSummaryScope) {
        summaryScope = scope
        delegate?.tableView(self, summaryScopeDidChange: summaryScope)
    }
}
#endif
