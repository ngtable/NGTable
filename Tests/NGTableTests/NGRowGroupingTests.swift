#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Campaigns with a network and a status to group by, and amounts to subtotal.
@MainActor
private final class CampaignsDataSource: NGTableViewDataSource {
    struct Campaign { var name: String; var network: String; var status: String; var spend: Double; var revenue: Double }
    var campaigns: [Campaign] = [
        Campaign(name: "A", network: "X", status: "active", spend: 10, revenue: 20),
        Campaign(name: "B", network: "Y", status: "paused", spend: 5, revenue: 0),
        Campaign(name: "C", network: "X", status: "paused", spend: 20, revenue: 10),
        Campaign(name: "D", network: "Z", status: "active", spend: 1, revenue: 4),
        Campaign(name: "E", network: "Y", status: "active", spend: 4, revenue: 8),
        Campaign(name: "F", network: "X", status: "active", spend: 2, revenue: 2),
    ]

    func numberOfRows(in tableView: NGTableView) -> Int { campaigns.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        let campaign = campaigns[row]
        return switch column.id {
        case "name": .text(campaign.name)
        case "network": campaign.network.isEmpty ? .empty : .text(campaign.network)
        case "status": .text(campaign.status)
        case "spend": .number(campaign.spend)
        case "revenue": .number(campaign.revenue)
        default: .empty
        }
    }
}

@MainActor
private final class GroupDelegate: NGTableViewDelegate {
    var expanded: [NGRowGroup] = []
    var collapsed: [NGRowGroup] = []
    var selectionChanges = 0
    var titles: [String: String] = [:]

    func tableView(_ tableView: NGTableView, titleFor group: NGRowGroup) -> String? { titles[group.key] }
    func tableViewGroupDidExpand(_ notification: Notification) {
        if let group = notification.userInfo?["NGRowGroup"] as? NGRowGroup { expanded.append(group) }
    }
    func tableViewGroupDidCollapse(_ notification: Notification) {
        if let group = notification.userInfo?["NGRowGroup"] as? NGRowGroup { collapsed.append(group) }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanges += 1 }
}

@Suite("Row grouping")
@MainActor
struct NGRowGroupingTests {
    private static let roi = NGSummaryFormula("roi", using: ["spend", "revenue"]) { values in
        guard let spend = values.sum("spend"), spend != 0 else { return nil }
        return ((values.sum("revenue") ?? 0) - spend) / spend * 100
    }

