#if os(macOS)
import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import NGTable

/// The SwiftUI table: values, updates by identity, selection and sort bindings.
@Suite("SwiftUI table")
@MainActor
struct NGDataTableTests {
    struct Campaign: Identifiable, Equatable {
        var id: Int
        var name: String
        var spend: Double
        var note: String?
    }

    /// State the bindings read and write.
    final class State {
        var selection: Set<Int> = []
        var sortOrder: [KeyPathComparator<Campaign>] = []
        var opened: Set<Int> = []
    }

    private func makeView(_ rows: [Campaign], state: State, sorted: Bool) -> NGDataTable<Campaign> {
        let selection = Binding(get: { state.selection }, set: { state.selection = $0 })
        let sortOrder = Binding(get: { state.sortOrder }, set: { state.sortOrder = $0 })
        return NGDataTable(rows, selection: selection, sortOrder: sorted ? sortOrder : nil) {
            NGDataColumn("Name", value: \.name)
            NGDataColumn("Spend", value: \.spend, format: .number(fractionDigits: 0), summary: .aggregate(.sum))
            NGDataColumn("Note", value: \.note)
        }
        .rowContextMenu { ids in Text("\(ids.count)") } primaryAction: { state.opened = $0 }
    }

    private func host(_ view: NGDataTable<Campaign>) -> (NSHostingView<NGDataTable<Campaign>>, NSWindow, NGTableView) {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NGTableView? {
            if let table = view as? NGTableView { return table }
            return view.subviews.lazy.compactMap(find).first
        }
        return (hosting, window, find(hosting)!)
    }

    private func names(_ table: NGTableView) -> [String] {
        (0..<table.numberOfRows).map { row in
            if case .text(let name) = table.dataSource!.tableView(table, valueFor: table.tableColumns[0], row: table.sourceRow(row)) { return name }
            return "?"
        }
    }

    /// A selection set for a row that isn't there yet (it's loading) is
    /// applied when the row arrives, and the binding keeps it meanwhile.
    @Test func aSelectionWaitsForItsRow() {
        let state = State()
        var rows = [Campaign(id: 1, name: "B", spend: 20), Campaign(id: 2, name: "A", spend: 10)]
        state.selection = [2, 3]
        let (hosting, window, table) = host(makeView(rows, state: state, sorted: false))
        defer { withExtendedLifetime(window) {} }
        #expect(table.selectedRowIndexes == [1])
        rows.append(Campaign(id: 3, name: "C", spend: 5))
        hosting.rootView = makeView(rows, state: state, sorted: false)
        hosting.layoutSubtreeIfNeeded()
        #expect(table.selectedRowIndexes == [1, 2])
        #expect(state.selection == [2, 3])
    }

    @Test func valuesUpdatesAndSelection() throws {
        let state = State()
        var rows = [Campaign(id: 1, name: "B", spend: 20), Campaign(id: 2, name: "A", spend: 10, note: "x")]
        let (hosting, window, table) = host(makeView(rows, state: state, sorted: false))
        defer { withExtendedLifetime(window) {} }
        #expect(table.bounds.width == 500 && table.bounds.height > 200)   // SwiftUI gives it the room.
        #expect(table.tableColumns.map(\.title) == ["Name", "Spend", "Note"])
        #expect(table.tableColumns[0].id == "\\Campaign.name")
        #expect(table.sortsRows)   // No sort binding: the table sorts.
        #expect(names(table) == ["B", "A"])
        #expect(table.summaryValue(forColumnID: "\\Campaign.spend") == 30)
        // Selection from the binding, and back.
        state.selection = [2]
        hosting.rootView = makeView(rows, state: state, sorted: false)
        hosting.layoutSubtreeIfNeeded()
        #expect(table.selectedRowIndexes == [1])
        table.selectRowIndexes([0], byExtendingSelection: false)
        #expect(state.selection == [1])
        // A value changed, a row inserted, one moved: by identity.
        rows[1].spend = 15
        rows.insert(Campaign(id: 3, name: "C", spend: 5), at: 0)
        rows.swapAt(1, 2)
        hosting.rootView = makeView(rows, state: state, sorted: false)
        hosting.layoutSubtreeIfNeeded()
        #expect(names(table) == ["C", "A", "B"])
        #expect(table.summaryValue(forColumnID: "\\Campaign.spend") == 40)
        #expect(state.selection == [1])                       // Still campaign 1, now row 2.
        #expect(table.selectedRowIndexes == [2])
        // Removed.
        rows.removeAll { $0.id == 3 }
        hosting.rootView = makeView(rows, state: state, sorted: false)
        hosting.layoutSubtreeIfNeeded()
        #expect(names(table) == ["A", "B"])
        // The table sorts by a header click.
        table.sortDescriptors = [NSSortDescriptor(key: "\\Campaign.spend", ascending: false)]
        #expect(names(table) == ["B", "A"])
        // The context menu: SwiftUI content for the rows it is for.
        let menu = table.delegate?.tableView(table, menuForRows: [0, 1], clickedRow: 0, column: nil)
        #expect(menu != nil)
        // A double click: the primary action for the clicked rows.
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.clickedRow = table.selectedRow
        _ = table.target?.perform(table.doubleAction, with: table)
        #expect(state.opened == [2])
        // Below the rows: nothing.
        state.opened = []
        table.clickedRow = -1
        _ = table.target?.perform(table.doubleAction, with: table)
        #expect(state.opened.isEmpty)
        // Return: the selected rows (another one than any click left).
        state.opened = []
        table.selectRowIndexes([1], byExtendingSelection: false)
        let selectedID = try #require(table.identifier(forRow: 1) as? Int)
        table.insertNewline(nil)
        #expect(state.opened == [selectedID])
        #expect(table.clickedRow == -1)
    }

