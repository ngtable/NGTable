import Foundation

/// How a table groups its rows: by the displayed value of one or more
/// columns, each column a level (e.g. by network, then by status within each
/// network).
///
/// Every group shows a header row with the value, the number of rows and the
/// subtotals of the columns that have a summary (the same aggregates and
/// formulas as the summary row, over the group's rows). Users collapse and
/// expand groups by clicking their headers.
///
/// Rows with the same displayed value form a group, wherever they are in the
/// data, and keep the rows' order within it (the data source's, or the
/// table's sort with `sortsRows`). Groups come in the order
/// of their first row: sorting by the grouping column orders the groups by
/// it, sorting by another column puts the group with the top row first.
public struct NGRowGrouping: Sendable, Hashable {
    /// The columns grouped by, outermost first. Like summary inputs, they
    /// can be any column ids the data source has values for: shown, hidden
    /// or not in the table at all.
    public var columnIDs: [String]
    /// Whether group headers show the number of rows next to the value.
    public var showsRowCount: Bool
    /// Whether groups start collapsed, showing only their headers.
    public var startsCollapsed: Bool

    public init(columnIDs: [String], showsRowCount: Bool = true, startsCollapsed: Bool = false) {
        self.columnIDs = columnIDs
        self.showsRowCount = showsRowCount
        self.startsCollapsed = startsCollapsed
    }

    /// Grouping by one column.
    public init(columnID: String, showsRowCount: Bool = true, startsCollapsed: Bool = false) {
        self.init(columnIDs: [columnID], showsRowCount: showsRowCount, startsCollapsed: startsCollapsed)
    }
}

/// A group of rows, like an item of an outline view: identified by the
/// displayed values its rows share, from the outermost level in. It stays the
/// same group across reloads as long as rows with those values exist, so it
/// keeps being collapsed or expanded.
public struct NGRowGroup: Sendable, Hashable, CustomStringConvertible {
    /// The columns grouped by, from the outermost level to this group's.
    public let columnIDs: [String]
    /// The displayed values of those columns that the group's rows share,
    /// outermost first ("" for rows without a value).
    public let path: [String]
    /// The value of the group's column in one of its rows (they all display
    /// it the same, but the value itself may differ, e.g. a date's time):
    /// the first one read, not necessarily the first one shown. E.g. to make
    /// a title of it (see `NGTableViewDelegate.tableView(_:titleFor:)`).
    public let value: NGCellValue

    public init(columnIDs: [String], path: [String], value: NGCellValue = .empty) {
        precondition(!path.isEmpty && path.count == columnIDs.count, "NGRowGroup: one value per grouping column")
        self.columnIDs = columnIDs
        self.path = path
        self.value = value
    }

    /// The column this group's rows share a value of.
    public var columnID: String { columnIDs[columnIDs.count - 1] }
    /// 0 for groups of the first grouping column, 1 within them, and so on.
    public var level: Int { path.count - 1 }
    /// The displayed value the group's rows share ("" without a value).
    public var key: String { path[path.count - 1] }
    /// The group this one is in, or `nil` at the outermost level.
    public var parent: NGRowGroup? {
        guard path.count > 1 else { return nil }
        return NGRowGroup(columnIDs: Array(columnIDs.dropLast()), path: Array(path.dropLast()))
    }

    /// Whether this group is `other` or within it.
    public func isWithin(_ other: NGRowGroup) -> Bool {
        path.count >= other.path.count && Array(path.prefix(other.path.count)) == other.path
            && Array(columnIDs.prefix(other.columnIDs.count)) == other.columnIDs
    }

    // Groups are their path: the value is only the first row's.
    public static func == (lhs: NGRowGroup, rhs: NGRowGroup) -> Bool {
        lhs.path == rhs.path && lhs.columnIDs == rhs.columnIDs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(columnIDs)
    }

    public var description: String {
        zip(columnIDs, path).map { "\($0)=\($1)" }.joined(separator: " / ")
    }
}
