//
//  CampaignsTable.swift
//  NGTable Mac Bench
//
//  Column definition and data source of the campaigns table (NGTable). Column ids are
//  `CampaignColumn` raw values plus a few table-only columns; keep them stable, saved layouts and
//  formulas refer to them.
//
//  A copy of EasyCPA's campaigns table (as of October 2026) for the campaigns bench: the bench
//  shows NGTable on a real app's table. It doesn't follow EasyCPA's changes.

import AppKit
import NGTable

nonisolated enum CampaignsTable {
    // Table-only column ids.
    static let markID = "mark"
    static let networkID = "network"
    static let statusDetailID = "statusDetail"
    /// Not shown: 1 for every row, the input of the row-count summary.
    static let oneID = "_one"

    private static func id(_ column: CampaignColumn) -> String { column.rawValue }

    // MARK: Summary formulas (totals of ratios are ratios of sums, like the web table)

    /// `numerator / denominator` of the sums, or nil when the denominator is 0.
    private static func ratio(_ name: String, _ numerator: CampaignColumn, _ denominator: CampaignColumn) -> NGSummaryFormula {
        let n = id(numerator), d = id(denominator)
        return NGSummaryFormula(name, using: [n, d]) { values in
            guard let bottom = values.sum(d), bottom != 0, let top = values.sum(n) else { return nil }
            return top / bottom
        }
    }

    private static let rowCount = NGSummaryFormula("campaigns.count", using: [oneID]) { values in
        values.sum(oneID) ?? 0
    }

    // MARK: Columns

    private static func column(
        _ column: CampaignColumn,
        width: Double,
        format: NGValueFormat = .automatic,
        summary: NGColumnSummary = .none,
        pin: NGColumnPin = .none,
        isHideable: Bool = true
    ) -> NGTableColumn {
        NGTableColumn(
            id(column),
            title: column.title,
            width: width,
            alignment: column.isNumeric ? .automatic : .leading,
            format: format,
            summary: summary,
            isHideable: isHideable,
            pin: pin,
            toolTip: column.fullTitle == column.title ? nil : column.fullTitle
        )
    }

    private static let usd = NGValueFormat.currency(code: "USD")
    private static let sum = NGColumnSummary.aggregate(.sum)

    static let columns: [NGColumnItem] = [
        // Leading, frozen: mark, id (row count in the summary), name.
        .column(NGTableColumn(markID, title: "", width: 28, alignment: .center,
                              isSortable: true, isResizable: false, isMovable: false,
                              showsHeaderDivider: false, pin: .leading, toolTip: "Отметка")),
        .column(column(.id, width: 64, summary: .formula(rowCount), pin: .leading, isHideable: false)),
        .column(column(.name, width: 240, pin: .leading, isHideable: false)),

        // Common, scrolling.
        .column(NGTableColumn(networkID, title: "Сеть", width: 100)),
        .column(column(.source, width: 140)),
        .column(column(.platforms, width: 150)),
        .column(column(.account, width: 130)),
        .column(column(.group, width: 130)),
        .column(column(.teasers, width: 120)),
        .column(column(.owner, width: 90)),

        .group(NGColumnGroup("group." + CampaignColumnGroup.adNetwork.rawValue, title: CampaignColumnGroup.adNetwork.title ?? "", columns: [
            column(.adClicks, width: 80, format: .number(fractionDigits: 0), summary: sum),
            column(.impressions, width: 95, format: .number(fractionDigits: 0), summary: sum),
            column(.adSpent, width: 95, format: usd, summary: sum),
            column(.adProfit, width: 95, format: usd, summary: sum),
            column(.adRoi, width: 80, format: .percent(fractionDigits: 2), summary: .formula(ratio("campaigns.adRoi", .adProfit, .adSpent))),
            column(.vCtr, width: 75, format: .percent(fractionDigits: 2), summary: .formula(ratio("campaigns.vCtr", .adClicks, .impressions))),
        ])),

        .group(NGColumnGroup("group." + CampaignColumnGroup.conversions.rawValue, title: CampaignColumnGroup.conversions.title ?? "", columns: [
            column(.conversions, width: 70, format: .number(fractionDigits: 0), summary: sum),
            column(.hold, width: 65, format: .number(fractionDigits: 0), summary: sum),
            column(.approved, width: 80, format: .number(fractionDigits: 0), summary: sum),
            column(.approvePercent, width: 85, format: .percent(fractionDigits: 2), summary: .formula(ratio("campaigns.approve", .approved, .conversions))),
            column(.rejected, width: 70, format: .number(fractionDigits: 0), summary: sum),
        ])),

        .group(NGColumnGroup("group." + CampaignColumnGroup.tracker.rawValue, title: CampaignColumnGroup.tracker.title ?? "", columns: [
            column(.clicks, width: 75, format: .number(fractionDigits: 0), summary: sum),
            column(.cr, width: 70, format: .percent(fractionDigits: 2), summary: .formula(ratio("campaigns.cr", .conversions, .clicks))),
            column(.cph, width: 60, format: .number(fractionDigits: 2), summary: .aggregate(.average, including: .nonZero)),
            column(.hours, width: 55, format: .number(fractionDigits: 1), summary: .aggregate(.average, including: .nonZero)),
            column(.revenue, width: 95, format: usd, summary: sum),
            column(.spent, width: 95, format: usd, summary: sum),
            column(.profit, width: 95, format: usd, summary: sum),
            column(.roi, width: 80, format: .percent(fractionDigits: 2), summary: .formula(ratio("campaigns.roi", .profit, .spent))),
            column(.cpl, width: 80, format: usd, summary: .formula(ratio("campaigns.cpl", .spent, .conversions))),
            column(.epl, width: 80, format: usd, summary: .formula(ratio("campaigns.epl", .revenue, .conversions))),
            column(.cpc, width: 75, format: .number(fractionDigits: 3), summary: .formula(ratio("campaigns.cpc", .spent, .clicks))),
            column(.epc, width: 75, format: .number(fractionDigits: 3), summary: .formula(ratio("campaigns.epc", .revenue, .clicks))),
        ])),

        .group(NGColumnGroup("group." + CampaignColumnGroup.guarantee.rawValue, title: CampaignColumnGroup.guarantee.title ?? "", columns: [
            column(.eplG, width: 80, format: usd, summary: .formula(ratio("campaigns.eplG", .revenueG, .conversions))),
            column(.revenueG, width: 95, format: usd, summary: sum),
            column(.epcG, width: 75, format: .number(fractionDigits: 3), summary: .formula(ratio("campaigns.epcG", .revenueG, .clicks))),
            column(.profitG, width: 95, format: usd, summary: sum),
            column(.roiG, width: 80, format: .percent(fractionDigits: 2), summary: .formula(ratio("campaigns.roiG", .profitG, .spent))),
        ])),

        .column(NGTableColumn(statusDetailID, title: "Причина статуса", width: 220)),

        // Trailing, frozen: controls.
        .column(column(.budget, width: 90, format: usd, summary: sum, pin: .trailing)),
        .column(NGTableColumn(CampaignColumn.bid.rawValue, title: CampaignColumn.bid.title, width: 90,
                              alignment: .trailing, pin: .trailing,
                              toolTip: "Цена клика или цель CPA")),
        .column(column(.status, width: 140, pin: .trailing, isHideable: false)),
    ]
}

