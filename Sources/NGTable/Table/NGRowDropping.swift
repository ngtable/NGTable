#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Dropping onto the rows, for both platforms (the Mac's dragging
// destination in NGRowDragging.swift, the iPad's drop interaction in
// NGRowDraggingUIKit.swift): where a drop at a point goes, the line, gap or
// highlight that shows it, and scrolling while a drag stays near an edge.

extension NGTableView {
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

    /// Where a drop at a point goes: above a data source row (or at the end).
    func dropRow(atWindowPoint location: CGPoint) -> Int {
        let y = centerRegion.canvas.convert(location, from: nil).y
        let displayRow = min(max(Int(rowGeometry.position(atY: y).rounded()), 0), numberOfRows)
        var next = displayRow
        while next < numberOfRows, isGroupRow(next) { next += 1 }
        return next < numberOfRows ? sourceRow(next) : numberOfSourceRows
    }

    /// Where a drop at a point goes, like NSTableView proposes it: onto a row
    /// over its middle half, else above the row nearest the pointer.
    func proposedDrop(atWindowPoint location: CGPoint) -> (row: Int, operation: NSTableView.DropOperation) {
        let position = rowGeometry.position(atY: centerRegion.canvas.convert(location, from: nil).y)
        let displayRow = Int(floor(position))
        let fraction = position - floor(position)
        if displayRow >= 0, displayRow < numberOfRows, !isGroupRow(displayRow), fraction > 0.25, fraction < 0.75 {
            return (sourceRow(displayRow), .on)
        }
        return (dropRow(atWindowPoint: location), .above)
    }

    /// Retargets the drop being validated, like NSTableView's: from
    /// `tableView(_:validateDrop:proposedRow:proposedDropOperation:)`, e.g.
    /// `.above` instead of `.on` for a list that only reorders, or row -1
    /// with `.on` for the whole table.
    public func setDropRow(_ row: Int, dropOperation: NSTableView.DropOperation) {
        dropRetarget = (row, dropOperation)
    }

    /// Shows where a drop would go (`nil`: nowhere).
    func showDropIndicator(_ target: (row: Int, operation: NSTableView.DropOperation)?) {
        if target?.row != dropIndicatorRow || (target != nil && target?.operation != dropIndicatorOperation) {
            dropIndicatorRow = target?.row
            dropIndicatorOperation = target?.operation ?? .above
            setNeedsMetalFrame()
        }
        updateDropGap()
    }

    /// How far into the band along the top (negative) or bottom (positive)
    /// edge of the rows a drag is, like NSTableView scrolling under a drag.
    func dropScrollOverflow(atWindowPoint location: CGPoint) -> CGFloat {
        let y = convert(location, from: nil).y
        let metrics = layoutMetrics
        let band = rowHeight
        let top = metrics.headerHeight + band
        let bottom = bounds.height - metrics.summaryHeight - band
        if y < top { return y - top }
        if y > bottom { return y - bottom }
        return 0
    }

    /// A frame's step of scrolling under a drag, faster deeper into the band
    /// and past it (points per second).
    func scrollForDrop(_ overflow: CGFloat, link: CADisplayLink) {
        let speed = min(abs(overflow) * 16 + 80, 3000)
        let elapsed = min(max(link.targetTimestamp - link.timestamp, 1.0 / 120), 1.0 / 30)
        setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y + (overflow < 0 ? -speed : speed) * elapsed))
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
        let animates = dropGap != nil && window != nil && !NGSystem.reducesMotion
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
        let rows = CGRect(x: 0, y: layoutMetrics.headerHeight, width: bounds.width,
                          height: max(0, bounds.height - layoutMetrics.headerHeight - layoutMetrics.summaryHeight))
        if dropIndicatorOperation == .on {
            if row < 0 {
                // The whole table: a frame around the rows.
                let frame = rows.insetBy(dx: 1, dy: 1)
                for edge in [CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 2),
                             CGRect(x: frame.minX, y: frame.maxY - 2, width: frame.width, height: 2),
                             CGRect(x: frame.minX, y: frame.minY, width: 2, height: frame.height),
                             CGRect(x: frame.maxX - 2, y: frame.minY, width: 2, height: frame.height)] {
                    quads.append(NGMetalRenderer.rectangle(edge, scale: scale, color: color, clip: rows))
                }
            } else if let displayRow = displayRow(forSourceRow: row) {
                let y = convert(CGPoint(x: 0, y: rowGeometry.top(of: displayRow)), from: centerRegion.canvas).y
                let inset = selectionHighlightStyle == .rounded ? NGMetrics.selectionInset : 0
                let frame = CGRect(x: inset, y: y, width: bounds.width - 2 * inset, height: rowGeometry.height(of: displayRow))
                quads.append(NGMetalRenderer.roundedRectangle(frame, radius: inset > 0 ? NGMetrics.selectionCornerRadius : 0, corners: allCorners,
                                                              scale: scale, color: color * 0.3, clip: frame.intersection(rows)))
            }
            return
        }
        let displayRow = row < numberOfSourceRows ? self.displayRow(forSourceRow: row) ?? numberOfRows : numberOfRows
        let y = convert(CGPoint(x: 0, y: rowGeometry.top(of: displayRow)), from: centerRegion.canvas).y
        quads.append(NGMetalRenderer.roundedRectangle(CGRect(x: 8, y: y - 1, width: bounds.width - 16, height: 2), radius: 1,
                                                      corners: allCorners, scale: scale, color: color))
    }
}
#endif
