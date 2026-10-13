#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Right to left: the layout, clicks, scrolling, keys and what cells draw
/// are mirrored; text still reads as written.
@Suite("Right to left")
@MainActor
struct NGRightToLeftTests {
    final class Rows: NGTableViewDataSource {
        func numberOfRows(in tableView: NGTableView) -> Int { 50 }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            column.id == "id" ? .text("#\(row)") : .text("نص \(column.id) \(row)")
        }
    }

    private func makeTable(_ rows: Rows, width: CGFloat = 600) -> (NGTableView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: width, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.userInterfaceLayoutDirection = .rightToLeft
        table.columns = [.column(NGTableColumn("id", title: "ID", width: 80, pin: .leading))]
            + (0..<8).map { .column(NGTableColumn("c\($0)", title: "C\($0)", width: 120)) }
        window.contentView = table
        table.dataSource = rows
        table.layoutSubtreeIfNeeded()
        return (table, window)
    }

    @Test func geometryIsMirrored() throws {
        let layout = NGColumnLayout(items: [.column(NGTableColumn("a", title: "A", width: 100)),
                                            .column(NGTableColumn("b", title: "B", width: 50))])
        let geometry = NGGridGeometry(layout: layout, isRightToLeft: true, centerSpan: 400)
        // The first column at the right end of the span, columns listed by x.
        #expect(geometry.center.columns.map(\.column.id) == ["b", "a"])
        #expect(geometry.center.columns.map(\.x) == [250, 300])
        #expect(geometry.center.column(atX: 350)?.column.id == "a")
    }

    @Test func layoutClicksAndScrolling() throws {
        let rows = Rows()
        let (table, window) = makeTable(rows)
        defer { withExtendedLifetime((window, rows)) {} }
        // Leading frozen columns at the right edge, the scrolling ones to their left.
        #expect(table.leadingRegion.frame.maxX == table.bounds.width)
        #expect(table.centerRegion.frame.maxX == table.leadingRegion.frame.minX)
        let id = try #require(table.frameOfCell(row: 0, columnID: "id"))
        let first = try #require(table.frameOfCell(row: 0, columnID: "c0"))
        // (The outer edge margin is at the right too.)
        #expect(id.maxX == table.bounds.width - NGMetrics.contentEdgeInset && first.maxX <= id.minX + 1)
        // A click at the right edge is on the first column.
        #expect(table.column(at: NSPoint(x: table.bounds.width - 20, y: id.midY)) == 0)
        // Scrolled to the start, the first scrolling column shows at the right;
        // scrolling to the last brings it in view at the left.
        #expect(table.contentOffset.x == 0)
        table.scrollColumnToVisible(8)
        #expect(table.contentOffset.x > 0)
        let last = try #require(table.frameOfCell(row: 0, columnID: "c7"))
        #expect(last.minX >= table.centerRegion.frame.minX - 1)
        // Fingers moving right scroll on toward the trailing end.
        table.scrollColumnToVisible(1)
        let before = table.contentOffset.x
        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 30, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: scroll))
        table.scrollWheel(with: event)
        #expect(table.contentOffset.x > before)
    }

    @Test func keysResizingAndButtons() throws {
        let rows = Rows()
        let (table, window) = makeTable(rows)
        defer { withExtendedLifetime((window, rows)) {} }
        // Left goes on to the next column.
        table.navigatesByCell = true
        table.focusCell(displayRow: 0, columnID: "c0")
        table.moveLeft(nil)
        #expect(table.focusedCell?.columnID == "c1")
        table.moveRight(nil)
        #expect(table.focusedCell?.columnID == "c0")
        // A scrolling column resizes from its left (trailing) edge.
        let column = try #require(table.frameOfCell(row: 0, columnID: "c0"))
        let handle = table.resizeHandle(at: NSPoint(x: column.minX, y: 10), headerHeight: table.layoutMetrics.headerHeight)
        #expect(handle?.frame.column.id == "c0")
        // The filter button and trailing swipe actions at the left.
        let title = NSRect(x: 100, y: 0, width: 120, height: 28)
        #expect(table.filterButtonRect(inTitleRect: title).minX < title.midX)
        #expect(!table.buttonsOnRight(.trailing))
        // The vertical overlay scroller is at the left, mirrored inside.
        #expect(table.verticalOverlayScroller.isMirrored)
    }

    /// Text of a leading-aligned column shows at the right of its cell.
    @Test func cellContentIsDrawnMirrored() throws {
        let rows = Rows()
        let (table, window) = makeTable(rows)
        defer { withExtendedLifetime((window, rows)) {} }
        // Dark text on a light background, whatever the system's appearance.
        window.appearance = NSAppearance(named: .aqua)
        table.layoutSubtreeIfNeeded()
        let cell = try #require(table.frameOfCell(row: 0, columnID: "c0"))
        let image = try #require(table.metalSnapshot())
        let scale = CGFloat(image.width) / table.bounds.width
        let rep = NSBitmapImageRep(cgImage: image)
        // Dark pixels (text) in the cell's left and right halves.
        var left = 0, right = 0
        for y in Int(cell.minY * scale)..<Int(cell.maxY * scale) {
            for x in Int(cell.minX * scale)..<Int(cell.maxX * scale) {
                guard let color = rep.colorAt(x: x, y: y), color.brightnessComponent < 0.5 else { continue }
                if CGFloat(x) < cell.midX * scale { left += 1 } else { right += 1 }
            }
        }
        #expect(right > left * 3)
    }
}
#endif
