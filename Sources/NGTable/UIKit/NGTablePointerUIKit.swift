#if os(iOS)
import UIKit

// A trackpad's or a mouse's pointer on the iPad: the cell under it
// (`hoveredCell`, the delegate's enter and exit calls, a media cell's motion,
// a link or button lit, an editable rating's preview), found again when the
// rows scroll under a resting pointer; over a column's edge in the header
// the pointer becomes a beam to drag.

extension NGTableView {
    /// The pointer moved (`nil`: it left the table), in the table's coordinates.
    func pointerMoved(to point: CGPoint?) {
        guard let point, bounds.contains(point) else {
            updateHoveredCell(atWindowPoint: nil)
            return
        }
        updateHoveredCell(atWindowPoint: convert(point, to: nil))
    }

    /// Finds the cell under a resting pointer again (the rows moved under it).
    func updateHoveredCellFromPointer() {
        // Not in a layout pass: the delegate's enter and exit calls may change the cells.
        if isInLayoutPass {
            scheduleHoverUpdate()
            return
        }
        guard let location = pointerWindowLocation, window != nil else {
            setHoveredCell(nil)
            return
        }
        updateHoveredCell(atWindowPoint: location)
    }

    /// The control under the pointer shows it (a link lit, a rating's preview).
    func syncControlUnderPointer() {
        var cell: NGDrawnCell?
        if let hoveredCell, let visible = visibleCell(sourceRow: hoveredCell.row, columnID: hoveredCell.columnID),
           Self.isControl(visible.content) {
            cell = visible
            if case .rating(_, let maximum, _, let alignment) = visible.content, let location = pointerWindowLocation {
                visible.previewRating = rating(atWindowLocation: location, maximum: maximum, alignment: alignment,
                                               row: hoveredCell.row, columnID: hoveredCell.columnID)
            }
        }
        if pointerOverCell !== cell {
            pointerOverCell?.isPointerOver = false
            pointerOverCell = cell
        }
        cell?.isPointerOver = true
    }

    /// Over a column's edge in the header: a vertical beam, held to the edge.
    func pointerRegion(at point: CGPoint) -> UIPointerRegion? {
        let headerHeight = layoutMetrics.headerHeight
        guard !hidesHeader, point.y < headerHeight, let handle = resizeHandle(at: point, headerHeight: headerHeight) else { return nil }
        return UIPointerRegion(rect: CGRect(x: handle.edgeX - 6, y: 0, width: 12, height: headerHeight), identifier: handle.frame.column.id as NSString)
    }
}

extension NGTouchScrollDelegate: UIPointerInteractionDelegate {
    @objc func hovered(_ hover: UIHoverGestureRecognizer) {
        guard let table else { return }
        switch hover.state {
        case .began, .changed:
            table.pointerMoved(to: hover.location(in: table))
        default:
            table.pointerMoved(to: nil)
        }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        table?.pointerRegion(at: request.location)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: .verticalBeam(length: region.rect.height), constrainedAxes: .horizontal)
    }
}
#endif
