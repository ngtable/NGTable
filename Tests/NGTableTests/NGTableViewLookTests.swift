#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// NSTableView's appearance properties by their names, column autoresizing
/// and swipe actions.
@Suite("NSTableView look")
@MainActor
struct NGTableViewLookTests {
    final class Rows: NGTableViewDataSource, NGTableViewDelegate {
        var count = 1000
        var swiped: [(String, Int)] = []
        func numberOfRows(in tableView: NGTableView) -> Int { count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text("r\(row)") }
        func tableView(_ tableView: NGTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NGRowAction] {
            guard edge == .trailing else { return [] }
            return [NGRowAction(style: .destructive, title: "Delete") { _, row in self.swiped.append(("delete", row)) },
                    NGRowAction(style: .regular, title: "Archive") { _, row in self.swiped.append(("archive", row)) }]
        }
    }

    private func makeTable(_ rows: Rows, width: CGFloat = 600) -> (NGTableView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: width, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = [.column(NGTableColumn("a", title: "A", width: 100)), .column(NGTableColumn("b", title: "B", width: 100)),
                         .column(NGTableColumn("c", title: "C", width: 100, minWidth: 60, maxWidth: 400))]
        window.contentView = table
        table.dataSource = rows
        table.delegate = rows
        table.layoutSubtreeIfNeeded()
        return (table, window)
    }

    @Test func appearanceProperties() {
        let rows = Rows()
        let (table, window) = makeTable(rows)
        defer { withExtendedLifetime((window, rows)) {} }
        // The header hidden: rows start at the top.
        table.showsHeader = false
        #expect(table.layoutMetrics.headerHeight == 0)
        #expect(table.rect(ofRow: 0).minY == 0)
        table.showsHeader = true
        #expect(table.layoutMetrics.headerHeight > 0)
        // Grid lines and their color.
        table.gridStyleMask = [.solidVerticalGridLineMask, .dashedHorizontalGridLineMask]
        #expect(table.showsVerticalGridLines && table.gridStyleMask == [.solidVerticalGridLineMask, .dashedHorizontalGridLineMask])
        table.gridColor = .systemPink
        #expect(table.gridColor == .systemPink)
        var quads: [NGMetalQuad] = []
        let background = NGRowBackground()
        background.frame = CGRect(x: 0, y: 0, width: 200, height: 24)
        table.appendHorizontalGridLines([(background, 0)], origin: .zero, clip: CGRect(x: 0, y: 0, width: 200, height: 300),
                                        scale: 2, style: table.metalStyle, to: &quads)
        #expect(quads.count == 50)   // Dashes of 2 points every 4.
        // Background, spacing, style, row size.
        table.backgroundColor = .systemYellow
        #expect(table.tableStyle.backgroundColor == .systemYellow)
        let height = table.rowHeight
        table.intercellSpacing = NSSize(width: 6, height: 4)
        #expect(table.rowHeight == height + 4)
        table.style = .plain
        #expect(table.selectionHighlightStyle == .fullWidth && table.style == .fullWidth)
        table.style = .inset
        #expect(table.selectionHighlightStyle == .rounded)
        table.rowSizeStyle = .large
        #expect(table.density == .spacious && table.rowSizeStyle == .large)
        // Cells of rows out of view.
        let frame = table.frameOfCell(atColumn: 1, row: 500)
        #expect(frame.minY == table.rect(ofRow: 500).minY && frame.width == table.rect(ofColumn: 1).width)
        #expect(table.frameOfCell(row: 500, columnID: "b") == nil)
    }

    @Test func columnsAutoresize() throws {
        let rows = Rows()
        let (table, window) = makeTable(rows)
        defer { withExtendedLifetime((window, rows)) {} }
        func width(_ id: String) -> Double { table.width(ofColumnID: id) ?? 0 }
        // None (the default): widths stay.
        table.setFrameSize(NSSize(width: 700, height: 300))
        table.layoutSubtreeIfNeeded()
        #expect(width("c") == 100)
        // The last column only, within its maximum.
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setFrameSize(NSSize(width: 800, height: 300))
        table.layoutSubtreeIfNeeded()
        #expect(width("c") == 200)
        // Uniformly: the others take what a column at its minimum can't.
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setFrameSize(NSSize(width: 500, height: 300))
        table.layoutSubtreeIfNeeded()
        // 300 points less in three: A and B stop at 40, C at its minimum of 60.
        #expect(width("a") == 40 && width("b") == 40 && width("c") == 60)
        // The last column fills the room left.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setWidth(100, forColumnID: "a")
        table.setWidth(100, forColumnID: "b")
        table.setWidth(100, forColumnID: "c")
        table.sizeLastColumnToFit()
        let free = table.layoutMetrics.leadingWidth + table.layoutMetrics.centerWidth + table.layoutMetrics.trailingWidth
        #expect(abs(table.geometry.center.width + table.geometry.leading.width + table.geometry.trailing.width - free) < 2)
    }

