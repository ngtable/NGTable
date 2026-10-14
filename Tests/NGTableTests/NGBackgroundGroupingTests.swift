#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Grouping large tables in the background (`synchronousGroupingLimit`):
/// the keys read in slices, the previous grouping shown meanwhile, changes
/// meanwhile read again, and the result that of grouping at once.
@MainActor
@Suite("Background grouping")
struct NGBackgroundGroupingTests {
    final class Records: NGTableViewDataSource {
        var ids: [Int]
        var networks: [String]
        var countries: [String]
        var nextID: Int
        /// How often each column's values were read.
        var reads: [String: Int] = [:]

        init(count: Int) {
            ids = Array(0..<count)
            networks = (0..<count).map { ["MGID", "Taboola", "Outbrain", "Geozo", "Adskeeper"][($0 * 7) % 5] }
            countries = (0..<count).map { ["DE", "FR", "IT"][($0 * 11) % 3] }
            nextID = count
        }

        func numberOfRows(in tableView: NGTableView) -> Int { ids.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            reads[column.id, default: 0] += 1
            switch column.id {
            case "net": return .text(networks[row])
            case "country": return .text(countries[row])
            default: return .text("Record \(ids[row])")
            }
        }
        func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { ids[row] }

        func insert(at row: Int) {
            ids.insert(nextID, at: row)
            networks.insert(["MGID", "New"][nextID % 2], at: row)
            countries.insert("ES", at: row)
            nextID += 1
        }
        func remove(at row: Int) {
            ids.remove(at: row)
            networks.remove(at: row)
            countries.remove(at: row)
        }
    }

