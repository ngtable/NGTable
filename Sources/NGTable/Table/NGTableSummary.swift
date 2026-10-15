#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Sorting by header clicks, and the summary row: calculators for the
// summarized columns (computed in the background for large tables, updated
// incrementally for targeted updates), the scope menu and the displayed texts.

/// The values a background summary computation reads (see
/// `computeSummaryCalculatorsInBackground`): the columns left, and the one
/// being read by row handle, with which handles are read. Kept by handle,
/// so inserts and removes meanwhile don't start it over (new rows are read
/// like the others).
struct NGSummaryBuild {
    var columns: [NGTableColumn]
    var values: [Double]
    var read: [Bool]

    /// - Parameter rowCount: The capacity of handles.
    init(columns: [NGTableColumn], rowCount: Int) {
        self.columns = columns
        values = [Double](repeating: .nan, count: rowCount)
        read = [Bool](repeating: false, count: rowCount)
    }
}

extension NGTableView {
    // MARK: Sorting

    /// Where a column is in `sortDescriptors` (0: the first), and its direction.
    func sortPosition(ofColumn column: NGTableColumn) -> (index: Int, ascending: Bool)? {
        guard let key = column.sortDescriptorPrototype?.key,
              let index = sortDescriptors.firstIndex(where: { $0.key == key }) else { return nil }
        return (index, sortDescriptors[index].ascending)
    }

    /// Sorts as a click on the header of a sortable column does.
    func sortByClicking(_ column: NGTableColumn) {
        guard let prototype = column.sortDescriptorPrototype else { return }
        // Reversed by the user's last click (and not changed since): this click removes it.
        let reversedByUser = sortReversedByUser == sortDescriptors && sortDescriptors.first?.key == prototype.key
        let new = NGSorting.descriptors(afterClicking: prototype, current: sortDescriptors, reversedByUser: reversedByUser)
        let reverses = new.first?.key == prototype.key && sortDescriptors.first?.key == prototype.key
        isSortingByClick = true
        sortDescriptors = new
        isSortingByClick = false
        sortReversedByUser = reverses ? new : nil
    }

    // MARK: Summary

    /// - Parameter computingInBackground: Whether calculators built from
    ///   values already read may be built in the background when there are
    ///   many (a filter or a search keystroke over a million rows): for what
    ///   the user did, not for batches (a feed would never let it finish).
    func rebuildSummaryCalculators(reusingSourceValues: Bool = false, computingInBackground: Bool = false) {
        // A filtered tree counting its top level: which rows count depends on
        // the matches, so the values are read (and masked) again.
        let reusingSourceValues = reusingSourceValues && !(treeSummariesCountTopLevel && (rowMap != nil || treeSummaryMasksWereFiltered))
        if !reusingSourceValues {
            // New data: values read before are no longer valid.
            summarySourceValues = [:]
            summaryRowsChangedWhileComputing = []
            summaryDataGeneration += 1
        }
        computeSummaryCalculators(for: neededSummaryKeys(), replacingAll: true, computingInBackground: computingInBackground)
    }



    /// Values the summary row needs: each column's own values (filtered as its
    /// aggregate asks) and the inputs of formulas.
    private func neededSummaryKeys() -> Set<SummaryKey> {
        var keys = Set<SummaryKey>()
        for column in columnLayout.allColumns {
            switch column.summary {
            case .none:
                break
            case .aggregate(_, let filter):
                keys.insert(SummaryKey(columnID: column.id, filter: filter))
            case .formula(let formula):
                for input in formula.inputs {
                    keys.insert(SummaryKey(columnID: input, filter: .all))
                }
                if formula.fallback != nil {
                    keys.insert(SummaryKey(columnID: column.id, filter: formula.fallbackFilter))
                }
            }
        }
        // Conditional formats' automatic ranges (min and max of the rows shown).
        return keys.union(conditionalFormatSummaryKeys)
    }

    func addMissingSummaryCalculators() {
        // During a background computation the current calculators are about to
        // be replaced, so their keys say nothing: rebuild with every needed key.
        if summaryTask != nil {
            computeSummaryCalculators(for: neededSummaryKeys(), replacingAll: true)
            return
        }
        let missing = neededSummaryKeys().filter { summaryCalculators[$0] == nil }
        guard !missing.isEmpty else { return }
        computeSummaryCalculators(for: missing, replacingAll: false)
    }

