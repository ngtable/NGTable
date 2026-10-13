#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// NSTableView's API for hidden rows, frames of rows and columns, moving and
/// scrolling columns, and the delegate methods that come with them.
@Suite("NSTableView compatibility")
@MainActor
struct NGCompatibilityTests {
    typealias Records = NGLiveSortingTests.Records

    @MainActor
    final class Delegate: NGTableViewDelegate {
        var typeSelectStrings: [Int: String] = [:]
        var lockedColumnIDs: Set<String> = []
        var visibilityChanges: [[String]] = []
        var moves: [(Int, Int)] = []
        var dragged: [String] = []
        func tableView(_ tableView: NGTableView, didDrag tableColumn: NGTableColumn) { dragged.append(tableColumn.id) }

        func tableView(_ tableView: NGTableView, typeSelectStringFor tableColumn: NGTableColumn?, row: Int) -> String? {
            typeSelectStrings[row]
        }
        func tableView(_ tableView: NGTableView, userCanChangeVisibilityOf column: NGTableColumn) -> Bool {
            !lockedColumnIDs.contains(column.id)
        }
        func tableView(_ tableView: NGTableView, userDidChangeVisibilityOf columns: [NGTableColumn]) {
            visibilityChanges.append(columns.map(\.id))
        }
        func tableViewColumnDidMove(_ notification: Notification) {
            let old = (notification.userInfo?["NSOldColumn"] as? NSNumber)?.intValue ?? -1
            let new = (notification.userInfo?["NSNewColumn"] as? NSNumber)?.intValue ?? -1
            moves.append((old, new))
        }
    }

