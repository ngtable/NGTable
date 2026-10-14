#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Rows as a tree: parents by identity, expanding and collapsing, the
/// filter's rows with their ancestors, live changes and the summaries.
@Suite("Row trees")
@MainActor
struct NGRowTreeTests {
    @MainActor
    final class Items: NGTableViewDataSource {
        struct Item { var id: String; var parent: String?; var spend: Double }
        // Campaigns with teasers; a campaign's spend is its teasers' total.
        var items: [Item] = [
            Item(id: "c1", parent: nil, spend: 30),
            Item(id: "t1a", parent: "c1", spend: 10),
            Item(id: "t1b", parent: "c1", spend: 20),
            Item(id: "c2", parent: nil, spend: 5),
            Item(id: "t2a", parent: "c2", spend: 5),
            Item(id: "x", parent: "t2a", spend: 0),
        ]
        func numberOfRows(in tableView: NGTableView) -> Int { items.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            column.id == "spend" ? .number(items[row].spend) : .text(items[row].id)
        }
        func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { items[row].id }
        func tableView(_ tableView: NGTableView, parentIdentifierForRow row: Int) -> AnyHashable? { items[row].parent }
    }

    private func makeTable(_ items: Items, tree: NGRowTree = NGRowTree()) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                         .column(NGTableColumn("spend", title: "Spend", width: 100, summary: .aggregate(.sum)))]
        table.dataSource = items
        table.rowTree = tree
        return table
    }

    /// The ids shown, indented by level.
    private func shown(_ table: NGTableView, _ items: Items) -> [String] {
        (0..<table.numberOfRows).map { displayRow in
            let row = table.sourceRow(displayRow)
            return String(repeating: "  ", count: max(0, table.level(forRow: row))) + items.items[row].id
        }
    }

    @Test func treeExpandsAndCollapses() {
        let items = Items()
        let table = makeTable(items)
        defer { withExtendedLifetime(items) {} }
        #expect(shown(table, items) == ["c1", "  t1a", "  t1b", "c2", "  t2a", "    x"])
        #expect(table.isRowExpandable(0) && table.isRowExpanded(0))
        #expect(!table.isRowExpandable(1))
        #expect(table.parentRow(forRow: 5) == 4 && table.childRows(ofRow: 0) == [1, 2])
        table.collapseRow(0)
        #expect(shown(table, items) == ["c1", "c2", "  t2a", "    x"])
        // Collapsing with the children: expanding again shows them collapsed.
        table.collapseRow(3, collapseChildren: true)
        table.expandRow(3)
        #expect(shown(table, items) == ["c1", "c2", "  t2a"])
        // Expansion follows the records across a reload.
        items.items.reverse()
        table.reloadData()
        #expect(shown(table, items) == ["c2", "  t2a", "c1"])
        // Sorted: siblings in order, children under their parents.
        table.expandRow(items.items.firstIndex { $0.id == "c1" }!)
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "spend", ascending: true)]
        #expect(shown(table, items) == ["c2", "  t2a", "c1", "  t1a", "  t1b"])
    }

    @Test func filterShowsAncestors() {
        let items = Items()
        let table = makeTable(items)
        defer { withExtendedLifetime(items) {} }
        table.rowFilter = NGRowFilter(searchText: "x")
        #expect(shown(table, items) == ["c2", "  t2a", "    x"])
    }

    @Test func liveChangesAndParentsComingBack() {
        let items = Items()
        let table = makeTable(items)
        defer { withExtendedLifetime(items) {} }
        // A teaser inserted under c2 (first of its children in data source order).
        items.items.insert(.init(id: "t2b", parent: "c2", spend: 1), at: 0)
        table.insertRows(at: [0])
        #expect(shown(table, items) == ["c1", "  t1a", "  t1b", "c2", "  t2b", "  t2a", "    x"])
        // c1 removed: its teasers go to the top; it comes back: they go under it again.
        let c1 = items.items.remove(at: 1)
        table.removeRows(at: [1])
        #expect(shown(table, items).prefix(2) == ["t1a", "t1b"])
        items.items.append(c1)
        table.insertRows(at: [items.items.count - 1])
        #expect(shown(table, items).suffix(3) == ["c1", "  t1a", "  t1b"])
        // A teaser moved to another campaign.
        let index = items.items.firstIndex { $0.id == "t1a" }!
        items.items[index].parent = "c2"
        table.reloadData(forRowIndexes: [index], columnIndexes: [0])
        #expect(table.childRows(ofRow: items.items.firstIndex { $0.id == "c2" }!).map { items.items[$0].id }.contains("t1a"))
    }

    @Test func summariesOfTopLevelRows() {
        let items = Items()
        let all = makeTable(items)
        let top = makeTable(items, tree: NGRowTree(summaryRows: .topLevelRows))
        defer { withExtendedLifetime(items) {} }
        #expect(all.summaryValue(forColumnID: "spend") == 70)
        #expect(top.summaryValue(forColumnID: "spend") == 35)
        // Live: a value of a teaser changes, the top level's totals don't.
        items.items[1].spend = 99
        top.reloadData(forRowIndexes: [1], columnIndexes: [1])
        #expect(top.summaryValue(forColumnID: "spend") == 35)
    }

    /// Filtered, the top level counts the matches without a matching
    /// ancestor (a parent shown only for context isn't counted, its matching
    /// children are, each once); selecting a context parent doesn't blank
    /// the selected rows' total.
    @Test func filteredTopLevelTotalsCountTheMatches() {
        let items = Items()
        let table = makeTable(items, tree: NGRowTree(summaryRows: .topLevelRows))
        defer { withExtendedLifetime(items) {} }
        table.rowFilter = NGRowFilter(searchText: "t1")
        #expect(shown(table, items) == ["c1", "  t1a", "  t1b"])
        #expect(table.summaryValue(forColumnID: "spend") == 30)
        table.rowFilter = NGRowFilter(searchText: "c1")
        #expect(table.summaryValue(forColumnID: "spend") == 30)
        table.rowFilter = NGRowFilter(searchText: "t")
        #expect(table.summaryValue(forColumnID: "spend") == 35)   // t1a, t1b, t2a.
        // A live change of a match's value, and a row starting to match.
        let t2a = items.items.firstIndex { $0.id == "t2a" }!
        items.items[t2a].spend = 50
        table.reloadData(forRowIndexes: [t2a], columnIndexes: [1])
        #expect(table.summaryValue(forColumnID: "spend") == 80)
        // Selected rows: a context parent and one match.
        table.rowFilter = NGRowFilter(searchText: "t1")
        table.summaryScope = .selectedRows
        table.selectRowIndexes([0, 1], byExtendingSelection: false)   // c1 (context), t1a.
        #expect(table.summaryValue(forColumnID: "spend") == 10)
    }

    /// A filtered tree counting its top level: a row re-parented under a
    /// match makes its matching descendants context (no longer counted),
    /// and back; live totals match a reload's.
    @Test func reparentingUnderAMatchKeepsFilteredTopLevelTotals() {
        let items = Items()
        items.items = [
            .init(id: "tp", parent: nil, spend: 10),   // Matches "t".
            .init(id: "x", parent: nil, spend: 0),     // Doesn't.
            .init(id: "tc", parent: "x", spend: 5),    // Matches, under x.
        ]
        let table = makeTable(items, tree: NGRowTree(summaryRows: .topLevelRows))
        defer { withExtendedLifetime(items) {} }
        table.rowFilter = NGRowFilter(searchText: "t")
        #expect(table.summaryValue(forColumnID: "spend") == 15)
        func reloaded() -> Double? {
            let fresh = makeTable(items, tree: NGRowTree(summaryRows: .topLevelRows))
            fresh.rowFilter = NGRowFilter(searchText: "t")
            return fresh.summaryValue(forColumnID: "spend")
        }
        // x under tp: tc's ancestor tp matches, so only tp counts.
        items.items[1].parent = "tp"
        table.reloadData(forRowIndexes: [1], columnIndexes: [])
        #expect(table.summaryValue(forColumnID: "spend") == reloaded())
        #expect(table.summaryValue(forColumnID: "spend") == 10)
        // And back to the top level: tc counts again.
        items.items[1].parent = nil
        table.reloadData(forRowIndexes: [1], columnIndexes: [])
        #expect(table.summaryValue(forColumnID: "spend") == 15)
    }

    /// A background computation for a filtered top-level tree that rows
    /// moved during: it computes again, and only says it's done, with the
    /// right totals, once that one is.
    @Test func aComputationStartedAgainIsReportedOnceDone() async throws {
        @MainActor final class Watcher: NGTableViewDelegate {
            var reports: [(computing: Bool, running: Bool, total: Double?)] = []
            func tableViewDidUpdateSummary(_ tableView: NGTableView) {
                reports.append((tableView.isComputingSummary, tableView.summaryTask != nil, tableView.summaryValue(forColumnID: "spend")))
            }
        }
        let items = Items()
        items.items = (0..<2_000).map { index in
            index % 2 == 0 ? .init(id: "p\(index)", parent: nil, spend: 1) : .init(id: "t\(index)", parent: "p\(index - 1)", spend: 1)
        }
        let table = makeTable(items, tree: NGRowTree(summaryRows: .topLevelRows))
        defer { withExtendedLifetime(items) {} }
        let watcher = Watcher()
        table.delegate = watcher
        table.synchronousSummaryLimit = 1_000
        table.rowFilter = NGRowFilter(searchText: "t")   // Children match, parents are context.
        NGTableView.reportsBatchesAcrossRunLoopTurns = false
        table.reloadData()
        #expect(table.isComputingSummary)
        // Every value read, the calculators being built off the main actor:
        // rows move in a batch open until the computation waits for it.
        var turns = 0
        while table.summaryBuild?.columns.isEmpty != true, turns < 100_000 {
            await _Concurrency.Task.yield()
            turns += 1
        }
        #expect(table.summaryTask != nil)
        table.beginUpdates()
        items.items.swapAt(0, 2)
        table.moveRow(at: 0, to: 2)
        table.moveRow(at: 1, to: 0)
        try await _Concurrency.Task.sleep(for: .milliseconds(30))
        table.endUpdates()
        turns = 0
        try await waitWhile { table.isComputingSummary || table.summaryTask != nil }
        #expect(!watcher.reports.isEmpty)
        #expect(watcher.reports.allSatisfy { !$0.computing && !$0.running })
        #expect(watcher.reports.last?.total == 1_000)
        withExtendedLifetime(watcher) {}
    }

    /// The outline cells (level, triangle) follow children that come and go
    /// under rows that didn't change themselves, and grouping cells after a
    /// tree aren't indented.
    @Test func outlineCellsFollowTheirChildren() {
        let items = Items()
        let table = makeTable(items)
        defer { withExtendedLifetime(items) {} }
        table.layoutSubtreeIfNeeded()
        func outline(_ id: String) -> NGOutline? {
            guard let row = items.items.firstIndex(where: { $0.id == id }), let display = table.displayIndex(ofRow: row) else { return nil }
            return table.visibleCell(row: display, columnID: "name")?.outline
        }
        #expect(outline("t2a")?.hasChildren == true)
        // t2a's only child goes: t2a itself isn't reloaded.
        let x = items.items.firstIndex { $0.id == "x" }!
        items.items.remove(at: x)
        table.removeRows(at: [x])
        #expect(outline("t2a")?.hasChildren == false)
        // A child comes under t1b.
        items.items.append(.init(id: "y", parent: "t1b", spend: 1))
        table.insertRows(at: [items.items.count - 1])
        #expect(outline("t1b")?.hasChildren == true)
        #expect(outline("y")?.level == 2)
        // Grouped instead of a tree: no cell is indented.
        table.rowTree = nil
        table.rowGrouping = NGRowGrouping(columnID: "spend")
        table.layoutSubtreeIfNeeded()
        #expect(table.visibleCells.values.allSatisfy { $0.outline == nil })
    }

    /// Sorted by the table and filtered: a parent shown only for context
    /// moves when its own sort value changes, like in a fresh table.
    @Test func contextParentsMoveWithTheirSortValues() {
        let items = Items()
        items.items = [
            .init(id: "a", parent: nil, spend: 1),
            .init(id: "am", parent: "a", spend: 5),
            .init(id: "b", parent: nil, spend: 2),
            .init(id: "bm", parent: "b", spend: 5),
        ]
        func configure(_ table: NGTableView) {
            table.sortsRows = true
            table.sortDescriptors = [NSSortDescriptor(key: "spend", ascending: true)]
            table.rowFilter = NGRowFilter { [weak items] row in items?.items[row].id.hasSuffix("m") ?? false }   // Only the children.
        }
        let table = makeTable(items)
        defer { withExtendedLifetime(items) {} }
        configure(table)
        #expect(shown(table, items) == ["a", "  am", "b", "  bm"])
        items.items[0].spend = 3
        table.reloadData(forRowIndexes: [0], columnIndexes: [1])
        let fresh = makeTable(items)
        configure(fresh)
        #expect(shown(table, items) == shown(fresh, items))
        #expect(shown(table, items) == ["b", "  bm", "a", "  am"])
    }

    /// VoiceOver sees a tree's rows as disclosure rows: level, expanded, and
    /// expanding or collapsing them.
    @Test func treeRowsAreDisclosureRowsForVoiceOver() {
        let items = Items()
        let table = makeTable(items)
        defer { withExtendedLifetime(items) {} }
        let parent = table.accessibilityRowElement(0)   // c1
        let child = table.accessibilityRowElement(1)    // t1a
        #expect(parent.accessibilityDisclosureLevel() == 0 && child.accessibilityDisclosureLevel() == 1)
        #expect(parent.isAccessibilityDisclosed())
        parent.setAccessibilityDisclosed(false)
        #expect(!table.isRowExpanded(0))
        #expect(shown(table, items).first == "c1" && shown(table, items).count == 4)
        table.accessibilityRowElement(0).setAccessibilityDisclosed(true)
        #expect(table.isRowExpanded(0))
    }

    /// The exact cases of the review: a child inserted, a child moved to
    /// the top, a parent removed, a top-level row inserted.
    @Test func topLevelTotalsFollowStructuralChanges() {
        let items = Items()
        let table = makeTable(items, tree: NGRowTree(summaryRows: .topLevelRows))
        defer { withExtendedLifetime(items) {} }
        #expect(table.summaryValue(forColumnID: "spend") == 35)
        items.items.insert(Items.Item(id: "t1c", parent: "c1", spend: 7), at: 3)
        table.insertRows(at: [3])
        #expect(table.summaryValue(forColumnID: "spend") == 35)
        let t1a = items.items.firstIndex { $0.id == "t1a" }!
        items.items[t1a].parent = nil
        table.reloadData(forRowIndexes: [t1a], columnIndexes: [0])
        #expect(table.summaryValue(forColumnID: "spend") == 45)
        let c1 = items.items.firstIndex { $0.id == "c1" }!
        items.items.remove(at: c1)
        table.removeRows(at: [c1])
        // c1's teasers (t1b 20, t1c 7) are top level now: 45 - 30 + 27.
        #expect(table.summaryValue(forColumnID: "spend") == 42)
        items.items.append(Items.Item(id: "new", parent: nil, spend: 100))
        table.insertRows(at: [items.items.count - 1])
        #expect(table.summaryValue(forColumnID: "spend") == 142)
    }

    /// Random batches of inserts, removes, moves, value and parent changes:
    /// the live table always shows and totals what a fresh one does, sorted
    /// by the table or not, filtered by a search or by values (matches that
    /// change with the data), or not filtered.
    @Test(arguments: [(NGRowTree.SummaryRows.allRows, false), (.topLevelRows, false), (.allRows, true), (.topLevelRows, true)])
    func liveTreesMatchAFreshTable(summaryRows: NGRowTree.SummaryRows, sorted: Bool) {
        for seed in 1...10 as ClosedRange<UInt64> {
            var random = SplitMix(seed: seed)
            let items = Items()
            // Seeds by three: a search ("t" matches old rows and new ones), a
            // condition on values, or no filter.
            let filter: NGRowFilter? = switch seed % 3 {
            case 0: NGRowFilter(searchText: "t")
            case 1: NGRowFilter { [weak items] row in (items?.items[row].spend ?? 0) >= 20 }
            default: nil
            }
            func configure(_ table: NGTableView) {
                if sorted {
                    table.sortsRows = true
                    table.sortDescriptors = [NSSortDescriptor(key: "spend", ascending: false)]
                }
                table.rowFilter = filter
            }
            let table = makeTable(items, tree: NGRowTree(summaryRows: summaryRows))
            defer { withExtendedLifetime(items) {} }
            configure(table)
            var nextID = 0
            func randomParent() -> String? {
                Int.random(in: 0..<3, using: &random) == 0 || items.items.isEmpty ? nil
                    : items.items[Int.random(in: 0..<items.items.count, using: &random)].id
            }
            for step in 0..<40 {
                table.beginUpdates()
                for _ in 0..<Int.random(in: 1...3, using: &random) {
                    let count = items.items.count
                    switch Int.random(in: 0..<5, using: &random) {
                    case 0:
                        let row = Int.random(in: 0...count, using: &random)
                        nextID += 1
                        items.items.insert(Items.Item(id: (nextID % 2 == 0 ? "t" : "x") + "\(nextID)", parent: randomParent(),
                                                      spend: Double(Int.random(in: 0..<50, using: &random))), at: row)
                        table.insertRows(at: [row])
                    case 1 where count > 1:
                        let row = Int.random(in: 0..<count, using: &random)
                        items.items.remove(at: row)
                        table.removeRows(at: [row])
                    case 2 where count > 1:
                        let from = Int.random(in: 0..<count, using: &random), to = Int.random(in: 0..<count, using: &random)
                        items.items.insert(items.items.remove(at: from), at: to)
                        table.moveRow(at: from, to: to)
                    case 3 where count > 0:
                        let row = Int.random(in: 0..<count, using: &random)
                        items.items[row].parent = randomParent()
                        if items.items[row].parent == items.items[row].id { items.items[row].parent = nil }
                        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
                    case 4 where count > 0:
                        let row = Int.random(in: 0..<count, using: &random)
                        items.items[row].spend = Double(Int.random(in: 0..<50, using: &random))
                        table.reloadData(forRowIndexes: [row], columnIndexes: [1])
                    default:
                        break
                    }
                }
                table.endUpdates()
                let fresh = makeTable(items, tree: NGRowTree(summaryRows: summaryRows))
                configure(fresh)
                let same = table.summaryValue(forColumnID: "spend") == fresh.summaryValue(forColumnID: "spend")
                    && shown(table, items) == shown(fresh, items)
                #expect(table.summaryValue(forColumnID: "spend") == fresh.summaryValue(forColumnID: "spend"),
                        "seed \(seed) step \(step)")
                #expect(shown(table, items) == shown(fresh, items), "seed \(seed) step \(step)")
                if !same { return }
            }
        }
    }

    /// Like NSOutlineView's delegate: the user's expanding and collapsing
    /// (keys, VoiceOver) asks it first, code doesn't; "will" comes before
    /// the change, "did" after, as notifications and delegate calls.
    @Test func theDelegateDecidesForTheUser() throws {
        @MainActor final class Watcher: NGTableViewDelegate {
            var lockedRows: Set<Int> = []
            var asked: [String] = []
            var told: [String] = []
            func tableView(_ tableView: NGTableView, shouldExpandRow row: Int) -> Bool {
                asked.append("expand \(row)")
                return !lockedRows.contains(row)
            }
            func tableView(_ tableView: NGTableView, shouldCollapseRow row: Int) -> Bool {
                asked.append("collapse \(row)")
                return !lockedRows.contains(row)
            }
            func tableViewRowWillExpand(_ notification: Notification) { note("will expand", notification) }
            func tableViewRowDidExpand(_ notification: Notification) { note("did expand", notification) }
            func tableViewRowWillCollapse(_ notification: Notification) { note("will collapse", notification) }
            func tableViewRowDidCollapse(_ notification: Notification) { note("did collapse", notification) }
            private func note(_ what: String, _ notification: Notification) {
                let table = notification.object as? NGTableView
                let id = notification.userInfo?["NGRowIdentifier"] as? String ?? "?"
                told.append("\(what) \(id) \(table?.isRowExpanded(0) == true ? "open" : "closed")")
            }
        }
        let items = Items()
        let watcher = Watcher()
        let table = makeTable(items)
        table.delegate = watcher
        defer { withExtendedLifetime((items, watcher)) {} }
        var posted: [Notification.Name] = []
        let names = [NGTableView.rowWillExpandNotification, NGTableView.rowDidExpandNotification,
                     NGTableView.rowWillCollapseNotification, NGTableView.rowDidCollapseNotification]
        let observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: table, queue: nil) { note in
                let name = note.name
                MainActor.assumeIsolated { posted.append(name) }
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }

        // Locked: VoiceOver and Left leave it open.
        watcher.lockedRows = [0]
        table.accessibilityRowElement(0).setAccessibilityDisclosed(false)
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.moveLeft(nil)
        #expect(table.isRowExpanded(0) && table.selectedRowIndexes == [0])
        #expect(watcher.asked == ["collapse 0", "collapse 0"] && watcher.told.isEmpty && posted.isEmpty)
        // Code isn't asked.
        table.collapseRow(0)
        #expect(!table.isRowExpanded(0) && watcher.asked.count == 2)
        #expect(watcher.told == ["will collapse c1 open", "did collapse c1 closed"])
        #expect(posted == [NGTableView.rowWillCollapseNotification, NGTableView.rowDidCollapseNotification])
        // Unlocked: Right asks, then expands.
        watcher.lockedRows = []
        watcher.told = []
        table.moveRight(nil)
        #expect(table.isRowExpanded(0) && watcher.asked.last == "expand 0")
        #expect(watcher.told == ["will expand c1 closed", "did expand c1 open"])
        // With Option, rows within that the delegate keeps stay as they are.
        watcher.lockedRows = [4]
        table.selectRowIndexes([3], byExtendingSelection: false)
        _ = table.collapseOrGoToParent(includingChildren: true)
        #expect(!table.isRowExpanded(3) && table.isRowExpanded(4))
    }

    /// `autosaveExpandedItems` keeps which rows are expanded under the
    /// `autosaveName`, for identities that are strings or integers.
    @Test func expandedRowsAreSaved() {
        let items = Items()
        let name = "NGRowTreeTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NGTableView Expanded Rows \(name)") }
        let table = makeTable(items)
        table.autosaveName = name
        table.autosaveExpandedItems = true
        table.collapseRow(0)
        table.collapseRow(4)
        defer { withExtendedLifetime((items, table)) {} }
        // Another table with the name: the same rows collapsed.
        let again = NGTableView(frame: table.frame)
        again.columns = table.columns
        again.dataSource = items
        again.autosaveName = name
        again.autosaveExpandedItems = true
        again.rowTree = NGRowTree()
        #expect(shown(again, items) == ["c1", "c2", "  t2a"])
        // Saved per tree default: a tree that starts collapsed has its own.
        again.rowTree = NGRowTree(startsCollapsed: true)
        #expect(shown(again, items) == ["c1", "c2"])
        // Without the flag nothing is read.
        let plain = NGTableView(frame: table.frame)
        plain.columns = table.columns
        plain.dataSource = items
        plain.autosaveName = name
        plain.rowTree = NGRowTree()
        #expect(shown(plain, items).count == 6)
    }

    @Test func keysAndTriangles() throws {
        let items = Items()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = makeTable(items)
        defer { withExtendedLifetime((window, items)) {} }
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        // The outline column's cells: depth and triangle.
        let name = try #require(table.tableColumns.first)
        #expect(table.outline(forDisplayRow: 0, column: name) == NGOutline(level: 0, hasChildren: true, isExpanded: true))
        #expect(table.outline(forDisplayRow: 1, column: name) == NGOutline(level: 1, hasChildren: false, isExpanded: false))
        #expect(table.outline(forDisplayRow: 0, column: table.tableColumns[1]) == nil)
        // Left collapses, again goes to the parent; Right expands, again goes in.
        table.selectRowIndexes([4], byExtendingSelection: false)   // t2a
        table.moveLeft(nil)
        #expect(!table.isRowExpanded(4))
        table.moveLeft(nil)
        #expect(table.selectedRowIndexes == [3])                    // c2
        table.moveRight(nil)                                        // Expanded already: into it.
        #expect(table.selectedRowIndexes == [4])
        table.moveRight(nil)
        #expect(table.isRowExpanded(4))
        // A click on the triangle collapses without selecting.
        let cell = try #require(table.frameOfCell(row: 0, columnID: "name"))
        let point = table.convert(NSPoint(x: cell.minX + NGMetrics.cellPadding + 4, y: cell.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        table.rowsMouseDown(click, in: table.centerRegion)
        #expect(!table.isRowExpanded(0))
        #expect(table.selectedRowIndexes == [4])
        // A grouping takes the tree's place.
        table.rowGrouping = NGRowGrouping(columnID: "name")
        #expect(table.rowTree == nil)
    }

    /// A feed of a tree: rows inserted (under existing rows or at the top)
    /// and removed, now and then moved, reparented, collapsed or changed
    /// in value, sorted or not. Rows inserted and removed alone are placed
    /// by themselves (`layOutTreeEdits`); after every batch the tree is what
    /// laying out the whole of it gives.
    @Test(arguments: [false, true])
    func placingEditsMatchesTheWholeLayout(sorted: Bool) throws {
        let items = Items()
        var generator = SplitMix(seed: sorted ? 21 : 12)
        var nextID = 0
        func newID() -> String { nextID += 1; return "n\(nextID)" }
        var gone: [String] = []
        items.items = (0..<300).map { index in
            Items.Item(id: "r\(index)", parent: index % 10 == 0 ? nil : "r\(index - index % 10)", spend: Double(index * 7_919 % 10_007) + 0.5)
        }
        let table = makeTable(items)
        defer { withExtendedLifetime(items) {} }
        if sorted {
            table.sortsRows = true
            table.sortDescriptors = [NSSortDescriptor(key: "spend", ascending: false)]
        }
        table.layoutSubtreeIfNeeded()
        func snapshot(_ table: NGTableView) -> [String] {
            (0..<table.numberOfRows).map { displayRow in
                let row = table.sourceRow(displayRow)
                return "\(table.level(forRow: row)) \(items.items[row].id) \(table.childRows(ofRow: row).map { items.items[$0].id })"
            } + table.treeRoots.map { "root \(items.items[table.row(ofHandle: Int($0))].id)" }
        }
        // The same rows in a new table: parents read afresh.
        func fresh() -> [String] {
            let other = makeTable(items)
            other.toggledTreeRows = table.toggledTreeRows
            other.sortsRows = table.sortsRows
            other.sortDescriptors = table.sortDescriptors
            other.reloadData()
            other.layoutSubtreeIfNeeded()
            return snapshot(other)
        }
        let placedBefore = table.treeEditLayoutsForTesting
        for batch in 0..<150 {
            table.beginUpdates()
            let kind = generator.next() % 20
            for _ in 0..<(1 + Int(generator.next() % 3)) {
                let count = items.items.count
                switch kind {
                case 0:
                    // Moved.
                    let from = Int(generator.next() % UInt64(count)), to = Int(generator.next() % UInt64(count))
                    items.items.insert(items.items.remove(at: from), at: to)
                    table.moveRow(at: from, to: to)
                case 1:
                    // Another parent.
                    let row = Int(generator.next() % UInt64(count))
                    items.items[row].parent = items.items[Int(generator.next() % UInt64(count))].id
                    table.reloadData(forRowIndexes: [row], columnIndexes: [0])
                case 2:
                    // Another value (sorted: rows move).
                    let row = Int(generator.next() % UInt64(count))
                    items.items[row].spend += 7.25
                    table.reloadData(forRowIndexes: [row], columnIndexes: [1])
                case 3 ... 11:
                    // In, under a row or at the top, anywhere; now and then
                    // a row removed before, whose children wait for it.
                    let at = Int(generator.next() % UInt64(count + 1))
                    let parent = generator.next() % 4 == 0 ? nil : items.items[Int(generator.next() % UInt64(count))].id
                    let id = !gone.isEmpty && generator.next() % 3 == 0 ? gone.removeLast() : newID()
                    items.items.insert(Items.Item(id: id, parent: parent, spend: Double(generator.next() % 1_000_000) / 7), at: at)
                    table.insertRows(at: [at])
                default:
                    // Out: mostly rows without children.
                    let row = Int(generator.next() % UInt64(count))
                    gone.append(items.items.remove(at: row).id)
                    table.removeRows(at: [row])
                }
            }
            table.endUpdates()
            if batch % 30 == 15, let row = (0..<items.items.count).first(where: { table.isRowExpandable($0) }) {
                table.isRowExpanded(row) ? table.collapseRow(row) : table.expandRow(row)
            }
            table.layoutSubtreeIfNeeded()
            let placed = snapshot(table)
            table.buildTreeDisplay(readingParents: false)
            let whole = snapshot(table)
            let afresh = fresh()
            #expect(placed == whole, "batch \(batch), kind \(kind)")
            #expect(placed == afresh, "batch \(batch), kind \(kind)")
            if placed != whole || placed != afresh { break }
        }
        // Most batches only inserted and removed.
        #expect(table.treeEditLayoutsForTesting - placedBefore > 60)
    }
}
#endif