    /// Builds the calculators for `keys`, right away when few values have to be
    /// read from the data source, otherwise in the background.
    private func computeSummaryCalculators(for keys: Set<SummaryKey>, replacingAll: Bool, computingInBackground: Bool = false) {
        // The calculators count the filtered rows as they are now.
        updateRowMapAfterMoves()
        // While a background computation runs, the current calculators belong to
        // older data or rows: anything new is a full rebuild. So is anything new
        // after an open batch removed rows: new calculators leave them out, the
        // others still have to take them away at the end of the batch.
        let batchRemovedRows = rowUpdateBatch?.removedValues.isEmpty == false || rowUpdateBatch?.removedValuesUnfiltered == true
        let isFull = replacingAll || summaryTask != nil || batchRemovedRows
        let keys = isFull ? neededSummaryKeys() : keys
        let columnsToRead = Set(keys.map(\.columnID)).filter { summarySourceValues[$0] == nil }
        let computesInBackground = computingInBackground && rowUpdateDepth == 0
            && keys.count * summaryRows.count > synchronousSummaryComputeLimit
        guard columnsToRead.count * numberOfSourceRows > synchronousSummaryLimit || computesInBackground else {
            if cancelSummaryComputation() {
                // Whoever waited for the background result hears about this one.
                notifiesSummaryUpdate = true
            }
            if isFull {
                summaryCalculators = [:]
            }
            // Columns a stopped background computation had read may hold old
            // values of rows that changed meanwhile.
            rereadRowsChangedWhileComputing()
            readSourceValues(of: columnsToRead)
            if let newRows = rowUpdateBatch?.newRows, !newRows.isEmpty { clearSummaryValues(ofNewRows: newRows) }
            let rows = summaryRows
            for key in keys {
                summaryCalculators[key] = makeSummaryCalculator(for: key, source: summarySourceValues[key.columnID] ?? [], rowMap: rows)
            }
            if isFull, rowUpdateDepth > 0 {
                // In the middle of a batch: the calculators cover the rows as
                // they are now (the filter's too, with the changed rows' old
                // values), so the end of the batch continues from them.
                rowUpdateBatch!.removedValues = [:]
                rowUpdateBatch!.removedValuesUnfiltered = false
                rowUpdateBatch!.filterEvaluationsAtStart = filterEvaluations
                // The groups' calculators weren't rebuilt: they can't follow the batch.
                rowUpdateBatch!.removedLeaves = []
                rowUpdateBatch!.groupLeavesAreUnknown = true
            }
            summaryValuesVersion += 1
            return
        }
        computeSummaryCalculatorsInBackground(for: keys, reading: columnsToRead)
    }

    /// The data source column for a summary input (defined, hidden or not in the table).
    func summaryColumn(_ columnID: String) -> NGTableColumn {
        // By id (a search of the columns copied each one it passed, for every
        // summarized column of every batch).
        columnLayout.columnsByID[columnID] ?? tableColumns.first { $0.id == columnID } ?? NGTableColumn(columnID, title: columnID)
    }

    func readSourceValues(of columnIDs: Set<String>) {
        guard let dataSource else { return }
        let handles = allRowHandles
        for columnID in columnIDs {
            let column = summaryColumn(columnID)
            // All data source rows by handle, read once per reload; the filter
            // only picks from them. Loops, not a closure per row.
            var values = [Double](repeating: .nan, count: rowHandles.capacity)
            if !readNumbers(of: column, rows: 0..<handles.count, byHandle: handles, into: &values) {
                for (row, handle) in handles.enumerated() {
                    values[handle] = dataSource.tableView(self, valueFor: column, row: row).summaryNumber ?? .nan
                }
            }
            maskTreeSummaryValues(&values)
            summarySourceValues[columnID] = values
        }
    }

    /// Numbers of rows in one call to the data source
    /// (`tableView(_:numbersFor:rows:into:)`), stored by handle: in place
    /// while handles are the row indexes, else scattered. `false` if the data
    /// source doesn't give them.
    func readNumbers(of column: NGTableColumn, rows: Range<Int>, byHandle handles: [Int], into values: inout [Double]) -> Bool {
        guard let dataSource, !rows.isEmpty else { return false }
        if rowHandles.isIdentity, rows.upperBound <= values.count {
            return values.withUnsafeMutableBufferPointer { buffer in
                dataSource.tableView(self, numbersFor: column, rows: rows, into: UnsafeMutableBufferPointer(rebasing: buffer[rows]))
            }
        }
        var numbers = [Double](repeating: .nan, count: rows.count)
        let given = numbers.withUnsafeMutableBufferPointer { dataSource.tableView(self, numbersFor: column, rows: rows, into: $0) }
        guard given else { return false }
        for (offset, row) in rows.enumerated() where row < handles.count {
            values[handles[row]] = numbers[offset]
        }
        return true
    }