    private func makeTable(grouping: NGRowGrouping? = NGRowGrouping(columnID: "network")) -> (NGTableView, CampaignsDataSource) {
        let dataSource = CampaignsDataSource()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        table.columns = [
            .column(NGTableColumn("name", title: "Name", width: 200, pin: .leading)),
            .column(NGTableColumn("status", title: "Status", width: 100)),
            .column(NGTableColumn("spend", title: "Spend", width: 100, format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
            .column(NGTableColumn("revenue", title: "Revenue", width: 100, format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
            .column(NGTableColumn("roi", title: "ROI", width: 100, format: .number(fractionDigits: 0), summary: .formula(Self.roi))),
        ]
        table.dataSource = dataSource
        table.rowGrouping = grouping
        table.layoutSubtreeIfNeeded()
        return (table, dataSource)
    }

    /// The display rows: data source rows, and group keys for header rows.
    private func display(_ table: NGTableView) -> [String] {
        (0..<table.numberOfRows).map { row in
            if let node = table.groupNode(atDisplayRow: row) { return "[\(table.groupTree.nodes[node].group.key)]" }
            return "\(table.sourceRow(row))"
        }
    }

    @Test func rowsGatherUnderHeadersInTheOrderOfTheirFirstRow() {
        let (table, tableSource) = makeTable()
        defer { withExtendedLifetime(tableSource) {} }
        #expect(display(table) == ["[X]", "0", "2", "5", "[Y]", "1", "4", "[Z]", "3"])
        #expect(table.numberOfRows == 9)
        #expect(table.numberOfSourceRows == 6)
        #expect(table.topLevelGroups.map(\.key) == ["X", "Y", "Z"])
        #expect(table.rowIndexes(in: table.topLevelGroups[0]) == [0, 2, 5])
        #expect(table.group(forRow: 4)?.key == "Y")
        #expect(table.group(forRow: 4)?.value == .text("Y"))
        // Header rows have no data source row.
        #expect(table.sourceRow(0) == -1)
        #expect(table.displayRow(forSourceRow: 3) == 8)
        // Without grouping the rows come back as they are.
        table.rowGrouping = nil
        #expect(display(table) == ["0", "1", "2", "3", "4", "5"])
    }

    /// Subtotals use the summary row's aggregates and formulas over each
    /// group's rows; the summary row still covers every row.
    @Test func headersShowTitlesCountsAndSubtotals() {
        let (table, tableSource) = makeTable()
        defer { withExtendedLifetime(tableSource) {} }
        let x = table.groupTree.nodeOfGroup[table.topLevelGroups[0]]!
        let subtotals = table.subtotalTexts(ofNode: x)
        #expect(subtotals["spend"] == "32")
        #expect(subtotals["revenue"] == "32")
        #expect(subtotals["roi"] == "0")
        #expect(subtotals["name"] == nil)
        #expect(table.summaryValue(forColumnID: "spend") == 42)

        // The title spans the frozen name column; subtotals sit in their columns.
        guard let title = table.visibleCell(row: 0, columnID: "name"),
              case .groupTitle(let content) = title.content else {
            Issue.record("No title cell")
            return
        }
        #expect(content.title == "X")
        #expect(content.detail == "3")
        #expect(content.isExpanded)
        guard let spend = table.visibleCell(row: 0, columnID: "spend"),
              case .subtotal(let text, _) = spend.content else {
            Issue.record("No subtotal cell")
            return
        }
        #expect(text == "32")
        #expect(table.visibleCell(row: 0, columnID: "status") == nil)
        #expect(table.rowColor(0) === NGTableView.groupRowColor)
    }

    @Test func collapsingHidesRowsAndKeepsTheSelectionThatStaysShown() {
        let (table, tableSource) = makeTable()
        defer { withExtendedLifetime(tableSource) {} }
        let delegate = GroupDelegate()
        table.delegate = delegate
        table.selectRowIndexes([2, 4], byExtendingSelection: false)
        delegate.selectionChanges = 0
        let x = table.topLevelGroups[0]
        table.collapseGroup(x)
        #expect(!table.isGroupExpanded(x))
        #expect(display(table) == ["[X]", "[Y]", "1", "4", "[Z]", "3"])
        #expect(table.selectedRowIndexes == [4])
        #expect(delegate.collapsed == [x])
        #expect(delegate.selectionChanges == 1)
        // The header shows the collapsed chevron.
        guard let title = table.visibleCell(row: 0, columnID: "name"),
              case .groupTitle(let content) = title.content else {
            Issue.record("No title cell")
            return
        }
        #expect(!content.isExpanded)
        // A click on the header toggles it back.
        table.toggleGroup(atDisplayRow: 0, includingChildren: false)
        #expect(delegate.expanded == [x])
        #expect(display(table) == ["[X]", "0", "2", "5", "[Y]", "1", "4", "[Z]", "3"])
        #expect(table.selectedRowIndexes == [4])
        withExtendedLifetime(delegate) {}
    }

    @Test func headersAreNeverSelected() {
        let (table, tableSource) = makeTable()
        defer { withExtendedLifetime(tableSource) {} }
        table.selectAll(nil)
        #expect(table.selectedRowIndexes == IndexSet(0..<6))
        #expect(table.numberOfSelectedRows == 6)
        // Only headers: nothing to select.
        table.selectDisplayRows([0, 4], byExtendingSelection: false)
        #expect(table.selectedRowIndexes.isEmpty)
        // The arrow keys stop on headers without selecting them.
        let (fresh, freshSource) = makeTable()
        defer { withExtendedLifetime(freshSource) {} }
        fresh.moveDown(nil)
        #expect(fresh.selectedRowIndexes == [0])
        fresh.moveDown(nil)
        fresh.moveDown(nil)
        #expect(fresh.selectedRowIndexes == [5])
        fresh.moveDown(nil)
        #expect(fresh.selectedRowIndexes.isEmpty)
        #expect(fresh.keyboardGroup?.key == "Y")
        fresh.moveDown(nil)
        #expect(fresh.selectedRowIndexes == [1])
        fresh.moveUp(nil)
        fresh.moveUp(nil)
        #expect(fresh.selectedRowIndexes == [5])
        // Shift extends over rows only.
        fresh.moveDownAndModifySelection(nil)
        #expect(fresh.selectedRowIndexes == [5, 1])
    }

    /// Summaries of the selection count the selected records, wherever the
    /// grouping shows them.
    @Test func selectionSummariesFollowTheRecords() {
        let (table, tableSource) = makeTable()
        defer { withExtendedLifetime(tableSource) {} }
        table.summaryScope = .selectedRows
        table.selectRowIndexes([0, 1], byExtendingSelection: false)
        #expect(table.summaryValue(forColumnID: "spend") == 15)
        table.summaryScope = .excludingSelectedRows
        #expect(table.summaryValue(forColumnID: "spend") == 27)
        table.rowFilter = NGRowFilter(isIncluded: { $0 != 2 })
        #expect(table.rowMap == [0, 1, 3, 4, 5])
        #expect(table.summarySelection == [0, 1])
        #expect(table.selectedRowIndexes == [0, 1])
        table.summaryScope = .allRows
        #expect(table.summaryValue(forColumnID: "spend") == 22)
        table.summaryScope = .excludingSelectedRows
        #expect(table.summaryValue(forColumnID: "spend") == 7)
    }

    @Test func groupsNestByLevel() {
        let (table, tableSource) = makeTable(grouping: NGRowGrouping(columnIDs: ["network", "status"]))
        defer { withExtendedLifetime(tableSource) {} }
        #expect(display(table) == ["[X]", "[active]", "0", "5", "[paused]", "2",
                                   "[Y]", "[paused]", "1", "[active]", "4", "[Z]", "[active]", "3"])
        let x = table.topLevelGroups[0]
        let children = table.childGroups(of: x)
        #expect(children.map(\.path) == [["X", "active"], ["X", "paused"]])
        #expect(children[0].level == 1)
        #expect(children[0].parent == x)
        #expect(children[0].isWithin(x))
        let xActive = table.groupTree.nodeOfGroup[children[0]]!
        #expect(table.subtotalTexts(ofNode: xActive)["spend"] == "12")
        // Collapsing with the children collapses them too.
        table.collapseGroup(x, collapseChildren: true)
        table.expandGroup(x)
        #expect(Array(display(table).prefix(4)) == ["[X]", "[active]", "[paused]", "[Y]"])
        guard let title = table.visibleCell(row: 1, columnID: "name"),
              case .groupTitle(let content) = title.content else {
            Issue.record("No title cell")
            return
        }
        #expect(content.level == 1)
    }

    @Test func expandingAndCollapsingAll() {
        let (table, tableSource) = makeTable(grouping: NGRowGrouping(columnID: "network", startsCollapsed: true))
        defer { withExtendedLifetime(tableSource) {} }
        #expect(display(table) == ["[X]", "[Y]", "[Z]"])
        table.expandGroup(nil, expandChildren: true)
        #expect(table.numberOfRows == 9)
        table.collapseGroup(nil, collapseChildren: true)
        #expect(table.numberOfRows == 3)
        table.expandGroup(nil)
        #expect(table.numberOfRows == 9)
    }

    @Test func theFilterDecidesWhichRowsAreGrouped() {
        let (table, dataSource) = makeTable()
        table.rowFilter = NGRowFilter(isIncluded: { dataSource.campaigns[$0].spend >= 4 })
        #expect(display(table) == ["[X]", "0", "2", "[Y]", "1", "4"])
        let x = table.groupTree.nodeOfGroup[table.topLevelGroups[0]]!
        #expect(table.subtotalTexts(ofNode: x)["spend"] == "30")
        // A search shows the matching rows' groups only.
        table.rowFilter = NGRowFilter(searchText: "paused", columnIDs: ["status"])
        #expect(display(table) == ["[Y]", "1", "[X]", "2"])
        withExtendedLifetime(dataSource) {}
    }

    /// Values that don't group change only their groups' subtotals; the
    /// groups stay as they are.
    @Test func changedMetricsKeepTheGroups() {
        let (table, dataSource) = makeTable()
        let tree = table.groupTree.nodes.map(\.group)
        let y = table.groupTree.nodeOfGroup[table.topLevelGroups[1]]!
        let z = table.groupTree.nodeOfGroup[table.topLevelGroups[2]]!
        #expect(table.subtotalTexts(ofNode: y)["spend"] == "9")
        #expect(table.subtotalTexts(ofNode: z)["spend"] == "1")
        dataSource.campaigns[4].spend = 40   // E, in Y.
        table.reloadData(forRowIndexes: [4], columnIndexes: IndexSet(0..<table.numberOfColumns))
        #expect(table.groupTree.nodes.map(\.group) == tree)
        #expect(display(table) == ["[X]", "0", "2", "5", "[Y]", "1", "4", "[Z]", "3"])
        #expect(table.subtotalTexts(ofNode: y)["spend"] == "45")
        #expect(table.subtotalTexts(ofNode: z)["spend"] == "1")
        // The header shows it.
        guard let cell = table.visibleCell(row: 4, columnID: "spend"), case .subtotal(let text, _) = cell.content else {
            Issue.record("No subtotal cell")
            return
        }
        #expect(text == "45")
        withExtendedLifetime(dataSource) {}
    }

    /// Subtotals and rows after random batches (values, groups changing,
    /// inserts, removes, moves) match a fresh table's, sorted or not,
    /// filtered or not; seeded, so a failure repeats.
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func incrementalSubtotalsMatchAFreshTable(sorted: Bool, filtered: Bool) {
        func configure(_ table: NGTableView) {
            if sorted {
                table.sortsRows = true
                table.sortDescriptors = [NSSortDescriptor(key: "spend", ascending: false)]
            }
            if filtered { table.rowFilter = NGRowFilter { _ in true } }
        }
        for seed in 1...6 as ClosedRange<UInt64> {
            var random = SplitMix(seed: seed)
            let (table, dataSource) = makeTable(grouping: NGRowGrouping(columnIDs: ["network", "status"]))
            configure(table)
            if filtered {
                table.rowFilter = NGRowFilter { [weak dataSource] row in (dataSource?.campaigns[row].spend ?? 0) >= 3 }
            }
            for step in 0..<40 {
                table.beginUpdates()
                for _ in 0..<Int.random(in: 1...4, using: &random) {
                    let count = dataSource.campaigns.count
                    switch Int.random(in: 0..<6, using: &random) {
                    case 0:
                        let row = Int.random(in: 0...count, using: &random)
                        dataSource.campaigns.insert(.init(name: "N\(step)", network: ["X", "Y", "Z", ""].randomElement(using: &random)!,
                                                          status: ["active", "paused"].randomElement(using: &random)!,
                                                          spend: Double(Int.random(in: 0...20, using: &random)), revenue: 1), at: row)
                        table.insertRows(at: [row])
                    case 1 where count > 2:
                        let row = Int.random(in: 0..<count, using: &random)
                        dataSource.campaigns.remove(at: row)
                        table.removeRows(at: [row])
                    case 2 where count > 1:
                        let from = Int.random(in: 0..<count, using: &random), to = Int.random(in: 0..<count, using: &random)
                        dataSource.campaigns.insert(dataSource.campaigns.remove(at: from), at: to)
                        table.moveRow(at: from, to: to)
                    case _ where count > 0:
                        let row = Int.random(in: 0..<count, using: &random)
                        dataSource.campaigns[row].spend = Double(Int.random(in: 0...50, using: &random))
                        dataSource.campaigns[row].revenue = Double(Int.random(in: 0...80, using: &random))
                        if Int.random(in: 0..<4, using: &random) == 0 {
                            dataSource.campaigns[row].status = ["active", "paused"].randomElement(using: &random)!
                        }
                        table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(0..<table.numberOfColumns))
                    default:
                        break
                    }
                }
                table.endUpdates()
                let (fresh, freshSource) = makeTable(grouping: NGRowGrouping(columnIDs: ["network", "status"]))
                freshSource.campaigns = dataSource.campaigns
                fresh.reloadData()
                configure(fresh)
                if filtered {
                    fresh.rowFilter = NGRowFilter { [weak freshSource] row in (freshSource?.campaigns[row].spend ?? 0) >= 3 }
                }
                let context = "seed \(seed) step \(step)"
                #expect(display(table) == display(fresh), "\(context)")
                #expect(table.summaryValue(forColumnID: "spend") == fresh.summaryValue(forColumnID: "spend"), "\(context)")
                for group in fresh.groupTree.nodes.map(\.group) {
                    guard let mine = table.groupTree.nodeOfGroup[group], let theirs = fresh.groupTree.nodeOfGroup[group] else {
                        Issue.record("\(context): group \(group) missing")
                        continue
                    }
                    #expect(table.subtotalTexts(ofNode: mine) == fresh.subtotalTexts(ofNode: theirs), "\(context) \(group)")
                }
                withExtendedLifetime(freshSource) {}
                if display(table) != display(fresh) { break }
            }
            withExtendedLifetime(dataSource) {}
        }
    }

    /// Sorting reorders the groups by their first row; the subtotals and
    /// collapsed groups stay.
    @Test func sortingReordersGroups() {
        let (table, dataSource) = makeTable()
        table.collapseGroup(table.topLevelGroups[1])   // Y
        // By spend, descending: C(20) A(10) B(5) E(4) F(2) D(1).
        let oldIndexes = [2, 0, 1, 4, 5, 3]
        let old = dataSource.campaigns
        dataSource.campaigns = oldIndexes.map { old[$0] }
        table.reorderRows(fromOldIndexes: oldIndexes)
        #expect(display(table) == ["[X]", "0", "1", "4", "[Y]", "[Z]", "5"])
        let x = table.groupTree.nodeOfGroup[table.topLevelGroups[0]]!
        #expect(table.subtotalTexts(ofNode: x)["spend"] == "32")
        withExtendedLifetime(dataSource) {}
    }

    /// While summaries are computed in the background, headers keep their
    /// previous subtotals instead of showing none.
    @Test func subtotalsStayWhileComputedInTheBackground() async throws {
        let (table, dataSource) = makeTable()
        let x = table.groupTree.nodeOfGroup[table.topLevelGroups[0]]!
        #expect(table.subtotalTexts(ofNode: x)["spend"] == "32")
        table.synchronousSummaryLimit = 0
        table.reloadData()
        #expect(table.isComputingSummary)
        #expect(table.subtotalTexts(ofNode: x)["spend"] == "32")
        try await waitWhile { table.isComputingSummary }
        #expect(!table.isComputingSummary)
        #expect(table.subtotalTexts(ofNode: x)["spend"] == "32")
        withExtendedLifetime(dataSource) {}
    }

    /// A changed value moves its row to another group, and the subtotals follow.
    /// Live data that keeps changing the grouping values doesn't pile up keys
    /// or old subtotals: the groups are still right after many regroupings.
    @Test func changingGroupValuesKeepsTheKeysFew() throws {
        let (table, dataSource) = makeTable()
        for tick in 0..<2_000 {
            let row = tick % dataSource.campaigns.count
            dataSource.campaigns[row].network = "N\(tick)"
            table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(0..<table.numberOfColumns))
            // Subtotals are asked for (and kept) as the table shows them.
            for node in table.groupTree.topLevel { _ = table.subtotalTexts(ofNode: node) }
        }
        let keys = try #require(table.groupKeys)
        #expect(keys.keyCount(level: 0) <= 512)
        #expect(table.previousGroupSubtotals.keys.allSatisfy { table.groupTree.nodeOfGroup[$0] != nil })
        // The groups are those of the current values, in the order of their first row.
        #expect(table.topLevelGroups.map(\.key) == dataSource.campaigns.map(\.network))
        for (index, node) in table.groupTree.topLevel.enumerated() {
            #expect(table.subtotalTexts(ofNode: node)["spend"] == "\(Int(dataSource.campaigns[index].spend))")
        }
        withExtendedLifetime(dataSource) {}
    }

