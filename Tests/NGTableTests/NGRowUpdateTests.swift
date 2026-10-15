#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Records with an id, a name and an amount, changed in place like an app's model.
@MainActor
private final class RecordsDataSource: NGTableViewDataSource {
    struct Record { var id: Int; var name: String; var amount: Double }
    var records: [Record]
    var valueReads = 0

    init(count: Int) {
        records = (0..<count).map { Record(id: $0, name: "Item \($0)", amount: Double($0)) }
    }

    func numberOfRows(in tableView: NGTableView) -> Int { records.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        valueReads += 1
        return switch column.id {
        case "name": .text(records[row].name)
        case "amount", "max": .number(records[row].amount)
        default: .empty
        }
    }

    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { records[row].id }
}

@MainActor
private final class SelectionCounter: NGTableViewDelegate {
    var changes = 0
    func tableViewSelectionDidChange(_ notification: Notification) { changes += 1 }
}

@Suite("Row updates")
@MainActor
struct NGRowUpdateTests {
    private func makeTable(count: Int = 10) -> (NGTableView, RecordsDataSource) {
        let dataSource = RecordsDataSource(count: count)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("name", title: "Name", width: 200)),
            .column(NGTableColumn("amount", title: "Amount", width: 120, format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
        ]
        table.dataSource = dataSource
        table.layoutSubtreeIfNeeded()
        return (table, dataSource)
    }

    private func shownText(_ table: NGTableView, row: Int, column: String = "name") -> String? {
        guard let layer = table.visibleCell(row: row, columnID: column) else { return nil }
        if case .text(let text, _, _) = layer.content { return text }
        if case .number(let number, _) = layer.content { return number.format.string(for: number.value) }
        return nil
    }

    /// A steady feed of updates while summaries are computed in the background
    /// doesn't restart the computation: it finishes, with the changed values.
    @Test func updatesDuringABackgroundComputationLetItFinish() async throws {
        let (table, dataSource) = makeTable(count: 2_000)
        table.synchronousSummaryLimit = 0
        table.reloadData()
        #expect(table.isComputingSummary)
        var ticks = 0
        while table.isComputingSummary, ticks < 2_000 {
            let row = ticks % 2_000
            dataSource.records[row].amount += 1
            table.reloadData(forRowIndexes: [row], columnIndexes: [1])
            ticks += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!table.isComputingSummary)
        let expected = dataSource.records.reduce(0) { $0 + $1.amount }
        #expect(table.summaryValue(forColumnID: "amount") == expected)
        withExtendedLifetime(dataSource) {}
    }

    /// Values changed while a background computation ran, in columns it had
    /// already read, are read again when a synchronous computation (here
    /// after a search) replaces it.
    @Test func aSynchronousRebuildReadsRowsChangedDuringABackgroundOne() {
        let (table, dataSource) = makeTable(count: 100)
        table.synchronousSummaryLimit = 0
        table.reloadData()
        #expect(table.isComputingSummary)
        // The background computation has read the column (as it stood before the change)…
        let readBefore = dataSource.records.map(\.amount)
        dataSource.records[3].amount += 1_000
        table.reloadData(forRowIndexes: [3], columnIndexes: [1])
        table.summarySourceValues["amount"] = readBefore
        // …and a search makes the rest quick enough to compute right away.
        table.synchronousSummaryLimit = 1_000_000
        table.rowFilter = NGRowFilter(searchText: "Item")
        #expect(!table.isComputingSummary)
        let expected = dataSource.records.reduce(0) { $0 + $1.amount }
        #expect(table.summaryValue(forColumnID: "amount") == expected)
    }

    /// A batch that spans an `await` while a background computation finishes:
    /// rows it moved meanwhile don't leave the summaries on the old order.
    @Test func aComputationFinishingDuringABatchOfMovesIsntUsed() {
        let (table, dataSource) = makeTable(count: 10)
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.summaryScope = .selectedRows
        table.synchronousSummaryLimit = 0
        table.reloadData()
        #expect(table.isComputingSummary)
        let readBefore = dataSource.records.map(\.amount)
        table.beginUpdates()
        dataSource.records.insert(dataSource.records.remove(at: 0), at: 9)
        table.moveRow(at: 0, to: 9)
        // Meanwhile (the app awaits) the computation finishes, with the values
        // it read before the move.
        table.cancelSummaryComputation()
        table.summarySourceValues["amount"] = readBefore
        table.synchronousSummaryLimit = 1_000_000
        table.rebuildSummaryCalculators(reusingSourceValues: true)
        table.endUpdates()
        // The selected record (amount 0) is now row 9.
        #expect(table.selectedRowIndexes == [9])
        #expect(table.summaryValue(forColumnID: "amount") == 0)
        withExtendedLifetime(dataSource) {}
    }