    /// In the middle of a batch: the rows it inserted have no values yet (a
    /// reused handle still holds a removed row's), so calculators built now
    /// leave them out and the end of the batch adds them, like every row it
    /// changed.
    private func clearSummaryValues(ofNewRows newRows: IndexSet) {
        let capacity = rowHandles.capacity
        for columnID in Array(summarySourceValues.keys) {
            var values = summarySourceValues.removeValue(forKey: columnID) ?? []
            if values.count < capacity { values.append(contentsOf: repeatElement(.nan, count: capacity - values.count)) }
            for handle in newRows where handle < capacity { values[handle] = .nan }
            summarySourceValues[columnID] = values
        }
    }

    /// Shares the source values and the row map instead of copying them per key.
    private nonisolated static func makeSummaryCalculator(for key: SummaryKey, source: [Double], rowMap: [Int]?) -> NGSummaryCalculator {
        NGSummaryCalculator(source: source, rowMap: rowMap, including: key.filter)
    }

    private func makeSummaryCalculator(for key: SummaryKey, source: [Double], rowMap: [Int]?) -> NGSummaryCalculator {
        Self.makeSummaryCalculator(for: key, source: source, rowMap: rowMap)
    }

    /// After targeted row updates: the calculators take away the old values of
    /// changed and removed rows and add the new ones, instead of walking every
    /// row (see NGRowUpdates.swift). `removed` and `added` are values by
    /// column id; `summarySourceValues` already holds the new values.
    /// - Returns: `false` when they can't be updated in place (a row filter,
    ///   a background computation, values not read yet): rebuild them then.
    /// - Parameter filtered: With a filter: `removed` and `added` hold the
    ///   values of the filtered rows only (those that left and came too),
    ///   and the calculators count the rows of `rowMap` now.
    func updateSummaryCalculatorsInPlace(removed: [String: [Double]], added: [String: [Double]], filtered: Bool = false) -> Bool {
        guard summaryTask == nil, (rowMap != nil) == filtered else { return false }
        var updated: [SummaryKey: NGSummaryCalculator] = [:]
        // All rows, after rows moved: the totals need only their count; the
        // rows' order is made when a query needs it (`summaryCalculatorsWithRows`).
        let rowsMovedUnfiltered = rowMap == nil && allRowHandlesCache == nil
        let rows = rowsMovedUnfiltered ? [] : summaryRows
        for key in neededSummaryKeys() {
            guard let calculator = summaryCalculators[key], let source = summarySourceValues[key.columnID],
                  source.count == rowHandles.capacity else { return false }
            updated[key] = rowsMovedUnfiltered
                ? calculator.updating(source: source, movedRowsCount: numberOfSourceRows, removing: removed[key.columnID] ?? [],
                                      adding: added[key.columnID] ?? [])
                : calculator.updating(source: source, rowMap: rows, removing: removed[key.columnID] ?? [],
                                      adding: added[key.columnID] ?? [])
        }
        summaryCalculators = updated
        summaryValuesVersion += 1
        return true
    }

