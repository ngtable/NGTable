#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// A data source written for an NSTableView, as an app has it today.
@MainActor
private final class LegacyPeople: NSObject, NSTableViewDataSource {
    struct Person { var name: String; var age: Int; var isActive: Bool; var joined: Date? }
    var people: [Person] = [
        Person(name: "Mei", age: 34, isActive: true, joined: Date(timeIntervalSince1970: 0)),
        Person(name: "Juan", age: 28, isActive: false, joined: nil),
        Person(name: "Gita", age: 41, isActive: true, joined: nil),
    ]

    func numberOfRows(in tableView: NSTableView) -> Int { people.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let person = people[row]
        switch tableColumn?.identifier.rawValue {
        case "name": return person.name
        case "age": return person.age
        case "active": return person.isActive
        case "joined": return person.joined
        default: return nil
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sort = tableView.sortDescriptors.first else { return }
        people.sort { lhs, rhs in
            let ordered = sort.key == "age" ? lhs.age < rhs.age : lhs.name < rhs.name
            return sort.ascending ? ordered : !ordered
        }
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        switch tableColumn?.identifier.rawValue {
        case "name": people[row].name = object as? String ?? ""
        case "age": people[row].age = (object as? NSNumber)?.intValue ?? 0
        default: break
        }
    }

    var dropped: [Int] = []
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        people[row].name as NSString
    }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        row == 0 ? [] : .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        dropped.append(row)
        return true
    }

    var sessions: [String] = []
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        sessions.append("began \(Array(rowIndexes))")
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        sessions.append("ended \(operation.rawValue)")
    }

    /// Like an app's "Add" button: the model changes, then the table is told.
    func add(_ person: Person, to tableView: NSTableView) {
        people.insert(person, at: 0)
        tableView.insertRows(at: [0], withAnimation: .slideDown)
    }
}

/// A data source from before pasteboard writers: it writes all the rows
/// dragged at once (the deprecated `tableView(_:writeRowsWith:to:)`).
@MainActor
private final class OldDragger: NSObject, NSTableViewDataSource {
    let names = ["Mei", "Juan", "Gita", "Ana"]
    var written: [[Int]] = []
    func numberOfRows(in tableView: NSTableView) -> Int { names.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { names[row] }
    func tableView(_ tableView: NSTableView, writeRowsWith rows: IndexSet, to pasteboard: NSPasteboard) -> Bool {
        written.append(Array(rows))
        pasteboard.declareTypes([.string], owner: nil)
        return pasteboard.setString(rows.map { names[$0] }.joined(separator: ","), forType: .string)
    }
}

@Suite("NSTableViewDataSource adapter")
@MainActor
struct NGLegacyDataSourceTests {
    private func makeTable() -> (NGTableView, NGTableViewDataSourceAdapter, LegacyPeople) {
        let legacy = LegacyPeople()
        let adapter = NGTableViewDataSourceAdapter(legacy)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("name", title: "Name")),
            .column(NGTableColumn("age", title: "Age", format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
            .column(NGTableColumn("active", title: "Active")),
            .column(NGTableColumn("joined", title: "Joined", format: .date(includesTime: false))),
        ]
        table.dataSource = adapter
        table.layoutSubtreeIfNeeded()
        return (table, adapter, legacy)
    }

    /// Edits reach `setObjectValue` as object values, and drags its pasteboard writer.
    @Test func editsAndDragsGoToTheLegacyDataSource() throws {
        let (table, adapter, legacy) = makeTable()
        defer { withExtendedLifetime((adapter, legacy)) {} }
        table.setValue(.text("Mia"), row: 0, column: table.tableColumns[0], undoValue: .text("Mei"))
        table.setValue(.number(35), row: 0, column: table.tableColumns[1], undoValue: .number(34))
        #expect(legacy.people[0].name == "Mia" && legacy.people[0].age == 35)
        #expect(table.dataSource?.tableView(table, valueFor: table.tableColumns[0], row: 0) == .text("Mia"))
        let writer = try #require(adapter.tableView(table, pasteboardWriterForRow: 1) as? NSString)
        #expect(writer == "Juan")
        // Dragging sessions too.
        let session = NSDraggingSession()
        table.noteDraggedRows([1])
        table.draggingSession(session, willBeginAt: .zero)
        table.draggingSession(session, endedAt: .zero, operation: .delete)
        #expect(legacy.sessions == ["began [1]", "ended \(NSDragOperation.delete.rawValue)"])
        #expect(NGTableViewDataSourceAdapter.objectValue(of: .bool(true)) as? NSNumber == NSNumber(value: true))
        #expect(NGTableViewDataSourceAdapter.objectValue(of: .empty) == nil)
    }