    /// Without a data source, rows a batch removed still free their handles.
    @Test func removedRowsFreeTheirHandlesWithoutADataSource() {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200))]
        do {
            let dataSource = RecordsDataSource(count: 10)
            table.dataSource = dataSource
            table.layoutSubtreeIfNeeded()
        }
        // The data source went (the table holds it weakly), without a reload.
        #expect(table.dataSource == nil)
        #expect(table.numberOfSourceRows == 10)
        table.removeRows(at: [2, 3])
        #expect(table.rowHandles.removedHandles.isEmpty)
    }

    /// A reload in the middle of a batch that inserted rows: the cells show
    /// the rows as they are at the end, not those they showed before.
    @Test func aReloadInsideABatchShowsTheRowsAtItsEnd() {
        let (table, dataSource) = makeTable(count: 10)
        defer { withExtendedLifetime(dataSource) {} }
        table.beginUpdates()
        dataSource.records.insert(.init(id: 100, name: "Fresh", amount: 1), at: 0)
        table.insertRows(at: [0])
        table.reloadData()
        table.endUpdates()
        let shown = (0..<4).map { shownText(table, row: $0) }
        #expect(shown == ["Fresh", "Item 0", "Item 1", "Item 2"])
    }

    @Test func oldIndexesOfTwoOrders() {
        // Rows of the app's data 10, 11, 12 shown as 12, 10, 11, then sorted to 11, 12, 10.
        #expect(NGSorting.oldIndexes(from: [2, 0, 1], to: [1, 2, 0]) == [2, 0, 1])
        #expect(NGSorting.oldIndexes(from: [0, 1, 2], to: [0, 1, 2]) == [0, 1, 2])
        #expect(NGSorting.oldIndexes(from: [], to: []) == [])
    }

    /// Sorting reorders the rows without reading anything again.
    @Test func reorderingRowsReadsNothing() {
        let (table, dataSource) = makeTable()
        table.selectRowIndexes([2, 7], byExtendingSelection: false)
        let old = dataSource.records
        // Descending by amount: row i now holds the record that was at 9 - i.
        let oldIndexes = Array((0..<10).reversed())
        dataSource.records = oldIndexes.map { old[$0] }
        dataSource.valueReads = 0
        table.reorderRows(fromOldIndexes: oldIndexes)
        #expect(dataSource.valueReads == 0)
        #expect(table.selectedRowIndexes == [2, 7])   // Records 7 and 2.
        #expect(shownText(table, row: 0) == "Item 9")
        #expect(table.summaryValue(forColumnID: "amount") == 45)
        table.summaryScope = .selectedRows
        #expect(table.summaryValue(forColumnID: "amount") == 9)
        // A search keeps finding the same records.
        table.rowFilter = NGRowFilter(searchText: "Item 3")
        #expect(table.numberOfRows == 1)
        #expect(table.sourceRow(0) == 6)
        withExtendedLifetime(dataSource) {}
    }

    @Test func reloadingRowsReadsOnlyThem() {
        let (table, dataSource) = makeTable()
        #expect(table.summaryValue(forColumnID: "amount") == 45)
        dataSource.records[3].name = "Changed"
        dataSource.records[3].amount = 103
        dataSource.valueReads = 0
        table.reloadData(forRowIndexes: [3], columnIndexes: [0, 1])
        #expect(shownText(table, row: 3) == "Changed")
        #expect(shownText(table, row: 3, column: "amount") == "103")
        // The summary follows without reading every row again.
        #expect(table.summaryValue(forColumnID: "amount") == 145)
        #expect(dataSource.valueReads < 10)
        withExtendedLifetime(dataSource) {}
    }

    @Test func insertedRowsMoveTheSelectionAndSummaries() {
        let (table, dataSource) = makeTable()
        let counter = SelectionCounter()
        table.delegate = counter
        table.selectRowIndexes([2, 5], byExtendingSelection: false)
        counter.changes = 0

        dataSource.records.insert(.init(id: 100, name: "New A", amount: 1000), at: 0)
        dataSource.records.insert(.init(id: 101, name: "New B", amount: 2000), at: 4)
        table.insertRows(at: [0, 4])
        #expect(table.numberOfRows == 12)
        // The same records stay selected, at their new rows.
        #expect(table.selectedRowIndexes == [3, 7])
        #expect(counter.changes == 1)
        #expect(table.summaryValue(forColumnID: "amount") == 3045)
        #expect(shownText(table, row: 0) == "New A")
        #expect(shownText(table, row: 4) == "New B")
        #expect(shownText(table, row: 5) == "Item 3")
        withExtendedLifetime((dataSource, counter)) {}
    }

    @Test func removedRowsLeaveTheSelection() {
        let (table, dataSource) = makeTable()
        table.selectRowIndexes([1, 4, 8], byExtendingSelection: false)
        dataSource.records.remove(at: 4)
        dataSource.records.remove(at: 0)
        table.removeRows(at: [0, 4])
        #expect(table.numberOfRows == 8)
        #expect(table.selectedRowIndexes == [0, 6])
        #expect(table.summaryValue(forColumnID: "amount") == 41)  // Without 0 and 4.
        #expect(shownText(table, row: 0) == "Item 1")
        withExtendedLifetime(dataSource) {}
    }

    /// After rows move, the totals don't copy every row's handle (each batch
    /// of a feed did, O(rows)): only a query that reads rows makes their
    /// order, once, and gets the values of the rows as they are.
    @Test func totalsAfterMovesDontCopyEveryRow() {
        let (table, dataSource) = makeTable(count: 1_000)
        #expect(table.summaryValue(forColumnID: "amount") == Double(499_500))
        let builds = table.allRowHandlesBuilds
        for _ in 0..<5 {
            // The last row takes the first one's place, like a feed's delete.
            let last = dataSource.records.count - 1
            dataSource.records[0] = dataSource.records[last]
            dataSource.records.removeLast()
            table.beginUpdates()
            table.removeRows(at: [0])
            table.moveRow(at: last - 1, to: 0)
            table.endUpdates()
        }
        // 999, 998… took the place of 0, 999…: the five largest left with 0.
        let removed: Double = 0 + 999 + 998 + 997 + 996
        #expect(table.summaryValue(forColumnID: "amount") == 499_500 - removed)
        #expect(table.allRowHandlesBuilds == builds)
        // The selection's sums read rows: in step, once.
        table.summaryScope = .selectedRows
        table.selectRowIndexes([0, 1], byExtendingSelection: false)
        #expect(table.summaryValue(forColumnID: "amount") == Double(995 + 1))
        #expect(table.allRowHandlesBuilds == builds + 1)
        // Min and max of the rows as they are (the removed max is gone).
        table.summaryScope = .allRows
        var columns = table.tableColumns
        columns.append(NGTableColumn("max", title: "Max", width: 80, summary: .aggregate(.max)))
        table.columns = columns.map { .column($0) }
        #expect(table.summaryValue(forColumnID: "max") == Double(995))
        withExtendedLifetime(dataSource) {}
    }

    /// Min and max after rows moved and an extreme left: walked again over
    /// the rows as they are, not the order before the moves.
    @Test func minAndMaxAfterMovesWalkTheRowsAsTheyAre() {
        let (table, dataSource) = makeTable(count: 100)
        var columns = table.tableColumns
        columns.append(NGTableColumn("max", title: "Max", width: 80, summary: .aggregate(.max)))
        table.columns = columns.map { .column($0) }
        #expect(table.summaryValue(forColumnID: "max") == Double(99))
        for _ in 0..<3 {
            let last = dataSource.records.count - 1
            // The largest goes, the row before it takes its place.
            dataSource.records.remove(at: last)
            table.beginUpdates()
            table.removeRows(at: [last])
            table.moveRow(at: 0, to: last - 1)
            dataSource.records.insert(dataSource.records.remove(at: 0), at: last - 1)
            table.endUpdates()
        }
        #expect(table.summaryValue(forColumnID: "max") == dataSource.records.map(\.amount).max())
        #expect(table.summaryValue(forColumnID: "max")! < 99)
        withExtendedLifetime(dataSource) {}
    }

    /// Inserts and removes out of view (a feed's, mostly) leave the rows in
    /// view as they are, instead of placing every one again; a change in
    /// view places them, and they show the records where they are now.
    @Test func structuralChangesOutOfViewDontPlaceTheRowsInView() {
        let (table, dataSource) = makeTable(count: 1_000)
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((dataSource, window)) {} }
        let placements = table.rowPlacements
        for row in [900, 500, 700] {
            // The last row takes the removed one's place; a new row at the end.
            let last = dataSource.records.count - 1
            dataSource.records[row] = dataSource.records[last]
            dataSource.records.removeLast()
            dataSource.records.append(.init(id: 5_000 + row, name: "New \(row)", amount: 1))
            table.beginUpdates()
            table.removeRows(at: [row])
            table.moveRow(at: last - 1, to: row)
            table.insertRows(at: [last])
            table.endUpdates()
        }
        #expect(table.rowPlacements == placements)
        #expect(table.numberOfRows == 1_000)
        #expect(shownText(table, row: 0) == "Item 0")
        #expect(shownText(table, row: 3) == "Item 3")
        // In view: placed again, the rows below move up.
        dataSource.records.remove(at: 1)
        table.removeRows(at: [1])
        #expect(table.rowPlacements > placements)
        #expect(shownText(table, row: 1) == "Item 2")
        #expect(shownText(table, row: 3) == "Item 4")
        // The selection changes the rows' look: placed again too.
        let afterRemove = table.rowPlacements
        table.beginUpdates()
        table.selectRowIndexes([2], byExtendingSelection: false)
        dataSource.records.removeLast()
        table.removeRows(at: [dataSource.records.count])
        table.endUpdates()
        #expect(table.rowPlacements > afterRemove)
    }

    /// Every row selected in a sorted table: in data source rows it is every
    /// row, found without mapping each display row through the order (a
    /// feed's batch asked for it twice, a million rows each time).
    @Test func everyRowSelectedInASortedTableIsEveryRow() {
        let (table, dataSource) = makeTable(count: 200_000)
        defer { withExtendedLifetime(dataSource) {} }
        table.sortsRows = true
        table.synchronousSortLimit = .max
        table.sortDescriptors = [NSSortDescriptor(key: "amount", ascending: false)]
        table.selectAll(nil)
        let all = IndexSet(integersIn: 0..<200_000)
        #expect(table.selectedRowIndexes == all)
        #expect(table.displayRows(forSourceRows: all) == all)
        // Not every row: mapped.
        #expect(table.sourceRows(forDisplayRows: [0]) == [199_999])
        #expect(table.displayRows(forSourceRows: [199_999]) == [0])
        let start = CACurrentMediaTime()
        for _ in 0..<200 { _ = table.selectedRowIndexes }
        #expect(CACurrentMediaTime() - start < 0.05)
    }

    /// With rows selected, removing selected records out of view changes
    /// the selection, but not the look of the rows in view: they stay as
    /// they are, still highlighted.
    @Test func removingSelectedRowsOutOfViewDoesntPlaceTheRowsInView() {
        let (table, dataSource) = makeTable(count: 1_000)
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        let counter = SelectionCounter()
        table.delegate = counter
        defer { withExtendedLifetime((dataSource, window, counter)) {} }
        table.selectAll(nil)
        table.layoutSubtreeIfNeeded()
        let placements = table.rowPlacements, changes = counter.changes
        for row in [900, 500, 700] {
            dataSource.records.swapAt(row, dataSource.records.count - 1)
            dataSource.records.removeLast()
            table.removeRowReplacingWithLast(at: row)
        }
        #expect(counter.changes == changes + 3)
        #expect(table.rowPlacements == placements)
        #expect(table.numberOfSelectedRows == 997)
        #expect(table.isDisplayRowSelected(2))
        #expect(table.visibleCell(row: 2, columnID: "name")?.isHighlighted == table.isHighlighted(row: 2))
    }

    /// A selection of many ranges (every other row) through batches of
    /// random inserts, removes and moves: kept by record handle within a
    /// batch, it is the same records as a plain model's, read in the middle
    /// of a batch too, and changed there.
    @Test(arguments: 0..<4)
    func aFragmentedSelectionFollowsItsRecords(_ seed: Int) {
        let (table, dataSource) = makeTable(count: 300)
        defer { withExtendedLifetime(dataSource) {} }
        var random = SplitMix(seed: UInt64(40 + seed))
        table.selectRowIndexes(IndexSet(stride(from: 0, to: 300, by: 2)), byExtendingSelection: false)
        var selected = Set(stride(from: 0, to: 300, by: 2))   // Record ids.
        var nextID = 1_000
        func expected() -> IndexSet { IndexSet(dataSource.records.indices.filter { selected.contains(dataSource.records[$0].id) }) }
        for round in 0..<40 {
            table.beginUpdates()
            for step in 0..<12 {
                let count = dataSource.records.count
                switch Int.random(in: 0..<3, using: &random) {
                case 0 where count > 10:
                    let row = Int.random(in: 0..<count, using: &random)
                    selected.remove(dataSource.records[row].id)
                    if step % 2 == 0 {
                        dataSource.records.remove(at: row)
                        table.removeRows(at: [row])
                    } else {
                        // The last record put in its place.
                        dataSource.records.swapAt(row, count - 1)
                        dataSource.records.removeLast()
                        table.removeRowReplacingWithLast(at: row)
                    }
                case 1:
                    let row = Int.random(in: 0...count, using: &random)
                    dataSource.records.insert(.init(id: nextID, name: "New \(nextID)", amount: 1), at: row)
                    nextID += 1
                    table.insertRows(at: [row])
                default:
                    let from = Int.random(in: 0..<count, using: &random), to = Int.random(in: 0..<count, using: &random)
                    dataSource.records.insert(dataSource.records.remove(at: from), at: to)
                    table.moveRow(at: from, to: to)
                }
                if step == 6 {
                    // Read and changed in the middle of the batch.
                    #expect(table.selectedRowIndexes == expected(), "round \(round)")
                    let probe = Int.random(in: 0..<dataSource.records.count, using: &random)
                    #expect(table.isRowSelected(probe) == selected.contains(dataSource.records[probe].id))
                    if round % 5 == 0 {
                        table.deselectRow(probe)
                        selected.remove(dataSource.records[probe].id)
                    }
                }
            }
            table.endUpdates()
            #expect(table.selectedRowIndexes == expected(), "round \(round)")
            #expect(table.numberOfSelectedRows == selected.count)
        }
    }

    /// A large selection fragmented by a feed's batches stays by handle
    /// between them (its rows aren't built for every batch): what reads it,
    /// in a batch or after, and what draws it, sees the selected records;
    /// it changes (and is told) only when selected records go; selecting
    /// rows again ends it.
    @Test(arguments: [(false, false), (true, false), (false, true)])
    func aLargeSelectionStaysByHandleBetweenBatches(_ sorted: Bool, _ small: Bool) {
        let (table, dataSource) = makeTable(count: 30_000)
        let counter = SelectionCounter()
        table.delegate = counter
        defer { withExtendedLifetime((dataSource, counter)) {} }
        if sorted {
            table.sortsRows = true
            table.synchronousSortLimit = .max
            table.sortDescriptors = [NSSortDescriptor(key: "amount", ascending: false)]
        }
        // All rows, or fewer than the table keeps identities for, apart.
        let picked = small ? IndexSet(stride(from: 0, to: 30_000, by: 4)) : IndexSet(integersIn: 0..<30_000)
        table.selectRowIndexes(picked, byExtendingSelection: false)
        var selected = Set(picked.map { dataSource.records[$0].id })
        var nextID = 100_000
        var random = SplitMix(seed: 77)
        func expected() -> IndexSet { IndexSet(dataSource.records.indices.filter { selected.contains(dataSource.records[$0].id) }) }
        func runRounds(_ rounds: Range<Int>) {
        for round in rounds {
            let changes = counter.changes
            var removedSelected = false
            table.beginUpdates()
            for step in 0..<60 {
                let count = dataSource.records.count
                switch Int.random(in: 0..<4, using: &random) {
                case 0:
                    // Removed, the last one put in its place.
                    let row = Int.random(in: 0..<count, using: &random)
                    if selected.remove(dataSource.records[row].id) != nil { removedSelected = true }
                    dataSource.records.swapAt(row, count - 1)
                    dataSource.records.removeLast()
                    table.removeRowReplacingWithLast(at: row)
                case 1:
                    dataSource.records.append(.init(id: nextID, name: "New \(nextID)", amount: Double(nextID % 997)))
                    nextID += 1
                    table.insertRows(at: [count])
                case 2:
                    let row = Int.random(in: 0..<count, using: &random)
                    dataSource.records[row].amount = Double(Int.random(in: 0..<2_000, using: &random))
                    table.reloadData(forRowIndexes: [row], columnIndexes: [1])
                default:
                    let from = Int.random(in: 0..<count, using: &random), to = Int.random(in: 0..<count, using: &random)
                    dataSource.records.insert(dataSource.records.remove(at: from), at: to)
                    table.moveRow(at: from, to: to)
                }
                if round % 7 == 3, step == 30 {
                    // Read in the middle of a batch.
                    #expect(table.selectedRowIndexes == expected(), "round \(round), in the batch")
                    let probe = Int.random(in: 0..<dataSource.records.count, using: &random)
                    #expect(table.isRowSelected(probe) == selected.contains(dataSource.records[probe].id))
                }
            }
            table.endUpdates()
            if round > 2 { #expect(table.keptSelection != nil, "round \(round): kept by handle") }
            #expect(counter.changes == changes + (removedSelected ? 1 : 0), "round \(round): told when selected records went")
            // Drawn: the rows in view by their records.
            for row in 0..<20 {
                let source = table.sourceRow(row)
                #expect(table.isDisplayRowSelected(row) == selected.contains(dataSource.records[source].id), "round \(round), row \(row)")
            }
            #expect(table.numberOfSelectedRows == selected.count, "round \(round)")
            if round % 5 == 4 {
                // Read after the batch: built, then kept again by the next one.
                #expect(table.selectedRowIndexes == expected(), "round \(round)")
            }
        }
        }
        runRounds(0..<30)
        if small {
            // The records come back selected after a reload: their identities followed.
            dataSource.records.shuffle(using: &random)
            table.reloadData()
            #expect(table.selectedRowIndexes == expected())
            runRounds(30..<40)
        }
        // Selecting rows ends it; a reload then keeps those alone.
        table.selectRowIndexes([3, 4], byExtendingSelection: false)
        #expect(table.keptSelection == nil)
        #expect(table.selectedRowIndexes == [3, 4])
        let ids = Set([3, 4].map { dataSource.records[$0].id })
        dataSource.records.shuffle(using: &random)
        table.reloadData()
        #expect(Set(table.selectedRowIndexes.map { dataSource.records[$0].id }) == ids)
    }

    /// A changed record in view places its row again, alone: the other rows
    /// in view stay as they are (placing them all was most of a feed's
    /// layout), with or without rows moving out of view in the same batch.
    @Test func aChangedRowInViewIsPlacedAlone() {
        let (table, dataSource) = makeTable(count: 1_000)
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((dataSource, window)) {} }
        var placements = table.rowPlacements
        dataSource.records[3].name = "Changed"
        table.reloadData(forRowIndexes: [3], columnIndexes: [0])
        #expect(table.rowPlacements == placements + 1)
        #expect(shownText(table, row: 3) == "Changed")
        #expect(shownText(table, row: 4) == "Item 4")
        placements = table.rowPlacements
        // With a row going far below in the same batch.
        table.beginUpdates()
        dataSource.records[5].name = "Also changed"
        table.reloadData(forRowIndexes: [5], columnIndexes: [0])
        dataSource.records.remove(at: 900)
        table.removeRows(at: [900])
        table.endUpdates()
        #expect(table.rowPlacements == placements + 1)
        #expect(shownText(table, row: 5) == "Also changed")
        #expect(shownText(table, row: 3) == "Changed")
    }

    /// A frame and a layout ask AppKit for the layout direction once, not
    /// for every cell (it walks up the view tree); right to left still draws
    /// mirrored.
    @Test func aFrameReadsTheLayoutDirectionOnce() throws {
        let (table, dataSource) = makeTable(count: 1_000)
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((dataSource, window)) {} }
        let renderer = try #require(table.metalRenderer)
        let leftToRight = table.buildMetalQuads(renderer: renderer, scale: 2)
        var reads = table.layoutDirectionReads
        _ = table.buildMetalQuads(renderer: renderer, scale: 2)
        #expect(table.layoutDirectionReads == reads + 1)
        reads = table.layoutDirectionReads
        table.needsLayout = true
        table.layoutSubtreeIfNeeded()
        #expect(table.layoutDirectionReads == reads + 1)
        table.userInterfaceLayoutDirection = .rightToLeft
        let rightToLeft = table.buildMetalQuads(renderer: renderer, scale: 2)
        #expect(leftToRight.map(\.rect) != rightToLeft.map(\.rect))
    }

    /// A frame draws the text of unchanged cells by copying the quads they
    /// drew last (laying out their glyphs again was most of a feed's
    /// frame); a changed cell draws its text again; the quads are those of
    /// a fresh table showing the same.
    @Test func unchangedCellsReuseTheirTextQuads() throws {
        func quads(_ table: NGTableView, _ renderer: NGMetalRenderer) -> [String] {
            table.buildMetalQuads(renderer: renderer, scale: 2).map { "\($0.rect) \($0.source) \($0.color) \($0.clip) \($0.kind)" }.sorted()
        }
        let (table, dataSource) = makeTable(count: 1_000)
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((dataSource, window)) {} }
        let renderer = try #require(table.metalRenderer)
        _ = quads(table, renderer)
        let drawn = renderer.textAppends
        let again = quads(table, renderer)
        #expect(renderer.textAppends == drawn)
        dataSource.records[2].name = "Changed"
        table.reloadData(forRowIndexes: [2], columnIndexes: [0])
        let changed = quads(table, renderer)
        #expect(renderer.textAppends == drawn + 1)
        #expect(changed != again)
        // The same as a table drawing everything for the first time.
        let (fresh, freshSource) = makeTable(count: 1_000)
        freshSource.records = dataSource.records
        let freshWindow = NSWindow(contentRect: fresh.frame, styleMask: [.titled], backing: .buffered, defer: false)
        freshWindow.contentView = fresh
        fresh.reloadData()
        fresh.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((freshSource, freshWindow)) {} }
        #expect(quads(fresh, renderer) == changed)
    }

    /// Rows reloaded one by one, in any order and repeated, read their values
    /// again like an index set of them does.
    @Test func reloadingRowsGivenOneByOne() {
        let (table, dataSource) = makeTable(count: 100)
        defer { withExtendedLifetime(dataSource) {} }
        for row in [40, 3, 77, 3] { dataSource.records[row].amount += 1000 }
        table.reloadData(forRows: [40, 3, 77, 3, -1, 500], columnIndexes: [1])
        #expect(table.summaryValue(forColumnID: "amount") == Double(4950 + 4000))
        #expect(shownText(table, row: 3) == "Item 3")
    }

    /// Many rows given one by one, in a table whose rows moved (handles
    /// aren't rows), some removed in the same batch, with duplicates: their
    /// handles found in one walk; totals and the sorted order as a fresh
    /// table's.
    @Test(arguments: [false, true])
    func manyRowsGivenOneByOneAfterRowsMoved(_ sorted: Bool) {
        let (table, dataSource) = makeTable(count: 5_000)
        defer { withExtendedLifetime(dataSource) {} }
        if sorted {
            table.sortsRows = true
            table.sortDescriptors = [NSSortDescriptor(key: "amount", ascending: false)]
        }
        var random = SplitMix(seed: 31)
        for round in 0..<8 {
            table.beginUpdates()
            for _ in 0..<40 {
                let from = Int.random(in: 0..<dataSource.records.count, using: &random), to = Int.random(in: 0..<dataSource.records.count, using: &random)
                dataSource.records.insert(dataSource.records.remove(at: from), at: to)
                table.moveRow(at: from, to: to)
            }
            var rows: [Int] = []
            for _ in 0..<1_500 {
                let row = Int.random(in: 0..<dataSource.records.count, using: &random)
                dataSource.records[row].amount = Double(Int.random(in: -1_000...1_000, using: &random))
                rows.append(row)
            }
            table.reloadData(forRows: rows + [rows[0], -1, 99_999], columnIndexes: [1])
            // Some of the changed ones go.
            for _ in 0..<30 {
                let row = rows[Int.random(in: 0..<rows.count, using: &random)]
                guard row < dataSource.records.count else { continue }
                dataSource.records.remove(at: row)
                table.removeRows(at: [row])
            }
            table.endUpdates()
            #expect(table.summaryValue(forColumnID: "amount") == dataSource.records.reduce(0) { $0 + $1.amount }, "round \(round)")
            if sorted {
                let shown = (0..<table.numberOfRows).map { dataSource.records[table.sourceRow($0)].amount }
                #expect(shown == shown.sorted(by: >), "round \(round)")
            }
        }
    }

    /// Handles and handles left out as one set: the same as their union
    /// without them, for lists with duplicates, runs and -1.
    @Test func handleSetMatchesUnionAndSubtracting() {
        var random = SplitMix(seed: 17)
        for count in [17, 600, 5_000] {
            var handles = (0..<count).map { _ in Int32(Int.random(in: 0..<20_000, using: &random)) }
            handles += [-1, 7, 7, 8, 9, 10, 0]
            for excluded in [[], [7, 9, -1], (0..<count).map { _ in Int32(Int.random(in: 0..<20_000, using: &random)) } + [7]] as [[Int32]] {
                let expected = NGTableView.subtracting(excluded, from: NGTableView.union([], handles, capacity: 20_000))
                #expect(NGTableView.handleSet(handles, excluding: excluded) == expected, "\(count), \(excluded.count) excluded")
            }
        }
    }

    /// The summaries read a batch's changed rows' numbers at once from a data
    /// source that gives them (`numbersFor:atRows:`), not cell by cell.
    @Test func changedRowsNumbersReadAtOnce() {
        final class Bulk: NGTableViewDataSource {
            var amounts = (0..<100).map(Double.init)
            var cellReads = 0, bulkReads = 0
            func numberOfRows(in tableView: NGTableView) -> Int { amounts.count }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
                cellReads += 1
                return column.id == "amount" ? .number(amounts[row]) : .text("Row \(row)")
            }
            func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, atRows rows: UnsafeBufferPointer<Int>,
                           into values: UnsafeMutableBufferPointer<Double>) -> Bool {
                guard column.id == "amount" else { return false }
                bulkReads += 1
                for (index, row) in rows.enumerated() { values[index] = amounts[row] }
                return true
            }
        }
        let source = Bulk()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name")),
                         .column(NGTableColumn("amount", title: "Amount", summary: .aggregate(.sum)))]
        table.dataSource = source
        #expect(table.summaryValue(forColumnID: "amount") == Double(4950))
        source.cellReads = 0
        // (Out of view: a row in view reads its cells again to show them.)
        for row in [50, 70, 95] { source.amounts[row] += 100 }
        table.reloadData(forRows: [50, 70, 95], columnIndexes: [1])
        #expect(source.bulkReads == 1)
        #expect(source.cellReads == 0)
        #expect(table.summaryValue(forColumnID: "amount") == Double(5250))
        withExtendedLifetime(source) {}
    }

    @Test func movedRowsKeepTheirSelection() {
        let (table, dataSource) = makeTable()
        table.selectRowIndexes([2], byExtendingSelection: false)
        dataSource.records.insert(dataSource.records.remove(at: 2), at: 7)
        table.moveRow(at: 2, to: 7)
        #expect(table.selectedRowIndexes == [7])
        #expect(shownText(table, row: 7) == "Item 2")
        #expect(shownText(table, row: 2) == "Item 3")
        #expect(table.summaryValue(forColumnID: "amount") == 45)
        withExtendedLifetime(dataSource) {}
    }

    /// Each update of a batch refers to the rows after the ones before; values
    /// are read once at the end, by the final rows.
    @Test func batchesFinishOnce() {
        let (table, dataSource) = makeTable()
        let counter = SelectionCounter()
        table.delegate = counter
        table.selectRowIndexes([5], byExtendingSelection: false)
        counter.changes = 0

        table.beginUpdates()
        dataSource.records.insert(.init(id: 100, name: "First", amount: 100), at: 0)
        table.insertRows(at: [0])
        dataSource.records.remove(at: 3)
        table.removeRows(at: [3])
        dataSource.records[9].amount = 900
        table.reloadData(forRowIndexes: [9], columnIndexes: [1])
        #expect(counter.changes == 0)
        table.endUpdates()

        #expect(counter.changes == 0)  // Item 5 is still selected, still at row 5.
        #expect(table.selectedRowIndexes == [5])
        #expect(shownText(table, row: 0) == "First")
        // 45 + 100 (new) - 2 (removed) - 9 + 900 (changed).
        #expect(table.summaryValue(forColumnID: "amount") == 1034)
        withExtendedLifetime((dataSource, counter)) {}
    }

    @Test func filteredRowsFollowTheirValues() {
        let (table, dataSource) = makeTable()
        table.rowFilter = NGRowFilter(searchText: "Item")
        #expect(table.numberOfRows == 10)
        table.selectRowIndexes([3], byExtendingSelection: false)
        // A changed name the search no longer finds hides the row and drops it
        // from the selection.
        dataSource.records[3].name = "Other"
        table.reloadData(forRowIndexes: [3], columnIndexes: [0])
        #expect(table.numberOfRows == 9)
        #expect(table.selectedRowIndexes.isEmpty)
        // An inserted row the search finds shows.
        dataSource.records.append(.init(id: 50, name: "Item new", amount: 0))
        table.noteNumberOfRowsChanged()
        #expect(table.numberOfSourceRows == 11)
        #expect(table.numberOfRows == 10)
        withExtendedLifetime(dataSource) {}
    }

    @Test func noteNumberOfRowsChangedAddsAndDropsTheEnd() {
        let (table, dataSource) = makeTable(count: 3)
        dataSource.records.append(contentsOf: [.init(id: 3, name: "Item 3", amount: 3), .init(id: 4, name: "Item 4", amount: 4)])
        table.noteNumberOfRowsChanged()
        #expect(table.numberOfRows == 5)
        #expect(table.summaryValue(forColumnID: "amount") == 10)
        dataSource.records.removeLast(4)
        table.noteNumberOfRowsChanged()
        #expect(table.numberOfRows == 1)
        #expect(table.summaryValue(forColumnID: "amount") == 0)
        withExtendedLifetime(dataSource) {}
    }

    /// From no data to some: the grid comes back without a full reload.
    @Test func insertingIntoAnEmptyTableShowsTheGrid() {
        let (table, dataSource) = makeTable(count: 0)
        #expect(table.headerView.isHidden)
        dataSource.records = [.init(id: 1, name: "Only", amount: 7)]
        table.insertRows(at: [0])
        #expect(!table.headerView.isHidden)
        #expect(shownText(table, row: 0) == "Only")
        #expect(table.summaryValue(forColumnID: "amount") == 7)
        withExtendedLifetime(dataSource) {}
    }

    /// Totals change by the changed values; min and max, which can't be
    /// taken away, are computed again.
    @Test func minAndMaxStayExactAfterUpdates() {
        let dataSource = RecordsDataSource(count: 10)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("amount", title: "Max", summary: .aggregate(.max))),
            .column(NGTableColumn("name", title: "N")),
        ]
        table.dataSource = dataSource
        #expect(table.summaryValue(forColumnID: "amount") == 9)
        dataSource.records.remove(at: 9)
        table.removeRows(at: [9])
        #expect(table.summaryValue(forColumnID: "amount") == 8)
        dataSource.records[2].amount = 50
        table.reloadData(forRowIndexes: [2], columnIndexes: [0])
        #expect(table.summaryValue(forColumnID: "amount") == 50)
        dataSource.records[2].amount = 1
        table.reloadData(forRowIndexes: [2], columnIndexes: [0])
        #expect(table.summaryValue(forColumnID: "amount") == 8)
        withExtendedLifetime(dataSource) {}
    }

    /// Random updates leave the summaries, the selection and the shown rows
    /// as a full reload of the same data would.
    @Test func randomUpdatesMatchAFullReload() {
        let (table, dataSource) = makeTable(count: 200)
        table.selectRowIndexes([3, 50, 120], byExtendingSelection: false)
        let selectedIDs = Set([3, 50, 120])
        var nextID = 1000
        var generator = SplitMix(seed: 7)
        for _ in 0..<60 {
            table.beginUpdates()
            for _ in 0..<5 {
                switch generator.next() % 4 {
                case 0 where !dataSource.records.isEmpty:
                    let row = Int(generator.next() % UInt64(dataSource.records.count))
                    dataSource.records[row].amount += Double(generator.next() % 100) - 50
                    table.reloadData(forRowIndexes: [row], columnIndexes: [1])
                case 1:
                    let row = Int(generator.next() % UInt64(dataSource.records.count + 1))
                    dataSource.records.insert(.init(id: nextID, name: "Item \(nextID)", amount: Double(generator.next() % 1000)), at: row)
                    nextID += 1
                    table.insertRows(at: [row])
                case 2 where dataSource.records.count > 1:
                    let row = Int(generator.next() % UInt64(dataSource.records.count))
                    guard !selectedIDs.contains(dataSource.records[row].id) else { continue }
                    dataSource.records.remove(at: row)
                    table.removeRows(at: [row])
                case 3 where dataSource.records.count > 1:
                    let from = Int(generator.next() % UInt64(dataSource.records.count))
                    let to = Int(generator.next() % UInt64(dataSource.records.count))
                    dataSource.records.insert(dataSource.records.remove(at: from), at: to)
                    table.moveRow(at: from, to: to)
                default:
                    break
                }
            }
            table.endUpdates()
            let sum = dataSource.records.reduce(0) { $0 + $1.amount }
            #expect(table.summaryValue(forColumnID: "amount") == sum)
            #expect(Set(table.selectedRowIndexes.map { dataSource.records[$0].id }) == selectedIDs)
        }
        #expect(table.numberOfRows == dataSource.records.count)
        let first = dataSource.records.first?.name
        #expect(shownText(table, row: 0) == first)
        withExtendedLifetime(dataSource) {}
    }

    /// Inserting and removing many rows at once (runs and scattered rows)
    /// keeps the summaries, the selection and the search index on their records.
    @Test func manyRowsInsertedAndRemovedAtOnce() {
        let (table, dataSource) = makeTable(count: 300)
        let selectedIDs: Set<Int> = [1, 77, 150, 299]
        table.selectRowIndexes(IndexSet(selectedIDs), byExtendingSelection: false)
        // A search index exists before the updates (it moves with the rows).
        table.rowFilter = NGRowFilter(searchText: "Item")
        var nextID = 1000
        var generator = SplitMix(seed: 11)
        for round in 0..<20 {
            if round % 2 == 0 {
                // Final indexes: a run at a random place plus scattered rows.
                var indexes = IndexSet()
                let start = Int(generator.next() % UInt64(dataSource.records.count))
                indexes.insert(integersIn: start..<(start + 5))
                for _ in 0..<10 { indexes.insert(Int(generator.next() % UInt64(dataSource.records.count + 15))) }
                indexes = indexes.filteredIndexSet { $0 < dataSource.records.count + indexes.count }
                for index in indexes {
                    dataSource.records.insert(.init(id: nextID, name: "Item \(nextID)", amount: Double(generator.next() % 1000)), at: index)
                    nextID += 1
                }
                table.insertRows(at: indexes)
            } else {
                var indexes = IndexSet()
                let start = Int(generator.next() % UInt64(dataSource.records.count - 5))
                indexes.insert(integersIn: start..<(start + 4))
                for _ in 0..<10 { indexes.insert(Int(generator.next() % UInt64(dataSource.records.count))) }
                indexes = indexes.filteredIndexSet { !selectedIDs.contains(dataSource.records[$0].id) }
                for index in indexes.reversed() { dataSource.records.remove(at: index) }
                table.removeRows(at: indexes)
            }
            let sum = dataSource.records.reduce(0) { $0 + $1.amount }
            #expect(table.summaryValue(forColumnID: "amount") == sum, "round \(round)")
            #expect(Set(table.selectedRowIndexes.map { dataSource.records[$0].id }) == selectedIDs, "round \(round)")
        }
        // The search finds each record at its new row.
        let probe = dataSource.records.indices.filter { $0 % 37 == 0 }
        for row in probe {
            table.rowFilter = NGRowFilter(searchText: dataSource.records[row].name)
            #expect((0..<table.numberOfRows).map(table.sourceRow).contains(row), "\(dataSource.records[row].name)")
        }
        withExtendedLifetime(dataSource) {}
    }

    /// Hundreds of single-row inserts, removes and moves in one batch (a feed
    /// message) keep summaries, selection and search on their records, like a
    /// reload; a filter set in the middle of the batch sees the rows so far.
    @Test func manySingleRowChangesInOneBatch() {
        let (table, dataSource) = makeTable(count: 500)
        let selectedIDs: Set<Int> = [3, 250, 499]
        table.selectRowIndexes(IndexSet(selectedIDs), byExtendingSelection: false)
        table.rowFilter = NGRowFilter(searchText: "Item")
        var generator = SplitMix(seed: 23)
        var nextID = 10_000
        table.beginUpdates()
        for step in 0..<600 {
            switch generator.next() % 3 {
            case 0:
                let index = Int(generator.next() % UInt64(dataSource.records.count + 1))
                dataSource.records.insert(.init(id: nextID, name: "Item \(nextID)", amount: Double(generator.next() % 1000)), at: index)
                nextID += 1
                table.insertRows(at: [index])
            case 1:
                let index = Int(generator.next() % UInt64(dataSource.records.count))
                guard !selectedIDs.contains(dataSource.records[index].id) else { continue }
                dataSource.records.remove(at: index)
                table.removeRows(at: [index])
            default:
                let from = Int(generator.next() % UInt64(dataSource.records.count))
                let to = Int(generator.next() % UInt64(dataSource.records.count))
                dataSource.records.insert(dataSource.records.remove(at: from), at: to)
                table.moveRow(at: from, to: to)
            }
            if step == 300 {
                // A filter in the middle of the batch reads the search words of
                // the rows so far (another column set: the index is read again;
                // every row matches, so the selection stays).
                table.rowFilter = NGRowFilter(searchText: "Item", columnIDs: ["name"])
            }
        }
        table.endUpdates()
        table.rowFilter = nil
        let sum = dataSource.records.reduce(0) { $0 + $1.amount }
        #expect(table.summaryValue(forColumnID: "amount") == sum)
        #expect(Set(table.selectedRowIndexes.map { dataSource.records[$0].id }) == selectedIDs)
        for row in dataSource.records.indices where row % 41 == 0 {
            table.rowFilter = NGRowFilter(searchText: dataSource.records[row].name)
            #expect((0..<table.numberOfRows).map(table.sourceRow).contains(row), "\(dataSource.records[row].name)")
        }
        withExtendedLifetime(dataSource) {}
    }

    /// Summaries computed again in the middle of a batch (the same filter set
    /// again, a reload, `reloadSummary()`) already leave out the rows removed
    /// so far: the end of the batch doesn't take them away a second time.
    @Test(arguments: ["filter", "reload", "summary", "filtered"])
    func summariesRebuiltInTheMiddleOfABatch(_ rebuild: String) {
        let (table, dataSource) = makeTable(count: 10)
        if rebuild == "filtered" { table.rowFilter = NGRowFilter(searchText: "item") }
        table.beginUpdates()
        dataSource.records.remove(at: 9)
        table.removeRows(at: [9])
        switch rebuild {
        case "filter": table.rowFilter = nil
        case "reload": table.reloadData()
        case "summary": table.reloadSummary()
        default: table.rowFilter = NGRowFilter(searchText: "ite")
        }
        dataSource.records[0].amount = 100
        table.reloadData(forRowIndexes: [0], columnIndexes: [1])
        dataSource.records.remove(at: 1)
        table.removeRows(at: [1])
        table.endUpdates()
        #expect(table.summaryValue(forColumnID: "amount") == dataSource.records.reduce(0) { $0 + $1.amount })
        withExtendedLifetime(dataSource) {}
    }

    /// Rows inserted where removed rows' handles are reused (see
    /// `NGRowHandles`) start without values: removing one again in the batch,
    /// or summarizing again in the middle of it, doesn't count the values the
    /// removed rows left behind.
    @Test(arguments: [false, true])
    func reusedRowHandlesStartEmpty(rebuildingInTheBatch: Bool) {
        let (table, dataSource) = makeTable(count: 10)
        // Rows 0...4 go: their handles are reused from the next batch on.
        dataSource.records.removeSubrange(0..<5)
        table.removeRows(at: IndexSet(integersIn: 0..<5))
        table.beginUpdates()
        for index in 0..<3 {
            dataSource.records.insert(.init(id: 100 + index, name: "New \(index)", amount: 1_000), at: 0)
            table.insertRows(at: [0])
        }
        if rebuildingInTheBatch { table.reloadSummary() }
        dataSource.records.remove(at: 1)
        table.removeRows(at: [1])
        table.endUpdates()
        #expect(table.summaryValue(forColumnID: "amount") == dataSource.records.reduce(0) { $0 + $1.amount })
        withExtendedLifetime(dataSource) {}
    }

    /// The selection in the middle of a batch is in the rows as they are
    /// now, like an `NSTableView`'s, and what is selected then stays
    /// selected at the end of the batch.
    @Test func selectingInTheMiddleOfABatch() {
        let (table, dataSource) = makeTable(count: 10)
        defer { withExtendedLifetime(dataSource) {} }
        table.selectRowIndexes([5], byExtendingSelection: false)
        table.beginUpdates()
        dataSource.records.insert(.init(id: 100, name: "New", amount: 0), at: 0)
        table.insertRows(at: [0])
        #expect(table.selectedRowIndexes == [6])
        table.selectRowIndexes([3], byExtendingSelection: false)
        #expect(table.selectedRowIndexes == [3])
        #expect(table.isRowSelected(3))
        table.selectRowIndexes([8], byExtendingSelection: true)
        dataSource.records.remove(at: 1)
        table.removeRows(at: [1])
        table.endUpdates()
        #expect(table.selectedRowIndexes == [2, 7])
        #expect(table.displaySelection == [2, 7])
    }

    /// A reload in the middle of a batch selects the records selected
    /// before, wherever they are now; the batch doesn't put the selection
    /// back on the rows it had counted.
    @Test func reloadingInTheMiddleOfABatchFollowsTheRecords() {
        let (table, dataSource) = makeTable(count: 10)
        defer { withExtendedLifetime(dataSource) {} }
        table.selectRowIndexes([5], byExtendingSelection: false)
        table.beginUpdates()
        dataSource.records.insert(.init(id: 100, name: "New", amount: 0), at: 0)
        table.insertRows(at: [0])
        dataSource.records.reverse()
        table.reloadData()
        dataSource.records[0].amount = 50
        table.reloadData(forRowIndexes: [0], columnIndexes: [1])
        table.endUpdates()
        #expect(table.selectedRowIndexes.map { dataSource.records[$0].id } == [5])
        #expect(table.summaryValue(forColumnID: "amount") == dataSource.records.reduce(0) { $0 + $1.amount })
    }
}

