#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Columns that wrap text: rows as high as their text, measured by the table.
@MainActor
@Suite("Wrapped rows")
struct NGWrappedRowsTests {
    static let long = "The quick brown fox jumps over the lazy dog and runs far away into the woods"

    final class Notes: NGTableViewDataSource {
        var texts: [String]
        init(_ texts: [String]) { self.texts = texts }
        func numberOfRows(in tableView: NGTableView) -> Int { texts.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            column.id == "note" ? .text(texts[row]) : .text("Row \(row)")
        }
        func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { row }
    }

    func makeTable(_ notes: Notes, note: NGTableColumn = NGTableColumn("note", title: "Note", width: 140).wrappingText(),
                   height: CGFloat = 400) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 80)), .column(note)]
        table.dataSource = notes
        table.layoutSubtreeIfNeeded()
        return table
    }

    /// A display row's height and top, as the table places it.
    func height(_ table: NGTableView, _ row: Int) -> CGFloat { table.rowGeometry.height(of: row) }
    func top(_ table: NGTableView, _ row: Int) -> CGFloat { table.rowGeometry.top(of: row) }

    /// The height `text` takes in the note column, as the table draws it.
    func expectedHeight(_ table: NGTableView, _ text: String, maximumLines: Int = .max) throws -> CGFloat {
        let shaper = try #require(table.metalRenderer?.shaper)
        let font = table.metalStyle.textFont
        let width = try #require(table.width(ofColumnID: "note")) - 2 * Double(NGMetrics.cellPadding)
        let lines = shaper.shapeLines(text, font: font, width: CGFloat(width), maximumLines: maximumLines).count
        return table.rowHeight + CGFloat(max(0, lines - 1)) * NGLineHeights.height(of: font)
    }

    @Test func rowsGrowToTheirWrappedText() throws {
        let notes = Notes(["Short", Self.long, "", Self.long + " " + Self.long])
        let table = makeTable(notes)
        #expect(table.rowGeometry.hasRowHeights)
        #expect(table.rect(ofRow: 0).height == table.rowHeight)
        #expect(table.rect(ofRow: 2).height == table.rowHeight)
        let one = try expectedHeight(table, Self.long)
        #expect(one > table.rowHeight * 2)
        #expect(table.rect(ofRow: 1).height == one)
        #expect(table.rect(ofRow: 3).height == (try expectedHeight(table, notes.texts[3])))
        #expect(table.rect(ofRow: 3).height > one)
        for row in 1..<4 { #expect(table.rect(ofRow: row).minY == table.rect(ofRow: row - 1).maxY) }
        #expect(table.layoutMetrics.contentHeight == top(table, 3) + height(table, 3))
    }

    @Test func aLineLimitCapsTheHeight() throws {
        let notes = Notes([Self.long + " " + Self.long])
        let table = makeTable(notes, note: NGTableColumn("note", title: "Note", width: 140).wrappingText(maximumNumberOfLines: 2))
        #expect(table.rect(ofRow: 0).height == table.rowHeight + NGLineHeights.height(of: table.metalStyle.textFont))
        #expect(table.rect(ofRow: 0).height == (try expectedHeight(table, notes.texts[0], maximumLines: 2)))
    }

    @Test func aNarrowerColumnMakesTallerRows() throws {
        let notes = Notes([Self.long, "Short"])
        let table = makeTable(notes)
        let before = table.rect(ofRow: 0).height
        table.setWidth(70, forColumnID: "note")
        table.layoutSubtreeIfNeeded()
        #expect(table.rect(ofRow: 0).height > before)
        #expect(table.rect(ofRow: 0).height == (try expectedHeight(table, Self.long)))
        #expect(top(table, 1) == top(table, 0) + height(table, 0))
    }

    @Test func reloadedRowsAreMeasuredAgain() throws {
        let notes = Notes(Array(repeating: "Short", count: 10))
        let table = makeTable(notes)
        #expect(table.rect(ofRow: 3).height == table.rowHeight)
        notes.texts[3] = Self.long
        table.reloadData(forRowIndexes: [3], columnIndexes: [1])
        table.layoutSubtreeIfNeeded()
        #expect(table.rect(ofRow: 3).height == (try expectedHeight(table, Self.long)))
        #expect(top(table, 4) == top(table, 3) + height(table, 3))
        // And back.
        notes.texts[3] = "Short"
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        #expect(table.rect(ofRow: 3).height == table.rowHeight)
    }

    /// Heights follow their records through a sort.
    @Test func heightsFollowTheirRecords() throws {
        let notes = Notes(["a", Self.long, "c", "d"])
        let table = makeTable(notes)
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "note", ascending: false)]
        table.layoutSubtreeIfNeeded()
        let long = try #require(table.displayRow(forSourceRow: 1))
        #expect(long != 1)
        let tall = try expectedHeight(table, Self.long)
        for row in 0..<4 { #expect(height(table, row) == (row == long ? tall : table.rowHeight)) }
    }

    /// In a large table only the rows in view are measured; the others count
    /// as `rowHeight` until they come into view.
    @Test func aLargeTableMeasuresTheRowsInView() throws {
        let notes = Notes(Array(repeating: Self.long, count: NGTableView.measuredAtOnceLimit * 2))
        let table = makeTable(notes)
        let tall = try expectedHeight(table, Self.long)
        #expect(table.rect(ofRow: 0).height == tall)
        #expect(height(table, 3_000) == table.rowHeight)
        table.scrollRowToVisible(3_000)
        table.layoutSubtreeIfNeeded()
        #expect(table.rowIndexes(in: table.visibleRect).contains(3_000))
        #expect(table.rect(ofRow: 3_000).height == tall)
    }

    /// Rows above the view measured as they come in don't move the rows in
    /// view: the scroll position takes their new height.
    @Test func scrollingUpDoesNotJump() throws {
        let notes = Notes(Array(repeating: Self.long, count: NGTableView.measuredAtOnceLimit * 2))
        let table = makeTable(notes)
        table.setContentOffset(CGPoint(x: 0, y: 50_000))
        table.layoutSubtreeIfNeeded()
        #expect(height(table, Int(table.rowGeometry.position(atY: table.contentOffset.y))) > table.rowHeight)
        // Up into rows not measured yet: the row then at the top stays where
        // their estimates put it, though the rows above it grow.
        let offset = table.contentOffset.y - 200
        let rows = table.rowGeometry
        let anchor = Int(rows.position(atY: offset))
        let screenY = rows.top(of: anchor) - offset
        #expect(height(table, anchor - 1) == table.rowHeight)
        table.setContentOffset(CGPoint(x: 0, y: offset))
        table.layoutSubtreeIfNeeded()
        #expect(height(table, anchor - 1) > table.rowHeight)
        #expect(top(table, anchor) - table.contentOffset.y == screenY)
    }

    /// Without a wrapping column every row has `rowHeight`; the delegate's
    /// heights win over measuring.
    @Test func measuringOnlyWithWrappingColumns() throws {
        let notes = Notes([Self.long])
        let table = makeTable(notes, note: NGTableColumn("note", title: "Note", width: 140))
        #expect(!table.rowGeometry.hasRowHeights)
        #expect(table.rect(ofRow: 0).height == table.rowHeight)
        table.columns = [.column(NGTableColumn("note", title: "Note", width: 140).wrappingText())]
        table.layoutSubtreeIfNeeded()
        #expect(table.rect(ofRow: 0).height == (try expectedHeight(table, Self.long)))
        final class Fixed: NGTableViewDelegate, NGTableViewRowHeights {
            func tableView(_ tableView: NGTableView, heightOfRow row: Int) -> CGFloat { 33 }
        }
        let fixed = Fixed()
        table.delegate = fixed
        table.layoutSubtreeIfNeeded()
        #expect(table.rect(ofRow: 0).height == 33)
    }
}
#endif
