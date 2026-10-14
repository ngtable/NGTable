#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// The table's sort holding the rows while the pointer rests over them or a
/// selection is dragged (`pausesLiveSortUnderPointer`).
@MainActor
@Suite("Live sort paused under the pointer")
struct NGLiveSortPauseTests {
    typealias Records = NGLiveSortingTests.Records

    func makeTable(_ records: Records) -> (NGTableView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                         .column(NGTableColumn("profit", title: "Profit", width: 120, format: .number(fractionDigits: 0)))]
        window.contentView = table
        table.dataSource = records
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        table.layoutSubtreeIfNeeded()
        return (table, window)
    }

    /// The display order, by record id.
    func shownIDs(_ table: NGTableView, _ records: Records) -> [Int] {
        (0..<table.numberOfRows).map { records.records[table.sourceRow($0)].id }
    }

    func sortedIDs(_ table: NGTableView, _ records: Records) -> [Int] {
        records.expectedOrder(table.sortDescriptors, tableView: table).map { records.records[$0].id }
    }

    /// Moves the pointer (in the window, `nil`: away) as AppKit would report it.
    func point(_ table: NGTableView, _ location: NSPoint?) {
        table.pointerLocationForTesting = location ?? NSPoint(x: -100, y: -100)
        table.updateHoveredCellFromPointer()
    }

    /// Over a display row.
    func overRow(_ table: NGTableView, _ row: Int) -> NSPoint {
        let rect = table.rect(ofRow: table.sourceRow(row))
        return table.convert(NSPoint(x: 50, y: rect.midY), to: nil)
    }

    /// Values that move every row (and a new row) while the pointer rests
    /// over a row: the order holds; when it leaves, the rows go where they go.
    @Test func rowsHoldWhileThePointerRestsOverThem() async throws {
        let records = Records(count: 40)
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        #expect(shownIDs(table, records) == sortedIDs(table, records))
        point(table, overRow(table, 3))
        #expect(table.isLiveSortPaused)
        let before = shownIDs(table, records)
        table.beginUpdates()
        for row in records.records.indices { records.records[row].profit = -records.records[row].profit }
        table.reloadData(forRowIndexes: IndexSet(records.records.indices), columnIndexes: [1])
        records.records.append(.init(id: 99, name: "New", profit: 1_000, status: "Active"))
        table.insertRows(at: [records.records.count - 1])
        table.endUpdates()
        table.layoutSubtreeIfNeeded()
        // The same rows in the same places, the new one at the end; the values changed.
        #expect(shownIDs(table, records) == before + [99])
        try await Task.sleep(for: .milliseconds(150))
        #expect(shownIDs(table, records) == before + [99])
        // Away from the rows: placed.
        point(table, nil)
        #expect(!table.isLiveSortPaused)
        #expect(try await waitWhile { table.isSettlingSort })
        table.layoutSubtreeIfNeeded()
        #expect(shownIDs(table, records) == sortedIDs(table, records))
        #expect(shownIDs(table, records).first == 99)
    }

    /// A press in the rows (a selection being dragged) holds them too, past
    /// the rows' edge, until the button comes up.
    @Test func aPressHoldsTheRows() async throws {
        let records = Records(count: 30)
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        table.isPressingRows = true
        point(table, nil)
        #expect(table.isLiveSortPaused)
        let before = shownIDs(table, records)
        let row = try #require(records.records.firstIndex { $0.id == before.last })
        records.records[row].profit = 10_000
        table.reloadData(forRowIndexes: [row], columnIndexes: [1])
        table.layoutSubtreeIfNeeded()
        #expect(shownIDs(table, records) == before)
        table.isPressingRows = false
        #expect(try await waitWhile { table.isSettlingSort })
        table.layoutSubtreeIfNeeded()
        #expect(shownIDs(table, records) == sortedIDs(table, records))
    }

    /// Rows placed in the background (too many changed to place at once)
    /// when the pointer comes over the rows: the round waits for it to leave.
    @Test func aRoundBegunBeforeWaits() async throws {
        let records = Records(count: 40)
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        table.synchronousSortLimit = 10
        table.synchronousPlacementLimit = 1
        for row in records.records.indices { records.records[row].profit = -records.records[row].profit }
        let before = shownIDs(table, records)
        table.reloadData(forRowIndexes: IndexSet(records.records.indices), columnIndexes: [1])
        #expect(table.isSettlingSort)
        // The round runs on the next turns; the pointer is there first.
        point(table, overRow(table, 1))
        try await Task.sleep(for: .milliseconds(200))
        table.layoutSubtreeIfNeeded()
        #expect(shownIDs(table, records) == before)
        point(table, nil)
        #expect(try await waitWhile { table.isSettlingSort })
        table.layoutSubtreeIfNeeded()
        #expect(shownIDs(table, records) == sortedIDs(table, records))
    }

    /// Without the pause the rows move at once, under the pointer too.
    @Test func withoutThePauseRowsMoveAtOnce() throws {
        let records = Records(count: 30)
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        table.pausesLiveSortUnderPointer = false
        point(table, overRow(table, 2))
        #expect(!table.isLiveSortPaused)
        let last = try #require(shownIDs(table, records).last)
        let row = try #require(records.records.firstIndex { $0.id == last })
        records.records[row].profit = 10_000
        table.reloadData(forRowIndexes: [row], columnIndexes: [1])
        table.layoutSubtreeIfNeeded()
        #expect(shownIDs(table, records).first == last)
    }

    /// The pointer over the header or below the last row doesn't hold them.
    @Test func onlyOverTheRows() throws {
        let records = Records(count: 3)
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        point(table, table.convert(NSPoint(x: 50, y: 5), to: nil))   // The header.
        #expect(!table.isLiveSortPaused)
        point(table, table.convert(NSPoint(x: 50, y: 300), to: nil))   // Below the rows.
        #expect(!table.isLiveSortPaused)
        point(table, overRow(table, 1))
        #expect(table.isLiveSortPaused)
    }
}
#endif
