#if os(macOS)
import AppKit

/// A data source that puts all the rows dragged on the pasteboard at once,
/// as `NSTableViewDataSource`'s `tableView(_:writeRowsWith:to:)` does.
@MainActor
protocol NGRowsPasteboardWriting {
    var writesRowsAtOnce: Bool { get }
    func pasteboardWriter(forRows rows: IndexSet, in tableView: NGTableView) -> (any NSPasteboardWriting)?
}

/// Lets an existing `NSTableViewDataSource` feed an `NGTableView` unchanged,
/// to move a table over before rewriting its data source.
///
/// The data source keeps working with an `NSTableView`: it gets a stand-in
/// whose columns stand for the table's (identifiers, titles, sort descriptor
/// prototypes; made as the data source asks for them), whose `sortDescriptors`, selection and clicked row are the
/// table's, and whose `reloadData()`, targeted updates and selection calls
/// go to the `NGTableView`. Values from `tableView(_:objectValueFor:row:)`
/// become cell values (see `value(from:)`), or pass your own `convert`;
/// edits reach `tableView(_:setObjectValue:for:row:)` as object values (see
/// `objectValue(of:)`), and row drags and drops go to its
/// `pasteboardWriterForRow` (or, without one, the deprecated
/// `writeRowsWith`, for all the rows dragged at once), `validateDrop`,
/// `acceptDrop` and the dragging session calls.
///
/// ```swift
/// let adapter = NGTableViewDataSourceAdapter(campaignsDataSource)
/// table.dataSource = adapter   // Keep the adapter: the table holds it weakly.
/// ```
///
/// Only values are used: the stand-in has no views, so view-based cells
/// don't carry over (images become `.media` values of your own). Each value
/// goes through `Any`, so for the largest tables a data source returning
/// `NGCellValue`s directly stays faster.
@MainActor
public final class NGTableViewDataSourceAdapter: NSObject, NGTableViewDataSource {
    /// The data source, held weakly like a table view's.
    public weak var source: (any NSTableViewDataSource)?
    /// Turns an object value into a cell value; `value(from:)` by default.
    public var convert: (Any?, NGTableColumn) -> NGCellValue
    /// A stable identity of a row, which `NSTableViewDataSource` has no method
    /// for (see `NGTableViewDataSource.tableView(_:identifierForRow:)`).
    public var identifierForRow: ((Int) -> AnyHashable?)?

    private let proxy = NGTableViewProxy(frame: .zero)

    /// The `NSTableView` the data source is given (for tests and debugging).
    public var tableViewStandIn: NSTableView { proxy }

    public init(_ source: any NSTableViewDataSource, convert: ((Any?, NGTableColumn) -> NGCellValue)? = nil) {
        self.source = source
        self.convert = convert ?? { value, _ in NGTableViewDataSourceAdapter.value(from: value) }
        super.init()
    }

    /// The cell value for an object value: strings and attributed strings as
    /// text, numbers as numbers, Booleans as check marks, dates as dates,
    /// `nil` and `NSNull` as empty, cell values as they are, anything else as
    /// the text of its description.
    public static func value(from object: Any?) -> NGCellValue {
        switch object {
        case nil, is NSNull: return .empty
        case let value as NGCellValue: return value
        case let text as String: return .text(text)
        case let text as NSAttributedString: return .text(text.string)
        case let date as Date: return .date(date)
        case let number as NSNumber:
            // Booleans are NSNumbers too: tell them apart by their CF type.
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let object?: return .text(String(describing: object))
        }
    }

    // MARK: NGTableViewDataSource

    public func numberOfRows(in tableView: NGTableView) -> Int {
        proxy.table = tableView
        return source?.numberOfRows?(in: proxy) ?? 0
    }

