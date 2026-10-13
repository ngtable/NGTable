#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import NGTable

// Scaling benchmark: the costs the review found quadratic or proportional to
// all rows, asserted as ratios (twice or four times the work may cost a
// little more than twice or four times, never the square), so the bounds
// hold on any machine. Skipped unless NGTABLE_BENCH is set; meant for
// release builds:
//
//     NGTABLE_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter NGScalingBenchmark

@MainActor
private final class Metrics: NGTableViewDataSource {
    var values: [[Double]]
    let names: [String]

    init(count: Int) {
        var generator = SplitMix(seed: 5)
        values = (0..<4).map { _ in (0..<count).map { _ in Double(generator.next() % 100_000) } }
        names = (0..<count).map { "Campaign \($0)" }
    }

    func numberOfRows(in tableView: NGTableView) -> Int { names.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        switch column.id {
        case "name": .text(names[row])
        case "net": .text(["MGID", "Taboola", "Outbrain", "Geozo", "Adskeeper"][row % 5])
        default: .number(values[Int(column.id.dropFirst()) ?? 0][row])
        }
    }

    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { row }
}

extension NGBenchmarks {
    @Suite("Scaling benchmark", .enabled(if: ProcessInfo.processInfo.environment["NGTABLE_BENCH"] != nil), .serialized)
    @MainActor
    struct NGScalingBenchmark {
        private func makeTable(_ data: Metrics, summary: NGColumnSummary = .aggregate(.sum)) -> (NGTableView, NSWindow) {
            let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            let table = NGTableView(frame: frame)
            table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                             .column(NGTableColumn("net", title: "Network", width: 120))]
                + (0..<4).map { .column(NGTableColumn("m\($0)", title: "M\($0)", width: 100, summary: summary)) }
            table.dataSource = data
            window.contentView = table
            table.layoutSubtreeIfNeeded()
            return (table, window)
        }

        /// The best of a few runs, in milliseconds.
        private func milliseconds(runs: Int = 3, _ body: () -> Void) -> Double {
            var best = Double.infinity
            for _ in 0..<runs {
                let start = ContinuousClock.now
                body()
                let elapsed = ContinuousClock.now - start
                best = min(best, Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)
            }
            return best
        }

        private func waitForBackgroundWork(_ table: NGTableView) async throws {
            let deadline = ContinuousClock.now + .seconds(120)
            while table.isSortingRows || table.isSearchingRows || table.isComputingSummary, ContinuousClock.now < deadline {
                try await _Concurrency.Task.sleep(for: .milliseconds(5))
            }
            #expect(!table.isSortingRows && !table.isSearchingRows && !table.isComputingSummary)
        }

        /// One tick changing the values of `count` random rows.
        private func tick(_ table: NGTableView, _ data: Metrics, count: Int, seed: UInt64) {
            var generator = SplitMix(seed: seed)
            let rows = data.names.count
            table.beginUpdates()
            var changed: [Int] = []
            changed.reserveCapacity(count)
            for _ in 0..<count {
                let row = Int(generator.next() % UInt64(rows))
                data.values[0][row] = Double(generator.next() % 100_000)
                changed.append(row)
            }
            // Built in order: random inserts into an IndexSet are quadratic themselves.
            table.reloadData(forRowIndexes: IndexSet(changed.sorted()), columnIndexes: [2])
            table.endUpdates()
        }

        /// A shuffle of 1,000,000 rows takes about four times a shuffle of 250,000.
        @Test func reorderRowsIsNearLinear() {
            func cost(_ count: Int) -> Double {
                let data = Metrics(count: count)
                let (table, window) = makeTable(data)
                defer { withExtendedLifetime((window, data)) {} }
                var generator = SplitMix(seed: 3)
                var order = Array(0..<count)
                for index in stride(from: count - 1, to: 0, by: -1) {
                    order.swapAt(index, Int(generator.next() % UInt64(index + 1)))
                }
                let identity = Array(0..<count)
                var flip = false
                return milliseconds {
                    flip.toggle()
                    flip ? table.reorderRows(from: identity, to: order) : table.reorderRows(from: order, to: identity)
                }
            }
            let small = cost(250_000), large = cost(1_000_000)
            print("reorderRows shuffled: 250k \(small) ms, 1M \(large) ms")
            #expect(large / small < 8)
        }

