#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// What the table keeps of a record for longer than a batch (an editor, a
/// swipe, a choice menu, Undo, the focused cell, a copy in the background)
/// stays on that record, or goes with it: a removed record's handle goes to
/// the next inserted one, which must never receive what was meant for the old.
@Suite("Kept records")
@MainActor
struct NGKeptRecordTests {
    @MainActor
    final class Records: NGTableViewDataSource, NGTableViewDelegate {
        var names = (0..<20).map { "Campaign \($0)" }
        var statuses = [Int](repeating: 0, count: 20)
        var groups = (0..<20).map { "G\($0 / 5)" }
        var swiped: [Int] = []
        var identifies = false
        func numberOfRows(in tableView: NGTableView) -> Int { names.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            switch column.id {
            case "name": .text(names[row])
            case "status": .number(Double(statuses[row]))
            default: .text(groups[row])
            }
        }
        func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
            switch (column.id, value) {
            case ("name", .text(let text)): names[row] = text
            case ("status", .number(let number)): statuses[row] = Int(number)
            default: break
            }
        }
        func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? {
            identifies ? AnyHashable(names[row]) : nil
        }
        func tableView(_ tableView: NGTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NGRowAction] {
            [NGRowAction(style: .destructive, title: "Delete") { _, row in self.swiped.append(row) }]
        }

        func remove(_ row: Int, from table: NGTableView) {
            names.remove(at: row)
            statuses.remove(at: row)
            groups.remove(at: row)
            table.removeRows(at: [row])
        }

