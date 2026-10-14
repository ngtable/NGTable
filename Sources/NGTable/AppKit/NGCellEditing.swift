#if os(macOS)
import AppKit

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
        let rows = NSRect(x: 0, y: layoutMetrics.headerHeight, width: bounds.width,
                          height: max(0, bounds.height - layoutMetrics.headerHeight - layoutMetrics.summaryHeight))
        let ring = frame.insetBy(dx: 1, dy: 1)
        for edge in [NSRect(x: ring.minX, y: ring.minY, width: ring.width, height: width),
                     NSRect(x: ring.minX, y: ring.maxY - width, width: ring.width, height: width),
                     NSRect(x: ring.minX, y: ring.minY, width: width, height: ring.height),
                     NSRect(x: ring.maxX - width, y: ring.minY, width: width, height: ring.height)] {
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
        let field = NGCellEditorField(frame: frame.insetBy(dx: 1, dy: 1))
        // In a view clipped to the rows its region shows, so a cell scrolled
        // partly under the header, the summary row or frozen columns isn't
        // edited over them (see `layoutCellEditor`).
        let clip = NGFlippedView()
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        field.stringValue = text ?? Self.editingText(of: value, format: column.format, locale: formattingLocale)
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
        editor = NGCellEditor(field: field, clip: clip, ref: rowRef(ofRow: row), columnID: columnID, originalValue: value)
        layoutCellEditor()
        focusedCell = NGCellPosition(row: row, columnID: columnID)
        window?.makeFirstResponder(field)
        if text != nil {
            // Typed over: the caret after the text, like a spreadsheet.
            field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
        setNeedsMetalFrame()
        return true
    }

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
        let text = editor.field.stringValue
        editor.field.delegate = nil
        editor.clip.removeFromSuperview()
        window?.makeFirstResponder(self)
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
            editor.field.setFrameOrigin(NSPoint(x: 0, y: -10 * max(editor.field.frame.height, 1)))
            return
        }
        editor.clip.frame = placement.visible
        editor.field.frame = placement.frame.insetBy(dx: 1, dy: 1)
            .offsetBy(dx: -placement.visible.minX, dy: -placement.visible.minY)
    }

    /// Gives the data source a cell's new value, reads the row again and
    /// registers the change for Undo (its undo sets the old value back).
    func setValue(_ value: NGCellValue, row: Int, column: NGTableColumn, undoValue: NGCellValue) {
        guard let dataSource, row < numberOfSourceRows else { return }
        dataSource.tableView(self, setValue: value, for: column, row: row)
        if let index = tableColumns.firstIndex(where: { $0.id == column.id }) {
            // The user's own edit moves its record at once, under the pointer too.
            isApplyingUserEdit = true
            defer { isApplyingUserEdit = false }
            reloadData(forRowIndexes: [row], columnIndexes: [index])
        }
        // The record may have moved by the time it's undone: found by its
        // reference (exact, also among rows sharing an identity), or after a
        // reload (references go) by its identity if rows have one; a record
        // that is gone isn't touched, nor another data source's.
        let identifier = identifier(forSourceRow: row)
        let ref = rowRef(ofRow: row)
        undoManager?.registerUndo(withTarget: self) { [weak source = dataSource as AnyObject] table in
            guard let source, table.dataSource as AnyObject === source else { return }
            var current = table.row(of: ref)
            if current < 0, ref.epoch != table.rowHandles.epoch, let identifier { current = table.row(forIdentifier: identifier) }
            guard current >= 0 else { return }
            table.setValue(undoValue, row: current, column: column, undoValue: value)
        }
        undoManager?.setActionName(String(localized: "Edit Cell", bundle: .module, comment: "Undo menu: a cell's value changed."))
    }

    /// The text a value is edited as: numbers without grouping, as typed.
    static func editingText(of value: NGCellValue, format: NGValueFormat, locale: Locale = .current) -> String {
        switch value {
        case .number(let number):
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.maximumFractionDigits = 10
            if case .percent = format { return (formatter.string(from: NSNumber(value: number * 100)) ?? "") + "%" }
            return formatter.string(from: NSNumber(value: number)) ?? ""
        default:
            return format.string(for: value, locale: locale)
        }
    }

    /// The value typed text means for a column: numbers for number formats
    /// (and where the cell held a number), dates for date columns, text
    /// otherwise; `nil` if it isn't a valid number or date where one is due.
    static func value(from text: String, format: NGValueFormat, like original: NGCellValue, locale: Locale = .current) -> NGCellValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        var wantsNumber = format.isNumeric
        if case .number = original { wantsNumber = true }
        if wantsNumber {
            // Letters other than the currency's (and an exponent's e) make it
            // not a number: "10 or 20" isn't 1020.
            var letters = trimmed
            if case .currency(let code) = format {
                let formatter = NumberFormatter()
                formatter.numberStyle = .currency
                formatter.currencyCode = code
                for symbol in [code, formatter.currencySymbol ?? ""] where !symbol.isEmpty {
                    letters = letters.replacingOccurrences(of: symbol, with: "", options: .caseInsensitive)
                }
            }
            guard !letters.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) && $0 != "e" && $0 != "E" }) else {
                return nil
            }
            // Without the currency's code and symbol (a code's E isn't an exponent).
            var cleaned = letters
            var isPercent = false
            if case .percent = format { isPercent = true }
            if cleaned.hasSuffix("%") {
                isPercent = true
                cleaned.removeLast()
            }
            // Currency symbols and spaces aside.
            cleaned = String(cleaned.unicodeScalars.filter {
                CharacterSet.decimalDigits.contains($0) || ",.-−+eE".unicodeScalars.contains($0)
            }).replacingOccurrences(of: "−", with: "-")
            // The user's locale first ("1 234,5"), then the common English
            // way ("1,234.5"), strictly (a lenient reading takes "1300.50" in
            // Swedish or German for 130050), then leniently, then a plain
            // number with either decimal mark.
            func parse(_ locale: Locale, lenient: Bool) -> Double? {
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .decimal
                formatter.isLenient = lenient
                return formatter.number(from: cleaned)?.doubleValue
            }
            let english = Locale(identifier: "en_US")
            let number = parse(locale, lenient: false) ?? parse(english, lenient: false)
                ?? parse(locale, lenient: true) ?? parse(english, lenient: true)
                ?? Double(cleaned.replacingOccurrences(of: ",", with: "."))
            guard let number else { return nil }
            return .number(isPercent ? number / 100 : number)
        }
        if case .date(let includesTime) = format {
            // As displayed first (`string(for:)`), then the usual styles.
            let shown = Date.FormatStyle(date: .abbreviated, time: includesTime ? .shortened : .omitted).locale(.current)
            if let date = try? shown.parse(trimmed) { return .date(date) }
            for style in [DateFormatter.Style.medium, .short, .long] {
                let formatter = DateFormatter()
                formatter.dateStyle = style
                formatter.timeStyle = includesTime ? .short : .none
                formatter.isLenient = true
                if let date = formatter.date(from: trimmed) { return .date(date) }
            }
            return nil
        }
        return .text(trimmed)
    }
}

/// An open editor: the field, and which cell it edits.
struct NGCellEditor {
    let field: NGCellEditorField
    /// The view the field is in, clipped to where rows show.
    let clip: NSView
    /// The edited record (rows may move while it's edited).
    let ref: NGRowRef
    let columnID: String
    let originalValue: NGCellValue
}

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
#endif