        /// Ticks cost by the changed rows, not the table's (unsorted and sorted
        /// by the table): four times the changes cost about four times as
        /// much, and the same changes cost about the same among four times
        /// the rows.
        @Test(arguments: [false, true])
        func feedTicksFollowTheChanges(sorted: Bool) async throws {
            func costs(rows: Int) async throws -> (small: Double, large: Double) {
                let data = Metrics(count: rows)
                let (table, window) = makeTable(data)
                defer { withExtendedLifetime((window, data)) {} }
                try await waitForBackgroundWork(table)
                if sorted {
                    table.sortsRows = true
                    table.sortDescriptors = [NSSortDescriptor(key: "m0", ascending: false)]
                    try await waitForBackgroundWork(table)
                }
                var seed: UInt64 = 100
                let small = milliseconds { seed += 1; tick(table, data, count: 10_000, seed: seed) }
                let large = milliseconds { seed += 1; tick(table, data, count: 40_000, seed: seed) }
                return (small, large)
            }
            let million = try await costs(rows: 1_000_000), quarter = try await costs(rows: 250_000)
            print("feed\(sorted ? " sorted" : ""): 1M 10k \(million.small) ms, 40k \(million.large) ms; 250k 10k \(quarter.small) ms")
            #expect(million.large / million.small < 6)
            #expect(million.small / quarter.small < 2.5)
        }

        /// Ticks while the summaries of 1,000,000 rows are computed in the
        /// background cost the same from the first to the last (the changed rows
        /// it reads again at the end are gathered without growing costs).
        @Test func ticksDuringABackgroundSummaryStayFlat() async throws {
            let data = Metrics(count: 1_000_000)
            let (table, window) = makeTable(data)
            defer { withExtendedLifetime((window, data)) {} }
            #expect(table.isComputingSummary)
            var costs: [Double] = []
            var seed: UInt64 = 300
            while table.isComputingSummary, costs.count < 400 {
                seed += 1
                costs.append(milliseconds(runs: 1) { tick(table, data, count: 10_000, seed: seed) })
                await _Concurrency.Task.yield()
            }
            try await waitForBackgroundWork(table)
            let early = costs.prefix(5).sorted()[min(2, costs.count - 1)]
            let late = costs.suffix(5).sorted()[min(2, costs.count - 1)]
            print("ticks during a background summary: \(costs.count), early \(early) ms, late \(late) ms")
            #expect(costs.count >= 10)
            #expect(late < 3 * max(early, 1))
            // The changed values all count.
            #expect(table.summaryValue(forColumnID: "m0") == data.values[0].reduce(0, +))
        }

        /// Min and max summaries stay exact through updates: asked for after
        /// a tick, they cost about what sums do, not a walk over every row.
        @Test func minAndMaxAfterTicksCostLikeSums() async throws {
            func cost(_ summary: NGColumnSummary) async throws -> Double {
                let data = Metrics(count: 1_000_000)
                let (table, window) = makeTable(data, summary: summary)
                defer { withExtendedLifetime((window, data)) {} }
                try await waitForBackgroundWork(table)
                var seed: UInt64 = 200
                var worst = 0.0
                for _ in 0..<10 {
                    seed += 1
                    tick(table, data, count: 100, seed: seed)
                    worst = max(worst, milliseconds(runs: 1) {
                        for column in 0..<4 { _ = table.summaryValue(forColumnID: "m\(column)") }
                    })
                }
                return worst
            }
            let sums = try await cost(.aggregate(.sum)), maxima = try await cost(.aggregate(.max))
            print("summaries after a tick, 1M: sums \(sums) ms, max \(maxima) ms")
            #expect(maxima < 10 * sums + 0.1)
        }

        /// Keystrokes over 1,000,000 rows, unsorted and sorted by the table:
        /// one that narrows the search (most matches drop out) costs no more
        /// than evaluating the search afresh, and column filters add little.
        /// The worst of a few of each counts (the setup between them, back to
        /// the wider search, isn't timed).
        @Test(arguments: [false, true])
        func keystrokesNarrowingTheSearch(sorted: Bool) async throws {
            func costs(filtered: Bool) async throws -> (narrowing: Double, fresh: Double) {
                let data = Metrics(count: 1_000_000)
                let (table, window) = makeTable(data)
                defer { withExtendedLifetime((window, data)) {} }
                if sorted {
                    table.sortsRows = true
                    table.sortDescriptors = [NSSortDescriptor(key: "m1", ascending: false)]
                }
                if filtered {
                    table.columnFilters = ["net": .values(["MGID", "Geozo"]), "name": .contains("9")]
                }
                table.rowFilter = NGRowFilter(searchText: "campaign", columnIDs: ["name"])
                try await waitForBackgroundWork(table)
                table.synchronousSearchLimit = .max
                var narrowing = 0.0, fresh = 0.0
                for _ in 0..<3 {
                    table.rowFilter = NGRowFilter(searchText: "campaign", columnIDs: ["name"])
                    let n = milliseconds(runs: 1) {
                        table.rowFilter = NGRowFilter(searchText: "campaign 1", columnIDs: ["name"])
                    }
                    narrowing = max(narrowing, n)
                    // Words that don't extend the last ones: every row again.
                    table.rowFilter = NGRowFilter(searchText: "zzz", columnIDs: ["name"])
                    let f = milliseconds(runs: 1) {
                        table.rowFilter = NGRowFilter(searchText: "campaign 1", columnIDs: ["name"])
                    }
                    fresh = max(fresh, f)
                }
                return (narrowing, fresh)
            }
            let plain = try await costs(filtered: false), filtered = try await costs(filtered: true)
            print("keystroke 1M\(sorted ? " sorted" : ""): narrowing \(plain.narrowing) ms (fresh \(plain.fresh)), "
                  + "with column filters \(filtered.narrowing) ms (fresh \(filtered.fresh))")
            #expect(plain.narrowing < 1.5 * plain.fresh + 2)
            #expect(filtered.narrowing < 1.5 * filtered.fresh + 2)
            #expect(filtered.narrowing < 4 * plain.narrowing + 2)
        }

