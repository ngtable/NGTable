#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Drops onto the table: where they go, the indicator, and the data source's say.
@Suite("Row dragging")
@MainActor
struct NGRowDraggingTests {
    @MainActor
    final class Records: NGTableViewDataSource {
        var names = (0..<20).map { "Row \($0)" }
        var proposedRows: [Int] = []
        var proposedOperations: [NSTableView.DropOperation] = []
        var acceptedRow: Int?
        var acceptedOperation: NSTableView.DropOperation?
        var accepts = true
        /// Retargets drops onto rows to above them, like a list that only reorders.
        var onlyAbove = false
        func numberOfRows(in tableView: NGTableView) -> Int { names.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text(names[row]) }
        func tableView(_ tableView: NGTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            names[row] as NSString
        }
        func tableView(_ tableView: NGTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            proposedRows.append(row)
            proposedOperations.append(dropOperation)
            if onlyAbove, dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
            return accepts ? .move : []
        }
        func tableView(_ tableView: NGTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            acceptedRow = row
            acceptedOperation = dropOperation
            return true
        }
        var sessionEvents: [String] = []
        func tableView(_ tableView: NGTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                       forRowIndexes rowIndexes: IndexSet) {
            sessionEvents.append("began \(Array(rowIndexes))")
        }
        func tableView(_ tableView: NGTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                       operation: NSDragOperation) {
            sessionEvents.append("ended \(operation.rawValue) \(Array(tableView.draggedRowIndexes))")
        }
        func tableView(_ tableView: NGTableView, updateDraggingItemsForDrag draggingInfo: any NSDraggingInfo) {
            sessionEvents.append("update")
        }
    }

    /// A drag at a point in the window.
    final class Drag: NSObject, NSDraggingInfo {
        let draggingLocation: NSPoint
        weak var source: AnyObject?
        init(location: NSPoint, source: AnyObject?) {
            draggingLocation = location
            self.source = source
        }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .every }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { NSPasteboard(name: NSPasteboard.Name("NGTableTests.drag")) }
        var draggingSource: Any? { source }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    /// The middle of a row in the window's coordinates.
    private func location(onDisplayRow row: Int, in table: NGTableView) -> NSPoint {
        table.centerRegion.canvas.convert(NSPoint(x: 50, y: (CGFloat(row) + 0.5) * table.rowHeight), to: nil)
    }