// MARK: - Data source

/// Rows as received; the table sorts them itself (`sortsRows`; the server has no sort for this list).
///
/// Every cell value is computed once when the data arrives (`replace(with:)`): the table asks for
/// the visible cells on every scroll step, and `valueFor` must be a plain array lookup. Building
/// values on demand (copying the large `CampaignRow`, parsing the column id, allocating tags)
/// made scrolling 18,000 production campaigns stutter.
@MainActor
final class CampaignTableData: NGTableViewDataSource {
    /// Every column id the table can ask for, in a fixed order; `cells` rows follow it.
    private nonisolated static let columnIDs: [String] = CampaignsTable.columns.flatMap { item -> [String] in
        switch item {
        case .column(let column): [column.id]
        case .group(let group): group.columns.map(\.id)
        @unknown default: []
        }
    } + [CampaignsTable.oneID]
    private nonisolated static let columnIndex: [String: Int] = Dictionary(
        uniqueKeysWithValues: columnIDs.enumerated().map { ($1, $0) }
    )
    /// What each of `columnIDs` shows, resolved once: parsing the id of every value of every
    /// campaign was most of the cost of building the cells.
    private nonisolated static let columnKinds: [ColumnKind] = columnIDs.map(ColumnKind.init)

    private enum ColumnKind {
        case one, mark, network, statusDetail, column(CampaignColumn), none

        nonisolated init(_ id: String) {
            switch id {
            case CampaignsTable.oneID: self = .one
            case CampaignsTable.markID: self = .mark
            case CampaignsTable.networkID: self = .network
            case CampaignsTable.statusDetailID: self = .statusDetail
            default: self = CampaignColumn(rawValue: id).map { .column($0) } ?? .none
            }
        }
    }