    /// The SwiftUI environment reaches the table, as it reaches a `Table`'s
    /// cells: the locale formats values (cells, summary, VoiceOver), the
    /// layout direction mirrors it, and `.disabled` turns it off.
    @Test func theEnvironmentReachesTheTable() throws {
        struct Wrapper: View {
            let table: NGDataTable<Campaign>
            var locale: Locale
            var direction: LayoutDirection
            var enabled: Bool
            var body: some View {
                table.environment(\.locale, locale).environment(\.layoutDirection, direction).disabled(!enabled)
            }
        }
        let rows = [Campaign(id: 1, name: "B", spend: 1234.5), Campaign(id: 2, name: "A", spend: 10)]
        let view = NGDataTable(rows) {
            NGDataColumn("Name", value: \.name)
            NGDataColumn("Spend", value: \.spend, format: .number(fractionDigits: 2), summary: .aggregate(.sum))
        }
        let hosting = NSHostingView(rootView: Wrapper(table: view, locale: Locale(identifier: "de_DE"), direction: .leftToRight, enabled: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(window) {} }
        func find(_ view: NSView) -> NGTableView? {
            if let table = view as? NGTableView { return table }
            return view.subviews.lazy.compactMap(find).first
        }
        let table = try #require(find(hosting))
        let spend = try #require(table.tableColumns.last)
        let row = try #require(table.displayRow(forSourceRow: 0))
        #expect(table.locale?.identifier == "de_DE")
        #expect(table.accessibilityText(row: row, column: spend) == "1.234,50")
        #expect(table.summaryText(forColumnID: spend.id) == "1.244,50")
        let cell = try #require(table.visibleCells.first { $0.key.row == row && $0.value.content.alignment == .right }?.value)
        if case .number(let number, _) = cell.content { #expect(number.text == "1.234,50") } else { Issue.record("not a number cell") }
        // Another locale: formatted again.
        hosting.rootView = Wrapper(table: view, locale: Locale(identifier: "en_US"), direction: .rightToLeft, enabled: false)
        hosting.layoutSubtreeIfNeeded()
        #expect(table.accessibilityText(row: row, column: spend) == "1,234.50")
        #expect(table.userInterfaceLayoutDirection == .rightToLeft)
        // Disabled: no clicks, no keys.
        #expect(!table.isEnabled && table.ignoresUserInput)
        table.selectRowIndexes([], byExtendingSelection: false)
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        table.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, characters: down,
                                             charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125)!)
        #expect(table.selectedRowIndexes.isEmpty)
        hosting.rootView = Wrapper(table: view, locale: Locale(identifier: "en_US"), direction: .leftToRight, enabled: true)
        hosting.layoutSubtreeIfNeeded()
        #expect(table.isEnabled && !table.ignoresUserInput)
    }

