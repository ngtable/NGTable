#if os(macOS)
import AppKit
import Metal

extension NGTableView {

    // MARK: Column reordering

    /// What a header press would move: the whole group when pressing its title
    /// band, otherwise the column (inside its group, if any).
    private func reorderUnit(for column: NGTableColumn, pointY: CGFloat) -> NGColumnReorder.Unit {
        guard let groupID = columnLayout.groupIDByColumnID[column.id] else {
            return .item(id: column.id)
        }
        return pointY < groupHeaderHeight ? .item(id: groupID) : .member(columnID: column.id, groupID: groupID)
    }

    /// Columns that don't take part in a drag: hidden ones, and fixed ones, which
    /// keep their slot (the others move around them, like around hidden ones).
    private var reorderExcludedIDs: Set<String> {
        hiddenColumnIDs.union(columns.flatMap(\.leafColumns).filter { !$0.isMovable }.map(\.id))
    }

    /// Viewport x ranges of the unit's siblings, in display order.
    private func siblingRanges(of unit: NGColumnReorder.Unit, pin: NGColumnPin) -> [(id: String, range: ClosedRange<CGFloat>)] {
        let region = geometry[pin]
        let origin = viewport.origin(of: pin)
        return NGColumnReorder.siblings(of: unit, in: columns, hiddenIDs: reorderExcludedIDs).compactMap { id in
            if let frame = region.columns.first(where: { $0.column.id == id }) {
                return (id, (origin + CGFloat(frame.x))...(origin + CGFloat(frame.maxX)))
            }
            if let group = region.groups.first(where: { $0.groupID == id }) {
                return (id, (origin + CGFloat(group.x))...(origin + CGFloat(group.maxX)))
            }
            return nil
        }
    }

    private func draggedID(of unit: NGColumnReorder.Unit) -> String {
        switch unit {
        case .item(let id): id
        case .member(let columnID, _): columnID
        }
    }

    /// Leaf columns moved by a drag unit.
    private func columnIDs(of unit: NGColumnReorder.Unit) -> Set<String> {
        switch unit {
        case .member(let columnID, _):
            return [columnID]
        case .item(let id):
            if let group = columnLayout.groupsByID[id] {
                return Set(group.columns.map(\.id))
            }
            return [id]
        }
    }

    /// The visible part of the unit's slot in viewport coordinates.
    private func visibleSlot(of unit: NGColumnReorder.Unit, pin: NGColumnPin) -> ClosedRange<CGFloat>? {
        let draggedID = draggedID(of: unit)
        guard let range = siblingRanges(of: unit, pin: pin).first(where: { $0.id == draggedID })?.range else { return nil }
        let clip = viewport.clipRange(of: pin, regionWidth: CGFloat(geometry[pin].width))
        let minX = max(range.lowerBound, clip.lowerBound)
        let maxX = min(range.upperBound, clip.upperBound)
        return minX < maxX ? minX...maxX : nil
    }

    /// Like NSTableView: the dragged columns (header, cells and summary) are
    /// lifted as a snapshot that follows the pointer, leaving an empty slot.
    private func beginColumnDrag(unit: NGColumnReorder.Unit, pin: NGColumnPin, pointerX: CGFloat) {
        let draggedID = draggedID(of: unit)
        guard let range = siblingRanges(of: unit, pin: pin).first(where: { $0.id == draggedID })?.range else { return }
        // The whole column lifts, even if it is partly scrolled out or under a
        // frozen region. A column inside a group lifts without the group title
        // band, which stays in place.
        let top: CGFloat = if case .member = unit { groupHeaderHeight } else { 0 }
        let rect = NSRect(x: range.lowerBound, y: top, width: range.upperBound - range.lowerBound, height: bounds.height - top)
        let columnIDs = columnIDs(of: unit)
        // Columns still sliding from a previous drop would be captured half-way.
        stopColumnSlide()
        let snapshot = NGDragSnapshotView(frame: rect)
        snapshot.image = makeColumnDragImage(of: rect, unit: unit, columnIDs: columnIDs, pin: pin)
        // Above the content, below the scrollers.
        addSubview(snapshot, positioned: .below, relativeTo: verticalScroller)

        columnDrag = ColumnDrag(
            unit: unit,
            pin: pin,
            snapshot: snapshot,
            grabOffset: pointerX - rect.minX,
            columnIDs: columnIDs,
            originalColumns: columns
        )
        // Column edges passing under the pointer must not switch to the resize cursor.
        suspendHeaderCursorRects(showing: .arrow)
        refreshAfterColumnMove()
    }

