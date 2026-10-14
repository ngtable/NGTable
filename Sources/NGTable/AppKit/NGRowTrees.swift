#if os(macOS)
import AppKit

// Rows as a tree (`NGTableView.rowTree`), like NSOutlineView: each row names
// its parent by identity, and the display rows are the rows of expanded
// parents, depth first, siblings in the table's order (sorted or the data
// source's). The filter shows the rows it lets through with their ancestors,
// so their path stays visible. Display rows are data source rows only (no
// headers): the selection, the data source and the summaries work as without
// a tree. The outline column draws each row indented by its depth, with a
// disclosure triangle for rows with children; clicking it, or Left and Right
// on the row, collapses and expands (with Option, the rows within too).
//
// Parents are kept by row handle and read once per reload, then only for
// rows inserted or changed; a parent removed (and its handle maybe reused)
// is looked up again by identity. Laying out the tree is a pass over the
// rows after each change of the shown rows, except for a feed's few rows
// inserted and removed (without a filter, rows moving or other rows getting
// other parents): those are placed among their siblings and in the display
// rows alone (`layOutTreeEdits`; 200,000 rows: 5.2 ms a batch to 0.76 ms).

extension NGTableView {
    /// Whether the rows show as a tree now (a grouping takes its place).
    var isShowingRowTree: Bool { rowTree != nil && rowGrouping == nil && dataSource != nil }

    // MARK: Parents

    /// Reads the parents of all rows after a reload, otherwise of the rows
    /// inserted or changed since, and looks up again those whose parent was
    /// removed or not there yet. Returns whether any row's parent changed.
    @discardableResult
    func readTreeParents() -> Bool {
        guard let dataSource else { return false }
        let capacity = rowHandles.capacity
        updateIdentityIndex()
        if treeParentHandles.isEmpty {
            treeEdits = nil
            treeHasOrphans = false
            treeParentHandles = [Int32](repeating: -1, count: capacity)
            treeParentIdentities = [AnyHashable?](repeating: nil, count: capacity)
            for row in 0..<numberOfSourceRows {
                readTreeParent(ofHandle: Int(rowHandles.handle(at: row)), row: row, dataSource: dataSource)
            }
            treeParentsToRead = []
            treeRemovedHandles = []
            return true
        }
        if treeParentHandles.count < capacity {
            treeParentHandles.append(contentsOf: repeatElement(-1, count: capacity - treeParentHandles.count))
            treeParentIdentities.append(contentsOf: repeatElement(nil, count: capacity - treeParentIdentities.count))
        }
        var changed = false
        let notesFlips = rowTree?.summaryRows == .topLevelRows
        for handle in treeParentsToRead where handle < capacity {
            let row = row(ofHandle: handle)
            guard row >= 0 else { continue }
            let before = (treeParentHandles[handle], treeParentIdentities[handle])
            readTreeParent(ofHandle: handle, row: row, dataSource: dataSource)
            if treeParentHandles[handle] != before.0 || treeParentIdentities[handle] != before.1 { changed = true }
            if treeParentHandles[handle] != before.0 {
                treeReparentedHandles.append(handle)
                noteTreeReparented(handle)
            }
            if notesFlips, (before.0 >= 0) != (treeParentHandles[handle] >= 0) { treeSummaryFlips.append(handle) }
        }
        treeParentsToRead = []
        // New rows (children may be waiting for them) and removed ones
        // (their handles may be reused): parents are looked up again.
        let structural = rowsInsertedSinceTreeLayout || !treeRemovedHandles.isEmpty
        rowsInsertedSinceTreeLayout = false
        guard structural else { return changed }
        // No row waits for its parent, and the removed rows had no children
        // (the last layout's, which has every row's without a filter, and
        // those of rows inserted since): nothing to look up again.
        if !treeHasOrphans, rowMap == nil, let edits = treeEdits {
            let laidOut = treeChildStarts.count - 1
            let childless = treeRemovedHandles.allSatisfy { handle in
                Int(handle) < laidOut && treeChildStarts[Int(handle) + 1] == treeChildStarts[Int(handle)]
            }
            if childless, !edits.inserted.contains(where: { treeRemovedHandles.contains(treeParentHandles[Int($0)]) }) {
                treeRemovedHandles = []
                return true
            }
        }
        // Removed handles marked, rows checked by their parent first (a hash
        // or a copy of every row's parent identity cost ~2 ms on 200,000 rows).
        var isRemoved: [Bool] = []
        if !treeRemovedHandles.isEmpty {
            isRemoved = [Bool](repeating: false, count: capacity)
            for handle in treeRemovedHandles where handle >= 0 && Int(handle) < capacity { isRemoved[Int(handle)] = true }
        }
        treeRemovedHandles = []
        // Rows without a parent, or whose parent went (one pass in place).
        var candidates: [Int] = []
        treeParentHandles.withUnsafeBufferPointer { parents in
            isRemoved.withUnsafeBufferPointer { isRemoved in
                for handle in 0..<min(capacity, parents.count) {
                    let parent = Int(parents[handle])
                    if parent >= 0, parent >= isRemoved.count || !isRemoved[parent] { continue }
                    candidates.append(handle)
                }
            }
        }
        treeHasOrphans = false
        for handle in candidates {
            let parent = treeParentHandles[handle]
            guard let identity = treeParentIdentities[handle] else { continue }
            treeParentHandles[handle] = self.handle(forIdentifier: identity) ?? -1
            if treeParentHandles[handle] < 0 { treeHasOrphans = true }
            if treeParentHandles[handle] != parent {
                treeReparentedHandles.append(handle)
                noteTreeReparented(handle)
            }
            if notesFlips, (parent >= 0) != (treeParentHandles[handle] >= 0), row(ofHandle: handle) >= 0 {
                treeSummaryFlips.append(handle)
            }
        }
        return true
    }

