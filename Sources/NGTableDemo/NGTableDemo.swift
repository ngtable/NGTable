#if os(macOS)
import AppKit
import NGTable
// Required by the Xcode preview engine even though the preview itself is AppKit.
import SwiftUI

/// Sample data of the demo app.
@MainActor
final class NGTableDemoData: NGTableViewDataSource {
    struct Row {
        /// The campaign id, as the CRM's API sends it.
        var id: String
        var name: String
        var city: String
        var income: [Double]
        var expenses: [Double]
        var adSpend: Double
        var adRevenue: Double
        var mark: NGMark?
        var total: Double { income.reduce(0, +) - expenses.reduce(0, +) }
        /// 0% for campaigns that haven't spent anything, as ad platforms report it.
        var roi: Double { adSpend > 0 ? (adRevenue - adSpend) / adSpend : 0 }
    }

    /// The total ROI weighs every campaign by its spend: (Σ revenue − Σ spend) / Σ spend.
    /// Averaging the rows' ROI would let a small campaign with +200% outweigh
    /// a big one with −10%. If the data source has no spend or revenue values,
    /// it falls back to the average of the rows' non-zero ROI.
    static let roiFormula = NGSummaryFormula("roi", using: ["adSpend", "adRevenue"], otherwise: .average, including: .nonZero) { values in
        guard let spend = values.sum("adSpend"), spend != 0, let revenue = values.sum("adRevenue") else { return nil }
        return (revenue - spend) / spend
    }

    static let storeCount = 5
    static let expenseIDs = ["rent", "salary", "logistics"]

    static let columns: [NGColumnItem] = [
        // Untitled, fixed and frozen first: the campaign's mark.
        .column(NGTableColumn("mark", title: "", width: 30, alignment: .center, isResizable: false,
                              isMovable: false, showsHeaderDivider: false, pin: .leading, toolTip: "Mark")),
        .column(NGTableColumn("name", title: "Manager", width: 150, isHideable: false, pin: .leading)),
        .column(NGTableColumn("city", title: "City", width: 110, pin: .leading)),
        .group(NGColumnGroup("income", title: "Income", columns: (1...storeCount).map { index in
            NGTableColumn("store\(index)", title: "Store \(index)", width: 130, format: .currency(code: "EUR"), summary: .aggregate(.sum))
        })),
        .group(NGColumnGroup("expenses", title: "Expenses", columns: [
            NGTableColumn("rent", title: "Rent", width: 100, format: .currency(code: "EUR"), summary: .aggregate(.sum)),
            NGTableColumn("salary", title: "Salaries", width: 100, format: .currency(code: "EUR"), summary: .aggregate(.sum)),
            NGTableColumn("logistics", title: "Logistics", width: 100, format: .currency(code: "EUR"), summary: .aggregate(.average), toolTip: "The average of the rows"),
        ])),
        .group(NGColumnGroup("ads", title: "Ads", columns: [
            NGTableColumn("adSpend", title: "Spend", width: 120, format: .currency(code: "EUR"), summary: .aggregate(.sum)),
            NGTableColumn("adRevenue", title: "Revenue", width: 120, format: .currency(code: "EUR"), summary: .aggregate(.sum)),
            NGTableColumn("roi", title: "ROI %", width: 90, format: .percent(fractionDigits: 1), summary: .formula(roiFormula),
                          toolTip: "Total: (Σ revenue − Σ spend) / Σ spend"),
        ])),
        .column(NGTableColumn("total", title: "Total", width: 120, format: .currency(code: "EUR"), summary: .aggregate(.sum), pin: .trailing, toolTip: "Income minus expenses")),
    ]

    static let sampleMarks: [NGMark?] = [
        NGMark("hand.thumbsup.fill", color: .green, label: "Recommended"),
        NGMark("star.fill", color: .yellow, label: "Favorite"),
        nil,
        NGMark("percent", color: .blue, label: "Discount"),
        NGMark("flame.fill", color: .orange, label: "Hot"),
    ]

