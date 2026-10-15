#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Navigating by cell and editing cells, like a spreadsheet:
// - With `navigatesByCell`, a focused cell (`focusedCell`) moves with the
//   arrow keys and Tab, and a click focuses the cell clicked. A ring shows it
//   once the keys move it (a click hides the ring, as does the table losing
//   the focus).
// - Columns that are `isEditable` edit in place: Return, a double click, or
//   typing on a focused cell opens a text field over the cell; Return and Tab
//   commit (moving down or on), Escape cancels. The text is parsed by the
//   column's format, the data source receives the value
//   (`tableView(_:setValue:for:row:)`), the row is read again, and the change
//   can be undone.
// On the iPad a second tap edits, the text field is UIKit's, and the
// keyboard's Return commits (Tab and Escape with a hardware keyboard).

extension NGTableView {
    // MARK: Focused cell

    /// The visible columns in display order.
    private var navigableColumns: [NGTableColumn] {
        columnLayout.allColumns
    }

    /// Moves the focused cell by columns (Left, Right, Tab) and rows (Up,
    /// Down), keeping it in view; returns `false` without a focused cell.
    @discardableResult
    func moveFocusedCell(columns: Int, rows: Int) -> Bool {
        guard navigatesByCell else { return false }
        let columns0 = navigableColumns
        guard !columns0.isEmpty, numberOfRows > 0 else { return false }
        var columnIndex = focusedCell.flatMap { cell in columns0.firstIndex { $0.id == cell.columnID } } ?? 0
        var displayRow = focusedCell.flatMap { self.displayRow(forSourceRow: $0.row) } ?? cursorRow ?? 0
        columnIndex = min(max(columnIndex + columns, 0), columns0.count - 1)
        displayRow = min(max(displayRow + rows, 0), numberOfRows - 1)
        // Group headers have no cells: step over them.
        while isGroupRow(displayRow), displayRow + (rows < 0 ? -1 : 1) >= 0, displayRow + (rows < 0 ? -1 : 1) < numberOfRows {
            displayRow += rows < 0 ? -1 : 1
        }
        guard !isGroupRow(displayRow) else { return true }
        focusCell(displayRow: displayRow, columnID: columns0[columnIndex].id)
        showsFocusRing = true
        return true
    }

    /// Focuses a cell: selects its row (like moving the cursor) and scrolls it into view.
    func focusCell(displayRow: Int, columnID: String) {
        let row = sourceRow(displayRow)
        guard row >= 0 else { return }
        focusedCell = NGCellPosition(row: row, columnID: columnID)
        selectedCellRange = nil
        anchorRow = displayRow
        cursorRow = displayRow
        setSelection([displayRow], byUser: true)
        scrollDisplayRowToVisible(displayRow)
        if let index = tableColumns.firstIndex(where: { $0.id == columnID }) { scrollColumnToVisible(index) }
    }

    /// The ring around the focused cell (four edges), in the table's coordinates.
    func appendFocusRing(style: MetalStyle, scale: CGFloat, to quads: inout [NGMetalQuad]) {
        guard navigatesByCell, showsFocusRing, hasFocus, keyboardGroup == nil, let cell = focusedCell, editor == nil,
              let frame = frameOfCell(row: cell.row, columnID: cell.columnID) else { return }
        let color = style.color(hasFocus ? .keyboardFocusIndicatorColor : .tertiaryLabelColor)
        let width: CGFloat = 2
        let rows = CGRect(x: 0, y: layoutMetrics.headerHeight, width: bounds.width,
                          height: max(0, bounds.height - layoutMetrics.headerHeight - layoutMetrics.summaryHeight))
        let ring = frame.insetBy(dx: 1, dy: 1)
        for edge in [CGRect(x: ring.minX, y: ring.minY, width: ring.width, height: width),
                     CGRect(x: ring.minX, y: ring.maxY - width, width: ring.width, height: width),
                     CGRect(x: ring.minX, y: ring.minY, width: width, height: ring.height),
                     CGRect(x: ring.maxX - width, y: ring.minY, width: width, height: ring.height)] {
            quads.append(NGMetalRenderer.rectangle(edge, scale: scale, color: color, clip: rows))
        }
    }

    // MARK: Editing

    /// Whether a cell can be edited: an editable column, and the delegate agrees.
    func canEdit(row: Int, columnID: String) -> Bool {
        guard !ignoresUserInput, row >= 0, row < numberOfSourceRows,
              let column = tableColumns.first(where: { $0.id == columnID }), column.isEditable else { return false }
        return delegate?.tableView(self, shouldEdit: column, row: row) ?? true
    }

