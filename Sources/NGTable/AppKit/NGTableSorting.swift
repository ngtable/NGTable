#if os(macOS)
import AppKit
import os

// Live sorting by the table (`sortsRows`): the table orders the rows by its
// `sortDescriptors` itself, as a display layer like the row filter, so row
// indexes in the API stay the data source's. Every row's sort value is read
// once per descriptor key (`tableView(_:sortValueFor:row:)`, the cell value
// by default) and kept by row handle (`NGRowHandles`); `sortedOrder` holds
// the handles of all rows in order as an `NGHandleSequence` (blocks of about
// twice the square root of the rows), so inserts and removes renumber
// nothing. Targeted updates read the changed rows' values again and move
// only the rows whose value changed: each is taken out of its block and put
// back by binary search over the blocks (O(k (√n + log n)) per batch, no pass
// over every row), so a live feed stays sorted at every tick. With a filter,
// `filteredSortedOrder` is the sorted rows it shows, kept the same way;
// `rowMap` (the filtered rows the summaries count) stays in data source
// order, so summaries keep updating in place.


/// A full sort of a large table in the background (`synchronousSortLimit`):
/// every row's values are read on the main actor in slices, then a snapshot
/// of them is sorted off the main thread. Values are kept by row handle, so
/// inserts, removes and moves meanwhile move nothing: new rows are read as
/// well, changed rows again, and once the snapshot is sorted the rows that
/// changed, moved or came since take their place by binary search. So a
/// feed that never pauses doesn't keep the sort from finishing.

/// The values a background sort read, made into `NGSortKeys` off the main thread.
struct NGSortSnapshot: @unchecked Sendable {
    let keys: [String]
    let ascending: [Bool]
    let comparisons: [NGTextComparison]
    let values: [[NGCellValue]]
    let numbers: [(ranks: [UInt8], values: [Double])?]
    let rowCount: Int
}

/// Changed rows of a live sort placed in the background (see
/// `NGTableView.synchronousPlacementLimit`): those waiting for the next
/// round, and while a round runs, the rows gone and come since its snapshot
/// (its order gets them when it's done).
struct NGSortSettle {
    /// Waiting rows by handle, and how many (marks, not an index set: a
    /// union with a set of tens of thousands of scattered rows on every
    /// batch cost a quarter of placing them).
    var pendingMarks: [Bool] = []
    var pendingCount = 0
    var hasPending: Bool { pendingCount > 0 }

    mutating func addPending(_ handles: some Sequence<Int>, capacity: Int) {
        if pendingMarks.count < capacity { pendingMarks.append(contentsOf: repeatElement(false, count: capacity - pendingMarks.count)) }
        pendingMarks.withUnsafeMutableBufferPointer { marks in
            for handle in handles where handle < marks.count && !marks[handle] {
                marks[handle] = true
                pendingCount &+= 1
            }
        }
    }
    var isInFlight = false
    var goneSince: [Int32] = []
    var newSince: [Int32] = []
    /// Bumped when the order is replaced: a round of an older one is dropped.
    var generation = 0
    var lastStart: ContinuousClock.Instant?
}

struct NGBackgroundSort {
    let keys: [String]
    let ascending: [Bool]
    let comparisons: [NGTextComparison]
    let columns: [NGTableColumn]
    /// While reading: each descriptor's value of every row, and which rows
    /// are read (by handle). Made when the first slice reads the descriptor
    /// cell by cell (not for those read as numbers by range).
    var values: [[NGCellValue]]
    /// Descriptors the data source gave numbers for by range
    /// (`sortNumbersFor`): their ranks and numbers by handle instead.
    var numbers: [(ranks: [UInt8], values: [Double])?]
    /// The data source was asked for numbers by range (once per sort).
    var askedForNumbers = false
    /// By handle: rows changed or new since the numbers by range were given
    /// (their numbers are read again with the other descriptors' values;
    /// the others' are as given).
    var numbersStale: [Bool] = []
    var read: [Bool]
    /// Values read before (only the direction changed): sorted at once.
    var reused: NGSortKeys?
    /// Whether the snapshot is taken (reading is done).
    var isSnapshotTaken = false
    /// Rows (handles) to place again when the snapshot is sorted: their
    /// values changed, they moved in the data source, or they came.
    var changed = IndexSet()

    /// - Parameter rowCount: The capacity of handles.
    init(keys: [String], ascending: [Bool], comparisons: [NGTextComparison], columns: [NGTableColumn], rowCount: Int) {
        self.keys = keys
        self.ascending = ascending
        self.comparisons = comparisons
        self.columns = columns
        values = keys.map { _ in [] }
        numbers = keys.map { _ in nil }
        read = [Bool](repeating: false, count: rowCount)
    }

    /// A new row's handle: read with the others, or placed when it's done.
    mutating func prepare(_ handle: Int) {
        guard !isSnapshotTaken else {
            changed.insert(handle)
            return
        }
        if handle >= read.count {
            let added = handle - read.count + 1
            read.append(contentsOf: repeatElement(false, count: added))
            if !numbersStale.isEmpty { numbersStale.append(contentsOf: repeatElement(true, count: added)) }
            for index in values.indices where numbers[index] == nil && !values[index].isEmpty {
                values[index].append(contentsOf: repeatElement(.empty, count: added))
            }
            for index in numbers.indices where numbers[index] != nil {
                numbers[index]!.ranks.append(contentsOf: repeatElement(0, count: added))
                numbers[index]!.values.append(contentsOf: repeatElement(0, count: added))
            }
        }
        read[handle] = false
    }

