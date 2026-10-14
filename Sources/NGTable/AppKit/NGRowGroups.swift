#if os(macOS)
import AppKit

// Row grouping (`NGTableView.rowGrouping`). Groups are a display layer on top
// of the row filter: the filter decides which data source rows are shown, the
// grouping gathers them under header rows and leaves out those of collapsed
// groups. Display rows then are either data source rows or group headers;
// everything that works with data source rows (selection, the data source,
// the delegate, summaries) never sees the headers.
//
// The key of every row (the displayed value of each grouping column) is read
// once and kept like the search index, so filtering, collapsing and targeted
// updates don't ask the data source again.

/// The group key of every data source row, by level, as small numbers.
struct NGGroupKeys {
    let columnIDs: [String]
    /// Per level: the key number of each data source row (-1: not read yet).
    var ids: [[Int32]]
    /// Per level: the displayed value of each key number, and the value of
    /// the first row read with it.
    var keys: [[String]]
    var values: [[NGCellValue]]
    var idOfKey: [[String: Int32]]
    /// Per level: the key number of each value seen, so a value seen before
    /// isn't formatted again (formatting is most of reading the keys). Text
    /// and numbers, most grouping values, have their own: hashing a cell
    /// value costs several times hashing its text.
    var idOfValue: [[NGCellValue: Int32]]
    var idOfText: [[String: Int32]]
    var idOfNumber: [[Double: Int32]]
    /// Per level: how many key numbers there may be before the ones no row
    /// has any more are dropped (`compactIfNeeded()`).
    private var compactionThresholds: [Int]
    private static let minimumThreshold = 256

    init(columnIDs: [String], rowCount: Int) {
        self.columnIDs = columnIDs
        ids = columnIDs.map { _ in Array(repeating: -1, count: rowCount) }
        keys = columnIDs.map { _ in [] }
        values = columnIDs.map { _ in [] }
        idOfKey = columnIDs.map { _ in [:] }
        idOfValue = columnIDs.map { _ in [:] }
        idOfText = columnIDs.map { _ in [:] }
        idOfNumber = columnIDs.map { _ in [:] }
        compactionThresholds = columnIDs.map { _ in Self.minimumThreshold }
    }

    /// Live data that changes grouping values (e.g. a status, a rounded
    /// number) leaves keys no row has any more; without a reload they would
    /// pile up (and every regrouping allocates per key). Once a level has
    /// many more keys than in use, they are numbered again, keeping only the
    /// used ones. Each compaction walks the rows once; the next waits for as
    /// many new keys again, so the cost per changed key stays constant.
    mutating func compactIfNeeded() {
        for level in keys.indices where keys[level].count > compactionThresholds[level] {
            var newID = [Int32](repeating: -1, count: keys[level].count)
            var newKeys: [String] = [], newValues: [NGCellValue] = []
            var newIDOfKey: [String: Int32] = [:]
            ids[level].withUnsafeMutableBufferPointer { rowIDs in
                for row in rowIDs.indices {
                    let id = Int(rowIDs[row])
                    guard id >= 0 else { continue }
                    if newID[id] < 0 {
                        newID[id] = Int32(newKeys.count)
                        newIDOfKey[keys[level][id]] = newID[id]
                        newKeys.append(keys[level][id])
                        newValues.append(values[level][id])
                    }
                    rowIDs[row] = newID[id]
                }
            }
            keys[level] = newKeys
            values[level] = newValues
            idOfKey[level] = newIDOfKey
            idOfValue[level] = [:]
            idOfText[level] = [:]
            idOfNumber[level] = [:]
            compactionThresholds[level] = max(Self.minimumThreshold, newKeys.count * 2)
        }
    }

    /// Key numbers of a level (used or not), for tests.
    func keyCount(level: Int) -> Int { keys[level].count }

    /// The keys of other grouping columns: the levels of columns these keys
    /// have are taken over as they are (read already), the others are new.
    /// - Returns: The keys, and the levels that are new (no row read).
    func regrouped(by columnIDs: [String], rowCount: Int) -> (keys: NGGroupKeys, newLevels: [Int]) {
        var result = NGGroupKeys(columnIDs: columnIDs, rowCount: rowCount)
        var newLevels: [Int] = []
        for (level, columnID) in columnIDs.enumerated() {
            guard let old = self.columnIDs.firstIndex(of: columnID), ids[old].count == rowCount else {
                newLevels.append(level)
                continue
            }
            result.take(level: level, from: self, level: old)
        }
        return (result, newLevels)
    }

    /// Takes over one level of other keys.
    mutating func take(level: Int, from other: NGGroupKeys, level old: Int) {
        ids[level] = other.ids[old]
        keys[level] = other.keys[old]
        values[level] = other.values[old]
        idOfKey[level] = other.idOfKey[old]
        idOfValue[level] = other.idOfValue[old]
        idOfText[level] = other.idOfText[old]
        idOfNumber[level] = other.idOfNumber[old]
        compactionThresholds[level] = other.compactionThresholds[old]
    }

    mutating func id(level: Int, key: String, value: NGCellValue) -> Int32 {
        if let id = idOfKey[level][key] { return id }
        let id = Int32(keys[level].count)
        keys[level].append(key)
        values[level].append(value)
        idOfKey[level][key] = id
        return id
    }

