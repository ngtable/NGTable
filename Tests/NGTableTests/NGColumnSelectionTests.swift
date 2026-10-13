#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Selecting columns, like NSTableView's `allowsColumnSelection`: by
/// clicking their headers or in code, instead of rows.
@Suite("Column selection")
@MainActor
struct NGColumnSelectionTests {
    @MainActor
    final class Rows: NGTableViewDataSource, NGTableViewDelegate {
        var refused: Set<String> = []
        var changes = 0
        func numberOfRows(in tableView: NGTableView) -> Int { 20 }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text("\(column.id) \(row)") }
        func tableView(_ tableView: NGTableView, shouldSelect tableColumn: NGTableColumn?) -> Bool {
            !refused.contains(tableColumn?.id ?? "")
        }
        func tableViewSelectionDidChange(_ notification: Notification) { changes += 1 }
    }

    private func makeTable(_ rows: Rows) -> (NGTableView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = ["a", "b", "c", "d"].map { .column(NGTableColumn($0, title: $0.uppercased(), width: 120)) }
        window.contentView = table
        table.dataSource = rows
        table.delegate = rows
        table.layoutSubtreeIfNeeded()
        return (table, window)
    }

    /// In code: rows or columns are selected, not both, with one notice.
    @Test func selectingColumnsInCode() {
        let rows = Rows()
        let (table, window) = makeTable(rows)
        defer { withExtendedLifetime((window, rows)) {} }
        table.selectRowIndexes([2], byExtendingSelection: false)
        let before = rows.changes
        table.selectColumnIndexes([1], byExtendingSelection: false)
        #expect(table.selectedColumnIndexes == [1] && table.selectedColumn == 1 && table.numberOfSelectedColumns == 1)
        #expect(table.selectedRowIndexes.isEmpty)
        #expect(rows.changes == before + 1)
        table.selectColumnIndexes([3], byExtendingSelection: true)
        #expect(table.selectedColumnIndexes == [1, 3] && table.selectedColumn == 3 && table.isColumnSelected(3))
        table.deselectColumn(1)
        #expect(table.selectedColumnIndexes == [3])
        // A selected column stays selected when it moves.
        table.moveColumn(3, toColumn: 0)
        #expect(table.selectedColumnIndexes == [0] && table.tableColumns[0].id == "d")
        // Hidden: not selected.
        table.hiddenColumnIDs = ["d"]
        #expect(table.selectedColumnIndexes.isEmpty)
        table.hiddenColumnIDs = []
        // Rows again: the columns go, with one notice.
        let count = rows.changes
        table.selectRowIndexes([4], byExtendingSelection: false)
        #expect(table.selectedColumnIndexes.isEmpty && rows.changes == count + 1)
        #expect(table.selectedColumn == -1)
    }

    /// Header clicks select columns when `allowsColumnSelection` is on:
    /// Command toggles, Shift extends; the delegate may refuse a column.
    /// Selected columns are tinted and VoiceOver hears of them.
    @Test func clickingHeadersSelectsColumns() throws {
        let rows = Rows()
        let (table, window) = makeTable(rows)
        defer { withExtendedLifetime((window, rows)) {} }
        let header = table.headerView
        func click(_ id: String, modifiers: NSEvent.ModifierFlags = []) throws {
            let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(id))
            let point = header.convert(NSPoint(x: table.rect(ofColumn: index).midX, y: header.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: 1, pressure: 1))
                type == .leftMouseDown ? table.headerMouseDown(event, in: header) : table.headerMouseUp(event)
            }
        }
        try click("b")
        #expect(table.selectedColumnIndexes.isEmpty)   // Off by default.
        table.allowsColumnSelection = true
        let renderer = try #require(table.metalRenderer)
        let plain = table.buildMetalQuads(renderer: renderer, scale: 2).count
        try click("b")
        #expect(table.selectedColumnIndexes == [1])
        #expect(table.buildMetalQuads(renderer: renderer, scale: 2).count > plain)
        try click("c", modifiers: .command)
        #expect(table.selectedColumnIndexes == [1, 2])
        try click("b", modifiers: .command)
        #expect(table.selectedColumnIndexes == [2])
        try click("a", modifiers: .shift)
        #expect(table.selectedColumnIndexes == [0, 1, 2])
        rows.refused = ["d"]
        try click("d")
        #expect(table.selectedColumnIndexes == [0, 1, 2])
        let columns = try #require(table.accessibilityColumns() as? [NSAccessibilityElement])
        #expect(columns.map { $0.isAccessibilitySelected() } == [true, true, true, false])
        #expect(table.accessibilitySelectedColumns()?.count == 3)
    }
}
#endif