/// Records that note reads of rows they don't have instead of trapping.
@MainActor
private final class CheckedRecords: NGTableViewDataSource {
    struct Record { var name: String; var amount: Double; var status: String }
    var records: [Record]
    var readsOutOfRange = 0
    init(count: Int) {
        records = (0..<count).map { Record(name: "Item \($0)", amount: Double($0), status: ["A", "B"][$0 % 2]) }
    }
    func numberOfRows(in tableView: NGTableView) -> Int { records.count }
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        guard row >= 0, row < records.count else {
            readsOutOfRange += 1
            return .empty
        }
        return switch column.id {
        case "name": .text(records[row].name)
        case "amount", "copy": .number(records[row].amount)
        case "status": .text(records[row].status)
        default: .empty
        }
    }
}

@Suite("Columns in the middle of a batch")
@MainActor
struct NGColumnsDuringBatchTests {
    private func makeTable(_ records: CheckedRecords) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("name", title: "Name", width: 150)),
            .column(NGTableColumn("status", title: "Status", width: 80)),
            .column(NGTableColumn("amount", title: "Amount", width: 100, format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
            .column(NGTableColumn("copy", title: "Copy", width: 100, format: .number(fractionDigits: 0), summary: .aggregate(.max))),
        ]
        table.hiddenColumnIDs = ["copy"]
        table.dataSource = records
        table.layoutSubtreeIfNeeded()
        return table
    }

    /// Showing a column lays the table out: the rows a batch removed so far
    /// aren't read (display rows still mean the rows before its moves).
    @Test func showingAColumnDoesntReadRemovedRows() {
        let records = CheckedRecords(count: 30)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.beginUpdates()
        records.records.removeLast(10)
        table.removeRows(at: IndexSet(integersIn: 20..<30))
        table.hiddenColumnIDs = []
        table.sizeColumnToFit("name")
        table.endUpdates()
        #expect(records.readsOutOfRange == 0)
        #expect(table.numberOfRows == 20)
    }

    /// A summarized column shown during a filtered batch totals the rows the
    /// filter shows as they are after the batch's moves.
    @Test func showingASummarizedColumnDuringAFilteredBatch() {
        let records = CheckedRecords(count: 30)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.rowFilter = NGRowFilter(searchText: "item", columnIDs: ["name"]) { [weak records] row in records?.records[row].status == "A" }
        table.beginUpdates()
        records.records.removeFirst(5)
        table.removeRows(at: IndexSet(integersIn: 0..<5))
        table.hiddenColumnIDs = []
        records.records[1].amount = 1_000
        table.reloadData(forRowIndexes: [1], columnIndexes: [2, 3])
        table.endUpdates()
        let shown = records.records.filter { $0.status == "A" }
        #expect(table.summaryValue(forColumnID: "amount") == shown.reduce(0) { $0 + $1.amount })
        #expect(table.summaryValue(forColumnID: "copy") == 1_000)
    }

    /// The table's sort with a filter, a column shown during a batch that
    /// removed rows the filter hides: the order follows the removed rows.
    @Test func sortedAndFilteredWhileAColumnIsShown() {
        let records = CheckedRecords(count: 30)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "amount", ascending: false)]
        table.rowFilter = NGRowFilter(searchText: "item", columnIDs: ["name"]) { [weak records] row in records?.records[row].status == "A" }
        table.beginUpdates()
        // Hidden rows (status B) before the shown ones, and the last one.
        records.records.remove(at: 29)
        table.removeRows(at: [29])
        records.records.remove(at: 1)
        table.removeRows(at: [1])
        table.hiddenColumnIDs = []
        table.endUpdates()
        let expected = records.records.indices.filter { records.records[$0].status == "A" }
            .sorted { records.records[$0].amount > records.records[$1].amount }
        #expect((0..<table.numberOfRows).map(table.sourceRow) == expected)
        #expect(table.sortedOrder?.count == records.records.count)
        #expect(table.filteredSortedOrder?.count == expected.count)
    }

    /// While a batch that moved rows is open across a turn of the run loop,
    /// clicks, Select All and Copy are ignored (display rows still mean the
    /// rows before the batch), and the batch is reported once in debug builds.
    @Test func userInputWaitsForABatchThatMovedRows() throws {
        NGTableView.reportsBatchesAcrossRunLoopTurns = false
        let records = CheckedRecords(count: 30)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        func click(_ row: Int) throws {
            let y = table.bounds.height - (table.layoutMetrics.headerHeight + CGFloat(row) * table.rowHeight + table.rowHeight / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: y), modifierFlags: [], timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: 1, pressure: 1))
                if type == .leftMouseDown { table.rowsMouseDown(event, in: table.centerRegion) } else { table.rowsMouseUp(event) }
            }
        }
        table.beginUpdates()
        records.records.removeFirst(5)
        table.removeRows(at: IndexSet(integersIn: 0..<5))
        try click(2)
        table.selectAll(nil)
        #expect(table.selectedRowIndexes.isEmpty)
        #expect(!table.validateMenuItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")))
        #expect(!table.validateMenuItem(NSMenuItem(title: "Print…", action: #selector(NSView.printView(_:)), keyEquivalent: "")))
        table.checkBatchAcrossRunLoopTurn()
        #expect(table.rowUpdateBatch?.reportedRunLoopTurn == true)
        table.endUpdates()
        try click(2)
        #expect(table.selectedRowIndexes == [2])
        withExtendedLifetime(window) {}
    }

    /// Group headers show the subtotals of the columns shown, also of a
    /// column whose values changed while it was hidden.
    @Test func groupSubtotalsFollowShownColumns() {
        let records = CheckedRecords(count: 30)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.rowGrouping = NGRowGrouping(columnID: "status")
        table.layoutSubtreeIfNeeded()
        func subtotal(_ columnID: String, of key: String) -> String? {
            guard let node = table.groupTree.nodes.firstIndex(where: { $0.group.key == key }) else { return nil }
            return table.subtotalTexts(ofNode: node)[columnID]
        }
        #expect(subtotal("amount", of: "A") == "210")
        table.hiddenColumnIDs = ["copy", "amount"]
        #expect(subtotal("amount", of: "A") == nil)
        records.records[2].amount = 100
        table.reloadData(forRowIndexes: [2], columnIndexes: [2])
        table.hiddenColumnIDs = ["copy"]
        #expect(subtotal("amount", of: "A") == "308")
    }

    /// Column indexes mean the columns at the time they were reported, also
    /// when the same index comes again after the columns moved: the cells of
    /// both columns are read again, and a column filter on the second one
    /// sees its new value.
    @Test(arguments: [false, true])
    func reportedColumnsAreTheOnesAtTheTime(filtered: Bool) {
        let records = CheckedRecords(count: 30)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        if filtered { table.columnFilters = ["status": .values(["A", "B"])] }
        func shown(_ row: Int, _ columnID: String) -> String? {
            guard let display = table.displayIndex(ofRow: row), let layer = table.visibleCell(row: display, columnID: columnID),
                  case .text(let text, _, _) = layer.content else { return nil }
            return text
        }
        table.beginUpdates()
        records.records[2].name = "Renamed"
        table.reloadData(forRowIndexes: [2], columnIndexes: [0])   // Name.
        table.moveColumn(1, toColumn: 0)                            // Index 0 is Status now.
        records.records[4].status = "Z"
        table.reloadData(forRowIndexes: [4], columnIndexes: [0])   // Status.
        table.endUpdates()
        #expect(table.tableColumns.map(\.id).prefix(2) == ["status", "name"])
        #expect(shown(2, "name") == "Renamed")
        if filtered {
            #expect(table.displayIndex(ofRow: 4) == nil)
        } else {
            #expect(shown(4, "status") == "Z")
        }
    }
}