    /// A row inserted or removed: placed alone at the next layout, unless
    /// there are many (then all are laid out again).
    func noteTreeEdit(inserted: Int32? = nil, removed: Int32? = nil) {
        guard var edits = treeEdits else { return }
        if let inserted { edits.inserted.append(inserted) }
        if let removed { edits.removed.append(removed) }
        treeEdits = edits.inserted.count + edits.removed.count <= Self.treeEditLimit ? edits : nil
    }

    /// Edits placed alone at most; more are laid out with the whole tree.
    static let treeEditLimit = 32

    /// A row got another parent: unless it's a new row, the tree is laid out again.
    private func noteTreeReparented(_ handle: Int) {
        guard let edits = treeEdits, !edits.inserted.contains(Int32(truncatingIfNeeded: handle)) else { return }
        treeEdits = nil
    }

    private func readTreeParent(ofHandle handle: Int, row: Int, dataSource: NGTableViewDataSource) {
        let identity = dataSource.tableView(self, parentIdentifierForRow: row)
        treeParentIdentities[handle] = identity
        treeParentHandles[handle] = identity.flatMap { self.handle(forIdentifier: $0) } ?? -1
        if identity != nil, treeParentHandles[handle] < 0 { treeHasOrphans = true }
    }

    // MARK: Layout

    /// Lays out the rows of expanded parents, depth first.
    func buildTreeDisplay(readingParents: Bool = true) {
        if readingParents { readTreeParents() }
        let capacity = rowHandles.capacity
        let parents = treeParentHandles
        // The filter's rows and their ancestors (all rows without a filter).
        var included: [Bool]?
        if let rowMap {
            var marks = [Bool](repeating: false, count: capacity)
            for handle in rowMap {
                var next = handle, steps = 0
                while next >= 0, next < capacity, !marks[next], steps <= capacity {
                    marks[next] = true
                    next = Int(parents[next])
                    steps += 1
                }
            }
            included = marks
        }
        // All rows in the table's order (ancestors the filter hides too).
        let order = sortedRows ?? allRowHandles
        // Children by parent, in order (counts, then starts, then rows).
        var starts = [Int](repeating: 0, count: capacity + 1)
        var roots: [Int32] = []
        func parent(of handle: Int) -> Int {
            let parent = Int(parents[handle])
            guard parent >= 0, parent != handle, included?[parent] ?? true else { return -1 }
            return parent
        }
        for handle in order where included?[handle] ?? true {
            let parent = parent(of: handle)
            if parent >= 0 { starts[parent + 1] += 1 } else { roots.append(Int32(handle)) }
        }
        for index in 0..<capacity { starts[index + 1] += starts[index] }
        var children = [Int32](repeating: 0, count: starts[capacity])
        var fill = starts
        for handle in order where included?[handle] ?? true {
            let parent = parent(of: handle)
            guard parent >= 0 else { continue }
            children[fill[parent]] = Int32(handle)
            fill[parent] += 1
        }
        // Depth first; rows in a cycle of parents have no root and stay out.
        var display: [Int] = []
        display.reserveCapacity(order.count)
        var levels = [Int32](repeating: -1, count: capacity)
        var stack: [(handle: Int32, level: Int32)] = roots.reversed().map { ($0, 0) }
        while let (handle, level) = stack.popLast() {
            let index = Int(handle)
            display.append(index)
            levels[index] = level
            guard starts[index + 1] > starts[index], isTreeRowExpanded(handle: index) else { continue }
            for child in children[starts[index]..<starts[index + 1]].reversed() {
                stack.append((child, level + 1))
            }
        }
        treeLevels = levels
        treeChildStarts = starts
        treeChildren = children
        treeRoots = roots
        treeEdits = ([], [])
        var positions = [Int](repeating: -1, count: capacity)
        for (displayRow, handle) in display.enumerated() { positions[handle] = displayRow }
        groupedDisplay = display
        displayRowOfSource = positions
        numberOfRows = display.count
    }