    /// The key number of a value: from the values seen before, or by its key
    /// (`key()` formats it).
    mutating func id(level: Int, value: NGCellValue, key: () -> String) -> Int32 {
        // Distinct values of live numbers could pile up: kept while few.
        switch value {
        case .text(let text):
            if let id = idOfText[level][text] { return id }
            let id = id(level: level, key: key(), value: value)
            if idOfText[level].count < 4096 { idOfText[level][text] = id }
            return id
        case .number(let number) where !number.isNaN:
            if let id = idOfNumber[level][number] { return id }
            let id = id(level: level, key: key(), value: value)
            if idOfNumber[level].count < 4096 { idOfNumber[level][number] = id }
            return id
        default:
            if let id = idOfValue[level][value] { return id }
            let id = id(level: level, key: key(), value: value)
            if idOfValue[level].count < 4096 { idOfValue[level][value] = id }
            return id
        }
    }
}

/// A group: its rows are `NGGroupTree.groupedRows[rows]`, its subgroups the
/// nodes `children` (none at the innermost level).
struct NGGroupNode {
    var group: NGRowGroup
    var parent: Int
    var rows: Range<Int>
    var children: Range<Int>
}

/// The groups of the rows the filter shows.
struct NGGroupTree {
    var nodes: [NGGroupNode] = []
    var topLevel: Range<Int> = 0..<0
    /// The shown rows (handles, see `NGRowHandles`), group after group (each
    /// group's rows are contiguous, in display order).
    var groupedRows: [Int] = []
    var nodeOfGroup: [NGRowGroup: Int] = [:]
    /// The innermost group (node) of each row by handle (-1: not shown), so
    /// it follows the rows in a batch.
    var leafOfSourceRow: [Int32] = []

    /// The groups (nodes) rows are in, with the groups around them.
    func nodes(containing rows: IndexSet) -> Set<Int> {
        var found = Set<Int>()
        for row in rows where row >= 0 && row < leafOfSourceRow.count {
            var node = Int(leafOfSourceRow[row])
            while node >= 0, found.insert(node).inserted {
                node = nodes[node].parent
            }
        }
        return found
    }

    /// After the table's sort moved rows that stayed in their groups: each
    /// group's rows in the new `order`, the groups kept. Returns `false` if
    /// that doesn't give the same tree (a group's first row now comes after
    /// the next group's, so the groups change order; or the rows differ):
    /// the tree must be built again. One pass over the rows, no buckets.
    mutating func refill(inOrder order: [Int]) -> Bool {
        var next = nodes.map(\.rows.lowerBound)
        let end = nodes.map(\.rows.upperBound)
        var first = [Int](repeating: Int.max, count: nodes.count)
        var fits = true
        // Plain buffer loops: this pass goes over every row each tick.
        let rowCount = leafOfSourceRow.count
        leafOfSourceRow.withUnsafeBufferPointer { leaves in
        groupedRows.withUnsafeMutableBufferPointer { groupedRows in
        next.withUnsafeMutableBufferPointer { next in
        first.withUnsafeMutableBufferPointer { first in
        end.withUnsafeBufferPointer { end in
        order.withUnsafeBufferPointer { order in
            for index in order.indices {
                let row = order[index]
                guard row >= 0, row < rowCount else { fits = false; return }
                let leaf = Int(leaves[row])
                guard leaf >= 0 else { continue }
                if first[leaf] == Int.max { first[leaf] = index }
                let position = next[leaf]
                guard position < end[leaf], position < groupedRows.count else { fits = false; return }
                groupedRows[position] = row
                next[leaf] = position + 1
            }
        }
        }
        }
        }
        }
        }
        guard fits else { return false }
        // Children come after their parents in `nodes`.
        for node in nodes.indices.reversed() {
            if nodes[node].children.isEmpty, next[node] != nodes[node].rows.upperBound { return false }
            let parent = nodes[node].parent
            if parent >= 0 { first[parent] = min(first[parent], first[node]) }
        }
        func ordered(_ siblings: Range<Int>) -> Bool {
            var previous = -1
            for node in siblings {
                guard first[node] > previous else { return false }
                previous = first[node]
            }
            return true
        }
        guard ordered(topLevel) else { return false }
        for node in nodes where !ordered(node.children) { return false }
        return true
    }

