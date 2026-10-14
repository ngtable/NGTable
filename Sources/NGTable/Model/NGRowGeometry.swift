import CoreGraphics

// Where a table's display rows are: each one's top and height, the row at a
// y, the height of them all. Everything in the table that turns rows into
// positions or positions into rows asks this, not `rowHeight`, so rows of
// different heights (wrapped text, an app's heights) change one place. With
// one height for every row it is the multiplication and division the table
// always did, in the same order of operations.

/// The display rows' positions: tops, heights and the row at a y.
struct NGRowGeometry: Sendable {
    /// The height of every row.
    let rowHeight: CGFloat
    /// The display rows.
    let count: Int

    /// The top of a display row (rows past the end continue the last ones).
    func top(of row: Int) -> CGFloat { CGFloat(row) * rowHeight }

    /// The height of a display row.
    func height(of row: Int) -> CGFloat { rowHeight }

    /// The bottom of a display row: the top of the next one.
    func bottom(of row: Int) -> CGFloat { top(of: row + 1) }

    /// How far a row's top moves from display row `old` to `new` (in this
    /// geometry): positive when it moves up.
    func offset(from old: Int, to new: Int) -> CGFloat { CGFloat(old - new) * rowHeight }

    /// The display row at `y` as a fraction (2.5: the middle of row 2):
    /// rounded down, the row at `y`; rounded up, the row after the last one
    /// that reaches `y`. Callers round it as they need.
    func position(atY y: CGFloat) -> CGFloat { y / rowHeight }

    /// The height of all the rows.
    var totalHeight: CGFloat { CGFloat(count) * rowHeight }
}
