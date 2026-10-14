#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Rows of their own heights: the geometry, and a table whose delegate gives
/// the heights (`NGTableViewRowHeights`).
@MainActor
@Suite("Row heights")
struct NGRowHeightTests {
    @Test func geometryOfRowsOfTheirOwnHeights() {
        let rows = NGRowGeometry(rowHeight: 24, heights: [10, 20, 30])
        #expect(rows.hasRowHeights)
        #expect((0...3).map(rows.top) == [0, 10, 30, 60])
        #expect(rows.top(of: 5) == CGFloat(60 + 2 * 24))
        #expect(rows.top(of: -1) == -24)
        #expect((0..<3).map(rows.height) == [10, 20, 30])
        #expect(rows.height(of: 3) == 24)
        #expect(rows.bottom(of: 1) == 30)
        #expect(rows.totalHeight == 60)
        #expect(rows.offset(from: 2, to: 0) == 30)
        #expect(rows.position(atY: 0) == 0)
        #expect(rows.position(atY: 5) == 0.5)
        #expect(rows.position(atY: 10) == 1)
        #expect(rows.position(atY: 25) == 1.75)
        #expect(Int(rows.position(atY: 59.9)) == 2)
        #expect(rows.position(atY: 60) == 3)
        #expect(rows.position(atY: 72) == 3.5)
        #expect(rows.position(atY: -12) == -0.5)
    }

    /// With one height it is the arithmetic of a single height.
    @Test func uniformGeometry() {
        let rows = NGRowGeometry(rowHeight: 24.5, count: 10)
        #expect(!rows.hasRowHeights)
        #expect(rows.top(of: 3) == 3 * 24.5)
        #expect(rows.offset(from: 5, to: 2) == 3 * 24.5)
        #expect(rows.position(atY: 49) == 2)
        #expect(rows.totalHeight == 245)
    }

    final class Records: NGTableViewDataSource {
        var names: [String]
        var groups: [String]
        init(count: Int) {
            names = (0..<count).map { String(format: "Record %03d", $0) }
            groups = (0..<count).map { $0 % 2 == 0 ? "Even" : "Odd" }
        }
        func numberOfRows(in tableView: NGTableView) -> Int { names.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            column.id == "group" ? .text(groups[row]) : .text(names[row])
        }
        func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { names[row] }
    }

    /// Heights by record name; counts what the table asks.
    final class Heights: NGTableViewDelegate, NGTableViewRowHeights {
        let records: Records
        var heights: [String: CGFloat] = [:]
        var asked: [String] = []
        init(_ records: Records) {
            self.records = records
            for (index, name) in records.names.enumerated() { heights[name] = index % 3 == 0 ? 60 : 24 }
        }
        func tableView(_ tableView: NGTableView, heightOfRow row: Int) -> CGFloat {
            asked.append(records.names[row])
            return heights[records.names[row]] ?? 24
        }
    }

