import AppKit
import Testing
@testable import NGTable

// Live update benchmark: batches of targeted updates on a large table, like a
// dashboard fed by a socket. Skipped unless NGTABLE_BENCH is set:
//
//     NGTABLE_BENCH=1 swift test --filter NGLiveUpdateBenchmark
//     NGTABLE_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter NGLiveUpdateBenchmark
//
// NGTABLE_BENCH_ROWS sets the number of rows (100,000 by default), NGTABLE_BENCH_TICKS
// the number of batches, NGTABLE_BENCH_PAUSE milliseconds of idle time between them,
// NGTABLE_BENCH_UPDATES the changed rows per batch (500), NGTABLE_BENCH_INSERTS the
// inserted and the removed rows per batch (2 each). NGTABLE_BENCH_GROUPS groups the
// rows by comma-separated columns (network: 5 values, owner: 8), collapsed with
// NGTABLE_BENCH_COLLAPSED=1. NGTABLE_BENCH_VALUES_ONLY=1 leaves out the inserts, removes
// and moves (a feed of changing metrics). NGTABLE_BENCH_SORT sorts by a column
// (`sortsRows`, descending), NGTABLE_BENCH_FILTER filters by search text.
// NGTABLE_BENCH_METRICS_ONLY=1 reports only the changed metric columns
// (clicks, spend, ROI) instead of every column.

/// Campaign-like records changed in place: text, tags and summed metrics.
@MainActor
private final class LiveRecords: NGTableViewDataSource {
    struct Record { let id: Int; var name: String; var clicks: Double; var spend: Double; var revenue: Double }
    var records: [Record]
    private var nextID: Int

    init(count: Int) {
        records = (0..<count).map { Record(id: $0, name: "Campaign \($0)", clicks: Double($0 % 997), spend: Double($0 % 313), revenue: Double($0 % 541)) }
        nextID = count
    }

    func newRecord() -> Record {
        defer { nextID += 1 }
        return Record(id: nextID, name: "Campaign \(nextID)", clicks: 1, spend: 1, revenue: 1)
    }

    func numberOfRows(in tableView: NGTableView) -> Int { records.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        let record = records[row]
        return switch column.id {
        case "id": .text(String(record.id))
        case "name": .text(record.name)
        case "status": .tags([NGTag("Active", color: .green)])
        case "network": .text(["MGID", "Taboola", "Outbrain", "Geozo", "Adskeeper"][record.id % 5])
        case "owner": .text("owner \(record.id % 8)")
        case "clicks": .number(record.clicks)
        case "spend": .number(record.spend)
        case "revenue": .number(record.revenue)
        case "roi": .number(record.spend > 0 ? (record.revenue - record.spend) / record.spend : 0)
        case "_one": .number(1)
        default: .empty
        }
    }

    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { records[row].id }
}

extension NGBenchmarks {
    @Suite("Live update benchmark", .enabled(if: ProcessInfo.processInfo.environment["NGTABLE_BENCH"] != nil))
    @MainActor
    struct NGLiveUpdateBenchmark {
        static let rows = Int(ProcessInfo.processInfo.environment["NGTABLE_BENCH_ROWS"] ?? "") ?? 100_000

