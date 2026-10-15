#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The keyboard's commands, for both platforms: the Mac's responder methods
// (NGTableKeyboard.swift) and the iPad's hardware keyboard (NGTableKeys.swift)
// call these.

extension NGTableView {
    /// Typing within this pause continues a type select search.
    static let typeSelectPause: TimeInterval = 1

    /// Space toggles a focused check box or presses a focused link; a number
    /// key sets a focused editable rating. Whether the key did something.
    func actOnFocusedCell(key: String) -> Bool {
        // Not on a cell the filter or a collapsed group hides.
        guard !ignoresUserInput, navigatesByCell, let cell = focusedCell, displayRow(forSourceRow: cell.row) != nil else { return false }
        if key == " ", let column = tableColumns.first(where: { $0.id == cell.columnID }), isCheckBox(row: cell.row, column: column) {
            toggleCheckBox(row: cell.row, columnID: cell.columnID)
            return true
        }
        if let digit = Int(key), setRating(digit, row: cell.row, columnID: cell.columnID) { return true }
        return key == " " && activateControl(row: cell.row, columnID: cell.columnID)
    }

    /// Up and Down (`delta` -1 or 1): through group headers, the focused cell, the selection.
    func moveVertically(by delta: Int) {
        if moveThroughGroupHeaders(by: delta) { return }
        if moveFocusedCell(columns: 0, rows: delta) { return }
        moveSelection(by: delta, extending: false)
    }

    /// Shift with Up and Down: a range of cells, or of rows.
    func extendVertically(by delta: Int) {
        if extendCellRange(columns: 0, rows: delta) { return }
        moveSelection(by: delta, extending: true)
    }

    /// Toward the leading side: collapse, the previous column.
    func moveTowardStart(includingChildren: Bool) {
        if collapseKeyboardGroup(includingChildren: includingChildren) { return }
        if collapseOrGoToParent(includingChildren: includingChildren) { return }
        if moveFocusedCell(columns: -1, rows: 0) { return }
        scrollToColumn(forward: false)
    }

    /// Toward the trailing side: expand, the next column.
    func moveTowardEnd(includingChildren: Bool) {
        if expandKeyboardGroup(includingChildren: includingChildren) { return }
        if expandOrGoToChild(includingChildren: includingChildren) { return }
        if moveFocusedCell(columns: 1, rows: 0) { return }
        scrollToColumn(forward: true)
    }

    /// Command-A: every row.
    func selectAllRowsByUser() {
        guard allowsMultipleSelection, numberOfRows > 0, !ignoresUserInput else { return }
        // On the first and last rows, not on group headers.
        let rows = 0..<numberOfRows
        anchorRow = rows.first { !isGroupRow($0) } ?? 0
        cursorRow = rows.last { !isGroupRow($0) } ?? numberOfRows - 1
        setSelection(IndexSet(integersIn: 0..<numberOfRows), byUser: true)
    }

    /// Typed text: edits a focused editable cell, like a spreadsheet, or
    /// selects the row whose value starts with what was typed lately.
    /// - Parameter shouldSearch: Asked with the search going on (`nil` when
    ///   this starts one) whether the table searches.
    func typeSelect(_ typed: String, shouldSearch: (String?) -> Bool = { _ in true }) {
        if navigatesByCell, let cell = focusedCell, !typed.trimmingCharacters(in: .whitespaces).isEmpty,
           editCell(row: cell.row, columnID: cell.columnID, text: typed) {
            return
        }
        guard allowsTypeSelect else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let search = typeSelectBuffer.isEmpty || now - lastTypeSelectTime > Self.typeSelectPause ? nil : typeSelectBuffer
        guard shouldSearch(search) else { return }
        // Typing continues a search within a short pause, otherwise starts over.
        if now - lastTypeSelectTime > Self.typeSelectPause {
            typeSelectBuffer = ""
        }
        let continuing = !typeSelectBuffer.isEmpty
        lastTypeSelectTime = now
        // A leading space is not a search (it would match nothing useful).
        guard !(typeSelectBuffer.isEmpty && typed.trimmingCharacters(in: .whitespaces).isEmpty) else { return }
        typeSelectBuffer += typed
        guard let row = typeSelectMatch(for: typeSelectBuffer, continuing: continuing) else {
            #if os(macOS)
            NSSound.beep()
            #endif
            return
        }
        anchorRow = row
        cursorRow = row
        setSelection([row], byUser: true)
        scrollDisplayRowToVisible(row)
    }