/// Index sets built from many handles in random order (one pass over marks).
@Suite("Handle index sets")
struct NGHandleIndexSetTests {
    /// Handles gathered with duplicates come out once each, few or many.
    @Test(arguments: [100, 50_000])
    func uniqueHandlesDropDuplicates(_ count: Int) {
        var generator = SplitMix(seed: UInt64(count))
        let capacity = 10_000
        let handles = (0..<count).map { _ in Int32(generator.next() % UInt64(capacity + 10)) }
        let unique = NGTableView.uniqueHandles(handles, capacity: capacity)
        #expect(Set(unique) == Set(handles.filter { $0 < capacity }))
        #expect(unique.count == Set(unique).count)
    }

    @Test func unionAndRemapMatchPlainSets() {
        var random = SplitMix(seed: 7)
        for count in [10, 300, 5_000] {
            let set = IndexSet((0..<count / 3).map { $0 * 2 })
            let handles = (0..<count).map { _ in Int32(Int.random(in: 0..<1_000, using: &random)) }
            var expected = set
            for handle in handles { expected.insert(Int(handle)) }
            #expect(NGTableView.union(set, handles, capacity: 2_000) == expected)
            let rows = IndexSet(handles.map(Int.init))
            let permutation = Array(0..<1_000).shuffled(using: &random)
            let shifted = NGTableView.shifted(rows, inserting: [], removing: [], moving: nil, isRemapping: true) { row in
                row % 7 == 0 ? nil : permutation[row]
            }
            #expect(shifted == IndexSet(rows.compactMap { $0 % 7 == 0 ? nil : permutation[$0] }))
        }
    }

