//
//  BenchTable.swift
//  NGTable Mac Bench
//
//  the table a live bench (the feed, Binance) shows its rows in, whichever engine
//  draws it: NGTable, AppKit's NSTableView or SwiftUI's Table, to compare them on the same data.
//  The stores tell it what changed through `BenchRowUpdates` (rows inserted, a row removed with
//  the last one put in its place, cells changed) and give it values through `BenchRowSource`;
//  everything before (network, decoding, the frame's batch) is the same for every engine.
//  `MainThreadLoad` measures how busy the main thread is, whatever runs on it: applying,
//  layout, drawing (the apply time alone leaves out what AppKit and SwiftUI do later).
//

import AppKit
import NGTable

/// What a store tells the table about its rows.
@MainActor protocol BenchRowUpdates: AnyObject {
    /// Column ids in the table's order, and the keys rows are sorted by.
    var benchColumnIDs: [String] { get }
    var benchSortKeys: [String] { get }
    func benchInsertRows(at indexes: IndexSet)
    /// The data source removed `row` and put its last row there.
    func benchRemoveRowReplacingWithLast(at row: Int)
    func benchReloadRows(_ rows: [Int], columns: IndexSet)
}

extension NGTableView: BenchRowUpdates {
    var benchColumnIDs: [String] { tableColumns.map(\.id) }
    var benchSortKeys: [String] { sortDescriptors.compactMap(\.key) }
    func benchInsertRows(at indexes: IndexSet) { insertRows(at: indexes) }
    func benchRemoveRowReplacingWithLast(at row: Int) { removeRowReplacingWithLast(at: row) }
    func benchReloadRows(_ rows: [Int], columns: IndexSet) { reloadData(forRows: rows, columnIndexes: columns) }
}

/// The rows a bench shows (its store).
@MainActor protocol BenchRowSource: NGTableViewDataSource {
    var benchRowCount: Int { get }
    func benchValue(columnID: String, row: Int) -> NGCellValue
}

enum BenchEngine: String, CaseIterable {
    case ngTable, nsTable, swiftUI

    var title: String {
        switch self {
        case .ngTable: "NGTable"
        case .nsTable: "NSTableView"
        case .swiftUI: "SwiftUI Table"
        }
    }

    /// A table of this engine showing a source's rows.
    @MainActor func makeTable(source: BenchRowSource) -> BenchTable {
        switch self {
        case .ngTable: NGBenchTable(source: source)
        case .nsTable: NSBenchTable(source: source)
        case .swiftUI: SwiftUIBenchTable(source: source)
        }
    }
}

/// A bench's table, whichever engine draws it.
@MainActor protocol BenchTable: BenchRowUpdates {
    var engine: BenchEngine { get }
    var view: NSView { get }
    /// Its columns and their order; the rows are read again.
    func show(columns: [NGColumnItem], sort: [NSSortDescriptor])
    /// Every row read again (a snapshot came).
    func reloadAll()
    func beginUpdates()
    func endUpdates()
    func selectAll()
    /// Rows with this text alone (NGTable only: the others show every row).
    func search(_ text: String)
    /// When a frame of rows was drawn and showed (NGTable only: `NGTableView.framePresented`).
    var framePresented: ((_ drawnAt: CFTimeInterval, _ presentedAt: CFTimeInterval) -> Void)? { get set }
}

extension NGColumnItem {
    /// Its columns (a group's, in order).
    var benchColumns: [NGTableColumn] {
        switch self {
        case .column(let column): [column]
        case .group(let group): group.columns
        }
    }
}

/// NGTable: it sorts, filters and groups the rows itself, as they change.
final class NGBenchTable: BenchTable {
    let engine = BenchEngine.ngTable
    let table = NGTableView(frame: .zero)
    var view: NSView { table }

    init(source: BenchRowSource) {
        table.sortsRows = true
        table.allowsColumnFilters = true
        table.allowsUserGrouping = true
        table.emptyStateText = "Нет строк"
        table.dataSource = source
    }

    var benchColumnIDs: [String] { table.benchColumnIDs }
    var benchSortKeys: [String] { table.benchSortKeys }
    func benchInsertRows(at indexes: IndexSet) { table.insertRows(at: indexes) }
    func benchRemoveRowReplacingWithLast(at row: Int) { table.removeRowReplacingWithLast(at: row) }
    func benchReloadRows(_ rows: [Int], columns: IndexSet) { table.reloadData(forRows: rows, columnIndexes: columns) }

    func show(columns: [NGColumnItem], sort: [NSSortDescriptor]) {
        table.columns = columns
        table.sortDescriptors = sort
    }

    func reloadAll() { table.reloadData() }
    func beginUpdates() { table.beginUpdates() }
    func endUpdates() { table.endUpdates() }
    func selectAll() { table.selectAll(nil) }

    func search(_ text: String) {
        table.rowFilter = text.isEmpty ? nil : NGRowFilter(searchText: text)
        table.emptyStateText = table.rowFilter == nil ? "Нет строк" : "Ничего не найдено"
    }

    var framePresented: ((CFTimeInterval, CFTimeInterval) -> Void)? {
        get { table.framePresented }
        set { table.framePresented = newValue }
    }
}

/// How busy the main thread is: the time its run loop didn't wait, of the time measured.
@MainActor final class MainThreadLoad {
    private var observer: CFRunLoopObserver?
    private var waitStart: CFTimeInterval?
    private var waited: CFTimeInterval = 0
    private var start = CACurrentMediaTime()

    init() {
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue,
                                                      true, Int.max) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .beforeWaiting {
                    self.waitStart = now
                } else if let started = self.waitStart {
                    self.waited += now - started
                    self.waitStart = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    isolated deinit {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }

    /// The share of the time since the last call the main thread was busy, and starts again.
    func takeBusyShare() -> Double {
        let now = CACurrentMediaTime()
        var waited = waited
        if let waitStart { waited += now - waitStart; self.waitStart = now }
        let elapsed = max(now - start, 1e-9)
        (start, self.waited) = (now, 0)
        return min(1, max(0, 1 - waited / elapsed))
    }
}