    /// After a batch that inserted, removed or moved rows, when the groups
    /// stay the same: every shown row (`order`) goes to the group it had
    /// (the groups followed the rows), new and `changed` rows to the group
    /// of their keys (`ids` by level, `leafOfKeys` the innermost group of
    /// each path of key numbers). Returns `false` if that doesn't give the
    /// same groups in the same order (a group appears, keeps no rows, or
    /// comes before another now): the tree must be built again. Two passes
    /// over the rows instead of a counting sort per level.
    mutating func refill(inOrder order: [Int], changed: IndexSet, ids: [[Int32]], leafOfKeys: [[Int32]: Int32]) -> Bool {
        let rowCount = leafOfSourceRow.count
        guard !nodes.isEmpty, ids.allSatisfy({ $0.count == rowCount }) else { return false }
        // Changed rows (their keys, or whether they're shown) find their group again.
        for range in changed.rangeView {
            for row in range where row < rowCount { leafOfSourceRow[row] = -1 }
        }
        var counts = [Int](repeating: 0, count: nodes.count)
        var first = [Int](repeating: Int.max, count: nodes.count)
        var path = [Int32](repeating: 0, count: ids.count)
        var fits = true
        leafOfSourceRow.withUnsafeMutableBufferPointer { leaves in
            order.withUnsafeBufferPointer { order in
                for index in order.indices {
                    let row = order[index]
                    guard row >= 0, row < rowCount else { fits = false; return }
                    var leaf = Int(leaves[row])
                    if leaf < 0 {
                        // A new or changed row: few of them.
                        for level in ids.indices { path[level] = ids[level][row] }
                        guard let found = leafOfKeys[path] else { fits = false; return }
                        leaf = Int(found)
                        leaves[row] = found
                    }
                    counts[leaf] += 1
                    if first[leaf] == Int.max { first[leaf] = index }
                }
            }
        }
        guard fits else { return false }
        // Children come after their parents in `nodes`.
        for node in nodes.indices.reversed() {
            if nodes[node].children.isEmpty, counts[node] == 0 { return false }
            let parent = nodes[node].parent
            if parent >= 0 { first[parent] = min(first[parent], first[node]) }
        }
        func ordered(_ siblings: Range<Int>) -> Bool {
            var previous = -1
            for node in siblings {
                guard first[node] > previous else { return false }
                previous = first[node]
            }
            return true
        }
        guard ordered(topLevel) else { return false }
        for node in nodes where !ordered(node.children) { return false }
        // The groups' rows with their new counts, in display order.
        var position = 0
        func lay(_ node: Int) {
            let start = position
            if nodes[node].children.isEmpty {
                position += counts[node]
            } else {
                for child in nodes[node].children { lay(child) }
            }
            nodes[node].rows = start..<position
        }
        for node in topLevel { lay(node) }
        var next = nodes.map(\.rows.lowerBound)
        var rows = [Int](repeating: 0, count: position)
        leafOfSourceRow.withUnsafeBufferPointer { leaves in
            rows.withUnsafeMutableBufferPointer { rows in
                next.withUnsafeMutableBufferPointer { next in
                    order.withUnsafeBufferPointer { order in
                        for row in order {
                            let leaf = Int(leaves[row])
                            rows[next[leaf]] = row
                            next[leaf] += 1
                        }
                    }
                }
            }
        }
        groupedRows = rows
        return true
    }
}

extension NGTableView {
    // MARK: Display rows

    /// Whether a display row is a group header.
    func isGroupRow(_ displayRow: Int) -> Bool {
        guard let groupedDisplay, displayRow >= 0, displayRow < groupedDisplay.count else { return false }
        return groupedDisplay[displayRow] < 0
    }

    /// The group node of a header row, or `nil` for other rows.
    func groupNode(atDisplayRow displayRow: Int) -> Int? {
        guard let groupedDisplay, displayRow >= 0, displayRow < groupedDisplay.count else { return nil }
        let entry = groupedDisplay[displayRow]
        return entry < 0 ? -1 - entry : nil
    }

    /// What `computeDisplayRows` changed.
    struct DisplayRowsChange {
        /// Rows moved between groups, or groups appeared or disappeared.
        var regrouped = true
        /// The subtotals of unchanged groups were kept (only the changed rows'
        /// groups compute theirs again).
        var keptSubtotals = false
        /// The table's own sort put rows in another order.
        var reordered = false
    }

