#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Numbers for ranges of rows in one call (`tableView(_:numbersFor:rows:into:)`).
@Suite("Batch reads")
@MainActor
struct NGBatchReadTests {
    @MainActor
    final class Numbers: NGTableViewDataSource {
        var spend: [Double] = (0..<1000).map { Double($0) }
        var givesNumbers = true
        var cellReads = 0
        var batchCalls = 0
        func numberOfRows(in tableView: NGTableView) -> Int { spend.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            if column.id == "spend" { cellReads += 1 }
            return column.id == "spend" ? .number(spend[row]) : .text("r\(row)")
        }
        func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, rows: Range<Int>,
                       into values: UnsafeMutableBufferPointer<Double>) -> Bool {
            guard givesNumbers, column.id == "spend" else { return false }
            batchCalls += 1
            for (offset, row) in rows.enumerated() { values[offset] = spend[row] }
            return true
        }
    }

    private func makeTable(_ source: Numbers) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 100)),
                         .column(NGTableColumn("spend", title: "Spend", width: 100, summary: .aggregate(.sum)))]
        table.dataSource = source
        return table
    }

    @Test func summariesReadNumbersInOneCall() {
        let source = Numbers()
        let table = makeTable(source)
        defer { withExtendedLifetime(source) {} }
        table.layoutSubtreeIfNeeded()
        #expect(table.summaryValue(forColumnID: "spend") == 499_500)
        #expect(source.batchCalls > 0)
        // Only the visible cells were asked one by one.
        #expect(source.cellReads < 100)
        // After inserts (handles no longer the row indexes) a full read scatters by handle.
        source.spend.insert(1_000, at: 0)
        table.insertRows(at: [0])
        source.cellReads = 0
        table.reloadSummary()
        #expect(table.summaryValue(forColumnID: "spend") == 500_500)
        #expect(source.cellReads < 100)
        // The same totals without batches.
        let plain = Numbers()
        plain.givesNumbers = false
        plain.spend = source.spend
        let other = makeTable(plain)
        defer { withExtendedLifetime(plain) {} }
        #expect(other.summaryValue(forColumnID: "spend") == 500_500)
        #expect(plain.batchCalls == 0)
    }
}
#endif