    /// Over the middle of a row a drop goes onto it; the data source can
    /// retarget it; near the edges of the rows a drag scrolls.
    @Test func dropsOntoRowsAndScrolling() {
        let records = Records()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        defer { withExtendedLifetime((window, records)) {} }
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200))]
        window.contentView = table
        table.dataSource = records
        table.layoutSubtreeIfNeeded()

        let onRow = Drag(location: location(onDisplayRow: 4, in: table), source: table)
        #expect(table.draggingUpdated(onRow) == .move)
        #expect(records.proposedRows.last == 4 && records.proposedOperations.last == .on)
        #expect(table.dropIndicatorRow == 4 && table.dropIndicatorOperation == .on)
        var quads: [NGMetalQuad] = []
        table.appendDropIndicator(style: table.metalStyle, scale: 2, to: &quads)
        #expect(quads.count == 1)
        #expect(table.performDragOperation(onRow))
        #expect(records.acceptedRow == 4 && records.acceptedOperation == .on)

        // Retargeted above: the indicator and the drop follow.
        records.onlyAbove = true
        #expect(table.draggingUpdated(onRow) == .move)
        #expect(table.dropIndicatorOperation == .above)
        #expect(table.performDragOperation(onRow))
        #expect(records.acceptedRow == 4 && records.acceptedOperation == .above)

        // Scrolling: in the band along the top and bottom edges, not between.
        let middle = Drag(location: location(onDisplayRow: 5, in: table), source: table)
        #expect(table.dropScrollOverflow(middle) == 0)
        let bottom = Drag(location: table.convert(NSPoint(x: 50, y: table.bounds.height - table.layoutMetrics.summaryHeight - 2), to: nil),
                          source: table)
        #expect(table.dropScrollOverflow(bottom) > 0)
        _ = table.draggingUpdated(bottom)
        #expect(table.dropScrollLink != nil)
        table.draggingExited(bottom)
        #expect(table.dropScrollLink == nil)
        let top = Drag(location: table.convert(NSPoint(x: 50, y: table.layoutMetrics.headerHeight + 2), to: nil), source: table)
        #expect(table.dropScrollOverflow(top) < 0)
    }

    /// The data source's dragging session calls, like NSTableView's: when
    /// rows start to drag (which, as data source rows), when the drag ends
    /// (e.g. on the Trash, `.delete`), and to update the items over the
    /// table. `draggedRowIndexes` follows the records meanwhile. With the
    /// feedback style `.none`, drops show no indicator.
    @Test func draggingSessions() {
        let records = Records()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        defer { withExtendedLifetime((window, records)) {} }
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200))]
        window.contentView = table
        table.dataSource = records
        table.layoutSubtreeIfNeeded()

        let session = NSDraggingSession()
        table.noteDraggedRows([2, 5])
        table.draggingSession(session, willBeginAt: .zero)
        #expect(records.sessionEvents == ["began [2, 5]"])
        records.names.insert("New", at: 0)
        table.insertRows(at: [0])
        #expect(table.draggedRowIndexes == [3, 6])
        let drag = Drag(location: location(onDisplayRow: 4, in: table), source: table)
        table.updateDraggingItemsForDrag(drag)
        table.draggingSession(session, endedAt: .zero, operation: .delete)
        #expect(records.sessionEvents == ["began [2, 5]", "update", "ended \(NSDragOperation.delete.rawValue) [3, 6]"])
        #expect(table.draggedRowIndexes.isEmpty)

        // No indicator with `.none`; the drop still goes there.
        table.draggingDestinationFeedbackStyle = .none
        #expect(table.draggingUpdated(drag) == .move)
        var quads: [NGMetalQuad] = []
        table.appendDropIndicator(style: table.metalStyle, scale: 2, to: &quads)
        #expect(quads.isEmpty)
        #expect(table.performDragOperation(drag))
        #expect(records.acceptedRow == 4)
    }

    /// The `.gap` feedback style, like NSTableView's: the rows from where a
    /// drop between rows would go are drawn a row lower, opening a gap
    /// there instead of a line; it closes when the drag leaves. Drops onto a
    /// row still highlight it. Layout doesn't move: only drawing.
    @Test func dropsOpenAGap() {
        let records = Records()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        defer { withExtendedLifetime((window, records)) {} }
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200))]
        window.contentView = table
        table.dataSource = records
        table.draggingDestinationFeedbackStyle = .gap
        table.layoutSubtreeIfNeeded()
        let before = table.rect(ofRow: 5)
        let above = Drag(location: location(aboveDisplayRow: 3, in: table), source: table)
        #expect(table.draggingUpdated(above) == .move)
        #expect(table.dropGapDisplayRow == 3)
        #expect(table.dropGapOffset(ofDisplayRow: 2, progress: 1) == 0)
        #expect(table.dropGapOffset(ofDisplayRow: 3, progress: 1) == table.rowHeight)
        #expect(table.dropGapOffset(ofDisplayRow: 9, progress: 1) == table.rowHeight)
        #expect(table.rect(ofRow: 5) == before)
        var quads: [NGMetalQuad] = []
        table.appendDropIndicator(style: table.metalStyle, scale: 2, to: &quads)
        #expect(quads.isEmpty)   // The gap, not a line.
        // Onto a row: no gap, the highlight.
        let onRow = Drag(location: location(onDisplayRow: 6, in: table), source: table)
        _ = table.draggingUpdated(onRow)
        #expect(table.dropGapDisplayRow == nil)
        table.appendDropIndicator(style: table.metalStyle, scale: 2, to: &quads)
        #expect(quads.count == 1)
        // Leaving closes it; so does the drop.
        _ = table.draggingUpdated(above)
        table.draggingExited(above)
        #expect(table.dropGapDisplayRow == nil)
        _ = table.draggingUpdated(above)
        #expect(table.performDragOperation(above))
        #expect(table.dropGapDisplayRow == nil && records.acceptedRow == 3)
    }

    /// A row's middle-top edge in the window's coordinates.
    private func location(aboveDisplayRow row: Int, in table: NGTableView) -> NSPoint {
        table.centerRegion.canvas.convert(NSPoint(x: 50, y: CGFloat(row) * table.rowHeight + 1), to: nil)
    }

    /// Rows that come between the last update of a drag and the drop (a
    /// live feed): the drop goes where the pointer is when it's let go, not
    /// to the row index found before.
    @Test func aDropIsPlacedWhenItsLetGo() {
        let records = Records()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        defer { withExtendedLifetime((window, records)) {} }
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200))]
        window.contentView = table
        table.dataSource = records
        table.registerForDraggedTypes([.string])
        table.layoutSubtreeIfNeeded()
        let drag = Drag(location: location(aboveDisplayRow: 3, in: table), source: table)
        #expect(table.draggingUpdated(drag) == .move)
        #expect(table.dropIndicatorRow == 3)
        // Two rows sorted out of view under the pointer: the pointer is now over other records.
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        #expect(table.performDragOperation(drag))
        #expect(records.acceptedRow == table.sourceRow(3))
        #expect(records.acceptedRow != 3)
    }

    @Test func dropsGoAboveTheRowUnderThePointer() {
        let records = Records()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        defer { withExtendedLifetime((window, records)) {} }
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200))]
        window.contentView = table
        table.dataSource = records
        table.registerForDraggedTypes([.string])
        table.layoutSubtreeIfNeeded()

        let drag = Drag(location: location(aboveDisplayRow: 3, in: table), source: table)
        #expect(table.draggingEntered(drag) == .move)
        #expect(records.proposedRows.last == 3)
        #expect(table.dropIndicatorRow == 3)
        #expect(table.performDragOperation(drag))
        #expect(records.acceptedRow == 3)
        #expect(table.dropIndicatorRow == nil)

        // Sorted: the row is the record shown there.
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        let sorted = Drag(location: location(aboveDisplayRow: 0, in: table), source: table)
        #expect(table.draggingUpdated(sorted) == .move)
        #expect(records.proposedRows.last == 19)   // "Row 19" sorts first, descending (numbers compare as numbers).

        // Refused: no indicator, nothing dropped.
        records.accepts = false
        records.acceptedRow = nil
        #expect(table.draggingUpdated(drag).isEmpty)
        #expect(table.dropIndicatorRow == nil)
        #expect(!table.performDragOperation(drag))
        #expect(records.acceptedRow == nil)
    }

    /// Presses on draggable rows: selected rows stay selected until the
    /// mouse goes up (so they drag together), and with
    /// `verticalMotionCanBeginDrag` off a vertical drag selects rows.
    @Test func pressesOnDraggableRows() throws {
        let records = Records()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        defer { withExtendedLifetime((window, records)) {} }
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200))]
        window.contentView = table
        table.dataSource = records
        table.layoutSubtreeIfNeeded()
        func event(_ type: NSEvent.EventType, row: Int, x: CGFloat = 50, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let location = table.centerRegion.canvas.convert(NSPoint(x: x, y: (CGFloat(row) + 0.5) * table.rowHeight), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        table.selectRowIndexes([2, 4, 6], byExtendingSelection: false)
        table.rowsMouseDown(try event(.leftMouseDown, row: 4), in: table.centerRegion)
        #expect(table.selectedRowIndexes == [2, 4, 6])   // Still all: they could be dragged.
        #expect(table.rowDragPress?.wasSelected == true)
        table.rowsMouseUp(try event(.leftMouseUp, row: 4))
        #expect(table.selectedRowIndexes == [4])          // A click: only it.
        // A row inserted above between the press and the release: the record pressed is selected.
        table.selectRowIndexes([2, 4, 6], byExtendingSelection: false)
        table.rowsMouseDown(try event(.leftMouseDown, row: 4), in: table.centerRegion)
        records.names.insert("New", at: 0)
        table.insertRows(at: [0])
        table.rowsMouseUp(try event(.leftMouseUp, row: 4))
        #expect(table.selectedRowIndexes == [5])

        // Vertical motion from a row that wasn't selected: selects rows.
        table.verticalMotionCanBeginDrag = false
        table.rowsMouseDown(try event(.leftMouseDown, row: 8), in: table.centerRegion)
        table.rowsMouseDragged(try event(.leftMouseDragged, row: 11))
        #expect(table.rowDragPress == nil)
        table.rowsMouseDragged(try event(.leftMouseDragged, row: 11))
        table.rowsMouseUp(try event(.leftMouseUp, row: 11))
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 8...11))
    }

    /// The focused cell's ring shows only after the keys move it: a click
    /// (plain, Command or Shift), Escape or losing the focus hides it, the
    /// focused cell stays for the keys to go on from.
    @Test func focusRingOnlyAfterTheKeyboard() throws {
        let records = Records()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        defer { withExtendedLifetime((window, records)) {} }
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                         .column(NGTableColumn("other", title: "Other", width: 100))]
        window.contentView = table
        table.dataSource = records
        table.navigatesByCell = true
        table.layoutSubtreeIfNeeded()
        window.makeFirstResponder(table)
        func ringQuads() -> Int {
            var quads: [NGMetalQuad] = []
            table.appendFocusRing(style: table.metalStyle, scale: 2, to: &quads)
            return quads.count
        }
        func click(_ row: Int, modifiers: NSEvent.ModifierFlags = []) throws {
            let location = table.centerRegion.canvas.convert(NSPoint(x: 50, y: (CGFloat(row) + 0.5) * table.rowHeight), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: 1, pressure: 1))
                type == .leftMouseDown ? table.rowsMouseDown(event, in: table.centerRegion) : table.rowsMouseUp(event)
            }
        }

        try click(2)
        #expect(table.focusedCell == NGCellPosition(row: 2, columnID: "name"))
        #expect(ringQuads() == 0)
        table.moveDown(nil)
        #expect(table.focusedCell?.row == 3)
        #expect(ringQuads() == 4)
        try click(5, modifiers: .command)
        #expect(ringQuads() == 0)
        table.moveRightAndModifySelection(nil)
        #expect(ringQuads() == 4)
        try click(7, modifiers: .shift)
        #expect(ringQuads() == 0)
        table.moveUp(nil)
        table.cancelOperation(nil)
        #expect(ringQuads() == 0)
        #expect(table.focusedCell != nil)
        table.moveDown(nil)
        #expect(ringQuads() == 4)
        window.makeFirstResponder(nil)
        #expect(ringQuads() == 0)
    }
}
#endif
