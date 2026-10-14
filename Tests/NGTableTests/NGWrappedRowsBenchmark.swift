#if os(macOS)
import AppKit
import Testing
@testable import NGTable

// Wrapped-rows benchmark: a log of a million messages in a wrapping column,
// measured in the background (see NGWrappedRows.swift): how long until every
// row has its height, and the longest the main thread is held meanwhile.
// Skipped unless NGTABLE_BENCH is set; meant for release builds:
//
//     NGTABLE_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter NGWrappedRowsBenchmark

@MainActor
private final class Log: NGTableViewDataSource {
    static let words = ["request", "retried", "upstream", "timeout", "user", "session", "cache", "miss", "connection",
                        "reset", "by", "peer", "after", "the", "server", "answered", "slowly", "with", "status", "503"]
    let messages: [String]

    init(count: Int) {
        var generator = SplitMix(seed: 11)
        messages = (0..<count).map { _ in
            (0..<(4 + Int(generator.next() % 30))).map { _ in Self.words[Int(generator.next() % UInt64(Self.words.count))] }
                .joined(separator: " ")
        }
    }

    func numberOfRows(in tableView: NGTableView) -> Int { messages.count }
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        column.id == "message" ? .text(messages[row]) : .text("\(row)")
    }
}

extension NGBenchmarks {
    @Suite("Wrapped rows benchmark", .enabled(if: ProcessInfo.processInfo.environment["NGTABLE_BENCH"] != nil), .serialized)
    @MainActor
    struct NGWrappedRowsBenchmark {
        static let rows = Int(ProcessInfo.processInfo.environment["NGTABLE_BENCH_ROWS"] ?? "") ?? 1_000_000

        @Test func measuringAMillionMessages() async throws {
            let log = Log(count: Self.rows)
            let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            defer { withExtendedLifetime((window, log)) {} }
            let table = NGTableView(frame: frame)
            table.columns = [.column(NGTableColumn("line", title: "Line", width: 80)),
                             .column(NGTableColumn("message", title: "Message", width: 420).wrappingText())]
            let start = ContinuousClock.now
            table.dataSource = log
            window.contentView = table
            table.layoutSubtreeIfNeeded()
            let opened = ContinuousClock.now - start
            var longest = Duration.zero
            while table.isMeasuringRows {
                let before = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(1))
                longest = max(longest, ContinuousClock.now - before - .milliseconds(1))
            }
            let measured = ContinuousClock.now - start
            table.layoutSubtreeIfNeeded()
            let tall = (0..<table.numberOfRows).filter { table.rowGeometry.height(of: $0) > table.rowHeight }.count
            print("BENCH wrapped rows: opened in \(opened), all measured after \(measured), main thread held at most \(longest) at once, "
                  + "\(tall) of \(table.numberOfRows) rows wrap, content \(Int(table.layoutMetrics.contentHeight)) pt")
        }
    }
}
#endif
