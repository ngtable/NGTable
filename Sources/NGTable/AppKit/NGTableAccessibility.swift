#if os(macOS)
import AppKit

// VoiceOver support. The grid draws its own rows, so it describes itself as an
// accessibility table built from lightweight NSAccessibilityElements instead of
// exposing its internal canvases.
//
// NSAccessibilityElement's methods are nonisolated in the SDK, but AppKit calls
// them on the main thread; `onMain` runs the bodies with main-actor isolation
// (and traps if that assumption is ever violated). The closures capture only the
// table (main-actor isolated, so Sendable) and plain values, never the element.

private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
    MainActor.assumeIsolated(body)
}

/// A row of the table.
///
/// Elements may outlive a reload (VoiceOver keeps the focused one), so they
/// refer to the table and their row weakly and check that the row still exists.
final class NGAccessibilityRow: NSAccessibilityElement {
    nonisolated(unsafe) weak var table: NGTableView?
    let index: Int
    /// Created on first access (on the main thread, like every call here).
    nonisolated(unsafe) private var cells: [NGAccessibilityCell]?

    init(table: NGTableView, index: Int) {
        self.table = table
        self.index = index
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    override func accessibilityParent() -> Any? { table }
    override func accessibilityIndex() -> Int { index }

    override func accessibilityChildren() -> [Any]? {
        if let cells { return cells }
        guard let table else { return nil }
        nonisolated(unsafe) let row = self
        let created = NGTableView.onMainActor {
            table.accessibilityColumnOrder.enumerated().map { position, frame in
                NGAccessibilityCell(table: table, row: row, column: frame.column, columnIndex: position)
            }
        } as? [NGAccessibilityCell] ?? []
        cells = created
        return created
    }

    override func isAccessibilitySelected() -> Bool {
        guard let table else { return false }
        let index = index
        return onMain { table.displaySelection.contains(index) }
    }

    override func setAccessibilitySelected(_ selected: Bool) {
        guard let table else { return }
        let index = index
        onMain {
            guard !table.ignoresUserInput, index < table.numberOfRows else { return }
            var rows = table.allowsMultipleSelection ? table.displaySelection : []
            if selected { rows.insert(index) } else { rows.remove(index) }
            table.selectDisplayRows(rows, byExtendingSelection: false)
        }
    }

    override func accessibilityFrame() -> NSRect {
        guard let table else { return .zero }
        let index = index
        return onMain { index < table.numberOfRows ? table.accessibilityScreenFrame(forRow: index, columnRange: nil) : .zero }
    }

    // Group headers and a tree's rows are disclosure rows, like an outline view's.

    override func accessibilityDisclosureLevel() -> Int {
        guard let table else { return 0 }
        let index = index
        return onMain {
            if let node = table.groupNode(atDisplayRow: index) { return table.groupTree.nodes[node].group.level }
            guard table.isShowingRowTree, let row = table.row(atDisplayIndex: index) else { return 0 }
            return max(0, table.level(forRow: row))
        }
    }

    override func isAccessibilityDisclosed() -> Bool {
        guard let table else { return false }
        let index = index
        return onMain {
            if let node = table.groupNode(atDisplayRow: index) { return table.isGroupExpanded(table.groupTree.nodes[node].group) }
            guard table.isShowingRowTree, let row = table.row(atDisplayIndex: index) else { return false }
            return table.isRowExpandable(row) && table.isRowExpanded(row)
        }
    }

    override func setAccessibilityDisclosed(_ disclosed: Bool) {
        guard let table else { return }
        let index = index
        onMain {
            guard !table.ignoresUserInput else { return }
            if let node = table.groupNode(atDisplayRow: index) {
                let group = table.groupTree.nodes[node].group
                if disclosed { table.expandGroup(group) } else { table.collapseGroup(group) }
            } else if table.isShowingRowTree, let row = table.row(atDisplayIndex: index), table.isRowExpandable(row) {
                table.setTreeRow(handle: table.handle(ofRow: row), expanded: disclosed, includingChildren: false, byUser: true)
            }
        }
    }

    /// The row's swipe actions, which VoiceOver can't swipe (both edges).
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let table else { return nil }
        let index = index
        nonisolated(unsafe) var made: [NSAccessibilityCustomAction] = []
        onMain {
            guard index < table.numberOfRows, !table.isGroupRow(index), let delegate = table.delegate else { return }
            let row = table.sourceRow(index)
            guard row >= 0 else { return }
            let ref = table.rowRef(ofRow: row)
            for edge in [NSTableView.RowActionEdge.leading, .trailing] {
                for action in delegate.tableView(table, rowActionsForRow: row, edge: edge) {
                    made.append(NSAccessibilityCustomAction(name: action.title) { [weak table] in
                        onMain {
                            // On the record it was for, wherever it is now (not if it's gone).
                            guard let table, !table.ignoresUserInput else { return false }
                            let row = table.row(of: ref)
                            guard row >= 0 else { return false }
                            action.handler(action, row)
                            return true
                        }
                    })
                }
            }
        }
        return made
    }