    private func makeTable(_ records: Records, width: CGFloat = 600) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        table.columns = [
            .column(NGTableColumn("name", title: "Name", width: 200)),
            .column(NGTableColumn("profit", title: "Profit", width: 120, format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
            .column(NGTableColumn("status", title: "Status", width: 100)),
            .column(NGTableColumn("rank", title: "Rank", width: 80)),
        ]
        table.dataSource = records
        table.layoutSubtreeIfNeeded()
        return table
    }

    private func shown(_ table: NGTableView) -> [Int] {
        (0..<table.numberOfRows).map(table.sourceRow)
    }

    /// Hidden rows leave the display, the selection and the totals, follow
    /// their records through inserts and removes, and stay hidden by index
    /// across a reload.
    @Test func hiddenRowsFollowTheirRecords() {
        let records = Records(count: 50)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.selectRowIndexes([3, 4, 5], byExtendingSelection: false)
        table.hideRows(at: [4, 10, 60])
        #expect(table.hiddenRowIndexes == [4, 10])
        #expect(table.numberOfRows == 48)
        #expect(!shown(table).contains(4) && !shown(table).contains(10))
        #expect(table.selectedRowIndexes == [3, 5])
        let total = records.records.indices.filter { ![4, 10].contains($0) }.reduce(0) { $0 + records.records[$1].profit }
        #expect(table.summaryValue(forColumnID: "profit") == total)
        // An insert before them moves them down; removing one forgets it.
        records.records.insert(.init(id: 100, name: "New", profit: 1, status: "Active"), at: 0)
        table.insertRows(at: [0])
        #expect(table.hiddenRowIndexes == [5, 11])
        records.records.remove(at: 11)
        table.removeRows(at: [11])
        #expect(table.hiddenRowIndexes == [5])
        // A new row on the removed row's handle is shown.
        records.records.insert(.init(id: 101, name: "Newer", profit: 1, status: "Active"), at: 20)
        table.insertRows(at: [20])
        #expect(table.hiddenRowIndexes == [5])
        #expect(shown(table).contains(20))
        // A reload keeps the same indexes hidden; unhiding shows them.
        table.reloadData()
        #expect(table.hiddenRowIndexes == [5])
        table.unhideRows(at: [5])
        #expect(table.hiddenRowIndexes.isEmpty)
        #expect(table.numberOfRows == records.records.count)
        // With a filter and a sort, both apply.
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        table.rowFilter = NGRowFilter(searchText: "campaign", columnIDs: ["name"])
        let hidden = shown(table)[0]
        table.hideRows(at: [hidden])
        #expect(!shown(table).contains(hidden))
        #expect(shown(table).count == records.records.filter { $0.name.hasPrefix("Campaign") }.count - 1)
    }

    /// Row and column frames, and the rows and columns a rect covers.
    @Test func framesOfRowsAndColumns() {
        let records = Records(count: 200)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let row5 = table.rect(ofRow: 5)
        #expect(row5.height == table.rowHeight)
        #expect(row5.width == table.bounds.width)
        #expect(table.rect(ofRow: 6).minY - row5.minY == table.rowHeight)
        #expect(table.rowIndexes(in: row5.insetBy(dx: 0, dy: 1)) == [5])
        #expect(table.row(at: NSPoint(x: row5.midX, y: row5.midY)) == 5)
        #expect(table.rect(ofRow: 500) == .zero)
        // Within the visible rows, a rect covers consecutive rows.
        let span = NSRect(x: 0, y: row5.minY, width: 10, height: table.rowHeight * 3)
        #expect(table.rowIndexes(in: span) == [5, 6, 7])
        // Columns: their frames agree with the cells' and with column(at:).
        for (index, column) in table.tableColumns.enumerated() {
            let frame = table.rect(ofColumn: index)
            #expect(frame.width == CGFloat(table.width(ofColumnID: column.id) ?? 0))
            if let cell = table.frameOfCell(row: 5, columnID: column.id) {
                #expect(cell.minX == frame.minX)
            }
            if frame.midX < table.bounds.width {
                #expect(table.column(at: NSPoint(x: frame.midX, y: row5.midY)) == index)
                #expect(table.columnIndexes(in: NSRect(x: frame.midX, y: 0, width: 1, height: 1)) == [index])
            }
        }
        table.hiddenColumnIDs = ["status"]
        #expect(table.rect(ofColumn: 2) == .zero)
        // Sorted, rows are where the sort shows them.
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        let first = table.sourceRow(0)
        #expect(table.rowIndexes(in: table.rect(ofRow: first).insetBy(dx: 0, dy: 1)) == [first])
    }

    /// A scrolling column scrolls into view; moving columns posts the moves
    /// and keeps groups together.
    @Test func scrollingAndMovingColumns() {
        let records = Records(count: 20)
        let table = makeTable(records, width: 250)
        defer { withExtendedLifetime(records) {} }
        let delegate = Delegate()
        table.delegate = delegate
        table.scrollColumnToVisible(3)
        let rank = table.rect(ofColumn: 3)
        #expect(rank.minX >= 0 && rank.maxX <= table.bounds.width + 0.5)
        table.scrollColumnToVisible(0)
        #expect(table.contentOffset.x == 0)

        table.moveColumn(0, toColumn: 2)
        #expect(table.tableColumns.map(\.id) == ["profit", "status", "name", "rank"])
        #expect(delegate.moves.contains { $0 == (0, 2) })
        table.moveColumn(3, toColumn: 0)
        #expect(table.tableColumns.map(\.id) == ["rank", "profit", "status", "name"])
        // Groups stay together: a member moves within its group only.
        table.columns = [
            .column(NGTableColumn("name", title: "Name")),
            .group(NGColumnGroup("money", title: "Money", columns: [NGTableColumn("profit", title: "Profit"), NGTableColumn("rank", title: "Rank")])),
            .column(NGTableColumn("status", title: "Status")),
        ]
        table.moveColumn(1, toColumn: 2)
        #expect(table.tableColumns.map(\.id) == ["name", "rank", "profit", "status"])
        table.moveColumn(1, toColumn: 3)   // Out of its group: ignored.
        #expect(table.tableColumns.map(\.id) == ["name", "rank", "profit", "status"])
        table.moveColumn(0, toColumn: 2)   // Past the whole group.
        #expect(table.tableColumns.map(\.id) == ["rank", "profit", "name", "status"])
    }

    /// Changed values in view flash: numbers up or down with `.direction`,
    /// text with `.flash`; values reported but unchanged don't. Flashes follow
    /// their records when the sort moves them, and a reload clears them.
    @Test func changedValuesFlash() throws {
        let records = Records(count: 50)
        let table = makeTable(records)
        // In a window: out of one nothing flashes (nor in one no one sees,
        // which this one isn't to the test).
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        table.drawsWhileUnseenForTesting = true
        defer { withExtendedLifetime((records, window)) {} }
        var columns = table.tableColumns
        columns[1].changeHighlight = .direction
        columns[0].changeHighlight = .flash
        table.columns = columns.map { .column($0) }
        table.layoutSubtreeIfNeeded()
        let all = IndexSet(integersIn: 0..<table.numberOfColumns)
        let profit = table.columnOrdinal(of: "profit"), name = table.columnOrdinal(of: "name")
        func flash(row: Int, ordinal: Int) -> NGChangeFlash.Kind? {
            table.changeHighlights[NGChangeKey(handle: table.handle(ofRow: row), ordinal: ordinal)]?.kind
        }
        records.records[2].profit += 10
        records.records[3].profit -= 10
        records.records[4].name = "Renamed"
        table.reloadData(forRowIndexes: [2, 3, 4, 5], columnIndexes: all)
        #expect(flash(row: 2, ordinal: profit) == .up)
        #expect(flash(row: 3, ordinal: profit) == .down)
        #expect(flash(row: 4, ordinal: name) == .changed)
        #expect(flash(row: 4, ordinal: profit) == nil)
        #expect(flash(row: 5, ordinal: profit) == nil)   // Reported, unchanged.
        #expect(table.changeHighlights.count == 3)
        // Drawn where the cell is, also after the sort moved the row.
        let style = MetalStyle.resolved(for: table.effectiveAppearance)
        #expect(table.changeHighlightQuads(style: style).values.joined().count == 3)
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        records.records[2].profit = 10_000
        table.reloadData(forRowIndexes: [2], columnIndexes: all)
        #expect(table.displayRow(forSourceRow: 2) == 0)
        let frames = table.changeHighlightQuads(style: style).values.joined().map(\.frame)
        let cell = try #require(table.visibleCells[NGCellKey(row: 0, column: profit)])
        #expect(frames.contains(cell.cellFrame))
        // A removed row's flashes don't pass to a new row on its handle.
        records.records.remove(at: 3)
        table.removeRows(at: [3])
        records.records.insert(.init(id: 900, name: "New", profit: 1, status: "Active"), at: 3)
        table.insertRows(at: [3])
        #expect(flash(row: 3, ordinal: profit) == nil)
        table.reloadData()
        #expect(table.changeHighlights.isEmpty)
        // A window no one sees (not on screen): nothing flashes.
        table.drawsWhileUnseenForTesting = false
        records.records[2].profit += 1
        table.reloadData(forRowIndexes: [2], columnIndexes: all)
        #expect(table.changeHighlights.isEmpty)
        table.drawsWhileUnseenForTesting = true
        // Turned off with a zero duration.
        table.changeHighlightDuration = 0
        records.records[2].profit += 1
        table.reloadData(forRowIndexes: [2], columnIndexes: all)
        #expect(table.changeHighlights.isEmpty)
    }

    /// Every inserted row forgets the flashes of its handle (it may be a
    /// reused one): by key, not by going through every flash, or a feed
    /// inserting thousands of rows a second among thousands of flashes
    /// takes the main thread (60 % of it, in a test feed of that kind).
    @Test func forgettingFlashesOfAHandleIsCheap() {
        let table = makeTable(Records(count: 10))
        let flash = NGChangeFlash(start: CACurrentMediaTime(), kind: .up)
        for handle in 0..<10_000 {
            for ordinal in 0..<2 { table.changeHighlights[NGChangeKey(handle: handle, ordinal: ordinal)] = flash }
        }
        table.changeHighlightOrdinals = [0, 1]
        let start = CACurrentMediaTime()
        for handle in 10_000..<30_000 { table.forgetChangeHighlights(ofHandle: handle) }
        table.forgetChangeHighlights(ofHandle: 7)
        #expect(CACurrentMediaTime() - start < 0.5)
        #expect(table.changeHighlights.count == 19_998)
        #expect(table.changeHighlights[NGChangeKey(handle: 7, ordinal: 1)] == nil)
        #expect(table.changeHighlights[NGChangeKey(handle: 8, ordinal: 1)] != nil)
    }

    /// The animation options each look as NSTableView's: rows come and go
    /// fading (`.effectFade`), sliding in or out up, down, left or right
    /// (`.slideUp` …, fading too), or in a gap without fading
    /// (`.effectGap`); the other rows slide to their places with all of them.
    /// Hiding and unhiding rows animates too.
    @Test func animationOptionsAndHiddenRows() throws {
        let records = Records(count: 50)
        let table = makeTable(records)
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        defer { withExtendedLifetime((records, window)) {} }
        let width = table.bounds.width
        func insert(_ options: NSTableView.AnimationOptions) throws -> NGRowAnimation {
            records.records.insert(.init(id: 1000 + records.records.count, name: "New", profit: 1, status: "Active"), at: 2)
            table.insertRows(at: [2], withAnimation: options)
            return try #require(table.rowAnimation)
        }
        // Coming in: where it starts (progress 0) and how opaque.
        _ = try insert(.slideLeft)   // Moving left: from the right.
        #expect(table.rowAnimationShift(ofDisplayRow: 2, progress: 0) == CGPoint(x: width, y: 0))
        #expect(table.rowAnimationShift(ofDisplayRow: 2, progress: 1) == .zero)
        _ = try insert(.slideRight)
        #expect(table.rowAnimationShift(ofDisplayRow: 2, progress: 0) == CGPoint(x: -width, y: 0))
        _ = try insert(.slideDown)   // From above.
        #expect(table.rowAnimationShift(ofDisplayRow: 2, progress: 0) == CGPoint(x: 0, y: -table.rowHeight))
        _ = try insert(.slideUp)
        #expect(table.rowAnimationShift(ofDisplayRow: 2, progress: 0) == CGPoint(x: 0, y: table.rowHeight))
        #expect(table.rowAnimationOpacity(ofDisplayRow: 2, progress: 0) == 0)
        _ = try insert(.effectGap)
        #expect(table.rowAnimationShift(ofDisplayRow: 2, progress: 0) == .zero)
        #expect(table.rowAnimationOpacity(ofDisplayRow: 2, progress: 0) == 1)
        // The rows below slide down whatever the option.
        #expect(table.rowAnimationShift(ofDisplayRow: 3, progress: 0) == CGPoint(x: 0, y: -table.rowHeight))
        _ = try insert(.effectFade)
        #expect(table.rowAnimationShift(ofDisplayRow: 2, progress: 0) == .zero)
        #expect(table.rowAnimationOpacity(ofDisplayRow: 2, progress: 0) == 0)
        // Going out: removed rows' cells leave the same way.
        records.records.remove(at: 4)
        table.removeRows(at: [4], withAnimation: .slideRight)
        #expect(table.disappearingShift(progress: 1) == CGPoint(x: width, y: 0))
        records.records.remove(at: 4)
        table.removeRows(at: [4], withAnimation: .slideUp)
        #expect(table.disappearingShift(progress: 1) == CGPoint(x: 0, y: -table.rowHeight))
        table.finishRowAnimation()

        // Hidden rows fade out, the others slide up; shown again, they fade in.
        let rowsShown = table.numberOfRows
        table.hideRows(at: [6, 7], withAnimation: .effectFade)
        let hiding = try #require(table.rowAnimation)
        #expect(table.numberOfRows == rowsShown - 2)
        #expect(hiding.disappearing.count == 2 * table.numberOfColumns)
        #expect(hiding.offsets[6] == 2 * table.rowHeight)   // Row 8 before: two rows lower at first.
        table.unhideRows(at: [6, 7], withAnimation: .effectFade)
        let showing = try #require(table.rowAnimation)
        #expect(showing.appearing == [6, 7])
        #expect(table.numberOfRows == rowsShown)
        // Without an option: at once.
        table.finishRowAnimation()
        table.hideRows(at: [6])
        #expect(table.rowAnimation == nil && table.numberOfRows == rowsShown - 1)
    }

    /// Updates with an animation slide moved rows from where they were, fade
    /// new rows in and gone rows out; without one, rows change at once. The
    /// table's own sort animates its moves only with `animatesSortMoves`.
    @Test func rowChangesAnimate() throws {
        let records = Records(count: 50)
        let table = makeTable(records)
        // In a window: out of one rows change at once.
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        defer { withExtendedLifetime((records, window)) {} }
        let columnCount = table.numberOfColumns
        // Without an animation: at once.
        records.records.insert(.init(id: 900, name: "New", profit: 1, status: "Active"), at: 2)
        table.insertRows(at: [2])
        #expect(table.rowAnimation == nil)
        // An insert: the new row fades in, the rows after it slide down.
        records.records.insert(.init(id: 901, name: "Newer", profit: 1, status: "Active"), at: 3)
        table.insertRows(at: [3], withAnimation: .effectFade)
        let insert = try #require(table.rowAnimation)
        #expect(insert.appearing == [3])
        #expect(insert.offsets[4] == -table.rowHeight)   // Row 3 before: drawn a row higher at first.
        #expect(insert.offsets[1] == nil)
        #expect(table.rowAnimationOffset(ofDisplayRow: 4) == -table.rowHeight || table.rowAnimationProgress > 0)
        #expect(table.rowAnimationOpacity(ofDisplayRow: 3) < 1 || table.rowAnimationProgress == 1)
        // A remove: its cells fade out where they were, the rows after it slide up.
        records.records.remove(at: 5)
        table.removeRows(at: [5], withAnimation: .slideUp)
        let remove = try #require(table.rowAnimation)
        #expect(remove.disappearing.count == columnCount)
        #expect(remove.offsets[5] == table.rowHeight)
        _ = table.metalSnapshot()   // Draws mid-animation.
        table.finishRowAnimation()
        #expect(table.rowAnimation == nil)
        let recycled = remove.disappearing.allSatisfy { $0.isHidden }
        #expect(recycled)   // Back in the pool.
        // The table's sort: moves animate only when asked.
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        let all = IndexSet(integersIn: 0..<columnCount)
        let last = table.sourceRow(table.numberOfRows - 1)
        records.records[last].profit = 100_000
        table.reloadData(forRowIndexes: [last], columnIndexes: all)
        #expect(table.rowAnimation == nil)
        table.animatesSortMoves = true
        let second = table.sourceRow(1)
        records.records[second].profit = 200_000
        table.reloadData(forRowIndexes: [second], columnIndexes: all)
        let sorted = try #require(table.rowAnimation)
        #expect(sorted.offsets[0] == table.rowHeight)   // The new first row came from row 1.
        #expect(sorted.offsets[1] == -table.rowHeight)
        // A batch that moves rows without animating ends it (its rows would be wrong).
        table.animatesSortMoves = false
        records.records.insert(.init(id: 950, name: "Plain", profit: 300_000, status: "Active"), at: 0)
        table.insertRows(at: [0])
        #expect(table.rowAnimation == nil)
        // So does a filter.
        table.animatesSortMoves = true
        records.records[table.sourceRow(2)].profit = 400_000
        table.reloadData(forRowIndexes: [table.sourceRow(2)], columnIndexes: all)
        #expect(table.rowAnimation != nil)
        table.rowFilter = NGRowFilter { _ in true }
        #expect(table.rowAnimation == nil)
        // A reload ends it.
        records.records[table.sourceRow(3)].profit = 500_000
        table.reloadData(forRowIndexes: [table.sourceRow(3)], columnIndexes: all)
        table.reloadData()
        #expect(table.rowAnimation == nil)
    }

    /// Autosave keeps the user's customizations through a new definition:
    /// one without the sorted column keeps the user's order, and pins the app
    /// changes apply (only the user's own pins are saved).
    @Test func autosaveKeepsTheUsersLayoutThroughNewDefinitions() throws {
        let records = Records(count: 20)
        let name = "NGTableTests.autosave.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NGTableView Columns \(name)") }
        let definition: [NGColumnItem] = [.column(NGTableColumn("a", title: "A", width: 100)),
                                          .column(NGTableColumn("b", title: "B", width: 100)),
                                          .column(NGTableColumn("c", title: "C", width: 100))]
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = definition
        table.dataSource = records
        table.autosaveName = name
        table.moveColumn(2, toColumn: 0)   // The user's order: c, a, b.
        table.setWidth(150, forColumnID: "a")
        table.sortDescriptors = [NSSortDescriptor(key: "b", ascending: true)]
        #expect(table.tableColumns.map(\.id) == ["c", "a", "b"])
        // A new version drops b (the sorted column) and adds d (where it's defined: last).
        table.columns = [definition[0], definition[2], .column(NGTableColumn("d", title: "D", width: 100))]
        #expect(table.tableColumns.map(\.id) == ["c", "a", "d"])
        #expect(table.width(ofColumnID: "a") == 150)
        #expect(table.sortDescriptors.isEmpty)
        // The app pins a in a newer version: the save doesn't revert it.
        var pinned = table.columns
        let index = try #require(pinned.firstIndex { $0.id == "a" })
        if case .column(var column) = pinned[index] {
            column.pin = .leading
            pinned[index] = .column(column)
        }
        let other = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        other.columns = pinned
        other.dataSource = records
        other.autosaveName = name
        #expect(other.columns.first { $0.id == "a" }?.pin == .leading)
        #expect(other.columnLayoutState.pins == nil)
        withExtendedLifetime(records) {}
    }

    /// Like NSTableView's `autosaveTableColumns`, every width is saved:
    /// widths set in code, those of hidden columns, and those the table's
    /// autoresizing gives (once per turn of the run loop, not per step).
    @Test func everyWidthIsSaved() async throws {
        let records = Records(count: 20)
        let name = "NGTableTests.widths.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NGTableView Columns \(name)") }
        let definition: [NGColumnItem] = ["a", "b", "c"].map { .column(NGTableColumn($0, title: $0, width: 100)) }
        func makeSaved() -> NGTableView {
            let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            table.columns = definition
            table.dataSource = records
            table.autosaveName = name
            table.layoutSubtreeIfNeeded()
            return table
        }
        defer { withExtendedLifetime(records) {} }
        func saved() -> NGColumnLayoutState? {
            UserDefaults.standard.data(forKey: "NGTableView Columns \(name)").flatMap { try? PropertyListDecoder().decode(NGColumnLayoutState.self, from: $0) }
        }
        let table = makeSaved()
        table.setWidth(150, forColumnID: "a")
        try await eventually { saved()?.widths["a"] == 150 }
        #expect(makeSaved().width(ofColumnID: "a") == 150)
        // A hidden column keeps its width.
        table.setWidth(170, forColumnID: "b")
        table.hiddenColumnIDs = ["b"]
        try await eventually { saved()?.hiddenIDs == ["b"] && saved()?.widths["b"] == 170 }
        let reopened = makeSaved()
        #expect(reopened.hiddenColumnIDs == ["b"])
        reopened.hiddenColumnIDs = []
        #expect(reopened.width(ofColumnID: "b") == 170)
        // Autoresizing: the widths it gives.
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setFrameSize(NSSize(width: 660, height: 400))
        table.layoutSubtreeIfNeeded()
        let resized = table.width(ofColumnID: "a")
        #expect(resized != 150)
        try await eventually { saved()?.widths["a"] == resized }
        #expect(makeSaved().width(ofColumnID: "a") == resized)
    }

    /// The header menu pins a column (or its whole group) to an edge and
    /// unpins it; the pins are saved with the layout.
    @Test func userPinning() throws {
        let records = Records(count: 20)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let status = table.rect(ofColumn: 2)
        let menu = try #require(table.makeColumnVisibilityMenu(at: NSPoint(x: status.midX, y: 5)))
        let pinLeft = try #require(menu.items.first { $0.action == NSSelectorFromString("pinColumn:") })
        #expect(menu.items.filter { $0.action == NSSelectorFromString("pinColumn:") }.count == 2)   // Left, right (not "Unpin").
        NSApp.sendAction(try #require(pinLeft.action), to: pinLeft.target, from: pinLeft)
        #expect(table.columns.first { $0.id == "status" }?.pin == .leading)
        #expect(table.geometry.leading.columns.map(\.column.id) == ["status"])
        // Saved and restored.
        let state = table.columnLayoutState
        #expect(state.pins?["status"] == .leading)
        let other = makeTable(records)
        other.columnLayoutState = state
        #expect(other.columns.first { $0.id == "status" }?.pin == .leading)
        // Unpinned from its own menu.
        let pinned = table.rect(ofColumn: table.tableColumns.firstIndex { $0.id == "status" } ?? 0)
        let again = try #require(table.makeColumnVisibilityMenu(at: NSPoint(x: pinned.midX, y: 5)))
        let unpin = try #require(again.items.last { $0.action == NSSelectorFromString("pinColumn:") })
        NSApp.sendAction(try #require(unpin.action), to: unpin.target, from: unpin)
        #expect(table.columns.first { $0.id == "status" }?.pin == NGColumnPin.none)
        // Turned off: no pinning items.
        table.allowsColumnPinning = false
        let plain = table.makeColumnVisibilityMenu(at: NSPoint(x: status.midX, y: 5))
        #expect(plain?.items.contains { $0.action == NSSelectorFromString("pinColumn:") } == false)
    }

    /// A named view or a layout state set by the app brings back its pins:
    /// pins the user made since are undone, the definition's stay, and what
    /// is shown is what is saved. A state saved before user pins were kept
    /// apart (every item's pin, under "pins") keeps the user's pins.
    @Test func layoutStatesBringBackTheirPins() throws {
        let records = Records(count: 20)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let defined = Dictionary(uniqueKeysWithValues: table.columns.map { ($0.id, $0.pin) })
        func pins() -> [String: NGColumnPin] { Dictionary(uniqueKeysWithValues: table.columns.map { ($0.id, $0.pin) }) }
        table.saveView(named: "Plain")
        let plain = table.columnLayoutState
        table.setPin(.leading, forItemID: "status")
        #expect(pins()["status"] == .leading)
        #expect(table.applyView(named: "Plain"))
        #expect(pins() == defined)
        #expect(table.columnLayoutState.pins == nil)
        // A view with a pin, pins changed, the view again: shown as saved.
        table.setPin(.trailing, forItemID: "status")
        table.saveView(named: "Status right")
        table.setPin(.leading, forItemID: "status")
        #expect(table.applyView(named: "Status right"))
        #expect(pins()["status"] == .trailing)
        #expect(table.columnLayoutState.pins == ["status": .trailing])
        table.columnLayoutState = plain
        #expect(pins() == defined)
        // An old save: every item's pin, "status" moved by the user.
        struct OldState: Encodable { let order: [String]; let pins: [String: NGColumnPin] }
        var old = defined
        old["status"] = .trailing
        let data = try PropertyListEncoder().encode(OldState(order: table.columns.map(\.id), pins: old))
        table.columnLayoutState = try PropertyListDecoder().decode(NGColumnLayoutState.self, from: data)
        #expect(pins()["status"] == .trailing)
        #expect(table.columnLayoutState.pins == ["status": .trailing])
    }

    /// A named view grouped by the columns already grouped by keeps the
    /// grouping's options and collapsed groups, and doesn't report a change.
    @Test func aViewWithTheSameGroupingKeepsIt() throws {
        @MainActor final class Recorder: NGTableViewDelegate {
            var groupings = 0
            func tableView(_ tableView: NGTableView, didChangeRowGrouping grouping: NGRowGrouping?) { groupings += 1 }
        }
        let records = Records(count: 30)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.rowGrouping = NGRowGrouping(columnID: "status", showsRowCount: false)
        table.saveView(named: "By status")
        let first = try #require(table.groupTree.nodes.first?.group)
        table.collapseGroup(first, collapseChildren: false)
        let rows = table.numberOfRows
        let recorder = Recorder()
        table.delegate = recorder
        #expect(table.applyView(named: "By status"))
        #expect(table.rowGrouping?.showsRowCount == false)
        #expect(table.numberOfRows == rows)
        #expect(recorder.groupings == 0)
        // Another grouping keeps the options too.
        table.rowGrouping = NGRowGrouping(columnID: "name", showsRowCount: false)
        table.columnLayoutState = table.columnLayoutState   // (No grouping saved: kept.)
        #expect(table.applyView(named: "By status"))
        #expect(table.rowGrouping?.columnIDs == ["status"])
        #expect(table.rowGrouping?.showsRowCount == false)
        withExtendedLifetime(recorder) {}
    }

    /// Named views save the columns, sort, column filters and grouping, and
    /// bring them back; with an autosave name they outlive the table.
    @Test func namedViews() throws {
        let records = Records(count: 30)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.hiddenColumnIDs = ["rank"]
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        table.columnFilters = ["status": .values(["Active"])]
        table.rowGrouping = NGRowGrouping(columnIDs: ["status"], startsCollapsed: true)
        table.saveView(named: "Active by profit")
        // Something else entirely.
        table.hiddenColumnIDs = []
        table.sortDescriptors = []
        table.columnFilters = [:]
        table.rowGrouping = nil
        table.saveView(named: "Everything")
        #expect(table.savedViewNames == ["Active by profit", "Everything"])
        // The delegate hears of what a view changes, as when the user changes it.
        final class Told: NGTableViewDelegate {
            var events: [String] = []
            func tableView(_ tableView: NGTableView, didChangeHiddenColumns hiddenColumnIDs: Set<String>) { events.append("hidden") }
            func tableView(_ tableView: NGTableView, didChangeColumnFilters filters: [String: NGColumnFilter]) { events.append("filters") }
            func tableView(_ tableView: NGTableView, didChangeRowGrouping grouping: NGRowGrouping?) { events.append("grouping") }
        }
        let told = Told()
        table.delegate = told
        #expect(table.applyView(named: "Active by profit"))
        #expect(Set(told.events) == ["hidden", "filters", "grouping"])
        #expect(table.rowGrouping?.startsCollapsed == true)
        table.delegate = records
        #expect(table.hiddenColumnIDs == ["rank"])
        #expect(table.sortDescriptors.first?.key == "profit")
        #expect(table.columnFilters == ["status": .values(["Active"])])
        #expect(table.rowGrouping?.columnIDs == ["status"])
        #expect(table.currentViewName == "Active by profit")
        table.applyView(named: "Everything")
        #expect(table.columnFilters.isEmpty && table.rowGrouping == nil && table.hiddenColumnIDs.isEmpty)
        table.removeView(named: "Everything")
        #expect(table.savedViewNames == ["Active by profit"])
        #expect(!table.applyView(named: "Everything"))
        // Kept under the autosave name.
        let name = "NGTableTests.views.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: "NGTableView Views \(name)")
            UserDefaults.standard.removeObject(forKey: "NGTableView Columns \(name)")
        }
        table.autosaveName = name
        table.saveView(named: "Kept")
        let other = makeTable(records)
        other.autosaveName = name
        #expect(other.savedViewNames == ["Kept"])
        // The header menu offers them.
        table.allowsNamedViews = true
        let menu = try #require(table.makeColumnVisibilityMenu())
        #expect(menu.items.first?.submenu?.items.contains { $0.title == "Kept" } == true)
    }

    /// The header menu groups by a column, adds levels and ungroups; the
    /// grouping is saved with the layout.
    @Test func userGrouping() throws {
        let records = Records(count: 30)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.allowsUserGrouping = true
        func menuItems(at column: Int) throws -> [NSMenuItem] {
            let rect = table.rect(ofColumn: column)
            return try #require(table.makeColumnVisibilityMenu(at: NSPoint(x: rect.midX, y: 5))).items
        }
        func click(_ item: NSMenuItem?) throws {
            let item = try #require(item)
            NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        }
        try click(try menuItems(at: 2).first { $0.action == NSSelectorFromString("groupByColumn:") })
        #expect(table.rowGrouping?.columnIDs == ["status"])
        try click(try menuItems(at: 0).first { $0.action == NSSelectorFromString("groupByColumn:") })
        #expect(table.rowGrouping?.columnIDs == ["status", "name"])
        // Saved with the layout and restored.
        let state = table.columnLayoutState
        #expect(state.grouping == ["status", "name"])
        let other = makeTable(records)
        other.columnLayoutState = state
        #expect(other.rowGrouping?.columnIDs == ["status", "name"])
        try click(try menuItems(at: 1).first { $0.action == NSSelectorFromString("ungroupRows:") })
        #expect(table.rowGrouping == nil)
        // Off by default: no grouping in the state.
        table.allowsUserGrouping = false
        #expect(table.columnLayoutState.grouping == nil)
    }

    /// Group headers scrolled past float at the top, each level under the
    /// one above, pushed up by the next group's header; clicks find them
    /// where they're drawn.
    @Test func floatingGroupHeaders() throws {
        let records = Records(count: 300)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.rowGrouping = NGRowGrouping(columnID: "status")
        table.layoutSubtreeIfNeeded()
        let rowHeight = table.rowHeight
        #expect(table.floatingGroupHeaders().isEmpty)   // At the top: in place.
        table.setContentOffset(CGPoint(x: 0, y: rowHeight * 10.5))
        table.layoutSubtreeIfNeeded()
        let floating = table.floatingGroupHeaders()
        #expect(floating.count == 1)
        #expect(floating.first?.row == 0)
        #expect(floating.first?.y == rowHeight * 10.5)
        #expect(table.floatingGroupHeader(atCanvasY: rowHeight * 10.6) == 0)
        // The header's cells are there to draw (its row is out of view).
        #expect(table.visibleCells.keys.contains { $0.row == 0 })
        // The next group's header pushes it up.
        let next = try #require(table.groupHeaderDisplayRows.filter { $0 > 0 }.min())
        table.setContentOffset(CGPoint(x: 0, y: rowHeight * (CGFloat(next) - 0.5)))
        table.layoutSubtreeIfNeeded()
        #expect(table.floatingGroupHeaders().first?.y == rowHeight * CGFloat(next - 1))
        // Two levels: the inner header under the outer one.
        table.rowGrouping = NGRowGrouping(columnIDs: ["status", "profit"])
        table.setContentOffset(CGPoint(x: 0, y: rowHeight * 2.2))
        table.layoutSubtreeIfNeeded()
        let levels = table.floatingGroupHeaders()
        // (At this offset both levels float: the check can't pass by skipping.)
        #expect(levels.count == 2)
        if levels.count == 2 {
            #expect(levels[1].y == levels[0].y + rowHeight)
        }
        table.floatsGroupRows = false
        #expect(table.floatingGroupHeaders().isEmpty)
    }

    /// A row scrolled into view going up stops below the headers floating
    /// there, and lookups at a floating header find the header.
    @Test func rowsScrolledIntoViewStayBelowFloatingHeaders() throws {
        let records = Records(count: 300)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        for grouping in [NGRowGrouping(columnID: "status"), NGRowGrouping(columnIDs: ["status", "profit"])] {
            table.rowGrouping = grouping
            table.layoutSubtreeIfNeeded()
            let rowHeight = table.rowHeight
            for target in [40, 25, 12, 3] where !table.isGroupRow(target) {
                table.setContentOffset(CGPoint(x: 0, y: rowHeight * 60))
                table.scrollDisplayRowToVisible(target)
                table.layoutSubtreeIfNeeded()
                let cover = table.floatingGroupHeaders().filter { $0.row != target }.map { $0.y + rowHeight }.max() ?? 0
                #expect(CGFloat(target) * rowHeight >= cover - 0.5, "row \(target) under a floating header")
            }
            // Over a floating header: the header, not the row beneath.
            table.setContentOffset(CGPoint(x: 0, y: rowHeight * 10.5))
            table.layoutSubtreeIfNeeded()
            // (The innermost: an outer one may be pushed up under the column titles.)
            let header = try #require(table.floatingGroupHeaders().last)
            let y = table.convert(NSPoint(x: 0, y: header.y + rowHeight / 2), from: table.centerRegion.canvas).y
            let point = NSPoint(x: table.bounds.midX, y: y)
            #expect(table.row(at: point) == -1)
            #expect(table.group(at: point) != nil)
            // Rows in the header's rect: not the one hidden beneath it.
            let headerRect = table.convert(NSRect(x: 0, y: header.y, width: 10, height: rowHeight), from: table.centerRegion.canvas)
            let beneath = Int(header.y / rowHeight)
            let hidden = table.isGroupRow(beneath) ? -1 : table.sourceRow(beneath)
            #expect(!table.rowIndexes(in: headerRect).contains(hidden))
            #expect(table.frameOfCell(row: hidden, columnID: "name") == nil)
        }
    }

    /// The table style's fonts and colors reach the renderer; density sets
    /// row heights for the font.
    @Test func tableStyleAndDensity() {
        let records = Records(count: 20)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        #expect(table.metalStyle.textFont.pointSize == NSFont.systemFontSize)
        table.density = .regular
        #expect(table.rowHeight == 24)   // The default at the system font size.
        table.density = .compact
        let compact = table.rowHeight
        table.density = .spacious
        #expect(compact < 24 && table.rowHeight > 24)
        table.tableStyle = NGTableStyle(fontSize: 18, headerFontSize: 14, groupRowColor: .systemPink)
        #expect(table.metalStyle.textFont.pointSize == 18)
        #expect(table.metalStyle.headerFont.pointSize == 14)
        #expect(table.rowHeight > 32)   // The density follows the larger font.
        table.rowGrouping = NGRowGrouping(columnID: "status")
        #expect(table.rowColor(0) == .systemPink)
        table.tableStyle = NGTableStyle()
        #expect(table.metalStyle.textFont.pointSize == NSFont.systemFontSize)
    }

    /// Rows the data source gives a pasteboard writer for can be dragged;
    /// the drop line is drawn above the row a drop would go to.
    @Test func rowDragging() throws {
        @MainActor final class Draggable: NGTableViewDataSource {
            func numberOfRows(in tableView: NGTableView) -> Int { 10 }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text("Row \(row)") }
            func tableView(_ tableView: NGTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
                row == 3 ? nil : "Row \(row)" as NSString
            }
        }
        let records = Records(count: 10)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!table.canDragRow(displayRow: 2))   // The data source doesn't drag rows.
        let draggable = Draggable()
        table.dataSource = draggable
        defer { withExtendedLifetime(draggable) {} }
        table.notePressForRowDrag(event, displayRow: 2, wasSelected: false, isDraggable: table.canDragRow(displayRow: 2))
        #expect(table.rowDragPress.map { table.row(of: $0.ref) } == table.sourceRow(2))
        table.notePressForRowDrag(event, displayRow: 3, wasSelected: false, isDraggable: table.canDragRow(displayRow: 3))
        #expect(table.rowDragPress == nil)   // No writer for that row.
        var quads: [NGMetalQuad] = []
        table.appendDropIndicator(style: table.metalStyle, scale: 2, to: &quads)
        #expect(quads.isEmpty)
        table.dropIndicatorRow = 4
        table.appendDropIndicator(style: table.metalStyle, scale: 2, to: &quads)
        #expect(quads.count == 1)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        #expect(table.draggingSourceOperationMaskWithinApplication == .copy)
    }

    /// `didDrag` follows every drag of a column, like NSTableView's, also
    /// one that ends where it started (then no column moved).
    @Test func didDragForEveryColumnDrag() throws {
        let records = Records(count: 20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let table = makeTable(records)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        let delegate = Delegate()
        table.delegate = delegate
        defer { withExtendedLifetime((records, window, delegate)) {} }
        let header = table.headerView
        func drag(_ id: String, by offsets: [CGFloat]) throws {
            let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(id))
            let start = header.convert(NSPoint(x: table.rect(ofColumn: index).midX, y: header.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, dx: CGFloat) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + dx, y: start.y), modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: 1))
            }
            table.headerMouseDown(try event(.leftMouseDown, dx: 0), in: header)
            for dx in offsets { table.headerMouseDragged(try event(.leftMouseDragged, dx: dx)) }
            table.headerMouseUp(try event(.leftMouseUp, dx: offsets.last ?? 0))
            table.finishColumnDragLanding()
        }
        // Out a little and back: dragged, not moved.
        try drag("profit", by: [10, 20, 0])
        #expect(delegate.dragged == ["profit"] && delegate.moves.isEmpty)
        // Past the next column: moved too.
        try drag("profit", by: [60, 120, 180])
        #expect(delegate.dragged == ["profit", "profit"] && delegate.moves.count >= 1)
        #expect((table.tableColumns.map(\.id).firstIndex(of: "profit") ?? 0) > 1)
    }

    /// The type select hooks of NSTableView's delegate: the delegate may let
    /// a typed key go on (e.g. to a shortcut of the view around the table),
    /// and may find the match itself, in ranges of display indexes; a search
    /// that wraps asks for the rest from the top.
    @Test func typeSelectHooks() throws {
        @MainActor final class Hooks: NGTableViewDelegate {
            var refuses = false
            var searches: [String?] = []
            var ranges: [String] = []
            var matches: [Int] = []
            func tableView(_ tableView: NGTableView, shouldTypeSelectFor event: NSEvent, withCurrentSearch searchString: String?) -> Bool {
                searches.append(searchString)
                return !refuses
            }
            func tableView(_ tableView: NGTableView, nextTypeSelectMatchFromRow startRow: Int, toRow endRow: Int, for searchString: String) -> Int {
                ranges.append("\(startRow)..<\(endRow) \(searchString)")
                return matches.first { $0 >= startRow && $0 < endRow } ?? -1
            }
        }
        final class Container: NSView {
            var keys: [String] = []
            override func keyDown(with event: NSEvent) { keys.append(event.characters ?? "") }
        }
        let records = Records(count: 20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let container = Container(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = container
        let table = makeTable(records)
        container.addSubview(table)
        let hooks = Hooks()
        table.delegate = hooks
        window.makeFirstResponder(table)
        defer { withExtendedLifetime((records, window, hooks)) {} }
        // Sorted the other way: display indexes aren't data source rows.
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "rank", ascending: false)]
        func type(_ text: String) {
            table.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: text,
                                                 charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!)
        }

        hooks.matches = [12]
        type("q")
        #expect(hooks.searches == [nil])
        #expect(hooks.ranges == ["0..<20 q"])
        #expect(table.selectedRowIndexes == [table.sourceRow(12)])
        // Continuing the search: asked with it.
        type("r")
        #expect(hooks.searches == [nil, "q"])
        #expect(hooks.ranges.last == "12..<20 qr")
        // A new search from after the row wraps to the top.
        table.lastTypeSelectTime = 0
        hooks.matches = [3]
        type("z")
        #expect(hooks.ranges.suffix(2) == ["13..<20 z", "0..<13 z"])
        #expect(table.selectedRowIndexes == [table.sourceRow(3)])
        // Refused: the key goes on, the selection stays.
        hooks.refuses = true
        type("k")
        #expect(container.keys == ["k"])
        #expect(table.selectedRowIndexes == [table.sourceRow(3)])
    }

    /// Type select can be turned off, and matches the delegate's strings;
    /// the header menu asks which columns the user may show or hide;
    /// resizing can be turned off for the whole table.
    @Test func typeSelectVisibilityAndResizing() {
        let records = Records(count: 20)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let delegate = Delegate()
        table.delegate = delegate
        delegate.typeSelectStrings = [7: "zebra", 3: ""]
        #expect(table.typeSelectMatch(for: "zeb") == 7)
        #expect(table.typeSelectMatch(for: "campaign 3") == nil)   // An empty string leaves the row out.
        table.allowsTypeSelect = false
        table.insertText("zeb")
        #expect(table.selectedRowIndexes.isEmpty)
        table.allowsTypeSelect = true
        table.insertText("zeb")
        #expect(table.selectedRowIndexes == [7])

        delegate.lockedColumnIDs = ["name"]
        let menu = table.makeColumnVisibilityMenu()
        let nameItem = menu?.items.first { $0.representedObject as? String == "name" }
        let statusItem = menu?.items.first { $0.representedObject as? String == "status" }
        #expect(nameItem?.isEnabled == false)
        #expect(statusItem?.isEnabled == true)
        if let statusItem, let action = statusItem.action {
            NSApp.sendAction(action, to: statusItem.target, from: statusItem)
        }
        #expect(table.hiddenColumnIDs == ["status"])
        #expect(delegate.visibilityChanges == [["status"]])

        table.allowsColumnResizing = false
        #expect(table.resizeHandle(at: NSPoint(x: table.rect(ofColumn: 0).maxX, y: 5), headerHeight: table.headerRowHeight) == nil)
        table.allowsColumnResizing = true
        #expect(table.resizeHandle(at: NSPoint(x: table.rect(ofColumn: 0).maxX, y: 5), headerHeight: table.headerRowHeight) != nil)
    }
}
#endif
