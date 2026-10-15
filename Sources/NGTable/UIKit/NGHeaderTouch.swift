#if os(iOS)
import UIKit

// The header under a finger: dragging a column's edge resizes it (a double
// tap there fits it to its content); dragging its title moves it, lifted
// while the others slide aside, the table scrolling at the edges. A tap
// sorts and a long press opens the header's menu, as before; the header
// doesn't scroll, so a pan in it is the columns'.

extension NGTableView {
    /// Whether a pan starting at a point resizes or moves columns.
    func headerPanShouldBegin(at point: CGPoint) -> Bool {
        let headerHeight = layoutMetrics.headerHeight
        guard !ignoresUserInput, !hidesHeader, !isEditingCell, point.y >= 0, point.y < headerHeight else { return false }
        if resizeHandle(at: point, headerHeight: headerHeight) != nil { return true }
        guard allowsColumnReordering, let column = column(atViewportPoint: point)?.frame.column else { return false }
        return column.isMovable
    }

    func headerPanBegan(at point: CGPoint) {
        // A new pan right after a drop finishes the landing at once.
        finishColumnDragLanding()
        if isHeaderInteracting { cancelHeaderInteraction() }
        if let handle = resizeHandle(at: point, headerHeight: layoutMetrics.headerHeight) {
            activeColumnResize = ColumnResize(columnID: handle.frame.column.id, pin: handle.pin, startX: point.x, startWidth: handle.frame.width)
            return
        }
        guard allowsColumnReordering, let (frame, pin) = column(atViewportPoint: point), frame.column.isMovable else { return }
        beginColumnDrag(unit: reorderUnit(for: frame.column, pointY: point.y), pin: pin, pointerX: point.x)
    }

    func headerPanChanged(to point: CGPoint) {
        if let resize = activeColumnResize {
            // Dragging away from the column's other edge widens it.
            let delta = Double(point.x - resize.startX)
            let grows = (resize.pin != .trailing) != isRightToLeft
            setWidth(resize.startWidth + (grows ? delta : -delta), forColumnID: resize.columnID)
            return
        }
        if let drag = columnDrag, !drag.isLanding { moveColumnDrag(drag, pointerX: point.x) }
    }

    func headerPanEnded() {
        if let resize = activeColumnResize {
            activeColumnResize = nil
            if let column = columnLayout.columnsByID[resize.columnID], let width = width(ofColumnID: resize.columnID),
               width != resize.startWidth {
                autosaveLayoutState()
                delegate?.tableView(self, didResizeColumn: column, width: width)
            }
            return
        }
        if let drag = columnDrag, !drag.isLanding { endColumnDrag(drag) }
    }

    /// A double tap on a column's edge fits it; `false` elsewhere.
    func fitColumn(atHeaderPoint point: CGPoint) -> Bool {
        guard !ignoresUserInput, let handle = resizeHandle(at: point, headerHeight: layoutMetrics.headerHeight) else { return false }
        fitColumnByUser(handle)
        return true
    }

    /// The dragged columns as they show (cut to the table), lifted: an
    /// opaque base, a shadow, a little transparent.
    func columnDragSnapshot(of rect: CGRect) -> UIView {
        let lifted = UIView(frame: rect)
        lifted.backgroundColor = metalStyle.background
        lifted.alpha = 0.9
        lifted.layer.shadowColor = UIColor.black.cgColor
        lifted.layer.shadowOpacity = 0.3
        lifted.layer.shadowRadius = 8
        lifted.layer.shadowOffset = CGSize(width: 0, height: 2)
        let visible = rect.intersection(bounds)
        if !visible.isEmpty, let snapshot = resizableSnapshotView(from: visible, afterScreenUpdates: false, withCapInsets: .zero) {
            snapshot.frame = visible.offsetBy(dx: -rect.minX, dy: -rect.minY)
            lifted.addSubview(snapshot)
        }
        return lifted
    }
}

/// The header's pan (resizing and moving columns).
final class NGHeaderPanRecognizer: UIPanGestureRecognizer {}

extension NGTouchScrollDelegate: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if let swipe = recognizer as? NGRowSwipeRecognizer, let table {
            let point = swipe.location(in: table)
            let translation = swipe.translation(in: table)
            return table.rowSwipeShouldBegin(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y),
                                             velocity: swipe.velocity(in: table))
        }
        guard let table, let pan = recognizer as? NGHeaderPanRecognizer else { return true }
        // Where the finger went down (the pan begins after it moved a little).
        let point = pan.location(in: table)
        let translation = pan.translation(in: table)
        return table.headerPanShouldBegin(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y))
    }

    @objc func headerPanned(_ pan: NGHeaderPanRecognizer) {
        guard let table else { return }
        let point = pan.location(in: table)
        switch pan.state {
        case .began:
            let translation = pan.translation(in: table)
            table.headerPanBegan(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y))
            table.headerPanChanged(to: point)
        case .changed:
            table.headerPanChanged(to: point)
        case .ended, .cancelled, .failed:
            table.headerPanEnded()
        default:
            break
        }
    }
}
#endif
