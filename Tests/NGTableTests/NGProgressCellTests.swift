#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Progress bars: values that sort, sum and export as their fraction (an
/// indeterminate one first, like an empty cell); written beside the bar
/// with the column's format; read out as a percentage or "in progress";
/// frames come while an indeterminate one shows, and stop after.
@Suite("Progress cells")
@MainActor
struct NGProgressCellTests {
    @MainActor
    final class Jobs: NGTableViewDataSource {
        var done: [Double?] = [3, nil, 10, 0]
        func numberOfRows(in tableView: NGTableView) -> Int { done.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            .progress(done[row], total: 10)
        }
    }

    @Test func theValue() {
        #expect(NGCellValue.progress(3, total: 4).numericValue == 0.75)
        #expect(NGCellValue.progress(nil).numericValue == nil)
        #expect(NGCellValue.progress(12, total: 10).numericValue == 1)   // Clamped.
        #expect(NGValueFormat.automatic.string(for: .progress(0.45), locale: Locale(identifier: "en_US")) == "45%")
        #expect(NGValueFormat.percent(fractionDigits: 1).string(for: .progress(1, total: 3), locale: Locale(identifier: "en_US")) == "33.3%")
        #expect(NGValueFormat.automatic.string(for: .progress(nil)) == "")
        let sorted: [NGCellValue] = [.progress(0.9), .progress(nil), .progress(0.2)].sorted { $0.sortsBefore($1) }
        #expect(sorted == [.progress(nil), .progress(0.2), .progress(0.9)])
    }

    @Test func inATable() async throws {
        let jobs = Jobs()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let window = NSWindow(contentRect: table.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        table.columns = [.column(NGTableColumn("done", title: "Done", width: 150, format: .percent(fractionDigits: 0),
                                               summary: .aggregate(.average)))]
        window.contentView = table
        table.dataSource = jobs
        // As if on screen (frames aren't asked for for a window nobody sees).
        table.drawsWhileUnseenForTesting = true
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((jobs, window)) {} }
        let done = table.tableColumns[0]
        #expect(table.cellContent(for: .progress(3, total: 10), in: done)
                == .progress(fraction: 0.3, text: done.format.string(for: Double(0.3)), reserved: done.format.string(for: Double(1))))
        #expect(table.summaryValue(forColumnID: "done").map { abs($0 - 13.0 / 30) < 1e-9 } == true)
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "done", ascending: true)]
        #expect((0..<table.numberOfRows).map(table.sourceRow) == [1, 3, 0, 2])
        #expect(table.accessibilityText(row: table.displayIndex(ofRow: 1)!, column: done) == "in progress")
        #expect(table.accessibilityText(row: table.displayIndex(ofRow: 0)!, column: done) == done.format.string(for: Double(0.3)))
        // An indeterminate bar in view: frames keep coming; without one, they stop.
        let renderer = try #require(table.metalRenderer)
        _ = table.buildMetalQuads(renderer: renderer, scale: 2)
        #expect(table.progressLink != nil)
        jobs.done[1] = 5
        table.reloadData(forRowIndexes: [1], columnIndexes: [0])
        table.layoutSubtreeIfNeeded()
        _ = table.buildMetalQuads(renderer: renderer, scale: 2)
        #expect(table.progressLink == nil)
        // Off the window, it stops too.
        jobs.done[1] = nil
        table.reloadData(forRowIndexes: [1], columnIndexes: [0])
        table.layoutSubtreeIfNeeded()
        _ = table.buildMetalQuads(renderer: renderer, scale: 2)
        #expect(table.progressLink != nil)
        table.removeFromSuperview()
        #expect(table.progressLink == nil)
    }
}
#endif
