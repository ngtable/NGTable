import NGTable
import SwiftUI
import UIKit

// The engines compared, each the way its framework is meant to be used for
// a live table: NGTable reloads the changed cells in a batch; UITableView
// and UICollectionView reconfigure the visible rows that changed (cells of
// labels in a stack); SwiftUI's Table and List observe each row's object,
// so only the rows that changed draw again. Only NGTable has a summary row.

@MainActor
protocol BenchEngine: AnyObject {
    var title: String { get }
    var controller: UIViewController { get }
    /// The rows were made anew.
    func reload()
    /// These rows' values changed.
    func rowsChanged(_ rows: [Int])
    /// The scroll view a scroll test drives.
    var scrollView: UIScrollView? { get }
}

enum BenchEngineKind: Int, CaseIterable {
    case ngTable, tableView, collectionView, swiftUITable, swiftUIList

    var title: String {
        switch self {
        case .ngTable: "NGTable"
        case .tableView: "UITableView"
        case .collectionView: "UICollectionView"
        case .swiftUITable: "SwiftUI Table"
        case .swiftUIList: "SwiftUI List"
        }
    }

    @MainActor
    func make(data: BenchData) -> BenchEngine {
        switch self {
        case .ngTable: NGTableEngine(data: data)
        case .tableView: TableViewEngine(data: data)
        case .collectionView: CollectionViewEngine(data: data)
        case .swiftUITable: SwiftUIEngine(data: data, usesTable: true)
        case .swiftUIList: SwiftUIEngine(data: data, usesTable: false)
        }
    }
}

// MARK: NGTable

@MainActor
final class NGTableEngine: NSObject, BenchEngine, NGTableViewDataSource {
    let title = "NGTable"
    let controller = UIViewController()
    private let table = NGTableView(frame: .zero)
    private let data: BenchData
    private static let formats: [NGValueFormat] = [.number(fractionDigits: 0), .number(fractionDigits: 0), .currency(code: "USD"),
                                                  .currency(code: "USD"), .currency(code: "USD"), .percent(fractionDigits: 1)]

    init(data: BenchData) {
        self.data = data
        super.init()
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 150, pin: .leading))]
            + BenchData.columnTitles.enumerated().map { index, title in
                .column(NGTableColumn("\(index)", title: title, width: 118, alignment: .trailing, headerAlignment: .trailing,
                                      format: Self.formats[index],
                                      summary: index == 5 ? .aggregate(.average) : .aggregate(.sum)))
            }
        table.dataSource = self
        table.frame = controller.view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(table)
    }

    var scrollView: UIScrollView? { table.subviews.compactMap { $0 as? UIScrollView }.first }

    func reload() { table.reloadData() }

    func rowsChanged(_ rows: [Int]) {
        table.beginUpdates()
        table.reloadData(forRowIndexes: IndexSet(rows), columnIndexes: [3, 5, 6])
        table.endUpdates()
    }

    func numberOfRows(in tableView: NGTableView) -> Int { data.rows.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        let item = data.rows[row]
        guard let index = Int(column.id) else { return .text(item.name) }
        return .number(item.values[index])
    }
}

// MARK: UIKit cells

/// A row of labels: the name and the numbers, in fixed widths.
final class BenchRowView: UIView {
    let labels: [UILabel]

    override init(frame: CGRect) {
        labels = (0...BenchData.columnTitles.count).map { index in
            let label = UILabel()
            label.font = index == 0 ? .systemFont(ofSize: 15) : .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
            label.textAlignment = index == 0 ? .natural : .right
            return label
        }
        super.init(frame: frame)
        labels.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 16
        for (index, label) in labels.enumerated() {
            let width: CGFloat = index == 0 ? 140 : 100
            label.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + 8
        }
    }

    func show(_ row: BenchRow) {
        labels[0].text = row.name
        for (index, value) in row.values.enumerated() {
            labels[index + 1].text = BenchData.text(value, column: index)
        }
    }
}

// MARK: UITableView

@MainActor
final class TableViewEngine: NSObject, BenchEngine, UITableViewDataSource {
    let title = "UITableView"
    let controller = UIViewController()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let data: BenchData