    /// Rows of a data source that writes them at once drag as one item
    /// with all of them, as with an NSTableView.
    @Test func rowsWrittenAtOnceDragTogether() throws {
        let old = OldDragger()
        let adapter = NGTableViewDataSourceAdapter(old)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [.column(NGTableColumn("name", title: "Name"))]
        table.dataSource = adapter
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((old, adapter)) {} }
        #expect(table.canDragRow(displayRow: 1))
        let items = table.draggingItems(forRows: [1, 3], dataSource: adapter)
        #expect(items.count == 1)
        let item = try #require(items.first?.item as? NSPasteboardItem)
        #expect(item.string(forType: .string) == "Juan,Ana")
        #expect(old.written.last == [1, 3])
    }

    @Test func objectValuesBecomeCellValues() {
        #expect(NGTableViewDataSourceAdapter.value(from: "Mei") == .text("Mei"))
        #expect(NGTableViewDataSourceAdapter.value(from: 34) == .number(34))
        #expect(NGTableViewDataSourceAdapter.value(from: 2.5) == .number(2.5))
        #expect(NGTableViewDataSourceAdapter.value(from: true) == .bool(true))
        #expect(NGTableViewDataSourceAdapter.value(from: NSNumber(value: 1)) == .number(1))
        #expect(NGTableViewDataSourceAdapter.value(from: nil) == .empty)
        #expect(NGTableViewDataSourceAdapter.value(from: NSNull()) == .empty)
        #expect(NGTableViewDataSourceAdapter.value(from: NSAttributedString(string: "Bold")) == .text("Bold"))
        #expect(NGTableViewDataSourceAdapter.value(from: Date(timeIntervalSince1970: 0)) == .date(Date(timeIntervalSince1970: 0)))
        #expect(NGTableViewDataSourceAdapter.value(from: NGCellValue.tags([NGTag("A")])) == .tags([NGTag("A")]))
        #expect(NGTableViewDataSourceAdapter.value(from: URL(string: "https://a.b")) == .text("https://a.b"))
    }

    @Test func aLegacyDataSourceFeedsTheTable() {
        let (table, adapter, legacy) = makeTable()
        #expect(table.numberOfRows == 3)
        #expect(table.summaryValue(forColumnID: "age") == 103)
        let column = NGTableColumn("active", title: "Active")
        #expect(adapter.tableView(table, valueFor: column, row: 0) == .bool(true))
        // The stand-in has the table's columns, by identifier.
        #expect(adapter.tableViewStandIn.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("age")) != nil)
        withExtendedLifetime(legacy) {}
    }

    /// The legacy data source sorts by the stand-in's sort descriptors and
    /// reloads it; the table follows.
    @Test func sortingAndReloadingGoThroughTheStandIn() {
        let (table, adapter, legacy) = makeTable()
        table.sortByClicking(NGTableColumn("age", title: "Age"))
        #expect(legacy.people.map(\.name) == ["Juan", "Mei", "Gita"])
        #expect(adapter.tableView(table, valueFor: NGTableColumn("name", title: "Name"), row: 0) == .text("Juan"))
        // The data source setting the sort sets the table's.
        adapter.tableViewStandIn.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        #expect(table.sortDescriptors.first?.key == "name")
        #expect(legacy.people.map(\.name) == ["Gita", "Juan", "Mei"])
        withExtendedLifetime(legacy) {}
    }

    /// Targeted updates and the selection the data source reads go to the table.
    @Test func updatesAndSelectionGoThroughTheStandIn() {
        let (table, adapter, legacy) = makeTable()
        table.selectRowIndexes([1], byExtendingSelection: false)
        let standIn = adapter.tableViewStandIn
        #expect(standIn.selectedRowIndexes == [1])
        #expect(standIn.numberOfRows == 3)
        legacy.add(.init(name: "Tom", age: 20, isActive: true, joined: nil), to: standIn)
        #expect(table.numberOfRows == 4)
        #expect(table.summaryValue(forColumnID: "age") == 123)
        // The selection followed its row.
        #expect(table.selectedRowIndexes == [2])
        #expect(standIn.selectedRow == 2)
        withExtendedLifetime(legacy) {}
    }
}
#endif