    /// The row's context menu, as a right-click opens it.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let table else { return false }
        let index = index
        return onMain { table.showAccessibilityMenu(forDisplayRow: index) }
    }

    override func accessibilityLabel() -> String? {
        guard let table else { return nil }
        let index = index
        return onMain { () -> String? in
            guard let node = table.groupNode(atDisplayRow: index) else { return nil }
            let group = table.groupTree.nodes[node]
            return "\(table.title(of: group.group)), \(group.rows.count.formatted(.number.locale(table.formattingLocale)))"
        }
    }
}

/// A cell of a row.
final class NGAccessibilityCell: NSAccessibilityElement {
    nonisolated(unsafe) weak var table: NGTableView?
    nonisolated(unsafe) weak var row: NGAccessibilityRow?
    let rowIndex: Int
    let column: NGTableColumn
    let columnIndex: Int

    init(table: NGTableView, row: NGAccessibilityRow, column: NGTableColumn, columnIndex: Int) {
        self.table = table
        self.row = row
        self.rowIndex = row.index
        self.column = column
        self.columnIndex = columnIndex
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .cell }
    override func accessibilityParent() -> Any? { row }

    /// A link or an enabled button: described so, and pressed like one.
    private var isControl: Bool {
        guard let table else { return false }
        let (rowIndex, columnID) = (rowIndex, column.id)
        return onMain { rowIndex < table.numberOfRows && table.isControlCell(row: table.sourceRow(rowIndex), columnID: columnID) }
    }

    override func accessibilityRoleDescription() -> String? {
        guard let table else { return super.accessibilityRoleDescription() }
        let (rowIndex, columnID) = (rowIndex, column.id)
        let control = onMain { rowIndex < table.numberOfRows ? table.controlRoleDescription(row: table.sourceRow(rowIndex), columnID: columnID) : nil }
        return control ?? super.accessibilityRoleDescription()
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformPress) { return isControl }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let table else { return false }
        let (rowIndex, columnID) = (rowIndex, column.id)
        return onMain {
            rowIndex < table.numberOfRows && table.activateControl(row: table.sourceRow(rowIndex), columnID: columnID)
        }
    }
    override func accessibilityLabel() -> String? { column.title }
    override func accessibilityRowIndexRange() -> NSRange { NSRange(location: rowIndex, length: 1) }
    override func accessibilityColumnIndexRange() -> NSRange { NSRange(location: columnIndex, length: 1) }

    override func accessibilityValue() -> Any? {
        guard let table else { return nil }
        let (rowIndex, column) = (rowIndex, column)
        return onMain { table.accessibilityText(row: rowIndex, column: column) }
    }

    override func accessibilityFrame() -> NSRect {
        guard let table else { return .zero }
        let (rowIndex, columnID) = (rowIndex, column.id)
        return onMain { () -> NSRect in
            // Scrolled out horizontally: no frame rather than the whole row's.
            guard rowIndex < table.numberOfRows, let range = table.viewportRange(ofColumnID: columnID) else { return .zero }
            return table.accessibilityScreenFrame(forRow: rowIndex, columnRange: range)
        }
    }
}

/// A column header; pressing it changes the sort like clicking it.
final class NGAccessibilityColumnHeader: NSAccessibilityElement {
    nonisolated(unsafe) weak var table: NGTableView?
    let column: NGTableColumn