        /// The moved rows of a diff by places (the longest increasing run) cost
        /// little next to what that diff costs anyway, each row's new place by
        /// id, when nearly all rows are in order (a far swap, 200 scattered
        /// moves): not a binary search per row.
        @Test func movedRowsOfNearlySortedOrders() {
            let count = 200_000
            var swapped: [Int?] = Array(0..<count)
            swapped.swapAt(10, 150_000)
            var scattered: [Int?] = Array(0..<count)
            var generator = SplitMix(seed: 9)
            for _ in 0..<200 {
                let a = Int(generator.next() % UInt64(count)), b = Int(generator.next() % UInt64(count))
                scattered.swapAt(a, b)
            }
            let places = milliseconds(runs: 5) {
                var position = [Int: Int](minimumCapacity: count)
                for index in 0..<count { position[index &* 7_919] = index }
                withExtendedLifetime(position) {}
            }
            var moved: [Int] = []
            let far = milliseconds(runs: 5) { moved = NGRowsDiff.movedRows(swapped) }
            #expect(moved.count <= 2)
            let many = milliseconds(runs: 5) { moved = NGRowsDiff.movedRows(scattered) }
            #expect(moved.count <= 400)
            print("movedRows 200k: far swap \(far) ms, 200 moves \(many) ms (new places by id \(places) ms)")
            #expect(far < places / 3)
            #expect(many < places / 3)
        }

        /// SwiftUI updates of 500 values among 200,000 rows cost about the
        /// same with every row selected as with none: the selection isn't
        /// compared element by element on every update.
        @Test func swiftUIUpdatesWithAllRowsSelected() {
            struct Row: Identifiable, Equatable { var id: Int; var spend: Double }
            final class State { var selection: Set<Int> = [] }
            func cost(selectingAll: Bool) -> Double {
                var rows = (0..<200_000).map { Row(id: $0, spend: Double($0)) }
                let state = State()
                if selectingAll { state.selection = Set(rows.map(\.id)) }
                func view() -> NGDataTable<Row> {
                    NGDataTable(rows, selection: Binding(get: { state.selection }, set: { state.selection = $0 })) {
                        NGDataColumn("Spend", value: \.spend, summary: .aggregate(.sum))
                    }
                }
                let hosting = NSHostingView(rootView: view())
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
                hosting.frame = window.contentLayoutRect
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                defer { withExtendedLifetime(window) {} }
                var tick = 0
                return milliseconds(runs: 20) {
                    tick += 1
                    for k in 0..<500 { rows[(tick * 977 + k * 389) % rows.count].spend += 1 }
                    hosting.rootView = view()
                    hosting.layoutSubtreeIfNeeded()
                }
            }
            let none = cost(selectingAll: false), all = cost(selectingAll: true)
            print("SwiftUI 200k, 500 values: nothing selected \(none) ms, all selected \(all) ms")
            #expect(all < 2 * none + 0.5)
        }

        /// The SwiftUI diff finds a block insert and a move among 200,000 rows
        /// at about the cost of finding changed values, without remapping.
        @Test func diffsOfInsertsAndMovesStayCheap() {
            struct Row: Identifiable, Equatable { let id: Int; var value: Int }
            let old = (0..<200_000).map { Row(id: $0, value: $0) }
            var edited = old
            for index in stride(from: 0, to: 200_000, by: 400) { edited[index].value += 1 }
            var shifted = old
            shifted.insert(contentsOf: (0..<17).map { Row(id: 1_000_000 + $0, value: 0) }, at: 100_000)
            shifted.insert(shifted.remove(at: 10), at: 150_000)
            var values: NGRowsDiff?, structure: NGRowsDiff?
            let valueCost = milliseconds { values = NGDataTable<Row>.diff(old, edited, equal: ==) }
            let structureCost = milliseconds { structure = NGDataTable<Row>.diff(old, shifted, equal: ==) }
            print("diff 200k: 500 values \(valueCost) ms, block insert + move \(structureCost) ms")
            #expect(values?.changed.count == 500)
            #expect(structure?.inserted.count == 17)
            #expect(structure?.moves.count == 1)
            #expect(structure?.oldToNew.isEmpty == true)
            #expect(structureCost < max(5 * valueCost, 2))
        }
    }
}
#endif
