#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Check boxes for editable Booleans and menus of choices.
@Suite("Choice editing")
@MainActor
struct NGChoiceEditingTests {
    static let statuses: [NGCellValue] = [.tags([NGTag("Active", color: .green)]), .tags([NGTag("Paused", color: .gray)])]

    @MainActor
    final class Records: NGTableViewDataSource {
        var names = (0..<10).map { "Campaign \($0)" }
        var isOn = (0..<10).map { $0.isMultiple(of: 2) }
        var statuses = (0..<10).map { _ in 0 }
        func numberOfRows(in tableView: NGTableView) -> Int { names.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            switch column.id {
            case "on": .bool(isOn[row])
            case "status": NGChoiceEditingTests.statuses[statuses[row]]
            default: .text(names[row])
            }
        }
        func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
            switch (column.id, value) {
            case ("on", .bool(let flag)): isOn[row] = flag
            case ("status", let value): statuses[row] = NGChoiceEditingTests.statuses.firstIndex(of: value) ?? 0
            default: break
            }
        }
    }

    private func makeTable(_ records: Records) -> (NGTableView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                         .column(NGTableColumn("on", title: "On", width: 60, alignment: .center, isEditable: true)),
                         .column(NGTableColumn("status", title: "Status", width: 120, isEditable: true, editChoices: Self.statuses))]
        window.contentView = table
        table.dataSource = records
        table.navigatesByCell = true
        table.layoutSubtreeIfNeeded()
        window.makeFirstResponder(table)
        return (table, window)
    }

    @Test func checkBoxesToggle() throws {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        // Drawn as a check box, only where editable.
        let on = try #require(table.tableColumns.first { $0.id == "on" })
        #expect(table.cellContent(for: .bool(true), in: on) == .mark(NGTableView.checkBoxMark(true), alignment: .center))
        // A click on the box toggles it; a click beside it only selects.
        func click(row: Int, x: CGFloat) throws {
            let location = table.centerRegion.canvas.convert(NSPoint(x: x, y: (CGFloat(row) + 0.5) * table.rowHeight), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: 1, pressure: 1))
                type == .leftMouseDown ? table.rowsMouseDown(event, in: table.centerRegion) : table.rowsMouseUp(event)
            }
        }
        let boxX = try #require(table.frameOfCell(row: 1, columnID: "on")).midX
        try click(row: 1, x: boxX)
        #expect(records.isOn[1])
        #expect(table.selectedRowIndexes == [1])
        try click(row: 1, x: boxX + 26)
        #expect(records.isOn[1])
        // Space on the focused cell, Return too; Undo sets it back.
        table.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, characters: " ",
                                                          charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)))
        #expect(!records.isOn[1])
        table.insertNewline(nil)
        #expect(records.isOn[1])
        try #require(table.undoManager).undo()
        #expect(!records.isOn[1])
    }

    /// A click on a check box in a table sorted by its column: the record
    /// moves with its new value, and it's the one selected.
    @Test func checkBoxClickInASortedTable() throws {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "on", ascending: true)]
        // The first row shown has no check; checked, it goes after the unchecked rows.
        let first = try #require(table.row(atDisplayIndex: 0))
        #expect(!records.isOn[first])
        let boxX = try #require(table.frameOfCell(row: first, columnID: "on")).midX
        let location = table.centerRegion.canvas.convert(NSPoint(x: boxX, y: 0.5 * table.rowHeight), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            type == .leftMouseDown ? table.rowsMouseDown(event, in: table.centerRegion) : table.rowsMouseUp(event)
        }
        #expect(records.isOn[first])
        #expect(table.selectedRowIndexes == [first])
        #expect(table.displayIndex(ofRow: first) != 0)
    }

    @Test func choicesInAMenu() throws {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        let status = try #require(table.tableColumns.first { $0.id == "status" })
        let menu = try #require(table.choiceMenu(row: 3, column: status))
        #expect(menu.items.map(\.title) == ["Active", "Paused"])
        #expect(menu.items.map(\.state) == [.on, .off])
        // A record inserted above while the menu is open: the choice still lands on its record.
        records.names.insert("New", at: 0)
        records.isOn.insert(false, at: 0)
        records.statuses.insert(0, at: 0)
        table.insertRows(at: [0])
        menu.performActionForItem(at: 1)
        #expect(records.statuses[4] == 1)
        #expect(records.statuses[3] == 0)
        // Typing doesn't open the menu.
        #expect(!table.editCell(row: 2, columnID: "status", text: "P"))
    }
    /// Cells with choices show the pop-up's chevron (only in an editable
    /// column); with `opensChoicesOnClick` a single click selects the row and
    /// opens the menu, without it a single click only selects.
    @Test func choicesOpenOnAClick() throws {
        let records = Records()
        let (table, window) = makeTable(records)
        defer {
            withExtendedLifetime((window, records)) {}
            NGTableView.choiceMenuShownForTesting = nil
        }
        #expect(table.visibleCell(sourceRow: 0, columnID: "status")?.showsChoiceChevron == true)
        #expect(table.visibleCell(sourceRow: 0, columnID: "name")?.showsChoiceChevron == false)
        var shown: [NSMenu] = []
        NGTableView.choiceMenuShownForTesting = { shown.append($0) }
        func click(row: Int) throws {
            let frame = try #require(table.frameOfCell(row: row, columnID: "status"))
            let location = table.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: 1, pressure: 1))
                type == .leftMouseDown ? table.rowsMouseDown(event, in: table.centerRegion) : table.rowsMouseUp(event)
            }
        }
        try click(row: 2)
        #expect(shown.isEmpty && table.selectedRowIndexes == [2])
        var columns = table.columns
        if case .column(var status) = columns[2] {
            status.opensChoicesOnClick = true
            columns[2] = .column(status)
        }
        table.columns = columns
        table.layoutSubtreeIfNeeded()
        try click(row: 3)
        #expect(shown.count == 1 && table.selectedRowIndexes == [3])
        // The menu's items are the choices.
        #expect(shown.first?.items.count == Self.statuses.count)
        // Not editable: no chevron, no menu.
        if case .column(var status) = columns[2] {
            status.isEditable = false
            columns[2] = .column(status)
        }
        table.columns = columns
        table.layoutSubtreeIfNeeded()
        #expect(table.visibleCell(sourceRow: 0, columnID: "status")?.showsChoiceChevron == false)
        try click(row: 4)
        #expect(shown.count == 1 && table.selectedRowIndexes == [4])
    }
}
#endif
