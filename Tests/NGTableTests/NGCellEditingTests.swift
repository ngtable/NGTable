#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Navigating by cell and editing cells in place.
@Suite("Cell editing")
@MainActor
struct NGCellEditingTests {
    @MainActor
    final class Records: NGTableViewDataSource, NGTableViewDelegate {
        var names = (0..<20).map { "Campaign \($0)" }
        var budgets = (0..<20).map { Double($0) * 10 }
        var lockedRows: Set<Int> = []
        func numberOfRows(in tableView: NGTableView) -> Int { names.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            column.id == "name" ? .text(names[row]) : column.id == "budget" ? .number(budgets[row]) : .text("x")
        }
        func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
            switch (column.id, value) {
            case ("name", .text(let text)): names[row] = text
            case ("budget", .number(let number)): budgets[row] = number
            case ("budget", .empty): budgets[row] = 0
            default: break
            }
        }
        func tableView(_ tableView: NGTableView, shouldEdit tableColumn: NGTableColumn, row: Int) -> Bool {
            !lockedRows.contains(row)
        }
    }

    private func makeTable(_ records: Records) -> (NGTableView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200, isEditable: true)),
                         .column(NGTableColumn("budget", title: "Budget", width: 120, format: .currency(code: "USD"), isEditable: true)),
                         .column(NGTableColumn("note", title: "Note", width: 120))]
        window.contentView = table
        table.dataSource = records
        table.delegate = records
        table.navigatesByCell = true
        table.layoutSubtreeIfNeeded()
        window.makeFirstResponder(table)
        return (table, window)
    }

    /// What's edited, like NSTableView's `editedRow` and `editedColumn`
    /// (the row follows its record), `abortEditing()` throwing the text
    /// away, and `editColumn(_:row:with:select:)` from code.
    @Test func theEditedCellAndAbortingIt() throws {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        #expect(table.editedRow == -1 && table.editedColumn == -1)
        #expect(!table.abortEditing())
        table.editColumn(1, row: 3, with: nil, select: true)
        #expect(table.editedRow == 3 && table.editedColumn == 1)
        let field = try #require(table.editor?.field)
        #expect(field.currentEditor()?.selectedRange == NSRange(location: 0, length: (field.stringValue as NSString).length))
        // A record inserted above: the edited one is a row further down.
        records.names.insert("New", at: 0)
        records.budgets.insert(1, at: 0)
        table.insertRows(at: [0])
        #expect(table.editedRow == 4)
        field.stringValue = "999"
        #expect(table.abortEditing())
        #expect(table.editedRow == -1 && table.editedColumn == -1 && table.editor == nil)
        #expect(records.budgets[4] == 30)
        #expect(window.firstResponder === table)
        // Without `select`, the caret goes after the text.
        table.editColumn(0, row: 2, with: nil, select: false)
        let name = try #require(table.editor?.field)
        #expect(name.currentEditor()?.selectedRange == NSRange(location: (name.stringValue as NSString).length, length: 0))
        // Not editable, or out of range: nothing.
        table.abortEditing()
        table.editColumn(2, row: 2, with: nil, select: true)
        table.editColumn(7, row: 2, with: nil, select: true)
        #expect(table.editedRow == -1)
    }

    @Test func arrowsAndTabMoveTheFocusedCell() {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        table.moveDown(nil)
        #expect(table.focusedCell == NGCellPosition(row: 1, columnID: "name"))
        table.moveRight(nil)
        table.insertTab(nil)
        #expect(table.focusedCell == NGCellPosition(row: 1, columnID: "note"))
        table.moveRight(nil)   // At the last column: stays.
        #expect(table.focusedCell?.columnID == "note")
        table.insertBacktab(nil)
        table.moveUp(nil)
        #expect(table.focusedCell == NGCellPosition(row: 0, columnID: "budget"))
        #expect(table.selectedRowIndexes == [0])
    }

    /// The field stays over its cell as the table scrolls, the column
    /// resizes and the record moves; it hides out of view and ends with its
    /// column.
    @Test func theEditorFollowsItsCell() async throws {
        let records = Records()
        records.names = (0..<200).map { "Campaign \($0)" }
        records.budgets = (0..<200).map { Double($0) }
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        #expect(table.editCell(row: 3, columnID: "budget"))
        let editor = try #require(table.editor)
        func fieldFrame() -> NSRect { table.convert(editor.field.frame, from: editor.clip) }
        func expectOverCell(_ row: Int, _ comment: Comment) {
            guard let cell = table.frameOfCell(row: row, columnID: "budget") else {
                Issue.record("no cell: \(comment)")
                return
            }
            #expect(fieldFrame() == cell.insetBy(dx: 1, dy: 1), comment)
            #expect(table.isEditingCell, comment)
        }
        expectOverCell(3, "opened")
        table.setContentOffset(CGPoint(x: 0, y: 48))
        expectOverCell(3, "scrolled")
        table.setWidth(300, forColumnID: "name")
        table.layoutSubtreeIfNeeded()
        expectOverCell(3, "resized")
        // The record moves (rows inserted above it).
        records.names.insert(contentsOf: ["N0", "N1"], at: 0)
        records.budgets.insert(contentsOf: [0, 0], at: 0)
        table.insertRows(at: [0, 1])
        expectOverCell(5, "moved")
        // Out of view: clipped away (still editing), then back.
        table.setContentOffset(CGPoint(x: 0, y: table.rowHeight * 100))
        #expect(!editor.clip.frame.intersects(table.convert(editor.field.frame, from: editor.clip)))
        #expect(table.isEditingCell)
        table.setContentOffset(.zero)
        expectOverCell(5, "back")
        // Its column hidden: the edit ends (committed).
        editor.field.stringValue = "77"
        table.hiddenColumnIDs = ["budget"]
        table.layoutSubtreeIfNeeded()
        try await eventually { !table.isEditingCell }
        #expect(!table.isEditingCell)
        #expect(records.budgets[5] == 77)
    }

    /// A cell being edited under a floating group header: the field is cut
    /// below the header, not drawn over it.
    @Test func theEditorStaysUnderFloatingHeaders() throws {
        let records = Records()
        records.names = (0..<200).map { $0 < 100 ? "A" : "B" }
        records.budgets = (0..<200).map { Double($0) }
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        table.rowGrouping = NGRowGrouping(columnID: "name")
        table.layoutSubtreeIfNeeded()
        #expect(table.editCell(row: 10, columnID: "budget"))
        let editor = try #require(table.editor)
        // Row 10 (display row 11, after its header) at the top: under the floating header.
        table.setContentOffset(CGPoint(x: 0, y: table.rowHeight * 11))
        table.layoutSubtreeIfNeeded()
        let headerBottom = table.layoutMetrics.headerHeight + table.rowHeight
        #expect(editor.clip.frame.minY >= headerBottom - 0.5, "clip at \(editor.clip.frame.minY), header ends at \(headerBottom)")
        #expect(table.isEditingCell)
    }

    @Test func editingCommitsCancelsAndUndoes() throws {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        // A name: typed over, committed.
        #expect(table.editCell(row: 2, columnID: "name"))
        #expect(table.isEditingCell)
        let field = try #require(table.editor?.field)
        #expect(field.stringValue == "Campaign 2")
        field.stringValue = "Renamed"
        table.endEditing(committing: true)
        #expect(records.names[2] == "Renamed")
        #expect(!table.isEditingCell)
        // A budget: parsed by the format, "$1,234.50" and plain numbers.
        table.editCell(row: 3, columnID: "budget")
        #expect(table.editor?.field.stringValue == "30")
        table.editor?.field.stringValue = "$1,234.50"
        table.endEditing(committing: true)
        #expect(records.budgets[3] == 1234.5)
        // Not a number: nothing changes. Escape: nothing changes.
        table.editCell(row: 3, columnID: "budget")
        table.editor?.field.stringValue = "abc"
        table.endEditing(committing: true)
        #expect(records.budgets[3] == 1234.5)
        table.editCell(row: 4, columnID: "name")
        table.editor?.field.stringValue = "Thrown away"
        table.endEditing(committing: false)
        #expect(records.names[4] == "Campaign 4")
        // Undo sets the old value back.
        let undo = try #require(table.undoManager)
        undo.undo()
        #expect(records.budgets[3] == 30)
        // Not editable: a plain column, or the delegate says no.
        #expect(!table.editCell(row: 1, columnID: "note"))
        records.lockedRows = [5]
        #expect(!table.editCell(row: 5, columnID: "name"))
        // Typing on the focused cell starts editing with what was typed.
        table.focusedCell = NGCellPosition(row: 6, columnID: "name")
        table.insertText("Q")
        #expect(table.editor?.field.stringValue == "Q")
        table.endEditing(committing: true)
        #expect(records.names[6] == "Q")
    }

    /// A key typed on a focused text cell opens its field and goes to the
    /// field's editor, where input methods compose (marked text), like
    /// typing into a spreadsheet's cell; the selection stays emphasized while
    /// the table's cell is edited. Arrows, Command keys and check boxes don't.
    @Test func typingGoesToTheCellsField() throws {
        /// The window's field editor, which notes the keys it gets.
        @MainActor final class Editors: NSObject, NSWindowDelegate {
            final class Recording: NSTextView {
                var keys: [String] = []
                override func keyDown(with event: NSEvent) {
                    keys.append(event.characters ?? "")
                    super.keyDown(with: event)
                }
            }
            let editor: Recording = {
                let editor = Recording()
                editor.isFieldEditor = true
                return editor
            }()
            func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { editor }
        }
        let records = Records()
        let (table, window) = makeTable(records)
        let editors = Editors()
        window.delegate = editors
        defer { withExtendedLifetime((window, records, editors)) {} }
        func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
        }
        table.selectRowIndexes([4], byExtendingSelection: false)
        table.focusedCell = NGCellPosition(row: 4, columnID: "name")
        #expect(table.hasEffectiveFocus)
        table.keyDown(with: key("q"))
        let field = try #require(table.editor?.field)
        let fieldEditor = try #require(window.firstResponder as? NSTextView)
        #expect(fieldEditor === field.currentEditor() && fieldEditor.inputContext != nil)
        #expect(field.stringValue == "q")
        #expect(fieldEditor === editors.editor && editors.editor.keys == ["q"])   // The key itself, not its text.
        fieldEditor.keyDown(with: key("r"))
        #expect(field.stringValue == "qr")
        #expect(table.hasEffectiveFocus)   // The field has the keyboard; the rows still look focused.
        table.endEditing(committing: true)
        #expect(records.names[4] == "qr" && table.hasEffectiveFocus)
        // Not for arrows or Command keys.
        table.keyDown(with: key(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)))
        table.keyDown(with: key("c", modifiers: .command))
        #expect(table.editor == nil)
    }

    /// Shift with the arrows makes a range of cells from the focused one;
    /// its rows are selected, Copy copies its block, Escape drops it.
    @Test func rangesOfCells() throws {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NGTableTests.cells.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        table.copyPasteboard = pasteboard
        table.focusCell(displayRow: 1, columnID: "name")
        table.moveRightAndModifySelection(nil)
        table.moveDownAndModifySelection(nil)
        table.moveDownAndModifySelection(nil)
        let range = try #require(table.selectedCellRange)
        #expect(range.anchor == NGCellPosition(row: 1, columnID: "name"))
        #expect(range.end == NGCellPosition(row: 3, columnID: "budget"))
        #expect(table.selectedRowIndexes == [1, 2, 3])
        table.copy(nil)
        let usd = NGValueFormat.currency(code: "USD")
        #expect(pasteboard.string(forType: .string) == (1...3).map {
            "Campaign \($0)\t\(usd.string(for: .number(Double($0) * 10)))"
        }.joined(separator: "\n"))
        // After a sort the range spans the rows between its corners as shown.
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "budget", ascending: false)]
        let bounds = try #require(table.selectedCellRange.flatMap(table.cellRangeBounds))
        #expect(bounds.rows.count == 3)
        // Escape drops it; a plain move too.
        table.cancelOperation(nil)
        #expect(table.selectedCellRange == nil)
        table.moveRightAndModifySelection(nil)
        #expect(table.selectedCellRange != nil)
        table.moveDown(nil)
        #expect(table.selectedCellRange == nil)
        // Only the focused cell: Copy copies it.
        table.copy(nil)
        #expect(pasteboard.string(forType: .string)?.contains("\t") == false)
    }

    /// Rows inserted and removed live: the focused cell, the cell range and
    /// the editor stay on their records (they don't jump to other rows).
    @Test func focusFollowsItsRecordThroughLiveUpdates() throws {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        table.focusCell(displayRow: 5, columnID: "budget")
        table.editCell(row: 8, columnID: "name")
        records.names.insert(contentsOf: ["New A", "New B"], at: 0)
        records.budgets.insert(contentsOf: [1, 2], at: 0)
        table.insertRows(at: [0, 1])
        #expect(table.focusedCell == NGCellPosition(row: 10, columnID: "name"))
        // The edit lands on its record, now two rows down.
        table.editor?.field.stringValue = "Edited"
        table.endEditing(committing: true)
        #expect(records.names[10] == "Edited")
        #expect(records.names[8] == "Campaign 6")
        // A range keeps its corners on their records too.
        table.focusCell(displayRow: 3, columnID: "name")
        table.moveDownAndModifySelection(nil)
        records.names.remove(at: 0)
        records.budgets.remove(at: 0)
        table.removeRows(at: [0])
        let range = try #require(table.selectedCellRange)
        #expect(range.anchor == NGCellPosition(row: 2, columnID: "name"))
        #expect(range.end == NGCellPosition(row: 3, columnID: "name"))
        // A removed record's cell is no longer focused.
        records.names.remove(at: 2)
        records.budgets.remove(at: 2)
        table.removeRows(at: [2])
        #expect(table.focusedCell == nil)
        // A full reload keeps the row indexes, like the selection.
        table.focusedCell = NGCellPosition(row: 4, columnID: "note")
        table.reloadData()
        #expect(table.focusedCell == NGCellPosition(row: 4, columnID: "note"))
    }

    /// Return on a cell that doesn't edit, Escape without a range or ring,
    /// Shift-Left and Shift-Right by row go on along the responder chain
    /// (NSView doesn't implement them: calling super raised an exception).
    @Test func unhandledCommandsGoOn() {
        @MainActor final class Catcher: NSResponder {
            var commands: [Selector] = []
            override func doCommand(by selector: Selector) { commands.append(selector) }
        }
        let records = Records()
        let (table, window) = makeTable(records)
        let catcher = Catcher()
        defer { withExtendedLifetime((window, records, catcher)) {} }
        table.nextResponder = catcher
        table.focusedCell = NGCellPosition(row: 1, columnID: "note")   // Not editable.
        table.insertNewline(nil)
        table.cancelOperation(nil)
        table.navigatesByCell = false
        table.moveLeftAndModifySelection(nil)
        table.moveRightAndModifySelection(nil)
        #expect(catcher.commands == [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)),
                                     #selector(NSResponder.moveLeftAndModifySelection(_:)),
                                     #selector(NSResponder.moveRightAndModifySelection(_:))])
    }

    @Test func parsing() {
        #expect(NGTableView.value(from: "$1,234.50", format: .currency(code: "USD"), like: .number(30)) == .number(1234.5))
        #expect(NGTableView.value(from: "25%", format: .percent(fractionDigits: 0), like: .number(0)) == .number(0.25))
        #expect(NGTableView.value(from: "12", format: .percent(fractionDigits: 0), like: .number(0)) == .number(0.12))
        #expect(NGTableView.value(from: "−5", format: .number(fractionDigits: 0), like: .empty) == .number(-5))
        #expect(NGTableView.value(from: "  ", format: .automatic, like: .text("a")) == .empty)
        #expect(NGTableView.value(from: "hello", format: .automatic, like: .text("a")) == .text("hello"))
        #expect(NGTableView.value(from: "7", format: .automatic, like: .number(1)) == .number(7))
        #expect(NGTableView.editingText(of: .number(0.25), format: .percent(fractionDigits: 1)) == "25%")
        // Words aren't numbers; the currency's code and symbol are fine.
        #expect(NGTableView.value(from: "10 or 20", format: .number(fractionDigits: 0), like: .number(1)) == nil)
        #expect(NGTableView.value(from: "USD 12", format: .currency(code: "USD"), like: .number(1)) == .number(12))
        #expect(NGTableView.value(from: "1e3", format: .number(fractionDigits: 0), like: .number(1)) == .number(1000))
        // Codes with an E, and a decimal point the user's locale doesn't use.
        #expect(NGTableView.value(from: "SEK 1,300.50", format: .currency(code: "SEK"), like: .number(1)) == .number(1300.5))
        #expect(NGTableView.value(from: "EUR 12", format: .currency(code: "EUR"), like: .number(1)) == .number(12))
        let swedish = Locale(identifier: "sv_SE"), german = Locale(identifier: "de_DE")
        #expect(NGTableView.value(from: "1300.50", format: .currency(code: "SEK"), like: .number(1), locale: swedish) == .number(1300.5))
        #expect(NGTableView.value(from: "1300,50", format: .currency(code: "SEK"), like: .number(1), locale: swedish) == .number(1300.5))
        #expect(NGTableView.value(from: "1.300,50", format: .number(fractionDigits: 2), like: .number(1), locale: german) == .number(1300.5))
        #expect(NGTableView.value(from: "1300.50", format: .number(fractionDigits: 2), like: .number(1), locale: german) == .number(1300.5))
        // A date with its time parses back as shown.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let format = NGValueFormat.date(includesTime: true)
        let shown = format.string(for: .date(date))
        guard case .date(let parsed)? = NGTableView.value(from: shown, format: format, like: .date(date)) else {
            Issue.record("\(shown) didn't parse")
            return
        }
        #expect(abs(parsed.timeIntervalSince(date)) < 60)
    }

    /// Return on a cell left as it was writes nothing (a date shown without
    /// its time kept it, and no Undo step is added).
    @Test func anUnchangedEditWritesNothing() throws {
        final class Dates: NGTableViewDataSource {
            var dates = [Date(timeIntervalSince1970: 1_700_001_380)]
            var writes = 0
            func numberOfRows(in tableView: NGTableView) -> Int { 1 }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .date(dates[row]) }
            func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) { writes += 1 }
        }
        let data = Dates()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = [.column(NGTableColumn("d", title: "D", width: 200, format: .date(includesTime: false), isEditable: true))]
        window.contentView = table
        table.dataSource = data
        table.layoutSubtreeIfNeeded()
        #expect(table.editCell(row: 0, columnID: "d"))
        table.endEditing(committing: true)
        #expect(data.writes == 0)
        withExtendedLifetime((window, data)) {}
    }
}
#endif