    @Test func targetedUpdatesRegroup() {
        let (table, dataSource) = makeTable()
        table.selectRowIndexes([3], byExtendingSelection: false)
        dataSource.campaigns[3].network = "X"
        table.reloadData(forRowIndexes: [3], columnIndexes: IndexSet(0..<table.numberOfColumns))
        #expect(display(table) == ["[X]", "0", "2", "3", "5", "[Y]", "1", "4"])
        #expect(table.selectedRowIndexes == [3])
        let x = table.groupTree.nodeOfGroup[table.topLevelGroups[0]]!
        #expect(table.subtotalTexts(ofNode: x)["spend"] == "33")
        // Inserted rows join their groups.
        dataSource.campaigns.insert(.init(name: "G", network: "Y", status: "active", spend: 7, revenue: 0), at: 0)
        table.insertRows(at: [0])
        // Its group now has the first row: it comes first.
        #expect(display(table) == ["[Y]", "0", "2", "5", "[X]", "1", "3", "4", "6"])
        #expect(table.selectedRowIndexes == [4])
        let y = table.groupTree.nodeOfGroup[table.topLevelGroups[0]]!
        #expect(table.subtotalTexts(ofNode: y)["spend"] == "16")
        withExtendedLifetime(dataSource) {}
    }

    @Test func rowsWithoutAValueAndCustomTitles() {
        let (table, dataSource) = makeTable(grouping: nil)
        let delegate = GroupDelegate()
        delegate.titles = ["Y": "Network Y"]
        table.delegate = delegate
        dataSource.campaigns[3].network = ""
        table.reloadData()
        table.rowGrouping = NGRowGrouping(columnID: "network", showsRowCount: false)
        let groups = table.topLevelGroups
        #expect(groups.map(\.key) == ["X", "Y", ""])
        #expect(table.title(of: groups[1]) == "Network Y")
        #expect(table.title(of: groups[2]) == NGTableView.noValueGroupTitle)
        let z = table.groupTree.nodeOfGroup[groups[2]]!
        guard case .groupTitle(let content) = table.groupTitleContent(ofNode: z) else {
            Issue.record("No title")
            return
        }
        #expect(content.detail.isEmpty)
        withExtendedLifetime(delegate) {}
    }

