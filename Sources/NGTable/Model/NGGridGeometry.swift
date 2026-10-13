import Foundation

/// Position of a leaf column inside its region.
public struct NGColumnFrame: Sendable, Hashable {
    public var column: NGTableColumn
    public var x: Double
    public var width: Double

    public var maxX: Double { x + width }
}

/// Position of a column group header inside its region.
public struct NGGroupFrame: Sendable, Hashable {
    public var groupID: String
    public var title: String
    public var x: Double
    public var width: Double

    public var maxX: Double { x + width }
}

/// Column and group positions of one horizontal region.
public struct NGRegionGeometry: Sendable, Hashable {
    public var pin: NGColumnPin
    public var columns: [NGColumnFrame] = []
    public var groups: [NGGroupFrame] = []
    public var width: Double = 0

    public var isEmpty: Bool { columns.isEmpty }

    /// Mirrors the region within `origin..<origin + span` (right to left),
    /// columns and groups listed by `x` again.
    mutating func mirror(from origin: Double, span: Double) {
        let end = 2 * origin + span
        columns = columns.reversed().map { frame in
            var frame = frame
            frame.x = end - frame.maxX
            return frame
        }
        groups = groups.reversed().map { frame in
            var frame = frame
            frame.x = end - frame.maxX
            return frame
        }
    }

    /// Columns overlapping the horizontal range `minX..<maxX`, found by binary search.
    public func columns(intersecting minX: Double, _ maxX: Double) -> ArraySlice<NGColumnFrame> {
        var end = firstIndex(endingAfter: minX)
        let start = end
        while end < columns.count, columns[end].x < maxX {
            end += 1
        }
        return columns[start..<end]
    }

    public func column(atX x: Double) -> NGColumnFrame? {
        let index = firstIndex(endingAfter: x)
        guard index < columns.count, columns[index].x <= x else { return nil }
        return columns[index]
    }

    /// Index of the first column whose trailing edge is past `x`.
    private func firstIndex(endingAfter x: Double) -> Int {
        var low = 0
        var high = columns.count
        while low < high {
            let mid = (low + high) / 2
            if columns[mid].maxX <= x { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// Horizontal geometry of the grid.
///
/// The document is laid out as `leading | center | trailing`. Center column
/// positions are document coordinates (they start after the leading region);
/// frozen column positions are relative to their region.
///
/// `edgeInset` is an empty margin at the table's outer leading and trailing
/// edges, added to the outermost region on each side (the scrolling region
/// when there are no frozen columns on that side).
///
/// Right to left, every region is mirrored: the first column is at its right
/// edge, and each region's columns (and groups) are listed by `x`, right to
/// left in display order, so lookups by position stay binary searches.
public struct NGGridGeometry: Sendable {
    public private(set) var leading = NGRegionGeometry(pin: .leading)
    public private(set) var center = NGRegionGeometry(pin: .none)
    public private(set) var trailing = NGRegionGeometry(pin: .trailing)

    /// - Parameters:
    ///   - layout: The columns of each region.
    ///   - widths: Current widths by column id; missing ones use the column's default width.
    ///   - edgeInset: Margin at the table's outer leading and trailing edges.
    ///   - isRightToLeft: Whether the regions are laid out right to left.
    ///   - centerSpan: Right to left, the width the scrolling columns are
    ///     mirrored in (the visible width, when they are narrower): they
    ///     start at the right.
    public init(layout: NGColumnLayout = NGColumnLayout(), widths: [String: Double] = [:], edgeInset: Double = 0,
                isRightToLeft: Bool = false, centerSpan: Double = 0) {
        let hasLeading = !layout.leading.columns.isEmpty
        let hasTrailing = !layout.trailing.columns.isEmpty
        leading = Self.region(layout.leading, origin: 0, leadingMargin: hasLeading ? edgeInset : 0, trailingMargin: 0, widths: widths)
        center = Self.region(layout.center, origin: leading.width,
                             leadingMargin: hasLeading ? 0 : edgeInset, trailingMargin: hasTrailing ? 0 : edgeInset, widths: widths)
        trailing = Self.region(layout.trailing, origin: 0, leadingMargin: 0, trailingMargin: hasTrailing ? edgeInset : 0, widths: widths)
        if isRightToLeft {
            leading.mirror(from: 0, span: leading.width)
            center.mirror(from: leading.width, span: max(center.width, centerSpan))
            trailing.mirror(from: 0, span: trailing.width)
        }
    }

    public subscript(pin: NGColumnPin) -> NGRegionGeometry {
        switch pin {
        case .leading: leading
        case .none: center
        case .trailing: trailing
        }
    }

    public var contentWidth: Double {
        leading.width + center.width + trailing.width
    }

    private static func region(
        _ layout: NGColumnRegionLayout, origin: Double, leadingMargin: Double, trailingMargin: Double, widths: [String: Double]
    ) -> NGRegionGeometry {
        var region = NGRegionGeometry(pin: layout.pin)
        var x = origin + leadingMargin
        for column in layout.columns {
            let width = min(max(widths[column.id] ?? column.width, column.minWidth), column.maxWidth)
            region.columns.append(NGColumnFrame(column: column, x: x, width: width))
            x += width
        }
        region.width = x + trailingMargin - origin
        region.groups = layout.groups.compactMap { span in
            guard let first = region.columns[safe: span.columnRange.lowerBound],
                  let last = region.columns[safe: span.columnRange.upperBound - 1] else { return nil }
            return NGGroupFrame(groupID: span.groupID, title: span.title, x: first.x, width: last.maxX - first.x)
        }
        return region
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