    /// Removed handles cut out of a set: the same as removing them one by
    /// one, at range ends, inside ranges, outside, twice.
    @Test func subtractingHandlesMatchesRemovingThem() {
        var random = SplitMix(seed: 5)
        for count in [3, 40, 2_000] {
            var set = IndexSet()
            for _ in 0..<count { let start = Int.random(in: 0..<10_000, using: &random); set.insert(integersIn: start..<(start + Int.random(in: 1..<20, using: &random))) }
            var removed = (0..<count).map { _ in Int32(Int.random(in: 0..<10_020, using: &random)) }
            removed += set.rangeView.prefix(5).flatMap { [Int32($0.lowerBound), Int32($0.upperBound - 1), Int32($0.lowerBound)] }
            var expected = set
            for handle in removed { expected.remove(Int(handle)) }
            #expect(NGTableView.subtracting(removed, from: set) == expected)
        }
    }

    /// Handles sorted by radix: the same as sorted by comparison, without -1.
    @Test func radixSortedHandles() {
        var random = SplitMix(seed: 2)
        for count in [0, 10, 600, 5_000] {
            var handles = (0..<count).map { _ in Int32(Int.random(in: 0..<3_000_000, using: &random)) }
            handles += [-1, 0, 65_535, 65_536, Int32.max, 7, 7]
            #expect(NGTableView.radixSorted(handles) == handles.filter { $0 >= 0 }.sorted())
        }
    }