    /// Filters, groups and lays out the display rows of the current data.
    ///
    /// - Parameter changedRows: After targeted updates that only changed
    ///   values: the changed rows. Their keys are read again, and the groups
    ///   are only rebuilt if one of them moved to another group (or the filter
    ///   shows other rows); the other groups keep their subtotals. Live data
    ///   mostly changes values that don't group, so this stays cheap.
    /// - Parameter regroupingRows: The changed rows whose group keys may have
    ///   changed (all of `changedRows` by default).
    /// - Parameter keepingGroupSubtotals: The groups are built again, but the
    ///   caller updates the subtotals' calculators of the groups that stay.
    /// - Parameter movedRows: At the end of a batch that moved rows: the
    ///   rows changed in it. Only they may be in other groups, or be shown
    ///   or hidden now; if the groups stay, the rows are laid out in them
    ///   again instead of grouped from scratch.
    @discardableResult
    func computeDisplayRows(changedRows: IndexSet? = nil, regroupingRows: IndexSet? = nil,
                            keepingGroupSubtotals: Bool = false, movedRows: IndexSet? = nil) -> DisplayRowsChange {
        // Display rows in the open batch's rows from here on.
        rowUpdateBatch?.displayIsStale = false
        let previousRowMap = rowMap
        let evaluations = filterEvaluations
        computeRowMap()
        let reordered = updateDisplayOrder()
        if isShowingRowTree {
            retireGroupSubtotals()
            groupTree = NGGroupTree()
            groupTreeGeneration += 1
            groupHeaderDisplayRows = []
            groupDisplayEnds = []
            // Changed rows may have other parents; if none did, and the rows
            // shown and their order stayed, the tree stays.
            if let changedRows { treeParentsToRead.formUnion(changedRows) }
            // (A batch may have read them already, before its summaries.)
            let parentsChanged = readTreeParents() || treeParentsChangedSinceLayout
            treeParentsChangedSinceLayout = false
            if changedRows != nil, !parentsChanged, !reordered, rowMap == previousRowMap, groupedDisplay != nil {
                return DisplayRowsChange(regrouped: false, reordered: false)
            }
            buildTreeDisplay(readingParents: false)
            return DisplayRowsChange(reordered: reordered)
        }
        // A grouping whose keys are read in the background shows the rows as
        // they were grouped before meanwhile (see NGBackgroundGrouping.swift).
        guard let target = rowGrouping?.columnIDs, !target.isEmpty, dataSource != nil,
              let columnIDs = groupingColumnsToShow(for: target) else {
            retireGroupSubtotals()
            groupTree = NGGroupTree()
            groupTreeGeneration += 1
            groupedDisplay = nil
            displayRowOfSource = []
            numberOfRows = rowMap?.count ?? numberOfSourceRows
            return DisplayRowsChange(reordered: reordered)
        }
        // Sorted rows in other places: the groups list their rows again (in order).
        if let changedRows, groupedDisplay != nil, rowMap == previousRowMap, groupKeys?.columnIDs == columnIDs,
           groupKeys?.ids.first?.count == rowHandles.capacity {
            // Their groups before and after: their subtotals change.
            var affected = groups(containing: changedRows)
            let regrouped = rereadGroupKeys(ofRows: regroupingRows ?? changedRows)
            if regrouped {
                buildGroupTree()
                buildGroupedDisplay()
                affected.formUnion(groups(containing: changedRows))
                // Their rows changed: their subtotals are computed again.
                dropGroupCalculators(of: affected)
            } else if reordered {
                // The same groups with their rows in another order: their subtotals stay.
                var tree = groupTree
                groupTree = NGGroupTree()   // One owner while it changes.
                if tree.refill(inOrder: displayOrder ?? []) {
                    groupTree = tree
                } else {
                    groupTree = tree
                    buildGroupTree()
                }
                buildGroupedDisplay()
            }
            for group in affected {
                groupSubtotals[group] = nil
            }
            return DisplayRowsChange(regrouped: regrouped, keptSubtotals: true, reordered: reordered)
        }
        // The groups may have other rows now.
        if !keepingGroupSubtotals { retireGroupSubtotals() }
        if let changedRows { invalidateGroupKeys(forRows: regroupingRows ?? changedRows) }
        // Rows moved in a batch: if only its changed rows may be in other
        // groups (or shown or hidden), and the keys were kept, the groups
        // may stay.
        let keysKept = groupKeys?.columnIDs == columnIDs && groupKeys?.ids.first?.count == rowHandles.capacity
        let reread = groupKeysToRead
        readGroupKeys(columnIDs)
        if let movedRows, keysKept, filterEvaluations == evaluations, groupedDisplay != nil, let keys = groupKeys,
           groupTree.nodes.last?.group.columnIDs == columnIDs, groupTree.leafOfSourceRow.count == rowHandles.capacity {
            var tree = groupTree
            groupTree = NGGroupTree()   // One owner while it changes.
            let shown = displayOrder ?? rowMap ?? allRowHandles
            let refilled = tree.refill(inOrder: shown, changed: movedRows.union(reread), ids: keys.ids,
                                       leafOfKeys: Self.leafOfKeys(in: tree, keys: keys))
            groupTree = tree
            if !refilled { buildGroupTree() }
        } else {
            buildGroupTree()
        }
        buildGroupedDisplay()
        return DisplayRowsChange(reordered: reordered)
    }

    /// The innermost group of each path of key numbers (by level).
    private static func leafOfKeys(in tree: NGGroupTree, keys: NGGroupKeys) -> [[Int32]: Int32] {
        var leaves: [[Int32]: Int32] = [:]
        for (index, node) in tree.nodes.enumerated() where node.children.isEmpty {
            var path: [Int32] = []
            for (level, key) in node.group.path.enumerated() where level < keys.idOfKey.count {
                guard let id = keys.idOfKey[level][key] else { break }
                path.append(id)
            }
            if path.count == keys.columnIDs.count { leaves[path] = Int32(index) }
        }
        return leaves
    }

    /// The groups (with the groups around them) that rows are in.
    private func groups(containing rows: IndexSet) -> Set<NGRowGroup> {
        Set(groupTree.nodes(containing: rows).map { groupTree.nodes[$0].group })
    }

    /// The key of a row's value in a grouping column.
    func groupKey(of value: NGCellValue, in column: NGTableColumn) -> String {
        value == .empty ? "" : column.format.string(for: value, locale: formattingLocale)
    }

    /// Reads the keys of all rows after a reload (or of grouping columns not
    /// read before: the levels of columns grouped by before are kept),
    /// otherwise of the rows (handles) `invalidateGroupKeys(forRows:)` marked.
    private func readGroupKeys(_ columnIDs: [String]) {
        guard let dataSource else { return }
        let capacity = rowHandles.capacity
        let allRows = IndexSet(integersIn: 0..<capacity)
        var newLevels: [Int] = []
        if groupKeys?.columnIDs != columnIDs || groupKeys?.ids.first?.count != capacity {
            if let old = groupKeys.take() {
                (groupKeys, newLevels) = old.regrouped(by: columnIDs, rowCount: capacity)
            } else {
                groupKeys = NGGroupKeys(columnIDs: columnIDs, rowCount: capacity)
                newLevels = Array(columnIDs.indices)
            }
            // Read before for other columns or rows: every row is read.
            if newLevels.count == columnIDs.count { groupKeysToRead = allRows }
        }
        guard var keys = groupKeys, !groupKeysToRead.isEmpty || !newLevels.isEmpty else { return }
        groupKeys = nil   // One owner: changing a row's key doesn't copy every row's.
        for (level, columnID) in columnIDs.enumerated() {
            let column = summaryColumn(columnID)
            // By ranges (all rows after a reload): iterating an index set row by row costs more.
            for range in (newLevels.contains(level) ? allRows : groupKeysToRead).rangeView {
                for handle in range where handle < capacity {
                    let row = row(ofHandle: handle)
                    guard row >= 0 else { continue }
                    let value = dataSource.tableView(self, valueFor: column, row: row)
                    keys.ids[level][handle] = keys.id(level: level, value: value) { groupKey(of: value, in: column) }
                }
            }
        }
        keys.compactIfNeeded()
        groupKeysToRead = []
        groupKeys = keys
    }

