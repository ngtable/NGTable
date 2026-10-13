#if os(macOS)
import AppKit

// Collapsing and expanding groups by keyboard, like NSOutlineView: with
// grouped rows, Up and Down stop on group header rows too (the header is
// drawn selected, and no rows are selected). On a header, Left collapses
// its group (or goes to the group it's in, when collapsed) and Right expands
// it (or goes into it, when expanded); with Option, the groups within it too.

extension NGTableView {
    /// The display row of the header the keyboard is on, if it's shown.
    var keyboardGroupRow: Int? {
        guard let keyboardGroup, let node = groupTree.nodeOfGroup[keyboardGroup],
              node < groupHeaderDisplayRows.count, groupHeaderDisplayRows[node] >= 0 else { return nil }
        // Kept by node (a search through every display row on every arrow key before).
        return groupHeaderDisplayRows[node]
    }

    /// Up or Down with grouped rows, onto or from a header row; `false`
    /// when neither (the rows' own movement goes on).
    func moveThroughGroupHeaders(by delta: Int) -> Bool {
        guard groupedDisplay != nil, numberOfRows > 0 else { return false }
        let header = keyboardGroupRow
        if header == nil { keyboardGroup = nil }
        let current = navigatesByCell ? focusedCell.flatMap { displayRow(forSourceRow: $0.row) } ?? cursorRow : cursorRow
        guard let start = header ?? current else { return false }
        var next = start + delta
        // Rows the delegate doesn't let the user select are skipped, and so
        // are headers when the rows can't be left unselected (the keyboard on
        // a header selects no row).
        while next >= 0, next < numberOfRows,
              isGroupRow(next) ? !allowsEmptySelection : !(delegate?.tableView(self, shouldSelectRow: sourceRow(next)) ?? true) {
            next += delta > 0 ? 1 : -1
        }
        guard next >= 0, next < numberOfRows else { return header != nil || isGroupRow(start + delta) }
        if isGroupRow(next) {
            focusGroupHeader(atDisplayRow: next)
            return true
        }
        // From a header onto a row: like the arrows moving there.
        guard header != nil else { return false }
        keyboardGroup = nil
        if navigatesByCell {
            focusCell(displayRow: next, columnID: focusedCell?.columnID ?? columnLayout.allColumns.first?.id ?? "")
            showsFocusRing = true
        } else {
            anchorRow = next
            cursorRow = next
            setSelection([next], byUser: true)
            scrollDisplayRowToVisible(next)
        }
        return true
    }

    /// Puts the keyboard on a header row: no rows are selected while it's there.
    private func focusGroupHeader(atDisplayRow row: Int) {
        guard let node = groupNode(atDisplayRow: row) else { return }
        setSelection([], byUser: true)
        // The delegate kept the rows selected: the keyboard stays with them.
        guard displaySelection.isEmpty else { return }
        keyboardGroup = groupTree.nodes[node].group
        scrollDisplayRowToVisible(row)
    }

    /// Left on a header: collapses its group, or goes to the group it's in.
    func collapseKeyboardGroup(includingChildren: Bool) -> Bool {
        guard let group = keyboardGroup, keyboardGroupRow != nil else { return false }
        if isGroupExpanded(group) || (includingChildren && childGroups(of: group).contains(where: isGroupExpanded)) {
            collapseGroup(group, collapseChildren: includingChildren)
        } else if let parent = group.parent, groupTree.nodeOfGroup[parent] != nil {
            keyboardGroup = parent
            if let row = keyboardGroupRow { scrollDisplayRowToVisible(row) }
        }
        return true
    }

    /// Right on a header: expands its group, or goes into it.
    func expandKeyboardGroup(includingChildren: Bool) -> Bool {
        guard let group = keyboardGroup, keyboardGroupRow != nil else { return false }
        if !isGroupExpanded(group) || includingChildren {
            expandGroup(group, expandChildren: includingChildren)
            if let row = keyboardGroupRow { scrollDisplayRowToVisible(row) }
        } else {
            _ = moveThroughGroupHeaders(by: 1)
        }
        return true
    }

    /// Whether the key event being handled has Option down.
    var currentEventHasOption: Bool {
        NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
    }

    /// Whether a display row is the header the keyboard is on (drawn selected).
    func isKeyboardGroupRow(_ row: Int) -> Bool {
        guard let keyboardGroup, let node = groupNode(atDisplayRow: row) else { return false }
        return groupTree.nodeOfGroup[keyboardGroup] == node
    }
}
#endif
