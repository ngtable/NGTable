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
        // A number key sets a focused editable rating; Space presses a focused link.
        if event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
           let key = event.charactersIgnoringModifiers, actOnFocusedCell(key: key) {
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
        return !isTypeSelecting
    }


    public override func moveUp(_ sender: Any?) {
        moveVertically(by: -1)
    }

    public override func moveDown(_ sender: Any?) {
        moveVertically(by: 1)
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
        extendVertically(by: -1)
    }

    public override func moveDownAndModifySelection(_ sender: Any?) {
        extendVertically(by: 1)
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
        selectAllRowsByUser()
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

    private func moveTowardStart() {
        moveTowardStart(includingChildren: currentEventHasOption)
    }

    private func moveTowardEnd() {
        moveTowardEnd(includingChildren: currentEventHasOption)
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

    // MARK: Type select

    public override func insertText(_ insertString: Any) {
        let typed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        typeSelect(typed) { [typeSelectEvent] search in
            // The delegate may let the key go on, like NSTableView's.
            guard let event = typeSelectEvent, let delegate = self.delegate else { return true }
            guard delegate.tableView(self, shouldTypeSelectFor: event, withCurrentSearch: search) else {
                super.keyDown(with: event)
                return false
            }
            return true
        }
    }

}
#endif