    /// Rows whose values are read again (or placed again once sorted).
    mutating func invalidate(_ rows: IndexSet) {
        guard !isSnapshotTaken else {
            changed.formUnion(rows)
            return
        }
        for range in rows.rangeView {
            for row in range where row < read.count {
                read[row] = false
                if row < numbersStale.count { numbersStale[row] = true }
            }
        }
    }
}

extension NGTableView {
    /// The descriptors the table sorts by (those with a key).
    private var tableSortDescriptors: [(key: String, ascending: Bool, comparison: NGTextComparison)] {
        sortDescriptors.compactMap { descriptor in descriptor.key.map { ($0, descriptor.ascending, NGTextComparison(descriptor)) } }
    }

    /// The column a descriptor key sorts: the one whose prototype has the key
    /// (hidden ones too: their sort stays), else the column with that id
    /// (shown, hidden or not in the table).
    func sortColumn(forKey key: String) -> NGTableColumn {
        for column in tableColumns where column.sortDescriptorPrototype?.key == key { return column }
        return summaryColumn(key)
    }

    /// What a full sort of `count` rows by these keys costs, counted in rows
    /// of numbers (see `synchronousSortLimit`): comparing text costs about 16
    /// times as much (`localizedStandardCompare`; 49,000 rows took 160 ms
    /// where numbers took 11), so keys with text count 16 a row.
    func sortCost(ofRows count: Int, keys: NGSortKeys?) -> Int {
        guard let keys, !keys.comparesWithoutText else { return count }
        return count.multipliedReportingOverflow(by: 16).partialValue
    }

    /// Whether the table's sort holds the rows in place now (see
    /// `pausesLiveSortUnderPointer`): the pointer is over a row of a window
    /// that shows the table, or a press in the rows hasn't ended.
    var isLiveSortPaused: Bool {
        guard pausesLiveSortUnderPointer, sortsRows, !isApplyingUserEdit else { return false }
        if isPressingRows { return true }
        guard let location = pointerWindowLocation, let window, window.isVisible || pointerLocationForTesting != nil else { return false }
        let point = convert(location, from: nil)
        return bounds.contains(point) && row(at: point) >= 0
    }

    /// The rows held while the sort paused go where they go.
    func resumeLiveSortIfNeeded() {
        guard !isLiveSortPaused, sortSettle.hasPending else { return }
        scheduleSortSettle()
    }

    /// Marks rows (handles) whose sort values are read again (targeted updates).
    func invalidateSortKeys(forRows rows: IndexSet) {
        guard !rows.isEmpty else { return }
        if backgroundSort != nil {
            backgroundSort!.invalidate(rows)
            return
        }
        guard sortKeys != nil else { return }
        sortKeysToRead.formUnion(rows)
    }

