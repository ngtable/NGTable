import CoreGraphics

// Where a table's display rows are: each one's top and height, the row at a
// y, the height of them all. Everything in the table that turns rows into
// positions or positions into rows asks this, not `rowHeight`. With one
// height for every row it is the multiplication and division the table
// always did, in the same order of operations; with rows of their own
// heights it keeps the tops of all of them (prefix sums: a row's top at
// once, the row at a y by binary search). Rows past either end continue
// with `rowHeight`, as the uniform rows do.

/// The display rows' positions: tops, heights and the row at a y.
struct NGRowGeometry: Sendable {
    /// The height of every row (with `heights`, of rows past the ends).
    let rowHeight: CGFloat
    /// The display rows.
    let count: Int
    /// With rows of their own heights, each row's top and then the bottom of
    /// the last one (`count + 1` values); empty when they all have `rowHeight`.
    private let tops: [CGFloat]

    /// Rows that all have `rowHeight`.
    init(rowHeight: CGFloat, count: Int) {
        self.rowHeight = rowHeight
        self.count = count
        tops = []
    }

    /// Rows of the given heights, in display order.
    init(rowHeight: CGFloat, heights: some Collection<CGFloat>) {
        self.rowHeight = rowHeight
        count = heights.count
        var tops: [CGFloat] = []
        tops.reserveCapacity(heights.count + 1)
        var y: CGFloat = 0
        tops.append(0)
        for height in heights {
            y += height
            tops.append(y)
        }
        self.tops = tops
    }

    /// Whether rows have heights of their own.
    var hasRowHeights: Bool { !tops.isEmpty }

    /// The top of a display row (rows past the end continue the last ones).
    func top(of row: Int) -> CGFloat {
        guard !tops.isEmpty else { return CGFloat(row) * rowHeight }
        if row < 0 { return CGFloat(row) * rowHeight }
        if row > count { return tops[count] + CGFloat(row - count) * rowHeight }
        return tops[row]
    }

    /// The height of a display row.
    func height(of row: Int) -> CGFloat {
        guard !tops.isEmpty, row >= 0, row < count else { return rowHeight }
        return tops[row + 1] - tops[row]
    }

    /// The bottom of a display row: the top of the next one.
    func bottom(of row: Int) -> CGFloat { top(of: row + 1) }

    /// How far a row's top moves from display row `old` to `new` (in this
    /// geometry): positive when it moves up.
    func offset(from old: Int, to new: Int) -> CGFloat {
        guard !tops.isEmpty else { return CGFloat(old - new) * rowHeight }
        return top(of: old) - top(of: new)
    }

    /// The display row at `y` as a fraction (2.5: the middle of row 2):
    /// rounded down, the row at `y`; rounded up, the row after the last one
    /// that reaches `y`. Callers round it as they need.
    func position(atY y: CGFloat) -> CGFloat {
        guard !tops.isEmpty else { return y / rowHeight }
        if y < 0 { return y / rowHeight }
        let total = tops[count]
        if y >= total { return CGFloat(count) + (y - total) / rowHeight }
        // The last row whose top is at or above y.
        var low = 0, high = count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if tops[middle] <= y { low = middle } else { high = middle - 1 }
        }
        let height = tops[low + 1] - tops[low]
        return CGFloat(low) + (height > 0 ? (y - tops[low]) / height : 0)
    }

    /// The height of all the rows.
    var totalHeight: CGFloat {
        guard !tops.isEmpty else { return CGFloat(count) * rowHeight }
        return tops[count]
    }
}