    /// The expansion follows groups by their values across reloads.
    @Test func collapsedGroupsStayCollapsedAcrossReloads() {
        let (table, dataSource) = makeTable()
        table.collapseGroup(table.topLevelGroups[1])
        dataSource.campaigns.swapAt(0, 1)
        table.reloadData()
        #expect(display(table) == ["[Y]", "[X]", "1", "2", "5", "[Z]", "3"])
        withExtendedLifetime(dataSource) {}
    }

    /// Updates while the grouping is off note which rows' keys to read when
    /// it comes back; those rows move with inserts and removes like the keys.
    @Test func keysToReadMoveWithTheRowsWhileNotGrouped() {
        let (table, dataSource) = makeTable(grouping: NGRowGrouping(columnID: "status"))
        defer { withExtendedLifetime(dataSource) {} }
        table.rowGrouping = nil
        // A new last row: its key is to be read.
        dataSource.campaigns.append(.init(name: "G", network: "W", status: "done", spend: 1, revenue: 1))
        table.insertRows(at: [6])
        // Rows before it go: it moves up to 4.
        dataSource.campaigns.removeSubrange(0..<2)
        table.removeRows(at: [0, 1])
        // A changed status, reported for its column only.
        dataSource.campaigns[3].status = "paused"
        table.reloadData(forRowIndexes: [3], columnIndexes: [table.column(withIdentifier: .init("status"))])
        table.rowGrouping = NGRowGrouping(columnID: "status")
        #expect(display(table) == ["[paused]", "0", "3", "[active]", "1", "2", "[done]", "4"])
    }