    public func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        proxy.table = tableView
        guard let getValue = source?.tableView(_:objectValueFor:row:) else { return .empty }
        return convert(getValue(proxy, proxy.standIn(for: column), row), column)
    }

    public func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? {
        identifierForRow?(row)
    }

    public func tableView(_ tableView: NGTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        proxy.table = tableView
        source?.tableView?(proxy, sortDescriptorsDidChange: oldDescriptors)
    }

    public func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
        proxy.table = tableView
        source?.tableView?(proxy, setObjectValue: Self.objectValue(of: value), for: proxy.standIn(for: column), row: row)
    }

    public func tableView(_ tableView: NGTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        proxy.table = tableView
        if let writer = source?.tableView?(proxy, pasteboardWriterForRow: row) { return writer }
        // A data source from before pasteboard writers: what it writes for the row.
        return writesRowsAtOnce ? pasteboardWriter(forRows: [row], in: tableView) : nil
    }

    public func tableView(_ tableView: NGTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                          proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        proxy.table = tableView
        return source?.tableView?(proxy, validateDrop: info, proposedRow: row, proposedDropOperation: dropOperation) ?? []
    }

    public func tableView(_ tableView: NGTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                          dropOperation: NSTableView.DropOperation) -> Bool {
        proxy.table = tableView
        return source?.tableView?(proxy, acceptDrop: info, row: row, dropOperation: dropOperation) ?? false
    }

    public func tableView(_ tableView: NGTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                          forRowIndexes rowIndexes: IndexSet) {
        proxy.table = tableView
        source?.tableView?(proxy, draggingSession: session, willBeginAt: screenPoint, forRowIndexes: rowIndexes)
    }

    public func tableView(_ tableView: NGTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                          operation: NSDragOperation) {
        proxy.table = tableView
        source?.tableView?(proxy, draggingSession: session, endedAt: screenPoint, operation: operation)
    }

    public func tableView(_ tableView: NGTableView, updateDraggingItemsForDrag draggingInfo: any NSDraggingInfo) {
        proxy.table = tableView
        source?.tableView?(proxy, updateDraggingItemsForDrag: draggingInfo)
    }

    /// The object value an edited cell's value is given to the data source
    /// as: text as a string, numbers and Booleans as `NSNumber`s, dates as
    /// dates, `nil` for an empty cell; tags as their titles (", "), icons as
    /// their labels, media as their text, a sparkline as its values
    /// (`[NSNumber]`).
    public static func objectValue(of value: NGCellValue) -> Any? {
        switch value {
        case .empty: nil
        case .text(let text): text
        case .number(let number): NSNumber(value: number)
        case .bool(let bool): NSNumber(value: bool)
        case .date(let date): date
        case .tags(let tags): tags.map(\.title).joined(separator: ", ")
        case .mark(let mark): mark.label
        case .media(let media): media.text
        case .sparkline(let sparkline): sparkline.values.map { NSNumber(value: $0) }
        case .link(let link): link.title
        case .button(let button): button.title
        case .progress(let value, let total): NGCellValue.fraction(value, total).map { NSNumber(value: $0) }
        case .rating(let value, _): NSNumber(value: value)
        }
    }
}

/// The `NSTableView` an adapted data source works with: its state is the
/// `NGTableView`'s, and what the data source asks it to do goes there.
@MainActor
final class NGTableViewProxy: NSTableView {
    weak var table: NGTableView?
    private var standIns: [String: NSTableColumn] = [:]

    /// An `NSTableColumn` with the column's identifier, title and sort
    /// descriptor prototype, added to the stand-in's columns on first use.
    func standIn(for column: NGTableColumn) -> NSTableColumn {
        if let existing = standIns[column.id] { return existing }
        let standIn = NSTableColumn(identifier: column.identifier)
        standIn.title = column.title
        standIn.sortDescriptorPrototype = column.sortDescriptorPrototype
        standIns[column.id] = standIn
        addTableColumn(standIn)
        return standIn
    }

    /// The `NGTableView` index of one of the stand-in's column indexes.
    private func tableIndexes(of indexes: IndexSet) -> IndexSet {
        guard let table else { return [] }
        let columns = tableColumns
        return IndexSet(indexes.compactMap { index in
            index >= 0 && index < columns.count ? table.column(withIdentifier: columns[index].identifier) : nil
        }.filter { $0 >= 0 })
    }

