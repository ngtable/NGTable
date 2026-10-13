#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// A table after live updates (batches of inserts, removes, moves and
/// changed values in any order, nested batches, single updates) shows what a
/// fresh table on the same data shows: the rows and their order, the groups,
/// their order and subtotals, the totals in the summary scope, and the
/// selection. Randomized with fixed seeds, with and without a filter, the
/// table's sort and grouping, and with background work.
@Suite("Consistency with a fresh table")
@MainActor
struct NGConsistencyTests {
    @MainActor
    final class Feed: NGTableViewDataSource, NGTableViewDelegate {
        struct Record {
            var id: Int
            var name: String
            /// Empty: no value (the "No Value" group).
            var status: String
            /// `nil`: an empty cell.
            var profit: Double?
            var spend: Double
            /// Not a column: a formula input only.
            var budget: Double
            /// A number, text or nothing.
            var score: NGCellValue
        }

        var records: [Record] = []
        var generator: SplitMix64
        var nextID = 0
        /// The delegate rejects rows whose id is a multiple of this (0: none).
        var rejectedIDs = 0

        static let words = ["Alpha", "beta", "Ёлка", "йогурт", "Іван", "café", "Straße", "東京", "x-1", "Ünal", "ПРОДАЖИ"]
        static let statuses = ["Active", "Paused", "Finished", ""]

        init(count: Int, seed: UInt64) {
            generator = SplitMix64(seed: seed)
            records = (0..<count).map { _ in makeRecord() }
        }

        func random(_ bound: Int) -> Int { Int(generator.next() % UInt64(max(bound, 1))) }

        func makeRecord() -> Record {
            defer { nextID += 1 }
            var record = Record(id: nextID, name: "", status: "", profit: nil, spend: 1, budget: 1, score: .empty)
            change(&record, columns: Self.changeableColumns)
            return record
        }

        static let changeableColumns: Set<String> = ["name", "status", "profit", "spend", "budget", "score"]

        func change(_ record: inout Record, columns: Set<String>) {
            if columns.contains("name") { record.name = "\(Self.words[random(Self.words.count)]) \(random(40))" }
            if columns.contains("status") { record.status = Self.statuses[random(Self.statuses.count)] }
            if columns.contains("profit") { record.profit = random(8) == 0 ? nil : Double(random(201) - 100) }
            if columns.contains("spend") { record.spend = Double(1 + random(50)) }
            if columns.contains("budget") { record.budget = Double(1 + random(100)) }
            if columns.contains("score") {
                record.score = switch random(4) {
                case 0: .empty
                case 1: .text("s\(random(30))")
                default: .number(Double(random(30)))
                }
            }
        }

        func numberOfRows(in tableView: NGTableView) -> Int { records.count }

        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            let record = records[row]
            return switch column.id {
            case "name": .text(record.name)
            case "status": record.status.isEmpty ? .empty : .text(record.status)
            case "profit", "profitAverage": record.profit.map(NGCellValue.number) ?? .empty
            case "spend": .number(record.spend)
            case "budget": .number(record.budget)
            case "score": record.score
            default: .empty
            }
        }

        func tableView(_ tableView: NGTableView, sortValueFor column: NGTableColumn, row: Int) -> NGCellValue {
            // The spend column sorts by its value as a number, shown or not.
            self.tableView(tableView, valueFor: column, row: row)
        }

        func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { records[row].id }