    /// Places the rows inserted and removed since the last layout alone:
    /// among their siblings (in the table's order), and in the display rows
    /// if their parent shows its children. Returns `false`, changing
    /// nothing, when the edits aren't such (a removed row with children, a
    /// new row under another new or removed one, a row not where the last
    /// layout put it): the whole tree is laid out then.
    ///
    /// (If it finds out only after changing things, the whole layout that
    /// follows makes everything again from the parents.)
    func layOutTreeEdits(inserted: [Int32], removed: [Int32]) -> Bool {
        guard groupedDisplay != nil else { return false }
        let capacity = rowHandles.capacity
        let laidOut = treeChildStarts.count - 1
        guard laidOut >= 0, treeLevels.count == laidOut, displayRowOfSource.count == laidOut else { return false }
        let insertedSet = Set(inserted), removedSet = Set(removed)
        guard insertedSet.isDisjoint(with: removedSet) else { return false }
        // Where each removed row is among its siblings (checked before anything changes).
        func siblings(of parent: Int) -> Range<Int>? {
            parent < 0 ? nil : treeChildStarts[parent]..<treeChildStarts[parent + 1]
        }
        for handle in removed {
            let index = Int(handle)
            guard index < laidOut, treeChildStarts[index + 1] == treeChildStarts[index] else { return false }
            let parent = Int(treeParentHandles[index])
            guard parent < laidOut, !removedSet.contains(Int32(parent)) else { return false }
            if let range = siblings(of: parent) {
                guard treeChildren[range].contains(handle) else { return false }
            } else if !treeRoots.contains(handle) {
                return false
            }
        }
        for handle in inserted {
            let index = Int(handle)
            guard index < capacity, index >= laidOut || treeChildStarts[index + 1] == treeChildStarts[index] else { return false }
            let parent = treeParentHandles[index]
            guard Int(parent) < laidOut, !insertedSet.contains(parent), !removedSet.contains(parent) else { return false }
        }

        // Taken out, so changing them doesn't copy them.
        var display = groupedDisplay!
        groupedDisplay = nil
        var positions = displayRowOfSource
        displayRowOfSource = []
        var levels = treeLevels
        treeLevels = []
        // Room for handles beyond the last layout's.
        if capacity > laidOut {
            positions.append(contentsOf: repeatElement(-1, count: capacity - laidOut))
            levels.append(contentsOf: repeatElement(-1, count: capacity - laidOut))
            treeChildStarts.append(contentsOf: repeatElement(treeChildren.count, count: capacity - laidOut))
        }
        func removeChild(_ handle: Int32, of parent: Int) {
            if parent < 0 {
                treeRoots.remove(at: treeRoots.firstIndex(of: handle)!)
                return
            }
            let range = treeChildStarts[parent]..<treeChildStarts[parent + 1]
            treeChildren.remove(at: treeChildren[range].firstIndex(of: handle)!)
            shiftChildStarts(after: parent, by: -1)
        }
        // The children of the rows after a parent start one earlier or later.
        func shiftChildStarts(after parent: Int, by delta: Int) {
            treeChildStarts.withUnsafeMutableBufferPointer { starts in
                for later in (parent + 1)..<starts.count { starts[later] += delta }
            }
        }

        // The display rows changed so far, in order: a row's place known
        // before one is one less after a row before it went out, one more
        // after a row came in at or before it. (Places are made right once,
        // at the end, from the first change on.)
        var changes: [(at: Int, isInsert: Bool)] = []
        var changeOf: [Int32: Int] = [:]
        func current(_ handle: Int32) -> Int {
            var position: Int
            var from: Int
            if let change = changeOf[handle] {
                position = changes[change].at
                from = change + 1
            } else {
                position = positions[Int(handle)]
                from = 0
                guard position >= 0 else { return -1 }
            }
            for change in changes[from...] {
                if change.isInsert { if position >= change.at { position += 1 } } else if position > change.at { position -= 1 }
            }
            return position
        }

        // Removed rows out, the last shown first (the others' places stay).
        var lowest = display.count
        for handle in removed.sorted(by: { positions[Int($0)] > positions[Int($1)] }) {
            let index = Int(handle)
            if positions[index] >= 0 {
                display.remove(at: positions[index])
                lowest = min(lowest, positions[index])
                changes.append((positions[index], false))
            }
            positions[index] = -1
            levels[index] = -1
            removeChild(handle, of: Int(treeParentHandles[index]))
        }

        // New rows in: their place in the table's order among their siblings.
        let sorted = sortedOrder
        func rank(_ handle: Int32) -> Int {
            sorted?.index(of: handle) ?? row(ofHandle: Int(handle))
        }
        /// The first of rows in order that comes after `key` (a binary search).
        func firstAfter(_ key: Int, in rows: ArraySlice<Int32>) -> Int {
            var low = rows.startIndex, high = rows.endIndex
            while low < high {
                let middle = (low + high) / 2
                if rank(rows[middle]) > key { high = middle } else { low = middle + 1 }
            }
            return low
        }
        for handle in inserted {
            let index = Int(handle)
            let parent = Int(treeParentHandles[index])
            let key = rank(handle)
            // Among the siblings, before the first that comes after it.
            var place: Int
            var next: Int32?
            if parent < 0 {
                place = firstAfter(key, in: treeRoots[...])
                next = place < treeRoots.count ? treeRoots[place] : nil
                treeRoots.insert(handle, at: place)
            } else {
                let range = treeChildStarts[parent]..<treeChildStarts[parent + 1]
                place = firstAfter(key, in: treeChildren[range])
                next = place < range.upperBound ? treeChildren[place] : nil
                treeChildren.insert(handle, at: place)
                shiftChildStarts(after: parent, by: 1)
            }
            // Shown if its parent shows its children (top-level rows always).
            let parentShown = parent < 0 || (levels[parent] >= 0 && current(Int32(parent)) >= 0 && isTreeRowExpanded(handle: parent))
            guard parentShown else { continue }
            var at: Int
            if let next {
                at = current(next)
            } else if parent < 0 {
                at = display.count
            } else {
                // After the parent's shown rows.
                at = current(Int32(parent)) + 1
                while at < display.count, levels[display[at]] > levels[parent] { at += 1 }
            }
            guard at >= 0 else { return false }
            display.insert(index, at: at)
            levels[index] = parent < 0 ? 0 : levels[parent] + 1
            changeOf[handle] = changes.count
            changes.append((at, true))
            lowest = min(lowest, at)
        }
        if lowest < display.count {
            for displayRow in lowest..<display.count { positions[display[displayRow]] = displayRow }
        }
        treeLevels = levels
        groupedDisplay = display
        displayRowOfSource = positions
        numberOfRows = display.count
        treeEdits = ([], [])
        treeEditLayoutsForTesting += 1
        return true
    }