    /// VoiceOver reads header rows as disclosure rows.
    @Test func headersAreDisclosureRowsForVoiceOver() {
        let (table, tableSource) = makeTable()
        defer { withExtendedLifetime(tableSource) {} }
        let header = table.accessibilityRowElement(0)
        #expect(header.isAccessibilityDisclosed())
        #expect(header.accessibilityLabel() == "X, 3")
        #expect(table.accessibilityText(row: 0, column: NGTableColumn("spend", title: "Spend")) == "32")
        header.setAccessibilityDisclosed(false)
        #expect(table.numberOfRows == 6)
    }

    /// The keyboard goes onto a header only when the rows can be left
    /// unselected: never a header and a row selected at once.
    @Test func headersTakeTheKeyboardOnlyWithoutASelection() throws {
        @MainActor final class Refusing: NGTableViewDelegate {
            var refuses = false
            func selectionShouldChange(in tableView: NGTableView) -> Bool { !refuses }
        }
        let (table, dataSource) = makeTable()
        defer { withExtendedLifetime(dataSource) {} }
        let refusing = Refusing()
        table.delegate = refusing
        table.moveDown(nil)
        #expect(table.selectedRowIndexes == [0])
        // The delegate keeps the selection: Up stays on the row.
        refusing.refuses = true
        table.moveUp(nil)
        #expect(table.keyboardGroup == nil)
        #expect(table.selectedRowIndexes == [0])
        // An empty selection isn't allowed: headers are passed over.
        refusing.refuses = false
        table.allowsEmptySelection = false
        table.moveUp(nil)
        #expect(table.keyboardGroup == nil)
        #expect(table.selectedRowIndexes == [0])
        withExtendedLifetime(refusing) {}
    }