    /// The values of one campaign, in the order of `columnIDs`.
    private nonisolated static func cells(of row: CampaignRow) -> [NGCellValue] {
        columnKinds.map { value($0, of: row) }
    }

    /// Rows as the model provides them (the "unsorted" order).
    private var received: [CampaignRow] = []
    /// Precomputed values, `cells[receivedIndex][columnIndex]`.
    private var cells: [[NGCellValue]] = []
    private var ids: [Int] = []
    private var problems: [Bool] = []
    /// The data source row of every campaign id: its index in `received` (the table sorts the
    /// rows itself, `sortsRows`, so the data source keeps the order they came in).
    private var rowForID: [Int: Int] = [:]
    var count: Int { received.count }

    /// - Parameter cells: The rows' values (`cells(of:)`), when computed beforehand, e.g. off the
    ///   main thread for a large synthetic data set.
    func replace(with rows: [CampaignRow], cells: [[NGCellValue]]? = nil) {
        received = rows
        self.cells = cells ?? Self.cells(of: rows)
        ids = rows.map(\.id)
        rowForID = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        problems = rows.map { $0.problems?.hasProblems == true }
    }

    /// The cell values of rows, in the order `replace(with:cells:)` expects.
    nonisolated static func cells(of rows: [CampaignRow]) -> [[NGCellValue]] {
        rows.map { cells(of: $0) }
    }

    /// Replaces campaigns in place (same ids, new values) and returns their data source rows, for
    /// `reloadData(forRowIndexes:columnIndexes:)`; the table moves the rows whose sort values changed.
    func update(_ rows: [CampaignRow]) -> IndexSet {
        var changed = IndexSet()
        for row in rows {
            guard let index = rowForID[row.id] else { continue }
            received[index] = row
            cells[index] = Self.cells(of: row)
            problems[index] = row.problems?.hasProblems == true
            changed.insert(index)
        }
        return changed
    }

    // MARK: Row access for the controller

    func id(at row: Int) -> Int { ids[row] }
    func hasProblems(at row: Int) -> Bool { problems[row] }
    func row(of id: Int) -> Int? { rowForID[id] }
    func campaign(at row: Int) -> CampaignRow { received[row] }

    // MARK: NGTableViewDataSource

    func numberOfRows(in tableView: NGTableView) -> Int { received.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        guard let index = Self.columnIndex[column.id] else { return .empty }
        return cells[row][index]
    }

    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? {
        ids[row]
    }