    init(table: NGTableView, column: NGTableColumn) {
        self.table = table
        self.column = column
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityParent() -> Any? { table }
    override func accessibilityLabel() -> String? { column.title }

    override func accessibilitySortDirection() -> NSAccessibilitySortDirection {
        guard let table else { return .unknown }
        let column = column
        return onMain { table.accessibilitySortDirection(of: column) }
    }

    override func accessibilityValue() -> Any? {
        guard let table else { return nil }
        let column = column
        return onMain { () -> String? in
            guard let sort = table.sortPosition(ofColumn: column) else { return nil }
            return sort.ascending
                ? String(localized: "ascending", bundle: .module, comment: "VoiceOver: a column sorted in ascending order.")
                : String(localized: "descending", bundle: .module, comment: "VoiceOver: a column sorted in descending order.")
        }
    }

    /// Like a click: sorts by a sortable column, and the delegate hears of it.
    override func accessibilityPerformPress() -> Bool {
        guard let table else { return false }
        let column = column
        return onMain {
            guard !table.ignoresUserInput, !table.hidesHeader else { return false }
            if column.isSortable { table.sortByClicking(column) }
            table.delegate?.tableView(table, didClick: column)
            return true
        }
    }

    override func accessibilityFrame() -> NSRect {
        guard let table else { return .zero }
        let columnID = column.id
        return onMain {
            guard let range = table.viewportRange(ofColumnID: columnID) else { return .zero }
            let rect = NSRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: table.headerHeight)
            return table.accessibilityScreenRect(rect)
        }
    }
}

/// A column, like NSTableView's: its header, and its cells in the rows shown.
final class NGAccessibilityColumn: NSAccessibilityElement {
    nonisolated(unsafe) weak var table: NGTableView?
    let column: NGTableColumn

    init(table: NGTableView, column: NGTableColumn) {
        self.table = table
        self.column = column
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .column }
    override func accessibilityParent() -> Any? { table }
    override func accessibilityLabel() -> String? { column.title }

    /// Its place among the columns shown (they may have moved since it was made).
    override func accessibilityIndex() -> Int {
        guard let table else { return 0 }
        let id = column.id
        return onMain { table.accessibilityColumnOrder.firstIndex { $0.column.id == id } ?? 0 }
    }

    override func isAccessibilitySelected() -> Bool {
        guard let table else { return false }
        let id = column.id
        return onMain { table.selectedColumnIndexes.contains { table.tableColumns[$0].id == id } }
    }

    override func accessibilityHeader() -> Any? {
        guard let table else { return nil }
        let column = column
        return NGTableView.onMainActor { table.accessibilityHeaderElement(column) }
    }

    override func accessibilityChildren() -> [Any]? {
        guard let table else { return nil }
        let id = column.id
        return NGTableView.onMainActor {
            table.visibleRowRange.compactMap { row in
                (table.accessibilityRowElement(row).accessibilityChildren() as? [NGAccessibilityCell])?.first { $0.column.id == id }
            }
        } as? [Any]
    }

    override func accessibilitySortDirection() -> NSAccessibilitySortDirection {
        guard let table else { return .unknown }
        let column = column
        return onMain { table.accessibilitySortDirection(of: column) }
    }

    override func accessibilityFrame() -> NSRect {
        guard let table else { return .zero }
        let id = column.id
        return onMain { () -> NSRect in
            guard let range = table.viewportRange(ofColumnID: id) else { return .zero }
            let metrics = table.layoutMetrics
            let rect = NSRect(x: range.lowerBound, y: metrics.headerHeight, width: range.upperBound - range.lowerBound,
                              height: max(0, table.bounds.height - metrics.headerHeight - metrics.summaryHeight))
            return table.accessibilityScreenRect(rect)
        }
    }
}

/// The summary row: one static text per summarized column.
final class NGAccessibilitySummary: NSAccessibilityElement {
    nonisolated(unsafe) weak var table: NGTableView?
    /// Kept per column so VoiceOver's focus survives value updates.
    nonisolated(unsafe) private var elements: [String: NSAccessibilityElement] = [:]