    /// Up and Down stop on header rows; Left and Right there collapse and
    /// expand the group (or go out of and into it), like NSOutlineView.
    @Test func keyboardCollapsesAndExpandsGroups() throws {
        let (table, dataSource) = makeTable()
        defer { withExtendedLifetime(dataSource) {} }
        let x = try #require(table.topLevelGroups.first)
        #expect(x.key == "X")
        table.moveDown(nil)
        #expect(table.selectedRowIndexes == [0])      // A, the first row of X.
        table.moveUp(nil)
        #expect(table.keyboardGroup == x)
        #expect(table.selectedRowIndexes.isEmpty)
        table.moveLeft(nil)
        #expect(!table.isGroupExpanded(x))
        table.moveLeft(nil)                            // Collapsed, outermost: stays.
        #expect(table.keyboardGroup == x)
        table.moveDown(nil)                            // The next header, Y's.
        #expect(table.keyboardGroup?.key == "Y")
        table.moveDown(nil)
        #expect(table.keyboardGroup == nil)
        #expect(table.selectedRowIndexes == [1])       // B, Y's first row.
        table.moveUp(nil)
        table.moveUp(nil)
        #expect(table.keyboardGroup == x)
        table.moveRight(nil)
        #expect(table.isGroupExpanded(x))
        table.moveRight(nil)                           // Expanded: into it.
        #expect(table.keyboardGroup == nil)
        #expect(table.selectedRowIndexes == [0])

        // Nested groups: Left from an inner header goes out to its group once
        // collapsed; a click leaves the header.
        table.rowGrouping = NGRowGrouping(columnIDs: ["network", "status"])
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.moveUp(nil)
        let inner = try #require(table.keyboardGroup)
        #expect(inner.level == 1)
        table.moveLeft(nil)
        #expect(!table.isGroupExpanded(inner))
        table.moveLeft(nil)
        #expect(table.keyboardGroup == inner.parent)
        table.selectRowIndexes([3], byExtendingSelection: false)
        #expect(table.keyboardGroup == nil)
    }
}
#endif
