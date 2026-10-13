#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Ratings: stars that sort and sum as their number; in an editable column a
/// click on a star sets it (with Undo), just before the first one clears it,
/// a number key sets the focused one, and the pointer previews the value.
@Suite("Rating cells")
@MainActor
struct NGRatingCellTests {
    @MainActor
    final class Ratings: NGTableViewDataSource {
        var stars = [3, 1, 5, 0]
        func numberOfRows(in tableView: NGTableView) -> Int { stars.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            column.id == "name" ? .text("Row \(row)") : .rating(stars[row])
        }
        func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
            if case .rating(let stars, _) = value { self.stars[row] = stars }
        }
    }

    private func makeTable(_ ratings: Ratings, editable: Bool = true) -> (NGTableView, NSWindow) {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: table.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 100)),
                         .column(NGTableColumn("stars", title: "Stars", width: 140, summary: .aggregate(.average), isEditable: editable))]
        window.contentView = table
        table.dataSource = ratings
        table.navigatesByCell = true
        table.layoutSubtreeIfNeeded()
        window.makeFirstResponder(table)
        return (table, window)
    }

    /// The window point at the middle of a star (1-based), or just before the first.
    private func point(_ table: NGTableView, row: Int, star: Int) throws -> NSPoint {
        let frame = try #require(table.frameOfCell(row: row, columnID: "stars"))
        let stars = NGTableView.ratingStars(maximum: 5, alignment: .left, in: CGRect(origin: .zero, size: frame.size))
        let x = star == 0 ? stars[0].minX - 3 : stars[star - 1].midX
        return table.convert(NSPoint(x: frame.minX + x, y: frame.midY), to: nil)
    }

    private func click(_ table: NGTableView, at location: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            type == .leftMouseDown ? table.rowsMouseDown(event, in: table.centerRegion) : table.rowsMouseUp(event)
        }
    }

    @Test func theValue() {
        #expect(NGCellValue.rating(4).numericValue == 4)
        #expect(NGCellValue.rating(2).sortsBefore(.rating(3)))
        #expect(NGValueFormat.automatic.string(for: .rating(3), locale: Locale(identifier: "en_US")) == "3")
    }

    @Test func clicksKeysAndThePointer() throws {
        let ratings = Ratings()
        let (table, window) = makeTable(ratings)
        defer { withExtendedLifetime((ratings, window)) {} }
        try click(table, at: try point(table, row: 1, star: 4), in: window)
        #expect(ratings.stars[1] == 4)
        #expect(table.selectedRowIndexes.isEmpty)
        // (One undo group here, without the run loop's events: one change to undo.)
        try #require(table.undoManager).undo()
        #expect(ratings.stars[1] == 1)
        try click(table, at: try point(table, row: 1, star: 4), in: window)
        try click(table, at: try point(table, row: 0, star: 0), in: window)
        #expect(ratings.stars[0] == 0 && ratings.stars[1] == 4)
        // A number key on the focused cell (more than the maximum: not taken).
        table.focusedCell = NGCellPosition(row: 2, columnID: "stars")
        for key in ["2", "9"] {
            table.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                              windowNumber: window.windowNumber, context: nil, characters: key,
                                                              charactersIgnoringModifiers: key, isARepeat: false, keyCode: 19)))
        }
        #expect(ratings.stars[2] == 2)
        // The pointer over the third star previews 3.
        table.pointerLocationForTesting = try point(table, row: 3, star: 3)
        table.updateHoveredCellFromPointer()
        #expect(table.visibleCell(sourceRow: 3, columnID: "stars")?.previewRating == 3)
        #expect(!table.showsPointingHand)
        let column = table.tableColumns[1]
        #expect(table.accessibilityText(row: table.displayIndex(ofRow: 1)!, column: column) == "4 of 5 stars")
        #expect(table.summaryValue(forColumnID: "stars") == Double(0 + 4 + 2 + 0) / 4)
    }

    /// Not editable: stars to look at; a click selects the row.
    @Test func readOnlyRatings() throws {
        let ratings = Ratings()
        let (table, window) = makeTable(ratings, editable: false)
        defer { withExtendedLifetime((ratings, window)) {} }
        try click(table, at: try point(table, row: 0, star: 5), in: window)
        #expect(ratings.stars[0] == 3 && table.selectedRowIndexes == [0])
    }
}
#endif