    /// Whether a row (by handle) shows its children.
    func isTreeRowExpanded(handle: Int) -> Bool {
        guard let identity = identityIndex?.identity(of: Int32(handle)) else { return treeExpandedByDefault }
        return toggledTreeRows.contains(identity) != treeExpandedByDefault
    }

    /// A handle's shown children, in order.
    private func treeChildHandles(of handle: Int) -> ArraySlice<Int32> {
        guard handle >= 0, handle + 1 < treeChildStarts.count else { return [] }
        return treeChildren[treeChildStarts[handle]..<treeChildStarts[handle + 1]]
    }

    // MARK: Outline cells

    /// The column with the indentation and the triangles.
    var outlineColumnID: String? {
        rowTree?.outlineColumnID ?? (columnLayout.leading.columns.first ?? columnLayout.center.columns.first
            ?? columnLayout.trailing.columns.first)?.id
    }

    /// The outline of a cell, for the outline column of a tree.
    func outline(forDisplayRow displayRow: Int, column: NGTableColumn) -> NGOutline? {
        guard isShowingRowTree, column.id == outlineColumnID, let groupedDisplay,
              displayRow >= 0, displayRow < groupedDisplay.count else { return nil }
        let handle = groupedDisplay[displayRow]
        guard handle >= 0, handle < treeLevels.count else { return nil }
        let hasChildren = !treeChildHandles(of: handle).isEmpty
        return NGOutline(level: Int(treeLevels[handle]), hasChildren: hasChildren,
                         isExpanded: hasChildren && isTreeRowExpanded(handle: handle))
    }

