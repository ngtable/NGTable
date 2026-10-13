#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Conditional formats: automatic ranges follow the rows shown and live
/// updates; rules pick colors.
@Suite("Conditional formats")
@MainActor
struct NGConditionalFormatTests {
    typealias Records = NGLiveSortingTests.Records

    @Test func rangesFollowTheRowsShown() throws {
        let records = Records(count: 100)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("name", title: "Name", width: 200)),
            .column(NGTableColumn("profit", title: "Profit", width: 120, format: .number(fractionDigits: 0), conditionalFormat: .dataBar())),
            .column(NGTableColumn("status", title: "Status", width: 100)),
        ]
        table.dataSource = records
        table.layoutSubtreeIfNeeded()
        let ordinal = table.columnOrdinal(of: "profit")
        func range() -> ClosedRange<Double>? { table.resolvedConditionalFormats()[ordinal]?.range }
        let profits = records.records.map(\.profit)
        #expect(range() == profits.min()!...profits.max()!)
        // A live update past the maximum widens it; the summary row shows nothing for it.
        records.records[7].profit = 10_000
        table.reloadData(forRowIndexes: [7], columnIndexes: [1])
        #expect(range()?.upperBound == 10_000)
        // The maximum falls back: the range is walked again once, and kept.
        records.records[7].profit = -10_000
        table.reloadData(forRowIndexes: [7], columnIndexes: [1])
        let others = records.records.map(\.profit)
        #expect(range() == others.min()!...others.max()!)
        #expect(table.summaryCalculators[NGTableView.SummaryKey(columnID: "profit", filter: .all)]?.hasExactMinMax == true)
        #expect(table.summaryText(forColumnID: "profit") == nil || table.summaryText(forColumnID: "profit") == "")
        // The filter's rows only.
        table.rowFilter = NGRowFilter { [weak records] row in records?.records[row].status == "Active" }
        let active = records.records.filter { $0.status == "Active" }.map(\.profit)
        #expect(range() == active.min()!...active.max()!)
        // A fixed range stays.
        var columns = table.tableColumns
        columns[1].conditionalFormat = .colorScale(low: .red, high: .green, range: .fixed(min: 50, max: -50))
        table.columns = columns.map { .column($0) }
        #expect(range() == -50...50)
    }

    @Test func rulesPickTheFirstMatch() {
        let rules = [NGColorRule(.below(0), color: .red), NGColorRule(.between(0, 10), color: .orange), NGColorRule(.above(5), color: .green)]
        #expect(rules.first { $0.matches(-1) }?.color == .red)
        #expect(rules.first { $0.matches(7) }?.color == .orange)
        #expect(rules.first { $0.matches(11) }?.color == .green)
        #expect(NGConditionalFormat.textColor(rules).range == nil)
    }
}
#endif
