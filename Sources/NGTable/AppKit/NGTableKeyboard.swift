#if os(macOS)
import AppKit

// Keyboard: arrow keys and their shift-extended selection, ←/→ scrolling by a
// column, paging, Home/End, Tab out of the table, and type select (typing the
// beginning of a value selects the row).

extension NGTableView {
    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        // The table ignores the keyboard while its data is about to change (see
        // `isUpdatingData`), and a space that doesn't continue a type select
        // search isn't the table's either: both go on to the next responder,
        // e.g. the app's Escape to cancel loading, or Quick Look.
        // Space toggles a focused check box.
        if !ignoresUserInput, navigatesByCell, event.charactersIgnoringModifiers == " ",
           event.modifierFlags.isDisjoint(with: [.command, .control, .option]), let cell = focusedCell,
           let column = tableColumns.first(where: { $0.id == cell.columnID }), isCheckBox(row: cell.row, column: column),
           displayRow(forSourceRow: cell.row) != nil {   // Not one the filter or a collapsed group hides.
            toggleCheckBox(row: cell.row, columnID: cell.columnID)
            return
        }
        // A number key sets a focused editable rating.
        if !ignoresUserInput, navigatesByCell, event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
           let cell = focusedCell, displayRow(forSourceRow: cell.row) != nil,
           let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), setRating(digit, row: cell.row, columnID: cell.columnID) {
            return
        }
        // Space presses a focused link.
        if !ignoresUserInput, navigatesByCell, event.charactersIgnoringModifiers == " ",
           event.modifierFlags.isDisjoint(with: [.command, .control, .option]), let cell = focusedCell,
           displayRow(forSourceRow: cell.row) != nil, activateControl(row: cell.row, columnID: cell.columnID) {
            return
        }
        // Option-Down Arrow opens the focused cell's column filter, like a spreadsheet's.
        if !ignoresUserInput, navigatesByCell, allowsColumnFilters, event.keyCode == 125,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .option,
           let cell = focusedCell, showFilter(forColumnID: cell.columnID) {
            return
        }
        if ignoresUserInput || startsWithSpaceOutsideTypeSelect(event) {
            super.keyDown(with: event)
            return
        }
        if typesIntoFocusedCell(event) { return }
        // Type select asks the delegate about the key that types.
        typeSelectEvent = event
        defer { typeSelectEvent = nil }
        interpretKeyEvents([event])
    }

    /// A key that types on a focused text cell opens its field and goes to
    /// the field's editor, so input methods compose there (marked text), like
    /// typing into a spreadsheet's cell. Not for spaces, controls, arrows and
    /// function keys, Command and Control keys, check boxes and lists.
    private func typesIntoFocusedCell(_ event: NSEvent) -> Bool {
        guard navigatesByCell, let cell = focusedCell, event.modifierFlags.isDisjoint(with: [.command, .control]),
              let scalar = event.characters?.unicodeScalars.first,
              !CharacterSet.whitespacesAndNewlines.contains(scalar), !CharacterSet.controlCharacters.contains(scalar),
              !(0xF700...0xF8FF).contains(scalar.value),
              let column = tableColumns.first(where: { $0.id == cell.columnID }),
              !isCheckBox(row: cell.row, column: column), column.editChoices == nil,
              canEdit(row: cell.row, columnID: cell.columnID),
              editCell(row: cell.row, columnID: cell.columnID, text: ""),
              let fieldEditor = editor?.field.currentEditor() else { return false }
        fieldEditor.keyDown(with: event)
        return true
    }

    /// A plain space while no type select search is going on (a space within
    /// one is part of it, like in Finder).
    private func startsWithSpaceOutsideTypeSelect(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers == " ",
              event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let isSearching = !typeSelectBuffer.isEmpty && ProcessInfo.processInfo.systemUptime - lastTypeSelectTime <= Self.typeSelectPause
        return !isSearching
    }

    /// Typing within this pause continues a type select search.
    private static let typeSelectPause: TimeInterval = 1

    public override func moveUp(_ sender: Any?) {
        if moveThroughGroupHeaders(by: -1) { return }
        if moveFocusedCell(columns: 0, rows: -1) { return }
        moveSelection(by: -1, extending: false)
    }

    public override func moveDown(_ sender: Any?) {
        if moveThroughGroupHeaders(by: 1) { return }
        if moveFocusedCell(columns: 0, rows: 1) { return }
        moveSelection(by: 1, extending: false)
    }

    /// A command the table doesn't handle goes on along the responder chain,
    /// e.g. Escape to a sheet's controller (NSView doesn't implement these
    /// commands itself: calling `super` would raise "unrecognized selector").
    /// Nobody taking it beeps, like for any unhandled key.
    private func passOn(_ command: Selector) {
        if let nextResponder {
            nextResponder.doCommand(by: command)
        } else {
            NSSound.beep()
        }
    }

    /// Return edits the focused cell, when it's editable; otherwise it sends
    /// `returnAction` if there is one.
    public override func insertNewline(_ sender: Any?) {
        if navigatesByCell, let cell = focusedCell, editCell(row: cell.row, columnID: cell.columnID) { return }
        if let returnAction, !ignoresUserInput, !selectedRowIndexes.isEmpty {
            clickedRow = -1
            isSendingReturnAction = true
            defer { isSendingReturnAction = false }
            NSApp.sendAction(returnAction, to: target, from: self)
            return
        }
        passOn(#selector(insertNewline(_:)))
    }

    public override func moveUpAndModifySelection(_ sender: Any?) {
        if extendCellRange(columns: 0, rows: -1) { return }
        moveSelection(by: -1, extending: true)
    }

    public override func moveDownAndModifySelection(_ sender: Any?) {
        if extendCellRange(columns: 0, rows: 1) { return }
        moveSelection(by: 1, extending: true)
    }

    // Shift with Left and Right: a range of cells, with navigation by cell.
    public override func moveLeftAndModifySelection(_ sender: Any?) {
        if extendCellRange(columns: isRightToLeft ? 1 : -1, rows: 0) { return }
        passOn(#selector(moveLeftAndModifySelection(_:)))
    }

    public override func moveRightAndModifySelection(_ sender: Any?) {
        if extendCellRange(columns: isRightToLeft ? -1 : 1, rows: 0) { return }
        passOn(#selector(moveRightAndModifySelection(_:)))
    }

    /// Escape drops a range of cells (the focused cell stays).
    public override func cancelOperation(_ sender: Any?) {
        guard selectedCellRange != nil else {
            // Escape hides the focused cell's ring (the rows stay selected).
            if navigatesByCell, showsFocusRing {
                showsFocusRing = false
                return
            }
            passOn(#selector(cancelOperation(_:)))
            return
        }
        selectedCellRange = nil
        if let cell = focusedCell, let row = displayRow(forSourceRow: cell.row) { setSelection([row], byUser: true) }
    }

    public override func selectAll(_ sender: Any?) {
        guard allowsMultipleSelection, numberOfRows > 0, !ignoresUserInput else { return }
        // On the first and last rows, not on group headers.
        let rows = 0..<numberOfRows
        anchorRow = rows.first { !isGroupRow($0) } ?? 0
        cursorRow = rows.last { !isGroupRow($0) } ?? numberOfRows - 1
        setSelection(IndexSet(integersIn: 0..<numberOfRows), byUser: true)
    }

    public override func scrollPageUp(_ sender: Any?) {
        scrollByPage(-1, along: .vertical)
    }

    public override func scrollPageDown(_ sender: Any?) {
        scrollByPage(1, along: .vertical)
    }

    public override func scrollToBeginningOfDocument(_ sender: Any?) {
        scrollToFraction(0, along: .vertical)
    }

    public override func scrollToEndOfDocument(_ sender: Any?) {
        scrollToFraction(1, along: .vertical)
    }

    // Tab moves focus on like other controls instead of beeping.
    // With navigation by cell, Tab moves the focused cell on instead.
    public override func insertTab(_ sender: Any?) {
        if moveFocusedCell(columns: 1, rows: 0) { return }
        window?.selectNextKeyView(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        if moveFocusedCell(columns: -1, rows: 0) { return }
        window?.selectPreviousKeyView(sender)
    }

    // Left and right arrows scroll the scrolling columns one column at a time
    // (or move the focused cell, with navigation by cell); on a group header or
    // a tree row they collapse and expand. Right to left they trade roles,
    // like in NSOutlineView: Left goes on, Right goes back and collapses.
    public override func moveLeft(_ sender: Any?) {
        isRightToLeft ? moveTowardEnd() : moveTowardStart()
    }

    public override func moveRight(_ sender: Any?) {
        isRightToLeft ? moveTowardStart() : moveTowardEnd()
    }

    /// Toward the leading side: collapse, the previous column.
    private func moveTowardStart() {
        if collapseKeyboardGroup(includingChildren: currentEventHasOption) { return }
        if collapseOrGoToParent(includingChildren: currentEventHasOption) { return }
        if moveFocusedCell(columns: -1, rows: 0) { return }
        scrollToColumn(forward: false)
    }

    /// Toward the trailing side: expand, the next column.
    private func moveTowardEnd() {
        if expandKeyboardGroup(includingChildren: currentEventHasOption) { return }
        if expandOrGoToChild(includingChildren: currentEventHasOption) { return }
        if moveFocusedCell(columns: 1, rows: 0) { return }
        scrollToColumn(forward: true)
    }

    /// Scrolls so that the previous or next scrolling column starts at the
    /// leading edge of the scrolling area.
    private func scrollToColumn(forward: Bool) {
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
        revealScroller(.horizontal)
    }

    // MARK: Deleting rows

    public override func deleteBackward(_ sender: Any?) {
        if !deleteSelectedRows() { super.deleteBackward(sender) }
    }

    public override func deleteForward(_ sender: Any?) {
        if !deleteSelectedRows() { super.deleteForward(sender) }
    }

    /// Edit > Delete.
    @objc public func delete(_ sender: Any?) {
        deleteSelectedRows()
    }

    /// The selected rows go to `rowDeletion`, if it's set; whether they did.
    @discardableResult
    func deleteSelectedRows() -> Bool {
        guard let rowDeletion, !ignoresUserInput, !selectedRowIndexes.isEmpty else { return false }
        rowDeletion(selectedRowIndexes)
        return true
    }

    // MARK: Type select

    public override func insertText(_ insertString: Any) {
        let typed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        // Typing on a focused editable cell edits it, like a spreadsheet.
        if navigatesByCell, let cell = focusedCell, !typed.trimmingCharacters(in: .whitespaces).isEmpty,
           editCell(row: cell.row, columnID: cell.columnID, text: typed) {
            return
        }
        guard allowsTypeSelect else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // The delegate may let the key go on, like NSTableView's.
        if let event = typeSelectEvent, let delegate {
            let search = typeSelectBuffer.isEmpty || now - lastTypeSelectTime > Self.typeSelectPause ? nil : typeSelectBuffer
            guard delegate.tableView(self, shouldTypeSelectFor: event, withCurrentSearch: search) else {
                super.keyDown(with: event)
                return
            }
        }
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
            NSSound.beep()
            return
        }
        anchorRow = row
        cursorRow = row
        setSelection([row], byUser: true)
        scrollDisplayRowToVisible(row)
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

    private func moveSelection(by delta: Int, extending: Bool) {
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