    /// Reads the values on the main actor (the data source lives there) in
    /// slices of a few milliseconds, giving the run loop a turn in between so
    /// scrolling and typing stay smooth, then builds the calculators off the
    /// main thread. Each column read is kept right away, so a filter change
    /// meanwhile only reads what is left. Values that depend on the selection
    /// are hidden until the new calculators are ready; totals keep showing the
    /// previous values, dimmed after a moment. Targeted updates meanwhile,
    /// inserts and removes too, keep what was read (by row handle, see
    /// `NGSummaryBuild`); changed and new rows are read again at the end.
    private func computeSummaryCalculatorsInBackground(for keys: Set<SummaryKey>, reading columnIDs: Set<String>) {
        summaryTask?.cancel()
        summaryGeneration += 1
        let generation = summaryGeneration
        let dataGeneration = summaryDataGeneration
        summaryBuild = NGSummaryBuild(columns: columnIDs.sorted().map { summaryColumn($0) }, rowCount: rowHandles.capacity)
        isComputingSummary = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.summaryGeneration == generation, self.isComputingSummary else { return }
            self.isSummaryProgressVisible = true
        }
        summaryTask = Task { [weak self] in
            while true {
                await NGBackgroundSlices.nextSlice()
                guard !Task.isCancelled, let table = self, table.summaryGeneration == generation else { return }
                guard let done = table.readSummarySlice(dataGeneration: dataGeneration) else {
                    // The data changed without a reload (or the data source is gone):
                    // stop instead of reading past the end; the reload starts over.
                    table.cancelSummaryComputation()
                    return
                }
                if done { break }
            }
            // What the calculators are made of, taken without holding the
            // table across the build and the wait below (it may go meanwhile).
            let taken = self.flatMap { table -> (sources: [String: [Double]], rowMap: [Int], rowsMoved: Int)? in
                guard table.summaryGeneration == generation, table.summaryDataGeneration == dataGeneration else { return nil }
                // Rows changed by targeted updates meanwhile may have been read before they changed.
                table.rereadRowsChangedWhileComputing()
                return (table.summarySourceValues, table.summaryRows, table.summaryRowsMoved)
            }
            guard let (sources, rowMap, rowsMoved) = taken else { return }
            let calculators = await Task.detached(priority: .userInitiated) {
                var calculators: [SummaryKey: NGSummaryCalculator] = [:]
                for key in keys {
                    calculators[key] = Self.makeSummaryCalculator(for: key, source: sources[key.columnID] ?? [], rowMap: rowMap)
                }
                return calculators
            }.value
            // Put in in a turn of the run loop of its own.
            await NGBackgroundSlices.turnOfItsOwn()
            // An open batch (one can span an `await`) finishes the summaries at its end.
            while self.map({ $0.summaryGeneration == generation && $0.rowUpdateBatch?.displayIsStale == true }) == true {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard let table = self, !Task.isCancelled, table.summaryGeneration == generation else { return }
            table.summaryTask = nil
            table.summaryBuild = nil
            if table.summaryRowsMoved != rowsMoved || table.summaryRows != rowMap {
                // Rows moved or the filter shows others: the calculators are
                // built again from the values (all read by now).
                table.rebuildSummaryCalculators(reusingSourceValues: true)
            } else {
                table.summaryCalculators = calculators
                table.summaryValuesVersion += 1
                // Rows changed while the calculators were built: their values are read again
                // and the calculators rebuilt from the values already read (no reading of all rows).
                if !table.summaryRowsChangedWhileComputing.isEmpty {
                    table.rereadRowsChangedWhileComputing()
                    table.rebuildSummaryCalculators(reusingSourceValues: true)
                }
            }
            // Rebuilt above, it may compute again in the background (a
            // filtered tree reads its values again): that one says when.
            guard table.summaryTask == nil else { return }
            table.isComputingSummary = false
            table.isSummaryProgressVisible = false
            table.updateSummary()
            table.delegate?.tableViewDidUpdateSummary(table)
        }
    }

    /// Reads values of the column being read for a few milliseconds, and
    /// keeps every column done; whether all are (`nil`: the data source has
    /// other rows than the table). By handle: rows inserted and removed
    /// meanwhile don't move what was read.
    private func readSummarySlice(dataGeneration: Int) -> Bool? {
        guard var build = summaryBuild.take() else { return true }
        defer { summaryBuild = build }
        guard let dataSource, rowUpdateDepth > 0 || dataSource.numberOfRows(in: self) == numberOfSourceRows else {
            return nil
        }
        let capacity = rowHandles.capacity
        if build.values.count < capacity {
            build.values.append(contentsOf: repeatElement(.nan, count: capacity - build.values.count))
            build.read.append(contentsOf: repeatElement(false, count: capacity - build.read.count))
        }
        let deadline = NGBackgroundSlices.deadline()
        while let column = build.columns.first, ContinuousClock.now < deadline {
            var next = build.read.firstIndex(of: false) ?? capacity
            // Handles that are the row indexes read in large slices at once,
            // when the data source gives numbers for ranges of rows.
            if rowHandles.isIdentity, rowUpdateDepth == 0, next < numberOfSourceRows {
                while next < numberOfSourceRows, ContinuousClock.now < deadline {
                    let end = min(numberOfSourceRows, next + 16_384)
                    guard readNumbers(of: column, rows: next..<end, byHandle: [], into: &build.values) else { break }
                    for handle in next..<end { build.read[handle] = true }
                    next = end
                }
                if next >= numberOfSourceRows { next = build.read.firstIndex(of: false) ?? capacity }
            }
            while next < capacity, ContinuousClock.now < deadline {
                let end = min(capacity, next + 256)
                for handle in next..<end where !build.read[handle] {
                    let row = row(ofHandle: handle)
                    build.values[handle] = row >= 0 ? dataSource.tableView(self, valueFor: column, row: row).summaryNumber ?? .nan : .nan
                    build.read[handle] = true
                }
                next = end
            }
            guard next >= capacity, build.read.firstIndex(of: false) == nil else { break }
            if summaryDataGeneration == dataGeneration {
                maskTreeSummaryValues(&build.values)
                summarySourceValues[column.id] = build.values
            }
            build.columns.removeFirst()
            build.values = [Double](repeating: .nan, count: capacity)
            build.read = [Bool](repeating: false, count: capacity)
        }
        return build.columns.isEmpty
    }