        func insertFresh(at row: Int, into table: NGTableView) {
            names.insert("Fresh", at: row)
            statuses.insert(0, at: row)
            groups.insert("G0", at: row)
            table.insertRows(at: [row])
        }
    }

    private func makeTable(_ records: Records) -> (NGTableView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200, isEditable: true)),
                         .column(NGTableColumn("status", title: "Status", width: 120, isEditable: true,
                                               editChoices: [.number(0), .number(1)])),
                         .column(NGTableColumn("group", title: "Group", width: 100))]
        window.contentView = table
        table.dataSource = records
        table.delegate = records
        table.navigatesByCell = true
        table.layoutSubtreeIfNeeded()
        window.makeFirstResponder(table)
        return (table, window)
    }

    @Test func aReferenceIsGoneWhenItsHandleGoesToAnotherRecord() {
        var handles = NGRowHandles(count: 10)
        let kept = handles.ref(at: 5)
        handles.remove(at: 5)
        #expect(handles.index(of: kept) == -1)
        handles.releaseRemoved()
        let fresh = handles.insert(at: 0)
        #expect(fresh == kept.handle)   // The same handle, another record.
        #expect(handles.index(of: kept) == -1)
        #expect(handles.index(of: handles.ref(at: 0)) == 0)
        // Every reference is gone after a reset.
        let other = handles.ref(at: 3)
        handles.reset(count: 10)
        #expect(handles.index(of: other) == -1)
    }

    @Test func theEditorEndsWithItsRecord() throws {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        #expect(table.editCell(row: 5, columnID: "name"))
        let field = try #require(table.editor?.field)
        field.stringValue = "Typed"
        records.remove(5, from: table)
        // Closed without writing anything.
        #expect(!table.isEditingCell && field.window == nil)
        records.insertFresh(at: 0, into: table)
        table.endEditing(committing: true)
        #expect(!records.names.contains("Typed"))
        #expect(records.names[0] == "Fresh")
    }

    @Test func theSwipeClosesWithItsRecord() throws {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        let actions = records.tableView(table, rowActionsForRow: 5, edge: .trailing)
        table.rowSwipe = NGRowSwipe(ref: table.rowRef(ofRow: 5), edge: .trailing, actions: actions, offset: -64, isTracking: false)
        table.layoutRowActionButtons()
        let buttons = try #require(table.rowActionButtons?.subviews as? [NSButton])
        records.remove(5, from: table)
        #expect(!table.rowActionsVisible)
        records.insertFresh(at: 0, into: table)
        buttons[0].performClick(nil)
        #expect(records.swiped.isEmpty)
    }

    /// Open buttons follow their record when rows come before it, and close
    /// when a filter hides it: a click never acts on a record not shown.
    @Test func theSwipeFollowsItsRecord() throws {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        let actions = records.tableView(table, rowActionsForRow: 5, edge: .trailing)
        table.rowSwipe = NGRowSwipe(ref: table.rowRef(ofRow: 5), edge: .trailing, actions: actions, offset: -64, isTracking: false)
        table.layoutRowActionButtons()
        records.insertFresh(at: 0, into: table)
        let container = try #require(table.rowActionButtons)
        let expected = table.rect(ofRow: 6)
        #expect(abs(container.frame.minY - expected.minY) < 0.5, "buttons at \(container.frame.minY), row 6 at \(expected.minY)")
        // Hidden by a filter: closed, and its buttons do nothing.
        let buttons = try #require(container.subviews as? [NSButton])
        table.rowFilter = NGRowFilter { row in row != 6 }
        #expect(!table.rowActionsVisible)
        buttons[0].performClick(nil)
        #expect(records.swiped.isEmpty)
    }

    @Test func aChoiceForARemovedRecordGoesNowhere() throws {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        let status = try #require(table.tableColumns.first { $0.id == "status" })
        let menu = try #require(table.choiceMenu(row: 6, column: status))
        records.remove(6, from: table)
        records.insertFresh(at: 0, into: table)
        menu.performActionForItem(at: 1)
        #expect(records.statuses.allSatisfy { $0 == 0 })
    }

    /// With identities, Undo still goes to the edited record by its
    /// reference first: a duplicated identity, an edit of the identity
    /// itself, and a table given another data source since.
    @Test func undoByReferenceFirst() throws {
        func edit(_ table: NGTableView, row: Int, column: Int, to value: NGCellValue, from old: NGCellValue, _ undo: UndoManager) {
            undo.beginUndoGrouping()
            table.setValue(value, row: row, column: table.tableColumns[column], undoValue: old)
            undo.endUndoGrouping()
        }
        // Rows 3 and 7 share an identity.
        do {
            let records = Records()
            records.identifies = true
            records.names[7] = records.names[3]
            records.statuses[7] = 1
            let (table, window) = makeTable(records)
            defer { withExtendedLifetime((window, records)) {} }
            let undo = UndoManager()
            undo.groupsByEvent = false
            let undoTable = NGUndoTable(table: table, undoManager: undo)
            edit(table, row: 3, column: 1, to: .number(1), from: .number(0), undo)
            undo.undo()
            #expect(records.statuses[3] == 0 && records.statuses[7] == 1)
            withExtendedLifetime(undoTable) {}
        }
        // The identity itself edited: undone and redone.
        do {
            let records = Records()
            records.identifies = true
            let (table, window) = makeTable(records)
            defer { withExtendedLifetime((window, records)) {} }
            let undo = UndoManager()
            undo.groupsByEvent = false
            let undoTable = NGUndoTable(table: table, undoManager: undo)
            _ = table.row(forIdentifier: "Campaign 2")   // The index is built before the edit.
            edit(table, row: 2, column: 0, to: .text("Renamed"), from: .text("Campaign 2"), undo)
            undo.undo()
            #expect(records.names[2] == "Campaign 2")
            undo.redo()
            #expect(records.names[2] == "Renamed")
            withExtendedLifetime(undoTable) {}
        }
        // Another data source since: its records aren't touched.
        do {
            let records = Records(), other = Records()
            records.identifies = true
            other.identifies = true
            let (table, window) = makeTable(records)
            defer { withExtendedLifetime((window, records, other)) {} }
            let undo = UndoManager()
            undo.groupsByEvent = false
            let undoTable = NGUndoTable(table: table, undoManager: undo)
            edit(table, row: 4, column: 1, to: .number(1), from: .number(0), undo)
            other.statuses[4] = 1
            table.dataSource = other
            undo.undo()
            #expect(other.statuses[4] == 1)
            withExtendedLifetime(undoTable) {}
        }
    }

    /// With identities, the focused cell follows its record across a
    /// reload, like the selection.
    @Test func theFocusedCellFollowsItsRecordAcrossAReload() {
        let records = Records()
        records.identifies = true
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        table.selectRowIndexes([3], byExtendingSelection: false)
        table.focusedCell = NGCellPosition(row: 3, columnID: "status")
        records.names.reverse()
        records.statuses.reverse()
        records.groups.reverse()
        table.reloadData()
        #expect(table.selectedRowIndexes == [16])
        #expect(table.focusedCell == NGCellPosition(row: 16, columnID: "status"))
    }

    @Test func undoGoesToTheEditedRecordOrNowhere() throws {
        for identifies in [false, true] {
            let records = Records()
            records.identifies = identifies
            let (table, window) = makeTable(records)
            defer { withExtendedLifetime((window, records)) {} }
            let undo = UndoManager()
            undo.groupsByEvent = false
            let undoTable = NGUndoTable(table: table, undoManager: undo)
            // Edited, then the app reverses its data and reloads.
            undo.beginUndoGrouping()
            table.setValue(.text("Edited"), row: 0, column: table.tableColumns[0], undoValue: .text("Campaign 0"))
            records.names[0] = "Edited"
            undo.endUndoGrouping()
            records.names.reverse()
            table.reloadData()
            undo.undo()
            if identifies {
                // Found by its identity ("Edited") at its new row.
                #expect(records.names[19] == "Campaign 0" && records.names[0] == "Campaign 19")
            } else {
                // Without identities the record can't be found: nothing changes.
                #expect(records.names[19] == "Edited" && records.names[0] == "Campaign 19")
            }
            withExtendedLifetime(undoTable) {}
        }
        // A removed record, its handle reused: Undo doesn't touch the newcomer.
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        let undo = UndoManager()
        undo.groupsByEvent = false
        let undoTable = NGUndoTable(table: table, undoManager: undo)
        undo.beginUndoGrouping()
        table.setValue(.text("Edited"), row: 5, column: table.tableColumns[0], undoValue: .text("Campaign 5"))
        undo.endUndoGrouping()
        records.remove(5, from: table)
        records.insertFresh(at: 0, into: table)
        undo.undo()
        #expect(records.names[0] == "Fresh")
        withExtendedLifetime(undoTable) {}
    }

    @Test func theFocusedCellAndRangeDontComeBackOnANewcomer() {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        table.focusedCell = NGCellPosition(row: 5, columnID: "status")
        table.selectedCellRange = NGCellRange(anchor: NGCellPosition(row: 5, columnID: "name"),
                                              end: NGCellPosition(row: 5, columnID: "status"))
        records.remove(5, from: table)
        records.insertFresh(at: 0, into: table)
        #expect(table.focusedCell == nil)
        #expect(table.selectedCellRange == nil)
    }

    @Test func aBackgroundCopyKeepsItsRecordsAndTheOrderShown() async throws {
        let records = Records()
        records.names = (0..<3_000).map { "Campaign \($0)" }
        records.statuses = (0..<3_000).map { ($0 * 7) % 3_000 }
        records.groups = [String](repeating: "G", count: 3_000)
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NGTableTests.kept.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        table.copyPasteboard = pasteboard
        table.synchronousCopyLimit = 100
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "status", ascending: true)]
        table.selectRowIndexes(IndexSet(integersIn: 0..<2_000), byExtendingSelection: false)
        // Small: the order shown.
        #expect(table.copyText(forRows: [1, 0]).hasPrefix("Campaign 0"))
        let expected = table.copyText(forRows: table.selectedRowIndexes)
        #expect(expected.hasPrefix("Campaign 0\t0\tG\nCampaign 1286\t2\t"))
        table.copy(nil)
        #expect(table.isCopying)
        // A selected record removed meanwhile, and its handle given to a newcomer.
        records.remove(0, from: table)
        records.insertFresh(at: 0, into: table)
        let start = ContinuousClock.now
        while table.isCopying, ContinuousClock.now - start < .seconds(60) {
            try await Task.sleep(for: .milliseconds(2))
        }
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(!copied.contains("Fresh"))
        #expect(copied.hasPrefix("Campaign 1286\t2\t"))
    }

    /// A large range of cells is copied in the background, the same text as
    /// at once.
    @Test func aLargeRangeOfCellsCopiesInTheBackground() async throws {
        let records = Records()
        records.names = (0..<3_000).map { "Campaign \($0)\t\"tab\"" }
        records.statuses = (0..<3_000).map { $0 % 2 }
        records.groups = [String](repeating: "G", count: 3_000)
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NGTableTests.kept.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        table.copyPasteboard = pasteboard
        table.selectedCellRange = NGCellRange(anchor: NGCellPosition(row: 10, columnID: "name"),
                                              end: NGCellPosition(row: 2_500, columnID: "status"))
        let expected = try #require(table.copyTextOfCellRange())
        table.synchronousCopyLimit = 100
        table.copy(nil)
        #expect(table.isCopying)
        let start = ContinuousClock.now
        while table.isCopying, ContinuousClock.now - start < .seconds(60) {
            try await _Concurrency.Task.sleep(for: .milliseconds(2))
        }
        #expect(pasteboard.string(forType: .string) == expected)
    }

    /// Reloads during a background copy, more than it starts over for: every
    /// selected row is still copied. A copy cancelled by a newer one doesn't
    /// end the newer one's `isCopying`.
    @Test func aCopyOutlastsManyReloads() async throws {
        let records = Records()
        let count = 30_000
        records.names = (0..<count).map { "Campaign \($0)" }
        records.statuses = (0..<count).map { $0 % 5 }
        records.groups = [String](repeating: "G", count: count)
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NGTableTests.kept.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        table.copyPasteboard = pasteboard
        table.synchronousCopyLimit = 100
        table.selectAll(nil)
        table.copy(nil)
        table.copy(nil)   // The first is cancelled by the second.
        await _Concurrency.Task.yield()
        #expect(table.isCopying)
        var reloads = 0
        while table.isCopying, reloads < 1_000 {
            table.reloadData()
            reloads += 1
            await _Concurrency.Task.yield()
        }
        #expect(reloads >= 4)
        let start = ContinuousClock.now
        while table.isCopying, ContinuousClock.now - start < .seconds(60) {
            try await _Concurrency.Task.sleep(for: .milliseconds(2))
        }
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.split(separator: "\n").count == count)
    }

    /// The display order API: indexes shown, rows at them, and the selection as shown.
    @Test func displayOrderOfRows() {
        let records = Records()
        records.statuses = (0..<20).map { (20 - $0) % 7 }
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "status", ascending: true)]
        for display in 0..<table.numberOfRows {
            guard let row = table.row(atDisplayIndex: display) else { Issue.record("no row at \(display)"); continue }
            #expect(table.displayIndex(ofRow: row) == display)
        }
        table.selectRowIndexes([0, 6], byExtendingSelection: false)   // Statuses 6 and 0.
        #expect(table.selectedRowIndexesInDisplayOrder == [6, 0])
        table.rowGrouping = NGRowGrouping(columnID: "group")
        #expect(table.row(atDisplayIndex: 0) == nil)   // A group header.
        #expect(table.row(atDisplayIndex: table.numberOfRows) == nil)
    }

    @Test func selectAllInAGroupedTableThenUpdates() {
        let records = Records()
        let (table, window) = makeTable(records)
        defer { withExtendedLifetime((window, records)) {} }
        table.rowGrouping = NGRowGrouping(columnID: "group")
        table.selectAll(nil)
        #expect(table.isGroupRow(0))
        records.remove(5, from: table)
        records.insertFresh(at: 0, into: table)
        table.beginUpdates()
        table.moveRow(at: 0, to: 3)
        records.names.insert(records.names.remove(at: 0), at: 3)
        records.statuses.insert(records.statuses.remove(at: 0), at: 3)
        records.groups.insert(records.groups.remove(at: 0), at: 3)
        table.endUpdates()
        let old = Array(0..<records.names.count)
        records.names.reverse()
        records.statuses.reverse()
        records.groups.reverse()
        table.reorderRows(fromOldIndexes: old.reversed())
        table.selectAll(nil)
        #expect(table.selectedRowIndexes.count == records.names.count)
    }
}