    /// Reads the keys of changed rows again; whether any of them changed.
    private func rereadGroupKeys(ofRows rows: IndexSet) -> Bool {
        guard var keys = groupKeys, let dataSource else { return true }
        groupKeys = nil   // One owner: changing a row's key doesn't copy every row's.
        var changed = false
        for (level, columnID) in keys.columnIDs.enumerated() {
            let column = summaryColumn(columnID)
            for handle in rows where handle < keys.ids[level].count {
                let row = row(ofHandle: handle)
                guard row >= 0 else { continue }
                let value = dataSource.tableView(self, valueFor: column, row: row)
                let id = keys.id(level: level, value: value) { groupKey(of: value, in: column) }
                if id != keys.ids[level][handle] {
                    keys.ids[level][handle] = id
                    changed = true
                }
            }
        }
        // Only new keys add numbers, and they regroup: the tree is built again.
        if changed { keys.compactIfNeeded() }
        groupKeys = keys
        return changed
    }

    /// Makes the keys of some rows be read again (their values changed, or
    /// they were inserted).
    func invalidateGroupKeys(forRows rows: IndexSet) {
        guard groupKeys != nil, !rows.isEmpty else { return }
        groupKeysToRead.formUnion(rows)
    }

    /// A counting sort of `rows` by their key numbers: the keys in the order
    /// of their first row, where each one's rows start and how many there
    /// are, and the rows key after key in one flat array. `scratch` (zero
    /// for every key number) is left as it was. Plain buffer loops: this
    /// goes over every shown row.
    private nonisolated static func countingSort(_ rows: ArraySlice<Int>, ids: [Int32], scratch: inout [Int])
        -> (order: [Int], starts: [Int], counts: [Int], grouped: [Int]) {
        var order: [Int] = []
        scratch.withUnsafeMutableBufferPointer { slots in
            ids.withUnsafeBufferPointer { ids in
                for row in rows {
                    let id = Int(ids[row])
                    guard id >= 0 else { continue }
                    if slots[id] == 0 { order.append(id) }
                    slots[id] += 1
                }
            }
        }
        var starts: [Int] = [], counts: [Int] = []
        starts.reserveCapacity(order.count)
        counts.reserveCapacity(order.count)
        var total = 0
        for id in order {
            starts.append(total)
            counts.append(scratch[id])
            scratch[id] = total
            total += counts[counts.count - 1]
        }
        let grouped = [Int](unsafeUninitializedCapacity: total) { buffer, initialized in
            scratch.withUnsafeMutableBufferPointer { slots in
                ids.withUnsafeBufferPointer { ids in
                    for row in rows {
                        let id = Int(ids[row])
                        guard id >= 0 else { continue }
                        buffer[slots[id]] = row
                        slots[id] += 1
                    }
                }
            }
            initialized = total
        }
        for id in order { scratch[id] = 0 }
        return (order, starts, counts, grouped)
    }

    /// The innermost group of each row by handle (-1: not shown).
    private nonisolated static func leaves(of tree: NGGroupTree, rowCount: Int) -> [Int32] {
        var leaves = [Int32](repeating: -1, count: rowCount)
        leaves.withUnsafeMutableBufferPointer { leaves in
            tree.groupedRows.withUnsafeBufferPointer { groupedRows in
                for (index, node) in tree.nodes.enumerated() where node.children.isEmpty {
                    for position in node.rows {
                        let row = groupedRows[position]
                        guard row >= 0, row < rowCount else { continue }
                        leaves[row] = Int32(index)
                    }
                }
            }
        }
        return leaves
    }

    /// Gathers the shown rows into groups, level by level, in the order of
    /// their first row.
    private func buildGroupTree() {
        guard let keys = groupKeys else { return }
        var tree = NGGroupTree()
        let levels = keys.columnIDs.count
        // Per level, by key number: a group's row count, then where its next
        // row goes, while one group is split (reset after each split, so a
        // split costs its own rows only).
        var scratch = keys.keys.map { [Int](repeating: 0, count: $0.count) }

        func split(_ rows: ArraySlice<Int>, level: Int, parent: Int, path: [String]) -> Range<Int> {
            // Taken out while it changes (one owner, no copy).
            var slots = scratch[level]
            scratch[level] = []
            let (order, starts, counts, grouped) = Self.countingSort(rows, ids: keys.ids[level], scratch: &slots)
            scratch[level] = slots
            let columnIDs = Array(keys.columnIDs.prefix(level + 1))
            let start = tree.nodes.count
            for id in order {
                let group = NGRowGroup(columnIDs: columnIDs, path: path + [keys.keys[level][id]], value: keys.values[level][id])
                tree.nodeOfGroup[group] = tree.nodes.count
                tree.nodes.append(NGGroupNode(group: group, parent: parent, rows: 0..<0, children: 0..<0))
            }
            for index in order.indices {
                let node = start + index
                let rowStart = tree.groupedRows.count
                let bucketRows = grouped[starts[index]..<(starts[index] + counts[index])]
                if level + 1 < levels {
                    tree.nodes[node].children = split(bucketRows, level: level + 1, parent: node, path: tree.nodes[node].group.path)
                } else {
                    tree.groupedRows.append(contentsOf: bucketRows)
                }
                tree.nodes[node].rows = rowStart..<tree.groupedRows.count
            }
            return start..<(start + order.count)
        }

        // In display order: sorted by the table, or the data source's.
        let rowCount = rowHandles.capacity
        let shown = displayOrder ?? rowMap ?? allRowHandles
        tree.groupedRows.reserveCapacity(shown.count)
        tree.topLevel = split(shown[...], level: 0, parent: -1, path: [])
        tree.leafOfSourceRow = Self.leaves(of: tree, rowCount: rowCount)
        groupTree = tree
        groupTreeGeneration += 1
        // Subtotals kept to show while new ones are computed: only for groups
        // that still exist (live data would otherwise pile up old groups).
        if !previousGroupSubtotals.isEmpty {
            previousGroupSubtotals = previousGroupSubtotals.filter { tree.nodeOfGroup[$0.key] != nil }
        }
    }