    private(set) var rows: [Row]
    /// Rows in their original order, restored when sorting is turned off.
    private let originalRows: [Row]

    init(count: Int = 300) {
        // Deterministic pseudo-random numbers so the preview is stable.
        var seed: UInt64 = 42
        func next(_ range: ClosedRange<Double>) -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(seed >> 11) / Double(1 << 53)
            return (range.lowerBound + unit * (range.upperBound - range.lowerBound)).rounded()
        }
        let names = ["Anna", "Ben", "Clara", "David", "Emma", "Felix", "Grace", "Henry"]
        let cities = ["Berlin", "München", "Hamburg", "Köln", "Leipzig"]
        originalRows = (0..<count).map { index in
            Row(
                id: "CMP-\(10_000 + index)",
                name: "\(names[index % names.count]) #\(index + 1)",
                city: cities[index % cities.count],
                income: (0..<Self.storeCount).map { _ in next(500...9000) },
                expenses: Self.expenseIDs.map { _ in next(200...3000) },
                // Every fifth campaign hasn't started yet: no spend, 0% ROI.
                adSpend: index % 5 == 4 ? 0 : next(100...5000),
                adRevenue: index % 5 == 4 ? 0 : next(0...9000),
                mark: Self.sampleMarks[index % Self.sampleMarks.count]
            )
        }
        rows = originalRows
    }

    func numberOfRows(in tableView: NGTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        value(for: column.id, in: rows[row])
    }

    /// Sorts the rows by the table's descriptors (several columns: the first
    /// decides, the others break ties), or restores their original order.
    func sort(by descriptors: [NSSortDescriptor]) {
        let original = originalRows
        rows = NGSorting.order(ofRows: original.count, by: descriptors) { key, row in
            value(for: key, in: original[row])
        }.map { original[$0] }
    }

    func tableView(_ tableView: NGTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sort(by: tableView.sortDescriptors)
        // The selected campaigns stay selected at their new rows (rowIdentifierColumnID).
        tableView.reloadData()
    }

    private func value(for columnID: String, in row: Row) -> NGCellValue {
        switch columnID {
        case "id": return .text(row.id)
        case "name": return .text(row.name)
        case "city": return .text(row.city)
        case "total": return .number(row.total)
        case "adSpend": return .number(row.adSpend)
        case "adRevenue": return .number(row.adRevenue)
        case "roi": return .number(row.roi)
        case "mark": return row.mark.map(NGCellValue.mark) ?? .empty
        default:
            if columnID.hasPrefix("store"), let index = Int(columnID.dropFirst(5)) {
                return .number(row.income[index - 1])
            }
            if let index = Self.expenseIDs.firstIndex(of: columnID) {
                return .number(row.expenses[index])
            }
            return .empty
        }
    }
}

final class NGTableDemoViewController: NSViewController, NGTableViewDelegate {
    private static let rowCounts = [0, 20, 300, 10_000, 100_000]

    private var data = NGTableDemoData()
    private let table = NGTableView(frame: .zero)
    private let scopeControl = NSSegmentedControl(
        labels: ["All Rows", "Selected Rows", "All but Selected"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let rowCountControl = NSSegmentedControl(
        labels: rowCounts.map { $0.formatted() },
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    private let searchField = NSSearchField()
    private let profitableOnly = NSButton(checkboxWithTitle: "Profitable Only", target: nil, action: nil)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 560))

        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged(_:))
        scopeControl.selectedSegment = 0

        rowCountControl.target = self
        rowCountControl.action = #selector(rowCountChanged(_:))
        rowCountControl.selectedSegment = Self.rowCounts.firstIndex(of: data.rows.count) ?? 0
        rowCountControl.toolTip = "Number of rows"

        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        profitableOnly.target = self
        profitableOnly.action = #selector(filterChanged(_:))