    /// Room added between rows stays when the density sets the row height
    /// (and with a new style), and VoiceOver reads nothing during a batch
    /// that moved rows.
    @Test func spacingSurvivesDensityAndReadsWaitForBatches() {
        let rows = Rows()
        let (table, window) = makeTable(rows)
        defer { withExtendedLifetime((window, rows)) {} }
        table.density = .compact
        let compact = table.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 6)
        #expect(table.rowHeight == compact + 6)
        table.density = .regular
        table.density = .compact
        #expect(table.rowHeight == compact + 6)
        // A stale batch: no reads of rows that moved.
        table.beginUpdates()
        rows.count += 1
        table.insertRows(at: [0])
        #expect(table.accessibilityText(row: 0, column: table.tableColumns[0]) == nil)
        table.endUpdates()
        #expect(table.accessibilityText(row: 0, column: table.tableColumns[0]) != nil)
    }

    /// A slow live resize in 1-point steps moves uniformly autoresized
    /// columns by the whole change, and only real width changes are told.
    @Test func slowLiveResizeKeepsEveryPoint() {
        let rows = Rows()
        let (table, window) = makeTable(rows)
        defer { withExtendedLifetime((window, rows)) {} }
        final class Counter: NSObject { var count = 0; @objc func resized(_ note: Notification) { count += 1 } }
        let counter = Counter()
        NotificationCenter.default.addObserver(counter, selector: #selector(Counter.resized(_:)),
                                               name: NGTableView.columnDidResizeNotification, object: table)
        defer { NotificationCenter.default.removeObserver(counter) }
        func total() -> Double { ["a", "b", "c"].reduce(0) { $0 + (table.width(ofColumnID: $1) ?? 0) } }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.layoutSubtreeIfNeeded()
        let start = total()
        for step in 1...30 {
            table.setFrameSize(NSSize(width: 600 + CGFloat(step), height: 300))
            table.layoutSubtreeIfNeeded()
        }
        #expect(abs(total() - (start + 30)) <= 1, "\(total()) for \(start) + 30")
        // Only real changes are told: 30 points in pixels, one column each.
        #expect(counter.count <= 30 * Int(table.window?.backingScaleFactor ?? 1))
    }

    /// A trackpad scroll event with a gesture phase.
    private func swipeEvent(dx: Int32, phase: Int64, window: NSWindow, at point: NSPoint) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)   // kCGScrollWheelEventScrollPhase
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        // Quartz's screen coordinates start at the top of the main screen.
        let screen = window.convertPoint(toScreen: point)
        event.location = CGPoint(x: screen.x, y: CGDisplayBounds(CGMainDisplayID()).height - screen.y)
        return try #require(NSEvent(cgEvent: event))
    }

    @Test func swipeActions() throws {
        let rows = Rows()
        let (table, window) = makeTable(rows, width: 420)   // Columns fit: nothing to scroll sideways.
        defer { withExtendedLifetime((window, rows)) {} }
        // A borderless window at the screen's origin: event locations map back exactly.
        window.styleMask = [.borderless]
        window.setFrame(NSRect(x: 0, y: 0, width: 420, height: 300), display: false)
        table.layoutSubtreeIfNeeded()
        let point = table.convert(NSPoint(x: 150, y: table.rect(ofRow: 2).midY), to: nil)
        let began = try swipeEvent(dx: 0, phase: 1, window: window, at: point)
        guard began.phase.contains(.began) else { return }   // Events from CGEvent without phases on this system.
        table.scrollWheel(with: began)
        for _ in 0..<3 { table.scrollWheel(with: try swipeEvent(dx: -40, phase: 2, window: window, at: point)) }
        table.scrollWheel(with: try swipeEvent(dx: 0, phase: 4, window: window, at: point))
        #expect(table.rowActionsVisible)
        let buttons = try #require(table.rowActionButtons?.subviews as? [NSButton])
        #expect(buttons.map(\.title) == ["Delete", "Archive"])
        buttons[1].performClick(nil)
        #expect(rows.swiped.map(\.0) == ["archive"] && rows.swiped.first?.1 == 2)
        #expect(!table.rowActionsVisible)
    }
}
#endif
