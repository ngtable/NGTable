#if os(macOS)
import AppKit
import Observation
import SwiftUI
import Testing
@testable import NGTable

/// Rows that are `@Observable` objects, as a SwiftUI `Table`'s cells follow
/// them: a change inside a row reaches its cells, the summary, the sort and
/// the search, without a new array; many changes are read once.
@Suite("SwiftUI table of observable rows")
@MainActor
struct NGObservableRowsTests {
    @Observable
    final class Campaign: Identifiable {
        let id: Int
        var name: String
        var spend: Double
        init(id: Int, name: String, spend: Double) {
            self.id = id
            self.name = name
            self.spend = spend
        }
    }

    /// (Changes are read on later turns of the main thread, which a busy
    /// suite's other tests hold for a while: the waits are long.)
    @Test func changesInsideRowsReachTheTable() async throws {
        let rows = (1...20).map { Campaign(id: $0, name: "C\($0)", spend: Double($0)) }
        let view = NGDataTable(rows) {
            NGDataColumn("Name", value: \.name)
            NGDataColumn("Spend", value: \.spend, summary: .aggregate(.sum))
        }
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((window, rows)) {} }
        func find(_ view: NSView) -> NGTableView? {
            if let table = view as? NGTableView { return table }
            return view.subviews.lazy.compactMap(find).first
        }
        let table = try #require(find(hosting))
        let spend = "\\Campaign.spend"
        #expect(table.summaryValue(forColumnID: spend) == 210)
        // A row changes inside: the summary and its cell follow.
        rows[0].spend = 101
        try await eventually { table.summaryValue(forColumnID: spend) == 310 }
        #expect(table.summaryValue(forColumnID: spend) == 310)
        let column = try #require(table.tableColumns.last)
        let row = try #require(table.displayRow(forSourceRow: 0))
        #expect(table.accessibilityText(row: row, column: column) == column.format.string(for: .number(101)))
        // Sorted by the table: a change moves the row.
        table.sortDescriptors = [NSSortDescriptor(key: spend, ascending: false)]
        #expect(table.sourceRow(0) == 0)
        rows[5].spend = 1_000
        try await eventually { table.sourceRow(0) == 5 }
        #expect(table.sourceRow(0) == 5)
        // Many changes, read once: one batch.
        let coordinator = try #require(table.dataSource as? NGDataTableCoordinator<Campaign>)
        let (batches, reloaded) = (coordinator.observedBatches, coordinator.observedRowsReloaded)
        for campaign in rows { campaign.spend += 1 }
        let total = rows.reduce(0) { $0 + $1.spend }
        try await eventually { table.summaryValue(forColumnID: spend) == total }
        #expect(table.summaryValue(forColumnID: spend) == total)
        #expect(coordinator.observedBatches - batches == 1)
        #expect(coordinator.observedRowsReloaded - reloaded == rows.count)
        // Search follows text changes too.
        table.rowFilter = NGRowFilter(searchText: "zebra")
        #expect(table.numberOfRows == 0)
        rows[3].name = "Zebra"
        try await eventually { table.numberOfRows == 1 }
        #expect(table.numberOfRows == 1)
    }
}
#endif
