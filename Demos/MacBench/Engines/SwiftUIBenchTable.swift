//
//  SwiftUIBenchTable.swift
//  NGTable Mac Bench
//
//  For comparing engines: a bench's rows in SwiftUI's Table, in an NSHostingView.
//  (The app itself has no SwiftUI; this is the one place, and only in Debug and Bench builds.)
//  Used the way SwiftUI's docs show: an @Observable model with the rows as an array of
//  identifiable values (each row's values for every column), changed in place as the store
//  tells what changed (a changed row's values read again, a removed row's place taken by the
//  last one), the columns made with TableColumnForEach. A Table doesn't sort: sorted, the rows
//  are kept in the store's order apart and sorted into the model at the end of each batch.
//

import AppKit
import NGTable
import SwiftUI

struct SwiftUIBenchRow: Identifiable {
    /// A number of its own, given when the row came (a new row's record may have no values,
    /// so no identity, yet; Table requires unique ids).
    let id: Int
    /// The row's values, a column's at its index.
    var values: [NGCellValue]
}

struct SwiftUIBenchColumn: Identifiable {
    let id: String
    let index: Int
    let title: String
    let format: NGValueFormat
    let width: CGFloat
    let isTrailing: Bool
}

/// Rows by a column's values: empty first, numbers and dates by value, text by its characters.
struct SwiftUIBenchComparator: SortComparator, Hashable {
    var column: Int
    var order: SortOrder = .reverse

    func compare(_ lhs: SwiftUIBenchRow, _ rhs: SwiftUIBenchRow) -> ComparisonResult {
        let result = Self.compare(lhs.values[column], rhs.values[column])
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private static func compare(_ a: NGCellValue, _ b: NGCellValue) -> ComparisonResult {
        switch (a, b) {
        case (.number(let x), .number(let y)): x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        case (.date(let x), .date(let y)): x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        case (.text(let x), .text(let y)): x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        case (.empty, .empty): .orderedSame
        case (.empty, _): .orderedAscending
        case (_, .empty): .orderedDescending
        default: .orderedSame
        }
    }
}

@Observable final class SwiftUIBenchModel {
    var rows: [SwiftUIBenchRow] = []
    var columns: [SwiftUIBenchColumn] = []
    var sortOrder: [SwiftUIBenchComparator] = []
    var selection: Set<Int> = []
    @ObservationIgnored var sortChanged: (() -> Void)?
}

struct SwiftUIBenchTableView: View {
    @Bindable var model: SwiftUIBenchModel

    var body: some View {
        Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumnForEach(model.columns) { column in
                TableColumn(column.title, sortUsing: SwiftUIBenchComparator(column: column.index)) { row in
                    Text(column.format.string(for: row.values[column.index]))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .width(column.width)
                .alignment(column.isTrailing ? .trailing : .leading)
            }
        }
        .onChange(of: model.sortOrder) { model.sortChanged?() }
    }
}

final class SwiftUIBenchTable: BenchTable {
    let engine = BenchEngine.swiftUI
    private let model = SwiftUIBenchModel()
    private let hostingView: NSHostingView<SwiftUIBenchTableView>
    private unowned let source: BenchRowSource
    /// The rows in the store's order while sorted (the model's are sorted).
    private var storeRows: [SwiftUIBenchRow] = []
    private var depth = 0
    private var nextID = 0
    var framePresented: ((CFTimeInterval, CFTimeInterval) -> Void)?
    var view: NSView { hostingView }

    init(source: BenchRowSource) {
        self.source = source
        hostingView = NSHostingView(rootView: SwiftUIBenchTableView(model: model))
        model.sortChanged = { [weak self] in self?.sortChanged() }
    }

    private var isSorted: Bool { !model.sortOrder.isEmpty }

    private func makeRow(_ row: Int) -> SwiftUIBenchRow {
        nextID += 1
        return SwiftUIBenchRow(id: nextID, values: model.columns.map { source.benchValue(columnID: $0.id, row: row) })
    }

    /// The rows in the store's order, changed in place.
    private func changeRows(_ body: (inout [SwiftUIBenchRow]) -> Void) {
        if isSorted { body(&storeRows) } else { body(&model.rows) }
    }

    func show(columns items: [NGColumnItem], sort: [NSSortDescriptor]) {
        let columns = items.flatMap(\.benchColumns)
        model.columns = columns.enumerated().map { index, column in
            SwiftUIBenchColumn(id: column.id, index: index, title: column.title, format: column.format, width: column.width,
                               isTrailing: column.alignment == .trailing)
        }
        model.sortOrder = sort.compactMap { descriptor in
            columns.firstIndex { $0.id == descriptor.key }.map { SwiftUIBenchComparator(column: $0, order: descriptor.ascending ? .forward : .reverse) }
        }
        reloadAll()
    }

    var benchColumnIDs: [String] { model.columns.map(\.id) }
    var benchSortKeys: [String] { model.sortOrder.map { model.columns[$0.column].id } }

    func reloadAll() {
        let rows = (0..<source.benchRowCount).map(makeRow)
        if isSorted {
            storeRows = rows
            model.rows = rows.sorted(using: model.sortOrder)
        } else {
            model.rows = rows
        }
    }

    private func sortChanged() {
        // (Turned on: the model's rows were in the store's order.)
        if storeRows.count != source.benchRowCount { storeRows = model.rows }
        model.rows = storeRows.sorted(using: model.sortOrder)
    }

    func beginUpdates() { depth += 1 }

    func endUpdates() {
        depth -= 1
        guard depth == 0, isSorted else { return }
        model.rows = storeRows.sorted(using: model.sortOrder)
    }

    func benchInsertRows(at indexes: IndexSet) {
        changeRows { rows in
            for index in indexes { rows.insert(makeRow(index), at: index) }
        }
    }

    func benchRemoveRowReplacingWithLast(at row: Int) {
        changeRows { rows in
            if row < rows.count - 1 { rows[row] = rows[rows.count - 1] }
            rows.removeLast()
        }
    }

    func benchReloadRows(_ changed: [Int], columns: IndexSet) {
        let ids = columns.compactMap { $0 < model.columns.count ? model.columns[$0].id : nil }
        let indexes = columns.filter { $0 < model.columns.count }
        changeRows { rows in
            for row in changed where row < rows.count {
                for (index, id) in zip(indexes, ids) { rows[row].values[index] = source.benchValue(columnID: id, row: row) }
            }
        }
    }

    func selectAll() { model.selection = Set(model.rows.map(\.id)) }

    /// The rows as the Table gets them (for tests).
    var shownRows: [SwiftUIBenchRow] { model.rows }
    func search(_ text: String) {}
}
