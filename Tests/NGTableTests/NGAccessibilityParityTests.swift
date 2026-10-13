#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// What VoiceOver gets from an NSTableView and now from the table too:
/// columns as elements, the selected cells, the sort direction of headers,
/// and a row's swipe actions and menu as actions of the row.
@Suite("Accessibility like NSTableView")
@MainActor
struct NGAccessibilityParityTests {
    @MainActor
    final class Rows: NGTableViewDataSource, NGTableViewDelegate {
        var archived: [Int] = []
        func numberOfRows(in tableView: NGTableView) -> Int { 30 }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text("\(column.id) \(row)") }
        func tableView(_ tableView: NGTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NGRowAction] {
            guard edge == .trailing else { return [] }
            return [NGRowAction(style: .destructive, title: "Archive") { [weak self] _, row in self?.archived.append(row) }]
        }
        func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: NGTableColumn?) -> NSMenu? {
            let menu = NSMenu()
            menu.addItem(withTitle: "Rows \(Array(rows))", action: nil, keyEquivalent: "")
            return menu
        }
    }

    private func makeTable(_ rows: Rows) -> (NGTableView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = ["a", "b", "c"].map { .column(NGTableColumn($0, title: $0.uppercased(), width: 150)) }
        window.contentView = table
        table.dataSource = rows
        table.delegate = rows
        table.layoutSubtreeIfNeeded()
        return (table, window)
    }

    @Test func columnsAndTheirSortDirection() throws {
        let rows = Rows()
        let (table, window) = makeTable(rows)
        defer { withExtendedLifetime((window, rows)) {} }
        let columns = try #require(table.accessibilityColumns() as? [NSAccessibilityElement])
        #expect(columns.map { $0.accessibilityRole() } == [.column, .column, .column])
        #expect(columns.map { $0.accessibilityIndex() } == [0, 1, 2])
        #expect(table.accessibilityVisibleColumns()?.count == 3)
        // The header is the column's header button; the children are its cells in the rows shown.
        let headers = try #require(table.accessibilityColumnHeaderUIElements() as? [NSAccessibilityElement])
        #expect(columns[1].accessibilityHeader() as? NSAccessibilityElement === headers[1])
        let cells = try #require(columns[1].accessibilityChildren() as? [NGAccessibilityCell])
        #expect(cells.count == table.visibleRowRange.count && cells.allSatisfy { $0.column.id == "b" })
        #expect(cells.first?.accessibilityValue() as? String == "b \(table.visibleRowRange.lowerBound)")
        // Sorted descending by B: its header and column say so, the others don't.
        table.sortDescriptors = [NSSortDescriptor(key: "b", ascending: false)]
        #expect(headers[1].accessibilitySortDirection() == .descending)
        #expect(headers[0].accessibilitySortDirection() == .unknown)
        #expect(columns[1].accessibilitySortDirection() == .descending)
        table.sortDescriptors = [NSSortDescriptor(key: "b", ascending: true)]
        #expect(headers[1].accessibilitySortDirection() == .ascending)
    }

    /// The focused cell, or the cells of a range (navigation by cell).
    @Test func selectedCells() throws {
        let rows = Rows()
        let (table, window) = makeTable(rows)
        defer { withExtendedLifetime((window, rows)) {} }
        #expect(table.accessibilitySelectedCells()?.isEmpty ?? true)
        table.navigatesByCell = true
        table.focusedCell = NGCellPosition(row: 2, columnID: "b")
        let focused = try #require(table.accessibilitySelectedCells() as? [NGAccessibilityCell])
        #expect(focused.map { "\($0.rowIndex) \($0.column.id)" } == ["2 b"])
        table.selectedCellRange = NGCellRange(anchor: NGCellPosition(row: 1, columnID: "a"), end: NGCellPosition(row: 3, columnID: "b"))
        let range = try #require(table.accessibilitySelectedCells() as? [NGAccessibilityCell])
        #expect(range.map { "\($0.rowIndex) \($0.column.id)" } == ["1 a", "1 b", "2 a", "2 b", "3 a", "3 b"])
    }

    /// Swipe actions are the row's custom actions; its menu is the one a
    /// right-click opens (for the selection when the row is in it).
    @Test func rowActionsAndMenusForVoiceOver() throws {
        let rows = Rows()
        let (table, window) = makeTable(rows)
        defer { withExtendedLifetime((window, rows)) {} }
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "a", ascending: false)]
        let row = table.accessibilityRowElement(4)
        let actions = row.accessibilityCustomActions() ?? []
        #expect(actions.map(\.name) == ["Archive"])
        #expect(actions.first?.handler?() == true)
        #expect(rows.archived == [table.sourceRow(4)])
        #expect(table.accessibilityMenu(forDisplayRow: 4)?.items.first?.title == "Rows [\(table.sourceRow(4))]")
        table.selectRowIndexes([table.sourceRow(2), table.sourceRow(4)], byExtendingSelection: false)
        let selected = [table.sourceRow(2), table.sourceRow(4)].sorted()
        #expect(table.accessibilityMenu(forDisplayRow: 4)?.items.first?.title == "Rows \(selected)")
        // Group headers have no swipe actions.
        table.rowGrouping = NGRowGrouping(columnID: "c")
        #expect(table.accessibilityRowElement(0).accessibilityCustomActions()?.isEmpty ?? true)
    }
}
#endif
