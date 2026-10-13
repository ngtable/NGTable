#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Finding rows by identity while a feed inserts, removes and moves them,
/// and the selection's identities kept by handle.
@Suite("Row identities")
@MainActor
struct NGRowIdentityTests {
    @MainActor
    final class Records: NGTableViewDataSource {
        var ids = (0..<100).map { "id\($0)" }
        var usesColumn = false
        func numberOfRows(in tableView: NGTableView) -> Int { ids.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text(ids[row]) }
        func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { usesColumn ? nil : ids[row] }
    }

    private func makeTable(_ records: Records) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [.column(NGTableColumn("id", title: "ID", width: 100))]
        table.dataSource = records
        return table
    }

    /// Two rows with one identity: removing the one found finds the other.
    @Test func aDuplicateIdentityOutlivesOneCopy() {
        let records = Records()
        records.ids[10] = "id5"
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let first = table.row(forIdentifier: "id5")
        #expect(first == 5 || first == 10)
        records.ids.remove(at: first)
        table.removeRows(at: [first])
        let other = table.row(forIdentifier: "id5")
        #expect(other >= 0 && records.ids[other] == "id5")
        records.ids.remove(at: other)
        table.removeRows(at: [other])
        #expect(table.row(forIdentifier: "id5") == -1)
    }

    /// With three copies of an identity, each removal of the one found
    /// finds another, at once: lookups don't walk the rows.
    @Test func duplicatedIdentitiesAreFoundWithoutAWalk() {
        var index = NGIdentityIndex()
        let count: Int32 = 200_000
        index.reserve(Int(count))
        for handle in 0..<count { index.set(AnyHashable(handle % 199_998 == 0 ? -1 : Int(handle)), for: handle) }
        // Handles 0, 199,998 and the last two copies: identity -1 at 0 and 199,998.
        index.set(AnyHashable(-1), for: count - 1)
        var found: [Int32] = []
        let start = ContinuousClock.now
        for _ in 0..<2 {
            guard let handle = index.handle(of: AnyHashable(-1)) else { break }
            found.append(handle)
            index.remove(handle)
            for _ in 0..<1_000 { _ = index.handle(of: AnyHashable(-1)) }
        }
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(Set(found).count == 2)
        #expect(index.handle(of: AnyHashable(-1)) != nil)
        index.remove(index.handle(of: AnyHashable(-1))!)
        #expect(index.handle(of: AnyHashable(-1)) == nil)
    }

    @Test func rowsByIdentityFollowUpdates() {
        let records = Records()
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        #expect(table.row(forIdentifier: "id42") == 42)
        #expect(table.row(forIdentifier: "nope") == -1)
        #expect(table.identifier(forRow: 7) == AnyHashable("id7"))
        // Inserted above, removed, moved: lookups follow, new rows are found.
        table.beginUpdates()
        records.ids.insert(contentsOf: ["new0", "new1"], at: 0)
        table.insertRows(at: [0, 1])
        records.ids.remove(at: 12)          // "id10"
        table.removeRows(at: [12])
        records.ids.insert(records.ids.remove(at: 50), at: 3)   // "id49" to 3
        table.moveRow(at: 50, to: 3)
        table.endUpdates()
        #expect(table.row(forIdentifier: "new1") == 1)
        #expect(table.row(forIdentifier: "id10") == -1)
        #expect(table.row(forIdentifier: "id49") == 3)
        #expect(table.row(forIdentifier: "id42") == 44)
        for (row, id) in records.ids.enumerated() { #expect(table.row(forIdentifier: id) == row) }
        // A full reload reads them again.
        records.ids.reverse()
        table.reloadData()
        #expect(table.row(forIdentifier: "id99") == 0)
        // Identities from a column.
        records.usesColumn = true
        table.rowIdentifierColumnID = "id"
        #expect(table.row(forIdentifier: NGCellValue.text("id99")) == 0)
    }

    /// The selection's identities by handle: a removed record's identity
    /// isn't selected again when a record with its handle comes.
    @Test func selectionIdentitiesByHandle() {
        let records = Records()
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.selectRowIndexes([5, 6], byExtendingSelection: false)
        records.ids.remove(at: 5)
        table.removeRows(at: [5])
        records.ids.insert("fresh", at: 0)
        table.insertRows(at: [0])           // May reuse the removed row's handle.
        #expect(table.selectedRowIndexes == [6])
        records.ids.shuffle()
        table.reloadData()
        #expect(table.selectedRowIndexes == [records.ids.firstIndex(of: "id6")!])
    }
}
#endif