/// A view whose undo manager is a given one (`NSResponder.undoManager` comes
/// from the window).
@MainActor
final class NGUndoTable {
    let window: NSWindow
    private let delegate: Delegate

    final class Delegate: NSObject, NSWindowDelegate {
        let undo: UndoManager
        init(undo: UndoManager) { self.undo = undo }
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }
    }

    init(table: NGTableView, undoManager: UndoManager) {
        window = table.window!
        delegate = Delegate(undo: undoManager)
        window.delegate = delegate
    }
}
#endif

#if os(macOS)
/// Tables fed while out of a window are freed: their display links don't
/// start (they wouldn't run, and they keep the table).
@Suite("Table lifetime")
@MainActor
struct NGTableLifetimeTests {
    @Test(arguments: ["removed", "never shown"])
    func aTableFedOutOfAWindowIsFreed(_ how: String) async throws {
        let records = NGLiveSortingTests.Records(count: 50)
        weak var released: NGTableView?
        do {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                             .column(NGTableColumn("profit", title: "Profit", width: 100, changeHighlight: .direction))]
            table.dataSource = records
            table.sortsRows = true
            table.animatesSortMoves = true
            table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: true)]
            if how == "removed" {
                window.contentView?.addSubview(table)
                table.layoutSubtreeIfNeeded()
                table.removeFromSuperview()
            } else {
                table.layoutSubtreeIfNeeded()
            }
            // A flash and a sort move.
            records.records[3].profit = 1_000
            table.reloadData(forRowIndexes: [3], columnIndexes: [1])
            released = table
            withExtendedLifetime(window) {}
        }
        try await eventually { released == nil }
        #expect(released == nil)
        withExtendedLifetime(records) {}
    }

    /// A table dropped while it sorts and summarizes in the background, with
    /// a batch the app never ended: its tasks let it go and stop.
    @Test func aTableDroppedDuringBackgroundWorkIsFreed() async throws {
        NGTableView.reportsBatchesAcrossRunLoopTurns = false
        let records = NGLiveSortingTests.Records(count: 3_000)
        weak var released: NGTableView?
        do {
            let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                             .column(NGTableColumn("profit", title: "Profit", width: 100, summary: .aggregate(.sum)))]
            table.dataSource = records
            (table.synchronousSortLimit, table.synchronousSummaryLimit) = (100, 100)
            table.sortsRows = true
            table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            table.reloadData()
            // Every value read; the rest is off the main actor.
            var turns = 0
            while table.summaryBuild?.columns.isEmpty != true || table.backgroundSort?.isSnapshotTaken != true, turns < 100_000 {
                await _Concurrency.Task.yield()
                turns += 1
            }
            table.beginUpdates()
            records.records.swapAt(0, 1)
            table.moveRow(at: 0, to: 1)
            released = table
        }
        try await _Concurrency.Task.sleep(for: .milliseconds(200))
        #expect(released == nil)
        withExtendedLifetime(records) {}
    }
}
#endif
