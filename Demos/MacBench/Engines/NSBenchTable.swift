//
//  NSBenchTable.swift
//  NGTable Mac Bench
//
//  a bench's rows in AppKit's NSTableView, used the way its docs suggest for many
//  rows that change: view-based, cells reused (`makeView(withIdentifier:)`), targeted updates
//  inside beginUpdates/endUpdates (inserted rows, the last row removed, the changed cells
//  reloaded once at the end of the frame's batch, only those in view). NSTableView doesn't
//  sort: with sort descriptors the app sorts, as apps do: an order of the rows by the first
//  descriptor's values, made again at the end of each batch, and the table reloaded.
//

import AppKit
import NGTable

final class NSBenchTable: NSObject, BenchTable, NSTableViewDataSource, NSTableViewDelegate {
    let engine = BenchEngine.nsTable
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private unowned let source: BenchRowSource
    private var columns: [NGTableColumn] = []
    private var columnByID: [String: NGTableColumn] = [:]
    /// Display row → data source row while sorted.
    private var order: [Int]?
    private var depth = 0
    /// Rows to reload at the end of the batch, and their columns.
    private var pendingRows = IndexSet()
    private var pendingColumns = IndexSet()
    private var structureChanged = false
    var framePresented: ((CFTimeInterval, CFTimeInterval) -> Void)?
    var view: NSView { scrollView }

    /// Whether cells in view get their text in place (`-NSBenchInPlace NO`: reloaded instead).
    private static let updatesInPlace = UserDefaults.standard.object(forKey: "NSBenchInPlace") as? Bool ?? true
    private static let cellID = NSUserInterfaceItemIdentifier("cell")
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    init(source: BenchRowSource) {
        self.source = source
        super.init()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
    }

    // MARK: Columns and rows

    func show(columns items: [NGColumnItem], sort: [NSSortDescriptor]) {
        columns = items.flatMap(\.benchColumns)
        columnByID = Dictionary(columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: false)
            if column.alignment == .trailing { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
        tableView.sortDescriptors = sort
        reloadAll()
    }

    var benchColumnIDs: [String] { tableView.tableColumns.map(\.identifier.rawValue) }
    var benchSortKeys: [String] { tableView.sortDescriptors.compactMap(\.key) }

    func reloadAll() {
        sortRows()
        tableView.reloadData()
    }

    /// The order of the rows by the first sort descriptor (none: the data source's).
    private func sortRows() {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else {
            order = nil
            return
        }
        // (A fast app sort: NGTable's, which reads each row's value once.)
        order = NGSorting.order(ofRows: source.benchRowCount, by: [descriptor]) { [source] _, row in source.benchValue(columnID: key, row: row) }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        reloadAll()
    }

    // MARK: Updates

    func beginUpdates() {
        depth += 1
        if depth == 1, order == nil { tableView.beginUpdates() }
    }

    func endUpdates() {
        depth -= 1
        guard depth == 0 else { return }
        if order != nil {
            // Sorted by the app: the order made again, every row read again.
            if structureChanged || !pendingRows.isEmpty { reloadAll() }
        } else {
            // Only the rows in view: the table walks every index it is given (an app keeping up
            // with a feed does this much).
            let visible = tableView.rows(in: tableView.visibleRect)
            let rows = pendingRows.intersection(IndexSet(integersIn: max(0, visible.lowerBound)..<min(source.benchRowCount, visible.upperBound)))
            // Cells in view get their new text in place (reloading them makes and lays out their
            // views again: under a feed whose hot rows are in view, most of every frame).
            if !Self.updatesInPlace {
                if !rows.isEmpty { tableView.reloadData(forRowIndexes: rows, columnIndexes: pendingColumns) }
            } else { for row in rows {
                for index in pendingColumns where index < tableView.tableColumns.count {
                    let tableColumn = tableView.tableColumns[index]
                    guard let column = columnByID[tableColumn.identifier.rawValue] else { continue }
                    if let field = tableView.view(atColumn: index, row: row, makeIfNecessary: false) as? NSTextField {
                        let text = column.format.string(for: source.benchValue(columnID: column.id, row: row))
                        if field.stringValue != text { field.stringValue = text }
                    } else {
                        tableView.reloadData(forRowIndexes: [row], columnIndexes: [index])
                    }
                }
            } }
            tableView.endUpdates()
        }
        (pendingRows, pendingColumns, structureChanged) = ([], [], false)
    }

    func benchInsertRows(at indexes: IndexSet) {
        structureChanged = true
        guard order == nil else { return }
        tableView.insertRows(at: indexes, withAnimation: [])
    }

    func benchRemoveRowReplacingWithLast(at row: Int) {
        structureChanged = true
        guard order == nil else { return }
        // The last row goes; the removed one shows what the last showed.
        let last = source.benchRowCount
        tableView.removeRows(at: [last], withAnimation: [])
        if row < last {
            pendingRows.insert(row)
            pendingColumns.insert(integersIn: 0..<columns.count)
        }
    }

    func benchReloadRows(_ rows: [Int], columns: IndexSet) {
        pendingColumns.formUnion(columns)
        guard order == nil else {
            if !rows.isEmpty { structureChanged = true }
            return
        }
        // Rows out of view are left out here already (rows don't shift in a feed's batch:
        // inserts go at the end, a removed row's place is taken by the last).
        let visible = tableView.rows(in: tableView.visibleRect)
        for row in rows where row >= visible.lowerBound && row < visible.upperBound { pendingRows.insert(row) }
    }

    func selectAll() { tableView.selectAll(nil) }

    /// The table view (for tests).
    var nsTableView: NSTableView { tableView }
    func search(_ text: String) {}

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { order?.count ?? source.benchRowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = columnByID[tableColumn.identifier.rawValue] else { return nil }
        let field = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = Self.cellID
            field.font = Self.font
            field.lineBreakMode = .byTruncatingTail
            return field
        }()
        let sourceRow = order.map { row < $0.count ? $0[row] : -1 } ?? row
        let value = sourceRow >= 0 ? source.benchValue(columnID: column.id, row: sourceRow) : .empty
        field.stringValue = column.format.string(for: value)
        field.alignment = column.alignment == .trailing ? .right : .left
        return field
    }
}