    /// Where an outline cell's content starts, after its indentation and triangle.
    static func outlineContentInset(_ outline: NGOutline) -> CGFloat {
        CGFloat(outline.level) * NGMetrics.groupIndent + NGMetrics.disclosureWidth + NGMetrics.groupTitleSpacing
    }

    /// Whether a click in the window hits the triangle of a row; the row's
    /// handle if so.
    func treeDisclosureHit(atWindowLocation location: NSPoint, displayRow: Int) -> Int? {
        guard isShowingRowTree, let columnID = outlineColumnID, let groupedDisplay,
              displayRow >= 0, displayRow < groupedDisplay.count,
              let column = tableColumns.first(where: { $0.id == columnID }),
              let outline = outline(forDisplayRow: displayRow, column: column), outline.hasChildren else { return nil }
        let row = sourceRow(displayRow)
        guard let frame = frameOfCell(row: row, columnID: columnID) else { return nil }
        let x = frame.minX + NGMetrics.cellPadding + CGFloat(outline.level) * NGMetrics.groupIndent
        var box = NSRect(x: x - 4, y: frame.minY, width: NGMetrics.disclosureWidth + 8, height: frame.height)
        // Right to left, mirrored within the cell, like what it draws.
        if isRightToLeft { box.origin.x = frame.minX + frame.maxX - box.maxX }
        return box.contains(convert(location, from: nil)) ? groupedDisplay[displayRow] : nil
    }

    // MARK: Expanding and collapsing

    /// Expands or collapses a row (by handle), with Option the rows within it
    /// too. The user's changes (`byUser`) ask the delegate first.
    func setTreeRow(handle: Int, expanded: Bool, includingChildren: Bool, byUser: Bool = false) {
        guard isShowingRowTree else { return }
        var targets = [handle]
        if includingChildren {
            var index = 0
            while index < targets.count {
                targets.append(contentsOf: treeChildHandles(of: targets[index]).map(Int.init))
                index += 1
            }
        }
        var changed: [AnyHashable] = []
        for target in targets where !treeChildHandles(of: target).isEmpty {
            guard let identity = identityIndex?.identity(of: Int32(target)), isTreeRowExpanded(handle: target) != expanded else { continue }
            if byUser, let delegate {
                let row = row(ofHandle: target)
                let allowed = expanded ? delegate.tableView(self, shouldExpandRow: row) : delegate.tableView(self, shouldCollapseRow: row)
                // A row refused: the rows within it are still asked, unless it's the one the user acted on.
                guard allowed else {
                    if target == handle { return }
                    continue
                }
            }
            changed.append(identity)
        }
        guard !changed.isEmpty else { return }
        let notifications = changed.map { identity in
            (will: Notification(name: expanded ? Self.rowWillExpandNotification : Self.rowWillCollapseNotification,
                                object: self, userInfo: ["NGRowIdentifier": identity]),
             did: Notification(name: expanded ? Self.rowDidExpandNotification : Self.rowDidCollapseNotification,
                               object: self, userInfo: ["NGRowIdentifier": identity]))
        }
        for (will, _) in notifications {
            if expanded { delegate?.tableViewRowWillExpand(will) } else { delegate?.tableViewRowWillCollapse(will) }
            NotificationCenter.default.post(will)
        }
        for identity in changed {
            if expanded == treeExpandedByDefault {
                toggledTreeRows.remove(identity)
            } else {
                toggledTreeRows.insert(identity)
            }
        }
        updateDisplayedRows(rebuildingSummaries: false) { buildTreeDisplay() }
        saveExpandedRows()
        for (_, did) in notifications {
            if expanded { delegate?.tableViewRowDidExpand(did) } else { delegate?.tableViewRowDidCollapse(did) }
            NotificationCenter.default.post(did)
        }
        NSAccessibility.post(element: self, notification: expanded ? .rowExpanded : .rowCollapsed)
    }

