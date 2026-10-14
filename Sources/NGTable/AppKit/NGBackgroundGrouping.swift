#if os(macOS)
import AppKit

// Grouping a large table without holding the main thread. Most of grouping
// is reading every row's key from the data source (the groups themselves
// are built in a few milliseconds), and the data source lives on the main
// actor: so the keys of grouping columns not read yet are read in slices of
// a few milliseconds, giving the run loop a turn in between, like a search's
// words (`synchronousGroupingLimit`). Meanwhile the rows show as they were
// grouped before (or not grouped) and `isGroupingRows` is true; rows the app
// changes or inserts meanwhile are read again, so a live feed doesn't keep
// it from finishing. Columns already grouped by keep their keys: grouping by
// one more column reads that column only.

/// The keys of a new grouping being read (see `NGBackgroundGrouping.swift`).
struct NGGroupingJob {
    /// The grouping whose keys are read.
    let columnIDs: [String]
    /// The grouping shown meanwhile (its keys are read; `nil`: not grouped).
    let shownColumnIDs: [String]?
    /// The keys of the columns not read before.
    var keys: NGGroupKeys
    /// By handle: whether the row's keys are read.
    var read: [Bool]
    /// No row before this one is unread.
    var firstUnread = 0
}

extension NGTableView {
    /// The grouping to lay the rows out by for `columnIDs`: those columns
    /// if their keys are read or few enough to read now, otherwise the one
    /// shown before while the new keys are read in the background.
    func groupingColumnsToShow(for columnIDs: [String]) -> [String]? {
        if let job = groupingJob {
            if job.columnIDs == columnIDs { return job.shownColumnIDs }
            cancelGroupingJob()
        }
        let capacity = rowHandles.capacity
        let missing = columnIDs.filter { columnID in
            guard let keys = groupKeys, let level = keys.columnIDs.firstIndex(of: columnID) else { return true }
            return keys.ids[level].count != capacity
        }
        guard !missing.isEmpty, missing.count * numberOfSourceRows > synchronousGroupingLimit, rowUpdateDepth == 0 else {
            return columnIDs
        }
        // Shown meanwhile: the groups laid out now, if their keys stay read.
        var shown: [String]?
        if groupedDisplay != nil, let current = groupTree.nodes.last?.group.columnIDs, let keys = groupKeys,
           current.allSatisfy({ id in keys.columnIDs.firstIndex(of: id).map { keys.ids[$0].count == capacity } ?? false }) {
            shown = current
        }
        startGroupingJob(columnIDs, reading: missing, shown: shown)
        return shown
    }

    private func startGroupingJob(_ columnIDs: [String], reading missing: [String], shown: [String]?) {
        let capacity = rowHandles.capacity
        groupingJob = NGGroupingJob(columnIDs: columnIDs, shownColumnIDs: shown,
                                    keys: NGGroupKeys(columnIDs: missing, rowCount: capacity),
                                    read: [Bool](repeating: false, count: capacity))
        isGroupingRows = true
        groupingTask = Task { [weak self] in
            while true {
                await Task.yield()
                guard !Task.isCancelled, let table = self, table.groupingJob != nil else { return }
                guard let done = table.readGroupingSlice() else {
                    // The data changed without telling the table: the reload starts over.
                    table.cancelGroupingJob()
                    return
                }
                guard done else { continue }
                // The rows are laid out again between batches.
                while self?.rowUpdateDepth ?? 0 > 0 { try? await Task.sleep(for: .milliseconds(2)) }
                guard !Task.isCancelled, let table = self else { return }
                // Rows changed or inserted while waiting are read too.
                if table.readGroupingSlice() == true { table.finishGroupingJob() } else { continue }
                return
            }
        }
    }

    /// Reads keys of rows not read yet for a few milliseconds; whether all
    /// are read (`nil`: the data source has other rows than the table).
    private func readGroupingSlice() -> Bool? {
        guard var job = groupingJob.take() else { return true }
        defer { groupingJob = job }
        guard let dataSource, rowUpdateBatch != nil || dataSource.numberOfRows(in: self) == numberOfSourceRows else { return nil }
        // Rows inserted since have handles of their own.
        let capacity = rowHandles.capacity
        if job.read.count < capacity { job.read.append(contentsOf: repeatElement(false, count: capacity - job.read.count)) }
        for level in job.keys.ids.indices where job.keys.ids[level].count < capacity {
            job.keys.ids[level].append(contentsOf: repeatElement(-1, count: capacity - job.keys.ids[level].count))
        }
        let columns = job.keys.columnIDs.map(summaryColumn)
        let deadline = ContinuousClock.now.advanced(by: NGTableView.backgroundSlice)
        var next = job.read[job.firstUnread...].firstIndex(of: false) ?? capacity
        while next < capacity, ContinuousClock.now < deadline {
            let end = min(capacity, next + 256)
            for handle in next..<end where !job.read[handle] {
                let row = row(ofHandle: handle)
                if row >= 0 {
                    for (level, column) in columns.enumerated() {
                        let value = dataSource.tableView(self, valueFor: column, row: row)
                        job.keys.ids[level][handle] = job.keys.id(level: level, value: value) { groupKey(of: value, in: column) }
                    }
                }
                job.read[handle] = true
            }
            next = end
        }
        job.firstUnread = min(next, capacity)
        return next >= capacity && job.read[job.firstUnread...].firstIndex(of: false) == nil
    }

    /// Every key read: the grouping's keys go together, and the rows are
    /// grouped by them.
    private func finishGroupingJob() {
        guard var job = groupingJob.take() else { return }
        groupingTask = nil
        isGroupingRows = false
        job.keys.compactIfNeeded()
        // The keys of the columns grouped by before, and the ones read now.
        let capacity = rowHandles.capacity
        let (merged, newLevels) = (groupKeys ?? NGGroupKeys(columnIDs: [], rowCount: capacity)).regrouped(by: job.columnIDs, rowCount: capacity)
        var keys = merged
        for level in newLevels {
            guard let read = job.keys.columnIDs.firstIndex(of: job.columnIDs[level]) else {
                // Dropped meanwhile: grouping reads it again.
                computeGroupingAgain()
                return
            }
            keys.take(level: level, from: job.keys, level: read)
        }
        groupKeys = keys
        computeGroupingAgain()
    }

    private func computeGroupingAgain() {
        updateDisplayedRows(rebuildingSummaries: false) { computeDisplayRows() }
    }

    /// Stops reading a grouping's keys (the next layout of the rows reads
    /// them again if needed).
    func cancelGroupingJob() {
        guard groupingJob != nil || groupingTask != nil else { return }
        groupingTask?.cancel()
        groupingTask = nil
        groupingJob = nil
        isGroupingRows = false
    }

    /// Rows (handles) whose grouping values changed or that are new: read
    /// again by a grouping being read.
    func markGroupingJobRowsUnread(_ handles: IndexSet) {
        guard var job = groupingJob.take() else { return }
        for handle in handles where handle < job.read.count { job.read[handle] = false }
        if let first = handles.first { job.firstUnread = min(job.firstUnread, first) }
        groupingJob = job
    }
}
#endif
