#if os(iOS)
import UIKit

// Dragging rows and dropping on them on the iPad, like a UITableView's drag
// and drop delegates: a long press lifts the row (with the selected rows, if
// it's one of them) as the data source's items; a drag over the rows shows
// where it would drop (a line, a gap or a highlight, as on the Mac), and the
// rows scroll while it stays near the top or bottom.

extension NGTableView {
    /// The items a drag from a point lifts; the rows they're of are noted
    /// (`draggedRowIndexes`).
    func dragItems(at point: CGPoint, session: any UIDragSession) -> [(item: UIDragItem, displayRow: Int)] {
        guard let dataSource, !ignoresUserInput, !isEditingCell, point.y >= layoutMetrics.headerHeight,
              point.y < bounds.height - layoutMetrics.summaryHeight else { return [] }
        let row = row(atWindowLocation: convert(point, to: nil))
        guard row >= 0, row < numberOfRows, !isGroupRow(row) else { return [] }
        let pressed = dataSource.tableView(self, itemsForBeginning: session, row: sourceRow(row))
        guard !pressed.isEmpty else { return [] }
        var items = pressed.map { ($0, row) }
        var rows = IndexSet([sourceRow(row)])
        // One of several selected rows: they all go.
        if allowsMultipleSelection, displaySelection.contains(row), displaySelection.count > 1 {
            for other in displaySelection where other != row && !isGroupRow(other) {
                let more = dataSource.tableView(self, itemsForBeginning: session, row: sourceRow(other))
                if !more.isEmpty { rows.insert(sourceRow(other)) }
                items += more.map { ($0, other) }
            }
        }
        noteDraggedRows(rows)
        return items
    }

    /// A row lifted: its snapshot where it is.
    func dragPreview(ofDisplayRow row: Int) -> UITargetedDragPreview? {
        guard row >= 0, row < numberOfRows else { return nil }
        let metrics = layoutMetrics
        let rect = CGRect(x: 0, y: pixelAligned(metrics.headerHeight - renderedOffsetY) + rowGeometry.top(of: row),
                          width: bounds.width, height: rowGeometry.height(of: row)).intersection(bounds)
        guard !rect.isEmpty, let snapshot = resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerRadius: 6)
        parameters.backgroundColor = metalStyle.background
        return UITargetedDragPreview(view: snapshot, parameters: parameters,
                                     target: UIDragPreviewTarget(container: self, center: CGPoint(x: rect.midX, y: rect.midY)))
    }

    /// A drag over the rows at a point: where it would drop, as the data
    /// source sees it (`.forbidden`: nowhere).
    func updateDrop(_ session: any UIDropSession, at point: CGPoint) -> UIDropOperation {
        guard let dataSource, !ignoresUserInput else {
            showDropIndicator(nil)
            return .forbidden
        }
        let location = convert(point, to: nil)
        var target = proposedDrop(atWindowPoint: location)
        dropRetarget = nil
        let operation = dataSource.tableView(self, dropSessionDidUpdate: session, proposedRow: target.row, proposedDropOperation: target.operation)
        if let retarget = dropRetarget.take() { target = retarget }
        let drops = operation == .copy || operation == .move
        showDropIndicator(drops ? target : nil)
        updateDropScrolling(session, at: location)
        return operation
    }

    /// The drop, where the last update put it.
    func performDrop(_ session: any UIDropSession, at point: CGPoint) -> Bool {
        let operation = updateDrop(session, at: point)
        endDropScrolling()
        defer { showDropIndicator(nil) }
        guard let dataSource, operation == .copy || operation == .move, let row = dropIndicatorRow else { return false }
        return dataSource.tableView(self, performDrop: session, row: row, dropOperation: dropIndicatorOperation)
    }

    /// The drag left the rows, or ended.
    func endDrop() {
        endDropScrolling()
        showDropIndicator(nil)
    }

    private func updateDropScrolling(_ session: any UIDropSession, at location: CGPoint) {
        guard dropScrollOverflow(atWindowPoint: location) != 0 else {
            endDropScrolling()
            return
        }
        dropScrollSession = session
        dropScrollPoint = location
        guard dropScrollLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(stepDropScroll(_:)))
        link.add(to: .main, forMode: .common)
        dropScrollLink = link
    }

    @objc private func stepDropScroll(_ link: CADisplayLink) {
        guard let session = dropScrollSession, let location = dropScrollPoint else {
            endDropScrolling()
            return
        }
        let overflow = dropScrollOverflow(atWindowPoint: location)
        guard overflow != 0 else {
            endDropScrolling()
            return
        }
        scrollForDrop(overflow, link: link)
        // The rows moved under the finger: the drop target too.
        _ = updateDrop(session, at: convert(location, from: nil))
    }

    func endDropScrolling() {
        dropScrollLink?.invalidate()
        dropScrollLink = nil
        dropScrollSession = nil
        dropScrollPoint = nil
    }
}

extension NGTouchScrollDelegate: UIDragInteractionDelegate, UIDropInteractionDelegate {
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        guard let table else { return [] }
        let items = table.dragItems(at: session.location(in: table), session: session)
        dragItemRows = Dictionary(items.map { (ObjectIdentifier($0.item), $0.displayRow) }, uniquingKeysWith: { first, _ in first })
        return items.map(\.item)
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
                         session: any UIDragSession) -> UITargetedDragPreview? {
        guard let row = dragItemRows[ObjectIdentifier(item)] else { return nil }
        return table?.dragPreview(ofDisplayRow: row)
    }

    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
        dragItemRows = [:]
        table?.draggedRowRefs = []
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        table?.dataSource != nil
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        guard let table else { return UIDropProposal(operation: .cancel) }
        return UIDropProposal(operation: table.updateDrop(session, at: session.location(in: table)))
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        guard let table else { return }
        _ = table.performDrop(session, at: session.location(in: table))
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        table?.endDrop()
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        table?.endDrop()
    }
}
#endif