    /// Reads the summarized values of rows that targeted updates changed while
    /// a background computation was running.
    func rereadRowsChangedWhileComputing() {
        guard !summaryRowsChangedWhileComputing.isEmpty, let dataSource else { return }
        let changed = Self.uniqueHandles(summaryRowsChangedWhileComputing, capacity: rowHandles.capacity)
        summaryRowsChangedWhileComputing = []
        for columnID in Array(summarySourceValues.keys) {
            let column = summaryColumn(columnID)
            guard var values = summarySourceValues.removeValue(forKey: columnID) else { continue }
            if values.count < rowHandles.capacity {
                values.append(contentsOf: repeatElement(.nan, count: rowHandles.capacity - values.count))
            }
            // By handle; rows gone since have no value.
            for handle in changed.lazy.map(Int.init) where handle < values.count {
                let row = row(ofHandle: handle)
                values[handle] = row >= 0 && !treeExcludesFromSummaries(handle: handle)
                    ? dataSource.tableView(self, valueFor: column, row: row).summaryNumber ?? .nan : .nan
            }
            summarySourceValues[columnID] = values
        }
    }

    /// `handles` without duplicates (and without handles past `capacity`):
    /// sorted when they are few, else in their first order through a bitmap.
    nonisolated static func uniqueHandles(_ handles: [Int32], capacity: Int) -> [Int32] {
        if handles.count < capacity / 64 {
            var sorted = handles.filter { Int($0) < capacity }
            sorted.sort()
            var result: [Int32] = []
            result.reserveCapacity(sorted.count)
            for handle in sorted where handle != result.last { result.append(handle) }
            return result
        }
        var seen = [Bool](repeating: false, count: capacity)
        var result: [Int32] = []
        result.reserveCapacity(min(handles.count, capacity))
        for handle in handles where Int(handle) < capacity && !seen[Int(handle)] {
            seen[Int(handle)] = true
            result.append(handle)
        }
        return result
    }

    /// Stops a background computation; returns whether one was running.
    @discardableResult
    func cancelSummaryComputation() -> Bool {
        guard summaryTask != nil else { return false }
        summaryTask?.cancel()
        summaryTask = nil
        summaryBuild = nil
        summaryGeneration += 1
        isComputingSummary = false
        isSummaryProgressVisible = false
        return true
    }

    /// What summary values are computed over: the calculators of some rows
    /// (the table's, or a group's), the scope and the selection in their rows.
    private struct SummaryContext {
        var calculators: [SummaryKey: NGSummaryCalculator]
        var scope: NGSummaryScope
        var selection: IndexSet
        /// Accumulators computed once per summary update and shared by the
        /// aggregates and formulas that use them.
        var cache: [SummaryAccumulatorKey: NGAccumulator] = [:]
        /// The summary row's (not a group's): it follows the selection from
        /// the last one (`selectionAccumulators`).
        var isSummaryRow = false
    }

    /// The summary row's: the table's calculators in the summary scope.
    private func makeSummaryContext() -> SummaryContext {
        bringSummaryRowsInStep(forSelection: summaryScope != .allRows)
        keepExactMinMax(&summaryCalculators)
        return SummaryContext(calculators: summaryCalculators, scope: summaryScope,
                              selection: summaryScope == .allRows ? [] : summarySelection, isSummaryRow: true)
    }

    /// The summaries that show min or max of all rows: aggregates, formula
    /// fallbacks and automatic conditional-format ranges.
    var minMaxSummaryKeys: [SummaryKey] {
        var keys: [SummaryKey] = []
        for column in columnLayout.allColumns {
            switch column.summary {
            case .aggregate(let aggregate, let filter) where aggregate == .min || aggregate == .max:
                keys.append(SummaryKey(columnID: column.id, filter: filter))
            case .formula(let formula) where formula.fallback == .min || formula.fallback == .max:
                keys.append(SummaryKey(columnID: column.id, filter: formula.fallbackFilter))
            default:
                break
            }
            if column.conditionalFormat?.range == .automatic { keys.append(SummaryKey(columnID: column.id, filter: .all)) }
        }
        return keys
    }

    /// Computes again, once, the min and max an update in place couldn't
    /// keep, and keeps them: otherwise every frame and summary update walked
    /// all rows until the next reload.
    /// The table's calculators get their rows as they are now when a query
    /// will read rows: the selection's, or min and max walked again.
    /// Not in the middle of a batch that moved rows: the summaries are those
    /// of before it until its end, which brings them in step.
    func bringSummaryRowsInStep(forSelection: Bool) {
        guard rowUpdateBatch?.displayIsStale != true,
              summaryCalculators.values.contains(where: \.rowMapIsStale) else { return }
        let walks = minMaxSummaryKeys.contains { summaryCalculators[$0].map { !$0.hasExactMinMax } ?? false }
        guard forSelection || walks else { return }
        let rows = summaryRows
        summaryCalculators = summaryCalculators.mapValues { $0.rowMapIsStale && $0.count == rows.count ? $0.withRowMap(rows) : $0 }
    }