    /// A feed's batch: a few hundred handles in a table of millions. They
    /// are sorted and merged with the set, not marked in an array of every
    /// row, which every batch paid for (O(rows), not O(handles)).
    @Test func unionOfFewHandlesInABigTableCostsTheHandles() {
        var random = SplitMix(seed: 11)
        let capacity = 4_000_000
        // Ranges that touch, overlap and hold the handles; duplicates and -1.
        let set = IndexSet(integersIn: 10..<20).union(IndexSet(integersIn: 21..<30)).union(IndexSet(integersIn: 3_999_990..<4_000_000))
        var handles = (0..<400).map { _ in Int32(Int.random(in: 0..<capacity, using: &random)) }
        handles += [9, 20, 30, 15, 15, -1, 3_999_989, 0]
        var expected = set
        for handle in handles where handle >= 0 { expected.insert(Int(handle)) }
        #expect(NGTableView.union(set, handles, capacity: capacity) == expected)
        let start = CACurrentMediaTime()
        for _ in 0..<200 { _ = NGTableView.union(set, handles, capacity: capacity) }
        #expect(CACurrentMediaTime() - start < 0.2)
    }
}

/// Waits until `condition` holds (turns of the main actor go to the table
/// and its timers meanwhile), at most `timeout`: a condition, not a guess
/// of how long tests running alongside hold the main thread.
@MainActor
func eventually(within timeout: Duration = .seconds(300), _ condition: () -> Bool) async throws {
    try await waitWhile(timeout: timeout, poll: .milliseconds(5)) { !condition() }
}
#endif

/// A small deterministic random number generator, so a failing run repeats.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
