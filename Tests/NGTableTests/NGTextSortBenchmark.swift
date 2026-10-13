#if os(macOS)
import AppKit
import Testing
@testable import NGTable

// How long a text sort of many rows keeps the main thread, in one piece:
// the sort runs in the background, and the main thread should never be held
// longer than a frame's slice. A timer on the main queue every millisecond
// finds the longest gap. Skipped unless NGTABLE_BENCH is set:
//
//     NGTABLE_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter NGTextSortBenchmark
//
// NGTABLE_BENCH_ROWS sets the rows (1,000,000). `loadingManyRows` times
// loading them into a new table.

@MainActor
private final class Texts: NGTableViewDataSource {
    let names: [String]
    /// NGTABLE_BENCH_DISTINCT: how many different texts (50: like trades' pairs, many ties).
    init(count: Int, distinct: Int?) {
        var generator = SplitMix64(seed: 3)
        let pairs = distinct.map { distinct in (0..<distinct).map { "PAIR\($0)USDT" } }
        names = (0..<count).map { _ in
            if let pairs { return pairs[Int(generator.next() % UInt64(pairs.count))] }
            return "Campaign \(generator.next() % 10_000_000) – \(["Push", "Native", "Video", "Search"][Int(generator.next() % 4)])"
        }
    }
    func numberOfRows(in tableView: NGTableView) -> Int { names.count }
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text(names[row]) }
}

@Suite("Text sort benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["NGTABLE_BENCH"] != nil))
@MainActor
struct NGTextSortBenchmark {
    @Test func longestMainThreadHold() async throws {
        let count = Int(ProcessInfo.processInfo.environment["NGTABLE_BENCH_ROWS"] ?? "") ?? 1_000_000
        let texts = Texts(count: count, distinct: Int(ProcessInfo.processInfo.environment["NGTABLE_BENCH_DISTINCT"] ?? ""))
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 300))]
        // In a window on screen, drawing its frames (as in an app).
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        window.orderFront(nil)
        table.drawsWhileUnseenForTesting = true
        table.dataSource = texts
        table.sortsRows = true
        table.layoutSubtreeIfNeeded()
        defer {
            window.orderOut(nil)
            withExtendedLifetime((texts, window)) {}
        }
        // The longest time between ticks of a timer on the main queue.
        var last = CACurrentMediaTime(), longest = 0.0
        // Strict, without leeway: a late tick is the main thread's, not coalescing.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .nanoseconds(0))
        timer.setEventHandler {
            let now = CACurrentMediaTime()
            longest = max(longest, now - last)
            last = now
        }
        timer.resume()
        defer { timer.cancel() }
        for (round, ascending) in [true, false, true].enumerated() {
            // From the data source's order each time (as a benchmark app sorts).
            table.sortDescriptors = []
            while table.isSortingRows { try await Task.sleep(for: .milliseconds(1)) }
            try await Task.sleep(for: .milliseconds(50))
            (last, longest) = (CACurrentMediaTime(), 0)
            let start = CACurrentMediaTime()
            table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: ascending)]
            let setting = CACurrentMediaTime() - start
            while table.isSortingRows { try await Task.sleep(for: .milliseconds(1)) }
            try await Task.sleep(for: .milliseconds(20))
            print(String(format: "text sort %d (%@): %.0f ms, setting the descriptors %.1f ms, longest main-thread hold %.1f ms",
                         round, ascending ? "ascending" : "descending", (CACurrentMediaTime() - start) * 1000, setting * 1000, longest * 1000))
        }
    }

    /// Loading the rows into a new table, three times in a row: to the first
    /// frame drawn, and the main thread's time meanwhile (a first load costs
    /// no more than the next ones).
    @Test func loadingManyRows() async throws {
        let count = Int(ProcessInfo.processInfo.environment["NGTABLE_BENCH_ROWS"] ?? "") ?? 1_000_000
        let texts = Texts(count: count, distinct: 50)
        for round in 0..<3 {
            let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            table.sortsRows = true
            table.allowsColumnFilters = true
            table.allowsUserGrouping = true
            table.dataSource = texts
            let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = table
            window.orderFront(nil)
            table.drawsWhileUnseenForTesting = true
            // The main thread's busy time: gaps between ticks of a 1 ms timer.
            var last = CACurrentMediaTime(), busy = 0.0, longest = 0.0
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .nanoseconds(0))
            timer.setEventHandler {
                let now = CACurrentMediaTime()
                if now - last > 0.002 { busy += now - last }
                longest = max(longest, now - last)
                last = now
            }
            timer.resume()
            let start = CACurrentMediaTime()
            table.columns = (0..<6).map { .column(NGTableColumn("name\($0)", title: "Name", width: 150)) }
            table.sortDescriptors = []
            let setting = CACurrentMediaTime() - start
            var drawn: CFTimeInterval?
            while CACurrentMediaTime() - start < 3 {
                try await Task.sleep(for: .milliseconds(1))
                if drawn == nil, !table.needsMetalFrame { drawn = CACurrentMediaTime() }
            }
            timer.cancel()
            print(String(format: "load %d: first frame %.0f ms, setting the columns %.1f ms, main thread busy %.0f ms in 3 s, longest %.0f ms",
                         round, ((drawn ?? .nan) - start) * 1000, setting * 1000, busy * 1000, longest * 1000))
            window.orderOut(nil)
            window.contentView = nil
        }
        withExtendedLifetime(texts) {}
    }
}
#endif
