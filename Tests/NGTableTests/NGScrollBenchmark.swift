import AppKit
import os
import Testing
@testable import NGTable

// Scrolling benchmarks for a wide CRM-like table (43 columns, 2560×1400 points).
// They are skipped unless NGTABLE_BENCH is set:
//
//     NGTABLE_BENCH=1 swift test --filter NGScrollBenchmark
//     NGTABLE_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter NGScrollBenchmark
//
// Options (environment variables):
// - NGTABLE_BENCH_HZ: refresh rate to simulate, 120 (default) or 60; sets the
//   frame pacing.
// - NGTABLE_BENCH_ROWS: scroll steadily by this many rows per frame instead of a flick.
// - NGTABLE_BENCH_SPIN: keep a core busy during the pause before the flick
//   (the first frame after a pause is slow while the CPU clocks up).
//
// `sampleFlicks` also needs NGTABLE_BENCH_SAMPLE (NGTABLE_BENCH_SIDEWAYS for
// horizontal scrolling, NGTABLE_BENCH_RESTS for short flicks after pauses); it
// runs /usr/bin/sample on the test process and writes /tmp/ngtable-sample.txt.

/// A wide CRM-like table: text, money, percentages, tags and marks.
@MainActor
private final class WideDataSource: NGTableViewDataSource {
    static let statuses = [NGTag("Active", color: .green), NGTag("Paused", color: .orange), NGTag("Finished", color: .gray)]
    static let marks = [NGMark("star.fill", color: .yellow, label: "Favorite"), NGMark("flame.fill", color: .orange, label: "Hot")]
    var rowCount = 20_000

    func numberOfRows(in tableView: NGTableView) -> Int { rowCount }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        switch column.id {
        case "mark": return row % 3 == 0 ? .mark(Self.marks[row % 2]) : .empty
        case "name": return .text("Campaign \(row) — Summer sale")
        case "status": return .tags([Self.statuses[row % 3]])
        case "channels": return .tags([NGTag("Google"), NGTag("Meta", color: .blue)])
        default:
            let seed = Double((row &* 7919 &+ column.id.hashValue) % 100_000)
            return .number(column.id.hasPrefix("p") ? seed / 100_000 : seed * 1.37)
        }
    }
}

@MainActor
func makeWideColumns() -> [NGColumnItem] {
    var items: [NGColumnItem] = [
        .column(NGTableColumn("mark", title: "", width: 30, alignment: .center, isResizable: false, pin: .leading)),
        .column(NGTableColumn("name", title: "Campaign", width: 220, pin: .leading)),
        .column(NGTableColumn("status", title: "Status", width: 100)),
        .column(NGTableColumn("channels", title: "Channels", width: 140)),
    ]
    for index in 0..<39 {
        let id = index % 4 == 3 ? "p\(index)" : "m\(index)"
        let format: NGValueFormat = index % 4 == 3 ? .percent(fractionDigits: 1) : .currency(code: "EUR")
        items.append(.column(NGTableColumn(id, title: "Metric \(index)", width: 100, alignment: .automatic,
                                           format: format, summary: .aggregate(.sum))))
    }
    return items
}

/// The benchmarks run one at a time (each suite of them is in this one):
/// run alongside, their timings would mix. Skipped unless NGTABLE_BENCH is set.
@Suite("Benchmarks", .serialized, .enabled(if: ProcessInfo.processInfo.environment["NGTABLE_BENCH"] != nil))
struct NGBenchmarks {}

extension NGBenchmarks {
    @Suite("Scroll benchmark", .enabled(if: ProcessInfo.processInfo.environment["NGTABLE_BENCH"] != nil))
    @MainActor
    struct NGScrollBenchmark {
        /// Display refresh rate to simulate: sets the frame pacing.
        static let hertz = Double(ProcessInfo.processInfo.environment["NGTABLE_BENCH_HZ"] ?? "") ?? 120