    /// Lays out the headers and the rows of expanded groups.
    func buildGroupedDisplay() {
        let tree = groupTree
        var display: [Int] = []
        display.reserveCapacity(tree.groupedRows.count + tree.nodes.count)
        // Each shown header's display row and the display row after its
        // group, for floating headers (-1: not shown).
        var headerRows = [Int](repeating: -1, count: tree.nodes.count)
        var ends = [Int](repeating: -1, count: tree.nodes.count)
        func add(_ index: Int) {
            headerRows[index] = display.count
            display.append(-1 - index)
            let node = tree.nodes[index]
            defer { ends[index] = display.count }
            guard isGroupExpanded(node.group) else { return }
            if node.children.isEmpty {
                display.append(contentsOf: tree.groupedRows[node.rows])
            } else {
                for child in node.children { add(child) }
            }
        }
        for index in tree.topLevel { add(index) }
        groupHeaderDisplayRows = headerRows
        groupDisplayEnds = ends
        var positions = [Int](repeating: -1, count: rowHandles.capacity)
        for (displayRow, entry) in display.enumerated() where entry >= 0 {
            positions[entry] = displayRow
        }
        groupedDisplay = display
        displayRowOfSource = positions
        numberOfRows = display.count
    }

    // MARK: Groups (API)

    /// The outermost groups, in display order (empty without `rowGrouping`).
    public var topLevelGroups: [NGRowGroup] {
        groupTree.topLevel.map { groupTree.nodes[$0].group }
    }

    /// The groups within a group, in display order (empty at the innermost level).
    public func childGroups(of group: NGRowGroup) -> [NGRowGroup] {
        guard let index = groupTree.nodeOfGroup[group] else { return [] }
        return groupTree.nodes[index].children.map { groupTree.nodes[$0].group }
    }

    /// The data source rows of a group that the row filter shows.
    public func rowIndexes(in group: NGRowGroup) -> IndexSet {
        guard let index = groupTree.nodeOfGroup[group] else { return [] }
        return rowHandles.indexes(of: groupTree.groupedRows[groupTree.nodes[index].rows].lazy.map { Int32(truncatingIfNeeded: $0) })
    }

    /// The innermost group of a data source row, or `nil` if it isn't shown
    /// (or rows aren't grouped).
    public func group(forRow row: Int) -> NGRowGroup? {
        guard row >= 0, row < numberOfSourceRows else { return nil }
        let handle = handle(ofRow: row)
        guard handle < groupTree.leafOfSourceRow.count, groupTree.leafOfSourceRow[handle] >= 0 else { return nil }
        return groupTree.nodes[Int(groupTree.leafOfSourceRow[handle])].group
    }

    /// The group whose header row is at a point in the table's coordinates,
    /// or `nil` (like `row(at:)`, which gives -1 for header rows).
    public func group(at point: NSPoint) -> NGRowGroup? {
        let metrics = layoutMetrics
        guard rowHeight > 0, bounds.contains(point), point.y >= metrics.headerHeight,
              point.y < bounds.height - metrics.summaryHeight else { return nil }
        let row = displayRow(atCanvasY: centerRegion.canvas.convert(point, from: self).y)
        return groupNode(atDisplayRow: row).map { groupTree.nodes[$0].group }
    }

    /// Whether a group shows its rows (or subgroups), like `NSOutlineView`'s
    /// `isItemExpanded(_:)`.
    public func isGroupExpanded(_ group: NGRowGroup) -> Bool {
        toggledGroups.contains(group) != groupsExpandedByDefault
    }

    /// Expands a group, like `NSOutlineView.expandItem(_:expandChildren:)`;
    /// `expandChildren` also expands every group within it. `nil` with
    /// `expandChildren` expands every group, also ones that appear later;
    /// `nil` alone the outermost ones.
    public func expandGroup(_ group: NGRowGroup?, expandChildren: Bool = false) {
        setGroup(group, expanded: true, includingChildren: expandChildren)
    }

    /// Collapses a group, like `NSOutlineView.collapseItem(_:collapseChildren:)`;
    /// `collapseChildren` also collapses every group within it, so they are
    /// collapsed when it is expanded again. `nil` with `collapseChildren`
    /// collapses every group, also ones that appear later.
    public func collapseGroup(_ group: NGRowGroup?, collapseChildren: Bool = false) {
        setGroup(group, expanded: false, includingChildren: collapseChildren)
    }

