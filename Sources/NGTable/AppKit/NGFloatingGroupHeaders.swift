#if os(macOS)
import AppKit

// Floating group headers (`floatsGroupRows`): while a group is scrolled into,
// its header stays at the top of the rows, under its parent's, until the next
// group's header pushes it up, like NSTableView's floating group rows. The
// headers keep their display rows and cells (placed even when their rows are
// out of view); only drawing moves them, and hit testing finds them where
// they're drawn.

extension NGTableView {
    /// The floating headers now: their display rows and where they're drawn
    /// (y in the canvases), outermost first.
    func floatingGroupHeaders() -> [(row: Int, y: CGFloat)] {
        floatingGroupHeaders(atOffset: renderedOffsetY)
    }

    /// The floating headers when the rows are scrolled to an offset.
    func floatingGroupHeaders(atOffset top: CGFloat) -> [(row: Int, y: CGFloat)] {
        guard floatsGroupRows, let display = groupedDisplay, rowHeight > 0 else { return [] }
        guard top > 0 else { return [] }
        let rowLayout = rowGeometry
        let first = Int(rowLayout.position(atY: top))
        guard first < display.count else { return [] }
        // The group of the row at the top, and the groups around it.
        let entry = display[first]
        var node = entry < 0 ? -1 - entry : (entry < groupTree.leafOfSourceRow.count ? Int(groupTree.leafOfSourceRow[entry]) : -1)
        var chain: [Int] = []
        while node >= 0, node < groupTree.nodes.count {
            chain.append(node)
            node = groupTree.nodes[node].parent
        }
        chain.reverse()
        guard !chain.isEmpty, chain.allSatisfy({ $0 < groupHeaderDisplayRows.count && groupHeaderDisplayRows[$0] >= 0 }) else { return [] }
        // Each level under the one above, pushed up by the end of its group;
        // a parent stays above its pushed child. Group header rows are
        // `rowHeight` high whatever the other rows' heights.
        var ys = chain.enumerated().map { level, node in
            min(top + CGFloat(level) * rowHeight, rowLayout.top(of: groupDisplayEnds[node]) - rowHeight)
        }
        if ys.count > 1 {
            for level in stride(from: ys.count - 2, through: 0, by: -1) {
                ys[level] = min(ys[level], ys[level + 1] - rowHeight)
            }
        }
        var result: [(row: Int, y: CGFloat)] = []
        for (level, node) in chain.enumerated() {
            let row = groupHeaderDisplayRows[node]
            // In its place already: it and the levels within don't float.
            guard rowLayout.top(of: row) < ys[level] else { break }
            result.append((row, ys[level]))
        }
        return result
    }

    /// How much of the rows' top floating headers cover at an offset (other
    /// than a display row's own header): a row scrolled into view must be
    /// below them.
    func floatingHeadersCover(atOffset top: CGFloat, except displayRow: Int) -> CGFloat {
        floatingGroupHeaders(atOffset: top).filter { $0.row != displayRow }
            .map { $0.y + rowHeight - top }.max().map { max(0, $0) } ?? 0
    }

    /// The floating header at a y of the canvases, if any.
    func floatingGroupHeader(atCanvasY y: CGFloat) -> Int? {
        floatingGroupHeaders().last { y >= $0.y && y < $0.y + rowHeight }?.row
    }

    /// Places the cells of floating headers out of the visible rows, and
    /// recycles those of headers that no longer float.
    func placeFloatingGroupHeaders(visibleRows rows: Range<Int>, regions: [NGRegionView],
                                   place: (Int) -> Void) {
        let floating = Set(floatingGroupHeaders().map(\.row))
        for row in floatingHeaderRows where !floating.contains(row) && !rows.contains(row) {
            recycleCells(ofRow: row)
            for region in regions {
                if let layer = visibleRows.removeValue(forKey: NGRowKey(pin: region.pin, row: row)) {
                    layer.isHidden = true
                    rowPool.append(layer)
                }
            }
        }
        for row in floating where !rows.contains(row) {
            place(row)
        }
        if floating != floatingHeaderRows { setNeedsMetalFrame() }
        floatingHeaderRows = floating
    }
}
#endif
