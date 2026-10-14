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

    /// The data source rows being dragged out, following their records as
    /// rows move; empty when no rows are dragged. Like the rows of
    /// NSTableView's `draggingSession(_:willBeginAt:forRowIndexes:)`, kept
    /// up to date until the drag ended.
    public var draggedRowIndexes: IndexSet {
        IndexSet(draggedRowRefs.map { row(of: $0) }.filter { $0 >= 0 })
    }

    /// Remembers the rows a drag takes, by record.
    func noteDraggedRows(_ rows: IndexSet) {
        draggedRowRefs = rows.map { rowRef(ofRow: $0) }
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

    /// Where a drop at a point goes: above a data source row (or at the end).
    private func dropRow(for info: NSDraggingInfo) -> Int {
        let y = centerRegion.canvas.convert(info.draggingLocation, from: nil).y
        let displayRow = min(max(Int(rowGeometry.position(atY: y).rounded()), 0), numberOfRows)
        var next = displayRow
        while next < numberOfRows, isGroupRow(next) { next += 1 }
        return next < numberOfRows ? sourceRow(next) : numberOfSourceRows
    }

    /// Where a drop at a point goes, like NSTableView proposes it: onto a row
    /// over its middle half, else above the row nearest the pointer.
    private func proposedDrop(for info: NSDraggingInfo) -> (row: Int, operation: NSTableView.DropOperation) {
        let position = rowGeometry.position(atY: centerRegion.canvas.convert(info.draggingLocation, from: nil).y)
        let displayRow = Int(floor(position))
        let fraction = position - floor(position)
        if displayRow >= 0, displayRow < numberOfRows, !isGroupRow(displayRow), fraction > 0.25, fraction < 0.75 {
            return (sourceRow(displayRow), .on)
        }
        return (dropRow(for: info), .above)
    }

    /// Retargets the drop being validated, like NSTableView's: from
    /// `tableView(_:validateDrop:proposedRow:proposedDropOperation:)`, e.g.
    /// `.above` instead of `.on` for a list that only reorders, or row -1
    /// with `.on` for the whole table.
    public func setDropRow(_ row: Int, dropOperation: NSTableView.DropOperation) {
        dropRetarget = (row, dropOperation)
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dataSource, !ignoresUserInput else { return [] }
        var target = proposedDrop(for: sender)
        dropRetarget = nil
        let operation = dataSource.tableView(self, validateDrop: sender, proposedRow: target.row, proposedDropOperation: target.operation)
        if let retarget = dropRetarget.take() { target = retarget }
        let indicator = operation.isEmpty ? nil : target
        if indicator?.row != dropIndicatorRow || (indicator != nil && indicator?.operation != dropIndicatorOperation) {
            dropIndicatorRow = indicator?.row
            dropIndicatorOperation = indicator?.operation ?? .above
            setNeedsMetalFrame()
        }
        updateDropGap()
        updateDropScrolling(sender)
        return operation
    }

    public override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {
        guard let sender else { return }
        dataSource?.tableView(self, updateDraggingItemsForDrag: sender)
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        endDropScrolling()
        dropIndicatorRow = nil
        updateDropGap()
        setNeedsMetalFrame()
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        endDropScrolling()
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Where it goes now: rows may have come or gone since the last
        // update of the drag (a live feed), and the row index with them.
        let operation = draggingUpdated(sender)
        endDropScrolling()
        defer {
            dropIndicatorRow = nil
            updateDropGap()
            setNeedsMetalFrame()
        }
        guard let dataSource, !operation.isEmpty, let row = dropIndicatorRow else { return false }
        return dataSource.tableView(self, acceptDrop: sender, row: row, dropOperation: dropIndicatorOperation)
    }

    // MARK: Scrolling while dragging

    /// How far into the band along the top (negative) or bottom (positive)
    /// edge of the rows a drag is, like NSTableView scrolling under a drag.
    func dropScrollOverflow(_ info: NSDraggingInfo) -> CGFloat {
        let y = convert(info.draggingLocation, from: nil).y
        let metrics = layoutMetrics
        let band = rowHeight
        let top = metrics.headerHeight + band
        let bottom = bounds.height - metrics.summaryHeight - band
        if y < top { return y - top }
        if y > bottom { return y - bottom }
        return 0
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
        // Faster deeper into the band and past it (points per second).
        let speed = min(abs(overflow) * 16 + 80, 3000)
        let elapsed = min(max(link.targetTimestamp - link.timestamp, 1.0 / 120), 1.0 / 30)
        setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y + (overflow < 0 ? -speed : speed) * elapsed))
        // The rows moved under the pointer: the drop target too.
        _ = draggingUpdated(info)
    }

    func endDropScrolling() {
        dropScrollLink?.invalidate()
        dropScrollLink = nil
        dropScrollInfo = nil
    }

    // MARK: The drop gap

    static let dropGapDuration: CFTimeInterval = 0.15

    /// The display row the rows open a gap at for a drop between them
    /// (`draggingDestinationFeedbackStyle` `.gap`), or `nil`.
    var dropGapDisplayRow: Int? { dropGap?.displayRow }

    /// How far open the gap is now (0 to 1, eased; open at once with Reduce Motion).
    var dropGapProgress: CGFloat {
        guard let dropGap else { return 0 }
        guard dropGapLink != nil else { return 1 }
        let linear = min(1, max(0, (CACurrentMediaTime() - dropGap.start) / Self.dropGapDuration))
        return CGFloat(1 - pow(1 - linear, 3))
    }

    /// How much lower a display row is drawn for the gap.
    func dropGapOffset(ofDisplayRow row: Int, progress: CGFloat? = nil) -> CGFloat {
        guard let dropGap, row >= dropGap.displayRow else { return 0 }
        return rowHeight * (progress ?? dropGapProgress)
    }

    /// Opens the gap where a drop between rows would go, or closes it.
    func updateDropGap() {
        var target: Int?
        if draggingDestinationFeedbackStyle == .gap, dropIndicatorOperation == .above, let row = dropIndicatorRow {
            target = row < numberOfSourceRows ? displayRow(forSourceRow: row) : numberOfRows
        }
        guard target != dropGap?.displayRow else { return }
        dropGap = target.map { ($0, CACurrentMediaTime()) }
        let animates = dropGap != nil && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animates, dropGapLink == nil {
            let link = displayLink(target: self, selector: #selector(stepDropGap(_:)))
            link.add(to: .main, forMode: .common)
            dropGapLink = link
        } else if !animates {
            dropGapLink?.invalidate()
            dropGapLink = nil
        }
        setNeedsMetalFrame()
    }

    @objc func stepDropGap(_ link: CADisplayLink) {
        if dropGapProgress >= 1 {
            dropGapLink?.invalidate()
            dropGapLink = nil
        }
        setNeedsMetalFrame()
    }

    /// Where a drop would go: a line between rows (or the gap, `.gap`), or a
    /// highlight on the row (or around all rows) it would go onto.
    func appendDropIndicator(style: MetalStyle, scale: CGFloat, to quads: inout [NGMetalQuad]) {
        guard let row = dropIndicatorRow, draggingDestinationFeedbackStyle != .none else { return }
        if draggingDestinationFeedbackStyle == .gap, dropIndicatorOperation == .above { return }
        let color = style.color(.controlAccentColor)
        let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let rows = NSRect(x: 0, y: layoutMetrics.headerHeight, width: bounds.width,
                          height: max(0, bounds.height - layoutMetrics.headerHeight - layoutMetrics.summaryHeight))
        if dropIndicatorOperation == .on {
            if row < 0 {
                // The whole table: a frame around the rows.
                let frame = rows.insetBy(dx: 1, dy: 1)
                for edge in [NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: 2),
                             NSRect(x: frame.minX, y: frame.maxY - 2, width: frame.width, height: 2),
                             NSRect(x: frame.minX, y: frame.minY, width: 2, height: frame.height),
                             NSRect(x: frame.maxX - 2, y: frame.minY, width: 2, height: frame.height)] {
                    quads.append(NGMetalRenderer.rectangle(edge, scale: scale, color: color, clip: rows))
                }
            } else if let displayRow = displayRow(forSourceRow: row) {
                let y = convert(NSPoint(x: 0, y: rowGeometry.top(of: displayRow)), from: centerRegion.canvas).y
                let inset = selectionHighlightStyle == .rounded ? NGMetrics.selectionInset : 0
                let frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: rowGeometry.height(of: displayRow))
                quads.append(NGMetalRenderer.roundedRectangle(frame, radius: inset > 0 ? NGMetrics.selectionCornerRadius : 0, corners: allCorners,
                                                              scale: scale, color: color * 0.3, clip: frame.intersection(rows)))
            }
            return
        }
        let displayRow = row < numberOfSourceRows ? self.displayRow(forSourceRow: row) ?? numberOfRows : numberOfRows
        let y = convert(NSPoint(x: 0, y: rowGeometry.top(of: displayRow)), from: centerRegion.canvas).y
        quads.append(NGMetalRenderer.roundedRectangle(NSRect(x: 8, y: y - 1, width: bounds.width - 16, height: 2), radius: 1,
                                                      corners: allCorners, scale: scale, color: color))
    }
}
#endif