    // State: the NGTableView's.

    override var sortDescriptors: [NSSortDescriptor] {
        get { table?.sortDescriptors ?? [] }
        set { table?.sortDescriptors = newValue }
    }

    override var selectedRowIndexes: IndexSet { table?.selectedRowIndexes ?? [] }
    override var selectedRow: Int { table?.selectedRow ?? -1 }
    override var numberOfSelectedRows: Int { table?.numberOfSelectedRows ?? 0 }
    override var clickedRow: Int { table?.clickedRow ?? -1 }
    override var numberOfRows: Int { table?.numberOfSourceRows ?? 0 }

    override var clickedColumn: Int {
        guard let table, table.clickedColumn >= 0, table.clickedColumn < table.tableColumns.count else { return -1 }
        let column = table.tableColumns[table.clickedColumn]
        return self.column(withIdentifier: standIn(for: column).identifier)
    }

    override func isRowSelected(_ row: Int) -> Bool { table?.isRowSelected(row) ?? false }

    // Actions: done by the NGTableView.

    override func reloadData() { table?.reloadData() }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        table?.reloadData(forRowIndexes: rowIndexes, columnIndexes: tableIndexes(of: columnIndexes))
    }

    override func noteNumberOfRowsChanged() { table?.noteNumberOfRowsChanged() }
    override func beginUpdates() { table?.beginUpdates() }
    override func endUpdates() { table?.endUpdates() }

    override func insertRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        table?.insertRows(at: indexes, withAnimation: animationOptions)
    }

    override func removeRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        table?.removeRows(at: indexes, withAnimation: animationOptions)
    }

    override func moveRow(at oldIndex: Int, to newIndex: Int) { table?.moveRow(at: oldIndex, to: newIndex) }

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        table?.selectRowIndexes(indexes, byExtendingSelection: extend)
    }

    override func deselectRow(_ row: Int) { table?.deselectRow(row) }
    override func deselectAll(_ sender: Any?) { table?.deselectAll(sender) }
    override func scrollRowToVisible(_ row: Int) { table?.scrollRowToVisible(row) }

    override func setDropRow(_ row: Int, dropOperation: NSTableView.DropOperation) {
        table?.setDropRow(row, dropOperation: dropOperation)
    }
}
extension NGTableViewDataSourceAdapter: NGRowsPasteboardWriting {
    private static let writeRowsSelector = NSSelectorFromString("tableView:writeRowsWithIndexes:toPasteboard:")

    /// Whether the data source has only the deprecated `writeRowsWith`, no
    /// pasteboard writers.
    var writesRowsAtOnce: Bool {
        guard let source else { return false }
        return !source.responds(to: #selector(NSTableViewDataSource.tableView(_:pasteboardWriterForRow:)))
            && source.responds(to: Self.writeRowsSelector)
    }

    /// What the data source writes for the rows, as one pasteboard item.
    /// (Called through the runtime: the method is deprecated.)
    func pasteboardWriter(forRows rows: IndexSet, in tableView: NGTableView) -> (any NSPasteboardWriting)? {
        guard let source = source as? NSObject, source.responds(to: Self.writeRowsSelector) else { return nil }
        proxy.table = tableView
        typealias WriteRows = @convention(c) (NSObject, Selector, NSTableView, NSIndexSet, NSPasteboard) -> Bool
        let write = unsafeBitCast(source.method(for: Self.writeRowsSelector), to: WriteRows.self)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard write(source, Self.writeRowsSelector, proxy, rows as NSIndexSet, pasteboard) else { return nil }
        let item = NSPasteboardItem()
        for type in pasteboard.types ?? [] {
            if let data = pasteboard.data(forType: type) { item.setData(data, forType: type) }
        }
        return item.types.isEmpty ? nil : item
    }
}
#endif