    /// Orders the rows for display while the table sorts, and returns
    /// whether the order changed. Called by `computeDisplayRows`, after the
    /// filter: reads the sort values it needs (all of them after a reload or
    /// a new sort key, those of `sortKeysToRead` otherwise). Large tables
    /// sort in the background (`synchronousSortLimit`): the previous order
    /// shows meanwhile. The sorted rows are a blocked sequence: rows whose
    /// values changed, that moved in the data source or that came are taken
    /// out and put back by binary search and rows gone are taken out, and
    /// the rows the filter shows are a second sequence kept the same way, so
    /// a tick costs its changed rows, not the table's.
    func updateDisplayOrder() -> Bool {
        let descriptors = tableSortDescriptors
        // Rows whose match changed since the last time (`nil`: unknown).
        let flipped = filterFlippedRows
        filterFlippedRows = IndexSet()
        guard sortsRows, !descriptors.isEmpty, dataSource != nil else {
            cancelBackgroundSort()
            cancelSortSettle()
            let changed = sortedOrder != nil
            sortKeys = nil
            sortedOrder = nil
            filteredSortedOrder = nil
            sortKeysToRead = []
            sortRowsToPlace = []
            sortRowsInserted = []
            sortOrderNeedsRebuild = false
            sortPlacedInLastUpdate = []
            return changed
        }
        let count = numberOfSourceRows
        let capacity = rowHandles.capacity
        // Looked at once, by whichever way the order is updated below.
        defer { sortRowsInserted = [] }
        let keyNames = descriptors.map(\.key)
        let ascending = descriptors.map(\.ascending)
        // Another comparison of the same keys sorts like other keys (rare).
        let comparisons = descriptors.map(\.comparison)
        let sameKeys = sortKeys?.keys == keyNames && sortKeys?.comparisons == comparisons
        // The rows taken out and put back (`nil`: a new order), and whether any moved.
        var change: (placed: IndexSet?, moved: Bool) = ([], false)
        if let job = backgroundSort, job.keys == keyNames, job.ascending == ascending, job.comparisons == comparisons {
            cancelSortSettle()
            // Sorting in the background: rows changed or moved meanwhile take
            // their place when it's done; the previous order shows, without
            // rows gone and with new rows at the end.
            backgroundSort!.invalidate(sortKeysToRead.union(sortRowsToPlace))
            sortKeysToRead = []
            sortRowsToPlace = []
            if var sorted = sortedOrder.take() {
                change = Self.dropGoneAppendingNew(&sorted, rows: rowHandles, inserted: sortRowsInserted, scansAllRows: &sortScannedAllRows)
                sortedOrder = sorted
            }
        } else if sameKeys, sortKeys?.rowCount == capacity, sortedOrder != nil,
                  !((sortKeys?.ascending != ascending || sortOrderNeedsRebuild) && sortCost(ofRows: count, keys: sortKeys) >= synchronousSortLimit),
                  // Taken out, so changing them doesn't copy them.
                  var keys = sortKeys.take(), var sorted = sortedOrder.take() {
            cancelBackgroundSort()
            change = updateSortedOrder(&sorted, keys: &keys, ascending: ascending)
            sortKeys = keys
            sortedOrder = sorted
        } else if count >= synchronousSortLimit {
            cancelSortSettle()
            // The previous order meanwhile (reversed for the other direction), or the data source's.
            let reusesValues = sameKeys && sortKeys?.rowCount == capacity
            let flippedDirection = sameKeys && sortKeys?.ascending.map(!) == ascending
            let reused = reusesValues ? sortKeys.take() : nil
            if var sorted = sortedOrder.take() {
                _ = Self.dropGoneAppendingNew(&sorted, rows: rowHandles, scansAllRows: &sortScannedAllRows)
                sortedOrder = flippedDirection ? NGHandleSequence.changingOrder(sorted.integerElements.reversed(), capacity: capacity) : sorted
            }
            // (Not sorted before: the data source's order shows meanwhile, without
            // an order of its own: making one of a million rows held the main thread.)
            startBackgroundSort(keys: keyNames, ascending: ascending, comparisons: comparisons, reusing: reused)
            change = (nil, true)
        } else {
            // A reload or other keys: every row's value is read, then sorted.
            cancelBackgroundSort()
            cancelSortSettle()
            let keys = NGSortKeys(keys: keyNames, ascending: ascending, comparisons: comparisons, values: readSortValues(keyNames))
            if sortCost(ofRows: count, keys: keys) >= synchronousSortLimit {
                // Text, which compares slowly: sorted in the background with
                // the values just read, the previous order meanwhile.
                if var sorted = sortedOrder.take() {
                    _ = Self.dropGoneAppendingNew(&sorted, rows: rowHandles, scansAllRows: &sortScannedAllRows)
                    sortedOrder = sorted
                } else {
                    sortedOrder = NGHandleSequence.changingOrder(allRowHandles, capacity: capacity)
                }
                startBackgroundSort(keys: keyNames, ascending: ascending, comparisons: comparisons, reusing: keys)
            } else {
                sortKeys = keys
                sortKeysToRead = []
                sortRowsToPlace = []
                sortOrderNeedsRebuild = false
                sortedOrder = NGHandleSequence.changingOrder(NGRowSort.sortedRows(allRowHandles, keys: keys, order: rowHandles, keyProvider: collationKeyProvider), capacity: capacity)
            }
            change = (nil, true)
        }
        sortPlacedInLastUpdate = change.placed
        // A filtered tree lays out its rows by the whole order (parents the
        // filter shows for context are in it, not in the filtered one).
        return updateFilteredSortedOrder(placed: change.placed, flipped: flipped) || change.moved && (rowMap == nil || isShowingRowTree)
    }

    /// The sorted rows the filter shows, after the sorted rows changed
    /// (`placed`: rows taken out and put back, `nil` for a new order) and
    /// rows changed their match (`flipped`, `nil`: unknown): those rows are
    /// taken out and the ones it shows put back where they are in the
    /// sorted rows, by binary search; otherwise it's built again from them.
    /// Returns whether the shown order changed (always `false` without a filter).
    private func updateFilteredSortedOrder(placed: IndexSet?, flipped: IndexSet?) -> Bool {
        guard rowMap != nil, let matches = filterMatches, let sorted = sortedOrder else {
            filteredSortedOrder = nil
            return false
        }
        if let placed, let flipped, Self.placesFewer(placed.count + flipped.count, than: rowHandles.capacity),
           var shown = filteredSortedOrder.take(), shown.capacity == rowHandles.capacity {
            let moved = Self.place(placed.union(flipped), in: &shown, shownIn: sorted, matches: matches)
            filteredSortedOrder = shown
            return moved
        }
        let rows = Self.matching(sorted.integerElements, matches)
        let previous = filteredSortedOrder?.integerElements
        filteredSortedOrder = NGHandleSequence.changingOrder(rows, capacity: rowHandles.capacity)
        return previous != rows
    }