    init(table: NGTableView) {
        self.table = table
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityParent() -> Any? { table }

    override func accessibilityLabel() -> String? {
        guard let table else { return nil }
        // What it is, then which rows it counts (the scope menu's title).
        return onMain {
            let name = String(localized: "Summary", bundle: .module, comment: "VoiceOver: the summary row's name.")
            return table.summaryScopeTitles[table.summaryScope].map { "\(name), \($0)" } ?? name
        }
    }

    override func accessibilityChildren() -> [Any]? {
        guard let table else { return nil }
        nonisolated(unsafe) let summary = self
        nonisolated(unsafe) var elements = elements
        let children = NGTableView.onMainActor {
            table.accessibilityColumnOrder.compactMap { frame -> NSAccessibilityElement? in
                guard let text = table.summaryText(forColumnID: frame.column.id) else { return nil }
                let element = elements[frame.column.id] ?? NSAccessibilityElement()
                elements[frame.column.id] = element
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityLabel(frame.column.title)
                element.setAccessibilityValue(text)
                element.setAccessibilityParent(summary)
                return element
            }
        } as? [Any]
        self.elements = elements
        return children
    }

    override func accessibilityFrame() -> NSRect {
        guard let table else { return .zero }
        return onMain { table.accessibilityScreenRect(table.summaryBar.frame) }
    }
}

extension NGTableView {
    func accessibilityScreenRect(_ rect: NSRect) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func accessibilityScreenFrame(forRow row: Int, columnRange: ClosedRange<CGFloat>?) -> NSRect {
        let y = headerHeight + rowGeometry.top(of: row) - renderedOffsetY
        let minX = columnRange?.lowerBound ?? 0
        let maxX = columnRange?.upperBound ?? bounds.width
        return accessibilityScreenRect(NSRect(x: minX, y: y, width: maxX - minX, height: rowGeometry.height(of: row)))
    }

    /// Row elements are created lazily and cached until the next reload.
    func accessibilityRowElement(_ row: Int) -> NGAccessibilityRow {
        if let element = accessibilityRowCache[row] {
            return element
        }
        // Stepping through a huge table would otherwise keep every row visited.
        if accessibilityRowCache.count > Self.accessibilityRowLimit {
            let visible = visibleRowRange
            accessibilityRowCache = accessibilityRowCache.filter { visible.contains($0.key) }
        }
        let element = NGAccessibilityRow(table: self, index: row)
        accessibilityRowCache[row] = element
        return element
    }

    var visibleRowRange: Range<Int> {
        guard rowHeight > 0, numberOfRows > 0 else { return 0..<0 }
        let metrics = layoutMetrics
        let rowLayout = rowGeometry
        let first = max(0, Int(floor(rowLayout.position(atY: renderedOffsetY))))
        let last = min(numberOfRows, Int(ceil(rowLayout.position(atY: renderedOffsetY + metrics.bodyHeight - metrics.bottomInset))))
        return first..<max(first, last)
    }

    // MARK: NSAccessibility (table)

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .table }
    public override func accessibilityRowCount() -> Int { numberOfRows }
    public override func accessibilityColumnCount() -> Int { accessibilityColumnOrder.count }

    /// Above this many rows, only visible (and selected visible) rows are listed
    /// as elements; `accessibilityRowCount` still reports every row.
    static let accessibilityRowLimit = 5_000

    public override func accessibilityRows() -> [Any]? {
        numberOfRows <= Self.accessibilityRowLimit
            ? (0..<numberOfRows).map(accessibilityRowElement)
            : visibleRowRange.map(accessibilityRowElement)
    }

    public override func accessibilityVisibleRows() -> [Any]? {
        visibleRowRange.map(accessibilityRowElement)
    }

    public override func accessibilitySelectedRows() -> [Any]? {
        guard displaySelection.count > Self.accessibilityRowLimit else {
            return displaySelection.map(accessibilityRowElement)
        }
        let visible = visibleRowRange
        return displaySelection.filter { visible.contains($0) }.map(accessibilityRowElement)
    }

    public override func setAccessibilitySelectedRows(_ rows: [Any]?) {
        guard !ignoresUserInput else { return }
        let indexes = (rows ?? []).compactMap { ($0 as? NGAccessibilityRow)?.index }
        selectDisplayRows(IndexSet(indexes), byExtendingSelection: false)
    }

    public override func accessibilityColumnHeaderUIElements() -> [Any]? {
        // Without data the header isn't shown.
        guard showsGrid else { return [] }
        return accessibilityColumnOrder.map { accessibilityHeaderElement($0.column) }
    }

    func accessibilityHeaderElement(_ column: NGTableColumn) -> NGAccessibilityColumnHeader {
        if let element = accessibilityHeaderCache[column.id] {
            return element
        }
        let element = NGAccessibilityColumnHeader(table: self, column: column)
        accessibilityHeaderCache[column.id] = element
        return element
    }