    /// Posted before a row of a tree expands, like `NSOutlineView.itemWillExpandNotification`.
    /// The userInfo has the row's identity under `"NGRowIdentifier"`.
    public static let rowWillExpandNotification = Notification.Name("NGTableViewRowWillExpandNotification")
    /// Posted before a row of a tree collapses.
    public static let rowWillCollapseNotification = Notification.Name("NGTableViewRowWillCollapseNotification")

    /// Posted after a row of a tree expanded, like `NSOutlineView.itemDidExpandNotification`.
    /// The userInfo has the row's identity under `"NGRowIdentifier"`.
    public static let rowDidExpandNotification = Notification.Name("NGTableViewRowDidExpandNotification")
    /// Posted after a row of a tree collapsed.
    public static let rowDidCollapseNotification = Notification.Name("NGTableViewRowDidCollapseNotification")

    /// Whether a data source row has children shown in the tree, like
    /// `NSOutlineView.isExpandable(_:)`.
    public func isRowExpandable(_ row: Int) -> Bool {
        guard isShowingRowTree, row >= 0, row < numberOfSourceRows else { return false }
        return !treeChildHandles(of: handle(ofRow: row)).isEmpty
    }

    /// Whether a row of the tree shows its children, like `isItemExpanded(_:)`.
    public func isRowExpanded(_ row: Int) -> Bool {
        guard isRowExpandable(row) else { return false }
        return isTreeRowExpanded(handle: handle(ofRow: row))
    }

    /// Expands a row of the tree, like `NSOutlineView.expandItem(_:expandChildren:)`.
    public func expandRow(_ row: Int, expandChildren: Bool = false) {
        guard row >= 0, row < numberOfSourceRows else { return }
        setTreeRow(handle: handle(ofRow: row), expanded: true, includingChildren: expandChildren)
    }

    /// Collapses a row of the tree, like `NSOutlineView.collapseItem(_:collapseChildren:)`.
    public func collapseRow(_ row: Int, collapseChildren: Bool = false) {
        guard row >= 0, row < numberOfSourceRows else { return }
        setTreeRow(handle: handle(ofRow: row), expanded: false, includingChildren: collapseChildren)
    }

    /// How deep a row is in the tree (0 at the top), or -1 if it isn't shown,
    /// like `NSOutlineView.level(forRow:)` (but a data source row).
    public func level(forRow row: Int) -> Int {
        guard isShowingRowTree, row >= 0, row < numberOfSourceRows else { return -1 }
        let handle = handle(ofRow: row)
        return handle < treeLevels.count ? Int(treeLevels[handle]) : -1
    }

    /// The data source row of a row's parent, or -1 at the top, like
    /// `NSOutlineView.parent(forItem:)`.
    public func parentRow(forRow row: Int) -> Int {
        guard isShowingRowTree, row >= 0, row < numberOfSourceRows else { return -1 }
        let handle = handle(ofRow: row)
        guard handle < treeParentHandles.count, treeParentHandles[handle] >= 0 else { return -1 }
        return self.row(ofHandle: Int(treeParentHandles[handle]))
    }

    /// The data source rows of a row's children shown in the tree, in order.
    public func childRows(ofRow row: Int) -> [Int] {
        guard isShowingRowTree, row >= 0, row < numberOfSourceRows else { return [] }
        return treeChildHandles(of: handle(ofRow: row)).map { self.row(ofHandle: Int($0)) }
    }

    // MARK: Saving

    /// The defaults key of the saved expansion (see `autosaveExpandedItems`).
    private var expandedRowsKey: String? {
        guard autosaveExpandedItems, let autosaveName else { return nil }
        return "NGTableView Expanded Rows \(autosaveName)"
    }

    /// Saved apart for trees that start expanded and collapsed: the rows are
    /// those toggled from that.
    private var expandedRowsSlot: String { treeExpandedByDefault ? "startsExpanded" : "startsCollapsed" }

