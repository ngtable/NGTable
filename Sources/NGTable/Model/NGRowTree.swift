import Foundation

/// Shows the rows as a tree, like `NSOutlineView` or SwiftUI's `Table` with
/// `children:`: each row names its parent by identity
/// (`NGTableViewDataSource.tableView(_:parentIdentifierForRow:)`), and rows
/// with children expand and collapse. Unlike `NGRowGrouping`, every node is a
/// row of the data source with its own cells (a campaign and its teasers, a
/// folder and its files).
///
/// ```swift
/// table.rowIdentifierColumnID = "id"
/// table.rowTree = NGRowTree(summaryRows: .topLevelRows)
///
/// func tableView(_ tableView: NGTableView, parentIdentifierForRow row: Int) -> AnyHashable? {
///     items[row].parentID
/// }
/// ```
public struct NGRowTree: Sendable, Hashable {
    /// The rows the summary row counts.
    public enum SummaryRows: Sendable, Hashable {
        /// Every row the filter shows.
        case allRows
        /// Only rows without a parent: for trees whose parents show the
        /// totals of their children (which would count twice).
        case topLevelRows
    }

    /// Whether rows with children start collapsed.
    public var startsCollapsed: Bool
    /// The rows the summary row counts.
    public var summaryRows: SummaryRows
    /// The column with the indentation and the disclosure triangles; `nil`:
    /// the first visible column.
    public var outlineColumnID: String?

    public init(startsCollapsed: Bool = false, summaryRows: SummaryRows = .allRows, outlineColumnID: String? = nil) {
        self.startsCollapsed = startsCollapsed
        self.summaryRows = summaryRows
        self.outlineColumnID = outlineColumnID
    }
}

/// A cell of the outline column: how deep its row is, and its triangle.
struct NGOutline: Hashable {
    let level: Int
    let hasChildren: Bool
    let isExpanded: Bool
}