    final class Cell: UITableViewCell {
        let rowView = BenchRowView()
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            rowView.frame = contentView.bounds
            rowView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(rowView)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("made in code") }
    }

    init(data: BenchData) {
        self.data = data
        super.init()
        tableView.register(Cell.self, forCellReuseIdentifier: "row")
        tableView.dataSource = self
        tableView.rowHeight = 24
        tableView.estimatedRowHeight = 24
        tableView.frame = controller.view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(tableView)
    }

    var scrollView: UIScrollView? { tableView }

    func reload() { tableView.reloadData() }

    func rowsChanged(_ rows: [Int]) {
        let visible = Set(tableView.indexPathsForVisibleRows?.map(\.row) ?? [])
        let changed = Set(rows).intersection(visible).map { IndexPath(row: $0, section: 0) }
        if !changed.isEmpty { tableView.reconfigureRows(at: changed) }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { data.rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! Cell
        cell.rowView.show(data.rows[indexPath.row])
        return cell
    }
}

// MARK: UICollectionView

@MainActor
final class CollectionViewEngine: NSObject, BenchEngine, UICollectionViewDataSource {
    let title = "UICollectionView"
    let controller = UIViewController()
    private let collectionView: UICollectionView
    private let data: BenchData

    final class Cell: UICollectionViewCell {
        let rowView = BenchRowView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            rowView.frame = contentView.bounds
            rowView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(rowView)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("made in code") }
    }

    init(data: BenchData) {
        self.data = data
        // A list of fixed-height rows.
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(24)))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(24)),
                                                     subitems: [item])
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group)))
        super.init()
        collectionView.register(Cell.self, forCellWithReuseIdentifier: "row")
        collectionView.dataSource = self
        collectionView.backgroundColor = .systemBackground
        collectionView.frame = controller.view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(collectionView)
    }

    var scrollView: UIScrollView? { collectionView }

    func reload() { collectionView.reloadData() }

    func rowsChanged(_ rows: [Int]) {
        let visible = Set(collectionView.indexPathsForVisibleItems.map(\.item))
        let changed = Set(rows).intersection(visible).map { IndexPath(item: $0, section: 0) }
        if !changed.isEmpty { collectionView.reconfigureItems(at: changed) }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { data.rows.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath) as! Cell
        cell.rowView.show(data.rows[indexPath.item])
        return cell
    }
}

// MARK: SwiftUI

/// The rows the SwiftUI views show (a new array when they're made anew).
@Observable
@MainActor
final class SwiftUIRows {
    var rows: [BenchRow] = []
}

@MainActor
final class SwiftUIEngine: BenchEngine {
    let title: String
    let controller: UIViewController
    private let data: BenchData
    private let model = SwiftUIRows()

    init(data: BenchData, usesTable: Bool) {
        self.data = data
        title = usesTable ? "SwiftUI Table" : "SwiftUI List"
        model.rows = data.rows
        controller = usesTable ? UIHostingController(rootView: AnyView(BenchTable(model: model)))
            : UIHostingController(rootView: AnyView(BenchList(model: model)))
    }

    /// The scroll view SwiftUI makes for the table or list.
    var scrollView: UIScrollView? {
        func find(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for subview in view.subviews { if let scroll = find(subview) { return scroll } }
            return nil
        }
        return find(controller.view)
    }

    func reload() { model.rows = data.rows }

    /// (The rows' objects tell SwiftUI themselves.)
    func rowsChanged(_ rows: [Int]) {}
}

struct BenchTable: View {
    let model: SwiftUIRows

    var body: some View {
        Table(model.rows) {
            TableColumn("Name") { row in Text(row.name) }
            TableColumn(BenchData.columnTitles[0]) { row in BenchNumber(row: row, column: 0) }
            TableColumn(BenchData.columnTitles[1]) { row in BenchNumber(row: row, column: 1) }
            TableColumn(BenchData.columnTitles[2]) { row in BenchNumber(row: row, column: 2) }
            TableColumn(BenchData.columnTitles[3]) { row in BenchNumber(row: row, column: 3) }
            TableColumn(BenchData.columnTitles[4]) { row in BenchNumber(row: row, column: 4) }
            TableColumn(BenchData.columnTitles[5]) { row in BenchNumber(row: row, column: 5) }
        }
    }
}

struct BenchNumber: View {
    let row: BenchRow
    let column: Int

    var body: some View {
        Text(BenchData.text(row.values[column], column: column))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct BenchList: View {
    let model: SwiftUIRows

    var body: some View {
        List(model.rows) { row in
            BenchListRow(row: row)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 24)
    }
}

struct BenchListRow: View {
    let row: BenchRow

    var body: some View {
        HStack(spacing: 8) {
            Text(row.name).frame(width: 140, alignment: .leading)
            ForEach(0..<BenchData.columnTitles.count, id: \.self) { column in
                Text(BenchData.text(row.values[column], column: column))
                    .monospacedDigit()
                    .frame(width: 100, alignment: .trailing)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 15))
        .lineLimit(1)
    }
}
