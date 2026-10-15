#if os(iOS)
import UIKit

// VoiceOver on the iPad: the table is a data table (rows and columns, the
// titles as the columns' headers), its elements the titles, the cells of the
// rows in view and the summary row. A cell reads its value like the Mac's
// (check marks, ratings, sparklines in words); a double tap selects its row
// (and sends `action`) or presses a link or a button; the rows' swipe actions
// and menu are custom actions; three-finger swipes page. Elements are kept
// per row (until rows move) so VoiceOver's focus survives updates.

/// A row's cell elements, kept while the row stays.
final class NGAccessibilityRow {
    var cells: [String: NGTouchAccessibilityCell] = [:]
}

final class NGAccessibilityColumnHeader {}
final class NGAccessibilityColumn {}

/// The summary row: one element, its values read in order.
final class NGAccessibilitySummary: UIAccessibilityElement {
    weak var table: NGTableView?

    init(table: NGTableView) {
        self.table = table
        super.init(accessibilityContainer: table)
        accessibilityTraits = .staticText
    }

    override var accessibilityLabel: String? {
        get {
            guard let table else { return nil }
            let name = String(localized: "Summary", bundle: .module, comment: "VoiceOver: the summary row's name.")
            return table.summaryScopeTitles[table.summaryScope].map { "\(name), \($0)" } ?? name
        }
        set {}
    }

    override var accessibilityValue: String? {
        get {
            guard let table else { return nil }
            return table.accessibilityColumnOrder.compactMap { frame in
                table.summaryText(forColumnID: frame.column.id).map { "\(frame.column.title): \($0)" }
            }.joined(separator: ", ")
        }
        set {}
    }

    override var accessibilityFrameInContainerSpace: CGRect {
        get { table?.summaryBar.frame ?? .zero }
        set {}
    }
}

/// A column's title: a header, sorted by a double tap.
final class NGTouchAccessibilityHeader: UIAccessibilityElement, UIAccessibilityContainerDataTableCell {
    weak var table: NGTableView?
    let column: NGTableColumn
    let columnIndex: Int

    init(table: NGTableView, column: NGTableColumn, columnIndex: Int) {
        self.table = table
        self.column = column
        self.columnIndex = columnIndex
        super.init(accessibilityContainer: table)
        accessibilityLabel = column.title
        accessibilityTraits = column.isSortable ? [.header, .button] : .header
    }

    override var accessibilityValue: String? {
        get {
            guard let sort = table?.sortPosition(ofColumn: column) else { return nil }
            return sort.ascending
                ? String(localized: "ascending", bundle: .module, comment: "VoiceOver: a column sorted in ascending order.")
                : String(localized: "descending", bundle: .module, comment: "VoiceOver: a column sorted in descending order.")
        }
        set {}
    }

    override var accessibilityFrameInContainerSpace: CGRect {
        get {
            guard let table, let range = table.viewportRange(ofColumnID: column.id) else { return .zero }
            return CGRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: table.layoutMetrics.headerHeight)
        }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        guard let table, !table.ignoresUserInput, !table.hidesHeader else { return false }
        if column.isSortable { table.sortByClicking(column) }
        table.delegate?.tableView(table, didClick: column)
        return true
    }

    func accessibilityRowRange() -> NSRange { NSRange(location: 0, length: 1) }
    func accessibilityColumnRange() -> NSRange { NSRange(location: columnIndex, length: 1) }
}

/// A cell of a row in view.
final class NGTouchAccessibilityCell: UIAccessibilityElement, UIAccessibilityContainerDataTableCell {
    weak var table: NGTableView?
    /// The display row, and the column.
    let row: Int
    let column: NGTableColumn

    init(table: NGTableView, row: Int, column: NGTableColumn) {
        self.table = table
        self.row = row
        self.column = column
        super.init(accessibilityContainer: table)
    }

    private var isControl: Bool {
        guard let table, row < table.numberOfRows else { return false }
        return table.isControlCell(row: table.sourceRow(row), columnID: column.id)
    }

    override var accessibilityLabel: String? {
        get { table?.accessibilityText(row: row, column: column) }
        set {}
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get {
            guard let table else { return .none }
            var traits: UIAccessibilityTraits = isControl ? .button : .none
            if table.displaySelection.contains(row) { traits.insert(.selected) }
            return traits
        }
        set {}
    }

    override var accessibilityFrameInContainerSpace: CGRect {
        get {
            // Scrolled out sideways: no frame rather than the row's.
            guard let table, row < table.numberOfRows, let range = table.viewportRange(ofColumnID: column.id) else { return .zero }
            let y = table.layoutMetrics.headerHeight + table.rowGeometry.top(of: row) - table.renderedOffsetY
            return CGRect(x: range.lowerBound, y: y, width: range.upperBound - range.lowerBound, height: table.rowGeometry.height(of: row))
        }
        set {}
    }