    /// Renders the dragged columns in full: header, visible rows and summary.
    /// Screen capture would only include the visible part (and misses the Liquid
    /// Glass summary bar), so the image is drawn with the table's own code: the
    /// header and summary drawing, row colors, and cells made like visible ones
    /// (default cells drawn by the Metal renderer offscreen).
    func makeColumnDragImage(
        of rect: NSRect, unit: NGColumnReorder.Unit, columnIDs: Set<String>, pin: NGColumnPin
    ) -> NSImage? {
        let scale = displayScale
        guard rect.width > 0, rect.height > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int(ceil(rect.width * scale)), pixelsHigh: Int(ceil(rect.height * scale)),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        // The size in points first: the context takes its scale from it.
        bitmap.size = rect.size
        guard let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        // Draw in table coordinates: flipped, with the snapshot's origin at rect.origin.
        let cgContext = bitmapContext.cgContext
        cgContext.translateBy(x: 0, y: rect.height)
        cgContext.scaleBy(x: 1, y: -1)
        cgContext.translateBy(x: -rect.minX, y: -rect.minY)
        let context = NSGraphicsContext(cgContext: cgContext, flipped: true)

        let frames = geometry[pin].columns.filter { columnIDs.contains($0.column.id) }
        let origin = viewport.origin(of: pin)
        let metrics = layoutMetrics
        let bodyTop = metrics.headerHeight
        let bodyBottom = bounds.height - metrics.summaryHeight

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        effectiveAppearance.performAsCurrentDrawingAppearance {
            metalStyle.background.setFill()
            rect.fill()

            // Rows: backgrounds and cells for the rows visible right now.
            NSGraphicsContext.saveGraphicsState()
            let body = NSRect(x: rect.minX, y: bodyTop, width: rect.width, height: max(0, bodyBottom - bodyTop))
            body.clip()
            // Default cells, drawn together over the backgrounds; cells made
            // for the snapshot are recycled after that.
            var drawnCells: [(cell: NGDrawnCell, frame: CGRect)] = []
            var madeCells: [NGDrawnCell] = []
            let rowLayout = rowGeometry
            let firstRow = max(0, Int(floor(rowLayout.position(atY: renderedOffsetY))))
            let lastRow = Int(ceil(rowLayout.position(atY: renderedOffsetY + metrics.bodyHeight)))
            for row in firstRow..<max(firstRow, lastRow) {
                let y = bodyTop + rowLayout.top(of: row) - renderedOffsetY
                rowColor(row).setFill()
                NSRect(x: rect.minX, y: y, width: rect.width, height: rowLayout.height(of: row)).fill()
                guard row < numberOfRows else { continue }
                for frame in frames {
                    // Visible cells are drawn as they are (no data source calls).
                    let cell: NGDrawnCell
                    if let visible = visibleCell(row: row, columnID: frame.column.id) {
                        cell = visible
                    } else {
                        cell = makeCell(for: frame.column, row: row)
                        madeCells.append(cell)
                    }
                    resolveContent(of: cell)
                    let cellFrame = NSRect(x: origin + CGFloat(frame.x) - body.minX, y: y - body.minY,
                                           width: CGFloat(frame.width), height: rowLayout.height(of: row))
                    drawnCells.append((cell, cellFrame))
                }
            }
            if let image = metalImage(of: drawnCells, size: body.size, scale: scale) {
                NSImage(cgImage: image, size: body.size).draw(in: body, from: .zero, operation: .sourceOver, fraction: 1,
                                                              respectFlipped: true, hints: nil)
            }
            madeCells.forEach(recycle)
            NSGraphicsContext.restoreGraphicsState()

            // Header on an opaque base (the translucent header material is not drawn).
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, bodyTop - rect.minY)).fill()
            var region = NGRegionGeometry(pin: pin)
            region.columns = frames
            if case .item(let groupID) = unit {
                region.groups = geometry[pin].groups.filter { $0.groupID == groupID }
            }
            NSColor.separatorColor.setFill()
            NSRect(x: rect.minX, y: bodyTop - hairline, width: rect.width, height: hairline).fill()