    /// Column customization like a `Table`'s: columns say how
    /// (`customizationID`, `defaultVisibility`, `disabledCustomizationBehavior`);
    /// with SwiftUI's `TableColumnCustomization` visibility goes both ways
    /// (`customization[visibility:]`, the header menu); `NGColumnCustomization`
    /// keeps the order, widths and pins too.
    @Test func columnCustomization() throws {
        final class Box {
            var swiftUI = TableColumnCustomization<Campaign>()
            var ng = NGColumnCustomization()
        }
        let box = Box()
        let rows = [Campaign(id: 1, name: "B", spend: 20, note: "x")]
        func makeView() -> NGDataTable<Campaign> {
            NGDataTable(rows, columnCustomization: Binding(get: { box.swiftUI }, set: { box.swiftUI = $0 })) {
                NGDataColumn("Name", value: \.name).customizationID("name").disabledCustomizationBehavior([.visibility, .reorder])
                NGDataColumn("Spend", value: \.spend).customizationID("spend")
                NGDataColumn("Note", value: \.note).customizationID("note").defaultVisibility(.hidden)
            }
            .columnCustomization(Binding(get: { box.ng }, set: { box.ng = $0 }))
        }
        let hosting = NSHostingView(rootView: makeView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(window) {} }
        func find(_ view: NSView) -> NGTableView? {
            if let table = view as? NGTableView { return table }
            return view.subviews.lazy.compactMap(find).first
        }
        let table = try #require(find(hosting))
        func update() {
            hosting.rootView = makeView()
            hosting.layoutSubtreeIfNeeded()
        }
        #expect(table.tableColumns.map(\.id) == ["name", "spend", "note"])
        #expect(table.hiddenColumnIDs == ["note"])
        let name = try #require(table.tableColumns.first)
        #expect(!name.isHideable && !name.isMovable && name.isResizable)
        // From the customization: hidden.
        box.swiftUI[visibility: "spend"] = .hidden
        update()
        #expect(table.hiddenColumnIDs == ["note", "spend"])
        // The user shows a column from the header menu: both hear of it.
        let menu = try #require(table.makeColumnVisibilityMenu())
        let note = try #require(menu.items.first { $0.representedObject as? String == "note" })
        NSApp.sendAction(try #require(note.action), to: note.target, from: note)
        #expect(table.hiddenColumnIDs == ["spend"])
        #expect(box.swiftUI[visibility: "note"] == .visible)
        #expect(box.ng[visibility: "note"] == .visible && box.ng[visibility: "spend"] == .hidden)
        // The user resizes a column and pins one: the NG customization keeps them.
        let header = table.headerView
        let edge = header.convert(NSPoint(x: table.rect(ofColumn: 0).maxX - 1, y: header.bounds.midY), to: nil)
        for (type, dx) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseDragged, 40), (.leftMouseUp, 40)] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: edge.x + dx, y: edge.y), modifierFlags: [],
                                                        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: table.headerMouseDown(event, in: header)
            case .leftMouseDragged: table.headerMouseDragged(event)
            default: table.headerMouseUp(event)
            }
        }
        let width = try #require(table.width(ofColumnID: "name"))
        #expect(box.ng.widths["name"] == width)
        table.setPin(.leading, forItemID: "note")
        #expect(box.ng.pins["note"] == .leading)
        // A new window with the saved customization: the same columns.
        let saved = box.ng
        box.ng = NGColumnCustomization()
        box.swiftUI = TableColumnCustomization()
        update()
        #expect(table.hiddenColumnIDs == ["note"])   // Back to the defaults.
        box.ng = saved
        update()
        #expect(table.hiddenColumnIDs == ["spend"])
        #expect(table.width(ofColumnID: "name") == width)
        #expect(table.columns.first { $0.id == "note" }?.pin == .leading)
        // It goes through scene storage as text.
        #expect(NGColumnCustomization(rawValue: saved.rawValue) == saved)
    }

    /// Rows the user deletes, moves and drops on, like `onDelete`, `onMove`
    /// and `dropDestination(for:)` on a `Table`'s rows: offsets in the
    /// array, as `remove(atOffsets:)` and `move(fromOffsets:toOffset:)` take
    /// them, and dropped `Transferable` values with where they go.
    @Test func deletingMovingAndDroppingRows() async throws {
        final class Log {
            var deleted: [IndexSet] = []
            var moved: [(IndexSet, Int)] = []
            var dropped: [([String], Int)] = []
        }
        let log = Log()
        let rows = (1...10).map { Campaign(id: $0, name: "C\($0)", spend: Double($0)) }
        let view = NGDataTable(rows) {
            NGDataColumn("Name", value: \.name)
        }
        .onDelete { log.deleted.append($0) }
        .onMove { log.moved.append(($0, $1)) }
        .dropDestination(for: String.self, contentTypes: [.plainText]) { items, index in log.dropped.append((items, index)) }
        let (_, window, table) = host(view)
        defer { withExtendedLifetime(window) {} }
        // Delete: the selected rows (also from Edit > Delete).
        table.selectRowIndexes([1, 4], byExtendingSelection: false)
        table.deleteBackward(nil)
        #expect(log.deleted == [[1, 4]])
        let item = NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        #expect(table.validateMenuItem(item))
        table.selectRowIndexes([], byExtendingSelection: false)
        #expect(!table.validateMenuItem(item))
        // Move: rows dragged within the table go between rows.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NGTableTests.drag"))
        pasteboard.clearContents()
        let writer = try #require(table.dataSource?.tableView(table, pasteboardWriterForRow: 0))
        pasteboard.writeObjects([writer])
        table.noteDraggedRows([0, 2])
        let point = table.centerRegion.canvas.convert(NSPoint(x: 50, y: 5 * table.rowHeight + 1), to: nil)
        let move = NGRowDraggingTests.Drag(location: point, source: table)
        #expect(table.draggingUpdated(move) == .move)
        #expect(table.performDragOperation(move))
        #expect(log.moved.count == 1 && log.moved.first?.0 == [0, 2] && log.moved.first?.1 == 5)
        // Drop: text from elsewhere, decoded as the type asks.
        pasteboard.clearContents()
        pasteboard.setString("Hello", forType: .string)
        let drop = NGRowDraggingTests.Drag(location: point, source: nil)
        #expect(table.draggingUpdated(drop) == .copy)
        #expect(table.performDragOperation(drop))
        // (Decoded in the background: a busy suite may take long to come back.)
        try await eventually { !log.dropped.isEmpty }
        #expect(log.dropped.first?.0 == ["Hello"] && log.dropped.first?.1 == 5)
        #expect(table.registeredDraggedTypes.contains(NSPasteboard.PasteboardType(UTType.plainText.identifier)))
        // From macOS 15.2 the type tells the content types it takes.
        if #available(macOS 15.2, *) {
            let (_, other, otherTable) = host(NGDataTable(rows) { NGDataColumn("Name", value: \.name) }
                .dropDestination(for: String.self) { _, _ in })
            defer { withExtendedLifetime(other) {} }
            #expect(otherTable.registeredDraggedTypes.contains(.string))
        }
    }

    struct Node: Identifiable, Equatable {
        var id: String
        var spend: Double
        var children: [Node]?
    }

    /// Rows with children, like `Table(_:children:)`: shown as a tree,
    /// collapsed at first like a `Table`'s; `expandedRows` tells and sets
    /// which are open (`DisclosureTableRow(isExpanded:)`); a row moved to
    /// another parent goes there.
    @Test func rowsWithChildren() throws {
        final class Box { var expanded: Set<String> = [] }
        let box = Box()
        var roots = [Node(id: "A", spend: 3, children: [Node(id: "A1", spend: 1), Node(id: "A2", spend: 2, children: [Node(id: "A2a", spend: 2)])]),
                     Node(id: "B", spend: 5, children: [])]
        func makeView() -> NGDataTable<Node> {
            NGDataTable(roots, children: \.children) {
                NGDataColumn("ID", value: \.id)
                NGDataColumn("Spend", value: \.spend, summary: .aggregate(.sum))
            }
            .expandedRows(Binding(get: { box.expanded }, set: { box.expanded = $0 }))
        }
        let hosting = NSHostingView(rootView: makeView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(window) {} }
        func find(_ view: NSView) -> NGTableView? {
            if let table = view as? NGTableView { return table }
            return view.subviews.lazy.compactMap(find).first
        }
        let table = try #require(find(hosting))
        func update() {
            hosting.rootView = makeView()
            hosting.layoutSubtreeIfNeeded()
        }
        func shown() -> [String] {
            (0..<table.numberOfRows).map { display in
                let row = table.sourceRow(display)
                return String(repeating: "  ", count: max(0, table.level(forRow: row))) + (table.identifier(forRow: row) as? String ?? "?")
            }
        }
        #expect(table.rowTree != nil)
        #expect(shown() == ["A", "B"])
        #expect(table.isRowExpandable(0) && !table.isRowExpandable(table.row(forIdentifier: "B")))
        // The user opens A: the binding hears of it.
        table.expandRow(0)
        #expect(shown() == ["A", "  A1", "  A2", "B"])
        #expect(box.expanded == ["A"])
        // The binding opens A2.
        box.expanded = ["A", "A2"]
        update()
        #expect(shown() == ["A", "  A1", "  A2", "    A2a", "B"])
        // A1 moves under B, its values the same.
        let a1 = roots[0].children!.removeFirst()
        roots[1].children = [a1]
        box.expanded = ["A", "A2", "B"]
        update()
        #expect(shown() == ["A", "  A2", "    A2a", "B", "  A1"])
        // The table sorts siblings by a header click.
        table.sortDescriptors = [NSSortDescriptor(key: "\\Node.id", ascending: false)]
        #expect(shown() == ["B", "  A1", "A", "  A2", "    A2a"])
    }

    @Test func sortOrderBinding() {
        let state = State()
        var rows = [Campaign(id: 1, name: "B", spend: 20), Campaign(id: 2, name: "A", spend: 10)]
        let (hosting, window, table) = host(makeView(rows, state: state, sorted: true))
        defer { withExtendedLifetime(window) {} }
        #expect(!table.sortsRows)   // The app sorts.
        // A header click sets the comparators.
        table.sortDescriptors = [NSSortDescriptor(key: "\\Campaign.name", ascending: true)]
        #expect(state.sortOrder == [KeyPathComparator(\Campaign.name, order: .forward)])
        // The app sorts and updates; the table shows its order and the arrow.
        rows.sort(using: state.sortOrder)
        hosting.rootView = makeView(rows, state: state, sorted: true)
        hosting.layoutSubtreeIfNeeded()
        #expect(names(table) == ["A", "B"])
        #expect(table.sortDescriptors.first?.key == "\\Campaign.name")
        // Columns whose values don't compare don't sort with a binding.
        #expect(!table.tableColumns[2].isSortable)
        // The app's own comparator (lexical) stays when a click reverses it.
        rows = ["a1", "a10", "a9"].enumerated().map { Campaign(id: $0.offset, name: $0.element, spend: 0) }
        state.sortOrder = [KeyPathComparator(\Campaign.name, comparator: String.StandardComparator.lexical)]
        hosting.rootView = makeView(rows, state: state, sorted: true)
        hosting.layoutSubtreeIfNeeded()
        table.sortByClicking(table.tableColumns[0])
        #expect(state.sortOrder.first?.order == .reverse)
        #expect(rows.sorted(using: state.sortOrder).map(\.name) == ["a9", "a10", "a1"])
    }

    /// Random feeds (inserts, removes, moves, value changes, in any mix):
    /// the table shows the app's array after every update, and the selection
    /// stays on its record.
    @Test func randomFeedsMatchTheArray() {
        let state = State()
        var rows = (0..<300).map { Campaign(id: $0, name: "R\($0)", spend: Double($0)) }
        state.selection = [150]
        let (hosting, window, table) = host(makeView(rows, state: state, sorted: false))
        defer { withExtendedLifetime(window) {} }
        var seed: UInt64 = 7
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % max(1, n) }
        var nextID = 1000
        for round in 0..<60 {
            for _ in 0..<next(5) { rows.insert(Campaign(id: nextID, name: "N\(nextID)", spend: 1), at: next(rows.count + 1)); nextID += 1 }
            for _ in 0..<next(4) where rows.count > 1 {
                let index = next(rows.count)
                if rows[index].id != 150 { rows.remove(at: index) }
            }
            if round % 3 == 0 { rows.swapAt(next(rows.count), next(rows.count)) }       // A move.
            if round % 7 == 0 { rows.insert(rows.remove(at: next(rows.count)), at: next(rows.count)) }
            for _ in 0..<next(6) { rows[next(rows.count)].spend += 1 }
            hosting.rootView = makeView(rows, state: state, sorted: false)
            hosting.layoutSubtreeIfNeeded()
            #expect(names(table) == rows.map(\.name), "round \(round)")
            #expect(table.summaryValue(forColumnID: "\\Campaign.spend") == rows.reduce(0) { $0 + $1.spend }, "round \(round)")
            #expect(table.selectedRowIndexes == IndexSet(integer: rows.firstIndex { $0.id == 150 }!), "round \(round)")
        }
    }

    struct Task: Identifiable, Equatable {
        var id: Int
        var title: String
        var hours: Double
        var isDone: Bool
        var priority: [NGTag]
        var computed: String { title.uppercased() }
    }

    /// Edits write into the binding of rows; a table of plain rows doesn't edit.
    @Test func editingWritesIntoTheBinding() throws {
        final class Box { var tasks: [Task] = []; var submitted = 0 }
        let box = Box()
        box.tasks = [Task(id: 1, title: "Write", hours: 2, isDone: false, priority: [NGTag("Low")]),
                     Task(id: 2, title: "Test", hours: 1, isDone: true, priority: [NGTag("High")])]
        let tasks = Binding(get: { box.tasks }, set: { box.tasks = $0 })
        let choices: [NGCellValue] = [.tags([NGTag("Low")]), .tags([NGTag("High")])]
        func view() -> NGDataTable<Task> {
            NGDataTable(tasks) {
                NGDataColumn("Title", id: "title", value: \.title).editable()
                NGDataColumn("Hours", id: "hours", value: \.hours, format: .number(fractionDigits: 1)).editable()
                NGDataColumn("Done", id: "done", value: \.isDone).editable()
                NGDataColumn("Priority", id: "priority", value: \.priority).editable(choices: choices)
                NGDataColumn("Upper", id: "upper", value: \.computed).editable()   // Read-only key path: no editing.
            }
            .onSubmit { box.submitted += 1 }
        }
        let hosting = NSHostingView(rootView: view())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(window) {} }
        func find(_ view: NSView) -> NGTableView? { (view as? NGTableView) ?? view.subviews.lazy.compactMap(find).first }
        let table = try #require(find(hosting))
        #expect(table.tableColumns.map(\.isEditable) == [true, true, true, true, false])
        // Text and a number, typed in place.
        #expect(table.editCell(row: 0, columnID: "title"))
        table.editor?.field.stringValue = "Write docs"
        table.endEditing(committing: true)
        #expect(box.tasks[0].title == "Write docs")
        #expect(box.submitted == 1)   // Like a text field's onSubmit.
        table.editCell(row: 1, columnID: "hours")
        table.editor?.field.stringValue = "2.5"
        table.endEditing(committing: true)
        #expect(box.tasks[1].hours == 2.5)
        // A check box and a choice.
        #expect(table.editCell(row: 0, columnID: "done"))
        #expect(box.tasks[0].isDone)
        let column = try #require(table.tableColumns.first { $0.id == "priority" })
        try #require(table.choiceMenu(row: 0, column: column)).performActionForItem(at: 1)
        #expect(box.tasks[0].priority == [NGTag("High")])
        // SwiftUI updates with the edited array: nothing else changes.
        hosting.rootView = view()
        hosting.layoutSubtreeIfNeeded()
        #expect(table.dataSource?.tableView(table, valueFor: table.tableColumns[0], row: 0) == .text("Write docs"))
        // Undo writes the old value back.
        let submitted = box.submitted
        try #require(table.undoManager).undo()
        #expect(box.tasks[0].priority == [NGTag("Low")])
        #expect(box.submitted == submitted)   // Undo isn't the user's submit.
        // Plain rows (no binding): nothing edits.
        let plain = NSHostingView(rootView: NGDataTable(box.tasks) { NGDataColumn("Title", id: "title", value: \.title).editable() })
        plain.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        plain.layoutSubtreeIfNeeded()
        #expect(find(plain)?.tableColumns.first?.isEditable == false)
    }

    /// A filter by rows tests the current rows by the current condition; it
    /// applies to every row again when its id changes.
    @Test func rowFilterFollowsTheConditionAndTheRows() {
        var rows = (0..<10).map { Campaign(id: $0, name: "C\($0)", spend: Double($0)) }
        func view(_ rows: [Campaign], minimum: Double) -> NGDataTable<Campaign> {
            NGDataTable(rows) {
                NGDataColumn("Name", value: \.name)
                NGDataColumn("Spend", value: \.spend)
            }
            .rowFilter(id: minimum) { $0.spend >= minimum }
        }
        let (hosting, window, table) = host(view(rows, minimum: 5))
        defer { withExtendedLifetime(window) {} }
        #expect(names(table) == ["C5", "C6", "C7", "C8", "C9"])
        // Another threshold: every row again.
        hosting.rootView = view(rows, minimum: 8)
        hosting.layoutSubtreeIfNeeded()
        #expect(names(table) == ["C8", "C9"])
        // New rows, and a kept row whose value changed: tested as they come.
        rows.append(contentsOf: (10..<13).map { Campaign(id: $0, name: "C\($0)", spend: Double($0 % 2) * 20) })
        rows[2].spend = 30
        hosting.rootView = view(rows, minimum: 8)
        hosting.layoutSubtreeIfNeeded()
        #expect(names(table) == ["C2", "C8", "C9", "C11"])
    }

    /// The index-based filter is asked with indexes of the rows it captured:
    /// appended and removed rows never reach it with an index past them,
    /// and the rows shown follow its current condition.
    @Test func anIndexFilterIsAskedOnlyForItsRows() {
        var rows = (0..<10).map { Campaign(id: $0, name: "C\($0)", spend: Double($0)) }
        func view(_ rows: [Campaign]) -> NGDataTable<Campaign> {
            NGDataTable(rows) {
                NGDataColumn("Name", value: \.name)
                NGDataColumn("Spend", value: \.spend)
            }
            .rowFilter(NGRowFilter { rows[$0].spend >= 5 })
        }
        let (hosting, window, table) = host(view(rows))
        defer { withExtendedLifetime(window) {} }
        #expect(names(table) == ["C5", "C6", "C7", "C8", "C9"])
        rows.append(contentsOf: (10..<13).map { Campaign(id: $0, name: "C\($0)", spend: Double($0 % 2) * 20) })
        hosting.rootView = view(rows)
        hosting.layoutSubtreeIfNeeded()
        #expect(names(table) == ["C5", "C6", "C7", "C8", "C9", "C11"])
        rows.removeFirst(6)
        rows.insert(Campaign(id: 99, name: "C99", spend: 50), at: 0)
        hosting.rootView = view(rows)
        hosting.layoutSubtreeIfNeeded()
        #expect(names(table) == ["C99", "C6", "C7", "C8", "C9", "C11"])
    }

    /// Random edits of the rows (removes, inserts, moves near and far,
    /// swaps, shuffled blocks, whole shuffles): the table always shows the
    /// array's order, totals its values, and keeps the selection on its rows.
    @Test func diffsOfRandomEditsMatchTheRows() {
        var random = SplitMix(seed: 42)
        var nextID = 1_000
        var rows = (0..<300).map { Campaign(id: $0, name: "C\($0)", spend: Double($0 % 17)) }
        let state = State()
        let (hosting, window, table) = host(makeView(rows, state: state, sorted: false))
        defer { withExtendedLifetime(window) {} }
        for round in 0..<200 {
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                let count = rows.count
                switch Int.random(in: 0..<8, using: &random) {
                case 0 where count > 1:
                    rows.remove(at: Int.random(in: 0..<count, using: &random))
                case 1:
                    nextID += 1
                    rows.insert(Campaign(id: nextID, name: "N\(nextID)", spend: 3), at: Int.random(in: 0...count, using: &random))
                case 2 where count > 1:
                    // A row a few places on (within the walk's window).
                    let from = Int.random(in: 0..<count, using: &random)
                    let to = min(count - 1, max(0, from + Int.random(in: -6...6, using: &random)))
                    rows.insert(rows.remove(at: from), at: to)
                case 3 where count > 1:
                    // Far.
                    rows.insert(rows.remove(at: Int.random(in: 0..<count, using: &random)), at: Int.random(in: 0..<count, using: &random))
                case 4 where count > 1:
                    rows.swapAt(Int.random(in: 0..<count, using: &random), Int.random(in: 0..<count, using: &random))
                case 5 where count > 40:
                    let start = Int.random(in: 0..<(count - 30), using: &random)
                    rows[start..<(start + 30)].shuffle(using: &random)
                case 6 where count > 0:
                    let index = Int.random(in: 0..<count, using: &random)
                    rows[index].spend += 1
                case 7 where round % 25 == 0:
                    rows.shuffle(using: &random)
                default:
                    // A block of inserts (more than the window).
                    let at = Int.random(in: 0...count, using: &random)
                    rows.insert(contentsOf: (0..<20).map { _ in
                        nextID += 1
                        return Campaign(id: nextID, name: "B\(nextID)", spend: 1)
                    }, at: at)
                }
            }
            if round % 10 == 0, let first = rows.first { state.selection = [first.id] }
            hosting.rootView = makeView(rows, state: state, sorted: false)
            hosting.layoutSubtreeIfNeeded()
            #expect(names(table) == rows.map(\.name), "round \(round)")
            #expect(table.summaryValue(forColumnID: "\\Campaign.spend") == rows.reduce(0) { $0 + $1.spend }, "round \(round)")
            if names(table) != rows.map(\.name) { return }
            let selected = Set(table.selectedRowIndexes.map { rows[$0].id })
            #expect(selected == state.selection.intersection(Set(rows.map(\.id))), "round \(round)")
        }
    }

    /// Which way a diff goes: moves near and far are moves, many are a remap.
    @Test func diffsPreferMoves() {
        let rows = (0..<1_000).map { Campaign(id: $0, name: "C\($0)", spend: 0) }
        func diff(_ new: [Campaign]) -> NGRowsDiff { NGDataTable<Campaign>.diff(rows, new, equal: ==) }
        var near = rows
        near.insert(near.remove(at: 10), at: 15)
        #expect(diff(near).moves.count == 1 && diff(near).oldToNew.isEmpty)
        var far = rows
        far.insert(far.remove(at: 900), at: 3)
        #expect(diff(far).moves.count == 1 && diff(far).oldToNew.isEmpty)
        var swapped = rows
        swapped.swapAt(100, 700)
        #expect(diff(swapped).moves.count <= 2 && diff(swapped).oldToNew.isEmpty)
        var block = rows
        block.insert(contentsOf: (2_000..<2_040).map { Campaign(id: $0, name: "", spend: 0) }, at: 0)
        #expect(diff(block).inserted.count == 40 && diff(block).moves.isEmpty && diff(block).oldToNew.isEmpty)
        var random = SplitMix(seed: 3)
        #expect(!diff(rows.shuffled(using: &random)).oldToNew.isEmpty)
    }

    /// A binding of one row allows one row; a new title keeps the user's
    /// column order and the scroll position; a sort restored by autosave
    /// reaches the sort binding instead of being overwritten.
    @Test func bindingsAndDefinitionChangesKeepTheUsersState() async throws {
        let rows = (0..<300).map { Campaign(id: $0, name: "C\($0)", spend: Double($0)) }
        var one: Int? = nil
        let selection = Binding(get: { one }, set: { one = $0 })
        func view(_ title: String) -> NGDataTable<Campaign> {
            NGDataTable(rows, selection: selection) {
                NGDataColumn(title, value: \.name)
                NGDataColumn("Spend", value: \.spend)
            }
        }
        let hosting = NSHostingView(rootView: view("Name"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(window) {} }
        func find(_ view: NSView) -> NGTableView? {
            if let table = view as? NGTableView { return table }
            return view.subviews.lazy.compactMap(find).first
        }
        let table = try #require(find(hosting))
        #expect(!table.allowsMultipleSelection)
        // The user moves a column and scrolls; then the title changes.
        table.moveColumn(1, toColumn: 0)
        table.setContentOffset(CGPoint(x: 0, y: table.rowHeight * 50))
        hosting.rootView = view("Название")
        hosting.layoutSubtreeIfNeeded()
        #expect(table.tableColumns.map(\.title) == ["Spend", "Название"])
        #expect(table.contentOffset.y == table.rowHeight * 50)

        // A saved sort and a sort binding.
        let name = "NGDataTableTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NGTableView Columns \(name)") }
        let saving = NGTableView(frame: .zero)
        saving.columns = [.column(NGTableColumn("\\Campaign.spend", title: "Spend"))]
        saving.autosaveName = name
        saving.sortDescriptors = [NSSortDescriptor(key: "\\Campaign.spend", ascending: false)]
        var order: [KeyPathComparator<Campaign>] = []
        let sortOrder = Binding(get: { order }, set: { order = $0 })
        func sortedView() -> some View {
            NGDataTable(rows, sortOrder: sortOrder) {
                NGDataColumn("Spend", value: \.spend)
            }.tableConfiguration { $0.autosaveName = name }
        }
        let sorted = NSHostingView(rootView: sortedView())
        sorted.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        sorted.layoutSubtreeIfNeeded()
        // Updated again before the binding heard of the restored sort: the
        // binding's empty sort doesn't replace it (nor is it saved).
        sorted.rootView = sortedView()
        sorted.layoutSubtreeIfNeeded()
        let saved = try PropertyListDecoder().decode(NGColumnLayoutState.self,
                                                     from: try #require(UserDefaults.standard.data(forKey: "NGTableView Columns \(name)")))
        #expect(saved.sort?.count == 1)
        try await eventually { order.count == 1 }
        #expect(order.count == 1 && order.first?.order == .reverse)
        withExtendedLifetime((sorted, saving)) {}
    }

    /// Rows sharing an id in an update with many moves (a diff by places):
    /// read again instead of asserting.
    @Test func duplicateIDsWithManyMoves() {
        var rows = (0..<1_000).map { Campaign(id: $0 % 990, name: "C\($0)", spend: Double($0)) }
        let state = State()
        let (hosting, window, table) = host(makeView(rows, state: state, sorted: false))
        defer { withExtendedLifetime(window) {} }
        var generator = SplitMix(seed: 3)
        rows.shuffle(using: &generator)
        hosting.rootView = makeView(rows, state: state, sorted: false)
        hosting.layoutSubtreeIfNeeded()
        #expect(table.numberOfRows == 1_000)
        #expect(names(table) == rows.map(\.name))
    }

    /// A selected row the rows lose leaves the binding; rows sharing an id
    /// are read again instead of asserting; whole numbers take whole numbers.
    @Test func bindingsFollowRemovedRowsAndDuplicates() async throws {
        let state = State()
        var rows = (0..<10).map { Campaign(id: $0, name: "C\($0)", spend: Double($0)) }
        let (hosting, window, table) = host(makeView(rows, state: state, sorted: false))
        defer { withExtendedLifetime(window) {} }
        table.selectRowIndexes([3], byExtendingSelection: false)
        #expect(state.selection == [3])
        rows.remove(at: 3)
        hosting.rootView = makeView(rows, state: state, sorted: false)
        hosting.layoutSubtreeIfNeeded()
        try await eventually { state.selection.isEmpty }
        #expect(state.selection.isEmpty)
        // Two rows with one id.
        rows.append(Campaign(id: 5, name: "Again", spend: 1))
        hosting.rootView = makeView(rows, state: state, sorted: false)
        hosting.layoutSubtreeIfNeeded()
        #expect(table.numberOfRows == rows.count)
        #expect(Int(cellValue: .number(2.7)) == nil && Int(cellValue: .number(3)) == 3)
        #expect(Float(cellValue: .number(1.5)) == 1.5 && UInt(cellValue: .number(-1)) == nil)
    }
}
#endif
