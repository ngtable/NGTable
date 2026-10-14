#if os(macOS)
import AppKit

/// What a batch of row updates changed, in data source rows. Every update
/// maps the indexes kept so far right away; reading values, filtering,
/// summaries, drawing and notifications wait for the end of the batch.
struct NGRowUpdateBatch {
    /// The selection, anchor and cursor as data source rows, kept in step.
    var selection: IndexSet
    var anchor: Int?
    var cursor: Int?
    /// The selection when the batch began, to tell whether it changed, and
    /// as display rows (compared instead when no row moved: cheaper).
    let previousSelection: IndexSet
    var previousDisplaySelection = IndexSet()
    /// Rows were inserted, removed or moved.
    var isStructural = false
    /// Rows moved since the display rows were last computed: until they
    /// are (at the end, or when something changes them during the batch),
    /// `selection`, `anchor` and `cursor` are the selection, and display
    /// rows mean the old rows. Otherwise they follow the displayed selection.
    var displayIsStale = false
    /// `checkBatchAcrossRunLoopTurn()` reported the batch.
    var reportedRunLoopTurn = false
    /// Rows whose values must be read again at the end, by handle (see
    /// `NGRowHandles`: they don't move with the batch's inserts and removes).
    var dirtyRows = IndexSet()
    /// More of them, reloaded record by record: added to `dirtyRows` once at
    /// the end (inserting each into the index set at its place, in random
    /// order, made a feed's batch quadratic).
    var pendingDirtyRows: [Int32] = []
    /// The columns whose cells of `dirtyRows` are drawn again (values only),
    /// by id: reported indexes mean the columns at the time, and the columns
    /// may change before the batch ends.
    var dirtyColumnIDs: Set<String> = []
    /// The indexes reported while the columns were at `reportedColumnsVersion`
    /// (`tableColumnsVersion`): the same indexes again (every record of a feed)
    /// are skipped, but not once the columns changed.
    var reportedColumnIndexes = IndexSet()
    var reportedColumnsVersion = -1
    /// `dirtyColumnIDs` as indexes in `tableColumns`, set at the end.
    var dirtyColumns = IndexSet()
    /// Whether the rows' changes are animated (an update asked for it), and
    /// with which options: the first update's (how rows come and go, see
    /// `NGRowAnimation.Effect`; slides are values, not flags to combine).
    var animates = false
    var animationOptions: NSTableView.AnimationOptions = []
    /// Rows shown again (`unhideRows`), by handle: they come in like new rows.
    var revealedRows = IndexSet()
    /// Inserted rows, by handle: every value of theirs is read.
    var newRows = IndexSet()
    /// `filterEvaluations` when the batch began: if the filter evaluated
    /// every row since (it changed), the totals are computed again.
    var filterEvaluationsAtStart = 0
    /// While a filter is active, `removedValues` holds only rows it showed;
    /// if that couldn't be told, the totals are computed again.
    var removedValuesUnfiltered = false
    /// The summarized values of removed rows by column id, which the summaries
    /// take away.
    var removedValues: [String: [Double]] = [:]
    /// The innermost group (node of the group tree the batch began with) of
    /// each row in `removedValues`, -1 for rows no group showed: the groups'
    /// subtotals take them away too. `groupTreeGeneration` tells whether the
    /// tree is still that one; `groupLeavesAreUnknown` that they weren't noted.
    var removedLeaves: [Int32] = []
    var groupTreeGeneration = 0
    var groupLeavesAreUnknown = false
    /// The record (row handle) of each display row with visible cells when
    /// the batch began: the cells move with them. By handle, which inserts,
    /// removes and moves leave alone (and the batch reuses none): mapping
    /// data source rows on every update was a third of a feed's removes.
    var visibleHandles: [Int: Int32] = [:]
    /// Rows moved while a background computation ran: the summarized values
    /// moved with them, but the values of removed rows weren't noted (the
    /// computation replaces the calculators), so the batch can't update
    /// them in place.
    var movedRowsWithoutSummaryValues = false
    /// The selection by row handle while the batch moves rows and it has
    /// many ranges: shifting them on every update cost O(ranges) each (a
    /// feed's swap-removes fragment a large selection into thousands). Then
    /// `selection` is out of date until `syncBatchSelection()`.
    var selectionByHandle: [Bool]?
    /// How many handles `selectionByHandle` selects, and whether one of them
    /// was removed (the selected records changed; moving them doesn't).
    var selectedHandleCount = 0
    var removedSelectedHandles = false
    /// The batch took the selection kept by handle between batches
    /// (`keptSelection`): `previousSelection` isn't it.
    var tookKeptSelection = false
    /// The app selected or deselected rows in the batch: rows in view may
    /// look selected otherwise. (Without that, removing and moving rows
    /// only drops the removed records from the selection.)
    var selectionSetByCalls = false
    /// Rows moved with `moveRow`, by handle: while the table sorts, they
    /// take their place again among rows with equal sort values, which keep
    /// the data source's order.
    var movedRows = IndexSet()
}

/// Targeted updates, like `NSTableView`'s: the app changes its data first,
/// then tells the table which rows changed, instead of reloading everything.
extension NGTableView {
    // MARK: Batches

    /// Starts a batch of row updates, like `NSTableView`'s: the table finishes
    /// them (filter, summaries, drawing, notifications) once, at the matching
    /// `endUpdates()`. Batches can nest. Each update's indexes refer to the
    /// rows after the updates before it. Don't `await` inside a batch: after
    /// inserts, removes or moves, the rows aren't laid out and ignore the user
    /// until it ends (the table logs a batch open across the run loop).
    public func beginUpdates() {
        // The depth is kept apart: comparing the batch with `nil` would copy it
        // (all its index sets and dictionaries) on every update.
        if rowUpdateDepth == 0 {
            var batch: NGRowUpdateBatch
            if keptSelection == nil { _ = keepLargeSortedSelection() }
            if let kept = keptSelection {
                // Taken by handle as it is (the display selection stays out of date).
                keptSelection = nil
                batch = NGRowUpdateBatch(selection: [], anchor: anchorRow.flatMap(sourceRowIfAny),
                                         cursor: cursorRow.flatMap(sourceRowIfAny), previousSelection: [])
                batch.selectionByHandle = kept.bits
                batch.selectedHandleCount = kept.count
                batch.tookKeptSelection = true
            } else {
                let selection = selectedRowIndexes
                batch = NGRowUpdateBatch(selection: selection, anchor: anchorRow.flatMap(sourceRowIfAny),
                                         cursor: cursorRow.flatMap(sourceRowIfAny), previousSelection: selection)
                batch.previousDisplaySelection = displaySelection
            }
            batch.filterEvaluationsAtStart = filterEvaluations
            batch.groupTreeGeneration = groupTreeGeneration
            // Cells of group headers are placed again at the end.
            for key in visibleCells.keys where key.row < numberOfRows && batch.visibleHandles[key.row] == nil {
                let source = sourceRow(key.row)
                if source >= 0 { batch.visibleHandles[key.row] = rowHandles.handle(at: source) }
            }
            rowUpdateBatch = batch
        }
        rowUpdateDepth += 1
    }

    /// Ends a batch of row updates started with `beginUpdates()`.
    public func endUpdates() {
        guard rowUpdateDepth > 0 else { return }
        rowUpdateDepth -= 1
        guard rowUpdateDepth == 0 else { return }
        guard let batch = rowUpdateBatch.take() else { return }
        finishRowUpdates(batch)
        if localeChangedDuringBatch {
            localeChangedDuringBatch = false
            readLocaleDependentKeysAgain()
        }
    }

    /// Runs one update as a batch of its own unless a batch is open. The batch
    /// changes in place: a copy would copy its index sets on every update.
    private func updatingRows(_ update: (inout NGRowUpdateBatch) -> Void) {
        beginUpdates()
        if rowUpdateDepth > 0 {
            update(&rowUpdateBatch!)
        }
        endUpdates()
    }

    // MARK: Updates