    /// Reads the changed rows' values and puts the rows whose values changed
    /// (or that are new, or moved in the data source) where they now go;
    /// rows the batch removed leave. Returns those rows (`nil`: all of them,
    /// sorted again) and whether any moved.
    private func updateSortedOrder(_ sorted: inout NGHandleSequence, keys: inout NGSortKeys, ascending: [Bool]) -> (placed: IndexSet?, moved: Bool) {
        guard let dataSource else { return ([], false) }
        // Rows whose values changed, ascending (an index set only if they're placed now).
        var changedHandles: [Int] = []
        if !sortKeysToRead.isEmpty {
            // Each row found once; then column by column (a column's struct
            // copied per row, not per row and column, cost more than reading).
            var handles: [Int] = [], rows: [Int] = []
            for handle in sortKeysToRead where handle < keys.rowCount {
                let row = row(ofHandle: handle)
                guard row >= 0 else { continue }
                handles.append(handle)
                rows.append(row)
            }
            var changed = [Bool](repeating: false, count: handles.count)
            var numbers: [Double] = []
            for (index, key) in keys.keys.enumerated() {
                let column = sortColumn(forKey: key)
                // Numbers given at once, when the data source can.
                if keys.isNumeric(index) {
                    // (The buffer starts as NaN for each column.)
                    numbers = [Double](repeating: .nan, count: rows.count)
                    let given = rows.withUnsafeBufferPointer { rows in
                        numbers.withUnsafeMutableBufferPointer { dataSource.tableView(self, sortNumbersFor: column, atRows: rows, into: $0) }
                    }
                    if given {
                        numbers.withUnsafeBufferPointer { keys.setNumbers(at: index, handles: handles, $0, changed: &changed) }
                        continue
                    }
                }
                for position in handles.indices {
                    let value = dataSource.tableView(self, sortValueFor: column, row: rows[position])
                    if keys.set(value, at: index, row: handles[position]) { changed[position] = true }
                }
            }
            for position in handles.indices where changed[position] { changedHandles.append(handles[position]) }
        }
        sortKeysToRead = []
        let movedRows = NGTableView.live(sortRowsToPlace, in: rowHandles)
        sortRowsToPlace = []
        if keys.ascending != ascending || sortOrderNeedsRebuild {
            cancelSortSettle()
            keys.ascending = ascending
            sortOrderNeedsRebuild = false
            sorted = NGHandleSequence.changingOrder(NGRowSort.sortedRows(allRowHandles, keys: keys, order: rowHandles, keyProvider: collationKeyProvider), capacity: rowHandles.capacity)
            return (nil, true)
        }
        let gone = rowHandles.removedHandles
        let movingCount = changedHandles.count &+ movedRows.count
        guard movingCount > 0 || !gone.isEmpty || sorted.count != numberOfSourceRows else { return ([], false) }
        sorted.reserve(capacity: rowHandles.capacity)
        // Too many to place now (or some wait already): they keep their
        // places, rows gone leave and new ones go to the end, and a round in
        // the background puts them where they go.
        let cost = movingCount &* max(1, Int(log2(Double(max(2, numberOfSourceRows)))))
        // Held under the pointer too (see `pausesLiveSortUnderPointer`).
        if isSettlingSort || isLiveSortPaused || (numberOfSourceRows >= synchronousSortLimit && cost > synchronousPlacementLimit) {
            if sortSettle.isInFlight {
                sortSettle.goneSince.append(contentsOf: gone)
                sortSettle.newSince.append(contentsOf: sortRowsInserted)
            }
            let change = Self.dropGoneAppendingNew(&sorted, rows: rowHandles, inserted: sortRowsInserted, scansAllRows: &sortScannedAllRows)
            sortSettle.addPending(changedHandles, capacity: rowHandles.capacity)
            sortSettle.addPending(movedRows, capacity: rowHandles.capacity)
            scheduleSortSettle()
            return change
        }
        var moving = NGTableView.merged([], sortedHandles: changedHandles.map { Int32(truncatingIfNeeded: $0) })
        moving.formUnion(movedRows)
        return Self.place(moving, removing: gone, in: &sorted, keys: keys, rows: rowHandles)
    }

