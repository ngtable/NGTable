#if os(macOS)
import AppKit

// Dragging rows out of the table and dropping onto it, like NSTableView:
// - A data source that gives a pasteboard writer for a row
//   (`tableView(_:pasteboardWriterForRow:)`) makes rows draggable: dragging
//   a row (or the selected rows, when it is one of them) starts a dragging
//   session with an image of the rows.
// - A table registered for dragged types (`registerForDraggedTypes(_:)`)
//   asks the data source where a drop may go (`validateDrop`): onto a row
//   over its middle, else above the nearest row; the data source may
//   retarget it (`setDropRow(_:dropOperation:)`). A line between the rows or
//   a highlight on the row shows it, and the data source gets the drop
//   (`acceptDrop`). Rows are data source rows: a drop "above" a row is above
//   that record; at the end, `numberOfSourceRows`.
// - Near the top or bottom edge of the rows a drag scrolls them, faster
//   closer to the edge.

extension NGTableView: NSDraggingSource {
    // MARK: Dragging out

    /// Remembers a press on a row that can be dragged, by its record (a
    /// live update may move it before the drag starts).
    func notePressForRowDrag(_ event: NSEvent, displayRow: Int, wasSelected: Bool, isDraggable: Bool) {
        let row = sourceRow(displayRow)
        rowDragPress = isDraggable && row >= 0 ? (event.locationInWindow, rowRef(ofRow: row), wasSelected) : nil
    }

    /// Whether a display row can be dragged (the data source gives it a writer).
    func canDragRow(displayRow: Int) -> Bool {
        guard let dataSource, displayRow >= 0, displayRow < numberOfRows, !isGroupRow(displayRow) else { return false }
        return dataSource.tableView(self, pasteboardWriterForRow: sourceRow(displayRow)) != nil
    }

    /// Starts dragging once the pointer moved a little from the press.
    /// Returns whether rows are being dragged (so the drag doesn't select).
    func dragRowsIfNeeded(_ event: NSEvent) -> Bool {
        guard let press = rowDragPress, let dataSource else { return false }
        let dx = event.locationInWindow.x - press.location.x, dy = event.locationInWindow.y - press.location.y
        guard hypot(dx, dy) >= 4 else { return true }
        rowDragPress = nil
        // Up or down from a row that wasn't selected: selects instead.
        if !verticalMotionCanBeginDrag, !press.wasSelected, abs(dy) > abs(dx) { return false }
        pendingClickRow = nil
        // The selected rows when the press was on one of them, else that row
        // (a record removed meanwhile drags nothing).
        let pressedRow = row(of: press.ref)
        guard pressedRow >= 0 else { return false }
        let rows = selectedRowIndexes.contains(pressedRow) ? selectedRowIndexes : [pressedRow]
        let items = draggingItems(forRows: rows, dataSource: dataSource)
        guard !items.isEmpty else { return false }
        tracksDragSelection = false
        noteDraggedRows(rows)
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .list
        return true
    }

    /// The dragging items of rows: one per row with its pasteboard writer, or
    /// one for all of them when the data source writes rows at once (the
    /// adapter of an `NSTableViewDataSource` with `writeRowsWith`).
    func draggingItems(forRows rows: IndexSet, dataSource: NGTableViewDataSource) -> [NSDraggingItem] {
        let columns = columnLayout.allColumns
        let width = min(bounds.width, columns.reduce(0) { $0 + CGFloat(self.width(ofColumnID: $1.id) ?? $1.width) })
        if let writesAtOnce = dataSource as? NGRowsPasteboardWriting, writesAtOnce.writesRowsAtOnce,
           let first = rows.first, let writer = writesAtOnce.pasteboardWriter(forRows: rows, in: self) {
            let item = NSDraggingItem(pasteboardWriter: writer)
            let frame = rect(ofRow: first)
            item.setDraggingFrame(NSRect(x: frame.minX, y: frame.minY, width: width, height: frame.height),
                                  contents: rowDragImage(row: first, size: NSSize(width: width, height: frame.height)))
            return [item]
        }
        var items: [NSDraggingItem] = []
        // Pictures of the first rows only (the drag shows a few and a count):
        // drawing one for each of thousands of selected rows hung the press.
        let pictured = 24
        for row in rows {
            guard let writer = dataSource.tableView(self, pasteboardWriterForRow: row) else { continue }
            let item = NSDraggingItem(pasteboardWriter: writer)
            let frame = rect(ofRow: row)
            let image = items.count < pictured ? rowDragImage(row: row, size: NSSize(width: width, height: frame.height)) : nil
            item.setDraggingFrame(NSRect(x: frame.minX, y: frame.minY, width: width, height: frame.height), contents: image)
            items.append(item)
        }
        return items
    }

