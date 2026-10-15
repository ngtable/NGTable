#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// The table sorting the rows itself (`sortsRows`), also under live updates.
@Suite("Live sorting")
@MainActor
struct NGLiveSortingTests {
    @MainActor
    final class Records: NGTableViewDataSource, NGTableViewDelegate {
        struct Record { var id: Int; var name: String; var profit: Double; var status: String }
        var records: [Record]
        var sortReads = 0
        var nameReads = 0

        init(count: Int, seed: UInt64 = 1) {
            var generator = SplitMix64(seed: seed)
            records = (0..<count).map { id in
                Record(id: id, name: "Campaign \(id)", profit: Double(generator.next() % 200) - 100,
                       status: ["Active", "Paused", "Finished"][Int(generator.next() % 3)])
            }
        }

        func numberOfRows(in tableView: NGTableView) -> Int { records.count }

        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            if column.id == "name" { nameReads += 1 }
            return switch column.id {
            case "name": .text(records[row].name)
            case "profit": .number(records[row].profit)
            case "status": .text(records[row].status)
            // Shown as text, sorted by a number (see `sortValueFor`).
            case "rank": .text("#\(records[row].id)")
            default: .empty
            }
        }

        func tableView(_ tableView: NGTableView, sortValueFor column: NGTableColumn, row: Int) -> NGCellValue {
            sortReads += 1
            if column.id == "rank" { return .number(Double(records[row].id)) }
            return self.tableView(tableView, valueFor: column, row: row)
        }

        func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { records[row].id }

