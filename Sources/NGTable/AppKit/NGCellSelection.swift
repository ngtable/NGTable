#if os(macOS)
import AppKit

// Cell ranges, like a spreadsheet's, with navigation by cell: Shift with the
// arrow keys, a Shift-click or a drag extends a rectangle of cells from the
// focused cell. The range is kept as its two corner cells (data source rows
// and column ids), so it spans the rows and columns between them as shown
// now, also after a sort. Its rows are the selected rows (summaries of the
// selection cover them); it's tinted under the cells' content, and Copy
// copies its block of cells.

/// A rectangle of cells between two corners (see `NGTableView.selectedCellRange`).
public struct NGCellRange: Hashable, Sendable {
    /// Where the range started (the focused cell when it was made).
    public var anchor: NGCellPosition
    /// The opposite corner.
    public var end: NGCellPosition

    public init(anchor: NGCellPosition, end: NGCellPosition) {
        self.anchor = anchor
        self.end = end
    }
}

/// A cell by its row's record (see `NGRowRef`): it follows its record, and
/// is gone with it.
struct NGHandleCell: Hashable {
    let ref: NGRowRef
    let columnID: String
}

extension NGTableView {
    /// The data source cell of a handle cell, or `nil` if its record is gone.
    func position(of cell: NGHandleCell) -> NGCellPosition? {
        let row = row(of: cell.ref)
        return row >= 0 ? NGCellPosition(row: row, columnID: cell.columnID) : nil
    }

    /// The handle cell of a data source cell, or `nil` out of range.
    func handleCell(of position: NGCellPosition) -> NGHandleCell? {
        guard position.row >= 0, position.row < numberOfSourceRows else { return nil }
        return NGHandleCell(ref: rowRef(ofRow: position.row), columnID: position.columnID)
    }

    /// The range's display rows and visible column indexes (in display
    /// order), or `nil` when a corner isn't shown.
    func cellRangeBounds(_ range: NGCellRange) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>, columnIDs: [String])? {
        let columns = columnLayout.allColumns
        guard let anchorRow = displayRow(forSourceRow: range.anchor.row), let endRow = displayRow(forSourceRow: range.end.row),
              let anchorColumn = columns.firstIndex(where: { $0.id == range.anchor.columnID }),
              let endColumn = columns.firstIndex(where: { $0.id == range.end.columnID }) else { return nil }
        let columnRange = min(anchorColumn, endColumn)...max(anchorColumn, endColumn)
        return (min(anchorRow, endRow)...max(anchorRow, endRow), columnRange, columnRange.map { columns[$0].id })
    }

    /// Extends the cell range from the focused cell (or the range's anchor) to
    /// a cell, and selects its rows.
    func extendCellRange(toDisplayRow displayRow: Int, columnID: String) {
        let row = sourceRow(displayRow)
        guard row >= 0 else { return }
        let anchor = selectedCellRange?.anchor ?? focusedCell ?? NGCellPosition(row: row, columnID: columnID)
        let range = NGCellRange(anchor: anchor, end: NGCellPosition(row: row, columnID: columnID))
        selectedCellRange = range == NGCellRange(anchor: anchor, end: anchor) ? nil : range
        focusedCell = anchor
        if let bounds = selectedCellRange.flatMap(cellRangeBounds) {
            setSelection(IndexSet(integersIn: bounds.rows), byUser: true)
        } else if let anchorRow = self.displayRow(forSourceRow: anchor.row) {
            setSelection([anchorRow], byUser: true)
        }
        cursorRow = displayRow
        scrollDisplayRowToVisible(displayRow)
        if let index = tableColumns.firstIndex(where: { $0.id == columnID }) { scrollColumnToVisible(index) }
    }

    /// Shift with an arrow key: the range's moving corner by columns and rows.
    @discardableResult
    func extendCellRange(columns: Int, rows: Int) -> Bool {
        guard navigatesByCell, let start = selectedCellRange?.end ?? focusedCell else { return false }
        let all = columnLayout.allColumns
        guard let column = all.firstIndex(where: { $0.id == start.columnID }),
              let displayRow = displayRow(forSourceRow: start.row) else { return true }
        var row = min(max(displayRow + rows, 0), numberOfRows - 1)
        while isGroupRow(row), row + (rows < 0 ? -1 : 1) >= 0, row + (rows < 0 ? -1 : 1) < numberOfRows {
            row += rows < 0 ? -1 : 1
        }
        guard !isGroupRow(row) else { return true }
        extendCellRange(toDisplayRow: row, columnID: all[min(max(column + columns, 0), all.count - 1)].id)
        showsFocusRing = true
        return true
    }

    /// The visible column at a point in the window, if any.
    func columnID(atWindowLocation location: NSPoint) -> String? {
        let point = convert(location, from: nil)
        guard let region = regions.first(where: { !$0.isHidden && $0.frame.contains(point) }) else { return nil }
        let x = Double(region.canvas.convert(location, from: nil).x)
        return geometry[region.pin].column(atX: x)?.column.id
    }

    /// Tints the range's visible cells, under their content.
    func appendCellRangeTint(style: MetalStyle, scale: CGFloat, in region: NGRegionView, origin: CGPoint, clip: CGRect,
                             to quads: inout [NGMetalQuad]) {
        guard navigatesByCell, let range = selectedCellRange, let bounds = cellRangeBounds(range) else { return }
        let ordinals = Set(bounds.columnIDs.map(columnOrdinal(of:)))
        let color = style.color(.selectedContentBackgroundColor) * 0.18
        for (key, cell) in visibleCells where bounds.rows.contains(key.row) && ordinals.contains(key.column) && cell.regionPin == region.pin {
            let frame = cell.cellFrame.offsetBy(dx: origin.x, dy: origin.y)
            quads.append(NGMetalRenderer.rectangle(frame, scale: scale, color: color, clip: frame.intersection(clip)))
        }
    }

    /// The data source rows (in display order) and the columns of the range
    /// of cells, or of the focused cell, when navigating by cell.
    func cellBlockToCopy() -> (rows: [Int], columns: [NGTableColumn])? {
        guard navigatesByCell else { return nil }
        let range = selectedCellRange ?? focusedCell.map { NGCellRange(anchor: $0, end: $0) }
        guard let range, let bounds = cellRangeBounds(range) else { return nil }
        let columns = bounds.columnIDs.compactMap { id in tableColumns.first { $0.id == id } }
        let rows = bounds.rows.map(sourceRow).filter { $0 >= 0 }
        return (rows, columns)
    }

    /// The range's cells (or the focused cell's) as tab-separated text, rows
    /// by line, values as displayed.
    func copyTextOfCellRange() -> String? {
        guard let dataSource, let block = cellBlockToCopy() else { return nil }
        let columns = block.columns
        // One string built in loops, cells as rows are copied (see `appendCellText`).
        var text = ""
        var isFirst = true
        for row in block.rows {
            if !isFirst { text.append("\n") }
            isFirst = false
            for (index, column) in columns.enumerated() {
                if index > 0 { text.append("\t") }
                Self.appendCellText(NGFormatIDs.string(for: dataSource.tableView(self, valueFor: column, row: row), format: column.format,
                                                         locale: locale),
                                    to: &text)
            }
        }
        return text
    }
}
#endif