    func makeTable(_ records: Records, heights: Heights) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                         .column(NGTableColumn("group", title: "Group", width: 100))]
        table.dataSource = records
        table.delegate = heights
        table.layoutSubtreeIfNeeded()
        return table
    }

    /// The display rows' heights, as the table places them.
    func shownHeights(_ table: NGTableView) -> [CGFloat] {
        (0..<table.numberOfRows).map { table.rowGeometry.height(of: $0) }
    }

    @Test func rowsHaveTheirHeights() {
        let records = Records(count: 30)
        let heights = Heights(records)
        let table = makeTable(records, heights: heights)
        #expect(table.rowGeometry.hasRowHeights)
        #expect(shownHeights(table) == records.names.map { heights.heights[$0]! })
        // Each row's frame starts where the one above ends.
        for row in 1..<30 {
            #expect(table.rect(ofRow: row).minY == table.rect(ofRow: row - 1).maxY)
            #expect(table.rect(ofRow: row).height == heights.heights[records.names[row]])
        }
        // A point in a tall row is that row.
        let tall = table.rect(ofRow: 3)
        #expect(table.row(at: NSPoint(x: 50, y: tall.minY + 50)) == 3)
        #expect(table.row(at: NSPoint(x: 50, y: tall.maxY + 1)) == 4)
        // Each row is asked once.
        #expect(heights.asked.count == 30)
        _ = table.rowGeometry
        table.layoutSubtreeIfNeeded()
        #expect(heights.asked.count == 30)
        // The content is as high as the rows.
        #expect(table.rowGeometry.totalHeight == records.names.reduce(0) { $0 + heights.heights[$1]! })
    }

    @Test func heightsFollowTheirRecords() {
        let records = Records(count: 30)
        let heights = Heights(records)
        let table = makeTable(records, heights: heights)
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        table.layoutSubtreeIfNeeded()
        let shownNames = (0..<table.numberOfRows).map { records.names[table.sourceRow($0)] }
        #expect(shownNames == records.names.reversed())
        #expect(shownHeights(table) == shownNames.map { heights.heights[$0]! })
        // Filtered: the rows shown keep theirs.
        table.rowFilter = NGRowFilter(searchText: "Record 01")
        table.layoutSubtreeIfNeeded()
        let filtered = (0..<table.numberOfRows).map { records.names[table.sourceRow($0)] }
        #expect(!filtered.isEmpty && filtered.allSatisfy { $0.hasPrefix("Record 01") })
        #expect(shownHeights(table) == filtered.map { heights.heights[$0]! })
        // Sorting and filtering asked for no height again.
        #expect(heights.asked.count == 30)
    }

    /// A sort that finishes in the background places the heights with it.
    @Test func aBackgroundSortPlacesTheHeights() async throws {
        let records = Records(count: 3_000)
        let heights = Heights(records)
        let table = makeTable(records, heights: heights)
        table.synchronousSortLimit = 100
        table.sortsRows = true
        _ = table.rowGeometry   // Built for the order before the sort.
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        #expect(table.isSortingRows)
        try await waitWhile { table.isSortingRows }
        table.layoutSubtreeIfNeeded()
        let shownNames = (0..<table.numberOfRows).map { records.names[table.sourceRow($0)] }
        #expect(shownNames == records.names.reversed())
        #expect(shownHeights(table) == shownNames.map { heights.heights[$0]! })
    }

    @Test func groupHeaderRowsKeepTheRowHeight() {
        let records = Records(count: 12)
        let heights = Heights(records)
        let table = makeTable(records, heights: heights)
        table.rowGrouping = NGRowGrouping(columnIDs: ["group"])
        table.layoutSubtreeIfNeeded()
        for row in 0..<table.numberOfRows {
            let source = table.sourceRow(row)
            let expected = source < 0 ? table.rowHeight : heights.heights[records.names[source]]!
            #expect(table.rowGeometry.height(of: row) == expected, "display row \(row)")
        }
    }

    /// A reloaded row is asked for its height again; the others aren't.
    @Test func reloadedRowsAreAskedAgain() {
        let records = Records(count: 20)
        let heights = Heights(records)
        let table = makeTable(records, heights: heights)
        heights.asked = []
        heights.heights[records.names[5]] = 100
        table.reloadData(forRowIndexes: [5], columnIndexes: [0])
        table.layoutSubtreeIfNeeded()
        #expect(heights.asked == [records.names[5]])
        #expect(table.rect(ofRow: 5).height == 100)
        #expect(table.rect(ofRow: 6).minY == table.rect(ofRow: 5).maxY)
        // New rows are asked when they come; reloadData asks every row.
        heights.asked = []
        records.names.append("Record 999")
        records.groups.append("Odd")
        heights.heights["Record 999"] = 44
        table.insertRows(at: [20])
        table.layoutSubtreeIfNeeded()
        #expect(heights.asked == ["Record 999"])
        #expect(table.rect(ofRow: 20).height == 44)
        heights.asked = []
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        #expect(heights.asked.count == 21)
    }

    @Test func scrollingReachesTheLastRow() {
        let records = Records(count: 200)
        let heights = Heights(records)
        let table = makeTable(records, heights: heights)
        table.scrollRowToVisible(199)
        table.layoutSubtreeIfNeeded()
        #expect(table.rowIndexes(in: table.visibleRect).contains(199))
        #expect(table.row(at: NSPoint(x: 50, y: table.rect(ofRow: 199).midY)) == 199)
    }

    /// Without a delegate that gives heights, every row has `rowHeight` (the
    /// arithmetic of one height).
    @Test func oneHeightWithoutTheProvider() {
        let records = Records(count: 10)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200))]
        table.dataSource = records
        table.layoutSubtreeIfNeeded()
        #expect(!table.rowGeometry.hasRowHeights)
        #expect(table.rect(ofRow: 3).height == table.rowHeight)
    }
}
#endif
