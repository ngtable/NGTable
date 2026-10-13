#if os(macOS)
import AppKit
import Testing
@testable import NGTable

@Suite("Pointer over cells")
@MainActor
struct NGPointerTests {
    @MainActor
    final class Recorder: NGTableViewDataSource, NGTableViewDelegate {
        var events: [String] = []
        func numberOfRows(in tableView: NGTableView) -> Int { 200 }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            column.id == "group" ? .text(row < 100 ? "A" : "B") : .text("\(column.id)\(row)")
        }
        func tableView(_ tableView: NGTableView, pointerDidEnterRow row: Int, column: NGTableColumn) {
            events.append("enter \(row) \(column.id)")
        }
        func tableView(_ tableView: NGTableView, pointerDidExitRow row: Int, column: NGTableColumn) {
            events.append("exit \(row) \(column.id)")
        }
    }

    private func makeTable(_ recorder: Recorder) -> (NGTableView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = [.column(NGTableColumn("a", title: "A", width: 150)), .column(NGTableColumn("b", title: "B", width: 150))]
        window.contentView = table
        table.dataSource = recorder
        table.delegate = recorder
        table.layoutSubtreeIfNeeded()
        return (table, window)
    }

    /// A point of the table's rows area, in window coordinates (the table fills the window).
    private func windowPoint(_ table: NGTableView, x: CGFloat, row: Int) -> NSPoint {
        let y = table.layoutMetrics.headerHeight + (CGFloat(row) + 0.5) * table.rowHeight - table.contentOffset.y
        return table.convert(NSPoint(x: x, y: y), to: nil)
    }

    @Test func enterAndExitFollowThePointer() {
        let recorder = Recorder()
        let (table, window) = makeTable(recorder)
        defer { withExtendedLifetime((window, recorder)) {} }
        table.updateHoveredCell(atWindowPoint: windowPoint(table, x: 20, row: 2))
        #expect(table.hoveredCell == NGCellPosition(row: 2, columnID: "a"))
        table.updateHoveredCell(atWindowPoint: windowPoint(table, x: 30, row: 2))   // The same cell: nothing.
        table.updateHoveredCell(atWindowPoint: windowPoint(table, x: 200, row: 3))
        // Over the header: no cell.
        table.updateHoveredCell(atWindowPoint: table.convert(NSPoint(x: 20, y: 5), to: nil))
        #expect(table.hoveredCell == nil)
        #expect(recorder.events == ["enter 2 a", "exit 2 a", "enter 3 b", "exit 3 b"])
    }

    /// A row inserted above a resting pointer puts another record under it,
    /// at the same index: the pointer leaves the old one and enters the new.
    @Test func rowsComingUnderARestingPointer() {
        @MainActor final class Rows: NGTableViewDataSource, NGTableViewDelegate {
            var names = (0..<50).map { "r\($0)" }
            var events: [String] = []
            func numberOfRows(in tableView: NGTableView) -> Int { names.count }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text(names[row]) }
            func tableView(_ tableView: NGTableView, pointerDidEnterRow row: Int, column: NGTableColumn) { events.append("enter \(names[row])") }
            func tableView(_ tableView: NGTableView, pointerDidExitRow row: Int, column: NGTableColumn) { events.append("exit \(row)") }
        }
        let rows = Rows()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = [.column(NGTableColumn("a", title: "A", width: 150))]
        window.contentView = table
        table.dataSource = rows
        table.delegate = rows
        table.layoutSubtreeIfNeeded()
        table.pointerLocationForTesting = windowPoint(table, x: 20, row: 2)
        table.updateHoveredCellFromPointer()
        rows.names.insert("new", at: 0)
        table.insertRows(at: [0])
        table.updateHoveredCellFromPointer()
        #expect(rows.events == ["enter r2", "exit 2", "enter r1"])
        withExtendedLifetime((window, rows)) {}
    }

    /// The rows scroll under a resting pointer: the cell under it changes
    /// without the mouse moving.
    @Test func scrollingUnderARestingPointer() {
        let recorder = Recorder()
        let (table, window) = makeTable(recorder)
        defer { withExtendedLifetime((window, recorder)) {} }
        table.pointerLocationForTesting = windowPoint(table, x: 20, row: 2)
        table.updateHoveredCellFromPointer()
        table.setContentOffset(CGPoint(x: 0, y: table.rowHeight * 3))
        #expect(table.hoveredCell == NGCellPosition(row: 5, columnID: "a"))
        #expect(recorder.events == ["enter 2 a", "exit 2 a", "enter 5 a"])
        // Leaving the window ends it.
        table.removeFromSuperview()
        #expect(table.hoveredCell == nil)
        #expect(recorder.events.last == "exit 5 a")
    }

    /// Reloads the row under the pointer, e.g. to show it differently.
    @MainActor
    final class HoverReloader: NGTableViewDataSource, NGTableViewDelegate {
        var hovered: Int?
        func numberOfRows(in tableView: NGTableView) -> Int { 50 }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            .text(row == hovered ? "hot\(row)" : "cold\(row)")
        }
        func tableView(_ tableView: NGTableView, pointerDidEnterRow row: Int, column: NGTableColumn) {
            hovered = row
            tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
        }
    }

    /// A layout pass that finds the pointer over another cell tells the
    /// delegate after the pass: a row it reloads then is placed again (inside
    /// the pass its cell was left out until the next layout).
    @Test func reloadingTheHoveredRowFromALayoutPass() {
        let data = HoverReloader()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = [.column(NGTableColumn("a", title: "A", width: 150))]
        window.contentView = table
        table.dataSource = data
        table.delegate = data
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((window, data)) {} }
        table.pointerLocationForTesting = windowPoint(table, x: 20, row: 2)
        table.needsLayout = true
        table.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        #expect(table.hoveredCell == NGCellPosition(row: 2, columnID: "a"))
        let cell = table.visibleCell(row: 2, columnID: "a")
        #expect({ if case .text("hot2", _, _) = cell?.content { true } else { false } }())
    }

    /// Group header rows have no cell.
    @Test func groupHeadersHaveNoCell() {
        let recorder = Recorder()
        let (table, window) = makeTable(recorder)
        defer { withExtendedLifetime((window, recorder)) {} }
        table.rowGrouping = NGRowGrouping(columnID: "group")
        table.layoutSubtreeIfNeeded()
        table.updateHoveredCell(atWindowPoint: windowPoint(table, x: 20, row: 0))   // Header row "A".
        #expect(table.hoveredCell == nil)
        table.updateHoveredCell(atWindowPoint: windowPoint(table, x: 20, row: 1))   // Data row 0.
        #expect(table.hoveredCell == NGCellPosition(row: 0, columnID: "a"))
    }
}
#endif