    /// A double tap: a link or a button acts; otherwise the row is selected.
    override func accessibilityActivate() -> Bool {
        guard let table, !table.ignoresUserInput, row < table.numberOfRows else { return false }
        if isControl { return table.activateControl(row: table.sourceRow(row), columnID: column.id) }
        let frame = accessibilityFrameInContainerSpace
        guard !frame.isEmpty else { return false }
        table.tapped(at: CGPoint(x: frame.midX, y: frame.midY))
        return true
    }

    /// The row's swipe actions.
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let table, let delegate = table.delegate, row < table.numberOfRows, !table.isGroupRow(row) else { return nil }
            let source = table.sourceRow(row)
            let actions = [NSTableView.RowActionEdge.trailing, .leading].flatMap { delegate.tableView(table, rowActionsForRow: source, edge: $0) }
            return actions.map { action in
                UIAccessibilityCustomAction(name: action.title) { [weak table] _ in
                    guard let table, table.row(of: table.rowRef(ofRow: source)) >= 0 else { return false }
                    action.handler(action, source)
                    return true
                }
            }
        }
        set {}
    }

    func accessibilityRowRange() -> NSRange { NSRange(location: row + 1, length: 1) }
    func accessibilityColumnRange() -> NSRange {
        NSRange(location: table?.accessibilityColumnOrder.firstIndex { $0.column.id == column.id } ?? 0, length: 1)
    }
}

extension NGTableView: UIAccessibilityContainerDataTable {
    /// The display rows in view.
    var accessibilityRowsInView: Range<Int> {
        guard numberOfRows > 0 else { return 0..<0 }
        let metrics = layoutMetrics
        let first = max(0, Int(floor(rowGeometry.position(atY: renderedOffsetY))))
        let last = min(numberOfRows, Int(ceil(rowGeometry.position(atY: renderedOffsetY + max(0, metrics.bodyHeight - metrics.bottomInset)))))
        return first..<max(first, last)
    }

    func accessibilityCell(row: Int, column: NGTableColumn) -> NGTouchAccessibilityCell {
        let cached = accessibilityRowCache[row] ?? NGAccessibilityRow()
        accessibilityRowCache[row] = cached
        if let cell = cached.cells[column.id], cell.column == column { return cell }
        let cell = NGTouchAccessibilityCell(table: self, row: row, column: column)
        cached.cells[column.id] = cell
        return cell
    }

    func accessibilityHeader(columnIndex: Int, column: NGTableColumn) -> NGTouchAccessibilityHeader {
        if let header = accessibilityTitleCache[column.id], header.column == column, header.columnIndex == columnIndex { return header }
        let header = NGTouchAccessibilityHeader(table: self, column: column, columnIndex: columnIndex)
        accessibilityTitleCache[column.id] = header
        return header
    }

    public override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    public override var accessibilityContainerType: UIAccessibilityContainerType {
        get { .dataTable }
        set {}
    }

    public override var accessibilityElements: [Any]? {
        get {
            guard showsGrid else { return [] }
            let columns = accessibilityColumnOrder
            var elements: [Any] = []
            if !hidesHeader {
                elements += columns.enumerated().map { accessibilityHeader(columnIndex: $0.offset, column: $0.element.column) }
            }
            for row in accessibilityRowsInView {
                elements += columns.map { accessibilityCell(row: row, column: $0.column) }
            }
            if showsSummaryBar { elements.append(accessibilitySummaryElement) }
            return elements
        }
        set {}
    }

    /// Three-finger swipes: a page of rows.
    public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        switch direction {
        case .up: scrollByPage(-1)
        case .down: scrollByPage(1)
        default: return false
        }
        let rows = accessibilityRowsInView
        let text = String(localized: "Rows \(rows.lowerBound + 1) to \(rows.upperBound) of \(numberOfRows)", bundle: .module,
                          comment: "VoiceOver on the iPad: the rows in view after a page scroll.")
        UIAccessibility.post(notification: .pageScrolled, argument: text)
        return true
    }

    public func accessibilityRowCount() -> Int { numberOfRows + 1 }
    public func accessibilityColumnCount() -> Int { accessibilityColumnOrder.count }

    public func accessibilityDataTableCellElement(forRow row: Int, column: Int) -> (any UIAccessibilityContainerDataTableCell)? {
        let columns = accessibilityColumnOrder
        guard column >= 0, column < columns.count else { return nil }
        if row == 0 { return hidesHeader ? nil : accessibilityHeader(columnIndex: column, column: columns[column].column) }
        guard row - 1 < numberOfRows else { return nil }
        return accessibilityCell(row: row - 1, column: columns[column].column)
    }

    public func accessibilityHeaderElements(forColumn column: Int) -> [any UIAccessibilityContainerDataTableCell]? {
        let columns = accessibilityColumnOrder
        guard !hidesHeader, column >= 0, column < columns.count else { return nil }
        return [accessibilityHeader(columnIndex: column, column: columns[column].column)]
    }
}
#endif