        /// The data source rows in the order the table should show them.
        func expectedOrder(_ descriptors: [NSSortDescriptor], tableView: NGTableView) -> [Int] {
            NGSorting.order(ofRows: records.count, by: descriptors) { key, row in
                self.tableView(tableView, sortValueFor: NGTableColumn(key, title: key), row: row)
            }
        }
    }

    private func makeTable(_ records: Records) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("name", title: "Name", width: 200)),
            .column(NGTableColumn("profit", title: "Profit", width: 120, format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
            .column(NGTableColumn("status", title: "Status", width: 100)),
            .column(NGTableColumn("rank", title: "Rank", width: 80)),
        ]
        table.dataSource = records
        table.delegate = records
        table.sortsRows = true
        table.layoutSubtreeIfNeeded()
        return table
    }

    private func shown(_ table: NGTableView) -> [Int] {
        (0..<table.numberOfRows).map(table.sourceRow)
    }

    @Test func sortsWithoutTheDataSourceSorting() {
        let records = Records(count: 200)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let descriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        table.sortDescriptors = descriptors
        #expect(shown(table) == records.expectedOrder(descriptors, tableView: table))
        // Several keys, and another direction.
        let two = [NSSortDescriptor(key: "status", ascending: true), NSSortDescriptor(key: "profit", ascending: true)]
        table.sortDescriptors = two
        #expect(shown(table) == records.expectedOrder(two, tableView: table))
        // A key the data source sorts differently than it shows.
        let rank = [NSSortDescriptor(key: "rank", ascending: false)]
        table.sortDescriptors = rank
        #expect(shown(table) == Array((0..<200).reversed()))
        // No sort, or the table not sorting: the data source's order.
        table.sortDescriptors = []
        #expect(shown(table) == Array(0..<200))
        table.sortDescriptors = descriptors
        table.sortsRows = false
        #expect(shown(table) == Array(0..<200))
    }

    /// A sort by a column whose prototype has its own key keeps sorting by
    /// that column when it is hidden (the key isn't a column id).
    @Test func sortsByAHiddenColumnWithItsOwnKey() {
        let records = Records(count: 50)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        var rank = NGTableColumn("rank", title: "Rank", width: 80)
        rank.sortDescriptorPrototype = NSSortDescriptor(key: "byRank", ascending: true)
        table.columns = Array(table.columns.dropLast()) + [.column(rank)]
        table.sortDescriptors = [NSSortDescriptor(key: "byRank", ascending: false)]
        let descending = Array((0..<50).reversed())
        #expect(shown(table) == descending)
        table.hiddenColumnIDs = ["rank"]
        records.records[10].profit = 5
        table.reloadData(forRowIndexes: [10, 20], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        #expect(shown(table) == descending)
        table.reloadData()
        #expect(shown(table) == descending)
    }

    /// A live feed: every tick changes some profits; the rows stay sorted,
    /// the selection stays on its records, and the total follows.
    @Test func staysSortedUnderLiveUpdates() {
        let records = Records(count: 500)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let descriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        table.sortDescriptors = descriptors
        let selectedIDs: Set<Int> = [7, 123, 400]
        table.selectRowIndexes(IndexSet(selectedIDs), byExtendingSelection: false)
        var generator = SplitMix64(seed: 42)
        for tick in 0..<50 {
            var changed = IndexSet()
            for _ in 0..<(1 + Int(generator.next() % 40)) {
                let row = Int(generator.next() % 500)
                records.records[row].profit += Double(Int(generator.next() % 41) - 20)
                changed.insert(row)
            }
            let reads = records.sortReads
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            // Only the changed rows' sort values are read again.
            #expect(records.sortReads - reads == changed.count, "tick \(tick)")
            #expect(shown(table) == records.expectedOrder(descriptors, tableView: table), "tick \(tick)")
            #expect(Set(table.selectedRowIndexes.map { records.records[$0].id }) == selectedIDs, "tick \(tick)")
            #expect(table.summaryValue(forColumnID: "profit") == records.records.reduce(0) { $0 + $1.profit }, "tick \(tick)")
        }
        // The selection's display rows follow too (they are what the user sees highlighted).
        for row in table.selectedRowIndexes {
            #expect(table.displaySelection.contains(table.displayRow(forSourceRow: row) ?? -1))
        }
    }

    /// Inserts, removes and moves in batches keep the order (new rows go
    /// where their values belong).
    @Test func structuralUpdatesKeepTheOrder() {
        let records = Records(count: 300)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let descriptors = [NSSortDescriptor(key: "status", ascending: true), NSSortDescriptor(key: "profit", ascending: false)]
        table.sortDescriptors = descriptors
        var generator = SplitMix64(seed: 9)
        var nextID = 1000
        for round in 0..<30 {
            table.beginUpdates()
            for _ in 0..<10 {
                switch generator.next() % 4 {
                case 0:
                    let index = Int(generator.next() % UInt64(records.records.count + 1))
                    records.records.insert(.init(id: nextID, name: "New \(nextID)", profit: Double(generator.next() % 200) - 100,
                                                 status: ["Active", "Paused"][Int(generator.next() % 2)]), at: index)
                    nextID += 1
                    table.insertRows(at: [index])
                case 1:
                    let index = Int(generator.next() % UInt64(records.records.count))
                    records.records.remove(at: index)
                    table.removeRows(at: [index])
                case 2:
                    let from = Int(generator.next() % UInt64(records.records.count))
                    let to = Int(generator.next() % UInt64(records.records.count))
                    records.records.insert(records.records.remove(at: from), at: to)
                    table.moveRow(at: from, to: to)
                default:
                    let row = Int(generator.next() % UInt64(records.records.count))
                    records.records[row].profit = Double(generator.next() % 200) - 100
                    table.reloadData(forRowIndexes: [row], columnIndexes: [1])
                }
            }
            table.endUpdates()
            #expect(shown(table) == records.expectedOrder(descriptors, tableView: table), "round \(round)")
            #expect(table.summaryValue(forColumnID: "profit") == records.records.reduce(0) { $0 + $1.profit }, "round \(round)")
        }
    }

    /// A filter shows its rows in sorted order; groups keep their rows sorted.
    @Test func filtersAndGroupsKeepTheSort() {
        let records = Records(count: 300)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let descriptors = [NSSortDescriptor(key: "profit", ascending: true)]
        table.sortDescriptors = descriptors
        table.rowFilter = NGRowFilter { [weak records] row in (records?.records[row].profit ?? 0) > 0 }
        let positive = records.expectedOrder(descriptors, tableView: table).filter { records.records[$0].profit > 0 }
        #expect(shown(table) == positive)
        // A changed value moves the row among the shown ones.
        let row = positive[0]
        records.records[row].profit = 1_000
        table.reloadData(forRowIndexes: [row], columnIndexes: [1])
        #expect(shown(table).last == row)
        table.rowFilter = nil

        table.rowGrouping = NGRowGrouping(columnID: "status")
        table.layoutSubtreeIfNeeded()
        func groupsAreSorted() -> Bool {
            var previous: Double? = nil
            for displayRow in 0..<table.numberOfRows {
                let source = table.sourceRow(displayRow)
                guard source >= 0 else { previous = nil; continue }   // A header starts a group.
                let profit = records.records[source].profit
                if let previous, previous > profit { return false }
                previous = profit
            }
            return true
        }
        #expect(groupsAreSorted())
        var generator = SplitMix64(seed: 3)
        for _ in 0..<20 {
            let row = Int(generator.next() % 300)
            records.records[row].profit = Double(generator.next() % 300) - 150
            table.reloadData(forRowIndexes: [row], columnIndexes: [1])
            #expect(groupsAreSorted())
        }
        // Groups in the order of their first rows, as a fresh table lays them out.
        func layout(_ table: NGTableView) -> [String] {
            (0..<table.numberOfRows).map { row in
                table.groupNode(atDisplayRow: row).map { "group \(table.groupTree.nodes[$0].group.path)" } ?? "row \(table.sourceRow(row))"
            }
        }
        for _ in 0..<40 {
            let row = Int(generator.next() % 300)
            records.records[row].profit = Double(generator.next() % 300) - 150
            table.reloadData(forRowIndexes: [row], columnIndexes: [1])
            let fresh = makeTable(records)
            fresh.sortDescriptors = descriptors
            fresh.rowGrouping = NGRowGrouping(columnID: "status")
            fresh.layoutSubtreeIfNeeded()
            #expect(layout(table) == layout(fresh))
        }
    }

    /// Targeted updates filter only the changed rows again; the result is
    /// the same as filtering everything, with or without the sort.
    @Test(arguments: [false, true]) func filtersTheChangedRowsUnderLiveUpdates(sorted: Bool) {
        let records = Records(count: 400)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        if sorted { table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)] }
        // Search words and a condition, both changing with the data.
        table.rowFilter = NGRowFilter(searchText: "act") { [weak records] row in (records?.records[row].profit ?? 0) > -50 }
        func expected() -> [Int] {
            let order = sorted ? records.expectedOrder(table.sortDescriptors, tableView: table) : Array(records.records.indices)
            return order.filter { records.records[$0].status == "Active" && records.records[$0].profit > -50 }
        }
        #expect(shown(table) == expected())
        var generator = SplitMix64(seed: 77)
        var nextID = 1000
        for round in 0..<40 {
            table.beginUpdates()
            for _ in 0..<8 {
                switch generator.next() % 5 {
                case 0:
                    let index = Int(generator.next() % UInt64(records.records.count + 1))
                    records.records.insert(.init(id: nextID, name: "New \(nextID)", profit: Double(generator.next() % 200) - 100,
                                                 status: ["Active", "Paused"][Int(generator.next() % 2)]), at: index)
                    nextID += 1
                    table.insertRows(at: [index])
                case 1:
                    let index = Int(generator.next() % UInt64(records.records.count))
                    records.records.remove(at: index)
                    table.removeRows(at: [index])
                case 2:
                    let from = Int(generator.next() % UInt64(records.records.count))
                    let to = Int(generator.next() % UInt64(records.records.count))
                    records.records.insert(records.records.remove(at: from), at: to)
                    table.moveRow(at: from, to: to)
                default:
                    let row = Int(generator.next() % UInt64(records.records.count))
                    records.records[row].profit = Double(generator.next() % 200) - 100
                    records.records[row].status = ["Active", "Paused", "Finished"][Int(generator.next() % 3)]
                    table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                }
            }
            table.endUpdates()
            #expect(shown(table) == expected(), "round \(round)")
            let total = expected().reduce(0) { $0 + records.records[$1].profit }
            #expect(table.summaryValue(forColumnID: "profit") == total, "round \(round)")
        }
    }

    /// Updates of some columns read again only the keys of those columns:
    /// a sort by name doesn't read names when only profits change.
    @Test func readsTheKeysOfChangedColumnsOnly() {
        let records = Records(count: 300)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let descriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.sortDescriptors = descriptors
        table.rowFilter = NGRowFilter(searchText: "campaign 1", columnIDs: ["name"])
        let profit = IndexSet(integer: 1), name = IndexSet(integer: 0)
        func expected() -> [Int] {
            records.expectedOrder(descriptors, tableView: table).filter { records.records[$0].name.lowercased().hasPrefix("campaign 1") }
        }
        var reads = records.sortReads
        records.records[5].profit = 999
        table.reloadData(forRowIndexes: [5, 6, 7], columnIndexes: profit)
        #expect(records.sortReads == reads)
        #expect(shown(table) == expected())
        // A changed name moves the row and may hide it.
        records.records[12].name = "Campaign 0"
        records.records[200].name = "Campaign 1x"
        reads = records.sortReads
        table.reloadData(forRowIndexes: [12, 200], columnIndexes: name)
        #expect(records.sortReads - reads == 2)
        #expect(shown(table) == expected())
        // New rows are read whatever the columns.
        table.beginUpdates()
        records.records.insert(.init(id: 5000, name: "Campaign 100a", profit: 1, status: "Active"), at: 3)
        table.insertRows(at: [3])
        records.records[50].profit = 5
        table.reloadData(forRowIndexes: [50], columnIndexes: profit)
        table.endUpdates()
        #expect(shown(table) == expected())
        #expect(shown(table).contains(3))
    }

    /// Selections above `identitySelectionLimit` keep their rows across a
    /// reload instead of their identities; all rows selected stay all
    /// selected, also with new rows. Live updates move them by ranges.
    @Test func largeSelectionsSkipIdentities() {
        let count = NGTableView.identitySelectionLimit + 500
        let records = Records(count: count)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        table.selectAll(nil)
        #expect(table.selectedRowIndexes.count == count)
        #expect(table.selectedIdentifiers.isEmpty)
        // Inserted rows aren't selected; the others stay selected.
        records.records.insert(.init(id: -1, name: "New", profit: 0, status: "Active"), at: 3)
        table.insertRows(at: [3])
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 0..<(count + 1)).subtracting([3]))
        // A reload with more rows: everything stays selected.
        table.selectAll(nil)
        records.records.append(.init(id: -2, name: "Later", profit: 0, status: "Active"))
        table.reloadData()
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 0..<(count + 2)))
        // Back under the limit: identities again.
        table.selectRowIndexes([10, 20], byExtendingSelection: false)
        #expect(Set(table.selectedIdentifiers.values) == [AnyHashable(records.records[10].id), AnyHashable(records.records[20].id)])
    }

    /// Above `synchronousSearchLimit` the first search reads its words in
    /// slices: the previous rows show meanwhile, rows that change or come
    /// and go meanwhile are read too, and the filter then applies.
    @Test func searchesLargeTablesInSlices() async throws {
        let records = Records(count: 3_000)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.synchronousSearchLimit = 1_000
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        func expected(_ prefix: String) -> [Int] {
            records.expectedOrder(table.sortDescriptors, tableView: table).filter { records.records[$0].name.lowercased().hasPrefix(prefix) }
        }
        table.rowFilter = NGRowFilter(searchText: "campaign 1", columnIDs: ["name"])
        #expect(table.isSearchingRows)
        #expect(table.numberOfRows == 3_000)
        // Typing on keeps reading the same words.
        table.rowFilter = NGRowFilter(searchText: "campaign 12", columnIDs: ["name"])
        #expect(table.isSearchingRows)
        // A feed meanwhile.
        var generator = SplitMix64(seed: 11)
        var nextID = 10_000
        for _ in 0..<10 {
            table.beginUpdates()
            let index = Int(generator.next() % UInt64(records.records.count))
            records.records.insert(.init(id: nextID, name: "Campaign 12\(nextID)", profit: 50, status: "Active"), at: index)
            nextID += 1
            table.insertRows(at: [index])
            let removed = Int(generator.next() % UInt64(records.records.count))
            records.records.remove(at: removed)
            table.removeRows(at: [removed])
            let renamed = Int(generator.next() % UInt64(records.records.count))
            records.records[renamed].name = "Campaign 12 renamed"
            table.reloadData(forRowIndexes: [renamed], columnIndexes: [0])
            table.endUpdates()
            await Task.yield()
        }
        try await waitWhile { table.isSearchingRows }
        #expect(!table.isSearchingRows)
        #expect(shown(table) == expected("campaign 12"))
        let total = expected("campaign 12").reduce(0) { $0 + records.records[$1].profit }
        #expect(table.summaryValue(forColumnID: "profit") == total)
        // The words are kept: the next search is immediate.
        table.rowFilter = NGRowFilter(searchText: "campaign 2", columnIDs: ["name"])
        #expect(!table.isSearchingRows)
        #expect(shown(table) == expected("campaign 2"))
    }

    /// Above `synchronousCopyLimit` the copy is read in slices and formatted
    /// on all cores: the same text as `copyText(forRows:)`, without the rows
    /// a feed removes meanwhile.
    /// A tick that moves thousands of rows (placed together, not one by
    /// one) leaves the same order as sorting from scratch, ties in data
    /// source order, also with rows inserted and removed in the batch.
    @Test func manyMovesInOneTickSortLikeAFreshSort() async throws {
        let records = Records(count: 20_000)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.synchronousSortLimit = .max
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: true), NSSortDescriptor(key: "name", ascending: false)]
        var random = SplitMix(seed: 9)
        for round in 0..<3 {
            table.beginUpdates()
            for _ in 0..<12_000 {
                let row = Int.random(in: 0..<records.records.count, using: &random)
                records.records[row].profit = Double(Int.random(in: -50..<50, using: &random))
                table.reloadData(forRowIndexes: [row], columnIndexes: [1])
            }
            records.records.remove(at: 10)
            table.removeRows(at: [10])
            records.records.insert(.init(id: 90_000 + round, name: "New \(round)", profit: 0, status: "Active"), at: 3)
            table.insertRows(at: [3])
            table.endUpdates()
            let expected = records.records.indices.sorted { a, b in
                let x = records.records[a], y = records.records[b]
                if x.profit != y.profit { return x.profit < y.profit }
                let names = x.name.localizedStandardCompare(y.name)
                if names != .orderedSame { return names == .orderedDescending }
                return a < b
            }
            #expect((0..<table.numberOfRows).map(table.sourceRow) == expected, "round \(round)")
        }
    }

    @Test func copiesLargeSelectionsInTheBackground() async throws {
        let records = Records(count: 5_000)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NGTableTests.copy.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        table.copyPasteboard = pasteboard
        table.synchronousCopyLimit = 100
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        table.selectAll(nil)
        let expected = table.copyText(forRows: table.selectedRowIndexes)
        table.copy(nil)
        #expect(table.isCopying)
        try await waitWhile { table.isCopying }
        #expect(pasteboard.string(forType: .string) == expected)
        // A row removed while the values are read is left out.
        table.selectRowIndexes(IndexSet(integersIn: 0..<3_000), byExtendingSelection: false)
        table.copy(nil)
        records.records.remove(at: 2_999)
        table.removeRows(at: [2_999])
        try await waitWhile { table.isCopying }
        #expect(pasteboard.string(forType: .string) == table.copyText(forRows: IndexSet(integersIn: 0..<2_999)))
    }

    /// Without multiple selection, a reload keeps one row selected even when
    /// several rows share the selected identity (like NSTableView).
    @Test func singleSelectionStaysSingleAfterAReload() {
        let records = Records(count: 20)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.allowsMultipleSelection = false
        table.selectRowIndexes([4], byExtendingSelection: false)
        // Two records with the selected one's identity.
        records.records[9] = records.records[4]
        records.records[15] = records.records[4]
        table.reloadData()
        #expect(table.selectedRowIndexes.count == 1)
        #expect([4, 9, 15].contains(table.selectedRowIndexes.first ?? -1))
        #expect(table.selectedIdentifiers.count == 1)
    }

    /// A locale change reads the search words and group keys again (they are
    /// formatted text); the rows shown stay right.
    @Test func aLocaleChangeReadsWordsAndKeysAgain() {
        let records = Records(count: 300)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.rowFilter = NGRowFilter(searchText: "campaign 1", columnIDs: ["name"])
        table.rowGrouping = NGRowGrouping(columnID: "status")
        table.layoutSubtreeIfNeeded()
        let before = shown(table)
        let rows = table.numberOfRows
        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        #expect(table.searchIndex != nil)
        #expect(table.groupKeys != nil)
        #expect(table.numberOfRows == rows)
        #expect(shown(table) == before)
        // The table's observer may run before the collation's own: it drops
        // the collators of the old locale itself before it sorts again.
        let collators = NGTextCollation.current
        table.currentLocaleDidChange(Notification(name: NSLocale.currentLocaleDidChangeNotification))
        #expect(NGTextCollation.current !== collators)
        // Inside a batch: read again (every row evaluated) when it ends.
        let evaluations = table.filterEvaluations
        table.beginUpdates()
        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        #expect(table.filterEvaluations == evaluations)
        table.endUpdates()
        #expect(table.filterEvaluations > evaluations)
        #expect(table.groupKeys != nil && table.searchIndex != nil)
    }

    /// A locale change sorts text again (its collation changed), not numbers.
    @Test func aLocaleChangeSortsTextAgainNotNumbers() async throws {
        let records = Records(count: 100)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: true)]
        // Sorting again shows as a sort in the background.
        table.synchronousSortLimit = 10
        table.currentLocaleDidChange(Notification(name: NSLocale.currentLocaleDidChangeNotification))
        #expect(!table.isSortingRows)
        table.synchronousSortLimit = .max
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.synchronousSortLimit = 10
        table.currentLocaleDidChange(Notification(name: NSLocale.currentLocaleDidChangeNotification))
        #expect(table.isSortingRows)
        #expect(try await waitWhile { table.isSortingRows })
        #expect(shown(table) == records.expectedOrder(table.sortDescriptors, tableView: table))
    }

    /// A live sort by a number column places changed rows where a full sort
    /// puts them, for -0, NaN (empty), infinities, many equal values (the
    /// status, then the data source order decide), both ways, with rows
    /// coming and going.
    @Test(arguments: [true, false])
    func placementByOrderKeysMatchesAFullSort(_ ascending: Bool) {
        let records = Records(count: 600, seed: 9)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        var generator = SplitMix64(seed: ascending ? 3 : 4)
        let values: [Double] = [-0.0, 0, .nan, -.infinity, .infinity, -1, 1, 2.5, -2.5, 1e300, -1e-300, 7, 7, 7]
        func value() -> Double { values[Int(generator.next() % UInt64(values.count))] }
        for index in records.records.indices { records.records[index].profit = value() }
        table.reloadData()
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: ascending), NSSortDescriptor(key: "status", ascending: true)]
        func expected() -> [Int] {
            let rows = Array(records.records.indices)
            return rows.sorted { a, b in
                let (x, y) = (records.records[a], records.records[b])
                let (p, q) = (x.profit.isNaN ? nil : x.profit, y.profit.isNaN ? nil : y.profit)
                if (p == nil) != (q == nil) { return (p == nil) == ascending }
                if let p, let q, p != q { return (p < q) == ascending }
                if x.status != y.status { return x.status < y.status }
                return a < b
            }
        }
        #expect(shown(table) == expected())
        for round in 0..<30 {
            table.beginUpdates()
            var changed = IndexSet()
            for _ in 0..<40 {
                let row = Int(generator.next() % UInt64(records.records.count))
                records.records[row].profit = value()
                changed.insert(row)
            }
            table.reloadData(forRowIndexes: changed, columnIndexes: [1])
            if round % 3 == 0 {
                let row = Int(generator.next() % UInt64(records.records.count))
                records.records.remove(at: row)
                table.removeRows(at: [row])
                records.records.append(.init(id: 5_000 + round, name: "New", profit: value(), status: "Active"))
                table.insertRows(at: [records.records.count - 1])
            }
            table.endUpdates()
            #expect(shown(table) == expected(), "round \(round)")
        }
    }

    /// A large table changing more sort values in a batch than it places at
    /// once (`synchronousPlacementLimit`): the changed rows keep their places
    /// meanwhile, every row stays shown once, and rounds in the background,
    /// some of them while rows change, come and go, end in the full order.
    @Test func manyChangedRowsSettleInTheBackground() async throws {
        let records = Records(count: 3_000, seed: 12)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.synchronousSortLimit = 1_000
        table.synchronousPlacementLimit = 100
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false), NSSortDescriptor(key: "status", ascending: true)]
        try await waitForSort(table)
        func expected() -> [Int] {
            Array(records.records.indices).sorted { a, b in
                let (x, y) = (records.records[a], records.records[b])
                if x.profit != y.profit { return x.profit > y.profit }
                if x.status != y.status { return x.status < y.status }
                return a < b
            }
        }
        #expect(shown(table) == expected())
        var generator = SplitMix64(seed: 5)
        for round in 0..<20 {
            table.beginUpdates()
            var changed = IndexSet()
            for _ in 0..<200 {
                let row = Int(generator.next() % UInt64(records.records.count))
                records.records[row].profit = Double(generator.next() % 400) - 200
                changed.insert(row)
            }
            table.reloadData(forRowIndexes: changed, columnIndexes: [1])
            if round % 2 == 0 {
                let row = Int(generator.next() % UInt64(records.records.count))
                records.records.remove(at: row)
                table.removeRows(at: [row])
                records.records.append(.init(id: 9_000 + round, name: "New \(round)", profit: Double(round), status: "Active"))
                table.insertRows(at: [records.records.count - 1])
            }
            table.endUpdates()
            if round == 0 { #expect(table.isSettlingSort) }
            #expect(shown(table).sorted() == Array(records.records.indices), "round \(round)")
            // Rounds run now and then while the rows go on changing.
            if round % 4 == 3 { try await Task.sleep(for: .milliseconds(20)) }
        }
        try await waitWhile { table.isSettlingSort }
        #expect(!table.isSettlingSort)
        #expect(shown(table) == expected())
    }

    /// A settling sort's round moves rows: the cells of records that stay in
    /// view move with them, not read and laid out again (every round did,
    /// for every row in view); the rows show their records.
    @Test func settledRoundsKeepTheCellsOfRecordsInView() async throws {
        let records = Records(count: 3_000, seed: 3)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.synchronousSortLimit = 1_000
        table.synchronousPlacementLimit = 100
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        try await waitForSort(table)
        table.layoutSubtreeIfNeeded()
        let rowsInView = try #require(table.lastVisibleRange?.rows)
        func recordsInView() -> Set<Int> { Set(rowsInView.map { records.records[table.sourceRow($0)].id }) }
        var generator = SplitMix64(seed: 8)
        table.beginUpdates()
        var changed = IndexSet()
        // New values in the middle: the rows at the top stay there.
        for _ in 0..<300 {
            let row = Int(generator.next() % UInt64(records.records.count))
            records.records[row].profit = Double(generator.next() % 60) - 30
            changed.insert(row)
        }
        table.reloadData(forRowIndexes: changed, columnIndexes: [1])
        table.endUpdates()
        #expect(table.isSettlingSort)
        table.layoutSubtreeIfNeeded()
        let before = recordsInView()
        let reads = records.nameReads
        try await waitWhile { table.isSettlingSort }
        #expect(!table.isSettlingSort)
        table.layoutSubtreeIfNeeded()
        let after = recordsInView()
        #expect(records.nameReads - reads <= after.subtracting(before).count, "\(records.nameReads - reads) reads, \(after.subtracting(before).count) new, \(after.count)")
        for row in rowsInView {
            let cell = try #require(table.visibleCell(row: row, columnID: "name"))
            guard case .text(let text, _, _) = cell.content else { Issue.record("row \(row): no text"); continue }
            #expect(text == records.records[table.sourceRow(row)].name, "row \(row)")
        }
    }

    /// A large selection of a sorted table (its display rows scattered
    /// among the data source rows) is kept by handle: batches and settling
    /// rounds move rows without mapping it through the order, and it stays
    /// the same records, as read and as drawn.
    @Test func aLargeSortedSelectionStaysByHandle() async throws {
        let records = Records(count: 20_000, seed: 6)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.synchronousSortLimit = 1_000
        table.synchronousPlacementLimit = 100
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        try await waitForSort(table)
        // The first 8,000 shown: scattered data source rows.
        table.selectRowIndexes(table.sourceRows(forDisplayRows: IndexSet(integersIn: 0..<8_000)), byExtendingSelection: false)
        let selected = Set(table.selectedRowIndexes.map { records.records[$0].id })
        #expect(selected.count == 8_000)
        var generator = SplitMix64(seed: 2)
        for round in 0..<10 {
            table.beginUpdates()
            var changed = IndexSet()
            for _ in 0..<300 {
                let row = Int(generator.next() % UInt64(records.records.count))
                records.records[row].profit = Double(generator.next() % 400) - 200
                changed.insert(row)
            }
            table.reloadData(forRowIndexes: changed, columnIndexes: [1])
            table.endUpdates()
            #expect(table.keptSelection != nil, "round \(round)")
            if round % 3 == 2 { try await Task.sleep(for: .milliseconds(60)) }
        }
        try await waitWhile { table.isSettlingSort }
        #expect(table.keptSelection != nil)
        for row in 0..<30 {
            #expect(table.isDisplayRowSelected(row) == selected.contains(records.records[table.sourceRow(row)].id), "row \(row)")
        }
        #expect(table.numberOfSelectedRows == 8_000)
        #expect(Set(table.selectedRowIndexes.map { records.records[$0].id }) == selected)
        #expect(table.keptSelection == nil)
    }

    /// A large table sorted for the first time shows the data source's order
    /// while it sorts, without an order of its own (making one of every row
    /// held the main thread), and reads the values in slices that fill only
    /// what they read (filling a million values at once held it two or three
    /// slices long). Background work leaves a core to the main thread.
    @Test func aFirstBackgroundSortDoesLittleOnTheMainThread() async throws {
        let records = Records(count: 50_000, seed: 4)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.synchronousSortLimit = 1_000
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        #expect(table.isSortingRows)
        #expect(table.sortedOrder == nil)
        #expect((0..<10).map(table.sourceRow) == Array(0..<10))
        // One slice reads part of the rows and fills only those.
        let done = table.readBackgroundSortSlice()
        let filled = try #require(table.backgroundSort?.values.first?.count)
        #expect(done == false && filled < 50_000, "\(filled) values filled")
        try await waitForSort(table)
        #expect(shown(table) == records.expectedOrder(table.sortDescriptors, tableView: table))
        #expect(ProcessInfo.processInfo.activeProcessorCount == 1 || NGParallelism.backgroundWorkers < ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Rows inserted while a large table sorts in the background go to the
    /// end of the order shown meanwhile, found from the batch's inserts, not
    /// by looking through every row (a million, for each batch of a feed);
    /// once sorted, they are where they go.
    @Test func insertsDuringABackgroundSortDontLookAtEveryRow() async throws {
        let records = Records(count: 3_000)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.synchronousSortLimit = 2
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: true)]
        #expect(table.isSortingRows)
        table.sortScannedAllRows = false
        for id in 0..<5 {
            records.records.append(.init(id: 10_000 + id, name: "New \(id)", profit: Double(id * 40 - 100), status: "Active"))
            table.beginUpdates()
            records.records.remove(at: id)
            table.removeRows(at: [id])
            table.insertRows(at: [records.records.count - 1])
            table.endUpdates()
            #expect(table.numberOfRows == 3_000)
            #expect(table.sourceRow(table.numberOfRows - 1) == records.records.count - 1)   // Last, meanwhile.
        }
        #expect(!table.sortScannedAllRows)
        try await waitForSort(table)
        let profits = (0..<table.numberOfRows).map { records.records[table.sourceRow($0)].profit }
        #expect(profits == profits.sorted())
        #expect(Set(shown(table)) == Set(0..<3_000))
    }

    private func waitForSort(_ table: NGTableView) async throws {
        try await waitWhile { table.isSortingRows }
        #expect(!table.isSortingRows)
    }

    /// The descriptors' selectors, as an app sorting for NSTableView passes
    /// them: `localizedCompare:` and the case-insensitive ones compare text
    /// that way, synchronously, in the background and in `NGSorting`.
    /// `compare:` (NSSortDescriptor's default) and `localizedStandardCompare:`
    /// keep the table's Finder order, numbers in text by value.
    @Test func descriptorSelectorsCompareText() async throws {
        @MainActor final class Names: NGTableViewDataSource {
            var names = ["item 9", "item 10", "Zebra", "zebra", "Ångström", "œuf"]
            func numberOfRows(in tableView: NGTableView) -> Int { names.count }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text(names[row]) }
        }
        let names = Names()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200))]
        table.dataSource = names
        table.sortsRows = true
        defer { withExtendedLifetime(names) {} }
        func shownNames() -> [String] { (0..<table.numberOfRows).map { names.names[table.sourceRow($0)] } }
        func sort(_ selector: Selector?) {
            table.sortDescriptors = [selector.map { NSSortDescriptor(key: "name", ascending: true, selector: $0) }
                                     ?? NSSortDescriptor(key: "name", ascending: true)]
        }
        // (Each as Foundation's own comparison orders them, ties in data order.)
        let finder = ["Ångström", "item 9", "item 10", "œuf", "zebra", "Zebra"]
        sort(nil)
        #expect(shownNames() == finder)
        sort(#selector(NSString.localizedStandardCompare(_:)))
        #expect(shownNames() == finder)
        // Digits as characters: "1" before "9".
        sort(#selector(NSString.localizedCompare(_:)))
        #expect(shownNames() == ["Ångström", "item 10", "item 9", "œuf", "zebra", "Zebra"])
        // Case doesn't count: the data's order.
        sort(#selector(NSString.localizedCaseInsensitiveCompare(_:)))
        #expect(shownNames() == ["Ångström", "item 10", "item 9", "œuf", "Zebra", "zebra"])
        // Not localized: "œ" after the ASCII letters.
        let literal = ["Ångström", "item 10", "item 9", "Zebra", "zebra", "œuf"]
        sort(#selector(NSString.caseInsensitiveCompare(_:)))
        #expect(shownNames() == literal)
        // Live updates place rows by the same comparison.
        names.names[1] = "item 0"
        table.reloadData(forRowIndexes: [1], columnIndexes: [0])
        #expect(shownNames() == ["Ångström", "item 0", "item 9", "Zebra", "zebra", "œuf"])
        names.names[1] = "item 10"
        table.reloadData(forRowIndexes: [1], columnIndexes: [0])
        // In the background too.
        table.synchronousSortLimit = 2
        sort(#selector(NSString.localizedStandardCompare(_:)))
        try await waitForSort(table)
        #expect(shownNames() == finder)
        sort(#selector(NSString.caseInsensitiveCompare(_:)))
        try await waitForSort(table)
        #expect(shownNames() == literal)
        // And sorting for the app.
        let descriptor = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.caseInsensitiveCompare(_:)))
        let order = NGSorting.order(ofRows: names.names.count, by: [descriptor]) { _, row in .text(names.names[row]) }
        #expect(order.map { names.names[$0] } == literal)
    }

    /// The limits count what the work costs, not rows alone: comparing text
    /// costs about 16 times comparing numbers (a text sort of 49,000 rows
    /// held the main thread 160 ms, of numbers 11 ms), so text goes to the
    /// background from about 3,100 rows; a first search reads every searched
    /// column of every row, so it counts rows × columns.
    @Test func limitsCountTheCost() async throws {
        let records = Records(count: 5_000)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        #expect(table.synchronousSortLimit == 50_000)
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: true)]
        #expect(!table.isSortingRows)   // Numbers: at once.
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        #expect(table.isSortingRows)    // Text: in the background.
        try await waitForSort(table)
        #expect(table.sourceRow(0) == 0)
        // Shown as text but sorted by numbers (`sortValueFor`): at once.
        table.sortDescriptors = [NSSortDescriptor(key: "rank", ascending: true)]
        #expect(!table.isSortingRows)
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        try await waitForSort(table)
        #expect(table.sourceRow(0) == 0 && table.sourceRow(1) == 1)   // "Campaign 0", "Campaign 1"…
        // Search: 12,000 rows of 2 text columns go to the background; of one, at once.
        let many = Records(count: 12_000)
        let wide = makeTable(many)
        defer { withExtendedLifetime(many) {} }
        wide.synchronousSearchLimit = 20_000
        wide.rowFilter = NGRowFilter(searchText: "campaign 7", columnIDs: ["name"])
        #expect(!wide.isSearchingRows)
        wide.rowFilter = NGRowFilter(searchText: "active")
        #expect(wide.isSearchingRows)
    }

    /// Above `synchronousSortLimit` a full sort runs in the background: the
    /// previous order shows meanwhile (reversed for the other direction).
    @Test func sortsLargeTablesInTheBackground() async throws {
        let records = Records(count: 3_000)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.synchronousSortLimit = 1_000
        let descending = [NSSortDescriptor(key: "profit", ascending: false)]
        table.sortDescriptors = descending
        #expect(table.isSortingRows)
        #expect(shown(table) == Array(0..<3_000))
        try await waitForSort(table)
        let sorted = records.expectedOrder(descending, tableView: table)
        #expect(shown(table) == sorted)
        // The other direction: the reversed order at once, then the stable one.
        let ascending = [NSSortDescriptor(key: "profit", ascending: true)]
        table.sortDescriptors = ascending
        #expect(shown(table) == sorted.reversed())
        try await waitForSort(table)
        #expect(shown(table) == records.expectedOrder(ascending, tableView: table))
        // Live updates of single rows stay synchronous.
        records.records[5].profit = 10_000
        table.reloadData(forRowIndexes: [5], columnIndexes: [1])
        #expect(!table.isSortingRows)
        #expect(shown(table).last == 5)
    }

    /// Rows that change while the background sort runs take their place when
    /// it's done; inserts and removes start it over.
    @Test func updatesWhileSortingInTheBackground() async throws {
        let records = Records(count: 3_000)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.synchronousSortLimit = 1_000
        let descriptors = [NSSortDescriptor(key: "status", ascending: true), NSSortDescriptor(key: "profit", ascending: false)]
        table.sortDescriptors = descriptors
        var generator = SplitMix64(seed: 5)
        var nextID = 10_000
        for step in 0..<20 {
            if step % 5 == 4 {
                table.beginUpdates()
                let index = Int(generator.next() % UInt64(records.records.count + 1))
                records.records.insert(.init(id: nextID, name: "New", profit: 500, status: "Active"), at: index)
                nextID += 1
                table.insertRows(at: [index])
                let removed = Int(generator.next() % UInt64(records.records.count))
                records.records.remove(at: removed)
                table.removeRows(at: [removed])
                table.endUpdates()
            } else {
                let row = Int(generator.next() % UInt64(records.records.count))
                records.records[row].profit = Double(generator.next() % 400) - 200
                table.reloadData(forRowIndexes: [row], columnIndexes: [1])
            }
            await Task.yield()
        }
        try await waitForSort(table)
        #expect(shown(table) == records.expectedOrder(descriptors, tableView: table))
        #expect(table.summaryValue(forColumnID: "profit") == records.records.reduce(0) { $0 + $1.profit })
        // A reload sorts again; the filter applies to the interim order too.
        records.records.shuffle()
        table.reloadData()
        table.rowFilter = NGRowFilter { [weak records] row in (records?.records[row].profit ?? 0) > 0 }
        #expect(shown(table).allSatisfy { records.records[$0].profit > 0 })
        try await waitForSort(table)
        let positive = records.expectedOrder(descriptors, tableView: table).filter { records.records[$0].profit > 0 }
        #expect(shown(table) == positive)
    }

    /// When a background sort finishes, the selection stays on its records
    /// (with ties in the key and with a filter), and so do "selected rows"
    /// totals.
    @Test(arguments: [false, true])
    func theSelectionStaysWhenABackgroundSortFinishes(filtered: Bool) async throws {
        let records = Records(count: 60)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.synchronousSortLimit = 40
        table.summaryScope = .selectedRows
        if filtered { table.rowFilter = NGRowFilter { [weak records] row in (records?.records[row].profit ?? 0) > -60 } }
        table.sortDescriptors = [NSSortDescriptor(key: "status", ascending: true)]
        try await waitForSort(table)
        let picked = [0, 1, 2, 10, 20].map(table.sourceRow)
        table.selectRowIndexes(IndexSet(picked), byExtendingSelection: false)
        let ids = Set(picked.map { records.records[$0].id })
        let total = picked.reduce(0) { $0 + records.records[$1].profit }
        // Reversed: sorted in the background, ties in the status.
        table.sortDescriptors = [NSSortDescriptor(key: "status", ascending: false)]
        try await waitForSort(table)
        #expect(Set(table.selectedRowIndexes.map { records.records[$0].id }) == ids)
        #expect(table.summaryValue(forColumnID: "profit") == total)
        #expect(shown(table) == records.expectedOrder(table.sortDescriptors, tableView: table).filter { !filtered || records.records[$0].profit > -60 })
        // The data source reverses its rows (ties follow its order).
        let previous = Array(records.records.indices)
        records.records.reverse()
        table.reorderRows(from: previous, to: previous.reversed())
        try await waitForSort(table)
        #expect(Set(table.selectedRowIndexes.map { records.records[$0].id }) == ids)
        #expect(table.summaryValue(forColumnID: "profit") == total)
        #expect(shown(table) == records.expectedOrder(table.sortDescriptors, tableView: table).filter { !filtered || records.records[$0].profit > -60 })
    }

    /// Numbers given by range start as NaN for every descriptor: a source
    /// that wrote some for one descriptor and gave up leaves nothing in the
    /// next one's (rows it doesn't write are empty).
    @Test func sortNumbersStartEmptyForEachDescriptor() async throws {
        @MainActor final class Numbers: NGTableViewDataSource {
            func numberOfRows(in tableView: NGTableView) -> Int { 100 }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
                column.id == "a" ? .number(Double(row % 3)) : (row.isMultiple(of: 2) ? .number(Double(row)) : .empty)
            }
            func tableView(_ tableView: NGTableView, sortNumbersFor column: NGTableColumn, rows: Range<Int>,
                           into values: UnsafeMutableBufferPointer<Double>) -> Bool {
                if column.id == "a" {
                    for index in values.indices { values[index] = 0 }   // Written, then given up.
                    return false
                }
                for row in rows where row.isMultiple(of: 2) { values[row - rows.lowerBound] = Double(row) }
                return true
            }
        }
        let numbers = Numbers()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [.column(NGTableColumn("a", title: "A")), .column(NGTableColumn("b", title: "B"))]
        table.dataSource = numbers
        defer { withExtendedLifetime(numbers) {} }
        table.synchronousSortLimit = 10
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "a", ascending: true), NSSortDescriptor(key: "b", ascending: true)]
        try await waitForSort(table)
        let expected = NGSorting.order(ofRows: 100, by: table.sortDescriptors) { key, row in
            numbers.tableView(table, valueFor: NGTableColumn(key, title: key), row: row)
        }
        #expect(shown(table) == expected)
    }

    /// A batch's changed rows give their sort numbers at once
    /// (`sortNumbersFor(atRows:)`), not one value at a time; they go where
    /// values read one by one would put them, empty ones and NaN included.
    @Test func changedRowsSortNumbersReadAtOnce() {
        @MainActor final class Numbers: NGTableViewDataSource {
            var a: [Double], b: [Double]
            var valueReads = 0, givenRows = 0
            init(count: Int) {
                var generator = SplitMix64(seed: 4)
                a = (0..<count).map { _ in Double(generator.next() % 5) }
                b = (0..<count).map { _ in generator.next() % 7 == 0 ? .nan : Double(generator.next() % 1_000) - 500 }
            }
            func numberOfRows(in tableView: NGTableView) -> Int { a.count }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
                let number = column.id == "a" ? a[row] : b[row]
                return number.isNaN ? .empty : .number(number)
            }
            func tableView(_ tableView: NGTableView, sortValueFor column: NGTableColumn, row: Int) -> NGCellValue {
                valueReads += 1
                return self.tableView(tableView, valueFor: column, row: row)
            }
            func tableView(_ tableView: NGTableView, sortNumbersFor column: NGTableColumn, atRows rows: UnsafeBufferPointer<Int>,
                           into values: UnsafeMutableBufferPointer<Double>) -> Bool {
                givenRows += rows.count
                for (index, row) in rows.enumerated() { values[index] = column.id == "a" ? a[row] : b[row] }
                return true
            }
        }
        let numbers = Numbers(count: 2_000)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [.column(NGTableColumn("a", title: "A")), .column(NGTableColumn("b", title: "B"))]
        table.dataSource = numbers
        defer { withExtendedLifetime(numbers) {} }
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "a", ascending: true), NSSortDescriptor(key: "b", ascending: false)]
        func expected() -> [Int] {
            NGSorting.order(ofRows: numbers.a.count, by: table.sortDescriptors) { key, row in
                numbers.tableView(table, valueFor: NGTableColumn(key, title: key), row: row)
            }
        }
        #expect(shown(table) == expected())
        var generator = SplitMix64(seed: 9)
        for round in 0..<30 {
            let reads = numbers.valueReads
            table.beginUpdates()
            var changed = IndexSet()
            for _ in 0..<40 {
                let row = Int(generator.next() % 2_000)
                if generator.next() % 2 == 0 { numbers.a[row] = Double(generator.next() % 5) }
                numbers.b[row] = generator.next() % 4 == 0 ? .nan : Double(generator.next() % 1_000) - 500
                changed.insert(row)
            }
            table.reloadData(forRowIndexes: changed, columnIndexes: [0, 1])
            table.endUpdates()
            #expect(numbers.valueReads == reads, "round \(round): values read one by one")
            #expect(shown(table) == expected(), "round \(round)")
        }
        #expect(numbers.givenRows > 0)
    }

    /// Reversing a large sort reuses the values read; rows inserted before
    /// that sort runs (a feed's update already queued) have no values in it:
    /// they are placed afterwards instead of being sorted with it.
    @Test func rowsInsertedBeforeAReversedSortRuns() async throws {
        let records = Records(count: 3_000)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.synchronousSortLimit = 1_000
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        try await waitForSort(table)
        let reversed = [NSSortDescriptor(key: "profit", ascending: true)]
        table.sortDescriptors = reversed
        // Same turn: the reversed sort hasn't started.
        table.beginUpdates()
        for (offset, profit) in [(0, 777.0), (1_500, -777), (3_001, 5)] {
            records.records.insert(.init(id: 50_000 + offset, name: "New \(offset)", profit: profit, status: "Active"), at: offset)
            table.insertRows(at: [offset])
        }
        table.endUpdates()
        try await waitForSort(table)
        #expect(shown(table) == records.expectedOrder(reversed, tableView: table))
    }
}
#endif

/// A small deterministic random number generator.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
