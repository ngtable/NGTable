#if os(macOS)
import AppKit

// Selecting columns instead of rows, like NSTableView's column selection:
// with `allowsColumnSelection` a click on a column's header selects it
// (Command adds or removes it, Shift extends from the last one), and code
// selects columns by index. Rows or columns are selected, not both, and the
// change is one selection notice. Columns are kept by id, so they stay
// selected as they move; hidden ones aren't selected. Selected columns are
// tinted, header and rows, under the cells' content.

extension NGTableView {
    /// Whether clicking a column's header selects the column (and deselects
    /// the rows), like NSTableView's; `false` by default (NSTableView's is
    /// `true`, but its sorting tables usually turn it off).
    public var allowsColumnSelection: Bool {
        get { allowsColumnSelectionStorage }
        set { allowsColumnSelectionStorage = newValue }
    }

    /// The selected columns, as indexes of ``tableColumns``.
    public var selectedColumnIndexes: IndexSet {
        guard !selectedColumnIDs.isEmpty else { return [] }
        return IndexSet(tableColumns.enumerated().compactMap { index, column in
            selectedColumnIDs.contains(column.id) && !hiddenColumnIDs.contains(column.id) ? index : nil
        })
    }

    /// The last column selected or added to the selection, or -1, like
    /// NSTableView's `selectedColumn`.
    public var selectedColumn: Int {
        let selected = selectedColumnIndexes
        if let id = lastSelectedColumnID, let index = tableColumns.firstIndex(where: { $0.id == id }), selected.contains(index) {
            return index
        }
        return selected.last ?? -1
    }

    public var numberOfSelectedColumns: Int { selectedColumnIndexes.count }

    public func isColumnSelected(_ column: Int) -> Bool { selectedColumnIndexes.contains(column) }

    /// Selects columns (indexes of ``tableColumns``), adding them to the
    /// selected ones with `extend`; the rows are deselected.
    public func selectColumnIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        let all = tableColumns
        let ids = indexes.filter { $0 >= 0 && $0 < all.count }.map { all[$0].id }.filter { !hiddenColumnIDs.contains($0) }
        let base = extend ? Set(selectedColumnIndexes.map { all[$0].id }) : []
        setColumnSelection(base.union(ids), last: ids.last ?? lastSelectedColumnID)
    }

    /// Deselects a column.
    public func deselectColumn(_ column: Int) {
        let all = tableColumns
        guard column >= 0, column < all.count else { return }
        var ids = Set(selectedColumnIndexes.map { all[$0].id })
        ids.remove(all[column].id)
        setColumnSelection(ids, last: lastSelectedColumnID == all[column].id ? nil : lastSelectedColumnID)
    }

    /// A click on a header: selects its column, Command toggles it, Shift
    /// extends from the last column selected; the delegate may refuse it.
    func selectColumnByClicking(_ column: NGTableColumn, modifiers: NSEvent.ModifierFlags) {
        guard !ignoresUserInput, delegate?.tableView(self, shouldSelect: column) ?? true else { return }
        let all = tableColumns
        guard let index = all.firstIndex(where: { $0.id == column.id }) else { return }
        var ids = Set(selectedColumnIndexes.map { all[$0].id })
        if modifiers.contains(.command) {
            if ids.contains(column.id) { ids.remove(column.id) } else { ids.insert(column.id) }
            setColumnSelection(ids, last: ids.contains(column.id) ? column.id : nil)
        } else if modifiers.contains(.shift), let last = selectedColumn >= 0 ? selectedColumn : nil {
            let range = min(last, index)...max(last, index)
            let added = range.map { all[$0] }.filter { !hiddenColumnIDs.contains($0.id) && (delegate?.tableView(self, shouldSelect: $0) ?? true) }
            setColumnSelection(ids.union(added.map(\.id)), last: column.id)
        } else {
            setColumnSelection([column.id], last: column.id)
        }
    }

    /// Sets the selected columns (deselecting the rows) and tells of it.
    private func setColumnSelection(_ ids: Set<String>, last: String?) {
        let rowsGo = !ids.isEmpty && !displaySelection.isEmpty
        guard ids != selectedColumnIDs || rowsGo else { return }
        selectedColumnIDs = ids
        lastSelectedColumnID = ids.isEmpty ? nil : last
        if rowsGo {
            displaySelection = []
            rememberSelectionIdentity()
            if summaryScope != .allRows { updateSummary() }
            NSAccessibility.post(element: self, notification: .selectedRowsChanged)
        }
        refreshSelectionAppearance()
        NSAccessibility.post(element: self, notification: .selectedColumnsChanged)
        postSelectionNotification(Self.selectionDidChangeNotification)
    }

    /// Deselects the columns without telling (the rows' change tells).
    func clearColumnSelection() {
        selectedColumnIDs = []
        lastSelectedColumnID = nil
        NSAccessibility.post(element: self, notification: .selectedColumnsChanged)
    }

    func columnSelectionTint(_ style: MetalStyle) -> SIMD4<Float> {
        style.color(.selectedContentBackgroundColor) * 0.22
    }

    /// Tints the selected columns of a region over the rows, under the cells' content.
    func appendColumnSelectionTint(style: MetalStyle, scale: CGFloat, in region: NGRegionView, origin: CGPoint, clip: CGRect,
                                   to quads: inout [NGMetalQuad]) {
        guard !selectedColumnIDs.isEmpty else { return }
        let color = columnSelectionTint(style)
        for frame in geometry[region.pin].columns where selectedColumnIDs.contains(frame.column.id) {
            let x = origin.x + CGFloat(frame.x) + slideOffset(forColumnID: frame.column.id)
            let rect = NSRect(x: x, y: clip.minY, width: CGFloat(frame.width), height: clip.height)
            let visible = rect.intersection(clip)
            guard !visible.isEmpty else { continue }
            quads.append(NGMetalRenderer.rectangle(visible, scale: scale, color: color, clip: visible))
        }
    }
}
#endif
