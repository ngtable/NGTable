#if os(macOS)
import AppKit
import Testing
@testable import NGTable

// Structural update benchmark: a feed that inserts and removes records all the time, like an
// order book: each batch removes rows the way such a client
// does, the last row taking the removed one's place (`removeRows` + `moveRow`), appends new
// rows (`insertRows` at the end) and changes values. Skipped unless NGTABLE_BENCH is set:
//
//     NGTABLE_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter NGStructuralBenchmark
//
// NGTABLE_BENCH_ROWS sets the rows (200,000), NGTABLE_BENCH_TICKS the batches (300),
// NGTABLE_BENCH_CHURN the rows removed and inserted per batch (100), NGTABLE_BENCH_UPDATES
// the changed rows per batch (100), NGTABLE_BENCH_SORT=1 sorts by price (`sortsRows`),
// NGTABLE_BENCH_SELECT_ALL=1 selects every row first (the new rows aren't: it fragments).

/// Order-like records by column, as a feed client keeps them.
@MainActor
private final class ChurnRecords: NGTableViewDataSource {
    /// NGTABLE_BENCH_UNIQUE=1: no two prices equal (ties cost a lookup of the data source order).
    static let unique = ProcessInfo.processInfo.environment["NGTABLE_BENCH_UNIQUE"] != nil
    var ids: [Int]
    var prices: [Double]
    var quantities: [Double]
    private var nextID: Int

    init(count: Int) {
        ids = Array(0..<count)
        prices = (0..<count).map { Self.unique ? Double($0) * 1.000_37 : Double($0 % 9973) / 7 }
        quantities = (0..<count).map { Double($0 % 101) }
        nextID = count
    }

    func append() {
        ids.append(nextID)
        prices.append(Self.unique ? Double(nextID) * 1.000_37 : Double(nextID % 9973) / 7)
        quantities.append(1)
        nextID += 1
    }

    /// The last row takes the removed one's place.
    func swapRemove(_ row: Int) {
        ids[row] = ids[ids.count - 1]
        prices[row] = prices[prices.count - 1]
        quantities[row] = quantities[quantities.count - 1]
        ids.removeLast()
        prices.removeLast()
        quantities.removeLast()
    }

    func numberOfRows(in tableView: NGTableView) -> Int { ids.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        switch column.id {
        case "id": .text("o\(ids[row])")
        case "side": .text(ids[row] % 2 == 0 ? "buy" : "sell")
        case "price": .number(prices[row])
        case "qty": .number(quantities[row])
        default: .empty
        }
    }

    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { ids[row] }

    func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        let source: [Double]
        switch column.id {
        case "price": source = prices
        case "qty": source = quantities
        default: return false
        }
        for (offset, row) in rows.enumerated() { values[offset] = source[row] }
        return true
    }
}

extension NGBenchmarks {
    @Suite("Structural update benchmark", .enabled(if: ProcessInfo.processInfo.environment["NGTABLE_BENCH"] != nil))
    @MainActor
    struct NGStructuralBenchmark {
        static func setting(_ name: String, _ fallback: Int) -> Int {
            Int(ProcessInfo.processInfo.environment[name] ?? "") ?? fallback
        }

        @Test func swapRemovesAppendsAndUpdates() throws {
            let rows = Self.setting("NGTABLE_BENCH_ROWS", 200_000)
            let ticks = Self.setting("NGTABLE_BENCH_TICKS", 300)
            let churn = Self.setting("NGTABLE_BENCH_CHURN", 100)
            let updates = Self.setting("NGTABLE_BENCH_UPDATES", 100)
            let frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            let data = ChurnRecords(count: rows)
            let table = NGTableView(frame: frame)
            var price = NGTableColumn("price", title: "Price", width: 100, summary: .aggregate(.sum))
            price.changeHighlight = .direction
            table.columns = [
                .column(NGTableColumn("id", title: "ID", width: 120, pin: .leading)),
                .column(NGTableColumn("side", title: "Side", width: 80)),
                .column(price),
                .column(NGTableColumn("qty", title: "Qty", width: 100, summary: .aggregate(.sum))),
            ]
            table.dataSource = data
            window.contentView = table
            table.drawsWhileUnseenForTesting = true
            if ProcessInfo.processInfo.environment["NGTABLE_BENCH_SORT"] != nil {
                table.sortsRows = true
                // Sorted at once: the background sort reads values between run loop turns, which this loop doesn't give.
                table.synchronousSortLimit = .max
                table.sortDescriptors = [NSSortDescriptor(key: "price", ascending: false)]
            }
            table.layoutSubtreeIfNeeded()
            if ProcessInfo.processInfo.environment["NGTABLE_BENCH_SELECT_ALL"] != nil { table.selectAll(nil) }
            defer { withExtendedLifetime((data, window)) {} }

            var generator = SystemRandomNumberGenerator()
            var times: [Double] = []
            var phases: [String: Double] = [:]
            NGTableView.rowUpdatePhasesForTesting = { for (name, seconds) in $0 { phases[name, default: 0] += seconds } }
            defer { NGTableView.rowUpdatePhasesForTesting = nil }
            var calls: Double = 0
            for _ in 0..<ticks {
                let start = CACurrentMediaTime()
                table.beginUpdates()
                let callsStart = CACurrentMediaTime()
                for _ in 0..<churn {
                    let row = Int.random(in: 0..<data.ids.count, using: &generator)
                    let last = data.ids.count - 1
                    data.swapRemove(row)
                    table.removeRows(at: [row])
                    if row != last { table.moveRow(at: last - 1, to: row) }
                }
                let first = data.ids.count
                for _ in 0..<churn { data.append() }
                table.insertRows(at: IndexSet(integersIn: first..<data.ids.count))
                var changed = IndexSet()
                for _ in 0..<updates {
                    let row = Int.random(in: 0..<data.ids.count, using: &generator)
                    data.prices[row] += ChurnRecords.unique ? 0.5 + Double(row % 1000) / 7919 : 1
                    changed.insert(row)
                }
                table.reloadData(forRowIndexes: changed, columnIndexes: [2])
                calls += CACurrentMediaTime() - callsStart
                table.endUpdates()
                times.append(CACurrentMediaTime() - start)
            }
            times.sort()
            let total = times.reduce(0, +)
            func ms(_ seconds: Double) -> String { String(format: "%.3f", seconds * 1000) }
            print("""
                Structural benchmark: \(rows) rows, \(ticks) batches of \(churn) swap-removes, \(churn) appends, \(updates) updates
                  batch p50 \(ms(times[times.count / 2])) ms, p99 \(ms(times[times.count * 99 / 100])) ms, max \(ms(times.last ?? 0)) ms
                  per batch: calls \(ms(calls / Double(ticks))) ms, total \(ms(total / Double(ticks))) ms
                  phases per batch: \(phases.sorted { $0.value > $1.value }.map { "\($0.key) \(ms($0.value / Double(ticks)))" }.joined(separator: ", "))
                """)
            #expect(table.numberOfRows == rows)
        }
    }
}
#endif