    /// Whether a type select search is going on (a space within one is part of it, like in Finder).
    var isTypeSelecting: Bool {
        !typeSelectBuffer.isEmpty && ProcessInfo.processInfo.systemUptime - lastTypeSelectTime <= Self.typeSelectPause
    }

    /// Scrolls so that the previous or next scrolling column starts at the
    /// leading edge of the scrolling area.
    func scrollToColumn(forward: Bool) {
        // Scroll positions at which each scrolling column starts where the first
        // one does unscrolled (after the edge margin, if the region has one).
        let spans = geometry.center.columns.map { scrollSpan(of: $0).start }.sorted()
        let base = spans.first ?? 0
        let starts = spans.map { $0 - base }
        let x = contentOffset.x
        let target = forward
            ? starts.first { $0 > x + 0.5 } ?? layoutMetrics.maxOffset.x
            : starts.last { $0 < x - 0.5 } ?? 0
        setContentOffset(CGPoint(x: target, y: contentOffset.y))
        #if os(macOS)
        revealScroller(.horizontal)
        #endif
    }

    /// The selected rows go to `rowDeletion`, if it's set; whether they did.
    @discardableResult
    func deleteSelectedRows() -> Bool {
        guard let rowDeletion, !ignoresUserInput, !selectedRowIndexes.isEmpty else { return false }
        rowDeletion(selectedRowIndexes)
        return true
    }

    /// The first row (display index) that matches `prefix`. Continuing to
    /// type keeps the current row if it still matches; a new search starts
    /// after it, so typing the same letter again moves on to the next match,
    /// and wraps to the top. The delegate finds the match in each range
    /// (`nextTypeSelectMatchFromRow`, by default `typeSelectMatch(from:to:for:)`).
    func typeSelectMatch(for prefix: String, continuing: Bool = true) -> Int? {
        guard numberOfRows > 0 else { return nil }
        let start = (cursorRow.map { continuing ? $0 : $0 + 1 } ?? 0) % numberOfRows
        let ranges = start > 0 ? [start..<numberOfRows, 0..<start] : [0..<numberOfRows]
        for range in ranges {
            let match = delegate?.tableView(self, nextTypeSelectMatchFromRow: range.lowerBound, toRow: range.upperBound, for: prefix)
                ?? typeSelectMatch(from: range.lowerBound, to: range.upperBound, for: prefix)
            if range.contains(match), !isGroupRow(match) { return match }
        }
        return nil
    }

    /// The table's own type select match: the first display index from
    /// `start` up to `end` (wrapping past the last row if `end` is less)
    /// whose value in the type select column starts with `prefix`, ignoring
    /// case and diacritics, or -1.
    func typeSelectMatch(from start: Int, to end: Int, for prefix: String) -> Int {
        guard let dataSource, numberOfRows > 0, start >= 0, start < numberOfRows,
              let column = typeSelectColumnID.flatMap({ columnLayout.columnsByID[$0] }) ?? columnLayout.allColumns.first
        else { return -1 }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        let end = min(max(end, 0), numberOfRows)
        let count = end > start ? end - start : numberOfRows - start + end
        for offset in 0..<count {
            let row = (start + offset) % numberOfRows
            guard !isGroupRow(row) else { continue }
            let source = sourceRow(row)
            let text = delegate?.tableView(self, typeSelectStringFor: column, row: source)
                ?? column.format.string(for: dataSource.tableView(self, valueFor: column, row: source), locale: formattingLocale)
            if !text.isEmpty, text.range(of: prefix, options: options) != nil {
                return row
            }
        }
        return -1
    }

    func moveSelection(by delta: Int, extending: Bool) {
        guard numberOfRows > 0 else { return }
        let current = cursorRow ?? (delta > 0 ? -1 : numberOfRows)
        // Rows the delegate doesn't let the user select are skipped.
        guard let row = selectableRow(from: current, by: delta) else { return }
        if extending, allowsMultipleSelection {
            let anchor = anchorRow ?? row
            anchorRow = anchor
            setSelection(IndexSet(integersIn: min(anchor, row)...max(anchor, row)), byUser: true)
        } else {
            anchorRow = row
            setSelection([row], byUser: true)
        }
        cursorRow = row
        scrollDisplayRowToVisible(row)
    }
}
#endif