        func tableView(_ tableView: NGTableView, shouldSelectRow row: Int) -> Bool {
            rejectedIDs == 0 || records[row].id % rejectedIDs != 0
        }
    }

    static let roi = NGSummaryFormula("roi", using: ["profit", "budget"]) { values in
        guard let budget = values.sum("budget"), budget != 0 else { return nil }
        return (values.sum("profit") ?? 0) / budget
    }

    static let columns: [NGColumnItem] = [
        .column(NGTableColumn("name", title: "Name", width: 160)),
        .column(NGTableColumn("status", title: "Status", width: 80)),
        .column(NGTableColumn("profit", title: "Profit", width: 80, format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
        .column(NGTableColumn("profitAverage", title: "Average", width: 80, format: .number(fractionDigits: 3),
                              summary: .aggregate(.average, including: .positive))),
        .column(NGTableColumn("spend", title: "Spend", width: 80, format: .number(fractionDigits: 0), summary: .aggregate(.max))),
        .column(NGTableColumn("score", title: "Score", width: 80, summary: .aggregate(.count))),
        .column(NGTableColumn("roi", title: "ROI", width: 80, format: .number(fractionDigits: 4), summary: .formula(roi))),
    ]

    /// What a table is set to show.
    struct Configuration {
        var searchText = ""
        var searchColumns: Set<String>?
        var condition = false
        var sortsRows = false
        var sort: [NSSortDescriptor] = []
        var grouping: [String]?
        var scope = NGSummaryScope.allRows
        var hidden: Set<String> = []

        func filter(_ feed: Feed) -> NGRowFilter? {
            guard !searchText.isEmpty || condition else { return nil }
            var filter = NGRowFilter(searchText: searchText, columnIDs: searchColumns)
            if condition {
                filter.isIncluded = { [weak feed] row in (feed?.records[row].profit ?? 0) > -30 }
            }
            return filter
        }
    }

    static func makeTable(_ feed: Feed, _ configuration: Configuration) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        // Everything at once (tests of background work lower the limits).
        table.synchronousSortLimit = .max
        table.synchronousSearchLimit = .max
        table.synchronousSummaryLimit = .max
        table.columns = columns
        table.hiddenColumnIDs = configuration.hidden
        table.sortsRows = configuration.sortsRows
        table.sortDescriptors = configuration.sort
        table.rowFilter = configuration.filter(feed)
        table.rowGrouping = configuration.grouping.map { NGRowGrouping(columnIDs: $0) }
        table.summaryScope = configuration.scope
        table.dataSource = feed
        table.delegate = feed
        table.layoutSubtreeIfNeeded()
        return table
    }

    /// What a table shows, by record ids.
    struct Snapshot: Equatable, CustomStringConvertible {
        var rows: [String]
        var totals: [String: String]
        var subtotals: [String: [String: String]]
        var selection: Set<Int>

        var description: String {
            "rows \(rows.prefix(30))… (\(rows.count)), totals \(totals.sorted { $0.key < $1.key }), selection \(selection.sorted())"
        }
    }

    static func snapshot(_ table: NGTableView, _ feed: Feed) -> Snapshot {
        var rows: [String] = []
        for row in 0..<table.numberOfRows {
            if let node = table.groupNode(atDisplayRow: row) {
                rows.append("group \(table.groupTree.nodes[node].group.path) \(table.groupTree.nodes[node].rows.count)")
            } else {
                let source = table.sourceRow(row)
                rows.append(source >= 0 && source < feed.records.count ? "row \(feed.records[source].id)" : "bad \(source)")
            }
        }
        var subtotals: [String: [String: String]] = [:]
        for node in table.groupTree.nodes.indices {
            subtotals[table.groupTree.nodes[node].group.path.joined(separator: "/")] = table.subtotalTexts(ofNode: node)
        }
        let selection = Set(table.selectedRowIndexes.map { $0 < feed.records.count ? feed.records[$0].id : -1 - $0 })
        return Snapshot(rows: rows, totals: table.summaryTexts, subtotals: subtotals, selection: selection)
    }

    /// A fresh table on the same data, with the same groups collapsed and the
    /// same records selected.
    static func fresh(like table: NGTableView, _ feed: Feed, _ configuration: Configuration) -> NGTableView {
        let fresh = makeTable(feed, configuration)
        if table.rowGrouping != nil {
            fresh.groupsExpandedByDefault = table.groupsExpandedByDefault
            fresh.toggledGroups = table.toggledGroups
            fresh.updateDisplayedRows(rebuildingSummaries: false) { fresh.buildGroupedDisplay() }
        }
        let ids = Set(table.selectedRowIndexes.compactMap { $0 < feed.records.count ? feed.records[$0].id : nil })
        fresh.selectRowIndexes(IndexSet(feed.records.indices.filter { ids.contains(feed.records[$0].id) }), byExtendingSelection: false)
        return fresh
    }

    /// The table's internal arrays agree with each other and with the rows.
    static func checkInvariants(_ table: NGTableView, _ context: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let count = table.numberOfSourceRows
        // Per-row arrays are by row handle (`NGRowHandles`), orders list live handles.
        let capacity = table.rowHandles.capacity
        let live = { (handle: Int) in table.rowHandles.contains(Int32(truncatingIfNeeded: handle)) }
        #expect(table.rowHandles.count == count, "\(context): rowHandles", sourceLocation: sourceLocation)
        if let rowMap = table.rowMap {
            #expect(table.filteredRows?.integerElements == rowMap, "\(context): filteredRows", sourceLocation: sourceLocation)
            #expect(table.filteredRows?.capacity ?? 0 >= capacity, "\(context): filteredRows capacity", sourceLocation: sourceLocation)
            #expect(rowMap.allSatisfy(live), "\(context): rowMap live", sourceLocation: sourceLocation)
            // In data source order.
            let indexes = rowMap.map { table.rowHandles.index(of: Int32($0)) }
            #expect(zip(indexes, indexes.dropFirst()).allSatisfy { $0 < $1 }, "\(context): rowMap in data source order",
                    sourceLocation: sourceLocation)
            if !table.isSearchingRows, let matches = table.filterMatches {
                #expect(matches.count == capacity, "\(context): filterMatches", sourceLocation: sourceLocation)
                #expect(Set(matches.indices.filter { matches[$0] && live($0) }) == Set(rowMap), "\(context): filterMatches vs rowMap", sourceLocation: sourceLocation)
            }
        }
        if let order = table.displayOrder, let sorted = table.sortedRows {
            #expect(order.allSatisfy(live), "\(context): order live", sourceLocation: sourceLocation)
            #expect(sorted.allSatisfy(live), "\(context): sorted rows live", sourceLocation: sourceLocation)
            #expect(Set(sorted).count == sorted.count, "\(context): sorted rows distinct", sourceLocation: sourceLocation)
            #expect(table.sortedOrder?.capacity ?? 0 >= capacity, "\(context): sorted rows capacity", sourceLocation: sourceLocation)
            // The shown rows are the sorted rows the filter shows, in their order.
            let shown = table.rowMap == nil ? sorted : sorted.filter { (table.filterMatches ?? []).indices.contains($0) && table.filterMatches![$0] }
            if !table.isSearchingRows {
                #expect(order == shown, "\(context): shown sorted rows", sourceLocation: sourceLocation)
            }
            if !table.isSortingRows {
                #expect(sorted.count == count, "\(context): sortedRows", sourceLocation: sourceLocation)
                #expect(table.sortKeys?.rowCount == capacity, "\(context): sortKeys", sourceLocation: sourceLocation)
                if let keys = table.sortKeys {
                    #expect(zip(sorted, sorted.dropFirst()).allSatisfy { keys.comesBefore($0, $1, order: table.rowHandles) },
                            "\(context): sorted", sourceLocation: sourceLocation)
                }
            }
        }
        if table.summaryTask == nil {
            for (id, values) in table.summarySourceValues {
                #expect(values.count == capacity, "\(context): summarySourceValues \(id)", sourceLocation: sourceLocation)
            }
        }
        if let index = table.searchIndex {
            #expect(index.rowCount == capacity, "\(context): searchIndex", sourceLocation: sourceLocation)
        }
        if let keys = table.groupKeys {
            #expect(keys.ids.allSatisfy { $0.count == capacity }, "\(context): groupKeys", sourceLocation: sourceLocation)
        }
        if let display = table.groupedDisplay {
            #expect(display.enumerated().allSatisfy { $1 < 0 || ($1 < table.displayRowOfSource.count && table.displayRowOfSource[$1] == $0) }, "\(context): grouped inverse",
                    sourceLocation: sourceLocation)
        }
        #expect(table.displaySelection.allSatisfy { $0 < table.numberOfRows && !table.isGroupRow($0) },
                "\(context): selection in display rows", sourceLocation: sourceLocation)
    }

    static func expectSame(_ table: NGTableView, _ feed: Feed, _ configuration: Configuration, _ context: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        func log(_ text: String) { if ProcessInfo.processInfo.environment["NGTABLE_LOG"] != nil { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) } }
        log("invariants"); checkInvariants(table, context, sourceLocation: sourceLocation)
        log("fresh"); let fresh = fresh(like: table, feed, configuration)
        log("snapshot"); let actual = snapshot(table, feed)
        log("snapshot fresh"); let expected = snapshot(fresh, feed)
        log("compare")
        let difference = zip(actual.rows, expected.rows).enumerated().first { $1.0 != $1.1 }?.offset
            ?? min(actual.rows.count, expected.rows.count)
        #expect(actual.rows == expected.rows,
                "\(context): rows differ at \(difference): \(actual.rows.dropFirst(max(0, difference - 2)).prefix(6)) vs \(expected.rows.dropFirst(max(0, difference - 2)).prefix(6))",
                sourceLocation: sourceLocation)
        #expect(actual.totals == expected.totals, "\(context): totals", sourceLocation: sourceLocation)
        #expect(actual.subtotals == expected.subtotals, "\(context): subtotals", sourceLocation: sourceLocation)
        #expect(actual.selection == expected.selection, "\(context): selection", sourceLocation: sourceLocation)
    }

    // MARK: Random updates

    /// One random update: an insert, a remove, a move or changed values.
    static func randomUpdate(_ table: NGTableView, _ feed: Feed) {
        let count = feed.records.count
        switch feed.random(11) {
        case 0, 1:
            // One or a few rows, maybe in two places.
            var indexes = IndexSet()
            for _ in 0..<(1 + feed.random(3)) { indexes.insert(feed.random(count + indexes.count + 1)) }
            for index in indexes { feed.records.insert(feed.makeRecord(), at: index) }
            table.insertRows(at: indexes)
        case 2, 3:
            guard count > 0 else { return }
            var indexes = IndexSet()
            for _ in 0..<(1 + feed.random(3)) { indexes.insert(feed.random(count)) }
            for index in indexes.reversed() { feed.records.remove(at: index) }
            table.removeRows(at: indexes)
        case 4:
            guard count > 1 else { return }
            let (from, to) = (feed.random(count), feed.random(count))
            feed.records.insert(feed.records.remove(at: from), at: to)
            table.moveRow(at: from, to: to)
        case 10:
            // Removed, the last record put in its place (a feed's store).
            guard count > 0 else { return }
            let index = feed.random(count)
            feed.records.swapAt(index, count - 1)
            feed.records.removeLast()
            table.removeRowReplacingWithLast(at: index)
        case 5:
            // Appended at the end.
            let added = 1 + feed.random(3)
            for _ in 0..<added { feed.records.append(feed.makeRecord()) }
            table.noteNumberOfRowsChanged()
        default:
            // Changed values of some rows: the changed columns reported, or all of them.
            guard count > 0 else { return }
            var rows = IndexSet()
            for _ in 0..<(1 + feed.random(4)) { rows.insert(feed.random(count)) }
            let changeable = Array(Feed.changeableColumns).sorted()
            var changed = Set<String>()
            for _ in 0..<(1 + feed.random(3)) { changed.insert(changeable[feed.random(changeable.count)]) }
            for row in rows { feed.change(&feed.records[row], columns: changed) }
            let ids = table.tableColumns.map(\.id)
            var columnIndexes = IndexSet(integersIn: 0..<ids.count)
            if feed.random(2) == 0 {
                // Only the changed ones (the profit average shows the profit too).
                columnIndexes = IndexSet(ids.indices.filter {
                    changed.contains(ids[$0]) || (ids[$0] == "profitAverage" && changed.contains("profit"))
                })
            }
            table.reloadData(forRowIndexes: rows, columnIndexes: columnIndexes)
        }
    }

    /// A batch of random updates, sometimes with a nested batch.
    static func randomBatch(_ table: NGTableView, _ feed: Feed) {
        table.beginUpdates()
        for _ in 0..<(1 + feed.random(12)) {
            if feed.random(8) == 0 {
                table.beginUpdates()
                randomUpdate(table, feed)
                randomUpdate(table, feed)
                table.endUpdates()
            } else {
                randomUpdate(table, feed)
            }
        }
        table.endUpdates()
    }

    static let configurations: [(String, Configuration)] = [
        ("plain", Configuration()),
        ("filtered", Configuration(searchText: "a", condition: true)),
        ("searched by name", Configuration(searchText: "е", searchColumns: ["name", "score"])),
        ("sorted", Configuration(sortsRows: true, sort: [NSSortDescriptor(key: "profit", ascending: false)])),
        ("sorted by two", Configuration(sortsRows: true, sort: [NSSortDescriptor(key: "score", ascending: true),
                                                                NSSortDescriptor(key: "name", ascending: false)])),
        ("filtered and sorted", Configuration(searchText: "a", condition: true, sortsRows: true,
                                              sort: [NSSortDescriptor(key: "spend", ascending: true)])),
        ("grouped", Configuration(grouping: ["status"])),
        ("grouped and sorted", Configuration(sortsRows: true, sort: [NSSortDescriptor(key: "profit", ascending: true)],
                                             grouping: ["status", "score"])),
        ("everything", Configuration(searchText: "a", condition: true, sortsRows: true,
                                     sort: [NSSortDescriptor(key: "name", ascending: true)], grouping: ["status"],
                                     scope: .excludingSelectedRows)),
        ("selected rows", Configuration(condition: true, sortsRows: true, sort: [NSSortDescriptor(key: "profit", ascending: true)],
                                        scope: .selectedRows)),
    ]

    @Test(arguments: 0..<10)
    func liveUpdatesShowWhatAFreshTableShows(_ configurationIndex: Int) async {
        let (name, configuration) = Self.configurations[configurationIndex]
        let feed = Feed(count: 300, seed: UInt64(configurationIndex + 1))
        let table = Self.makeTable(feed, configuration)
        defer { withExtendedLifetime(feed) {} }
        // The selected records: they stay selected while they are shown.
        var selected = Set<Int>()
        func shownIDs() -> Set<Int> {
            Set((0..<table.numberOfRows).map(table.sourceRow).filter { $0 >= 0 }.map { feed.records[$0].id })
        }
        for round in 0..<60 {
            if feed.random(4) == 0 {
                var rows = IndexSet()
                for _ in 0..<feed.random(20) { rows.insert(feed.random(feed.records.count)) }
                table.selectRowIndexes(rows, byExtendingSelection: false)
                selected = Set(rows.map { feed.records[$0].id }).intersection(shownIDs())
            }
            if feed.random(15) == 0, let group = table.topLevelGroups.first {
                table.collapseGroup(group)
                selected.formIntersection(shownIDs())
            }
            if feed.random(10) == 0 {
                Self.randomUpdate(table, feed)
            } else {
                Self.randomBatch(table, feed)
            }
            selected.formIntersection(shownIDs())
            #expect(Set(table.selectedRowIndexes.map { $0 < feed.records.count ? feed.records[$0].id : -1 - $0 }) == selected, "\(name), round \(round): selected records")
            Self.expectSame(table, feed, configuration, "\(name), round \(round)")
            // Other tests' background work gets the main actor too.
            await Task.yield()
        }
        // Everything removed, then rows again.
        let all = IndexSet(integersIn: 0..<feed.records.count)
        feed.records.removeAll()
        table.removeRows(at: all)
        Self.expectSame(table, feed, configuration, "\(name), all removed")
        feed.records = (0..<5).map { _ in feed.makeRecord() }
        table.insertRows(at: IndexSet(integersIn: 0..<5))
        Self.expectSame(table, feed, configuration, "\(name), inserted into an empty table")
    }

    /// The filter, the sort, the grouping, the scope or the whole data
    /// change in the middle of a batch, after some of its updates.
    @Test(arguments: 0..<6)
    func changesInTheMiddleOfABatch(_ seed: Int) async {
        let feed = Feed(count: 250, seed: UInt64(100 + seed))
        var configuration = Self.configurations[seed].1
        let table = Self.makeTable(feed, configuration)
        defer { withExtendedLifetime(feed) {} }
        for round in 0..<50 {
            table.beginUpdates()
            for _ in 0..<(1 + feed.random(6)) { Self.randomUpdate(table, feed) }
            var change = ""
            switch feed.random(8) {
            case 7:
                configuration.hidden = [[], ["score"], ["profitAverage"], ["score", "spend"]][feed.random(4)]
                table.hiddenColumnIDs = configuration.hidden
                change = "hidden \(configuration.hidden.sorted())"
            case 0:
                let other = Self.configurations[feed.random(Self.configurations.count)].1
                (configuration.searchText, configuration.searchColumns, configuration.condition)
                    = (other.searchText, other.searchColumns, other.condition)
                table.rowFilter = configuration.filter(feed)
                change = "filter"
            case 1:
                let other = Self.configurations[feed.random(Self.configurations.count)].1
                (configuration.sortsRows, configuration.sort) = (other.sortsRows || feed.random(2) == 0, other.sort)
                table.sortsRows = configuration.sortsRows
                table.sortDescriptors = configuration.sort
                change = "sort"
            case 2:
                configuration.grouping = [nil, ["status"], ["score", "status"]][feed.random(3)]
                table.rowGrouping = configuration.grouping.map { NGRowGrouping(columnIDs: $0) }
                change = "grouping"
            case 3:
                configuration.scope = NGSummaryScope.allCases[feed.random(3)]
                table.summaryScope = configuration.scope
                change = "scope"
            case 4:
                if feed.random(2) == 0 { feed.records.shuffle(using: &feed.generator) }
                table.reloadData()
                change = "reload"
            default:
                var rows = IndexSet()
                for _ in 0..<feed.random(10) { rows.insert(feed.random(feed.records.count)) }
                table.selectRowIndexes(rows, byExtendingSelection: false)
                change = "selection"
            }
            for _ in 0..<feed.random(6) { Self.randomUpdate(table, feed) }
            table.endUpdates()
            Self.expectSame(table, feed, configuration, "seed \(seed), round \(round), \(change)")
            await Task.yield()
        }
    }

    /// Sort keys and search words of a long feed: a column of numbers that
    /// gets text turns into cell values, and the values and word lists
    /// left behind by changed rows are compacted, in the middle of batches too.
    @Test func longFeedsCompactKeysAndWords() async {
        let feed = Feed(count: 200, seed: 31)
        for row in feed.records.indices { feed.records[row].score = .number(Double(feed.random(50))) }
        let configuration = Configuration(searchText: "a", searchColumns: ["name", "score"], sortsRows: true,
                                          sort: [NSSortDescriptor(key: "score", ascending: false),
                                                 NSSortDescriptor(key: "name", ascending: true)])
        let table = Self.makeTable(feed, configuration)
        defer { withExtendedLifetime(feed) {} }
        #expect(table.sortKeys?.numbers.first.map { $0 != nil } == true)
        for round in 0..<80 {
            table.beginUpdates()
            for _ in 0..<40 {
                let row = feed.random(feed.records.count)
                feed.change(&feed.records[row], columns: feed.random(3) == 0 ? ["score", "name"] : ["score"])
                if round > 20, feed.random(10) == 0 { feed.records[row].score = .number(.nan) }
                table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
            Self.randomUpdate(table, feed)
            table.endUpdates()
            Self.expectSame(table, feed, configuration, "round \(round)")
            await Task.yield()
        }
        #expect(table.sortKeys?.numbers.first.map { $0 == nil } == true)
        // Compacted: at most about twice the rows.
        #expect((table.sortKeys?.cells.first?.values.count ?? 0) <= 2 * max(feed.records.count, 1024) + 1)
    }

    /// Background sorts, first searches and summaries (low limits) under
    /// random batches, some spanning an `await`, and changes of the filter,
    /// the sort and the grouping: once the work is done, the table shows
    /// what a fresh table shows.
    @Test(arguments: 0..<6)
    func backgroundWorkUnderRandomBatches(_ seed: Int) async {
        // These batches span an `await` on purpose.
        NGTableView.reportsBatchesAcrossRunLoopTurns = false
        let feed = Feed(count: 400, seed: UInt64(700 + seed))
        var configuration = Self.configurations[(seed * 3) % Self.configurations.count].1
        let table = Self.makeTable(feed, configuration)
        defer { withExtendedLifetime(feed) {} }
        (table.synchronousSortLimit, table.synchronousSearchLimit, table.synchronousSummaryLimit) = (100, 100, 100)
        table.reloadData()
        for round in 0..<25 {
            for _ in 0..<(1 + feed.random(4)) {
                table.beginUpdates()
                for step in 0..<(1 + feed.random(6)) {
                    Self.randomUpdate(table, feed)
                    if step == 1, feed.random(3) == 0 { await Task.yield() }
                }
                table.endUpdates()
                if feed.random(2) == 0 { await Task.yield() }
            }
            switch feed.random(6) {
            case 0:
                let other = Self.configurations[feed.random(Self.configurations.count)].1
                (configuration.searchText, configuration.searchColumns, configuration.condition)
                    = (other.searchText, other.searchColumns, other.condition)
                table.rowFilter = configuration.filter(feed)
            case 1:
                let other = Self.configurations[feed.random(Self.configurations.count)].1
                (configuration.sortsRows, configuration.sort) = (true, other.sort)
                table.sortsRows = true
                table.sortDescriptors = configuration.sort
            case 2:
                configuration.grouping = [nil, ["status"], ["score", "status"]][feed.random(3)]
                table.rowGrouping = configuration.grouping.map { NGRowGrouping(columnIDs: $0) }
            case 3:
                table.reloadData()
            default:
                break
            }
            if feed.random(3) == 0 {
                for _ in 0..<2_000 where table.isSortingRows || table.isSearchingRows || table.isComputingSummary {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                Self.expectSame(table, feed, configuration, "seed \(seed), round \(round)")
            }
        }
        for _ in 0..<2_000 where table.isSortingRows || table.isSearchingRows || table.isComputingSummary {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(!table.isSortingRows && !table.isSearchingRows && !table.isComputingSummary)
        Self.expectSame(table, feed, configuration, "seed \(seed), done")
    }
}

extension SplitMix64: RandomNumberGenerator {}
#endif
