#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Column filters (`NGTableView.columnFilters`): values, ranges and text,
/// with the search and live updates, and the values a filter offers.
@Suite("Column filters")
@MainActor
struct NGColumnFilterTests {
    typealias Records = NGLiveSortingTests.Records

    private func makeTable(_ records: Records) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("name", title: "Name", width: 200)),
            .column(NGTableColumn("profit", title: "Profit", width: 120, format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
            .column(NGTableColumn("status", title: "Status", width: 100)),
        ]
        table.dataSource = records
        table.layoutSubtreeIfNeeded()
        return table
    }

    private func shown(_ table: NGTableView) -> [Int] {
        (0..<table.numberOfRows).map(table.sourceRow)
    }

    /// A large table checks every row on all cores (no condition of the
    /// app's): the same rows as checking them one by one.
    @Test func largeTablesFilterOnAllCores() throws {
        let records = Records(count: NGTableView.parallelFilterRows + 10_000)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.synchronousSearchLimit = .max
        table.hideRows(at: [5, 10, 15, 100])
        table.columnFilters = ["status": .values(["Active"])]
        table.rowFilter = NGRowFilter(searchText: "campaign 1")
        let expected = records.records.indices.filter { row in
            ![5, 10, 15, 100].contains(row) && records.records[row].status == "Active" && String(records.records[row].id).hasPrefix("1")
        }
        #expect(!expected.isEmpty)
        #expect(shown(table) == expected)
    }

    @Test func valuesRangesAndText() {
        let records = Records(count: 300)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.columnFilters = ["status": .values(["Active", "Paused"])]
        #expect(shown(table) == records.records.indices.filter { ["Active", "Paused"].contains(records.records[$0].status) })
        table.columnFilters["profit"] = .range(min: 0, max: 50)
        let expected = records.records.indices.filter {
            ["Active", "Paused"].contains(records.records[$0].status) && (0...50).contains(records.records[$0].profit)
        }
        #expect(shown(table) == expected)
        #expect(table.summaryValue(forColumnID: "profit") == expected.reduce(0) { $0 + records.records[$1].profit })
        // With the search: both apply.
        table.rowFilter = NGRowFilter(searchText: "campaign 1", columnIDs: ["name"])
        #expect(shown(table) == expected.filter { records.records[$0].name.hasPrefix("Campaign 1") })
        table.rowFilter = nil
        // Text: contains, ignoring case.
        table.columnFilters = ["name": .contains("PAIGN 2")]
        #expect(shown(table) == records.records.indices.filter { records.records[$0].name.contains("paign 2") })
        // An open range or empty text lets everything through: dropped.
        table.columnFilters = ["profit": .range(min: nil, max: nil), "name": .contains("")]
        #expect(table.columnFilters.isEmpty)
        #expect(table.numberOfRows == 300)
        // No values: no rows.
        table.columnFilters = ["status": .values([])]
        #expect(table.numberOfRows == 0)
    }

    /// Live updates move rows into and out of the filter, the totals follow.
    @Test func liveUpdatesFollowTheFilters() {
        let records = Records(count: 200)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.columnFilters = ["profit": .range(min: 0, max: nil), "status": .values(["Active"])]
        func expected() -> [Int] {
            records.records.indices.filter { records.records[$0].profit >= 0 && records.records[$0].status == "Active" }
        }
        var generator = SplitMix64(seed: 21)
        for round in 0..<30 {
            table.beginUpdates()
            for _ in 0..<5 {
                let row = Int(generator.next() % UInt64(records.records.count))
                records.records[row].profit = Double(generator.next() % 200) - 100
                records.records[row].status = ["Active", "Paused"][Int(generator.next() % 2)]
                table.reloadData(forRowIndexes: [row], columnIndexes: [1, 2])
            }
            let index = Int(generator.next() % UInt64(records.records.count))
            records.records.insert(.init(id: 1000 + round, name: "New", profit: 5, status: "Active"), at: index)
            table.insertRows(at: [index])
            table.endUpdates()
            #expect(shown(table) == expected(), "round \(round)")
            #expect(table.summaryValue(forColumnID: "profit") == expected().reduce(0) { $0 + records.records[$1].profit }, "round \(round)")
        }
    }

    /// The header's filter popover: unchecking a value filters it out,
    /// "Select All" and "Clear Filter" show every row again; the range fields
    /// set a range.
    @Test func filterPopoverSetsTheFilter() throws {
        let records = Records(count: 100)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.allowsColumnFilters = true
        let status = try #require(table.tableColumns.first { $0.id == "status" })
        let controller = NGColumnFilterViewController(table: table, column: status)
        let window = NSWindow(contentViewController: controller)
        defer { withExtendedLifetime(window) {} }
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? [] + buttons(in: $0) }
        }
        let all = buttons(in: controller.view)
        let finished = try #require(all.first { $0.title.hasPrefix("Finished") })
        finished.performClick(nil)
        // One of three unchecked: excluded (values arriving later stay shown).
        #expect(table.columnFilters["status"] == .excluding(["Finished"]))
        #expect(!shown(table).contains { records.records[$0].status == "Finished" })
        finished.performClick(nil)
        #expect(table.columnFilters["status"] == nil)   // Everything checked: no filter.
        // Two of three unchecked: the checked one is the filter.
        let paused = try #require(all.first { $0.title.hasPrefix("Paused") })
        finished.performClick(nil)
        paused.performClick(nil)
        #expect(table.columnFilters["status"] == .values(["Active"]))
        let clear = try #require(all.first { $0.title == "Clear Filter" || $0.title == "Сбросить фильтр" })
        clear.performClick(nil)
        #expect(table.columnFilters.isEmpty)

        let profit = try #require(table.tableColumns.first { $0.id == "profit" })
        let range = NGColumnFilterViewController(table: table, column: profit)
        let rangeWindow = NSWindow(contentViewController: range)
        defer { withExtendedLifetime(rangeWindow) {} }
        func fields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { (($0 as? NSTextField).flatMap { $0.isEditable ? [$0] : nil } ?? []) + fields(in: $0) }
        }
        let from = try #require(fields(in: range.view).first)
        from.stringValue = "10"
        range.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: from))
        #expect(table.columnFilters["profit"] == .range(min: 10, max: nil))
        #expect(shown(table).allSatisfy { records.records[$0].profit >= 10 })
    }

    /// A column with more values than the list shows: unchecking one hides
    /// only its rows, not the values the list left out.
    @Test func uncheckingAValueAmongManyHidesOnlyIt() throws {
        let records = Records(count: 1_500)
        for index in records.records.indices { records.records[index].name = "Name \(index)" }
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.allowsColumnFilters = true
        let name = try #require(table.tableColumns.first { $0.id == "name" })
        let controller = NGColumnFilterViewController(table: table, column: name)
        let window = NSWindow(contentViewController: controller)
        defer { withExtendedLifetime(window) {} }
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? [] + buttons(in: $0) }
        }
        // (The list shows 1,000 of them: any one it shows.)
        let box = try #require(buttons(in: controller.view).first { $0.title.hasPrefix("Name ") })
        let value = try #require(box.title.components(separatedBy: "  (").first)   // "Name 7  (1)"
        box.performClick(nil)
        #expect(table.columnFilters["name"] == .excluding([value]))
        #expect(table.numberOfRows == 1_499)
        // "Select All" off: no rows, also of the values not listed; then
        // checking one shows only it.
        let all = try #require(buttons(in: controller.view).first { $0.title == "Select All" })
        while all.state != .off { all.performClick(nil) }   // From mixed, a click checks everything first.
        #expect(table.numberOfRows == 0)
        box.performClick(nil)
        #expect(table.columnFilters["name"] == .values([value]))
        #expect(table.numberOfRows == 1)
        // Opened over a filter of some values: checking one more adds it.
        table.columnFilters["name"] = .values(["Name 0", "Name 1"])
        let again = NGColumnFilterViewController(table: table, column: name)
        let otherWindow = NSWindow(contentViewController: again)
        defer { withExtendedLifetime(otherWindow) {} }
        let other = try #require(buttons(in: again.view).first { $0.title.hasPrefix("Name ") && $0.state == .off })
        let otherValue = try #require(other.title.components(separatedBy: "  (").first)
        other.performClick(nil)
        #expect(table.columnFilters["name"] == .values(["Name 0", "Name 1", otherValue]))
        #expect(table.numberOfRows == 3)
        // Everything checked again: no filter.
        let allAgain = try #require(buttons(in: again.view).first { $0.title == "Select All" })
        while allAgain.state != .on { allAgain.performClick(nil) }
        #expect(table.columnFilters["name"] == nil)
        #expect(table.numberOfRows == 1_500)
    }

    /// The offered values follow the search and hidden rows too, and a search
    /// keystroke doesn't read the filtered column again.
    @Test func offeredValuesFollowTheSearchAndKeystrokesDontReadFilteredValues() {
        let records = Records(count: 300)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.rowFilter = NGRowFilter(searchText: "Campaign 1")
        let searched = (0..<table.numberOfRows).map { table.sourceRow($0) }
        #expect(table.filterValues(forColumnID: "status").reduce(0) { $0 + $1.count } == searched.count)
        table.hideRows(at: IndexSet(searched.prefix(3)))
        #expect(table.filterValues(forColumnID: "status").reduce(0) { $0 + $1.count } == searched.count - 3)
        // Keystrokes with a column filter: its column isn't read again.
        final class Counting: NGTableViewDataSource {
            let base: Records
            var statusReads = 0
            init(_ base: Records) { self.base = base }
            func numberOfRows(in tableView: NGTableView) -> Int { base.numberOfRows(in: tableView) }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
                if column.id == "status" { statusReads += 1 }
                return base.tableView(tableView, valueFor: column, row: row)
            }
        }
        let counting = Counting(records)
        let other = makeTable(records)
        other.dataSource = counting
        other.columnFilters = ["status": .excluding(["Finished"])]
        other.rowFilter = NGRowFilter(searchText: "Campaign 1")
        counting.statusReads = 0
        other.rowFilter = NGRowFilter(searchText: "Campaign 12")
        other.rowFilter = NGRowFilter(searchText: "Campaign 123")
        #expect(counting.statusReads < 50)   // Visible cells only, not every row.
        #expect((0..<other.numberOfRows).allSatisfy { records.records[other.sourceRow($0)].status != "Finished" })
        withExtendedLifetime(counting) {}
    }

    /// Typing on narrows the search to the rows that matched: the same rows
    /// as searching afresh, also going back and after live updates.
    @Test func typingOnMatchesLikeAFreshSearch() {
        let records = Records(count: 400)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        func fresh(_ text: String) -> [Int] {
            let other = makeTable(records)
            other.rowFilter = NGRowFilter(searchText: text)
            return shown(other)
        }
        for text in ["c", "ca", "campaign 1", "campaign 12", "campaign 1", "campaign 12 a", "p", "pa"] {
            table.rowFilter = NGRowFilter(searchText: text)
            #expect(shown(table) == fresh(text), "\(text)")
        }
        // A record renamed while narrowed, then typing on.
        table.rowFilter = NGRowFilter(searchText: "campaign 1")
        records.records[5].name = "Campaign 13 renamed"
        table.reloadData(forRowIndexes: [5], columnIndexes: [0])
        table.rowFilter = NGRowFilter(searchText: "campaign 13")
        #expect(shown(table) == fresh("campaign 13"))
        #expect(shown(table).contains(5))
    }

    /// A column filter cleared and set again checks the rows as they are
    /// now: values changed and handles reused while it was off count.
    @Test func aFilterSetAgainSeesChangesMadeWhileItWasOff() {
        let records = Records(count: 100)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let filter: [String: NGColumnFilter] = ["status": .values(["Active"])]
        table.columnFilters = filter
        guard let changed = records.records.indices.first(where: { records.records[$0].status == "Active" }) else { Issue.record("no Active row"); return }
        table.columnFilters = [:]
        records.records[changed].status = "Paused"
        table.reloadData(forRowIndexes: [changed], columnIndexes: [2])
        // A record goes and another comes (it may take the freed handle).
        records.records.remove(at: 50)
        table.removeRows(at: [50])
        records.records.insert(.init(id: 900, name: "New", profit: 1, status: "Active"), at: 50)
        table.insertRows(at: [50])
        table.columnFilters = filter
        #expect(shown(table) == records.records.indices.filter { records.records[$0].status == "Active" })
    }

    /// Typing on over enough rows that most matches drop out at once (the
    /// filtered and sorted orders are built again, not placed row by row),
    /// sorted by the table or not, with a column filter or not, and with
    /// live updates between keystrokes: the same rows, in the same order,
    /// with the same totals as a fresh table.
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func typingOnManyRowsMatchesAFreshTable(sorted: Bool, filtered: Bool) {
        let records = Records(count: 9_000)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        func configure(_ table: NGTableView) {
            if sorted {
                table.sortsRows = true
                table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
            }
            if filtered { table.columnFilters = ["status": .values(["Active", "Paused"])] }
        }
        configure(table)
        func check(_ text: String) {
            let other = makeTable(records)
            configure(other)
            other.rowFilter = NGRowFilter(searchText: text, columnIDs: ["name"])
            #expect(shown(table) == shown(other), "\(text)")
            #expect(table.summaryValue(forColumnID: "profit") == other.summaryValue(forColumnID: "profit"), "\(text)")
        }
        var generator = SplitMix64(seed: 17)
        for text in ["campaign", "campaign 1", "campaign 12", "campaign", "campaign 8"] {
            table.rowFilter = NGRowFilter(searchText: text, columnIDs: ["name"])
            check(text)
            // A few records change name, profit and status meanwhile.
            table.beginUpdates()
            for _ in 0..<5 {
                let row = Int(generator.next() % UInt64(records.records.count))
                records.records[row].name = "Campaign \(generator.next() % 2_000)"
                records.records[row].profit = Double(generator.next() % 400) - 200
                records.records[row].status = ["Active", "Paused", "Finished"][Int(generator.next() % 3)]
                table.reloadData(forRowIndexes: [row], columnIndexes: [0, 1, 2])
            }
            table.endUpdates()
            check(text)
        }
    }

    /// The values a filter offers: displayed text with counts, among the rows
    /// the other filters let through; saved with the layout.
    @Test func offeredValuesAndAutosave() throws {
        let records = Records(count: 300)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let all = table.filterValues(forColumnID: "status")
        #expect(all.map(\.value) == ["Active", "Finished", "Paused"])
        #expect(all.reduce(0) { $0 + $1.count } == 300)
        table.columnFilters = ["profit": .range(min: 50, max: nil), "status": .values(["Active"])]
        // The status filter's own values ignore it, but follow the profit filter.
        let offered = table.filterValues(forColumnID: "status")
        #expect(offered.reduce(0) { $0 + $1.count } == records.records.filter { $0.profit >= 50 }.count)
        // Saved and restored with the layout.
        let state = table.columnLayoutState
        let data = try PropertyListEncoder().encode(state)
        let decoded = try PropertyListDecoder().decode(NGColumnLayoutState.self, from: data)
        #expect(decoded.filters == table.columnFilters)
        let other = makeTable(records)
        other.columnLayoutState = decoded
        #expect(shown(other) == shown(table))
        // An older state without filters keeps the current ones.
        other.columnLayoutState = NGColumnLayoutState(order: ["name", "profit", "status"])
        #expect(other.columnFilters == table.columnFilters)
    }
}
#endif