    /// Starts editing a cell, like NSTableView's `editColumn(_:row:with:select:)`:
    /// a text field over the cell with its value as displayed (`text` replaces
    /// it, e.g. what the user started typing). Returns whether editing began.
    @discardableResult
    public func editCell(row: Int, columnID: String, text: String? = nil) -> Bool {
        endEditing(committing: true)
        guard canEdit(row: row, columnID: columnID), let dataSource,
              let column = tableColumns.first(where: { $0.id == columnID }),
              let displayRow = displayRow(forSourceRow: row) else { return false }
        // Check boxes toggle; lists open their menu (typing doesn't).
        if isCheckBox(row: row, column: column) { return toggleCheckBox(row: row, columnID: columnID) }
        if column.editChoices != nil {
            guard text == nil else { return false }
            return showChoiceMenu(row: row, column: column)
        }
        scrollDisplayRowToVisible(displayRow)
        if let index = tableColumns.firstIndex(where: { $0.id == columnID }) { scrollColumnToVisible(index) }
        layoutSubtreeIfNeeded()
        guard let frame = frameOfCell(row: row, columnID: columnID) else { return false }
        let value = dataSource.tableView(self, valueFor: column, row: row)
        let (field, clip) = makeCellEditor(frame: frame, text: text ?? Self.editingText(of: value, format: column.format, locale: formattingLocale),
                                           column: column)
        editor = NGCellEditor(field: field, clip: clip, ref: rowRef(ofRow: row), columnID: columnID, originalValue: value)
        layoutCellEditor()
        focusedCell = NGCellPosition(row: row, columnID: columnID)
        #if os(macOS)
        window?.makeFirstResponder(field)
        if text != nil {
            // Typed over: the caret after the text, like a spreadsheet.
            field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
        #else
        field.becomeFirstResponder()
        // The whole text selected, to type over (typed over already: the caret after it).
        if text == nil { field.selectAll(nil) }
        #endif
        setNeedsMetalFrame()
        return true
    }

    #if os(macOS)
    /// The text field over a cell, in a view clipped to the rows its region
    /// shows, so a cell scrolled partly under the header, the summary row or
    /// frozen columns isn't edited over them (see `layoutCellEditor`).
    private func makeCellEditor(frame: CGRect, text: String, column: NGTableColumn) -> (NGCellEditorField, NGPlatformView) {
        let field = NGCellEditorField(frame: frame.insetBy(dx: 1, dy: 1))
        let clip = NGFlippedView()
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        field.stringValue = text
        field.font = column.isNumeric ? metalStyle.digitFont : metalStyle.textFont
        field.alignment = column.alignment.textAlignment(isNumeric: column.isNumeric, layoutDirection: userInterfaceLayoutDirection)
        field.isBordered = false
        field.focusRingType = .exterior
        field.drawsBackground = true
        field.backgroundColor = metalStyle.background
        field.delegate = editorDelegate
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        clip.addSubview(field)
        addSubview(clip, positioned: .below, relativeTo: headerBackground)
        return (field, clip)
    }
    #else
    /// The text field over a cell, in a view clipped to the rows (see `layoutCellEditor`).
    private func makeCellEditor(frame: CGRect, text: String, column: NGTableColumn) -> (NGCellEditorField, NGPlatformView) {
        let field = NGCellEditorField(frame: frame.insetBy(dx: 1, dy: 1))
        let clip = UIView()
        clip.clipsToBounds = true
        field.text = text
        field.font = column.isNumeric ? metalStyle.digitFont : metalStyle.textFont
        field.textAlignment = column.alignment.textAlignment(isNumeric: column.isNumeric, layoutDirection: layoutDirection)
        field.backgroundColor = metalStyle.background
        field.borderStyle = .none
        field.layer.borderColor = UIColor.tintColor.cgColor
        field.layer.borderWidth = 2
        field.autocorrectionType = .no
        field.returnKeyType = .done
        if column.isNumeric { field.keyboardType = .numbersAndPunctuation }
        field.delegate = editorDelegate
        field.table = self
        clip.addSubview(field)
        insertSubview(clip, belowSubview: headerBackground)
        return (field, clip)
    }
    #endif

    #if os(macOS)
    /// Starts editing a cell by column index, like NSTableView's: `select`
    /// selects the text, otherwise the caret goes after it. The event is
    /// ignored (the text field takes the clicks). Unlike NSTableView, the row
    /// needn't be selected.
    public func editColumn(_ column: Int, row: Int, with event: NSEvent?, select: Bool) {
        let all = tableColumns
        guard column >= 0, column < all.count, editCell(row: row, columnID: all[column].id),
              !select, let field = editor?.field else { return }
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }
    #endif

    /// The data source row whose cell is being edited in a text field, or
    /// -1, like NSTableView's: it follows the record as rows move.
    public var editedRow: Int {
        guard let editor else { return -1 }
        return row(of: editor.ref)
    }

    /// The index in ``tableColumns`` of the column being edited in a text
    /// field, or -1, like NSTableView's.
    public var editedColumn: Int {
        guard let editor else { return -1 }
        return tableColumns.firstIndex { $0.id == editor.columnID } ?? -1
    }

    /// Ends editing and throws the text away, like `NSControl`'s
    /// `abortEditing()` on an NSTableView: the cell keeps its value and the
    /// table takes the keyboard. Returns whether a cell was being edited.
    @discardableResult
    public func abortEditing() -> Bool {
        guard editor != nil else { return false }
        endEditing(committing: false)
        return true
    }

    /// Ends editing: commits the text (parsed by the column's format) or
    /// throws it away.
    func endEditing(committing: Bool) {
        guard let editor = editor.take() else { return }
        #if os(macOS)
        let text = editor.field.stringValue
        editor.field.delegate = nil
        editor.clip.removeFromSuperview()
        window?.makeFirstResponder(self)
        #else
        let text = editor.field.text ?? ""
        let hadKeyboard = editor.field.isFirstResponder
        editor.field.delegate = nil
        editor.clip.removeFromSuperview()
        // The keys go back to the table (Return and Tab move on from there).
        if hadKeyboard { _ = becomeFirstResponder() }
        #endif
        setNeedsMetalFrame()
        // Text left as it was is no edit (a date shown without its time
        // would otherwise lose it).
        guard committing, let column = tableColumns.first(where: { $0.id == editor.columnID }),
              text != Self.editingText(of: editor.originalValue, format: column.format, locale: formattingLocale),
              let value = Self.value(from: text, format: column.format, like: editor.originalValue, locale: formattingLocale),
              value != editor.originalValue else { return }
        // The record may have moved while it was edited (a live feed): found by its reference.
        let row = row(of: editor.ref)
        guard row >= 0 else { return }
        setValue(value, row: row, column: column, undoValue: editor.originalValue)
    }

    /// Keeps the editor over its cell as the table scrolls, columns resize
    /// and rows move (called whenever the rows are placed): clipped away
    /// while the cell is out of view (it keeps the keyboard, like
    /// NSTableView's), ended when its column is hidden.
    func layoutCellEditor() {
        guard let editor else { return }
        guard columnLayout.allColumns.contains(where: { $0.id == editor.columnID }) else {
            // Not in the middle of a layout pass: committing reads the row again.
            Task { @MainActor [weak self] in
                if self?.editor?.field === editor.field { self?.endEditing(committing: true) }
            }
            return
        }
        guard let placement = cellPlacement(row: row(of: editor.ref), columnID: editor.columnID),
              !placement.isRegionHidden else {
            // Its row isn't shown (filtered out, in a collapsed group).
            editor.field.setFrameOrigin(CGPoint(x: 0, y: -10 * max(editor.field.frame.height, 1)))
            return
        }
        editor.clip.frame = placement.visible
        editor.field.frame = placement.frame.insetBy(dx: 1, dy: 1)
            .offsetBy(dx: -placement.visible.minX, dy: -placement.visible.minY)
    }

}

/// An open editor: the field, and which cell it edits.
struct NGCellEditor {
    let field: NGCellEditorField
    /// The view the field is in, clipped to where rows show.
    let clip: NGPlatformView
    /// The edited record (rows may move while it's edited).
    let ref: NGRowRef
    let columnID: String
    let originalValue: NGCellValue
}

#if os(macOS)
/// The text field over an edited cell.
final class NGCellEditorField: NSTextField {}

/// Ends editing on Return (moving down), Tab (moving on) and Escape.
@MainActor
final class NGCellEditorDelegate: NSObject, NSTextFieldDelegate {
    weak var table: NGTableView?

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let table else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            table.endEditing(committing: true)
            table.moveFocusedCell(columns: 0, rows: 1)
            return true
        case #selector(NSResponder.insertTab(_:)):
            table.endEditing(committing: true)
            table.moveFocusedCell(columns: 1, rows: 0)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            table.endEditing(committing: true)
            table.moveFocusedCell(columns: -1, rows: 0)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            table.endEditing(committing: false)
            return true
        default:
            return false
        }
    }

    /// Clicking elsewhere commits.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let table, let field = notification.object as? NGCellEditorField, table.editor?.field === field else { return }
        table.endEditing(committing: true)
    }
}
#else
/// The text field over an edited cell: a hardware keyboard's Tab moves on
/// (Shift-Tab back), Escape throws the text away.
final class NGCellEditorField: UITextField {
    weak var table: NGTableView?

    override var keyCommands: [UIKeyCommand]? {
        let commands = [UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(nextCell)),
                        UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(previousCell)),
                        UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func nextCell() {
        table?.endEditing(committing: true)
        table?.moveFocusedCell(columns: 1, rows: 0)
    }

    @objc private func previousCell() {
        table?.endEditing(committing: true)
        table?.moveFocusedCell(columns: -1, rows: 0)
    }

    @objc private func cancel() { table?.endEditing(committing: false) }
}

/// Ends editing on Return (moving down); leaving the field commits.
@MainActor
final class NGCellEditorDelegate: NSObject, UITextFieldDelegate {
    weak var table: NGTableView?

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let table else { return true }
        table.endEditing(committing: true)
        table.moveFocusedCell(columns: 0, rows: 1)
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard let table, table.editor?.field === textField else { return }
        table.endEditing(committing: true)
    }
}
#endif
#endif
