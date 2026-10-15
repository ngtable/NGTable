#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// NSTableView's API for rows and columns that the rest of NGTable doesn't
// need itself: hiding rows, the frames of rows and columns, which rows and
// columns a rect covers, scrolling a column into view and moving a column.
// As elsewhere, row indexes are data source rows and column indexes are
// indexes in `tableColumns`. Hidden rows are part of the filter: they leave
// the display like rows the `rowFilter` rejects, and are kept by row handle,
// so they follow their records through inserts, removes and moves.

extension NGTableView {
    // MARK: Hidden rows

    /// Data source rows hidden with `hideRows(at:withAnimation:)`, like
    /// NSTableView's.
    public var hiddenRowIndexes: IndexSet {
        rowHandles.indexes(of: hiddenRowHandles.lazy.map { Int32(truncatingIfNeeded: $0) })
    }

    /// Hides rows, like NSTableView's: they leave the display, the selection,
    /// the summaries and copying, like rows the `rowFilter` rejects, and stay
    /// hidden as other rows come and go; `reloadData()` keeps the same row
    /// indexes hidden. With `rowAnimation`, they go like removed rows (see
    /// `NGRowAnimation.Effect`) and the rows after them slide up.
    public func hideRows(at indexes: IndexSet, withAnimation rowAnimation: NSTableView.AnimationOptions = []) {
        var changed: [Int] = []
        for row in Self.clamped(indexes, to: numberOfSourceRows) {
            let handle = handle(ofRow: row)
            if hiddenRowHandles.insert(handle).inserted { changed.append(handle) }
        }
        changeShownRows(changed, revealing: false, animation: rowAnimation)
    }

    /// Shows rows hidden with `hideRows(at:withAnimation:)` again, like
    /// NSTableView's. With `rowAnimation`, they come like inserted rows.
    public func unhideRows(at indexes: IndexSet, withAnimation rowAnimation: NSTableView.AnimationOptions = []) {
        var changed: [Int] = []
        for row in Self.clamped(indexes, to: numberOfSourceRows) {
            let handle = handle(ofRow: row)
            if hiddenRowHandles.remove(handle) != nil { changed.append(handle) }
        }
        changeShownRows(changed, revealing: true, animation: rowAnimation)
    }

    /// Shows the rows hidden or shown again: at once, or, with an animation,
    /// in a batch that filters them again (they go and come like removed
    /// and inserted rows, the others slide).
    private func changeShownRows(_ handles: [Int], revealing: Bool, animation: NSTableView.AnimationOptions) {
        guard !handles.isEmpty else { return }
        filterNeedsFullEvaluation = true
        guard !animation.isEmpty else {
            applyRowFilter()
            return
        }
        beginUpdates()
        if rowUpdateBatch != nil {
            rowUpdateBatch!.animates = true
            if rowUpdateBatch!.animationOptions.isEmpty { rowUpdateBatch!.animationOptions = animation }
            rowUpdateBatch!.pendingDirtyRows.append(contentsOf: handles.map { Int32(truncatingIfNeeded: $0) })
            if revealing { rowUpdateBatch!.revealedRows.formUnion(IndexSet(handles)) }
        }
        endUpdates()
    }

    // MARK: Frames

    /// The rows area: between the header and the summary row.
    private var rowsArea: CGRect {
        let metrics = layoutMetrics
        return CGRect(x: 0, y: metrics.headerHeight, width: bounds.width,
                      height: max(0, bounds.height - metrics.headerHeight - metrics.summaryHeight))
    }

    /// The frame of a row in the table's coordinates, across the table, like
    /// NSTableView's `rect(ofRow:)`: rows scrolled out of view give frames
    /// outside the visible area. `NSZeroRect` for a row that isn't shown
    /// (filtered out, hidden, in a collapsed group, out of range).
    public func rect(ofRow row: Int) -> CGRect {
        guard let displayRow = displayRow(forSourceRow: row), displayRow < numberOfRows else { return .zero }
        let inCanvas = CGRect(x: 0, y: rowGeometry.top(of: displayRow), width: 1, height: rowGeometry.height(of: displayRow))
        let frame = convert(inCanvas, from: centerRegion.canvas)
        return CGRect(x: 0, y: frame.minY, width: bounds.width, height: rowGeometry.height(of: displayRow))
    }

    /// The frame of a column in the table's coordinates, over the rows area
    /// (between the header and the summary row), like NSTableView's
    /// `rect(ofColumn:)`: a scrolling column scrolled out of view gives a
    /// frame outside the visible area. `NSZeroRect` for a hidden column or an
    /// index out of range.
    public func rect(ofColumn column: Int) -> CGRect {
        let all = tableColumns
        guard column >= 0, column < all.count else { return .zero }
        let id = all[column].id
        for (pin, region) in [(NGColumnPin.leading, leadingRegion), (.none, centerRegion), (.trailing, trailingRegion)] {
            guard let frame = geometry[pin].columns.first(where: { $0.column.id == id }) else { continue }
            let x = convert(CGPoint(x: CGFloat(frame.x) + slideOffset(forColumnID: id), y: 0), from: region.canvas).x
            let area = rowsArea
            return CGRect(x: x, y: area.minY, width: CGFloat(frame.width), height: area.height)
        }
        return .zero
    }

