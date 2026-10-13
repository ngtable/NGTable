#if os(macOS)
import AppKit
import Testing
@testable import NGTable

@Suite("Diffable data source")
@MainActor
struct NGDiffableDataSourceTests {
    /// The records the snapshots identify: id → (name, amount).
    private final class Store {
        var records: [Int: (name: String, amount: Double)] = [:]
    }

    private func makeTable(_ store: Store) -> (NGTableView, NGTableViewDiffableDataSource<String, Int>) {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("name", title: "Name")),
            .column(NGTableColumn("amount", title: "Amount", format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
        ]
        let dataSource = NGTableViewDiffableDataSource<String, Int>(tableView: table) { _, column, _, id in
            guard let record = store.records[id] else { return .empty }
            return column.id == "name" ? .text(record.name) : .number(record.amount)
        }
        table.layoutSubtreeIfNeeded()
        return (table, dataSource)
    }

    private func snapshot(_ sections: [(String, [Int])]) -> NGDiffableDataSourceSnapshot<String, Int> {
        var snapshot = NGDiffableDataSourceSnapshot<String, Int>()
        for (section, items) in sections {
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
        }
        return snapshot
    }

    private func names(_ table: NGTableView, _ dataSource: NGTableViewDiffableDataSource<String, Int>) -> [String] {
        (0..<table.numberOfRows).map { row in
            if case .text(let name) = dataSource.tableView(table, valueFor: NGTableColumn("name", title: ""), row: row) { return name }
            return "?"
        }
    }

    @Test func snapshotsKeepSectionsAndItemsInOrder() {
        var snapshot = snapshot([("a", [1, 2, 3]), ("b", [4])])
        snapshot.insertItems([5], beforeItem: 2)
        snapshot.insertItems([6], afterItem: 4)
        snapshot.moveItem(1, afterItem: 6)
        snapshot.deleteItems([3])
        snapshot.insertSections(["c"], beforeSection: "a")
        snapshot.appendItems([7])   // The last section.
        #expect(snapshot.sectionIdentifiers == ["c", "a", "b"])
        #expect(snapshot.itemIdentifiers == [5, 2, 4, 6, 1, 7])
        #expect(snapshot.numberOfItems == 6)
        #expect(snapshot.sectionIdentifier(containingItem: 1) == "b")
        #expect(snapshot.indexOfItem(6) == 3)
        #expect(snapshot.numberOfItems(inSection: "a") == 2)
        snapshot.reloadItems([2, 99])
        snapshot.reconfigureItems([7])
        #expect(snapshot.reloadedItemIdentifiers == [2])
        #expect(snapshot.reconfiguredItemIdentifiers == [7])
        snapshot.deleteSections(["b"])
        #expect(snapshot.itemIdentifiers == [5, 2])
        #expect(snapshot.reconfiguredItemIdentifiers.isEmpty)
        snapshot.moveSection("c", afterSection: "a")
        #expect(snapshot.sectionIdentifiers == ["a", "c"])
    }

    @Test func anAppKitSnapshotConverts() {
        var appKit = NSDiffableDataSourceSnapshot<String, Int>()
        appKit.appendSections(["a", "b"])
        appKit.appendItems([1, 2], toSection: "a")
        appKit.appendItems([3], toSection: "b")
        let snapshot = NGDiffableDataSourceSnapshot(appKit)
        #expect(snapshot.sectionIdentifiers == ["a", "b"])
        #expect(snapshot.itemIdentifiers == [1, 2, 3])
    }

    @Test func applyingShowsTheItems() {
        let store = Store()
        store.records = [1: ("A", 10), 2: ("B", 20), 3: ("C", 30)]
        let (table, dataSource) = makeTable(store)
        dataSource.apply(snapshot([("s", [1, 2]), ("t", [3])]))
        #expect(table.numberOfRows == 3)
        #expect(names(table, dataSource) == ["A", "B", "C"])
        #expect(table.summaryValue(forColumnID: "amount") == 60)
        #expect(dataSource.itemIdentifier(forRow: 2) == 3)
        #expect(dataSource.row(forItemIdentifier: 2) == 1)
        #expect(dataSource.sectionIdentifier(forRow: 2) == "t")
        #expect(dataSource.snapshot().itemIdentifiers == [1, 2, 3])
    }