        @Test func batchesOfValuesInsertsRemovesAndMoves() async throws {
            let frame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            let data = LiveRecords(count: Self.rows)
            let table = NGTableView(frame: frame)
            let count = NGSummaryFormula("count", using: ["_one"]) { $0.sum("_one") ?? 0 }
            let roi = NGSummaryFormula("roi", using: ["spend", "revenue"]) { values in
                guard let spend = values.sum("spend"), spend != 0, let revenue = values.sum("revenue") else { return nil }
                return (revenue - spend) / spend
            }
            table.columns = [
                .column(NGTableColumn("id", title: "ID", width: 80, summary: .formula(count), pin: .leading)),
                .column(NGTableColumn("name", title: "Name", width: 220, pin: .leading)),
                .column(NGTableColumn("status", title: "Status", width: 110)),
                .column(NGTableColumn("clicks", title: "Clicks", width: 100, format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
                .column(NGTableColumn("spend", title: "Spend", width: 100, format: .currency(code: "USD"), summary: .aggregate(.sum))),
                .column(NGTableColumn("revenue", title: "Revenue", width: 100, format: .currency(code: "USD"), summary: .aggregate(.sum))),
                .column(NGTableColumn("roi", title: "ROI", width: 90, format: .percent(fractionDigits: 1), summary: .formula(roi))),
            ]
            window.contentView = table
            table.dataSource = data
            table.layoutSubtreeIfNeeded()
            let environment = ProcessInfo.processInfo.environment
            if let groups = environment["NGTABLE_BENCH_GROUPS"] {
                table.rowGrouping = NGRowGrouping(columnIDs: groups.split(separator: ",").map(String.init),
                                                  startsCollapsed: environment["NGTABLE_BENCH_COLLAPSED"] == "1")
            }
            if let key = environment["NGTABLE_BENCH_SORT"] {
                table.sortsRows = true
                table.sortDescriptors = [NSSortDescriptor(key: key, ascending: false)]
            }
            if let text = environment["NGTABLE_BENCH_FILTER"] {
                table.rowFilter = NGRowFilter(searchText: text)
            }
            // NGTABLE_BENCH_COLUMN_FILTER=1: clicks of at least 500 (a column filter).
            if environment["NGTABLE_BENCH_COLUMN_FILTER"] == "1" {
                table.columnFilters = ["clicks": .range(min: 500, max: nil)]
            }
            table.selectRowIndexes([10, 20, 30], byExtendingSelection: false)
            // Large tables summarize in the background at first; updates then use the summaries.
            for _ in 0..<3000 where table.isComputingSummary || table.isSortingRows || table.isSearchingRows {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!table.isComputingSummary)

            var phaseTotals: [String: CFTimeInterval] = [:]
            NGTableView.rowUpdatePhasesForTesting = { phases in
                for (name, time) in phases { phaseTotals[name, default: 0] += time }
            }
            defer { NGTableView.rowUpdatePhasesForTesting = nil }

            let ticks = Int(ProcessInfo.processInfo.environment["NGTABLE_BENCH_TICKS"] ?? "") ?? 40
            let updates = Int(environment["NGTABLE_BENCH_UPDATES"] ?? "") ?? 500
            let inserts = Int(environment["NGTABLE_BENCH_INSERTS"] ?? "") ?? 2
            var generator = SystemRandomNumberGenerator()
            let changedColumns = environment["NGTABLE_BENCH_METRICS_ONLY"] == "1"
                ? IndexSet(table.tableColumns.indices.filter { ["clicks", "spend", "roi"].contains(table.tableColumns[$0].id) })
                : IndexSet(integersIn: 0..<table.numberOfColumns)
            // Time spent in the table's calls, not in changing the benchmark's own data.
            var tableTime: CFTimeInterval = 0
            func timed(_ call: () -> Void) {
                let start = CACurrentMediaTime()
                call()
                tableTime += CACurrentMediaTime() - start
            }
            // NGTABLE_BENCH_PAUSE: milliseconds of idle time between ticks, like a
            // timer-driven feed (the CPU may clock down or move to efficiency cores).
            let pause = Double(ProcessInfo.processInfo.environment["NGTABLE_BENCH_PAUSE"] ?? "") ?? 0
            let start = CACurrentMediaTime()
            for _ in 0..<ticks {
                if pause > 0 {
                    try await Task.sleep(for: .milliseconds(pause))
                }
                timed { table.beginUpdates() }
                for _ in 0..<updates {
                    let row = Int.random(in: 0..<data.records.count, using: &generator)
                    data.records[row].clicks += 1
                    data.records[row].spend += 1
                    timed { table.reloadData(forRowIndexes: [row], columnIndexes: changedColumns) }
                }
                for _ in 0..<(environment["NGTABLE_BENCH_VALUES_ONLY"] == "1" ? 0 : inserts) {
                    let row = Int.random(in: 0...data.records.count, using: &generator)
                    data.records.insert(data.newRecord(), at: row)
                    timed { table.insertRows(at: [row]) }
                    let gone = Int.random(in: 0..<data.records.count, using: &generator)
                    data.records.remove(at: gone)
                    timed { table.removeRows(at: [gone]) }
                }
                if environment["NGTABLE_BENCH_VALUES_ONLY"] != "1" {
                    let from = Int.random(in: 0..<data.records.count, using: &generator)
                    let to = Int.random(in: 0..<data.records.count, using: &generator)
                    data.records.insert(data.records.remove(at: from), at: to)
                    timed { table.moveRow(at: from, to: to) }
                }
                timed { table.endUpdates() }
            }
            let perTick = (CACurrentMediaTime() - start) / Double(ticks) * 1000 - pause
            let phases = phaseTotals.sorted { $0.value > $1.value }
                .map { "\($0.key) \(String(format: "%.1f", $0.value / Double(ticks) * 1000))" }.joined(separator: ", ")
            let tablePerTick = tableTime / Double(ticks) * 1000
            print("LIVE \(Self.rows) rows, \(updates) updates, groups \(environment["NGTABLE_BENCH_GROUPS"] ?? "none"), sort \(environment["NGTABLE_BENCH_SORT"] ?? "none"), filter \(environment["NGTABLE_BENCH_FILTER"] ?? "none"): \(String(format: "%.1f", perTick)) ms per tick, the table \(String(format: "%.1f", tablePerTick)) ms (finishing: \(phases) ms)")
            withExtendedLifetime((window, data)) {}
        }
    }
}