    /// Posted after a group expanded, like `NSOutlineView.itemDidExpandNotification`.
    /// The object is the table; the userInfo has the group under `"NGRowGroup"`.
    public static let groupDidExpandNotification = Notification.Name("NGTableViewGroupDidExpandNotification")
    /// Posted after a group collapsed. The userInfo has the group under `"NGRowGroup"`.
    public static let groupDidCollapseNotification = Notification.Name("NGTableViewGroupDidCollapseNotification")

    private func setGroup(_ group: NGRowGroup?, expanded: Bool, includingChildren: Bool) {
        guard rowGrouping != nil else { return }
        let changed: [NGRowGroup]
        if group == nil, includingChildren {
            changed = groupTree.nodes.map(\.group).filter { isGroupExpanded($0) != expanded }
            groupsExpandedByDefault = expanded
            toggledGroups = []
        } else {
            let targets: [NGRowGroup] = if let group {
                includingChildren ? groupTree.nodes.map(\.group).filter { $0.isWithin(group) } : [group]
            } else {
                topLevelGroups
            }
            changed = targets.filter { isGroupExpanded($0) != expanded }
            for target in targets {
                if expanded == groupsExpandedByDefault {
                    toggledGroups.remove(target)
                } else {
                    toggledGroups.insert(target)
                }
            }
        }
        guard !changed.isEmpty else { return }
        updateDisplayedRows(rebuildingSummaries: false) { buildGroupedDisplay() }
        // The rows changed, the header cells didn't: the cells of all rows
        // were recycled, and the subtotals are kept.
        let name = expanded ? Self.groupDidExpandNotification : Self.groupDidCollapseNotification
        for group in changed where groupTree.nodeOfGroup[group] != nil {
            let notification = Notification(name: name, object: self, userInfo: ["NGRowGroup": group])
            if expanded {
                delegate?.tableViewGroupDidExpand(notification)
            } else {
                delegate?.tableViewGroupDidCollapse(notification)
            }
            NotificationCenter.default.post(notification)
        }
        NSAccessibility.post(element: self, notification: expanded ? .rowExpanded : .rowCollapsed)
    }

    /// A click on a header toggles its group; with Option, also every group within it.
    func toggleGroup(atDisplayRow row: Int, includingChildren: Bool) {
        guard let index = groupNode(atDisplayRow: row) else { return }
        let group = groupTree.nodes[index].group
        setGroup(group, expanded: !isGroupExpanded(group), includingChildren: includingChildren)
    }

    // MARK: Header rows

    /// A stable color object (rows compare them by identity).
    static let groupRowColor = NSColor.tertiarySystemFill

    /// Where the title of header rows goes: across the leading frozen
    /// columns (their subtotals give way to it; the title has the row count),
    /// or without frozen columns, the first scrolling columns up to the first
    /// one with a summary after the first.
    struct GroupTitleSpan {
        let pin: NGColumnPin
        let columnIDs: Set<String>
        let ordinal: Int
        let x: CGFloat
        let width: CGFloat
    }

    var groupTitleSpan: GroupTitleSpan? {
        let pin: NGColumnPin = geometry.leading.isEmpty ? .none : .leading
        let columns = geometry[pin].columns
        guard let first = columns.first else { return nil }
        var spanned = [first]
        for column in columns.dropFirst() {
            guard pin == .leading || !column.column.summary.hasValue else { break }
            spanned.append(column)
        }
        let last = spanned[spanned.count - 1]
        let x = CGFloat(first.x) + slideOffset(forColumnID: first.column.id)
        return GroupTitleSpan(pin: pin, columnIDs: Set(spanned.map(\.column.id)), ordinal: columnOrdinal(of: first.column.id),
                              x: x, width: CGFloat(last.maxX) - CGFloat(first.x))
    }

    /// The title of a group: the delegate's, or the displayed value.
    func title(of group: NGRowGroup) -> String {
        if let title = delegate?.tableView(self, titleFor: group) { return title }
        return group.key.isEmpty ? Self.noValueGroupTitle : group.key
    }

    static var noValueGroupTitle: String {
        String(localized: "No Value", bundle: .module, comment: "Group header for rows without a value in the grouping column.")
    }

    func groupTitleContent(ofNode index: Int) -> NGCellContent {
        let node = groupTree.nodes[index]
        let detail = rowGrouping?.showsRowCount ?? true ? node.rows.count.formatted(.number.locale(formattingLocale)) : ""
        return .groupTitle(NGGroupTitle(title: title(of: node.group), detail: detail, level: node.group.level,
                                        isExpanded: isGroupExpanded(node.group)))
    }

    /// The subtotals of a group by column id, as displayed: the summaries
    /// of its rows (the same aggregates and formulas as the summary row,
    /// over all of the group's rows, whatever the summary scope).
    func subtotalTexts(ofNode index: Int) -> [String: String] {
        if groupSubtotalsVersion != summaryValuesVersion {
            retireGroupSubtotals()
            groupSubtotalsVersion = summaryValuesVersion
        }
        let group = groupTree.nodes[index].group
        if let cached = groupSubtotals[group] { return cached }
        // Until a background computation is done, the values aren't all read:
        // the previous subtotals stay, like the summary row's values (e.g.
        // after a reload that only sorted the rows), rather than blinking.
        guard summaryTask == nil else { return previousGroupSubtotals[group] ?? [:] }
        let range = groupTree.nodes[index].rows
        let texts = subtotalStrings(of: group, rows: groupTree.groupedRows[range])
        groupSubtotals[group] = texts
        return texts
    }

