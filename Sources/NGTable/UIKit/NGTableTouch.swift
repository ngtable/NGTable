#if os(iOS)
import UIKit

// Taps on the iPad, what a click does on the Mac: a title sorts by its
// column; a tree row's triangle or a group header opens or closes it; a link,
// a button or an editable rating acts; a check box toggles; otherwise the row
// is selected (with a hardware keyboard, Command adds or removes a row and
// Shift selects a range) and `action` is sent. A second tap edits an
// editable cell or sends `doubleAction`.

extension NGTableView {
    /// A tap at a point in the table's coordinates.
    func tapped(at point: CGPoint, modifiers: UIKeyModifierFlags = []) {
        guard !ignoresUserInput else { return }
        if point.y < layoutMetrics.headerHeight {
            if let (frame, _) = column(atViewportPoint: point), frame.column.isSortable { sortByClicking(frame.column) }
            return
        }
        guard point.y < bounds.height - layoutMetrics.summaryHeight else { return }
        endEditing(committing: true)
        let location = convert(point, to: nil)
        var row = row(atWindowLocation: location)
        if let handle = treeDisclosureHit(atWindowLocation: location, displayRow: row) {
            clickedRow = -1
            clickedColumn = -1
            setTreeRow(handle: handle, expanded: !isTreeRowExpanded(handle: handle), includingChildren: modifiers.contains(.alternate), byUser: true)
            return
        }
        if isGroupRow(row) {
            clickedRow = -1
            clickedColumn = -1
            toggleGroup(atDisplayRow: row, includingChildren: modifiers.contains(.alternate))
            return
        }
        let isOnRow = row >= 0 && row < numberOfRows
        let columnID = columnID(atWindowLocation: location)
        let isPlain = modifiers.isDisjoint(with: [.command, .shift, .control])
        // A plain tap on a control is the control's, not the selection's.
        if isPlain, isOnRow, let columnID, let cell = visibleCell(sourceRow: sourceRow(row), columnID: columnID),
           isOnControl(cell, atWindowLocation: location, row: sourceRow(row), columnID: columnID) {
            clickedRow = -1
            clickedColumn = -1
            if !setRating(atWindowLocation: location, row: sourceRow(row), columnID: columnID) {
                activateControl(row: sourceRow(row), columnID: columnID)
            }
            return
        }
        clickedRow = isOnRow ? sourceRow(row) : -1
        clickedColumn = columnID.flatMap { id in tableColumns.firstIndex { $0.id == id } } ?? -1
        guard isOnRow else {
            if isPlain {
                setSelection([], byUser: true)
                focusedCell = nil
                selectedCellRange = nil
            }
            send(action)
            return
        }
        if navigatesByCell, let columnID {
            if modifiers.contains(.shift), focusedCell != nil {
                extendCellRange(toDisplayRow: row, columnID: columnID)
                return
            }
            focusedCell = NGCellPosition(row: sourceRow(row), columnID: columnID)
            selectedCellRange = nil
        }
        // A check box toggles (the row is selected as well), a tap anywhere in
        // its cell (a finger's target); toggling may move the record (sorted
        // by it) or hide it (filtered by it).
        if isPlain, let columnID, isCheckBoxCell(row: sourceRow(row), columnID: columnID) {
            let ref = rowRef(ofRow: sourceRow(row))
            if toggleCheckBox(row: sourceRow(row), columnID: columnID) {
                guard let moved = displayRow(forSourceRow: self.row(of: ref)) else { return }
                row = moved
            }
        }
        if allowsMultipleSelection, modifiers.contains(.command) {
            var rows = displaySelection
            if rows.contains(row) { rows.remove(row) } else { rows.insert(row) }
            anchorRow = row
            setSelection(rows, byUser: true)
        } else if allowsMultipleSelection, modifiers.contains(.shift), let anchorRow {
            setSelection(IndexSet(integersIn: min(anchorRow, row)...max(anchorRow, row)), byUser: true)
        } else {
            anchorRow = row
            setSelection([row], byUser: true)
        }
        cursorRow = row
        // A column of pop-up choices that opens on a click: its menu opens.
        if isPlain, let columnID, let column = columnLayout.columnsByID[columnID], column.opensChoicesOnClick,
           Self.showsChoiceChevron(column), canEdit(row: sourceRow(row), columnID: columnID) {
            _ = showChoiceMenu(row: sourceRow(row), column: column)
            return
        }
        send(action)
    }

    /// A second tap on the rows: an editable cell is edited, otherwise
    /// `doubleAction` is sent (also below the rows, with `clickedRow` -1).
    func doubleTapped(at point: CGPoint, modifiers: UIKeyModifierFlags = []) {
        guard !ignoresUserInput, point.y >= layoutMetrics.headerHeight,
              point.y < bounds.height - layoutMetrics.summaryHeight,
              modifiers.isDisjoint(with: [.command, .shift]) else { return }
        let location = convert(point, to: nil)
        let row = row(atWindowLocation: location)
        guard !isGroupRow(row), treeDisclosureHit(atWindowLocation: location, displayRow: row) == nil else { return }
        let isOnRow = row >= 0 && row < numberOfRows
        let columnID = columnID(atWindowLocation: location)
        // The first tap acted on a control or a check box: the second does too, not more.
        if isOnRow, let columnID {
            if isCheckBoxCell(row: sourceRow(row), columnID: columnID) { return }
            if let cell = visibleCell(sourceRow: sourceRow(row), columnID: columnID),
               isOnControl(cell, atWindowLocation: location, row: sourceRow(row), columnID: columnID) { return }
        }
        clickedRow = isOnRow ? sourceRow(row) : -1
        clickedColumn = columnID.flatMap { id in tableColumns.firstIndex { $0.id == id } } ?? -1
        if isOnRow, let columnID, editCell(row: sourceRow(row), columnID: columnID) { return }
        send(doubleAction)
    }

    private func isCheckBoxCell(row: Int, columnID: String) -> Bool {
        guard let column = columnLayout.columnsByID[columnID] else { return false }
        return isCheckBox(row: row, column: column)
    }

    /// To `target`, or along the responder chain without one.
    func send(_ action: Selector?) {
        guard let action else { return }
        if let target = target as? NSObjectProtocol {
            _ = target.perform(action, with: self)
        } else {
            UIApplication.shared.sendAction(action, to: nil, from: self, for: nil)
        }
    }
}
#endif
