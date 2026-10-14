#if os(macOS)
import AppKit
import Testing
@testable import NGTable

// Grouping benchmark: how long grouping a million rows holds the main
// thread, from setting `rowGrouping` until the rows are laid out and drawn
// (keys read, groups built, headers with their subtotals placed). Skipped
// unless NGTABLE_BENCH is set; meant for release builds:
//
//     NGTABLE_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter NGGroupingBenchmark

@MainActor
private final class Campaigns: NGTableViewDataSource {
    let spend: [Double]
    let names: [String]

    init(count: Int) {
        var generator = SplitMix(seed: 7)
        spend = (0..<count).map { _ in Double(generator.next() % 100_000) }
        names = (0..<count).map { "Campaign \($0)" }
    }

    func numberOfRows(in tableView: NGTableView) -> Int { names.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        switch column.id {
        case "name": .text(names[row])
        case "net": .text(["MGID", "Taboola", "Outbrain", "Geozo", "Adskeeper"][row % 5])
        case "country": .text(["DE", "FR", "IT", "ES", "PL", "NL", "AT", "CZ"][row % 8])
        default: .number(spend[row])
        }
    }

    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { row }
}

extension NGBenchmarks {
    @Suite("Grouping benchmark", .enabled(if: ProcessInfo.processInfo.environment["NGTABLE_BENCH"] != nil), .serialized)
    @MainActor
    struct NGGroupingBenchmark {
        static let rows = Int(ProcessInfo.processInfo.environment["NGTABLE_BENCH_ROWS"] ?? "") ?? 1_000_000

        private func makeTable(_ data: Campaigns) -> (NGTableView, NSWindow) {
            let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            let table = NGTableView(frame: frame)
            table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                             .column(NGTableColumn("net", title: "Network", width: 120)),
                             .column(NGTableColumn("country", title: "Country", width: 80)),
                             .column(NGTableColumn("spend", title: "Spend", width: 100, summary: .aggregate(.sum)))]
            table.dataSource = data
            window.contentView = table
            table.layoutSubtreeIfNeeded()
            return (table, window)
        }

        private func milliseconds(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            body()
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
        }

        /// Waits for the table's background work; the longest the main actor
        /// was held meanwhile (beyond a 1 ms sleep), in milliseconds.
        @discardableResult
        private func waitForBackgroundWork(_ table: NGTableView) async throws -> Double {
            let deadline = ContinuousClock.now + .seconds(120)
            var longest = 0.0
            while table.isSortingRows || table.isSearchingRows || table.isComputingSummary || table.isGroupingRows,
                  ContinuousClock.now < deadline {
                let start = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(1))
                let held = ContinuousClock.now - start - .milliseconds(1)
                longest = max(longest, Double(held.components.attoseconds) / 1e15 + Double(held.components.seconds) * 1e3)
            }
            return longest
        }

        @Test func groupingAMillionRows() async throws {
            let data = Campaigns(count: Self.rows)
            let (table, window) = makeTable(data)
            defer { withExtendedLifetime((window, data)) {} }
            try await waitForBackgroundWork(table)
            func report(_ name: String, _ body: () -> Void) async throws {
                let held = milliseconds {
                    body()
                    table.layoutSubtreeIfNeeded()
                }
                let start = ContinuousClock.now
                let longest = try await waitForBackgroundWork(table)
                table.layoutSubtreeIfNeeded()
                let total = held + Double((ContinuousClock.now - start).components.attoseconds) / 1e15
                    + Double((ContinuousClock.now - start).components.seconds) * 1e3
                print(String(format: "BENCH grouping %@: main thread %.1f ms, then at most %.1f ms at once, until grouped %.1f ms, %d display rows",
                             name, held, longest, total, table.numberOfRows))
            }
            try await report("by network (keys read)") { table.rowGrouping = NGRowGrouping(columnIDs: ["net"]) }
            try await report("ungrouped") { table.rowGrouping = nil }
            try await report("by network again") { table.rowGrouping = NGRowGrouping(columnIDs: ["net"]) }
            try await report("by network, country") { table.rowGrouping = NGRowGrouping(columnIDs: ["net", "country"]) }
            try await report("collapse all") { table.collapseGroup(nil, collapseChildren: true) }
            try await report("expand all") { table.expandGroup(nil, expandChildren: true) }
            table.sortsRows = true
            try await report("sorted by spend") { table.sortDescriptors = [NSSortDescriptor(key: "spend", ascending: false)] }
        }
    }
}
#endif