    /// Keeps the current subtotals to show until new ones can be computed.
    func retireGroupSubtotals() {
        dropGroupCalculators(of: nil)
        guard !groupSubtotals.isEmpty else { return }
        previousGroupSubtotals.merge(groupSubtotals) { _, new in new }
        groupSubtotals = [:]
    }

    /// Text of a header row's cell, for VoiceOver.
    func groupCellText(ofNode index: Int, column: NGTableColumn) -> String? {
        if let span = groupTitleSpan, span.columnIDs.contains(column.id) {
            let node = groupTree.nodes[index]
            return "\(title(of: node.group)), \(node.rows.count.formatted(.number.locale(formattingLocale)))"
        }
        return subtotalTexts(ofNode: index)[column.id]
    }

    /// Places the cells of a header row: the title across its span, and
    /// subtotals in the other visible columns. Its other cells are recycled.
    func placeGroupCells(row: Int, node index: Int, columnsByRegion: [(NGRegionView, [PlacedColumn])]) {
        let span = groupTitleSpan
        let subtotals = subtotalTexts(ofNode: index)
        var needed = Set<NGCellKey>()
        for (region, columns) in columnsByRegion where !region.isHidden {
            for column in columns where !column.isHidden {
                let id = column.frame.column.id
                if let span, span.pin == region.pin, span.columnIDs.contains(id) {
                    let key = NGCellKey(row: row, column: span.ordinal)
                    guard needed.insert(key).inserted else { continue }
                    placeGroupCell(key, content: groupTitleContent(ofNode: index),
                                   frame: NSRect(x: span.x, y: rowGeometry.top(of: row), width: span.width, height: rowHeight),
                                   in: region.canvas)
                } else if let text = subtotals[id] {
                    let key = NGCellKey(row: row, column: column.ordinal)
                    needed.insert(key)
                    let alignment = column.frame.column.alignment.textAlignment(isNumeric: true, layoutDirection: contentLayoutDirection)
                    placeGroupCell(key, content: .subtotal(text, alignment: alignment),
                                   frame: NSRect(x: column.x, y: rowGeometry.top(of: row), width: CGFloat(column.frame.width), height: rowHeight),
                                   in: region.canvas)
                }
            }
        }
        recycleCells(ofRow: row, except: needed)
    }

    /// Recycles a row's visible cells, except some.
    func recycleCells(ofRow row: Int, except kept: Set<NGCellKey> = []) {
        for frame in geometry.leading.columns + geometry.center.columns + geometry.trailing.columns {
            let key = NGCellKey(row: row, column: columnOrdinal(of: frame.column.id))
            guard !kept.contains(key), let cell = visibleCells.removeValue(forKey: key) else { continue }
            recycle(cell)
        }
    }

    /// Visible header rows show new subtotals (the summarized values changed).
    func refreshGroupRows() {
        retireGroupSubtotals()
        groupSubtotalsVersion = summaryValuesVersion
        for key in visibleCells.keys where isGroupRow(key.row) {
            if let cell = visibleCells.removeValue(forKey: key) { recycle(cell) }
        }
        invalidateVisibleRange()
        needsLayout = true
    }

    // MARK: Menu

    /// The context menu of a header row: the table's own, as for the summary row.
    func groupMenu(forNode index: Int) -> NSMenu {
        let group = groupTree.nodes[index].group
        let menu = NSMenu()
        let toggle = NSMenuItem(
            title: isGroupExpanded(group)
                ? String(localized: "Collapse Group", bundle: .module, comment: "Group header context menu.")
                : String(localized: "Expand Group", bundle: .module, comment: "Group header context menu."),
            action: #selector(toggleGroupFromMenu(_:)), keyEquivalent: "")
        toggle.representedObject = GroupMenuTarget(group: group)
        menu.addItem(toggle)
        menu.addItem(.separator())
        let collapseAll = NSMenuItem(title: String(localized: "Collapse All Groups", bundle: .module, comment: "Group header context menu."),
                                     action: #selector(collapseAllGroupsFromMenu(_:)), keyEquivalent: "")
        let expandAll = NSMenuItem(title: String(localized: "Expand All Groups", bundle: .module, comment: "Group header context menu."),
                                   action: #selector(expandAllGroupsFromMenu(_:)), keyEquivalent: "")
        for item in [toggle, collapseAll, expandAll] { item.target = self }
        menu.addItem(collapseAll)
        menu.addItem(expandAll)
        return menu
    }

    @objc private func toggleGroupFromMenu(_ sender: NSMenuItem) {
        guard let group = (sender.representedObject as? GroupMenuTarget)?.group else { return }
        setGroup(group, expanded: !isGroupExpanded(group), includingChildren: false)
    }

    @objc private func collapseAllGroupsFromMenu(_ sender: NSMenuItem) {
        collapseGroup(nil, collapseChildren: true)
    }

    @objc private func expandAllGroupsFromMenu(_ sender: NSMenuItem) {
        expandGroup(nil, expandChildren: true)
    }
}

/// A group carried by a menu item (`representedObject` takes objects).
private final class GroupMenuTarget: NSObject {
    let group: NGRowGroup
    init(group: NGRowGroup) { self.group = group }
}
#endif