    /// Inserts, removes and moves in one apply: the selection stays on its
    /// records, the summaries follow, and kept rows aren't read again.
    @Test func applyingADiffKeepsSelectionAndSummaries() {
        let store = Store()
        store.records = [1: ("A", 10), 2: ("B", 20), 3: ("C", 30), 4: ("D", 40)]
        let (table, dataSource) = makeTable(store)
        dataSource.apply(snapshot([("s", [1, 2, 3, 4])]))
        table.selectRowIndexes([1, 3], byExtendingSelection: false)   // B and D
        store.records[5] = ("E", 50)
        store.records[1] = ("A changed but not reloaded", 1000)
        var completed = false
        dataSource.apply(snapshot([("s", [4, 5, 2, 1])])) { completed = true }
        #expect(completed)
        #expect(names(table, dataSource).count == 4)
        #expect(dataSource.itemIdentifier(forRow: 0) == 4)
        #expect(table.selectedRowIndexes == [0, 2])   // D and B
        // C (30) left, E (50) came; A's new amount wasn't marked, so not read.
        #expect(table.summaryValue(forColumnID: "amount") == 120)
    }

    @Test func reloadedItemsAreReadAgain() {
        let store = Store()
        store.records = [1: ("A", 10), 2: ("B", 20)]
        let (table, dataSource) = makeTable(store)
        dataSource.apply(snapshot([("s", [1, 2])]))
        store.records[2] = ("B", 25)
        var next = dataSource.snapshot()
        next.reloadItems([2])
        dataSource.apply(next)
        #expect(table.summaryValue(forColumnID: "amount") == 35)
        // The kept snapshot has no marks: applying it again reads nothing.
        #expect(dataSource.snapshot().reloadedItemIdentifiers.isEmpty)
        store.records[1] = ("A", 100)
        var sections = dataSource.snapshot()
        sections.reloadSections(["s"])
        dataSource.apply(sections)
        #expect(table.summaryValue(forColumnID: "amount") == 125)
    }

    @Test func emptyingAndRefilling() {
        let store = Store()
        store.records = [1: ("A", 10), 2: ("B", 20)]
        let (table, dataSource) = makeTable(store)
        dataSource.apply(snapshot([("s", [1, 2])]))
        dataSource.apply(snapshot([("s", [])]))
        #expect(table.numberOfRows == 0)
        #expect(table.summaryValue(forColumnID: "amount") == nil)   // No rows, no sum.
        dataSource.apply(snapshot([("s", [2])]))
        #expect(table.numberOfRows == 1)
        #expect(table.summaryValue(forColumnID: "amount") == 20)
    }

    /// Random diffs against the same data read from scratch.
    @Test func randomDiffsMatchAFullReload() {
        let store = Store()
        var generator = SplitMix(seed: 11)   // Seeded: a failure repeats.
        for id in 0..<200 { store.records[id] = ("R\(id)", Double(id)) }
        let (table, dataSource) = makeTable(store)
        var ids = Array(0..<100)
        dataSource.apply(snapshot([("s", ids)]))
        var nextID = 200
        for _ in 0..<30 {
            ids.shuffle(using: &generator)
            ids.removeLast(Int.random(in: 0...10, using: &generator))
            for _ in 0..<Int.random(in: 0...10, using: &generator) {
                store.records[nextID] = ("R\(nextID)", Double(nextID))
                ids.insert(nextID, at: Int.random(in: 0...ids.count, using: &generator))
                nextID += 1
            }
            var next = snapshot([("s", ids)])
            if let changed = ids.randomElement(using: &generator) {
                store.records[changed]?.amount += 1
                next.reloadItems([changed])
            }
            dataSource.apply(next)
            #expect(table.numberOfRows == ids.count)
            #expect(table.summaryValue(forColumnID: "amount") == ids.reduce(0) { $0 + (store.records[$1]?.amount ?? 0) })
            #expect((0..<ids.count).allSatisfy { dataSource.itemIdentifier(forRow: $0) == ids[$0] })
        }
    }