    /// The data source rows shown in a rect of the table's coordinates (rows
    /// scrolled out of view included, if the rect reaches them), like
    /// NSTableView's `rows(in:)`, as row indexes rather than a range: shown
    /// rows needn't be consecutive data source rows (filter, sort, groups).
    public func rowIndexes(in rect: CGRect) -> IndexSet {
        guard rowHeight > 0, numberOfRows > 0, !rect.isEmpty else { return [] }
        let inCanvas = convert(rect, to: centerRegion.canvas)
        let rowLayout = rowGeometry
        let first = max(0, Int(rowLayout.position(atY: inCanvas.minY).rounded(.down)))
        let end = min(numberOfRows, Int(rowLayout.position(atY: inCanvas.maxY).rounded(.up)))
        guard first < end else { return [] }
        var rows = IndexSet(integersIn: first..<end)
        // Rows whose visible part is all under floating group headers aren't
        // shown there (rows scrolled out of view above are, as before).
        if groupedDisplay != nil {
            let top = contentOffset.y
            let coverEnd = top + floatingHeadersCover(atOffset: top, except: -1)
            if coverEnd > top {
                let hidden = Int(rowLayout.position(atY: top).rounded(.down))..<Int(rowLayout.position(atY: coverEnd).rounded(.down))
                for row in hidden where rowLayout.bottom(of: row) > top { rows.remove(row) }
            }
        }
        return sourceRows(forDisplayRows: rows)
    }

    /// The columns (indexes in `tableColumns`) a rect of the table's
    /// coordinates covers horizontally, like NSTableView's `columnIndexes(in:)`.
    public func columnIndexes(in rect: CGRect) -> IndexSet {
        var indexes = IndexSet()
        for column in tableColumns.indices {
            let frame = self.rect(ofColumn: column)
            if !frame.isEmpty, frame.minX < rect.maxX, frame.maxX > rect.minX { indexes.insert(column) }
        }
        return indexes
    }

    // MARK: Columns

    /// Where a scrolling column is in scroll offsets: `contentOffset.x` puts
    /// `start` at the leading edge of the scrolling area (the left, or right to
    /// left the right), `end` its other edge.
    func scrollSpan(of frame: NGColumnFrame) -> (start: CGFloat, end: CGFloat) {
        let leadingWidth = geometry.leading.width
        if isRightToLeft {
            // Mirrored: measured from the right end of the scrolling columns.
            let end = leadingWidth + max(geometry.center.width, Double(mirroredCenterSpan))
            return (CGFloat(end - frame.maxX), CGFloat(end - frame.x))
        }
        return (CGFloat(frame.x - leadingWidth), CGFloat(frame.maxX - leadingWidth))
    }

    /// Scrolls horizontally so the column is in view, like NSTableView's.
    /// Frozen columns are always in view; hidden ones can't be.
    public func scrollColumnToVisible(_ column: Int) {
        let all = tableColumns
        guard column >= 0, column < all.count,
              let frame = geometry.center.columns.first(where: { $0.column.id == all[column].id }) else { return }
        // The column's span in scroll offsets (from the leading end).
        let (minX, maxX) = scrollSpan(of: frame)
        let visibleWidth = centerRegion.frame.width
        var x = contentOffset.x
        if minX < x {
            // The first column scrolls back to the start, edge margin included.
            x = frame.column.id == columnLayout.center.columns.first?.id ? 0 : minX
        } else if maxX > x + visibleWidth {
            x = maxX - visibleWidth
        }
        setContentOffset(CGPoint(x: min(max(0, x), layoutMetrics.maxOffset.x), y: contentOffset.y))
    }

    /// Moves a column to another index of `tableColumns`, like NSTableView's
    /// `moveColumn(_:toColumn:)`, and posts `columnDidMoveNotification`.
    /// Like a drag, a move keeps groups together and columns in their region
    /// (frozen or not): a column of a group moves within it, an ungrouped
    /// column moves past whole groups. Other moves are ignored.
    public func moveColumn(_ oldIndex: Int, toColumn newIndex: Int) {
        let all = tableColumns
        guard oldIndex != newIndex, all.indices.contains(oldIndex), all.indices.contains(newIndex) else { return }
        let id = all[oldIndex].id, targetID = all[newIndex].id
        let groupOf: (String) -> String? = { columnID in
            self.columns.first { $0.leafColumns.contains { $0.id == columnID } && $0.id != columnID }?.id
        }
        let unit: NGColumnReorder.Unit
        let target: String
        if let groupID = groupOf(id) {
            unit = .member(columnID: id, groupID: groupID)
            target = targetID
        } else {
            unit = .item(id: id)
            target = groupOf(targetID) ?? targetID
        }
        let others = NGColumnReorder.siblings(of: unit, in: columns).filter { $0 != id }
        guard let position = others.firstIndex(of: target) else { return }
        let original = columns
        // After the target when moving forward, before it when moving back.
        applyReorderedColumns(NGColumnReorder.moving(unit, to: oldIndex < newIndex ? position + 1 : position, in: columns))
        reportColumnsMoved(from: original, dragged: [id])
    }
}
#endif