    public override func accessibilityColumns() -> [Any]? {
        accessibilityColumnOrder.map { accessibilityColumnElement($0.column) }
    }

    public override func accessibilitySelectedColumns() -> [Any]? {
        let selected = Set(selectedColumnIndexes.map { tableColumns[$0].id })
        return accessibilityColumnOrder.filter { selected.contains($0.column.id) }.map { accessibilityColumnElement($0.column) }
    }

    /// The columns scrolled into view (frozen ones always).
    public override func accessibilityVisibleColumns() -> [Any]? {
        accessibilityColumnOrder.filter { viewportRange(ofColumnID: $0.column.id) != nil }.map { accessibilityColumnElement($0.column) }
    }

    /// The focused cell, or the cells of the selected range (navigation by
    /// cell), row by row, in the order the columns show.
    public override func accessibilitySelectedCells() -> [Any]? {
        var cells: [(row: Int, columnIDs: Set<String>)] = []
        if let range = selectedCellRange, let bounds = cellRangeBounds(range) {
            // Huge ranges: the rows in view.
            let rows = bounds.rows.count > Self.accessibilityRowLimit
                ? bounds.rows.clamped(to: visibleRowRange.lowerBound...max(visibleRowRange.lowerBound, visibleRowRange.upperBound - 1))
                : bounds.rows
            cells = rows.map { ($0, Set(bounds.columnIDs)) }
        } else if navigatesByCell, let cell = focusedCell, let row = displayRow(forSourceRow: cell.row) {
            cells = [(row, [cell.columnID])]
        }
        let selected: [NGAccessibilityCell] = cells.flatMap { row, ids in
            (accessibilityRowElement(row).accessibilityChildren() as? [NGAccessibilityCell] ?? []).filter { ids.contains($0.column.id) }
        }
        return selected
    }

    func accessibilitySortDirection(of column: NGTableColumn) -> NSAccessibilitySortDirection {
        guard let sort = sortPosition(ofColumn: column) else { return .unknown }
        return sort.ascending ? .ascending : .descending
    }

    private func accessibilityColumnElement(_ column: NGTableColumn) -> NGAccessibilityColumn {
        if let element = accessibilityColumnCache[column.id] {
            return element
        }
        let element = NGAccessibilityColumn(table: self, column: column)
        accessibilityColumnCache[column.id] = element
        return element
    }

    /// Only the logical structure: header buttons, visible rows and the summary.
    /// Internal canvases, cells and scrollers are not exposed.
    public override func accessibilityChildren() -> [Any]? {
        var children: [Any] = accessibilityColumnHeaderUIElements() ?? []
        children += accessibilityVisibleRows() ?? []
        if let emptyState = visibleEmptyStateView {
            children.append(emptyState)
        }
        if showsSummaryBar {
            children.append(accessibilitySummaryElement)
        }
        return children
    }

    /// `accessibilityHitTest(_:)` is nonisolated in the SDK, but AppKit calls it
    /// on the main thread; the actual lookup is main-actor isolated.
    public override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        Self.onMainActor { accessibilityElement(atScreenPoint: point) }
    }

    nonisolated static func onMainActor(_ body: @MainActor () -> Any?) -> Any? {
        nonisolated(unsafe) var result: Any?
        MainActor.assumeIsolated {
            result = body()
        }
        return result
    }

    func accessibilityElement(atScreenPoint point: NSPoint) -> Any? {
        guard let window else { return self }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        if local.y < headerHeight {
            let column = accessibilityColumnOrder.first { viewportRange(ofColumnID: $0.column.id)?.contains(local.x) ?? false }
            return column.map { accessibilityHeaderElement($0.column) } ?? self
        }
        if showsSummaryBar, summaryBar.frame.contains(local) {
            return accessibilitySummaryElement
        }
        let row = Int(floor(rowGeometry.position(atY: local.y - headerHeight + renderedOffsetY)))
        guard row >= 0, row < numberOfRows else { return self }
        let rowElement = accessibilityRowElement(row)
        let cells = rowElement.accessibilityChildren() as? [NGAccessibilityCell] ?? []
        return cells.first { cell in
            viewportRange(ofColumnID: cell.column.id)?.contains(local.x) ?? false
        } ?? rowElement
    }
}
#endif