    func makeTable(_ records: Records, limit: Int = 100) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                         .column(NGTableColumn("net", title: "Network", width: 100)),
                         .column(NGTableColumn("country", title: "Country", width: 80))]
        table.synchronousGroupingLimit = limit
        table.dataSource = records
        table.layoutSubtreeIfNeeded()
        return table
    }

    /// What a table shows: group headers by their path, rows by record id.
    func shown(_ table: NGTableView, _ records: Records) -> [String] {
        (0..<table.numberOfRows).map { displayRow in
            if let node = table.groupNode(atDisplayRow: displayRow) {
                return "# " + table.groupTree.nodes[node].group.path.joined(separator: "/")
            }
            return "\(records.ids[table.sourceRow(displayRow)])"
        }
    }

    /// What a table grouping at once shows for the same records.
    func expected(_ records: Records, _ columnIDs: [String]) -> [String] {
        let fresh = makeTable(records, limit: .max)
        fresh.rowGrouping = NGRowGrouping(columnIDs: columnIDs)
        return shown(fresh, records)
    }

    @Test func largeTablesGroupInTheBackground() async throws {
        let records = Records(count: 2_000)
        let table = makeTable(records)
        table.rowGrouping = NGRowGrouping(columnIDs: ["net"])
        // Meanwhile the rows show as they were.
        #expect(table.isGroupingRows)
        #expect(table.groupedDisplay == nil && table.numberOfRows == 2_000)
        #expect(try await waitWhile { table.isGroupingRows })
        #expect(table.topLevelGroups.count == 5)
        #expect(shown(table, records) == expected(records, ["net"]))
        // Small tables group at once.
        let few = Records(count: 50)
        let small = makeTable(few)
        small.rowGrouping = NGRowGrouping(columnIDs: ["net"])
        #expect(!small.isGroupingRows && small.topLevelGroups.count == 5)
    }

    /// A level more: the groups shown stay meanwhile, and only the new
    /// column is read (the other's keys are kept).
    @Test func anotherLevelKeepsTheGroupsShownMeanwhile() async throws {
        let records = Records(count: 2_000)
        let table = makeTable(records, limit: .max)
        table.rowGrouping = NGRowGrouping(columnIDs: ["net"])
        let byNetwork = shown(table, records)
        table.synchronousGroupingLimit = 100
        records.reads = [:]
        table.rowGrouping = NGRowGrouping(columnIDs: ["net", "country"])
        #expect(table.isGroupingRows)
        // Only the new column is read. (Not counted by reads: other tests
        // tell every table the locale changed, which reads all keys again.)
        #expect(table.groupingJob?.keys.columnIDs == ["country"])
        #expect(shown(table, records) == byNetwork)
        #expect(try await waitWhile { table.isGroupingRows })
        #expect(records.reads["country", default: 0] >= 2_000)
        #expect(shown(table, records) == expected(records, ["net", "country"]))
    }

    /// Grouping at once keeps the keys of the columns grouped by too.
    @Test func keysOfColumnsGroupedByAreKept() {
        let records = Records(count: 500)
        let table = makeTable(records, limit: .max)
        table.rowGrouping = NGRowGrouping(columnIDs: ["net"])
        records.reads = [:]
        table.rowGrouping = NGRowGrouping(columnIDs: ["net", "country"])
        #expect(records.reads["net", default: 0] < 100)
        #expect(shown(table, records) == expected(records, ["net", "country"]))
    }

    /// Values changed, rows inserted and removed while the keys are read:
    /// the grouping is the one of the data as it is then.
    @Test func changesMeanwhileAreReadAgain() async throws {
        // Too many to read in one slice.
        let records = Records(count: 300_000)
        let table = makeTable(records)
        table.rowGrouping = NGRowGrouping(columnIDs: ["country"])
        // Some keys read, not all.
        #expect(try await waitWhile { (table.groupingJob?.firstUnread ?? 0) == 0 && table.isGroupingRows })
        #expect(table.isGroupingRows)
        let read = try #require(table.groupingJob?.firstUnread)
        // A row already read gets another country, one not read yet too.
        records.countries[1] = "PL"
        records.countries[299_999] = "PL"
        table.reloadData(forRowIndexes: [1, 299_999], columnIndexes: [2])
        table.beginUpdates()
        records.insert(at: 0)
        table.insertRows(at: [0])
        records.remove(at: 10)
        table.removeRows(at: [10])
        table.endUpdates()
        #expect(read < 300_000)
        #expect(try await waitWhile { table.isGroupingRows })
        #expect(table.topLevelGroups.map(\.key).contains("PL"))
        #expect(shown(table, records) == expected(records, ["country"]))
    }

    @Test func aReloadMeanwhileStartsOver() async throws {
        let records = Records(count: 300_000)
        let table = makeTable(records)
        table.rowGrouping = NGRowGrouping(columnIDs: ["net"])
        // Some keys read, not all: those are read again.
        #expect(try await waitWhile { (table.groupingJob?.firstUnread ?? 0) == 0 && table.isGroupingRows })
        #expect(table.isGroupingRows)
        records.networks = records.networks.map { $0 == "MGID" ? "Other" : $0 }
        table.reloadData()
        #expect(try await waitWhile { table.isGroupingRows })
        #expect(!table.topLevelGroups.map(\.key).contains("MGID"))
        #expect(shown(table, records) == expected(records, ["net"]))
    }

    /// Another grouping, or none, while the keys are read.
    @Test func anotherGroupingMeanwhile() async throws {
        let records = Records(count: 2_000)
        let table = makeTable(records)
        table.rowGrouping = NGRowGrouping(columnIDs: ["net"])
        table.rowGrouping = NGRowGrouping(columnIDs: ["country"])
        #expect(table.isGroupingRows)
        #expect(try await waitWhile { table.isGroupingRows })
        #expect(shown(table, records) == expected(records, ["country"]))
        table.rowGrouping = NGRowGrouping(columnIDs: ["net"])
        #expect(table.isGroupingRows)
        table.rowGrouping = nil
        #expect(!table.isGroupingRows)
        try await Task.sleep(for: .milliseconds(50))
        #expect(table.groupedDisplay == nil && table.numberOfRows == 2_000)
    }
}
#endif
