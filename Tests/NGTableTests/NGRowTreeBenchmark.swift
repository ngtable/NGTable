#if os(macOS)
import AppKit
import Testing
@testable import NGTable

// Row tree benchmark: campaigns with their teasers as a tree (`rowTree`),
// a feed inserting and removing teasers: how long a batch takes, values
// only and with rows inserted and removed. Skipped unless NGTABLE_BENCH is
// set; meant for release builds:
//
//     NGTABLE_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter NGRowTreeBenchmark
//
// NGTABLE_BENCH_ROWS sets the rows (200,000), NGTABLE_BENCH_SORT=1 sorts by spend.

@MainActor
private final class Teasers: NGTableViewDataSource {
    var ids: [Int]
    var parents: [Int?]
    var spends: [Double]
    private var nextID: Int

    /// Campaigns of 99 teasers each.
    init(count: Int) {
        ids = Array(0..<count)
        parents = (0..<count).map { $0 % 100 == 0 ? nil : $0 - $0 % 100 }
        spends = (0..<count).map { Double($0 % 997) }
        nextID = count
    }

    /// A teaser of a campaign, after the campaign's rows.
    func append(under campaign: Int) {
        ids.append(nextID)
        parents.append(campaign)
        spends.append(Double(nextID % 997))
        nextID += 1
    }

    func remove(_ row: Int) {
        ids.remove(at: row)
        parents.remove(at: row)
        spends.remove(at: row)
    }

    func numberOfRows(in tableView: NGTableView) -> Int { ids.count }
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        column.id == "spend" ? .number(spends[row]) : .text("\(ids[row])")
    }
    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { ids[row] }
    func tableView(_ tableView: NGTableView, parentIdentifierForRow row: Int) -> AnyHashable? { parents[row] }
}

extension NGBenchmarks {
    @Suite("Row tree benchmark", .enabled(if: ProcessInfo.processInfo.environment["NGTABLE_BENCH"] != nil), .serialized)
    @MainActor
    struct NGRowTreeBenchmark {
        static let rows = Int(ProcessInfo.processInfo.environment["NGTABLE_BENCH_ROWS"] ?? "") ?? 200_000
        static let sorts = ProcessInfo.processInfo.environment["NGTABLE_BENCH_SORT"] == "1"

        @Test func batchesOfAFeed() async throws {
            let teasers = Teasers(count: Self.rows)
            let frame = NSRect(x: 0, y: 0, width: 600, height: 700)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            defer { withExtendedLifetime((window, teasers)) {} }
            let table = NGTableView(frame: frame)
            table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                             .column(NGTableColumn("spend", title: "Spend", width: 100, summary: .aggregate(.sum)))]
            table.dataSource = teasers
            table.rowTree = NGRowTree()
            if Self.sorts {
                table.sortsRows = true
                table.sortDescriptors = [NSSortDescriptor(key: "spend", ascending: false)]
            }
            window.contentView = table
            table.layoutSubtreeIfNeeded()
            while table.isSettlingSort || table.isComputingSummary { try await Task.sleep(for: .milliseconds(5)) }
            var generator = SplitMix(seed: 4)
            func measure(_ batches: Int, _ body: () -> Void) -> Duration {
                let start = ContinuousClock.now
                for _ in 0..<batches {
                    table.beginUpdates()
                    body()
                    table.endUpdates()
                    table.layoutSubtreeIfNeeded()
                }
                return (ContinuousClock.now - start) / batches
            }
            let values = measure(200) {
                for _ in 0..<50 {
                    let row = Int(generator.next() % UInt64(teasers.ids.count))
                    teasers.spends[row] += 1
                    table.reloadData(forRowIndexes: [row], columnIndexes: [1])
                }
            }
            let structural = measure(200) {
                // Two teasers of random campaigns in, two random teasers out.
                for _ in 0..<2 {
                    let campaign = Int(generator.next() % UInt64(Self.rows / 100)) * 100
                    teasers.append(under: campaign)
                    table.insertRows(at: [teasers.ids.count - 1])
                    var row = Int(generator.next() % UInt64(teasers.ids.count))
                    if teasers.parents[row] == nil { row += 1 }
                    teasers.remove(row)
                    table.removeRows(at: [row])
                }
            }
            print("BENCH row tree of \(Self.rows) rows\(Self.sorts ? ", sorted" : ""): a batch of 50 value changes \(values), "
                  + "of 2 inserts and 2 removes \(structural)")
        }
    }
}
#endif