            // Summary strip.
            if metrics.summaryHeight > 0 {
                let strip = NSRect(x: rect.minX, y: bodyBottom, width: rect.width, height: metrics.summaryHeight)
                NSColor.windowBackgroundColor.setFill()
                strip.fill()
                NSColor.separatorColor.setFill()
                NSRect(x: rect.minX, y: bodyBottom, width: rect.width, height: hairline).fill()
            }

            // Header titles and summary values, drawn by Metal like on screen,
            // in the snapshot's coordinates.
            if let renderer = metalRenderer {
                let style = metalStyle
                let headerClip = NSRect(x: 0, y: 0, width: rect.width, height: max(0, bodyTop - rect.minY))
                let quads = renderer.quadsSurvivingAtlasResets {
                    var quads: [NGMetalQuad] = []
                    appendHeaderRegion(region, originX: origin - rect.minX, clip: headerClip, top: -rect.minY, height: bodyTop,
                                       renderer: renderer, scale: scale, style: style, to: &quads)
                    if metrics.summaryHeight > 0 {
                        let summaryClip = NSRect(x: 0, y: bodyBottom - rect.minY, width: rect.width, height: metrics.summaryHeight)
                        for frame in frames {
                            let columnRect = NSRect(x: origin + CGFloat(frame.x) - rect.minX, y: summaryClip.minY,
                                                    width: CGFloat(frame.width), height: metrics.summaryHeight)
                            appendSummaryText(for: frame.column, in: columnRect, clip: summaryClip, renderer: renderer, scale: scale,
                                              style: style, to: &quads)
                        }
                    }
                    return quads
                }
                if let image = offscreenImage(of: quads, size: rect.size, scale: scale, clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) {
                    NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                                                  respectFlipped: true, hints: nil)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func moveColumnDrag(_ drag: ColumnDrag, pointerX: CGFloat) {
        columnDragPointerX = pointerX
        // Near an edge of the scrolling area the table keeps scrolling on every
        // frame, also while the pointer rests there, like system tables.
        if drag.pin == .none, canColumnDragScroll() {
            if columnDragScrollLink == nil {
                let link = displayLink(target: self, selector: #selector(stepColumnDragScroll(_:)))
                link.add(to: .main, forMode: .common)
                columnDragScrollLink = link
            }
        } else {
            stopColumnDragScrolling()
        }
        positionColumnDrag(drag, pointerX: pointerX)
    }

    private static let columnDragScrollEdge: CGFloat = 24

    /// How far the pointer is into the leading (negative) or trailing (positive)
    /// edge zone of the scrolling area, or 0 outside them.
    private func columnDragEdgeOverflow() -> CGFloat {
        let clip = viewport.clipRange(of: .none, regionWidth: CGFloat(geometry.center.width))
        let edge = Self.columnDragScrollEdge
        if columnDragPointerX < clip.lowerBound + edge { return columnDragPointerX - (clip.lowerBound + edge) }
        if columnDragPointerX > clip.upperBound - edge { return columnDragPointerX - (clip.upperBound - edge) }
        return 0
    }

    /// Whether the pointer is in an edge zone and the table can still scroll that way.
    private func canColumnDragScroll() -> Bool {
        let overflow = columnDragEdgeOverflow()
        guard overflow != 0 else { return false }
        // Physical left is toward the start left to right, toward the end right to left.
        let towardStart = (overflow < 0) != isRightToLeft
        return towardStart ? contentOffset.x > 0 : contentOffset.x < layoutMetrics.maxOffset.x
    }

    @objc func stepColumnDragScroll(_ link: CADisplayLink) {
        guard let drag = columnDrag, !drag.isLanding, drag.pin == .none else {
            stopColumnDragScrolling()
            return
        }
        // The mouse up went elsewhere (e.g. the app lost focus): end the drag
        // instead of scrolling on.
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            cancelHeaderInteraction()
            return
        }
        let overflow = columnDragEdgeOverflow()
        guard canColumnDragScroll() else {
            stopColumnDragScrolling()
            return
        }
        // Faster the deeper the pointer is in the edge zone (points per second).
        let speed = min(abs(overflow) * 40 + 200, 3_000)
        let elapsed = min(max(link.targetTimestamp - link.timestamp, 1.0 / 120), 1.0 / 30)
        let towardStart = (overflow < 0) != isRightToLeft
        setContentOffset(CGPoint(x: contentOffset.x + (towardStart ? -speed : speed) * elapsed, y: contentOffset.y))
        positionColumnDrag(drag, pointerX: columnDragPointerX)
    }

    func stopColumnDragScrolling() {
        columnDragScrollLink?.invalidate()
        columnDragScrollLink = nil
    }

    /// Scrolling moved the columns under a dragged one: keep reordering around it.
    func repositionColumnDragAfterScroll() {
        guard let drag = columnDrag, !drag.isLanding, drag.pin == .none else { return }
        positionColumnDrag(drag, pointerX: columnDragPointerX)
    }

    /// Keeps the snapshot under the pointer and moves the columns around it.
    private func positionColumnDrag(_ drag: ColumnDrag, pointerX: CGFloat) {
        let regionWidth = CGFloat(geometry[drag.pin].width)
        let clip = viewport.clipRange(of: drag.pin, regionWidth: regionWidth)
        var frame = drag.snapshot.frame
        frame.origin.x = min(max(pointerX - drag.grabOffset, clip.lowerBound), max(clip.lowerBound, clip.upperBound - frame.width))
        drag.snapshot.frame = frame

        // Swap when the snapshot's leading or trailing edge crosses a neighbor's midpoint.
        let draggedID = draggedID(of: drag.unit)
        guard let currentIndex = NGColumnReorder.siblings(of: drag.unit, in: columns, hiddenIDs: reorderExcludedIDs).firstIndex(of: draggedID) else { return }
        // In display order the siblings run left to right; right to left they
        // run the other way, so positions are negated (mirrored) for the search.
        func span(_ minX: CGFloat, _ maxX: CGFloat) -> ClosedRange<Double> {
            isRightToLeft ? -Double(maxX)...(-Double(minX)) : Double(minX)...Double(maxX)
        }
        let others = siblingRanges(of: drag.unit, pin: drag.pin)
            .filter { $0.id != draggedID }
            .map { span($0.range.lowerBound, $0.range.upperBound) }
        let targetIndex = NGColumnReorder.targetIndex(
            currentIndex: currentIndex,
            others: others,
            draggedSpan: span(frame.minX, frame.maxX)
        )
        guard targetIndex != currentIndex else { return }
        let reordered = NGColumnReorder.moving(drag.unit, to: targetIndex, in: columns, hiddenIDs: reorderExcludedIDs)
        // A single column asks the delegate (indexes in `tableColumns`).
        if case .item = drag.unit, columnLayout.groupIDByColumnID[draggedID] == nil, columnLayout.columnsByID[draggedID] == nil {
            // A whole group: moves without asking.
        } else if let from = tableColumns.firstIndex(where: { $0.id == draggedID }),
                  let to = reordered.flatMap(\.leafColumns).firstIndex(where: { $0.id == draggedID }),
                  delegate?.tableView(self, shouldReorderColumn: from, toColumn: to) == false {
            return
        }

        let before = columnPositions(in: drag.pin, includingSlide: true)
        applyReorderedColumns(reordered)
        slideColumns(from: before, to: columnPositions(in: drag.pin, includingSlide: false))
    }

    /// The snapshot glides into its slot, then the real column reappears.
    private func endColumnDrag(_ drag: ColumnDrag) {
        stopColumnDragScrolling()
        resumeHeaderCursorRects()
        columnDrag?.isLanding = true
        let snapshot = drag.snapshot
        // Land on the column's slot, kept within the region like while dragging.
        let draggedID = draggedID(of: drag.unit)
        let clip = viewport.clipRange(of: drag.pin, regionWidth: CGFloat(geometry[drag.pin].width))
        let slotStart = siblingRanges(of: drag.unit, pin: drag.pin).first { $0.id == draggedID }?.range.lowerBound ?? snapshot.frame.minX
        let slotX = min(max(slotStart, clip.lowerBound), max(clip.lowerBound, clip.upperBound - snapshot.frame.width))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            snapshot.animator().setFrameOrigin(NSPoint(x: slotX, y: snapshot.frame.minY))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.columnDrag?.snapshot === snapshot else {
                    snapshot.removeFromSuperview()
                    return
                }
                self.finishColumnDragLanding()
            }
        }
        // A drag that ends where it started moved nothing, but was a drag.
        reportColumnsMoved(from: drag.originalColumns, dragged: drag.columnIDs)
        reportColumnsDragged(drag.columnIDs)
    }

    /// The snapshot is an image of the columns at the table's height. If the
    /// table is resized while a column is dragged (only possible
    /// programmatically or by window tiling, as the mouse is busy), the drag
    /// ends right away at the current slot instead of showing a stretched image.
    func endColumnDragForResize() {
        guard let drag = columnDrag, abs(drag.snapshot.frame.maxY - bounds.height) > 0.5 else { return }
        if !drag.isLanding {
            resumeHeaderCursorRects()
            reportColumnsMoved(from: drag.originalColumns, dragged: drag.columnIDs)
            reportColumnsDragged(drag.columnIDs)
        }
        columnDrag?.isLanding = true
        finishColumnDragLanding()
    }

    /// Removes the landed snapshot and shows the real columns again. Called when
    /// the landing animation ends, or right away when a new press arrives first.
    func finishColumnDragLanding() {
        guard let drag = columnDrag, drag.isLanding else { return }
        drag.snapshot.removeFromSuperview()
        columnDrag = nil
        refreshAfterColumnMove()
    }

    // MARK: Cursor while columns move

    /// While columns move under the pointer (dragging, resizing), the resize
    /// cursor rects are rebuilt beneath it and AppKit can miss the exit, leaving a
    /// stale resize cursor. Cursor rects are therefore suspended during the
    /// interaction and rebuilt afterwards.
    /// Suspending and resuming always pair up, even if the table changed
    /// windows in between: the window that was disabled is the one re-enabled.
    private func suspendHeaderCursorRects(showing cursor: NSCursor) {
        if cursorRectsSuspendedWindow == nil, let window {
            window.disableCursorRects()
            cursorRectsSuspendedWindow = window
        }
        cursor.set()
    }

    private func resumeHeaderCursorRects() {
        NSCursor.arrow.set()
        if let suspended = cursorRectsSuspendedWindow {
            suspended.enableCursorRects()
            cursorRectsSuspendedWindow = nil
        }
        guard let window else { return }
        window.invalidateCursorRects(for: headerView)
        window.resetCursorRects()
    }

    /// Whether a header press, resize or column drag is in progress.
    var isHeaderInteracting: Bool {
        headerPress != nil || activeColumnResize != nil || (columnDrag.map { !$0.isLanding } ?? false)
    }

    /// Ends every header interaction at once, e.g. when the table leaves its
    /// window, or when a mouse up was lost (a context menu swallowed it).
    /// Columns moved by an unfinished drag stay where they are.
    func cancelHeaderInteraction() {
        headerPress = nil
        stopColumnDragScrolling()
        if let resize = activeColumnResize {
            activeColumnResize = nil
            // The width was applied live during the drag.
            if let column = columnLayout.columnsByID[resize.columnID], let width = width(ofColumnID: resize.columnID),
               width != resize.startWidth {
                autosaveLayoutState()
                delegate?.tableView(self, didResizeColumn: column, width: width)
            }
        }
        if let drag = columnDrag {
            drag.snapshot.removeFromSuperview()
            columnDrag = nil
            if !drag.isLanding {
                reportColumnsMoved(from: drag.originalColumns, dragged: drag.columnIDs)
                reportColumnsDragged(drag.columnIDs)
            }
        }
        stopColumnSlide()
        resumeHeaderCursorRects()
        refreshAfterColumnMove()
    }

    func stopColumnSlide() {
        columnSlideLink?.invalidate()
        columnSlideLink = nil
        columnSlideOffsets = [:]
        columnSlideStartOffsets = [:]
    }

    private func refreshAfterColumnMove() {
        layoutVisibleContent()
        headerView.needsDisplay = true
        summaryBar.contentView.needsDisplay = true
    }

    /// Viewport x of each column of a region.
    private func columnPositions(in pin: NGColumnPin, includingSlide: Bool) -> [String: CGFloat] {
        let origin = viewport.origin(of: pin)
        var positions: [String: CGFloat] = [:]
        for frame in geometry[pin].columns {
            let slide = includingSlide ? slideOffset(forColumnID: frame.column.id) : 0
            positions[frame.column.id] = origin + CGFloat(frame.x) + slide
        }
        return positions
    }

    // MARK: Column slide animation

    private static let columnSlideDuration: CFTimeInterval = 0.18

    /// Columns start where they were drawn and slide to their new positions.
    private func slideColumns(from before: [String: CGFloat], to after: [String: CGFloat]) {
        var offsets: [String: CGFloat] = [:]
        for (id, newX) in after {
            guard let oldX = before[id], abs(oldX - newX) > 0.5 else { continue }
            offsets[id] = oldX - newX
        }
        columnSlideStartOffsets = offsets
        columnSlideOffsets = offsets
        columnSlideStart = CACurrentMediaTime()
        if columnSlideLink == nil {
            let link = displayLink(target: self, selector: #selector(stepColumnSlide(_:)))
            link.add(to: .main, forMode: .common)
            columnSlideLink = link
        }
        refreshAfterColumnMove()
    }

    @objc func stepColumnSlide(_ link: CADisplayLink) {
        let progress = min(1, (CACurrentMediaTime() - columnSlideStart) / Self.columnSlideDuration)
        let remaining = pow(1 - progress, 3) // ease-out
        columnSlideOffsets = columnSlideStartOffsets.mapValues { $0 * remaining }
        if progress >= 1 {
            columnSlideOffsets = [:]
            columnSlideLink?.invalidate()
            columnSlideLink = nil
        }
        refreshAfterColumnMove()
    }

    // MARK: Tool tips

    /// Title areas of the visible columns that have a tool tip.
    func headerToolTipAreas() -> [NSRect] {
        let viewport = viewport
        let band = columnLayout.hasGroups ? groupHeaderHeight : 0
        var areas: [NSRect] = []
        for pin in drawingOrder {
            let region = geometry[pin]
            let clip = viewport.clipRange(of: pin, regionWidth: CGFloat(region.width))
            for frame in region.columns where frame.column.toolTip?.isEmpty == false {
                let minX = max(viewport.origin(of: pin) + CGFloat(frame.x), clip.lowerBound)
                let maxX = min(viewport.origin(of: pin) + CGFloat(frame.maxX), clip.upperBound)
                guard maxX > minX else { continue }
                areas.append(NSRect(x: minX, y: band, width: maxX - minX, height: headerView.bounds.height - band))
            }
        }
        return areas
    }

    func headerToolTip(at point: NSPoint) -> String? {
        column(atViewportPoint: point)?.frame.column.toolTip
    }

    /// The title area of the column with a tool tip at a point of the header.
    func headerToolTipRect(at point: NSPoint) -> NSRect? {
        guard !isDataUpdateActive else { return nil }
        return headerToolTipAreas().first { $0.contains(point) }
    }

    // MARK: Column resizing

    /// A column edge that can be dragged in the header.
    struct ResizeHandle {
        var frame: NGColumnFrame
        var pin: NGColumnPin
        /// Viewport x of the draggable edge.
        var edgeX: CGFloat
    }

    /// Leading and scrolling columns are resized from their trailing edge.
    /// Trailing frozen columns are resized from their leading edge: their block
    /// is anchored to the table's trailing edge, so it grows toward the content.
    private func resizeHandles() -> [ResizeHandle] {
        let viewport = viewport
        var handles: [ResizeHandle] = []
        for pin in drawingOrder.reversed() {
            let region = geometry[pin]
            guard !region.isEmpty else { continue }
            let range = viewport.clipRange(of: pin, regionWidth: CGFloat(region.width))
            let origin = viewport.origin(of: pin)
            for frame in region.columns where allowsColumnResizing && frame.column.isResizable {
                // The edge facing the scrolling content (mirrored right to left).
                let atMinX = (pin == .trailing) != isRightToLeft
                let edgeX = origin + CGFloat(atMinX ? frame.x : frame.maxX)
                // Allow the edge exactly at a region boundary (e.g. the last leading column).
                guard edgeX >= range.lowerBound - 1, edgeX <= range.upperBound + 1 else { continue }
                handles.append(ResizeHandle(frame: frame, pin: pin, edgeX: edgeX))
            }
        }
        // Scrolled to the end, the last scrolling column's edge meets the first
        // trailing column's edge. That is the only moment the scrolling column
        // can be resized, so its handle wins; the trailing one works elsewhere.
        let otherEdges = handles.filter { $0.pin != .trailing }.map(\.edgeX)
        return handles.filter { handle in
            handle.pin != .trailing || !otherEdges.contains { abs($0 - handle.edgeX) < 1 }
        }
    }

    private static let resizeHandleSlop: CGFloat = 4

    /// Vertical range of a column's handle: the leaf row for grouped columns,
    /// the full header height otherwise.
    private func resizeHandleRect(for handle: ResizeHandle, headerHeight: CGFloat) -> NSRect {
        let isGrouped = columnLayout.groupIDByColumnID[handle.frame.column.id] != nil
        let top = isGrouped ? groupHeaderHeight : 0
        let slop = Self.resizeHandleSlop
        return NSRect(x: handle.edgeX - slop, y: top, width: 2 * slop, height: headerHeight - top)
    }

    func resizeHandle(at point: NSPoint, headerHeight: CGFloat) -> ResizeHandle? {
        resizeHandles().first { resizeHandleRect(for: $0, headerHeight: headerHeight).contains(point) }
    }

    /// The resize cursor for a column edge at a point of the header, if any.
    func resizeCursor(at point: NSPoint) -> NSCursor? {
        resizeHandle(at: point, headerHeight: headerView.bounds.height).map(resizeCursor(for:))
    }

    func columnResizeCursorRects() -> [(NSRect, NSCursor)] {
        // Nothing to resize while the data updates.
        guard !isDataUpdateActive else { return [] }
        let height = headerView.bounds.height
        return resizeHandles().map { handle in
            (resizeHandleRect(for: handle, headerHeight: height), resizeCursor(for: handle))
        }
    }

    /// Shows which way the column can still go, like system tables.
    private func resizeCursor(for handle: ResizeHandle) -> NSCursor {
        guard #available(macOS 15.0, *) else { return .resizeLeftRight }
        let column = handle.frame.column
        let canGrow = handle.frame.width < column.maxWidth
        let canShrink = handle.frame.width > column.minWidth
        // For trailing columns dragging left grows them.
        let growsRight = (handle.pin != .trailing) != isRightToLeft
        var directions: NSHorizontalDirection.Set = []
        if canGrow { directions.insert(growsRight ? .right : .left) }
        if canShrink { directions.insert(growsRight ? .left : .right) }
        return directions.isEmpty ? .columnResize : .columnResize(directions: directions)
    }

    func headerMouseDown(_ event: NSEvent, in view: NSView) {
        // A new press right after a drop finishes the landing at once.
        finishColumnDragLanding()
        // A resize or drag still active here lost its mouse up (e.g. to a
        // context menu opened mid-drag): end it before starting anew.
        if isHeaderInteracting {
            cancelHeaderInteraction()
        }
        let point = view.convert(event.locationInWindow, from: nil)
        if let handle = resizeHandle(at: point, headerHeight: view.bounds.height) {
            // Double-clicking an edge fits the column to its content, like system tables.
            if event.clickCount == 2 {
                let columnID = handle.frame.column.id
                let oldWidth = handle.frame.width
                let index = column(withIdentifier: NSUserInterfaceItemIdentifier(columnID))
                if let width = delegate?.tableView(self, sizeToFitWidthOfColumn: index) {
                    setWidth(Double(width), forColumnID: columnID)
                } else {
                    sizeColumnToFit(columnID)
                }
                // The edge moved away from the pointer.
                resumeHeaderCursorRects()
                if let column = columnLayout.columnsByID[columnID], let width = width(ofColumnID: columnID),
                   width != oldWidth {
                    autosaveLayoutState()
                    delegate?.tableView(self, didResizeColumn: column, width: width)
                }
                return
            }
            activeColumnResize = ColumnResize(
                columnID: handle.frame.column.id,
                pin: handle.pin,
                startX: event.locationInWindow.x,
                startWidth: handle.frame.width
            )
            // Keep the resize cursor for the whole drag, wherever the pointer goes.
            suspendHeaderCursorRects(showing: resizeCursor(for: handle))
            return
        }
        // Sorting happens on mouse up, so a press can still turn into a drag.
        guard let (frame, pin) = column(atViewportPoint: point) else { return }
        let column = frame.column
        // The filter button opens the column's filter instead.
        if showsFilterButton(for: column, width: frame.width) {
            let band = columnLayout.hasGroups ? groupHeaderHeight : 0
            let title = NSRect(x: viewport.origin(of: pin) + CGFloat(frame.x) + slideOffset(forColumnID: column.id), y: band,
                               width: CGFloat(frame.width), height: view.bounds.height - band)
            let button = filterButtonRect(inTitleRect: title)
            if button.insetBy(dx: -2, dy: 0).contains(point) {
                showColumnFilter(for: column, relativeTo: button, of: view)
                return
            }
        }
        // The group band is not part of the leaf column below it.
        let isGrouped = columnLayout.groupIDByColumnID[column.id] != nil
        let isOnLeafTitle = !(isGrouped && point.y < groupHeaderHeight)
        if isOnLeafTitle { delegate?.tableView(self, mouseDownInHeaderOf: column) }
        headerPress = HeaderPress(
            startLocation: event.locationInWindow,
            columnID: isOnLeafTitle ? column.id : nil,
            sortColumnID: isOnLeafTitle && column.isSortable ? column.id : nil,
            reorderUnit: allowsColumnReordering && column.isMovable ? reorderUnit(for: column, pointY: point.y) : nil,
            pin: pin
        )
    }

    func headerMouseDragged(_ event: NSEvent) {
        if let resize = activeColumnResize {
            let delta = Double(event.locationInWindow.x - resize.startX)
            // Dragging away from the column's other edge widens it.
            let grows = (resize.pin != .trailing) != isRightToLeft
            setWidth(resize.startWidth + (grows ? delta : -delta), forColumnID: resize.columnID)
            return
        }

        let pointerX = headerView.convert(event.locationInWindow, from: nil).x
        if let drag = columnDrag, !drag.isLanding {
            moveColumnDrag(drag, pointerX: pointerX)
            return
        }
        // A press becomes a column drag once the pointer has moved a little.
        guard let press = headerPress, let unit = press.reorderUnit,
              abs(event.locationInWindow.x - press.startLocation.x) > 3 else { return }
        headerPress = nil
        let startX = headerView.convert(press.startLocation, from: nil).x
        beginColumnDrag(unit: unit, pin: press.pin, pointerX: startX)
        if let drag = columnDrag {
            moveColumnDrag(drag, pointerX: pointerX)
        }
    }

    func headerMouseUp(_ event: NSEvent) {
        if let resize = activeColumnResize {
            activeColumnResize = nil
            resumeHeaderCursorRects()
            // A click on the edge without moving it is not a resize.
            if let column = columnLayout.columnsByID[resize.columnID], let width = width(ofColumnID: resize.columnID),
               width != resize.startWidth {
                autosaveLayoutState()
                delegate?.tableView(self, didResizeColumn: column, width: width)
            }
            return
        }
        if let drag = columnDrag, !drag.isLanding {
            endColumnDrag(drag)
            return
        }
        if let press = headerPress {
            headerPress = nil
            // Like a button: releasing elsewhere cancels the click.
            let point = headerView.convert(event.locationInWindow, from: nil)
            if let columnID = press.columnID, headerView.bounds.contains(point),
               let column = column(atViewportPoint: point)?.frame.column, column.id == columnID {
                if allowsColumnSelection {
                    selectColumnByClicking(column, modifiers: event.modifierFlags)
                }
                if press.sortColumnID == columnID {
                    sortByClicking(column)
                }
                delegate?.tableView(self, didClick: column)
            }
        }
    }
}
#endif