    func keepExactMinMax(_ calculators: inout [SummaryKey: NGSummaryCalculator]) {
        for key in minMaxSummaryKeys {
            if let calculator = calculators[key], !calculator.hasExactMinMax {
                calculators[key] = calculator.withExactMinMax()
            }
        }
    }

    /// The scope's accumulator of a key.
    private func summaryAccumulator(_ key: SummaryKey, includesMinMax: Bool, context: inout SummaryContext) -> NGAccumulator? {
        let cacheKey = SummaryAccumulatorKey(key: key, includesMinMax: includesMinMax)
        if let cached = context.cache[cacheKey] { return cached }
        guard let calculator = context.calculators[key] else { return nil }
        let accumulator: NGAccumulator
        if context.isSummaryRow, context.scope != .allRows, !includesMinMax {
            accumulator = selectionAccumulator(key, calculator: calculator, scope: context.scope, selection: context.selection)
        } else {
            accumulator = calculator.accumulator(scope: context.scope, selection: context.selection, includesMinMax: includesMinMax)
        }
        context.cache[cacheKey] = accumulator
        return accumulator
    }

    /// The selection's (or the rest's) sum and count from the last
    /// selection's: the rows that joined or left it are added and taken
    /// away, when they are fewer than the rows a fresh computation walks
    /// (dragging a selection over many rows walked them on every step).
    private func selectionAccumulator(_ key: SummaryKey, calculator: NGSummaryCalculator, scope: NGSummaryScope,
                                      selection: IndexSet) -> NGAccumulator {
        if let last = selectionAccumulators[key], last.version == summaryValuesVersion, last.scope == scope {
            let joined = selection.subtracting(last.selection), left = last.selection.subtracting(selection)
            let fresh = min(selection.count, max(0, calculator.count - selection.count))
            if joined.count + left.count < fresh {
                let gained = calculator.accumulator(ofRows: joined), lost = calculator.accumulator(ofRows: left)
                // The rest gains what the selection loses, and the other way round.
                let result = scope == .selectedRows
                    ? last.accumulator.adding(gained).subtractingAdditive(lost)
                    : last.accumulator.adding(lost).subtractingAdditive(gained)
                selectionAccumulators[key] = (summaryValuesVersion, scope, selection, result)
                return result
            }
        }
        let result = calculator.accumulator(scope: scope, selection: selection, includesMinMax: false)
        selectionAccumulators[key] = (summaryValuesVersion, scope, selection, result)
        return result
    }

    private struct SummaryAccumulatorKey: Hashable {
        var key: SummaryKey
        var includesMinMax: Bool
    }

    func summaryValue(of column: NGTableColumn) -> Double? {
        var context = makeSummaryContext()
        return summaryValue(of: column, context: &context)
    }

    private func summaryValue(of column: NGTableColumn, context: inout SummaryContext) -> Double? {
        // Until the new calculators are ready, the old ones cover other rows:
        // values that depend on the selection would be wrong, not just old.
        if isComputingSummary, context.scope != .allRows { return nil }
        switch column.summary {
        case .none:
            return nil
        case .aggregate(let aggregate, let filter):
            let accumulator = summaryAccumulator(SummaryKey(columnID: column.id, filter: filter),
                                                 includesMinMax: aggregate == .min || aggregate == .max, context: &context)
            return accumulator?.value(for: aggregate)
        case .formula(let formula):
            var calculators: [String: NGSummaryCalculator] = [:]
            var accumulators: [String: NGAccumulator] = [:]
            for input in formula.inputs {
                let key = SummaryKey(columnID: input, filter: .all)
                guard let calculator = context.calculators[key] else { continue }
                calculators[input] = calculator
                accumulators[input] = summaryAccumulator(key, includesMinMax: false, context: &context)
            }
            let values = NGSummaryValues(calculators: calculators, accumulators: accumulators, scope: context.scope, selection: context.selection)
            if let value = formula.value(with: values), value.isFinite {
                return value
            }
            // No input data (or a division by zero): fall back to the column's own values.
            guard let fallback = formula.fallback,
                  let accumulator = summaryAccumulator(SummaryKey(columnID: column.id, filter: formula.fallbackFilter),
                                                       includesMinMax: fallback == .min || fallback == .max, context: &context)
            else { return nil }
            return accumulator.count > 0 ? accumulator.value(for: fallback) : nil
        }
    }

    /// The summary texts of the columns in a context, as displayed.
    private func summaryStrings(in context: inout SummaryContext) -> [String: String] {
        let columns = columnLayout.allColumns
        var texts: [String: String] = [:]
        texts.reserveCapacity(columns.count)
        for column in columns {
            guard let value = summaryValue(of: column, context: &context) else { continue }
            let isCount = if case .aggregate(.count, _) = column.summary { true } else { false }
            texts[column.id] = isCount
                ? value.formatted(.number.precision(.fractionLength(0)).locale(formattingLocale))
                : column.format.string(for: value, locale: formattingLocale)
        }
        return texts
    }

