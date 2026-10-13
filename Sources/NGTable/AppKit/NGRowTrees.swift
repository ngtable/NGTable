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
// rows after each change of the shown rows.

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
            if treeParentHandles[handle] != before.0 { treeReparentedHandles.append(handle) }
            if notesFlips, (before.0 >= 0) != (treeParentHandles[handle] >= 0) { treeSummaryFlips.append(handle) }
        }
        treeParentsToRead = []
        // New rows (children may be waiting for them) and removed ones
        // (their handles may be reused): parents are looked up again.
        let structural = rowsInsertedSinceTreeLayout || !treeRemovedHandles.isEmpty
        rowsInsertedSinceTreeLayout = false
        guard structural else { return changed }
        let removed = treeRemovedHandles
        treeRemovedHandles = []
        for handle in 0..<capacity {
            guard let identity = treeParentIdentities[handle] else { continue }
            let parent = treeParentHandles[handle]
            if parent < 0 || removed.contains(parent) {
                treeParentHandles[handle] = self.handle(forIdentifier: identity) ?? -1
                if treeParentHandles[handle] != parent { treeReparentedHandles.append(handle) }
                if notesFlips, (parent >= 0) != (treeParentHandles[handle] >= 0), row(ofHandle: handle) >= 0 {
                    treeSummaryFlips.append(handle)
                }
            }
        }
        return true
    }

    private func readTreeParent(ofHandle handle: Int, row: Int, dataSource: NGTableViewDataSource) {
        let identity = dataSource.tableView(self, parentIdentifierForRow: row)
        treeParentIdentities[handle] = identity
        treeParentHandles[handle] = identity.flatMap { self.handle(forIdentifier: $0) } ?? -1
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
        var positions = [Int](repeating: -1, count: capacity)
        for (displayRow, handle) in display.enumerated() { positions[handle] = displayRow }
        groupedDisplay = display
        displayRowOfSource = positions
        numberOfRows = display.count
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
