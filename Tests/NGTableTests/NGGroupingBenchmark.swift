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

        /// Everything in the background at once after a reload: the sort, a
        /// first search, the grouping and the summaries, each reading in
        /// slices. The longest the main thread is held meanwhile.
        @Test func everythingAtOnceAfterAReload() async throws {
            let data = Campaigns(count: Self.rows)
            let (table, window) = makeTable(data)
            defer { withExtendedLifetime((window, data)) {} }
            try await waitForBackgroundWork(table)
            table.sortsRows = true
            table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            table.rowGrouping = NGRowGrouping(columnIDs: ["net"])
            table.rowFilter = NGRowFilter(searchText: "Campaign 1")
            try await waitForBackgroundWork(table)
            // NGTABLE_BENCH_REPEAT: reloads before the measured one (for profiling).
            for _ in 0..<(Int(ProcessInfo.processInfo.environment["NGTABLE_BENCH_REPEAT"] ?? "") ?? 0) {
                table.reloadData()
                try await waitForBackgroundWork(table)
            }
            let start = ContinuousClock.now
            table.reloadData()
            table.layoutSubtreeIfNeeded()
            let held = ContinuousClock.now - start
            var jobs: [String] = []
            if table.isSortingRows { jobs.append("sort") }
            if table.isSearchingRows { jobs.append("search") }
            if table.isGroupingRows { jobs.append("grouping") }
            if table.isComputingSummary { jobs.append("summaries") }
            // The longest turn of the run loop (events wait for the next one).
            final class Turns: @unchecked Sendable { var last = ContinuousClock.now; var longest = 0.0; var span = (ContinuousClock.now, ContinuousClock.now) }
            let turns = Turns()
            // Busy from waking to going to sleep (or to the next turn).
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.beforeTimers.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
                let now = ContinuousClock.now
                if activity != .afterWaiting {
                    let d = now - turns.last
                    let ms = Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1e3
                    if ms > turns.longest { turns.longest = ms; turns.span = (turns.last, now) }
                }
                turns.last = now
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            defer { CFRunLoopObserverInvalidate(observer) }
            let longest = try await waitForBackgroundWork(table)
            let total = ContinuousClock.now - start
            print("BENCH all at once: reload held \(held), background \(jobs), then the run loop busy at most \(String(format: "%.1f", turns.longest)) ms at once (a 1 ms sleep waited \(String(format: "%.1f", longest)) ms), done after \(total)")
        }
    }
}
#endif
