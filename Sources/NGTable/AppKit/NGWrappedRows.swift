#if os(macOS)
import AppKit

// Rows as high as their wrapped text. When a shown column wraps text
// (`NGTableColumn.wrapsText`) and the delegate doesn't give heights
// (`NGTableViewRowHeights`), the table measures each row: the most lines
// its wrapped cells take, laid out as they are drawn (`appendWrappedText`).
// Heights are kept by row handle like a delegate's: they follow their
// records through sorts, filters and groups, and reloaded rows are measured
// again. Small tables are measured at once; in large ones the rows not seen
// yet count as `rowHeight` until they come into view, and while rows above
// the top of the view grow, the scroll position keeps the top row where it
// is on screen. A wrapping column's new width, the font or `rowHeight`
// measures every row again.

extension NGTableView {
    /// Up to this many rows, all are measured at once (a scroller of the
    /// true height); more, as they come into view.
    static let measuredAtOnceLimit = 2_000

    /// Whether the table measures rows by their wrapped text.
    var measuresRowHeights: Bool { wrapsTextInSomeColumn && rowHeightProvider == nil }

    /// The shown columns that wrap text, with their widths.
    private var wrappingColumnFrames: [NGColumnFrame] {
        (geometry.leading.columns + geometry.center.columns + geometry.trailing.columns).filter { $0.column.wrapsText }
    }

    /// The height a row's wrapped text needs: one line is `rowHeight`, each
    /// more a line of its font (as `appendWrappedText` draws them).
    private func measuredHeight(ofSourceRow row: Int, columns: [NGColumnFrame], shaper: NGTextShaper, style: MetalStyle) -> CGFloat {
        guard let dataSource else { return rowHeight }
        var height = rowHeight
        for frame in columns {
            // The width the text is drawn in (see `appendContentLeftToRight`).
            let width = CGFloat(frame.width) - cellSpacing.width - 2 * NGMetrics.cellPadding
            guard width > 0 else { continue }
            let value = dataSource.tableView(self, valueFor: frame.column, row: row)
            guard case .text(let text, _, let monospacedDigits) = cellContent(for: value, in: frame.column), !text.isEmpty else { continue }
            let font = monospacedDigits ? style.digitFont : style.textFont
            let lines = shaper.shapeLines(text, font: font, width: width, maximumLines: frame.column.lineLimit).count
            height = max(height, rowHeight + CGFloat(max(0, lines - 1)) * NGLineHeights.height(of: font))
        }
        return height
    }

    /// What measured heights depend on: the wrapping columns' widths and line
    /// limits, the fonts, the spacing and `rowHeight`.
    private func measuredRowsKey(_ columns: [NGColumnFrame], style: MetalStyle) -> [Double] {
        var key: [Double] = [Double(rowHeight), Double(cellSpacing.width), Double(style.textFont.pointSize), Double(style.digitFont.pointSize)]
        for frame in columns {
            key.append(frame.width)
            key.append(Double(frame.column.maximumNumberOfLines))
        }
        return key
    }

    /// Gets the measured heights ready: forgets them all if what they
    /// depend on changed, makes room for new rows.
    /// - Returns: The columns, shaper and style to measure with (`nil`: no
    ///   measuring now), and whether heights were forgotten.
    private func prepareMeasuring() -> (columns: [NGColumnFrame], shaper: NGTextShaper, style: MetalStyle, forgot: Bool)? {
        guard measuresRowHeights, rowUpdateDepth == 0, rowUpdateBatch?.displayIsStale != true,
              let shaper = metalRenderer?.shaper else { return nil }
        let columns = wrappingColumnFrames
        let style = metalStyle
        var forgot = false
        let key = measuredRowsKey(columns, style: style)
        if key != lastMeasuredRowsKey {
            lastMeasuredRowsKey = key
            rowHeightsByHandle = []
            rowGeometryCache = nil
            forgot = true
        }
        if rowHeightsByHandle.count < rowHandles.capacity {
            rowHeightsByHandle.append(contentsOf: repeatElement(.nan, count: rowHandles.capacity - rowHeightsByHandle.count))
        }
        return (columns, shaper, style, forgot)
    }

    /// Measures the display rows not measured yet.
    /// - Returns: Whether one is higher than its estimate (`rowHeight`).
    private func measure(_ displayRows: Range<Int>, columns: [NGColumnFrame], shaper: NGTextShaper, style: MetalStyle) -> Bool {
        var measured = false
        for displayRow in displayRows.clamped(to: 0..<numberOfRows) {
            let row = sourceRow(displayRow)
            guard row >= 0 else { continue }
            let handle = handle(ofRow: row)
            guard handle >= 0, handle < rowHeightsByHandle.count, rowHeightsByHandle[handle].isNaN else { continue }
            let height = measuredHeight(ofSourceRow: row, columns: columns, shaper: shaper, style: style)
            rowHeightsByHandle[handle] = height
            // A row of one line was counted as one already.
            if height != rowHeight { measured = true }
        }
        if measured { rowGeometryCache = nil }
        return measured
    }

    /// Measures the rows in view (all of them in a small table) not measured
    /// yet, keeping the top row in place on screen while rows above it grow.
    /// Returns whether a height changed (the content height may have).
    @discardableResult
    func measureRowsInView() -> Bool {
        guard let (columns, shaper, style, forgot) = prepareMeasuring() else { return false }
        if numberOfSourceRows <= Self.measuredAtOnceLimit {
            return measure(0..<numberOfRows, columns: columns, shaper: shaper, style: style) || forgot
        }
        // The row at the top of the view (below the header) and how far into
        // it the view starts.
        let before = rowGeometry
        let anchor = max(0, Int(floor(before.position(atY: contentOffset.y))))
        let into = contentOffset.y - before.top(of: anchor)
        // Rows measured taller leave room for fewer: a few rounds until all
        // the rows in view are measured.
        let headerHeight = layoutMetrics.headerHeight
        var changed = forgot
        for _ in 0..<4 {
            let rows = rowGeometry
            let first = max(0, Int(floor(rows.position(atY: renderedOffsetY - headerHeight))))
            let last = min(numberOfRows, Int(ceil(rows.position(atY: renderedOffsetY + bounds.height))))
            guard first < last, measure(first..<last, columns: columns, shaper: shaper, style: style) else { break }
            changed = true
        }
        if changed, contentOffset.y > 0 {
            contentOffset.y = max(0, rowGeometry.top(of: anchor) + into)
        }
        return changed
    }

    /// Before scrolling to a row of a large table: measures it and the rows
    /// that would share the view with it, at its top or bottom, so it is
    /// scrolled to by their true heights.
    func measureRows(around displayRow: Int) {
        guard numberOfSourceRows > Self.measuredAtOnceLimit, let (columns, shaper, style, _) = prepareMeasuring() else { return }
        // Each row is at least `rowHeight`: a view's worth of them either side.
        let reach = Int(ceil(bounds.height / rowHeight)) + 1
        if measure(displayRow - reach..<displayRow + reach + 1, columns: columns, shaper: shaper, style: style) {
            layoutMetrics = computeLayoutMetrics()
            needsLayout = true
        }
    }
}
#endif