    /// Saves the rows toggled from the tree's default, those whose identity
    /// is a string or an integer.
    func saveExpandedRows() {
        guard let key = expandedRowsKey else { return }
        let identities: [Any] = toggledTreeRows.compactMap { identity in
            switch identity.base {
            case let text as String: text
            case let number as Int: number
            default: nil
            }
        }
        var saved = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        saved[expandedRowsSlot] = identities
        UserDefaults.standard.set(saved, forKey: key)
    }

    /// Reads the saved expansion for the tree's default, if any; returns
    /// whether it did.
    @discardableResult
    func restoreExpandedRows() -> Bool {
        guard let key = expandedRowsKey,
              let saved = UserDefaults.standard.dictionary(forKey: key)?[expandedRowsSlot] as? [Any] else { return false }
        toggledTreeRows = Set(saved.compactMap { value -> AnyHashable? in
            switch value {
            case let text as String: AnyHashable(text)
            case let number as Int: AnyHashable(number)
            default: nil
            }
        })
        return true
    }

    // MARK: Keyboard

    /// Left on a row of a tree: collapses it, or goes to its parent.
    func collapseOrGoToParent(includingChildren: Bool) -> Bool {
        guard isShowingRowTree, !navigatesByCell, let cursor = cursorRow, let groupedDisplay,
              cursor >= 0, cursor < groupedDisplay.count else { return false }
        let handle = groupedDisplay[cursor]
        if !treeChildHandles(of: handle).isEmpty, isTreeRowExpanded(handle: handle) || includingChildren {
            setTreeRow(handle: handle, expanded: false, includingChildren: includingChildren, byUser: true)
        } else if handle < treeParentHandles.count, treeParentHandles[handle] >= 0,
                  let parentRow = displayRow(forSourceRow: row(ofHandle: Int(treeParentHandles[handle]))) {
            selectByKeyboard(displayRow: parentRow)
        }
        return true
    }

    /// Right on a row of a tree: expands it, or goes to its first child.
    func expandOrGoToChild(includingChildren: Bool) -> Bool {
        guard isShowingRowTree, !navigatesByCell, let cursor = cursorRow, let groupedDisplay,
              cursor >= 0, cursor < groupedDisplay.count else { return false }
        let handle = groupedDisplay[cursor]
        let children = treeChildHandles(of: handle)
        guard let first = children.first else { return true }
        if !isTreeRowExpanded(handle: handle) || includingChildren {
            setTreeRow(handle: handle, expanded: true, includingChildren: includingChildren, byUser: true)
        } else if let childRow = displayRow(forSourceRow: row(ofHandle: Int(first))) {
            selectByKeyboard(displayRow: childRow)
        }
        return true
    }

    private func selectByKeyboard(displayRow: Int) {
        anchorRow = displayRow
        cursorRow = displayRow
        setSelection([displayRow], byUser: true)
        scrollDisplayRowToVisible(displayRow)
    }

    // MARK: Summaries

    /// Whether the summaries count only some of a tree's rows, which depend
    /// on the filter (see `treeExcludesFromSummaries`).
    var treeSummariesCountTopLevel: Bool { rowTree?.summaryRows == .topLevelRows && isShowingRowTree }

    /// Whether a row's numbers stay out of the summaries when only the top
    /// level is counted: rows with a parent; with a filter, rows with an
    /// ancestor the filter shows too (a match under a parent shown only for
    /// context counts, so totals have the matches, each once).
    func treeExcludesFromSummaries(handle: Int) -> Bool {
        guard treeSummariesCountTopLevel, handle < treeParentHandles.count else { return false }
        guard rowMap != nil, let matches = filterMatches else { return treeParentHandles[handle] >= 0 }
        var next = Int(treeParentHandles[handle]), steps = 0
        while next >= 0, next < treeParentHandles.count, steps < treeParentHandles.count {
            if next < matches.count, matches[next] { return true }
            next = Int(treeParentHandles[next])
            steps += 1
        }
        return false
    }

    /// Leaves out of summarized values (by handle) the rows the tree doesn't count.
    func maskTreeSummaryValues(_ values: inout [Double]) {
        guard treeSummariesCountTopLevel else { return }
        treeSummaryMasksWereFiltered = rowMap != nil
        for handle in 0..<min(values.count, treeParentHandles.count) where treeExcludesFromSummaries(handle: handle) {
            values[handle] = .nan
        }
    }
}
#endif