    /// Starts a round placing the waiting rows, unless one runs: off the main
    /// thread, from a snapshot of the order and the sort values (which are
    /// read already), at most every 50 ms.
    func scheduleSortSettle() {
        // Held under the pointer: placed when it leaves (`resumeLiveSortIfNeeded`).
        guard !sortSettle.isInFlight, sortSettle.hasPending, !isLiveSortPaused else { return }
        sortSettle.isInFlight = true
        let generation = sortSettle.generation
        let wait = sortSettle.lastStart.map { max(.zero, .milliseconds(50) - $0.duration(to: .now)) } ?? .zero
        Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            // The snapshot between batches (an open one is finished first).
            while self?.rowUpdateDepth ?? 0 > 0 { try? await Task.sleep(for: .milliseconds(2)) }
            guard let table = self, table.sortSettle.generation == generation,
                  let order = table.sortedOrder, let keys = table.sortKeys else { return }
            let marks = table.sortSettle.pendingMarks
            table.sortSettle.pendingMarks = []
            table.sortSettle.pendingCount = 0
            table.sortSettle.goneSince = []
            table.sortSettle.newSince = []
            table.sortSettle.lastStart = .now
            let rows = table.rowHandles
            let settled = await Task.detached(priority: .userInitiated) {
                var order = order
                order.reserve(capacity: rows.capacity)
                _ = NGTableView.placeMany(NGTableView.runs(of: marks), removing: [], in: &order, keys: keys, rows: rows)
                return order
            }.value
            while table.rowUpdateDepth > 0 { try? await Task.sleep(for: .milliseconds(2)) }
            guard table.sortSettle.generation == generation else { return }
            // Begun before the pointer came over the rows: it waits for it to leave.
            while self?.isLiveSortPaused == true { try? await Task.sleep(for: .milliseconds(30)) }
            // Placed in a turn of the run loop of its own.
            await NGBackgroundSlices.turnOfItsOwn()
            while self?.rowUpdateDepth ?? 0 > 0 { try? await Task.sleep(for: .milliseconds(2)) }
            guard let table = self, table.sortSettle.generation == generation else { return }
            table.finishSortSettle(settled)
        }
    }

    /// A round's order goes in, without the rows gone since its snapshot and
    /// with the rows come since at the end (those wait for the next round).
    private func finishSortSettle(_ settled: NGHandleSequence) {
        sortSettle.isInFlight = false
        var result = settled
        result.reserve(capacity: rowHandles.capacity)
        for handle in sortSettle.goneSince where !rowHandles.contains(handle) { result.remove(handle) }
        for handle in sortSettle.newSince where rowHandles.contains(handle) && !result.contains(handle) {
            result.insert(handle, at: result.count)
        }
        sortSettle.goneSince = []
        sortSettle.newSince = []
        if result.count != rowHandles.count {
            _ = Self.dropGoneAppendingNew(&result, rows: rowHandles, scansAllRows: &sortScannedAllRows)
        }
        // The records show the same: their cells move with them.
        updateDisplayedRows(rebuildingSummaries: false, keepingCells: true) {
            sortedOrder = result
            filteredSortedOrder = nil
            computeDisplayRows()
        }
        scheduleSortSettle()
    }

    /// The order is replaced: waiting rows are in it, a running round's result is dropped.
    func cancelSortSettle() {
        guard sortSettle.isInFlight || sortSettle.hasPending else { return }
        let generation = sortSettle.generation &+ 1
        sortSettle = NGSortSettle()
        sortSettle.generation = generation
    }

    /// Every row's sort values by handle.
    private func readSortValues(_ keyNames: [String]) -> [[NGCellValue]] {
        guard let dataSource else { return [] }
        let handles = allRowHandles
        var result: [[NGCellValue]] = []
        for column in keyNames.map(sortColumn(forKey:)) {
            var values = [NGCellValue](repeating: .empty, count: rowHandles.capacity)
            for (row, handle) in handles.enumerated() {
                values[handle] = dataSource.tableView(self, sortValueFor: column, row: row)
            }
            result.append(values)
        }
        return result
    }

    // MARK: Background sorting

    /// Reads the sort values on the main actor (the data source lives there)
    /// in slices of a few milliseconds, giving the run loop a turn in between,
    /// then sorts a snapshot of them off the main thread, like large
    /// summaries. Targeted updates meanwhile, inserts and removes too, read
    /// again or place again what they change (see `NGBackgroundSort`);
    /// reloads and other sorts start it over.
    private func startBackgroundSort(keys keyNames: [String], ascending: [Bool], comparisons: [NGTextComparison],
                                     reusing reused: NGSortKeys?) {
        cancelBackgroundSort()
        sortGeneration += 1
        let generation = sortGeneration
        var job = NGBackgroundSort(keys: keyNames, ascending: ascending, comparisons: comparisons, columns: keyNames.map(sortColumn(forKey:)),
                                   rowCount: reused == nil ? rowHandles.capacity : 0)
        if var reused {
            reused.ascending = ascending
            job.reused = reused
            job.isSnapshotTaken = true
            // Rows marked to be read again since: they take their place at the end.
            job.changed = sortKeysToRead.union(sortRowsToPlace)
        }
        backgroundSort = job
        sortKeysToRead = []
        sortRowsToPlace = []
        sortOrderNeedsRebuild = false
        sortKeys = nil
        isSortingRows = true
        sortTask = Task { [weak self] in
            // Reading, until every row (also the ones that came meanwhile) is read.
            while true {
                await NGBackgroundSlices.nextSlice()
                guard !Task.isCancelled, let table = self, table.sortGeneration == generation else { return }
                guard let done = table.readBackgroundSortSlice() else {
                    // The data changed without telling the table: the reload starts over.
                    table.cancelBackgroundSort()
                    return
                }
                if done { break }
            }
            // The snapshot sorts by the job's directions (set when it was made),
            // ties in the data source's order of the moment.
            // The values read are taken as they are; the keys (numbers found
            // among them) are made off the main thread too.
            // Taken without holding the table across the sort and the wait
            // below (it may go meanwhile).
            let taken = self.flatMap { table -> (reused: NGSortKeys?, read: NGSortSnapshot?, rows: [Int], order: NGRowHandles,
                                                 rowsMoved: Int, keyProvider: (any NGCollationKeyProvider)?)? in
                let reused = table.backgroundSort?.reused
                let read = reused == nil ? table.backgroundSortValues() : nil
                guard reused != nil || read != nil else { return nil }
                return (reused, read, table.allRowHandles, table.rowHandles, table.summaryRowsMoved, table.collationKeyProvider)
            }
            guard let (reused, read, rows, order, rowsMoved, keyProvider) = taken else { return }
            // The order as the table keeps it is built there too (scattered
            // writes over every row, kept off the main thread).
            // Another sort or a reload cancels this one: the cores stop
            // comparing at once instead of finishing a sort no one waits for.
            let cancellation = NGSortCancellation()
            let job = Task.detached(priority: .userInitiated) {
                let snapshot = reused ?? NGSortKeys(keys: read!.keys, ascending: read!.ascending, comparisons: read!.comparisons, values: read!.values,
                                                    numbers: read!.numbers, rowCount: read!.rowCount)
                // Rows inserted after the snapshot was taken (a reused one is
                // taken before this task runs) have no values in it: they are
                // among the job's changed rows and are placed afterwards.
                let rows = order.capacity > snapshot.rowCount ? rows.filter { $0 < snapshot.rowCount } : rows
                let sorted = NGRowSort.sortedRows(rows, keys: snapshot, order: order, keyProvider: keyProvider, cancellation: cancellation)
                return (sorted, snapshot, cancellation.isCancelled ? NGHandleSequence() : NGHandleSequence.changingOrder(sorted, capacity: order.capacity))
            }
            let sorted = await withTaskCancellationHandler {
                await job.value
            } onCancel: {
                cancellation.cancel()
                job.cancel()
            }
            guard !cancellation.isCancelled else { return }
            // Laid out in a turn of the run loop of its own.
            await NGBackgroundSlices.turnOfItsOwn()
            // An open batch (one can span an `await`) finishes it at its end.
            while self.map({ $0.sortGeneration == generation && $0.rowUpdateBatch?.displayIsStale == true }) == true {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard let table = self, !Task.isCancelled, table.sortGeneration == generation else { return }
            // Rows inserted or removed meanwhile: the order is built again without the gone ones.
            table.finishBackgroundSort(sorted.0, keys: sorted.1, built: table.summaryRowsMoved == rowsMoved ? sorted.2 : nil)
        }
    }

    /// Reads values of rows not read yet for a few milliseconds; whether
    /// all are read (`nil`: the data source has other rows than the table).
    func readBackgroundSortSlice() -> Bool? {
        guard var job = backgroundSort.take() else { return true }
        defer { backgroundSort = job }
        guard !job.isSnapshotTaken else { return true }
        guard let dataSource, rowUpdateBatch != nil || dataSource.numberOfRows(in: self) == numberOfSourceRows else { return nil }
        let capacity = job.read.count
        let deadline = NGBackgroundSlices.deadline()
        // Numbers by range first, while handles are the row indexes: a call
        // per descriptor instead of one per row.
        if !job.askedForNumbers, rowHandles.isIdentity, rowUpdateDepth == 0 {
            job.askedForNumbers = true
            readSortNumbers(into: &job, dataSource: dataSource)
        }
        let byCell = job.columns.indices.filter { job.numbers[$0] == nil }
        // Room for every row's value, filled as rows are read (in order of
        // their handles: appended): filling a million values up front held
        // the main thread for a slice's two or three times.
        for index in byCell where job.values[index].capacity < capacity {
            job.values[index].reserveCapacity(capacity)
        }
        // By handle; rows changed or inserted since were marked unread.
        var next = job.read.firstIndex(of: false) ?? capacity
        while next < capacity, ContinuousClock.now < deadline {
            let end = min(capacity, next + 256)
            for handle in next..<end where !job.read[handle] {
                let row = row(ofHandle: handle)
                if row >= 0 {
                    for index in byCell {
                        let value = dataSource.tableView(self, sortValueFor: job.columns[index], row: row)
                        if handle < job.values[index].count {
                            job.values[index][handle] = value
                        } else {
                            // Handles not read before (gone rows') stay empty.
                            if handle > job.values[index].count {
                                job.values[index].append(contentsOf: repeatElement(.empty, count: handle - job.values[index].count))
                            }
                            job.values[index].append(value)
                        }
                    }
                    // Rows read again (changed meanwhile) in descriptors read as numbers.
                    let numbersStale = handle >= job.numbersStale.count || job.numbersStale[handle]
                    for index in job.columns.indices where numbersStale && job.numbers[index] != nil {
                        let ranked = NGSortKeys.rank(of: dataSource.tableView(self, sortValueFor: job.columns[index], row: row)) ?? (2, 0)
                        job.numbers[index]!.ranks[handle] = ranked.rank
                        job.numbers[index]!.values[handle] = ranked.value
                    }
                }
                job.read[handle] = true
            }
            next = end
        }
        guard next >= capacity, job.read.firstIndex(of: false) == nil else { return false }
        // Every handle has a value (the last ones gone may not have been appended).
        for index in byCell where job.values[index].count < capacity {
            job.values[index].append(contentsOf: repeatElement(.empty, count: capacity - job.values[index].count))
        }
        job.isSnapshotTaken = true
        return true
    }

    /// Asks the data source for each descriptor's numbers of all rows
    /// (`sortNumbersFor`); those it gives are read: every row's is marked
    /// read when all descriptors are.
    private func readSortNumbers(into job: inout NGBackgroundSort, dataSource: NGTableViewDataSource) {
        let rowCount = numberOfSourceRows
        let capacity = job.read.count
        guard rowCount > 0, rowCount <= capacity else { return }
        var numbers = [Double](repeating: .nan, count: rowCount)
        for index in job.columns.indices {
            // A source may have written some numbers and then returned false.
            if index > 0 { numbers.withUnsafeMutableBufferPointer { $0.update(repeating: .nan) } }
            let given = numbers.withUnsafeMutableBufferPointer {
                dataSource.tableView(self, sortNumbersFor: job.columns[index], rows: 0..<rowCount, into: $0)
            }
            guard given else { continue }
            var ranks = [UInt8](repeating: 0, count: capacity)
            var values = [Double](repeating: 0, count: capacity)
            for row in 0..<rowCount where !numbers[row].isNaN {
                ranks[row] = 1
                values[row] = numbers[row]
            }
            job.numbers[index] = (ranks, values)
            job.values[index] = []
        }
        // The numbers given are the rows' as they are now.
        if job.numbers.contains(where: { $0 != nil }) { job.numbersStale = [Bool](repeating: false, count: capacity) }
        // Every descriptor read: the rows not marked unread since are read.
        if job.numbers.allSatisfy({ $0 != nil }) {
            for row in 0..<rowCount { job.read[row] = true }
        }
    }

    /// The values read, for sorting a snapshot of them (the job notes the
    /// rows that change from here on): moved out of the job, not copied.
    private func backgroundSortValues() -> NGSortSnapshot? {
        guard var job = backgroundSort.take() else { return nil }
        let values = job.values
        let numbers = job.numbers
        let rowCount = job.read.count
        job.values = []
        job.numbers = job.numbers.map { _ in nil }
        job.read = []
        backgroundSort = job
        return NGSortSnapshot(keys: job.keys, ascending: job.ascending, comparisons: job.comparisons, values: values, numbers: numbers,
                              rowCount: rowCount)
    }

    /// The sorted snapshot: rows that came, changed or moved since take
    /// their place, and the table sorts by the new order.
    private func finishBackgroundSort(_ sorted: [Int], keys snapshotKeys: NGSortKeys, built: NGHandleSequence? = nil) {
        guard let job = backgroundSort.take() else { return }
        cancelSortSettle()
        var keys = snapshotKeys
        // Handles that came since have empty values until read.
        if keys.rowCount < rowHandles.capacity { keys.prepare(rowHandles.capacity - 1) }
        // Rows gone since are left out; those changed or moved in the data
        // source take their place again even if their values are the same
        // (among equal values the data source's order decides), and rows
        // that came are put in.
        var result = built.flatMap { $0.capacity == rowHandles.capacity ? $0 : nil }
            ?? NGHandleSequence.changingOrder(sorted.filter { rowHandles.contains(Int32(truncatingIfNeeded: $0)) }, capacity: rowHandles.capacity)
        sortKeysToRead = job.changed
        sortRowsToPlace = job.changed
        _ = updateSortedOrder(&result, keys: &keys, ascending: job.ascending)
        sortTask = nil
        isSortingRows = false
        // The new order goes in once the selection was taken by data source
        // row: display rows mean the old order until then.
        updateDisplayedRows(rebuildingSummaries: false) {
            sortKeys = keys
            sortedOrder = result
            // The shown rows are taken from the new order.
            filteredSortedOrder = nil
            computeDisplayRows()
        }
    }

    /// Stops a background sort (the next display update sorts again if needed).
    func cancelBackgroundSort() {
        guard sortTask != nil || backgroundSort != nil else { return }
        sortTask?.cancel()
        sortTask = nil
        sortGeneration += 1
        backgroundSort = nil
        isSortingRows = false
    }

    // MARK: Helpers off the main actor

    /// `array[sources[i]]` for every `i` (`placeholder` for -1).
    nonisolated static func gathered<Element>(_ array: [Element], at sources: [Int], placeholder: Element) -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(sources.count)
        for source in sources {
            result.append(source >= 0 && source < array.count ? array[source] : placeholder)
        }
        return result
    }

    /// A previous order for the meantime: rows gone left out (those the
    /// batch removed, or any after a release), new rows at the end.
    /// `inserted`: rows inserted since (their handles), looked at first: a
    /// feed's batches during a long background sort (a million rows) went
    /// through every row for the few new ones.
    private nonisolated static func dropGoneAppendingNew(_ sorted: inout NGHandleSequence, rows: NGRowHandles,
                                                         inserted: [Int32] = [], scansAllRows: inout Bool) -> (placed: IndexSet?, moved: Bool) {
        var placed = IndexSet()
        sorted.reserve(capacity: rows.capacity)
        for handle in rows.removedHandles where sorted.remove(handle) { placed.insert(Int(handle)) }
        if sorted.count > rows.count {
            // Handles released before they left: built again from the rows.
            sorted = NGHandleSequence.changingOrder(sorted.integerElements.filter { rows.contains(Int32(truncatingIfNeeded: $0)) }, capacity: rows.capacity)
            return (nil, true)
        }
        for handle in inserted where sorted.count < rows.count && rows.contains(handle) && !sorted.contains(handle) {
            sorted.insert(handle, at: sorted.count)
            placed.insert(Int(handle))
        }
        if sorted.count < rows.count {
            scansAllRows = true
            for handle in rows.handles where !sorted.contains(handle) {
                sorted.insert(handle, at: sorted.count)
                placed.insert(Int(handle))
            }
        }
        return (placed, !placed.isEmpty)
    }

    /// The sorted rows with `moving` rows taken out and put back where their
    /// values now go, by binary search over the blocks, and the rows gone
    /// taken out; new rows that weren't marked are found and put in too.
    /// Returns the rows taken out or put in, and whether any row's position
    /// changed. Nonisolated, like `sortedRows(_:keys:order:)`: closures made
    /// in the table's (main actor) methods check the executor on every
    /// call, which cost more than the comparisons.
    private nonisolated static func place(_ moving: IndexSet, removing gone: [Int32], in sorted: inout NGHandleSequence,
                                          keys: NGSortKeys, rows: NGRowHandles) -> (placed: IndexSet?, moved: Bool) {
        // Many rows: taken out in one pass, sorted among themselves and merged
        // in (placing each by itself costs a search and a block shift per
        // row; both are bound by reading the keys at random, about 3 µs a row
        // in a million, so this wins from several thousand rows on).
        if moving.count >= 8_192 {
            return placeMany(moving, removing: gone, in: &sorted, keys: keys, rows: rows)
        }
        var placed = moving
        var moved = false
        // Where the moving rows were, before any of them is taken out.
        var placing: [(handle: Int32, was: Int)] = []
        placing.reserveCapacity(moving.count)
        for handle in moving {
            let key = Int32(truncatingIfNeeded: handle)
            let was = sorted.index(of: key)
            if rows.contains(key) {
                placing.append((key, was))
                if was < 0 { moved = true }
            } else if was >= 0 {
                moved = true
            }
        }
        for handle in gone where sorted.remove(handle) {
            placed.insert(Int(handle))
            moved = true
        }
        for handle in moving { sorted.remove(Int32(truncatingIfNeeded: handle)) }
        if sorted.count + placing.count != rows.count {
            // Rows not marked (or handles released before they left): found in one pass.
            if sorted.count + placing.count > rows.count {
                sorted = NGHandleSequence.changingOrder(sorted.integerElements.filter { rows.contains(Int32(truncatingIfNeeded: $0)) }, capacity: rows.capacity)
            }
            let marked = Set(placing.map(\.handle))
            for handle in rows.handles where !sorted.contains(handle) && !marked.contains(handle) {
                placing.append((handle, -1))
                placed.insert(Int(handle))
            }
            moved = true
        }
        for (handle, _) in placing {
            // The first row this one comes before (equal values in data source order).
            var index = -1
            let comesBefore = { (other: Int32) -> Bool in
                if let order = keys.keyOrder(Int(handle), Int(other)) { return order }
                if index < 0 { index = rows.index(of: handle) }
                return index < rows.index(of: other)
            }
            sorted.insert(handle, at: sorted.partitioningIndex(where: comesBefore))
        }
        if !moved {
            for (handle, was) in placing where sorted.index(of: handle) != was {
                moved = true
                break
            }
        }
        return (placed, moved)
    }

    /// `place` for many rows at once: the other rows in one pass, the
    /// moving ones sorted, each one's place among the others found by binary
    /// search, and the order built again in one pass.
    nonisolated static func placeMany(_ moving: IndexSet, removing gone: [Int32], in sorted: inout NGHandleSequence,
                                              keys: NGSortKeys, rows: NGRowHandles) -> (placed: IndexSet?, moved: Bool) {
        let capacity = rows.capacity
        // Rows that stay where they are: in the order, still a row, not moving.
        var leaving = [Bool](repeating: false, count: capacity)
        for handle in moving where handle < capacity { leaving[handle] = true }
        var placed = moving
        for handle in gone where Int(handle) < capacity {
            leaving[Int(handle)] = true
            placed.insert(Int(handle))
        }
        // By handle, 0 for a row's handle (one sequential pass, not a lookup per row).
        let states = rows.states(unused: 1)
        var inOrder = [Bool](repeating: false, count: capacity)
        var staying: [Int] = []
        staying.reserveCapacity(sorted.count)
        let previous = sorted.integerElements
        for handle in previous where handle < capacity {
            inOrder[handle] = true
            if !leaving[handle], states[handle] == 0 { staying.append(handle) }
        }
        // The rows to put in: the moving ones, and rows not in the order yet.
        var placing = moving.filter { $0 < capacity && states[$0] == 0 }
        for handle in 0..<capacity where states[handle] == 0 && !inOrder[handle] && !leaving[handle] {
            placing.append(handle)
            placed.insert(handle)
        }
        // Before: by the sort values, equal values in data source order.
        func comesBefore(_ a: Int, _ b: Int) -> Bool {
            keys.keyOrder(a, b) ?? (rows.index(of: Int32(truncatingIfNeeded: a)) < rows.index(of: Int32(truncatingIfNeeded: b)))
        }
        placing.sort(by: comesBefore)
        var result: [Int] = []
        result.reserveCapacity(staying.count + placing.count)
        var next = 0
        for handle in placing {
            // The first staying row it comes before (after the previous one's place).
            var low = next, high = staying.count
            while low < high {
                let middle = (low + high) / 2
                if comesBefore(handle, staying[middle]) { high = middle } else { low = middle + 1 }
            }
            result.append(contentsOf: staying[next..<low])
            result.append(handle)
            next = low
        }
        result.append(contentsOf: staying[next...])
        sorted = NGHandleSequence.changingOrder(result, capacity: capacity)
        return (placed, result != previous)
    }

    /// The shown sorted rows with `candidates` taken out and those the
    /// filter shows (`matches`) put back where they are in `order` (all
    /// sorted rows, of which `shown` is a part), by binary search. Returns
    /// whether the shown order changed.
    private nonisolated static func place(_ candidates: IndexSet, in shown: inout NGHandleSequence, shownIn order: NGHandleSequence,
                                          matches: [Bool]) -> Bool {
        var placing: [(handle: Int32, was: Int)] = []
        var moved = false
        // Where they were, before any of them is taken out.
        for handle in candidates {
            let key = Int32(truncatingIfNeeded: handle)
            let was = shown.index(of: key)
            let shows = handle < matches.count && matches[handle] && order.contains(key)
            if shows {
                placing.append((key, was))
                if was < 0 { moved = true }
            } else if was >= 0 {
                moved = true
            }
        }
        for handle in candidates { shown.remove(Int32(truncatingIfNeeded: handle)) }
        for (handle, _) in placing {
            let index = order.index(of: handle)
            let position = shown.partitioningIndex { order.index(of: $0) > index }
            shown.insert(handle, at: position)
        }
        if !moved {
            for (handle, was) in placing where shown.index(of: handle) != was {
                moved = true
                break
            }
        }
        return moved
    }

    /// The table sorts again by the current descriptors (they changed, or
    /// `sortsRows` was turned on).
    func applyTableSort() {
        updateDisplayedRows(rebuildingSummaries: false) { computeDisplayRows() }
    }
}
#endif