        let controls = NSStackView(views: [searchField, profitableOnly, scopeControl, rowCountControl])
        controls.spacing = 16
        controls.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(controls)

        table.columns = NGTableDemoData.columns
        // Column order, widths and hidden columns survive relaunches.
        table.autosaveName = "NGTableDemo.4"
        table.emptyStateText = "No campaigns in this period"
        // Not a shown column: the data source answers "id" like any other.
        // The selection follows the same campaigns when rows are sorted or reloaded.
        table.rowIdentifierColumnID = "id"
        table.dataSource = data
        table.delegate = self
        table.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(table)

        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 12),
            controls.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            table.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// The table filters; the data source keeps all rows.
    @objc private func filterChanged(_ sender: Any?) {
        var filter = NGRowFilter(searchText: searchField.stringValue)
        if profitableOnly.state == .on {
            filter.isIncluded = { [weak self] row in (self?.data.rows[row].roi ?? 0) > 0 }
        }
        table.rowFilter = filter
        table.emptyStateText = table.rowFilter?.isEmpty == false ? "No matches" : "No campaigns in this period"
    }

    @objc private func scopeChanged(_ sender: NSSegmentedControl) {
        table.summaryScope = NGSummaryScope.allCases[sender.selectedSegment]
    }

    @objc private func rowCountChanged(_ sender: NSSegmentedControl) {
        let count = Self.rowCounts[sender.selectedSegment]
        // Like loading another period from a server: the table fades and
        // ignores the user until the data is there.
        table.dataUpdateText = "Loading \(count.formatted()) campaigns…"
        Task {
            await table.updatingData {
                try? await Task.sleep(for: .milliseconds(800))
                data = NGTableDemoData(count: count)
                // New rows come in the order the table shows as sorted.
                data.sort(by: table.sortDescriptors)
                // Reload first: until then the table still shows the old rows and may ask
                // about them (e.g. their tint), which the new data doesn't have.
                // Setting the data source reloads the table.
                table.dataSource = data
                table.selectRowIndexes([], byExtendingSelection: false)
            }
        }
    }

    func tableView(_ tableView: NGTableView, summaryScopeDidChange scope: NGSummaryScope) {
        scopeControl.selectedSegment = NGSummaryScope.allCases.firstIndex(of: scope) ?? 0
    }

    // Created once: the table asks for every visible row while scrolling.
    private static let profitTint = NSColor.systemGreen.withAlphaComponent(0.10)
    private static let lossTint = NSColor.systemRed.withAlphaComponent(0.10)

    // Profitable campaigns get a pale green row and a green mark, losing ones red.
    func tableView(_ tableView: NGTableView, backgroundColorForRow row: Int) -> NSColor? {
        let roi = data.rows[row].roi
        if roi > 0 { return Self.profitTint }
        if roi < 0 { return Self.lossTint }
        return nil
    }

    func tableView(_ tableView: NGTableView, markerColorForRow row: Int) -> NSColor? {
        let roi = data.rows[row].roi
        if roi > 0 { return .systemGreen }
        if roi < 0 { return .systemRed }
        return nil
    }

    /// The menu is the app's: the table only says which rows it is for.
    func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: NGTableColumn?) -> NSMenu? {
        guard !rows.isEmpty else { return nil }
        let menu = NSMenu()
        let names = rows.prefix(3).map { data.rows[$0].name }.joined(separator: ", ")
        let title = rows.count > 3 ? "\(names) and \(rows.count - 3) more" : names
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy", action: #selector(copyRows(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = rows
        menu.addItem(copy)
        return menu
    }

    @objc private func copyRows(_ sender: NSMenuItem) {
        guard let rows = sender.representedObject as? IndexSet else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(table.copyText(forRows: rows), forType: .string)
    }
}

#Preview("NGTable") {
    NGTableDemoViewController()
}
#endif