    /// The summaries read every row's numbers: one column lookup per range, not per cell.
    func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        guard let index = Self.columnIndex[column.id] else { return false }
        for (offset, row) in rows.enumerated() {
            values[offset] = cells[row][index].numericValue ?? .nan
        }
        return true
    }

    /// Sorting by a number reads every row's key: one call per column, not per cell. Text
    /// columns answer `false` (the table reads their values).
    func tableView(_ tableView: NGTableView, sortNumbersFor column: NGTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        guard let index = Self.columnIndex[column.id] else { return false }
        let hasOwnKeys = Self.ownSortKeys.contains(column.id)
        for (offset, row) in rows.enumerated() {
            let value = hasOwnKeys ? Self.sortKey(column.id, of: received[row]) : cells[row][index]
            switch value {
            case .number(let number): values[offset] = number
            case .empty: values[offset] = .nan
            default: return false
            }
        }
        return true
    }

    /// Columns that sort by their own keys (see `sortKey(_:of:)`).
    private static let ownSortKeys: Set<String> = [CampaignColumn.id.rawValue, CampaignColumn.teasers.rawValue,
                                                   CampaignColumn.status.rawValue, CampaignColumn.budget.rawValue,
                                                   CampaignColumn.bid.rawValue]

    /// The table sorts the rows itself (`sortsRows`), also as live values change; this is what
    /// it sorts by, where the display differs from the order.
    func tableView(_ tableView: NGTableView, sortValueFor column: NGTableColumn, row: Int) -> NGCellValue {
        Self.sortKey(column.id, of: received[row])
    }

    // MARK: Values

    /// Sort keys differ from displayed values where the display is text but the order is numeric.
    private static func sortKey(_ columnID: String, of row: CampaignRow) -> NGCellValue {
        switch columnID {
        case CampaignColumn.id.rawValue: .number(Double(row.id))
        case CampaignColumn.teasers.rawValue: .number(Double(row.teasersCounts?.total ?? 0))
        case CampaignColumn.status.rawValue: .number(Double(row.status?.sortRank ?? 99))
        case CampaignColumn.budget.rawValue: .number(row.budgetSortValue)
        case CampaignColumn.bid.rawValue: .number(row.bidSortValue)
        default: value(columnID, of: row)
        }
    }

    nonisolated static func value(_ columnID: String, of row: CampaignRow) -> NGCellValue {
        value(ColumnKind(columnID), of: row)
    }

    private nonisolated static func value(_ kind: ColumnKind, of row: CampaignRow) -> NGCellValue {
        let column: CampaignColumn
        switch kind {
        case .one: return .number(1)
        case .mark: return mark(row.mark)
        case .network: return row.network.map { .text($0.displayName) } ?? .empty
        case .statusDetail: return row.statusDetail.map { .text($0) } ?? .empty
        case .none: return .empty
        case .column(let resolved): column = resolved
        }

        switch column {
        case .id: return .text(String(row.id))
        case .name: return .text(row.name)
        case .source: return .text(row.sourceName)
        case .platforms: return .tags(row.platforms.map { NGTag($0.title) })
        case .account: return .text(row.account)
        case .group: return .text(row.groupName)
        case .teasers: return teasers(row)
        case .owner: return .text(row.owner)

        case .adClicks: return .number(Double(row.adClicks))
        case .impressions: return .number(Double(row.impressions))
        case .adSpent: return .number(row.adSpent)
        case .adProfit: return .number(row.adProfit)
        case .adRoi: return .number(row.adRoi / 100)
        case .vCtr: return .number(row.vCtr / 100)

        case .conversions: return .number(Double(row.conversions))
        case .hold: return .number(Double(row.holdConversions))
        case .approved: return .number(Double(row.approvedConversions))
        case .approvePercent: return .number(row.approvePercent / 100)
        case .rejected: return .number(Double(row.rejectedConversions))

        case .clicks: return .number(Double(row.trackerClicks))
        case .cr: return .number(row.cr / 100)
        case .cph: return .number(row.cph)
        case .hours: return .number(row.activeHours)
        case .revenue: return .number(row.revenue)
        case .spent: return .number(row.spent)
        case .profit: return .number(row.profit)
        case .roi: return .number(row.roi / 100)
        case .cpl: return .number(row.cpl)
        case .epl: return .number(row.epl)
        case .cpc: return .number(row.cpc)
        case .epc: return .number(row.epc)

        case .eplG: return .number(row.eplG)
        case .revenueG: return .number(row.revenueG)
        case .epcG: return .number(row.epcG)
        case .profitG: return .number(row.profitG)
        case .roiG: return .number(row.roiG / 100)

        case .budget: return row.budget.map { .number($0) } ?? .text("∞")
        // Click prices need three decimals and CPA goals are marked, so the column shows text.
        case .bid: return row.bid == nil ? .empty : .text(row.bidText)
        case .status: return status(row)
        }
    }

    private nonisolated static func teasers(_ row: CampaignRow) -> NGCellValue {
        guard let counts = row.teasersCounts else { return .empty }
        return .tags([
            NGTag(String(counts.active), color: .green),
            NGTag(String(counts.onModeration), color: .orange),
            NGTag(String(counts.rejected), color: .red),
        ])
    }

    private nonisolated static func status(_ row: CampaignRow) -> NGCellValue {
        if let task = row.currentTask {
            return .tags([NGTag(task.displayName + "…", color: .blue)])
        }
        guard let status = row.status else { return .empty }
        return statusValues[status] ?? .empty
    }

    private nonisolated static let statusValues: [CampaignStatus: NGCellValue] = Dictionary(
        uniqueKeysWithValues: CampaignStatus.allCases.map { ($0, NGCellValue.tags([NGTag($0.displayName, color: $0.tagColor)])) }
    )

    /// Marks are built once per kind: the table asks for every visible row while scrolling.
    private nonisolated static let marks: [CampaignMark: NGCellValue] = Dictionary(
        uniqueKeysWithValues: CampaignMark.allCases.compactMap { mark in
            mark.symbol.map { (mark, NGCellValue.mark(NGMark($0, color: .orange, label: mark.rawValue))) }
        }
    )

    private nonisolated static func mark(_ mark: CampaignMark) -> NGCellValue {
        marks[mark] ?? .empty
    }
}

extension CampaignStatus {
    nonisolated var tagColor: NGNamedColor {
        switch self {
        case .active: .green
        case .isActivating: .blue
        case .pendingReview: .orange
        case .stoppedBySchedule, .stoppedByCap: .yellow
        case .paused: .gray
        case .autoBlocked, .rejected: .red
        case .null, .deleted: .gray
        }
    }
}
