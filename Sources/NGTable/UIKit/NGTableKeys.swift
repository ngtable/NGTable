#if os(iOS)
import UIKit

// A hardware keyboard on the iPad, the Mac's keys: arrows move the selection
// (Shift extends it; Left and Right open and close groups and tree rows, or
// scroll by a column), Page Up/Down and Home/End scroll, Command-A selects
// every row (Command-C copies, as the edit menu's Copy), Return edits the
// focused cell or sends `returnAction`, Tab moves the focused cell, Escape
// drops a range of cells, Delete hands the rows to `rowDeletion`, and typing
// edits a focused cell or selects by type select. The table takes the
// keyboard when tapped.

extension NGTableView {
    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key,
                  handleKey(key.keyCode, modifiers: key.modifierFlags, characters: key.characters,
                            ignoringModifiers: key.charactersIgnoringModifiers) else {
                unhandled.insert(press)
                continue
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    /// A key pressed (what `UIKey` tells); whether the table took it.
    @discardableResult
    func handleKey(_ keyCode: UIKeyboardHIDUsage, modifiers flags: UIKeyModifierFlags = [], characters: String = "",
                   ignoringModifiers: String? = nil) -> Bool {
        guard !ignoresUserInput, !isEditingCell else { return false }
        let modifiers = flags.intersection([.shift, .command, .control, .alternate])
        let shift = modifiers == .shift
        switch keyCode {
        case .keyboardUpArrow where modifiers.isEmpty || shift:
            shift ? extendVertically(by: -1) : moveVertically(by: -1)
        case .keyboardDownArrow where modifiers.isEmpty || shift:
            shift ? extendVertically(by: 1) : moveVertically(by: 1)
        case .keyboardLeftArrow where modifiers.isEmpty || modifiers == .alternate || shift:
            if shift { return extendCellRange(columns: isRightToLeft ? 1 : -1, rows: 0) }
            isRightToLeft ? moveTowardEnd(includingChildren: modifiers == .alternate) : moveTowardStart(includingChildren: modifiers == .alternate)
        case .keyboardRightArrow where modifiers.isEmpty || modifiers == .alternate || shift:
            if shift { return extendCellRange(columns: isRightToLeft ? -1 : 1, rows: 0) }
            isRightToLeft ? moveTowardStart(includingChildren: modifiers == .alternate) : moveTowardEnd(includingChildren: modifiers == .alternate)
        case .keyboardPageUp:
            scrollByPage(-1)
        case .keyboardPageDown:
            scrollByPage(1)
        case .keyboardHome:
            setContentOffset(CGPoint(x: contentOffset.x, y: 0))
        case .keyboardEnd:
            setContentOffset(CGPoint(x: contentOffset.x, y: layoutMetrics.maxOffset.y))
        case .keyboardReturnOrEnter, .keypadEnter:
            return pressReturn()
        case .keyboardTab where modifiers.isEmpty || shift:
            return moveFocusedCell(columns: shift ? -1 : 1, rows: 0)
        case .keyboardEscape:
            return pressEscape()
        case .keyboardDeleteOrBackspace, .keyboardDeleteForward:
            return deleteSelectedRows()
        case .keyboardA where modifiers == .command:
            selectAllRowsByUser()
        default:
            return typeKey(characters, ignoringModifiers: ignoringModifiers ?? characters, modifiers: modifiers)
        }
        return true
    }

    /// Return edits the focused cell, when it's editable; otherwise it sends
    /// `returnAction` if there is one.
    private func pressReturn() -> Bool {
        if navigatesByCell, let cell = focusedCell, editCell(row: cell.row, columnID: cell.columnID) { return true }
        guard let returnAction, !selectedRowIndexes.isEmpty else { return false }
        clickedRow = -1
        isSendingReturnAction = true
        defer { isSendingReturnAction = false }
        send(returnAction)
        return true
    }

    /// Escape drops a range of cells (the focused cell stays), or hides the focused cell's ring.
    private func pressEscape() -> Bool {
        guard selectedCellRange != nil else {
            guard navigatesByCell, showsFocusRing else { return false }
            showsFocusRing = false
            return true
        }
        selectedCellRange = nil
        if let cell = focusedCell, let row = displayRow(forSourceRow: cell.row) { setSelection([row], byUser: true) }
        return true
    }

    /// A key that types: the focused cell's (Space, a rating's digit),
    /// editing, or type select. A space outside a search isn't the table's.
    private func typeKey(_ characters: String, ignoringModifiers: String, modifiers: UIKeyModifierFlags) -> Bool {
        guard modifiers.isDisjoint(with: [.command, .control]), !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        if modifiers.isDisjoint(with: [.alternate]), actOnFocusedCell(key: ignoringModifiers) { return true }
        if characters == " ", !isTypeSelecting { return false }
        typeSelect(characters)
        return true
    }

    /// Page Up and Page Down: a screenful of rows.
    func scrollByPage(_ direction: CGFloat) {
        let metrics = layoutMetrics
        let page = max(rowHeight, metrics.bodyHeight - metrics.bottomInset - rowHeight)
        setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y + direction * page))
    }
}
#endif