    /// A group's subtotal texts, from the values read for the summary row.
    /// Its calculators are kept, so changed values update them in place
    /// (`updateGroupCalculators`) instead of walking the group's rows again;
    /// they get the group's rows as they are now (rows around them may have
    /// moved since).
    func subtotalStrings(of group: NGRowGroup, rows: ArraySlice<Int>) -> [String: String] {
        var calculators = groupSummaryCalculators[group] ?? [:]
        let groupRows = Array(rows)
        for key in neededSummaryKeys() {
            guard let source = summarySourceValues[key.columnID] else {
                calculators[key] = nil
                continue
            }
            if let calculator = calculators[key] {
                calculators[key] = calculator.withSource(source, rowMap: groupRows)
            } else {
                calculators[key] = makeSummaryCalculator(for: key, source: source, rowMap: groupRows)
            }
        }
        keepExactMinMax(&calculators)
        groupSummaryCalculators[group] = calculators
        var context = SummaryContext(calculators: calculators, scope: .allRows, selection: [])
        return summaryStrings(in: &context)
    }

    /// Forgets the subtotal calculators of groups whose rows changed.
    func dropGroupCalculators(of groups: Set<NGRowGroup>?) {
        guard let groups else {
            groupSummaryCalculators = [:]
            return
        }
        for group in groups {
            groupSummaryCalculators[group] = nil
        }
    }

    /// Before the summarized values change in place: the calculators let go of
    /// the value arrays (they share them), so changing a value doesn't copy a
    /// whole column. Updating them gives the arrays back.
    func detachSummarySources() {
        summaryCalculators = summaryCalculators.mapValues { $0.withSource([]) }
        groupSummaryCalculators = groupSummaryCalculators.mapValues { $0.mapValues { $0.withSource([]) } }
    }

    /// After values of `rows` changed (the groups stayed): the groups' kept
    /// calculators take away the old values and add the new ones.
    /// - Parameters:
    ///   - olds: The previous values by column id, in the order of `rows`.
    ///   - news: The new values, in the same order.
    func updateGroupCalculators(changedRows rows: IndexSet, olds: [String: [Double]], news: [String: [Double]]) {
        guard !groupSummaryCalculators.isEmpty else { return }
        // By node number first: hashing a group (its path) for every row would cost more.
        var positionsOfNode: [Int: [Int]] = [:]
        let tree = groupTree
        for (position, row) in rows.enumerated() where row < tree.leafOfSourceRow.count {
            var node = Int(tree.leafOfSourceRow[row])
            while node >= 0 {
                positionsOfNode[node, default: []].append(position)
                node = tree.nodes[node].parent
            }
        }
        for (node, positions) in positionsOfNode {
            let group = tree.nodes[node].group
            guard var calculators = groupSummaryCalculators[group] else { continue }
            for (key, calculator) in calculators {
                guard let old = olds[key.columnID], let new = news[key.columnID], let source = summarySourceValues[key.columnID],
                      old.count == rows.count, new.count == rows.count else {
                    calculators[key] = nil
                    continue
                }
                calculators[key] = calculator.updating(source: source, removing: positions.map { old[$0] }, adding: positions.map { new[$0] })
            }
            groupSummaryCalculators[group] = calculators
        }
    }

    /// Before the groups are built again after a batch that moved rows:
    /// the values each group's kept calculators lose (its removed rows and
    /// its changed rows' old values), by group and column id. `nil` if the
    /// batch couldn't tell which groups had them.
    func groupValuesLost(in batch: NGRowUpdateBatch, changedRows rows: IndexSet,
                         olds: [String: [Double]]) -> [NGRowGroup: [String: [Double]]]? {
        guard !batch.groupLeavesAreUnknown, batch.groupTreeGeneration == groupTreeGeneration else { return nil }
        guard !groupSummaryCalculators.isEmpty else { return [:] }
        let removedCount = batch.removedLeaves.count
        guard batch.removedValues.values.allSatisfy({ $0.count == removedCount }),
              olds.values.allSatisfy({ $0.count == rows.count }) else { return nil }
        let tree = groupTree
        // By node first, as positions: hashing a group for every row would cost more.
        var removedOfNode: [Int: [Int]] = [:]
        for (index, leaf) in batch.removedLeaves.enumerated() {
            var node = Int(leaf)
            while node >= 0, node < tree.nodes.count {
                removedOfNode[node, default: []].append(index)
                node = tree.nodes[node].parent
            }
        }
        // The rows' groups are kept by handle.
        let changedOfNode = Self.positionsOfNodes(of: rows, in: tree)
        var lost: [NGRowGroup: [String: [Double]]] = [:]
        for node in Set(removedOfNode.keys).union(changedOfNode.keys) {
            let group = tree.nodes[node].group
            guard groupSummaryCalculators[group] != nil else { continue }
            var values: [String: [Double]] = [:]
            // Gathered by nonisolated helpers: closures made here check the executor per value.
            for (columnID, removed) in batch.removedValues {
                values[columnID] = Self.gathered(removed, at: removedOfNode[node] ?? [], placeholder: .nan)
            }
            for (columnID, old) in olds {
                values[columnID, default: []].append(contentsOf: Self.gathered(old, at: changedOfNode[node] ?? [], placeholder: .nan))
            }
            lost[group] = values
        }
        return lost
    }