    /// Reads the values of some rows again, like `NSTableView`'s: the cells of
    /// `columnIndexes` (indexes in `tableColumns`) are drawn again, the rows'
    /// summaries (of every column, shown or not) and filter result are
    /// updated, and their search words, sort values and group keys are read
    /// again if their columns are among `columnIndexes` (data the table
    /// doesn't have as a column may change with any). `rowIndexes` are data
    /// source rows.
    public func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        let rows = Self.clamped(rowIndexes, to: numberOfSourceRows)
        guard !rows.isEmpty else { return }
        // Called for every changed record: its handle is only noted (see
        // `pendingDirtyRows`), and the same columns (the usual case) aren't
        // added again (a union copies an index set's storage).
        updatingRows { batch in
            if rows.count == 1, let row = rows.first {
                batch.pendingDirtyRows.append(rowHandles.handle(at: row))
            } else {
                batch.pendingDirtyRows.append(contentsOf: rowHandles.handles(of: rows))
            }
            noteReportedColumns(columnIndexes, in: &batch)
        }
    }

    /// The same for rows given one by one, in any order, repeated or not:
    /// a feed's thousands of scattered rows without an index set of them
    /// (building one, and reading it back, cost more than reloading them).
    public func reloadData(forRows rows: [Int], columnIndexes: IndexSet) {
        guard !rows.isEmpty else { return }
        updatingRows { batch in
            let count = numberOfSourceRows
            if rows.count >= 512 {
                // Many: sorted, their handles found in one walk over the
                // rows (a search per row was most of a feed's reload).
                var valid: [Int32] = []
                valid.reserveCapacity(rows.count)
                for row in rows where row >= 0 && row < count { valid.append(Int32(truncatingIfNeeded: row)) }
                rowHandles.appendHandles(atAscending: Self.radixSorted(valid), to: &batch.pendingDirtyRows)
            } else {
                batch.pendingDirtyRows.reserveCapacity(batch.pendingDirtyRows.count + rows.count)
                for row in rows where row >= 0 && row < count { batch.pendingDirtyRows.append(rowHandles.handle(at: row)) }
            }
            noteReportedColumns(columnIndexes, in: &batch)
        }
    }

    /// The columns reported for reloaded rows, by id (the same indexes again
    /// are skipped while the columns stay).
    private func noteReportedColumns(_ columnIndexes: IndexSet, in batch: inout NGRowUpdateBatch) {
        if batch.reportedColumnsVersion != tableColumnsVersion {
            batch.reportedColumnsVersion = tableColumnsVersion
            batch.reportedColumnIndexes = []
        }
        if !batch.reportedColumnIndexes.contains(integersIn: columnIndexes) {
            batch.reportedColumnIndexes.formUnion(columnIndexes)
            let columns = tableColumns
            for index in columnIndexes where index >= 0 && index < columns.count { batch.dirtyColumnIDs.insert(columns[index].id) }
        }
    }

    /// Tells the table that rows were inserted into the data, like
    /// `NSTableView`'s. `indexes` are the new rows' data source indexes once
    /// they are in. Rows after them move down: the selection and the rows
    /// the summaries and search know about follow. With any
    /// `animationOptions`, rows in view slide and the new ones fade in (one
    /// animation for every option, see `NGRowAnimation`).
    public func insertRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        guard !indexes.isEmpty else { return }
        updatingRows { batch in
            if !animationOptions.isEmpty {
                batch.animates = true
                if batch.animationOptions.isEmpty { batch.animationOptions = animationOptions }
            }
            guard let last = indexes.last, last < numberOfSourceRows + indexes.count, indexes.first ?? 0 >= 0 else {
                assertionFailure("NGTableView: inserted rows \(indexes) out of range")
                return
            }
            // The j-th new row (in order) went in before the old row
            // `index - j`: an old row moves down by the new rows that went in
            // at or before it, found by binary search instead of a walk.
            let before = indexes.enumerated().map { $1 - $0 }
            applyStructuralChange(to: &batch, inserting: indexes) { row in
                var low = 0, high = before.count
                while low < high {
                    let middle = (low + high) / 2
                    if before[middle] <= row { low = middle + 1 } else { high = middle }
                }
                return row + low
            }
        }
    }

    /// Tells the table that rows were removed from the data, like
    /// `NSTableView`'s. `indexes` are the data source indexes the rows had.
    /// Removed rows leave the selection; rows after them move up. With any
    /// `animationOptions`, removed rows fade out and the others slide.
    public func removeRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        let indexes = Self.clamped(indexes, to: numberOfSourceRows)
        guard !indexes.isEmpty else { return }
        updatingRows { batch in
            if !animationOptions.isEmpty {
                batch.animates = true
                if batch.animationOptions.isEmpty { batch.animationOptions = animationOptions }
            }
            applyStructuralChange(to: &batch, removing: indexes) { row in
                indexes.contains(row) ? nil : row - indexes.count(in: 0..<row)
            }
        }
    }

    /// Tells the table that a row was removed from the data and the last row
    /// took its place, the way an array of records is kept without shifting
    /// (a feed's deletes): the same as `removeRows(at: [index])` then
    /// `moveRow(at: lastRow - 1, to: index)`, in one step that shifts nothing.
    public func removeRowReplacingWithLast(at index: Int) {
        let last = numberOfSourceRows - 1
        guard index >= 0, index <= last else { return }
        guard index < last else { return removeRows(at: [index]) }
        updatingRows { batch in
            batch.isStructural = true
            batch.displayIsStale = true
            keepSelectionByHandleIfFragmented(&batch)
            if batch.selectionByHandle == nil { Self.swapRemove(index, last: last, in: &batch.selection) }
            func map(_ row: Int) -> Int? { row == index ? nil : row == last ? index : row }
            batch.anchor = batch.anchor.flatMap { $0 >= 0 ? map($0) : nil }
            batch.cursor = batch.cursor.flatMap { $0 >= 0 ? map($0) : nil }
            Self.swapRemove(index, last: last, in: &rememberedSelection)
            if summaryTask != nil { batch.movedRowsWithoutSummaryValues = true }
            allRowHandlesCache = nil
            rowMapNeedsRebuild = true
            summaryRowsMoved += 1
            noteRemoved(rowHandles.removeReplacingWithLast(at: index), in: &batch)
            let movedHandle = handle(ofRow: index)
            if sortKeys != nil || backgroundSort != nil { batch.movedRows.insert(movedHandle) }
            if filteredRows != nil { filteredRowsToPlace.insert(movedHandle) }
            numberOfSourceRows = rowHandles.count
        }
    }

    /// Rows of a set after a swap-remove: `index` goes, `last` becomes it.
    private nonisolated static func swapRemove(_ index: Int, last: Int, in rows: inout IndexSet) {
        guard !rows.isEmpty else { return }
        let lastWasThere = rows.contains(last)
        rows.remove(index)
        rows.remove(last)
        if lastWasThere { rows.insert(index) }
    }

    /// Whether a batch's selection by handle can stay so after it: every row
    /// shown once in rows of its own (no filter, groups or tree: the display
    /// selection is then the shown rows of the selected handles), totals not
    /// depending on it, and the identities of a selection that became small
    /// remembered first (they are kept by handle: removed rows forget theirs,
    /// moving rows doesn't change them).
    func canKeepSelectionByHandle(count: Int) -> Bool {
        rowFilter == nil && rowMap == nil && groupedDisplay == nil && rowGrouping == nil && !isShowingRowTree
            && summaryScope == .allRows && !(selectionIsLarge && count <= Self.identitySelectionLimit)
    }

    /// Keeps the selection by handle between batches (see `keptSelection`).
    func keepSelection(_ kept: (bits: [Bool], count: Int)) {
        storedDisplaySelection = []
        keptSelection = kept
        displaySelectionIsStale = true
        // Its rows are remembered again when they are built.
        rememberedSelection = []
        if kept.count > Self.identitySelectionLimit {
            selectedIdentifiers = [:]
            selectionIsLarge = true
            selectionIsAllRows = false
        }
    }

    /// A selection of many ranges is kept by handle while rows move (handles don't).
    private func keepSelectionByHandleIfFragmented(_ batch: inout NGRowUpdateBatch) {
        guard batch.selectionByHandle == nil, batch.selection.rangeView.count > 32 else { return }
        var bits = [Bool](repeating: false, count: rowHandles.capacity)
        bits.withUnsafeMutableBufferPointer { bits in
            rowHandles.forEachHandle(of: batch.selection) { bits[Int($0)] = true }
        }
        batch.selectionByHandle = bits
        batch.selectedHandleCount = batch.selection.count
        batch.selection = []
    }

    /// Tells the table that a row moved in the data, like `NSTableView`'s:
    /// it keeps its selection and values; the rows between move by one.
    public func moveRow(at oldIndex: Int, to newIndex: Int) {
        guard oldIndex != newIndex, oldIndex >= 0, oldIndex < numberOfSourceRows,
              newIndex >= 0, newIndex < numberOfSourceRows else { return }
        updatingRows { batch in
            applyStructuralChange(to: &batch, moving: (oldIndex, newIndex)) { row in
                if row == oldIndex { return newIndex }
                if oldIndex < newIndex, row > oldIndex, row <= newIndex { return row - 1 }
                if newIndex < oldIndex, row >= newIndex, row < oldIndex { return row + 1 }
                return row
            }
        }
    }

    /// Tells the table that the same rows are in another order, e.g. sorted:
    /// `oldIndexes[row]` is the data source index each row had before. Use it
    /// after sorting instead of `reloadData()`: nothing is read again, and the
    /// cells, the selection, the summarized values, the search index and the
    /// groups move with their rows, so even a huge table re-sorts at once.
    /// The values must be the same; if they changed too, reload.
    public func reorderRows(fromOldIndexes oldIndexes: [Int]) {
        guard oldIndexes.count == numberOfSourceRows else {
            assertionFailure("NGTableView: a new order of \(oldIndexes.count) rows, the table has \(numberOfSourceRows)")
            reloadData()
            return
        }
        var oldToNew = [Int?](repeating: nil, count: numberOfSourceRows)
        for (new, old) in oldIndexes.enumerated() {
            guard old >= 0, old < oldToNew.count, oldToNew[old] == nil else {
                assertionFailure("NGTableView: the new order has \(old) out of range or twice")
                reloadData()
                return
            }
            oldToNew[old] = new
        }
        // Already in that order: nothing moves.
        guard oldIndexes.enumerated().contains(where: { $0 != $1 }) else { return }
        remapRows(oldToNew, newCount: numberOfSourceRows)
    }

    /// `reorderRows(fromOldIndexes:)` for two orders of the app's rows, like
    /// `NGSorting.order(ofRows:by:value:)` gives them (each an array of the
    /// indexes in the app's data). Reloads instead when the table doesn't
    /// show those rows yet, e.g. for a sort restored before it read them.
    ///
    /// ```swift
    /// let previous = order
    /// order = NGSorting.order(ofRows: campaigns.count, by: tableView.sortDescriptors) { … }
    /// tableView.reorderRows(from: previous, to: order)
    /// ```
    public func reorderRows(from previous: [Int], to new: [Int]) {
        guard previous.count == new.count, previous.count == numberOfSourceRows,
              dataSource?.numberOfRows(in: self) == numberOfSourceRows else {
            reloadData()
            return
        }
        reorderRows(fromOldIndexes: NGSorting.oldIndexes(from: previous, to: new))
    }

    /// Tells the table that the rows changed all at once: `oldToNew[row]` is
    /// the new index of each old row (`nil`: removed), and rows no old row
    /// maps to are new. For diffs (`NGTableViewDiffableDataSource`), where
    /// one pass over the rows beats a series of inserts, removes and moves.
    func remapRows(_ oldToNew: [Int?], newCount: Int) {
        guard oldToNew.count == numberOfSourceRows else {
            assertionFailure("NGTableView: a remapping of \(oldToNew.count) rows, the table has \(numberOfSourceRows)")
            return
        }
        // From marks, in one pass each: removing and inserting at random
        // places in index sets was quadratic (seconds for a million rows).
        var isNew = [Bool](repeating: true, count: newCount)
        var isRemoved = [Bool](repeating: false, count: oldToNew.count)
        for (old, new) in oldToNew.enumerated() {
            if let new {
                if new >= 0, new < newCount { isNew[new] = false }
            } else {
                isRemoved[old] = true
            }
        }
        let inserted = Self.runs(of: isNew)
        let removed = Self.runs(of: isRemoved)
        updatingRows { batch in
            applyStructuralChange(to: &batch, inserting: inserted, removing: removed, remapping: oldToNew) { row in
                row < oldToNew.count ? oldToNew[row] : nil
            }
        }
    }

    /// Tells the table that rows were added at or removed from the end of the
    /// data, like `NSTableView`'s: the existing rows keep their values.
    public func noteNumberOfRowsChanged() {
        let count = dataSource?.numberOfRows(in: self) ?? 0
        if count > numberOfSourceRows {
            insertRows(at: IndexSet(integersIn: numberOfSourceRows..<count))
        } else if count < numberOfSourceRows {
            removeRows(at: IndexSet(integersIn: count..<numberOfSourceRows))
        }
    }

    /// Receives how long each phase of finishing a batch took (for benchmarks).
    static var rowUpdatePhasesForTesting: (([(String, CFTimeInterval)]) -> Void)?

    // MARK: Bookkeeping

    /// Moves every row index the table keeps (the selection, its anchor and
    /// cursor, the rows of visible cells, as `map` says; `nil`: removed) and
    /// the rows' handles (see `NGRowHandles`): removed rows give their handle
    /// up, new rows get one, moved rows keep theirs. The per-row data is kept
    /// by handle, so it doesn't move; new rows get placeholders and are read
    /// at the end of the batch.
    private func applyStructuralChange(to batch: inout NGRowUpdateBatch, inserting inserted: IndexSet = [],
                                       removing removed: IndexSet = [], moving moved: (from: Int, to: Int)? = nil,
                                       remapping: [Int?]? = nil, map: (Int) -> Int?) {
        batch.isStructural = true
        batch.displayIsStale = true
        // A remapping goes row by row: the selection in rows first.
        if remapping != nil, let bits = batch.selectionByHandle {
            batch.selection = Self.rows(ofSelectedHandles: bits, in: rowHandles)
            batch.selectionByHandle = nil
        }
        if remapping == nil { keepSelectionByHandleIfFragmented(&batch) }
        if batch.selectionByHandle == nil {
            // By ranges: a large selection (all rows) costs its ranges, not its rows.
            batch.selection = Self.shifted(Self.taking(&batch.selection), inserting: inserted, removing: removed, moving: moved,
                                           isRemapping: remapping != nil, map: map)
        }
        // (A group header has no data source row: never kept as one.)
        batch.anchor = batch.anchor.flatMap { $0 >= 0 ? map($0) : nil }
        batch.cursor = batch.cursor.flatMap { $0 >= 0 ? map($0) : nil }
        rememberedSelection = Self.shifted(Self.taking(&rememberedSelection), inserting: inserted, removing: removed, moving: moved,
                                           isRemapping: remapping != nil, map: map)
        // A background computation reads rows that are moving: the values of
        // removed rows aren't noted (it replaces the calculators).
        if summaryTask != nil { batch.movedRowsWithoutSummaryValues = true }
        allRowHandlesCache = nil
        rowMapNeedsRebuild = true
        summaryRowsMoved += 1
        if let remapping {
            remapHandles(remapping, newCount: rowHandles.count - removed.count + inserted.count, in: &batch)
        } else {
            for index in removed.reversed() {
                noteRemoved(rowHandles.remove(at: index), in: &batch)
            }
            if let (from, to) = moved {
                rowHandles.move(from: from, to: to)
                let movedHandle = handle(ofRow: to)
                if sortKeys != nil || backgroundSort != nil { batch.movedRows.insert(movedHandle) }
                if filteredRows != nil { filteredRowsToPlace.insert(movedHandle) }
            }
            for index in inserted {
                let handle = rowHandles.insert(at: index)
                noteInserted(handle, in: &batch)
                // New rows aren't selected (a handle may be a reused one).
                if batch.selectionByHandle != nil {
                    if Int(handle) >= batch.selectionByHandle!.count {
                        batch.selectionByHandle!.append(contentsOf: repeatElement(false, count: Int(handle) - batch.selectionByHandle!.count + 1))
                    }
                    batch.selectionByHandle![Int(handle)] = false
                }
            }
        }
        numberOfSourceRows = rowHandles.count
    }

    /// The handles for a whole remapping (old row to new row): the rows that
    /// stay keep theirs, in their new order; rows no old row maps to are new.
    private func remapHandles(_ remapping: [Int?], newCount: Int, in batch: inout NGRowUpdateBatch) {
        var order = [Int32](repeating: -1, count: newCount)
        for (old, new) in remapping.enumerated() where old < rowHandles.count {
            if let new {
                if new < newCount { order[new] = rowHandles.handle(at: old) }
            } else {
                noteRemoved(rowHandles.handle(at: old), in: &batch)
            }
        }
        for handle in rowHandles.replaceOrder(with: order) {
            noteInserted(handle, in: &batch)
        }
        // Rows with equal sort values follow the data source's new order.
        if sortedOrder != nil { sortOrderNeedsRebuild = true }
        // The filtered rows too (built again from their matches).
        filteredRows = nil
        filteredRowsToPlace = []
        batch.groupLeavesAreUnknown = true
    }

    /// A row going: the summaries take away its values (if it was shown),
    /// and its group's subtotals too.
    private func noteRemoved(_ handle: Int32, in batch: inout NGRowUpdateBatch) {
        if batch.selectionByHandle != nil, Int(handle) < batch.selectionByHandle!.count, batch.selectionByHandle![Int(handle)] {
            batch.selectionByHandle![Int(handle)] = false
            batch.selectedHandleCount -= 1
            batch.removedSelectedHandles = true
        }
        // A removed record's identity is no longer selected (its handle may be reused).
        if !selectedIdentifiers.isEmpty { selectedIdentifiers.removeValue(forKey: handle) }
        identityIndex?.remove(handle)
        if !treeParentHandles.isEmpty { treeRemovedHandles.insert(handle) }
        let handle = Int(handle)
        guard !batch.movedRowsWithoutSummaryValues, !summarySourceValues.isEmpty else {
            if groupedDisplay != nil { batch.groupLeavesAreUnknown = true }
            return
        }
        // With a filter, the totals lose only the rows it showed.
        if rowMap != nil {
            guard let matches = filterMatches else {
                batch.removedValuesUnfiltered = true
                return
            }
            guard handle < matches.count, matches[handle] else { return }
        }
        // A row the batch inserted was never summarized (a reused handle
        // still holds a removed row's values).
        let wasSummarized = !batch.newRows.contains(handle)
        for (key, values) in summarySourceValues {
            batch.removedValues[key, default: []].append(wasSummarized && handle < values.count ? values[handle] : .nan)
        }
        if groupedDisplay != nil {
            if batch.groupTreeGeneration != groupTreeGeneration {
                batch.groupLeavesAreUnknown = true
            } else {
                batch.removedLeaves.append(handle < groupTree.leafOfSourceRow.count ? groupTree.leafOfSourceRow[handle] : -1)
            }
        }
    }

    /// A row coming (or a reused handle): its per-row data starts empty, and
    /// everything of it is read at the end of the batch.
    private func noteInserted(_ handle: Int32, in batch: inout NGRowUpdateBatch) {
        if !treeParentHandles.isEmpty {
            treeParentsToRead.insert(Int(handle))
            rowsInsertedSinceTreeLayout = true
        }
        if identityIndex != nil {
            identityIndex?.noteInserted(handle)
            // Many inserts without lookups: read all rows again when asked.
            if identityIndex!.pending.count > max(1024, numberOfSourceRows / 2) { identityIndex = nil }
        }
        // Read at the end with the reloaded ones (a list: reused handles go
        // into an index set at random places).
        batch.pendingDirtyRows.append(handle)
        let handle = Int(handle)
        batch.newRows.insert(handle)
        prepareRowData(forHandle: handle)
    }

    /// Placeholders for a new row's handle in the per-row data (taken out
    /// while they change: one owner, no copies). The summarized values grow
    /// at the end of the batch, once their calculators let them go. Arrays
    /// not in use (empty: no sort, no groups) stay empty.
    private func prepareRowData(forHandle handle: Int) {
        // A reused handle is a new record: shown, not flashing, its height asked.
        hiddenRowHandles.remove(handle)
        if handle < rowHeightsByHandle.count { rowHeightsByHandle[handle] = .nan }
        forgetChangeHighlights(ofHandle: handle)
        func prepare<Element>(_ array: inout [Element], _ placeholder: Element) {
            guard !array.isEmpty else { return }
            if handle < array.count {
                array[handle] = placeholder
            } else {
                array.append(contentsOf: repeatElement(placeholder, count: handle - array.count + 1))
            }
        }
        if var matches = filterMatches.take() {
            prepare(&matches, false)
            filterMatches = matches
        }
        filteredRows?.reserve(capacity: handle + 1)
        // A reused handle is in no sorted order (rows gone leave them at the end of their batch).
        sortedOrder?.reserve(capacity: handle + 1)
        if sortedOrder != nil { sortRowsInserted.append(Int32(handle)) }
        filteredSortedOrder?.reserve(capacity: handle + 1)
        prepare(&displayRowOfSource, -1)
        prepare(&groupTree.leafOfSourceRow, -1)
        if var index = searchIndex.take() {
            index.grow(to: handle + 1)
            index.clear(handle)
            searchIndex = index
        }
        if var build = searchBuild.take() {
            build.index.grow(to: handle + 1)
            build.index.clear(handle)
            prepare(&build.read, false)
            searchBuild = build
        }
        if var keys = groupKeys.take() {
            for level in keys.ids.indices { prepare(&keys.ids[level], -1) }
            groupKeys = keys
        }
        if var keys = sortKeys.take() {
            keys.prepare(handle)
            sortKeys = keys
        }
        if var job = backgroundSort.take() {
            job.prepare(handle)
            backgroundSort = job
        }
        if var build = summaryBuild.take() {
            prepare(&build.values, .nan)
            prepare(&build.read, false)
            summaryBuild = build
        }
    }

    /// The handles of a set that still belong to rows.
    nonisolated static func live(_ handles: IndexSet, in rowHandles: NGRowHandles) -> IndexSet {
        var result = handles
        for handle in handles where !rowHandles.contains(Int32(truncatingIfNeeded: handle)) { result.remove(handle) }
        return result
    }

    /// A batch's rows (handles) without those it removed: the batch's sets
    /// hold only handles of rows it had, so this is `live(_:in:)` without a
    /// lookup per row.
    nonisolated static func subtracting(_ removed: [Int32], from handles: IndexSet) -> IndexSet {
        guard !removed.isEmpty, !handles.isEmpty else { return handles }
        if removed.count <= 8 {
            var result = handles
            for handle in removed { result.remove(Int(handle)) }
            return result
        }
        // Built in order, cutting the sorted handles out of each range:
        // removing them one by one shifts the set's ranges every time.
        let sorted = removed.sorted()
        var result = IndexSet()
        var next = 0
        for range in handles.rangeView {
            var start = range.lowerBound
            while next < sorted.count, Int(sorted[next]) < range.lowerBound { next += 1 }
            while next < sorted.count, Int(sorted[next]) < range.upperBound {
                let cut = Int(sorted[next])
                if cut > start { result.insert(integersIn: start..<cut) }
                start = max(start, cut + 1)
                next += 1
            }
            if start < range.upperBound { result.insert(integersIn: start..<range.upperBound) }
        }
        return result
    }

    /// The rows below `count`. Most sets are already: then they are returned
    /// as they are, without building and intersecting a range of all rows.
    nonisolated static func clamped(_ rows: IndexSet, to count: Int) -> IndexSet {
        guard let first = rows.first, let last = rows.last else { return rows }
        if first >= 0, last < count { return rows }
        return rows.intersection(IndexSet(integersIn: 0..<max(0, count)))
    }

    /// The rows of an index set after a structural change: by ranges (not
    /// row by row) for inserts, removes and moves, which a batch of many
    /// single-row changes does hundreds of times over a growing set. A
    /// remapping goes row by row (`map`).
    /// The data source rows of selected handles (removed ones have none), in
    /// one pass over the rows.
    nonisolated static func rows(ofSelectedHandles bits: [Bool], in rowHandles: NGRowHandles) -> IndexSet {
        var result = IndexSet()
        var start = -1
        bits.withUnsafeBufferPointer { bits in
            rowHandles.forEachHandle { row, handle in
                let selected = Int(handle) < bits.count && bits[Int(handle)]
                if selected {
                    if start < 0 { start = row }
                } else if start >= 0 {
                    result.insert(integersIn: start..<row)
                    start = -1
                }
            }
        }
        if start >= 0 { result.insert(integersIn: start..<rowHandles.count) }
        return result
    }

    /// The open batch's selection in data source rows again, if it keeps it
    /// by handle (for whatever reads or changes it in the middle of a batch).
    func syncBatchSelection() {
        guard let bits = rowUpdateBatch?.selectionByHandle else { return }
        rowUpdateBatch!.selectionByHandle = nil
        rowUpdateBatch!.selection = Self.rows(ofSelectedHandles: bits, in: rowHandles)
    }

    /// The set, leaving an empty one in its place (so it has one owner).
    nonisolated static func taking(_ set: inout IndexSet) -> IndexSet {
        var taken = IndexSet()
        swap(&taken, &set)
        return taken
    }

    /// Pass the set taken out of where it is kept (`taking(_:)`): changed in
    /// place, not copied (a selection of many ranges was copied on every
    /// update of a batch).
    nonisolated static func shifted(_ rows: consuming IndexSet, inserting inserted: IndexSet, removing removed: IndexSet,
                        moving moved: (from: Int, to: Int)?, isRemapping: Bool, map: (Int) -> Int?) -> IndexSet {
        guard !rows.isEmpty else { return rows }
        // Marked, then read off in order: an index set built in random order is quadratic.
        if isRemapping {
            var mapped: [Int] = []
            mapped.reserveCapacity(rows.count)
            var largest = -1
            for row in rows {
                guard let new = map(row), new >= 0 else { continue }
                mapped.append(new)
                largest = max(largest, new)
            }
            var marked = [Bool](repeating: false, count: largest + 1)
            for new in mapped { marked[new] = true }
            return NGTableView.runs(of: marked)
        }
        var rows = rows
        // A negative shift drops the indexes it lands on: each one below
        // lands on a removed or empty position.
        if let (from, to) = moved {
            let wasThere = rows.contains(from)
            rows.remove(from)
            if from < to {
                // (from, to] move up by one; the rows after `to` stay.
                rows.shift(startingAt: from + 1, by: -1)
                rows.shift(startingAt: to, by: 1)
            } else {
                // [to, from) move down by one; the rows after `from` stay
                // (shifted too, then back over the empty `from + 1`).
                rows.shift(startingAt: to, by: 1)
                rows.shift(startingAt: from + 2, by: -1)
            }
            if wasThere { rows.insert(to) }
        }
        for range in removed.rangeView.reversed() {
            rows.remove(integersIn: range)
            rows.shift(startingAt: range.upperBound, by: -range.count)
        }
        // In order: each range's position already counts the ranges before it.
        for range in inserted.rangeView {
            rows.shift(startingAt: range.lowerBound, by: range.count)
        }
        return rows
    }

    /// The values the filtered totals lose and gain: of removed rows the
    /// filter showed, the old values of changed rows it showed, and the new
    /// values of changed rows it shows now. `nil` if the values don't line
    /// up with the rows.
    private nonisolated static func filteredChanges(of rows: [Int], shownBefore: IndexSet, matches: [Bool],
                                                    removedRows: [String: [Double]], olds: [String: [Double]],
                                                    news: [String: [Double]]) -> (removed: [String: [Double]], added: [String: [Double]])? {
        var removed = removedRows
        var added: [String: [Double]] = [:]
        for (columnID, new) in news {
            guard let old = olds[columnID], old.count == rows.count, new.count == rows.count else { return nil }
            var lost = removed[columnID] ?? []
            var gained: [Double] = []
            for (index, row) in rows.enumerated() {
                if shownBefore.contains(row) { lost.append(old[index]) }
                if row < matches.count, matches[row] { gained.append(new[index]) }
            }
            removed[columnID] = lost
            added[columnID] = gained
        }
        return (removed, added)
    }

    /// The rows of `rows` that `matches` marks.
    nonisolated static func matchingRows(_ rows: IndexSet, _ matches: [Bool]) -> IndexSet {
        var result = IndexSet()
        for row in rows where row < matches.count && matches[row] { result.insert(row) }
        return result
    }

    /// What the user was doing with a record the batch removed ends: the
    /// editor closes without committing, the swipe closes, the choice menu
    /// closes, and the focused cell and cell range go (they would come back
    /// on whichever record gets the handle next).
    private func endInteractionsWithRemovedRecords() {
        if let editor, row(of: editor.ref) < 0 { endEditing(committing: false) }
        if let rowSwipe, row(of: rowSwipe.ref) < 0 { closeRowActions() }
        if let openChoiceMenu, row(of: openChoiceMenu.ref) < 0 { openChoiceMenu.menu.cancelTracking() }
        if let focusedHandleCell, position(of: focusedHandleCell) == nil { self.focusedHandleCell = nil }
        if let range = selectedHandleRange, position(of: range.anchor) == nil || position(of: range.end) == nil {
            selectedHandleRange = nil
        }
    }

    /// An index set with more handles, in one pass over the handles when
    /// there are many (in any order).
    nonisolated static func union(_ set: IndexSet, _ handles: [Int32], capacity: Int) -> IndexSet {
        guard handles.count > 16 else {
            var result = set
            for handle in handles where handle >= 0 { result.insert(Int(handle)) }
            return result
        }
        let size = max(capacity, (set.last ?? -1) + 1, Int(handles.max() ?? -1) + 1)
        // Few handles among many rows (a feed's batch in a big table): sorted
        // and merged with the set's ranges, instead of a pass over every row.
        if handles.count * 16 < size {
            return merged(set, sortedHandles: radixSorted(handles))
        }
        var marked = [Bool](repeating: false, count: size)
        for range in set.rangeView {
            for index in range { marked[index] = true }
        }
        marked.withUnsafeMutableBufferPointer { marked in
            for handle in handles where handle >= 0 { marked[Int(handle)] = true }
        }
        return NGTableView.runs(of: marked)
    }

    /// Whether every row in view shows the record it showed when the batch
    /// began (`sources`: their data source rows now), unchanged: then its
    /// cells and background stay as they are. Not with group header or tree
    /// rows, whose look depends on rows around them.
    private func rowsInViewShowTheSameRecords(_ sources: [Int: Int]) -> Bool {
        guard groupedDisplay == nil, !isShowingRowTree, let range = lastVisibleRange,
              range.rows.upperBound <= numberOfRows else { return false }
        for row in range.rows {
            guard let source = sources[row], displayRow(forSourceRow: source) == row else { return false }
        }
        return true
    }

    /// The rows in view whose records changed lose their changed cells and
    /// are placed again by the next layout pass, alone (the others stay as
    /// they are: placing every row in view for a few changed ones was most
    /// of a feed's layout). Whether any is in view.
    private func placeChangedRowsInViewAgain(_ dirty: IndexSet, columns: IndexSet) -> Bool {
        guard let range = lastVisibleRange else { return false }
        let all = tableColumns
        let ordinals = columns.compactMap { $0 >= 0 && $0 < all.count ? columnOrdinal(of: all[$0].id) : nil }
        var any = false
        for row in range.rows where row < numberOfRows {
            let source = sourceRow(row)
            guard source >= 0, dirty.contains(handle(ofRow: source)) else { continue }
            for ordinal in ordinals {
                if let cell = visibleCells.removeValue(forKey: NGCellKey(row: row, column: ordinal)) { recycle(cell) }
            }
            rowsToPlaceAgain.insert(row)
            any = true
        }
        return any
    }

    /// Handles (`-1` left out) in ascending order: three passes of 11 bits
    /// (2,048 buckets), several times faster than a comparison sort of a
    /// batch's thousands; small ones are sorted by comparison.
    nonisolated static func radixSorted(_ handles: [Int32]) -> [Int32] {
        var source = handles.filter { $0 >= 0 }
        guard source.count >= 512 else { return source.sorted() }
        var target = [Int32](repeating: 0, count: source.count)
        var counts = [Int](repeating: 0, count: 1 << 11)
        for shift in [0, 11, 22] as [Int32] {
            source.withUnsafeBufferPointer { source in
                target.withUnsafeMutableBufferPointer { target in
                    counts.withUnsafeMutableBufferPointer { counts in
                        for index in counts.indices { counts[index] = 0 }
                        for handle in source { counts[Int((handle >> shift) & 0x7FF)] &+= 1 }
                        var total = 0
                        for index in counts.indices {
                            let count = counts[index]
                            counts[index] = total
                            total &+= count
                        }
                        for handle in source {
                            let bucket = Int((handle >> shift) & 0x7FF)
                            target[counts[bucket]] = handle
                            counts[bucket] &+= 1
                        }
                    }
                }
            }
            swap(&source, &target)
        }
        return source
    }

    /// An index set with sorted handles (duplicates allowed) added, built in
    /// order: appending ranges at the end costs nothing, inserting them in
    /// the middle shifts the set's ranges.
    /// Handles (`-1` left out, duplicates once) without the `excluded`
    /// ones, as a set: both sorted and merged, built once.
    nonisolated static func handleSet(_ handles: [Int32], excluding excluded: [Int32]) -> IndexSet {
        let sorted = radixSorted(handles)
        let cuts = excluded.count >= 512 ? radixSorted(excluded) : excluded.filter { $0 >= 0 }.sorted()
        var result = IndexSet()
        var next = 0
        var start = -1, end = -1
        for handle in sorted {
            while next < cuts.count, cuts[next] < handle { next &+= 1 }
            if next < cuts.count, cuts[next] == handle { continue }
            let handle = Int(handle)
            if handle <= end { end = max(end, handle &+ 1); continue }
            if start >= 0 { result.insert(integersIn: start..<end) }
            (start, end) = (handle, handle &+ 1)
        }
        if start >= 0 { result.insert(integersIn: start..<end) }
        return result
    }

    nonisolated static func merged(_ set: IndexSet, sortedHandles: [Int32]) -> IndexSet {
        var result = IndexSet()
        var ranges = set.rangeView.makeIterator()
        var nextRange = ranges.next()
        // The run being built.
        var start = -1, end = -1
        func add(_ range: Range<Int>) {
            if start >= 0, range.lowerBound <= end {
                end = max(end, range.upperBound)
                return
            }
            if start >= 0 { result.insert(integersIn: start..<end) }
            (start, end) = (range.lowerBound, range.upperBound)
        }
        for handle in sortedHandles {
            let handle = Int(handle)
            while let range = nextRange, range.lowerBound <= handle {
                add(range)
                nextRange = ranges.next()
            }
            add(handle..<(handle + 1))
        }
        while let range = nextRange {
            add(range)
            nextRange = ranges.next()
        }
        if start >= 0 { result.insert(integersIn: start..<end) }
        return result
    }

    /// Finishes a batch: reads what changed, filters, summarizes, draws and
    /// tells the delegate, once.
    private func finishRowUpdates(_ batch: NGRowUpdateBatch) {
        var batch = batch
        // A large selection by handle stays so between batches (building its
        // rows walked every row, for every batch of a feed); else in rows.
        var keeping: (bits: [Bool], count: Int)?
        if let bits = batch.selectionByHandle {
            if canKeepSelectionByHandle(count: batch.selectedHandleCount) {
                keeping = (bits, batch.selectedHandleCount)
            } else {
                batch.selection = Self.rows(ofSelectedHandles: bits, in: rowHandles)
            }
            batch.selectionByHandle = nil
        }
        // The reported columns where they are now.
        if !batch.dirtyColumnIDs.isEmpty {
            let columns = tableColumns
            batch.dirtyColumns = IndexSet(columns.indices.filter { batch.dirtyColumnIDs.contains(columns[$0].id) })
        } else {
            batch.dirtyColumns = []
        }
        // Handles the batch removed can be reused from the next batch on.
        defer { rowHandles.releaseRemoved() }
        endInteractionsWithRemovedRecords()
        guard let dataSource else { return }
        var phases: [(String, CFTimeInterval)] = []
        var phaseStart = CACurrentMediaTime()
        func phase(_ name: String) {
            guard Self.rowUpdatePhasesForTesting != nil else { return }
            let now = CACurrentMediaTime()
            phases.append((name, now - phaseStart))
            phaseStart = now
        }
        defer { Self.rowUpdatePhasesForTesting?(phases) }
        // The app must change its data to match the updates, like for an
        // NSTableView; if it didn't, everything is read again.
        guard dataSource.numberOfRows(in: self) == numberOfSourceRows else {
            assertionFailure("NGTableView: the data source has \(dataSource.numberOfRows(in: self)) rows, the updates make \(numberOfSourceRows)")
            reloadData()
            return
        }
        let readsTreeParents = isShowingRowTree && !treeParentHandles.isEmpty
        // A feed's batch, its changed rows given as a list: their set is
        // built once, without the rows removed after they changed.
        let dirtyListOnly = !readsTreeParents && batch.dirtyRows.isEmpty && batch.pendingDirtyRows.count > 16
        let batchDirtyRows = dirtyListOnly ? IndexSet() : Self.union(batch.dirtyRows, batch.pendingDirtyRows, capacity: rowHandles.capacity)
        // Reloaded rows' heights are asked again.
        if rowHeightProvider != nil || wrapsTextInSomeColumn {
            if dirtyListOnly {
                forgetRowHeights(ofHandles: batch.pendingDirtyRows.lazy.map { Int($0) })
            } else {
                forgetRowHeights(ofHandles: batchDirtyRows)
            }
        }
        // A tree's parents first: the summaries leave out rows with a parent
        // (`.topLevelRows`), so new rows, changed ones and those whose parent
        // came or went are read by what they are now; rows that got or lost
        // a parent count as changed.
        var batchRows = batchDirtyRows
        // Rows already shown that got another parent: with a filter, whether
        // their descendants count depends on the new ancestors' matches.
        var treeRowsReparented = false
        if readsTreeParents {
            treeParentsToRead.formUnion(batchDirtyRows)
            treeReparentedHandles = []
            if readTreeParents() { treeParentsChangedSinceLayout = true }
            treeRowsReparented = treeReparentedHandles.contains { !batch.newRows.contains($0) }
            treeReparentedHandles = []
            if !treeSummaryFlips.isEmpty {
                batchRows.formUnion(IndexSet(treeSummaryFlips))
                treeSummaryFlips = []
            }
        }
        // Rows by handle: those removed after they changed are gone.
        let dirty = dirtyListOnly
            ? Self.handleSet(batch.pendingDirtyRows, excluding: rowHandles.removedHandles)
            : Self.subtracting(rowHandles.removedHandles, from: batchRows)
        // Search words, sort and group keys are read again only for the rows
        // whose columns changed: a feed of changing numbers doesn't fold the
        // names of its rows every tick. Columns not in `tableColumns` (data
        // the table doesn't show) may have changed with any of them.
        let shownColumns = tableColumns
        let tableColumnIDs = Set(shownColumns.map(\.id))
        let changedColumnIDs = Set(batch.dirtyColumns.compactMap { $0 < shownColumns.count ? shownColumns[$0].id : nil })
        let newRows = Self.subtracting(rowHandles.removedHandles, from: batch.newRows)
        func rowsToRead(forColumns columnIDs: some Sequence<String>) -> IndexSet {
            let unchanged = columnIDs.allSatisfy { tableColumnIDs.contains($0) && !changedColumnIDs.contains($0) }
            return unchanged ? newRows : dirty
        }
        // A computation that ran during the batch may have finished with values
        // in the old order: they aren't used (the batch is structural, so the
        // summaries are rebuilt from the data source below).
        let summariesAreCached = summaryTask == nil && !batch.movedRowsWithoutSummaryValues
        // Old values the summaries take away (of removed and changed rows), and new ones they add.
        var removedValues = batch.removedValues
        var addedValues: [String: [Double]] = [:]
        // The changed rows' old and new values, in the order of `dirty`.
        var changedOlds: [String: [Double]] = [:]
        if summariesAreCached {
            detachSummarySources()
            let dirtyRows = Array(dirty)
            // Looked up once, not per column: whether each is new, and its row.
            // (Loops, not `map`: a closure made here checks the main actor on every call.)
            var isNew: [Bool] = [], rowsOfDirty: [Int] = []
            rowsOfDirty.reserveCapacity(dirtyRows.count)
            for handle in dirtyRows { rowsOfDirty.append(row(ofHandle: handle)) }
            if !newRows.isEmpty {
                isNew.reserveCapacity(dirtyRows.count)
                for handle in dirtyRows { isNew.append(newRows.contains(handle)) }
            }
            let capacity = rowHandles.capacity
            for columnID in Array(summarySourceValues.keys) {
                let column = summaryColumn(columnID)
                var olds: [Double] = [], news: [Double] = []
                olds.reserveCapacity(dirtyRows.count)
                news.reserveCapacity(dirtyRows.count)
                // Out of the dictionary while it changes: one lookup per column
                // instead of two per row, and still no copy. New handles get room.
                var values = summarySourceValues.removeValue(forKey: columnID) ?? []
                if values.count < capacity { values.append(contentsOf: repeatElement(.nan, count: capacity - values.count)) }
                // All the rows' numbers at once if the data source gives them.
                var read = [Double](repeating: .nan, count: dirtyRows.count)
                let readAtOnce = !treeSummariesCountTopLevel && rowsOfDirty.withUnsafeBufferPointer { rows in
                    read.withUnsafeMutableBufferPointer { dataSource.tableView(self, numbersFor: column, atRows: rows, into: $0) }
                }
                for (position, handle) in dirtyRows.enumerated() {
                    let new = readAtOnce ? read[position] : treeExcludesFromSummaries(handle: handle) ? .nan
                        : dataSource.tableView(self, valueFor: column, row: rowsOfDirty[position]).numericValue ?? .nan
                    // A new row (maybe a reused handle) had no value.
                    olds.append(!isNew.isEmpty && isNew[position] ? .nan : values[handle])
                    values[handle] = new
                    news.append(new)
                }
                summarySourceValues[columnID] = values
                removedValues[columnID, default: []].append(contentsOf: olds)
                addedValues[columnID] = news
                changedOlds[columnID] = olds
            }
        }
        var searchRows = dirty
        if var index = searchIndex.take() {
            index.grow(to: rowHandles.capacity)
            // The searched columns that may have changed (by position).
            let changed = index.columns.indices.filter {
                let id = index.columns[$0].id
                return changedColumnIDs.contains(id) || !tableColumnIDs.contains(id)
            }
            searchRows = []
            for handle in dirty {
                let row = row(ofHandle: handle)
                var reads = newRows.contains(handle)
                if !reads, !changed.isEmpty {
                    if index.tracksTextColumns {
                        // Only text gives words: a changed column matters if
                        // it gave words before or gives them now.
                        let mask = index.textColumns[handle]
                        for position in changed where mask & (1 << UInt64(position)) != 0
                            || dataSource.tableView(self, valueFor: index.columns[position], row: row).givesSearchWords {
                            reads = true
                            break
                        }
                    } else {
                        reads = true
                    }
                }
                guard reads else { continue }
                let entry = searchEntry(ofRow: row, in: index.columns, explicit: index.explicit, dataSource: dataSource)
                index.set(entry.words, textColumns: entry.textColumns, row: handle)
                searchRows.insert(handle)
            }
            searchIndex = index
        }
        // An index being built reads the changed rows again.
        if var build = searchBuild.take() {
            for handle in rowsToRead(forColumns: build.index.columnIDs) where handle < build.read.count {
                build.read[handle] = false
            }
            searchBuild = build
        }
        phase("read")

        // The filter may now show other rows, and changed values move rows
        // to other groups (and change the subtotals).
        let previousRowMap = rowMap
        // The changed rows the filter showed, for the totals.
        let shownBefore = rowMap != nil ? filterMatches.map { Self.matchingRows(dirty, $0) } : nil
        // The changed rows' sort values are read again: they may move.
        invalidateSortKeys(forRows: rowsToRead(forColumns: sortDescriptors.compactMap(\.key).map { sortColumn(forKey: $0).id }))
        // Only the changed rows may pass the filter differently now (a
        // condition may look at any column).
        filterRowsToCheck = rowFilter?.isIncluded == nil ? searchRows : dirty
        if !columnFilters.isEmpty {
            // And the rows whose filtered columns changed.
            let changed = rowsToRead(forColumns: columnFilters.keys)
            filterRowsToCheck?.formUnion(changed)
            columnFilterRowsToCheck.formUnion(changed)
        }
        // Keys kept while not grouped (for grouping again) are read again too.
        let groupRows = rowsToRead(forColumns: rowGrouping?.columnIDs ?? groupKeys?.columnIDs ?? [])
        if sortKeys != nil || backgroundSort != nil { sortRowsToPlace.formUnion(Self.subtracting(rowHandles.removedHandles, from: batch.movedRows)) }
        var display: DisplayRowsChange
        if groupedDisplay != nil, !batch.isStructural {
            display = computeDisplayRows(changedRows: dirty, regroupingRows: groupRows)
            // The groups stayed: their subtotals change by the changed values.
            if display.keptSubtotals, !display.regrouped, summariesAreCached {
                updateGroupCalculators(changedRows: dirty, olds: changedOlds, news: addedValues)
            }
        } else {
            invalidateGroupKeys(forRows: groupRows)
            // Groups kept through the batch keep their subtotals' calculators:
            // they lose their removed and changed rows' values and gain the
            // changed rows' new ones, instead of summing all their rows again.
            let lost = summariesAreCached && groupedDisplay != nil && rowGrouping != nil
                ? groupValuesLost(in: batch, changedRows: dirty, olds: changedOlds) : nil
            display = computeDisplayRows(keepingGroupSubtotals: lost != nil, movedRows: batch.isStructural ? dirty : nil)
            if let lost {
                updateGroupCalculators(losing: lost, changedRows: dirty, news: addedValues)
                display.keptSubtotals = true
            }
        }
        let rowsMoved = batch.isStructural || rowMap != previousRowMap || display.reordered
            || (groupedDisplay != nil && display.regrouped)
        if let keeping {
            keepSelection(keeping)
            anchorRow = batch.anchor.flatMap(displayRow(forSourceRow:))
            cursorRow = batch.cursor.flatMap(displayRow(forSourceRow:))
            if batch.isStructural {
                clickedRow = -1
                dragSelectionBase = []
                rowsMenuDidClose()
            }
        } else if batch.isStructural {
            displaySelection = displayRows(forSourceRows: batch.selection)
            anchorRow = batch.anchor.flatMap(displayRow(forSourceRow:))
            cursorRow = batch.cursor.flatMap(displayRow(forSourceRow:))
            // Indexes the user was acting on no longer mean the same rows.
            clickedRow = -1
            dragSelectionBase = []
            rowsMenuDidClose()
        } else if rowsMoved {
            // Rows the filter now hides leave the selection.
            displaySelection = displayRows(forSourceRows: batch.selection)
            anchorRow = batch.anchor.flatMap(displayRow(forSourceRow:))
            cursorRow = batch.cursor.flatMap(displayRow(forSourceRow:))
        }
        // A selection taken by handle and not kept is in rows again.
        if keeping == nil, displaySelectionIsStale {
            displaySelection = displayRows(forSourceRows: batch.selection)
        }
        // The selection in data source rows, once: with a sort, filter or
        // groups every look at it maps each selected row.
        let selectionChanged: Bool
        if keeping != nil {
            // The same records are selected unless some went.
            selectionChanged = batch.removedSelectedHandles
        } else if batch.tookKeptSelection {
            // (What it was isn't known as rows: told as changed.)
            let selection = selectedRowIndexes
            rememberSelectionIdentity(selection)
            selectionChanged = true
        } else if batch.isStructural || rowsMoved {
            let selection = selectedRowIndexes
            rememberSelectionIdentity(selection)
            selectionChanged = selection != batch.previousSelection
        } else {
            // No row moved: the same display rows are the same records.
            selectionChanged = displaySelection != batch.previousDisplaySelection
            if selectionChanged { rememberSelectionIdentity() }
        }
        phase("filter+selection")

        // The records of the cells in view, as data source rows now (removed: none).
        let visibleSources = rowsMoved ? batch.visibleHandles.compactMapValues { handle -> Int? in
            let row = rowHandles.index(of: handle)
            return row >= 0 ? row : nil
        } : [:]
        // Changed values in view flash (compared before their cells are read again).
        noteChangedValues(ofRows: dirty, columns: batch.dirtyColumns, sources: rowsMoved ? visibleSources : nil)
        // Row elements stand for display rows and read values as they are:
        // only rows that moved make them others.
        if rowsMoved { accessibilityRowCache.removeAll() }
        var changedInView = true
        if rowsMoved {
            NSAccessibility.post(element: self, notification: .rowCountChanged)
            // Cells move with their records instead of being read and drawn
            // again; those of changed, removed or hidden records go.
            let sources = visibleSources
            if batch.animates || (animatesSortMoves && display.reordered) {
                // Moved rows slide, new ones fade in, gone ones fade out (see NGRowAnimation.swift).
                finishRowAnimation()
                var moves: [Int: Int] = [:]
                var gone = Set<Int>()
                for oldRow in Set(visibleCells.keys.map(\.row)) {
                    if let source = sources[oldRow], let new = displayRow(forSourceRow: source) {
                        moves[oldRow] = new
                    } else {
                        gone.insert(oldRow)
                    }
                }
                let disappearing = moveVisibleCells(keeping: gone) { [self] oldRow in
                    guard let source = sources[oldRow], !dirty.contains(handle(ofRow: source)) else { return nil }
                    return moves[oldRow]
                }
                var appearing = Set<Int>()
                let coming = newRows.union(batch.revealedRows)
                if coming.count <= 10_000 {
                    for handle in coming {
                        if let row = displayRow(forSourceRow: row(ofHandle: handle)) { appearing.insert(row) }
                    }
                }
                startRowAnimation(moves: moves, appearing: appearing, disappearing: disappearing,
                                  effect: NGRowAnimation.Effect(batch.animationOptions))
            } else {
                // A running animation's rows mean the old display rows: it ends.
                finishRowAnimation()
                if !batch.selectionSetByCalls, rowsInViewShowTheSameRecords(sources) {
                    keepsVisibleRowsInNextLayout = true
                    _ = placeChangedRowsInViewAgain(dirty, columns: batch.dirtyColumns)
                } else {
                    moveVisibleCells { [self] oldRow in
                        guard let source = sources[oldRow], !dirty.contains(handle(ofRow: source)) else { return nil }
                        return displayRow(forSourceRow: source)
                    }
                }
            }
        } else if !selectionChanged, !display.keptSubtotals, groupedDisplay == nil, !isShowingRowTree, lastVisibleRange != nil {
            // The changed rows in view alone are placed again.
            changedInView = placeChangedRowsInViewAgain(dirty, columns: batch.dirtyColumns)
            if changedInView { keepsVisibleRowsInNextLayout = true }
        } else {
            // Whether a changed row is in view (drawn again: its cells, tint and markers).
            if dirty.count > visibleRows.count {
                changedInView = visibleRows.keys.contains { key in
                    let row = sourceRow(key.row)
                    return row >= 0 && dirty.contains(handle(ofRow: row))
                }
            } else {
                let shown = Set(visibleRows.keys.map(\.row))
                changedInView = dirty.contains { handle in displayRow(forSourceRow: row(ofHandle: handle)).map(shown.contains) ?? false }
            }
            // Only the changed cells read their values again.
            let all = tableColumns
            let ordinals = Set(batch.dirtyColumns.compactMap { $0 >= 0 && $0 < all.count ? columnOrdinal(of: all[$0].id) : nil })
            if dirty.count * ordinals.count > visibleCells.count {
                // Many changed rows (most of them out of view): look at the visible cells instead.
                for key in Array(visibleCells.keys) where ordinals.contains(key.column) {
                    let row = sourceRow(key.row)
                    guard row >= 0, dirty.contains(handle(ofRow: row)), let cell = visibleCells.removeValue(forKey: key) else { continue }
                    recycle(cell)
                }
            } else {
                for handle in dirty {
                    guard let displayRow = displayRow(forSourceRow: row(ofHandle: handle)) else { continue }
                    for ordinal in ordinals {
                        if let cell = visibleCells.removeValue(forKey: NGCellKey(row: displayRow, column: ordinal)) {
                            recycle(cell)
                        }
                    }
                }
            }
            // Group headers show the changed groups' new subtotals.
            if display.keptSubtotals {
                for key in Array(visibleCells.keys) where isGroupRow(key.row) {
                    if let cell = visibleCells.removeValue(forKey: key) { recycle(cell) }
                }
            }
        }

        phase("cells")
        // The totals change by the changed values only; with a filter, by
        // those of the rows it showed and shows (only changed rows can
        // change their match). A new filter or values not read yet need a
        // rebuild.
        let updatedInPlace: Bool
        if treeSummariesCountTopLevel, rowMap != previousRowMap || (rowMap != nil && treeRowsReparented) {
            // Which rows of a filtered tree count changed with the matches,
            // or with the ancestors of re-parented rows.
            updatedInPlace = false
        } else if previousRowMap == nil, rowMap == nil, filterEvaluations == batch.filterEvaluationsAtStart {
            updatedInPlace = summariesAreCached && updateSummaryCalculatorsInPlace(removed: removedValues, added: addedValues)
        } else if previousRowMap != nil, rowMap != nil, let shownBefore, let matches = filterMatches, summariesAreCached,
                  filterEvaluations == batch.filterEvaluationsAtStart, !batch.removedValuesUnfiltered,
                  let changes = Self.filteredChanges(of: Array(dirty), shownBefore: shownBefore, matches: matches,
                                                     removedRows: batch.removedValues, olds: changedOlds, news: addedValues) {
            updatedInPlace = updateSummaryCalculatorsInPlace(removed: changes.removed, added: changes.added, filtered: true)
        } else {
            updatedInPlace = false
        }
        if updatedInPlace {
            // Done.
        } else if summariesAreCached {
            rebuildSummaryCalculators(reusingSourceValues: true)
        } else {
            // A background computation is reading the values (or was while
            // rows moved): instead of starting over (it would never finish
            // under a steady feed), it reads the changed and new rows again
            // when it is done; the values it has read are kept by row handle.
            for handle in dirty { summaryRowsChangedWhileComputing.append(Int32(handle)) }
            if summaryRowsChangedWhileComputing.count > 2 * max(rowHandles.capacity, 1024) {
                summaryRowsChangedWhileComputing = Self.uniqueHandles(summaryRowsChangedWhileComputing, capacity: rowHandles.capacity)
            }
            if summaryTask == nil { rebuildSummaryCalculators(reusingSourceValues: true) }
        }
        // Unchanged groups keep their subtotals (the changed ones were dropped).
        if display.keptSubtotals, summaryTask == nil {
            groupSubtotalsVersion = summaryValuesVersion
        }
        updateSummary()
        // Data bars and color scales of every visible row follow a changed range.
        if !conditionalFormatSummaryKeys.isEmpty { setNeedsMetalFrame() }
        phase("summaries")
        // One layout pass: rows (their tints and markers too), the cells that
        // moved or are missing, and the empty state; none when only rows out
        // of view changed values (a feed's update of one record far below).
        if rowsMoved || changedInView || display.keptSubtotals {
            needsLayout = true
            layoutSubtreeIfNeeded()
            if rowsMoved { headerView.needsDisplay = true }
        }
        // Rows that got or lost children show it (they weren't read again).
        if isShowingRowTree { refreshTreeOutlines() }
        phase("layout")
        if selectionChanged {
            NSAccessibility.post(element: self, notification: .selectedRowsChanged)
            postSelectionNotification(Self.selectionDidChangeNotification)
        }
    }
}
#endif