    /// With a search filter, diffs show what a fresh table reading the same
    /// snapshot shows: the same rows, totals and selected records.
    @Test func filteredDiffsMatchAFreshTable() {
        let store = Store()
        var generator = SplitMix(seed: 11)   // Seeded: a failure repeats.
        for id in 0..<300 { store.records[id] = ("R\(id % 7)", Double(id)) }
        let (table, dataSource) = makeTable(store)
        table.rowFilter = NGRowFilter(searchText: "R3")
        var ids = Array(0..<120)
        dataSource.apply(snapshot([("s", ids)]))
        var nextID = 120
        for _ in 0..<20 {
            table.selectRowIndexes(IndexSet(ids.indices.filter { _ in Bool.random(using: &generator) }), byExtendingSelection: false)
            let selected = Set(table.selectedRowIndexes.compactMap(dataSource.itemIdentifier(forRow:)))
            ids.shuffle(using: &generator)
            ids.removeLast(Int.random(in: 0...8, using: &generator))
            for _ in 0..<Int.random(in: 0...8, using: &generator) where nextID < 300 {
                ids.insert(nextID, at: Int.random(in: 0...ids.count, using: &generator))
                nextID += 1
            }
            dataSource.apply(snapshot([("s", ids)]))

            let (fresh, freshSource) = makeTable(store)
            fresh.rowFilter = NGRowFilter(searchText: "R3")
            freshSource.apply(snapshot([("s", ids)]))
            #expect(table.numberOfRows == fresh.numberOfRows)
            #expect(table.summaryValue(forColumnID: "amount") == fresh.summaryValue(forColumnID: "amount"))
            let stillSelected = Set(table.selectedRowIndexes.compactMap(dataSource.itemIdentifier(forRow:)))
            #expect(stillSelected == selected.intersection(ids))
        }
    }

    @Test func sortingGoesToTheClosure() {
        let store = Store()
        store.records = [1: ("B", 10), 2: ("A", 20)]
        let (table, dataSource) = makeTable(store)
        dataSource.apply(snapshot([("s", [1, 2])]))
        dataSource.sortDescriptorsDidChange = { tableView, _ in
            let ascending = tableView.sortDescriptors.first?.ascending ?? true
            let sorted = [1, 2].sorted { lhs, rhs in
                let ordered = store.records[lhs]!.name < store.records[rhs]!.name
                return ascending ? ordered : !ordered
            }
            var next = NGDiffableDataSourceSnapshot<String, Int>()
            next.appendSections(["s"])
            next.appendItems(sorted)
            dataSource.apply(next)
        }
        table.selectRowIndexes([0], byExtendingSelection: false)   // B
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        #expect(dataSource.itemIdentifier(forRow: 0) == 2)
        #expect(table.selectedRowIndexes == [1])
    }

    /// Sections as groups: a header row per section, in order; items moved
    /// to another section change group.
    @Test func sectionsAsGroups() {
        let store = Store()
        for id in 1...5 { store.records[id] = ("R\(id)", Double(id)) }
        let (table, dataSource) = makeTable(store)
        dataSource.sectionTitleProvider = { $0.uppercased() }
        dataSource.apply(snapshot([("b", [1, 2]), ("a", [3, 4, 5])]))
        func layout() -> [String] {
            (0..<table.numberOfRows).map { row in
                if let node = table.groupNode(atDisplayRow: row) { return "[\(table.groupTree.nodes[node].group.key)]" }
                return store.records[dataSource.itemIdentifier(forRow: table.sourceRow(row)) ?? 0]?.name ?? "?"
            }
        }
        #expect(layout() == ["[B]", "R1", "R2", "[A]", "R3", "R4", "R5"])
        // R2 moves to section a.
        dataSource.apply(snapshot([("b", [1]), ("a", [2, 3, 4, 5])]))
        #expect(layout() == ["[B]", "R1", "[A]", "R2", "R3", "R4", "R5"])
        // Back to one list.
        dataSource.sectionTitleProvider = nil
        #expect(table.rowGrouping == nil)
        #expect(table.numberOfRows == 5)
    }
}
#endif