        @Test func flickThroughAWideTable() {
            let frame = NSRect(x: 0, y: 0, width: 2560, height: 1400)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            let dataSource = WideDataSource()
            let table = NGTableView(frame: frame)
            // Drawn even when other windows cover it (the frames are what's measured).
            table.drawsWhileUnseenForTesting = true
            window.contentView = table
            table.columns = makeWideColumns()
            table.dataSource = dataSource
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()

            // At rest first, like a user who stops before flicking.
            let spins = ProcessInfo.processInfo.environment["NGTABLE_BENCH_SPIN"] != nil
            let spinning = OSAllocatedUnfairLock(initialState: true)
            if spins {
                Thread.detachNewThread { while spinning.withLock({ $0 }) {} }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            spinning.withLock { $0 = false }
            var times: [Double] = []
            var layoutTimes: [Double] = []
            var frameTimes: [Double] = []
            // A flick: ~30 rows per frame, then slowing down.
            var y: CGFloat = 0
            let framesBefore = NGTableView.metalFramesForTesting
            for step in 0..<200 {
                if let rows = Double(ProcessInfo.processInfo.environment["NGTABLE_BENCH_ROWS"] ?? "") {
                    // Steady scrolling instead of a flick; a pause every 40 frames.
                    y += step % 40 < 30 ? CGFloat(rows) * table.rowHeight : 0
                } else {
                    y += CGFloat(max(2, 40 - step / 5)) * table.rowHeight * 0.75
                }
                let start = CACurrentMediaTime()
                table.setContentOffset(CGPoint(x: 0, y: y))
                window.displayIfNeeded()
                layoutTimes.append((CACurrentMediaTime() - start) * 1000)
                // The Metal frame (built and encoded), as before Core Animation commits.
                let frameStart = CACurrentMediaTime()
                table.drawMetalFrameIfNeeded()
                frameTimes.append((CACurrentMediaTime() - frameStart) * 1000)
                CATransaction.flush()
                times.append((CACurrentMediaTime() - start) * 1000)
                // The rest of a 120 Hz frame.
                RunLoop.current.run(until: Date(timeIntervalSinceNow: max(0, 1.0 / Self.hertz - (CACurrentMediaTime() - start))))
                CATransaction.flush()
            }
            // Each step drew (a covered window would draw nothing and measure nothing).
            #expect(NGTableView.metalFramesForTesting - framesBefore >= 150)
            let sorted = times.sorted()
            let average = times.reduce(0, +) / Double(times.count)
            print("BENCH \(Int(Self.hertz)) Hz cells=\(table.visibleCells.count) avg=\(String(format: "%.2f", average))ms p50=\(String(format: "%.2f", sorted[times.count / 2]))ms p95=\(String(format: "%.2f", sorted[times.count * 95 / 100]))ms max=\(String(format: "%.2f", sorted.last ?? 0))ms layout=\(String(format: "%.2f", layoutTimes.reduce(0, +) / Double(layoutTimes.count)))ms metal frame=\(String(format: "%.2f", frameTimes.reduce(0, +) / Double(frameTimes.count)))ms")
            let worst = times.enumerated().sorted { $0.element > $1.element }.prefix(5).map { "#\($0.offset):\(String(format: "%.1f", $0.element))/layout \(String(format: "%.1f", layoutTimes[$0.offset]))" }
            print("BENCH worst \(worst)")
            window.orderOut(nil)
            withExtendedLifetime(dataSource) {}
        }

        @Test func swipeSideways() {
            let frame = NSRect(x: 0, y: 0, width: 2560, height: 1400)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            let dataSource = WideDataSource()
            let table = NGTableView(frame: frame)
            // Drawn even when other windows cover it (the frames are what's measured).
            table.drawsWhileUnseenForTesting = true
            window.contentView = table
            table.columns = makeWideColumns()
            table.dataSource = dataSource
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            var times: [Double] = []
            var x: CGFloat = 0
            for _ in 0..<150 {
                x = min(x + 11, table.layoutMetrics.maxOffset.x)
                let start = CACurrentMediaTime()
                table.setContentOffset(CGPoint(x: x, y: 0))
                window.displayIfNeeded()
                CATransaction.flush()
                times.append((CACurrentMediaTime() - start) * 1000)
                // Frames at 120 Hz: the render server gets to show each one.
                Thread.sleep(forTimeInterval: max(0, 1.0 / 120 - (CACurrentMediaTime() - start)))
            }
            let sorted = times.sorted()
            print("BENCH sideways worst", times.enumerated().sorted { $0.element > $1.element }.prefix(4).map { "#\($0.offset):\(String(format: "%.1f", $0.element))" })
            print("BENCH sideways avg=\(String(format: "%.2f", times.reduce(0, +) / Double(times.count)))ms p95=\(String(format: "%.2f", sorted[times.count * 95 / 100]))ms max=\(String(format: "%.2f", sorted.last ?? 0))ms")
            window.orderOut(nil)
            withExtendedLifetime(dataSource) {}
        }

        @Test func clickThroughRows() {
            let frame = NSRect(x: 0, y: 0, width: 2560, height: 1400)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            let dataSource = WideDataSource()
            let table = NGTableView(frame: frame)
            // Drawn even when other windows cover it (the frames are what's measured).
            table.drawsWhileUnseenForTesting = true
            window.contentView = table
            table.columns = makeWideColumns()
            table.dataSource = dataSource
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            var times: [Double] = []
            for row in 0..<40 {
                let start = CACurrentMediaTime()
                table.selectRowIndexes([row], byExtendingSelection: false)
                window.displayIfNeeded()
                CATransaction.flush()
                times.append((CACurrentMediaTime() - start) * 1000)
            }
            let sorted = times.sorted()
            print("BENCH select avg=\(String(format: "%.2f", times.reduce(0, +) / Double(times.count)))ms max=\(String(format: "%.2f", sorted.last ?? 0))ms")
            window.orderOut(nil)
            withExtendedLifetime(dataSource) {}
        }

        /// Samples the main thread while flicking up and down for a few seconds.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["NGTABLE_BENCH_SAMPLE"] != nil))
        func sampleFlicks() throws {
            let frame = NSRect(x: 0, y: 0, width: 2560, height: 1400)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            let dataSource = WideDataSource()
            let table = NGTableView(frame: frame)
            // Drawn even when other windows cover it (the frames are what's measured).
            table.drawsWhileUnseenForTesting = true
            window.contentView = table
            table.columns = makeWideColumns()
            table.dataSource = dataSource
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            let sampler = Process()
            sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sampler.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "4", "1", "-mayDie", "-file", "/tmp/ngtable-sample.txt"]
            try sampler.run()
            Thread.sleep(forTimeInterval: 0.3)
            let end = CACurrentMediaTime() + 10
            var y: CGFloat = 0, direction: CGFloat = 1
            let sideways = ProcessInfo.processInfo.environment["NGTABLE_BENCH_SIDEWAYS"] != nil
            let rests = ProcessInfo.processInfo.environment["NGTABLE_BENCH_RESTS"] != nil
            var steps = 0
            while CACurrentMediaTime() < end {
                steps += 1
                if rests, steps % 3 == 0 {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
                }
                y += direction * (sideways ? 11 : 30 * table.rowHeight)
                let limit = sideways ? table.layoutMetrics.maxOffset.x : table.layoutMetrics.maxOffset.y
                if y > limit || y < 0 { direction = -direction; y = min(max(y, 0), limit) }
                table.setContentOffset(sideways ? CGPoint(x: y, y: 0) : CGPoint(x: 0, y: y))
                window.displayIfNeeded()
                CATransaction.flush()
                // Let the render link run like between frames.
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
            }
            sampler.waitUntilExit()
            window.orderOut(nil)
            withExtendedLifetime(dataSource) {}
        }
    }
}
