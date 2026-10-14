#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Radix and parallel sorts give exactly the order of comparing rows.
@Suite("Fast sorts")
@MainActor
struct NGFastSortTests {
    private func randomNumbers(_ count: Int, seed: UInt64) -> [NGCellValue] {
        var state = seed
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        return (0..<count).map { _ in
            switch next() % 10 {
            case 0: .empty
            case 1: .number(.nan)
            case 2: .number(-0.0)
            case 3: .number(0)
            default: .number(Double(Int(next() % 2001) - 1000) / 4)   // Duplicates, negatives, fractions.
            }
        }
    }

    @Test func radixMatchesComparing() throws {
        let count = 20_000
        let order = NGRowHandles(count: count)
        let rows = Array(0..<count)
        for ascending in [[true], [false], [true, false], [false, true]] {
            let values = ascending.indices.map { randomNumbers(count, seed: UInt64($0 + 1)) }
            let keys = NGSortKeys(keys: ascending.indices.map { "k\($0)" }, ascending: ascending, values: values)
            let radix = try #require(keys.radixSorted(rows))
            let compared = rows.sorted { keys.comesBefore($0, $1, order: order) }
            #expect(radix == compared, "\(ascending)")
        }
        // Text isn't sorted by radix.
        let text = NGSortKeys(keys: ["t"], ascending: [true], values: [rows.map { .text("r\($0)") }])
        #expect(text.radixSorted(rows) == nil)
    }

    @Test func parallelMatchesSequential() {
        let count = 100_000
        let dates = (0..<count).map { NGCellValue.date(Date(timeIntervalSince1970: Double(($0 * 7919) % 5000))) }
        let keys = NGSortKeys(keys: ["d"], ascending: [false], values: [dates])
        let order = NGRowHandles(count: count)
        let rows = Array(0..<count)
        #expect(keys.comparesWithoutText)
        #expect(NGParallelSort.sorted(rows, workers: 8) { a, b, _ in keys.comesBefore(a, b, order: order) }
            == rows.sorted { keys.comesBefore($0, $1, order: order) })
    }

    @MainActor
    final class Numbers: NGTableViewDataSource {
        var values: [Double] = (0..<3000).map { Double(($0 * 37) % 101) }
        var batchCalls = 0
        var cellReads = 0
        func numberOfRows(in tableView: NGTableView) -> Int { values.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            cellReads += 1
            return .number(values[row])
        }
        func tableView(_ tableView: NGTableView, sortNumbersFor column: NGTableColumn, rows: Range<Int>,
                       into buffer: UnsafeMutableBufferPointer<Double>) -> Bool {
            batchCalls += 1
            for (offset, row) in rows.enumerated() { buffer[offset] = values[row] }
            return true
        }
    }

    /// A background sort reads the numbers by range, and sorts like reading cells.
    @Test func sortNumbersByRange() async throws {
        let source = Numbers()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        table.columns = [.column(NGTableColumn("v", title: "V", width: 100))]
        table.synchronousSortLimit = 100
        table.dataSource = source
        source.cellReads = 0
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "v", ascending: false)]
        try await waitWhile { table.isSortingRows }
        #expect(!table.isSortingRows)
        #expect(source.batchCalls == 1)
        #expect(source.cellReads < 200)   // The visible cells only.
        let shown = (0..<table.numberOfRows).map { source.values[table.sourceRow($0)] }
        #expect(shown == source.values.sorted(by: >))
        // Equal values stay in data source order.
        let firstTop = (0..<table.numberOfRows).prefix { source.values[table.sourceRow($0)] == 100 }.map { table.sourceRow($0) }
        #expect(firstTop == firstTop.sorted())
    }
}
#endif