    /// An image of a row's visible cells, on a translucent background.
    private func rowDragImage(row: Int, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        guard let displayRow = displayRow(forSourceRow: row) else { return image }
        var cells: [(cell: NGDrawnCell, frame: CGRect)] = []
        for (key, cell) in visibleCells where key.row == displayRow {
            let region = regions.first { $0.pin == cell.regionPin } ?? centerRegion
            let frame = convert(cell.cellFrame, from: region.canvas)
            cells.append((cell, CGRect(x: frame.minX, y: 0, width: frame.width, height: size.height)))
        }
        let scale = window?.backingScaleFactor ?? 2
        let content = metalImage(of: cells, size: size, scale: scale)
        image.lockFocus()
        NSColor.controlBackgroundColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 4, yRadius: 4).fill()
        if let content {
            NSImage(cgImage: content, size: size).draw(in: NSRect(origin: .zero, size: size))
        }
        image.unlockFocus()
        return image
    }

    public func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        dataSource?.tableView(self, draggingSession: session, willBeginAt: screenPoint, forRowIndexes: draggedRowIndexes)
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dataSource?.tableView(self, draggingSession: session, endedAt: screenPoint, operation: operation)
        draggedRowRefs = []
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? draggingSourceOperationMaskWithinApplication : draggingSourceOperationMaskOutside
    }

    /// The operations rows dragged out allow, like NSTableView's
    /// `setDraggingSourceOperationMask(_:forLocal:)`.
    public func setDraggingSourceOperationMask(_ mask: NSDragOperation, forLocal isLocal: Bool) {
        if isLocal {
            draggingSourceOperationMaskWithinApplication = mask
        } else {
            draggingSourceOperationMaskOutside = mask
        }
    }

    // MARK: Dropping in

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dataSource, !ignoresUserInput else { return [] }
        var target = proposedDrop(atWindowPoint: sender.draggingLocation)
        dropRetarget = nil
        let operation = dataSource.tableView(self, validateDrop: sender, proposedRow: target.row, proposedDropOperation: target.operation)
        if let retarget = dropRetarget.take() { target = retarget }
        showDropIndicator(operation.isEmpty ? nil : target)
        updateDropScrolling(sender)
        return operation
    }

    public override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {
        guard let sender else { return }
        dataSource?.tableView(self, updateDraggingItemsForDrag: sender)
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        endDropScrolling()
        showDropIndicator(nil)
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        endDropScrolling()
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Where it goes now: rows may have come or gone since the last
        // update of the drag (a live feed), and the row index with them.
        let operation = draggingUpdated(sender)
        endDropScrolling()
        defer { showDropIndicator(nil) }
        guard let dataSource, !operation.isEmpty, let row = dropIndicatorRow else { return false }
        return dataSource.tableView(self, acceptDrop: sender, row: row, dropOperation: dropIndicatorOperation)
    }

    // MARK: Scrolling while dragging

    /// How far into the band along the top (negative) or bottom (positive)
    /// edge of the rows a drag is, like NSTableView scrolling under a drag.
    func dropScrollOverflow(_ info: NSDraggingInfo) -> CGFloat {
        dropScrollOverflow(atWindowPoint: info.draggingLocation)
    }

    private func updateDropScrolling(_ info: NSDraggingInfo) {
        guard dropScrollOverflow(info) != 0 else {
            endDropScrolling()
            return
        }
        dropScrollInfo = info
        guard dropScrollLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(stepDropScroll(_:)))
        link.add(to: .main, forMode: .common)
        dropScrollLink = link
    }

    @objc private func stepDropScroll(_ link: CADisplayLink) {
        guard let info = dropScrollInfo else {
            endDropScrolling()
            return
        }
        let overflow = dropScrollOverflow(info)
        guard overflow != 0 else {
            endDropScrolling()
            return
        }
        scrollForDrop(overflow, link: link)
        // The rows moved under the pointer: the drop target too.
        _ = draggingUpdated(info)
    }

    func endDropScrolling() {
        dropScrollLink?.invalidate()
        dropScrollLink = nil
        dropScrollInfo = nil
    }

}
#endif