    /// After the groups were built again: the kept calculators of the groups
    /// that still exist lose `lost` and gain the changed rows' new values in
    /// their new groups; those of groups gone are dropped. Groups whose rows
    /// changed show new subtotal texts.
    func updateGroupCalculators(losing lost: [NGRowGroup: [String: [Double]]], changedRows rows: IndexSet,
                                news: [String: [Double]]) {
        let tree = groupTree
        for group in groupSummaryCalculators.keys where tree.nodeOfGroup[group] == nil {
            groupSummaryCalculators[group] = nil
            groupSubtotals[group] = nil
        }
        var gained: [NGRowGroup: [String: [Double]]] = [:]
        if news.values.allSatisfy({ $0.count == rows.count }) {
            for (node, positions) in Self.positionsOfNodes(of: rows, in: tree) {
                let group = tree.nodes[node].group
                guard groupSummaryCalculators[group] != nil else { continue }
                var values: [String: [Double]] = [:]
                for (columnID, new) in news { values[columnID] = Self.gathered(new, at: positions, placeholder: .nan) }
                gained[group] = values
            }
        } else {
            // The new values don't line up with the rows: the groups with changed rows start over.
            for (node, _) in Self.positionsOfNodes(of: rows, in: tree) {
                groupSummaryCalculators[tree.nodes[node].group] = nil
            }
        }
        for group in Set(lost.keys).union(gained.keys) {
            groupSubtotals[group] = nil
            guard var calculators = groupSummaryCalculators[group] else { continue }
            for (key, calculator) in calculators {
                guard let source = summarySourceValues[key.columnID] else {
                    calculators[key] = nil
                    continue
                }
                calculators[key] = calculator.updating(source: source, removing: lost[group]?[key.columnID] ?? [],
                                                       adding: gained[group]?[key.columnID] ?? [])
            }
            groupSummaryCalculators[group] = calculators
        }
    }

    /// The positions in `rows` of the rows in each group (node), with the groups around them.
    private static func positionsOfNodes(of rows: IndexSet, in tree: NGGroupTree) -> [Int: [Int]] {
        var positionsOfNode: [Int: [Int]] = [:]
        for (position, row) in rows.enumerated() where row < tree.leafOfSourceRow.count {
            var node = Int(tree.leafOfSourceRow[row])
            while node >= 0, node < tree.nodes.count {
                positionsOfNode[node, default: []].append(position)
                node = tree.nodes[node].parent
            }
        }
        return positionsOfNode
    }

    func updateSummary() {
        var context = makeSummaryContext()
        let texts = summaryStrings(in: &context)
        // Header rows show subtotals of the same values.
        if groupedDisplay != nil, groupSubtotalsVersion != summaryValuesVersion {
            refreshGroupRows()
        }
        #if os(macOS)
        summaryBar.contentView.toolTip = summaryScopeTitles[summaryScope]
        #endif
        // Drawn again only when a text changed (a feed's batch of values out
        // of the summarized columns drew it every tick).
        if texts != summaryTexts {
            summaryTexts = texts
            summaryBar.contentView.needsDisplay = true
        }
        if notifiesSummaryUpdate {
            notifiesSummaryUpdate = false
            delegate?.tableViewDidUpdateSummary(self)
        }
    }

    #if os(macOS)
    /// The summary row's context menu: which rows the summaries count.
    func makeSummaryScopeMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, scope) in NGSummaryScope.allCases.enumerated() {
            let item = NSMenuItem(
                title: summaryScopeTitles[scope] ?? "\(scope)",
                action: #selector(selectSummaryScope(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.state = scope == summaryScope ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectSummaryScope(_ sender: NSMenuItem) {
        guard NGSummaryScope.allCases.indices.contains(sender.tag) else { return }
        setSummaryScopeByUser(NGSummaryScope.allCases[sender.tag])
    }
    #endif
}
#endif
