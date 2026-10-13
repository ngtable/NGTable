# Grouping Rows

Gather rows under collapsible header rows with subtotals.

## Overview

Set ``NGTableView/rowGrouping`` to group the rows by the displayed value of
one or more columns:

```swift
table.rowGrouping = NGRowGrouping(columnID: "network")
// Two levels: networks, and the statuses within each network.
table.rowGrouping = NGRowGrouping(columnIDs: ["network", "status"])
```

Every group shows a header row with a disclosure chevron, the value and the
number of rows, and the **subtotals** of the columns that have a summary.
Subtotals use the columns' own aggregates and formulas over the group's rows,
so a ratio is the ratio of the group's sums, like in the summary row (see
<doc:Summaries>). The summary row keeps covering every row, in its scope.

The grouping columns can be any columns the data source has values for:
shown, hidden or not in the table at all, like the inputs of a summary
formula. Rows with the same displayed value form a group wherever they are,
and keep the rows' order within it: the data source's, or the table's own
sort with ``NGTableView/sortsRows``.

### Order of groups

Groups come in the order of their first row in the rows' order: the data
source's, or the table's own sort with ``NGTableView/sortsRows``. Sorting by
the grouping column orders the groups by it, and sorting by another column
(say, spend, descending) puts the group with the top spender first; rows
within a group keep that order too.

### Header rows

Header rows are display rows, so they count in ``NGTableView/numberOfRows``,
but they aren't data source rows:

- They are never selected: selecting all selects the data rows; the arrow
  keys stop on headers without selecting them (see
  <doc:KeyboardAndAccessibility>). ``NGTableView/selectedRowIndexes`` stays data source rows.
- ``NGTableView/row(at:)`` gives -1 for them; ``NGTableView/group(at:)`` gives
  their group.
- The data source and the delegate are never asked about them, except for
  ``NGTableViewDelegate/tableView(_:titleFor:)``. Return a title there, e.g. a
  name for an id; by default the header shows the displayed value, or "No
  Value" for rows without one.

The title spans the frozen leading columns (or, without frozen columns, the
first columns up to the first one with a summary). Subtotals show in the other
columns.

### Floating headers

While a group is scrolled into, its header stays at the top of the rows (an
inner group's under its parent's) until the next group's header pushes it up,
like `NSTableView`'s floating group rows. Clicking it collapses the group as
usual. Turn it off with ``NGTableView/floatsGroupRows``.

### Collapsing and expanding

The user collapses and expands a group by clicking its header, like in
Finder; Option-click also collapses or expands every group within it. The
header's context menu collapses or expands all groups. By keyboard, the
arrow keys stop on headers, and Left Arrow and Right Arrow collapse and
expand them (see <doc:KeyboardAndAccessibility>). From code, use the
`NSOutlineView`-like methods:

```swift
table.collapseGroup(nil, collapseChildren: true)   // Everything, also groups that appear later.
table.expandGroup(group)
if table.isGroupExpanded(group) { … }
```

``NGRowGrouping/startsCollapsed`` shows only the headers at first. The
delegate's ``NGTableViewDelegate/tableViewGroupDidExpand(_:)`` and
``NGTableViewDelegate/tableViewGroupDidCollapse(_:)`` follow the changes.

A group (``NGRowGroup``) is its path of displayed values, so it stays
collapsed across `reloadData()` as long as rows with those values exist.
Selected rows of a group that collapses leave the selection, like rows the
row filter hides.

### Grouping by the user

With ``NGTableView/allowsUserGrouping``, the header's context menu groups the
rows by the clicked column ("Group by"), adds a level ("Then group by") and
ungroups. The grouping is then saved with ``NGTableView/autosaveName`` with
the columns, and the delegate hears of it in
``NGTableViewDelegate/tableView(_:didChangeRowGrouping:)``, so an app that
keeps the grouping in its own model can follow.

### Filters and updates

The ``NGTableView/rowFilter`` decides which rows are grouped: groups without
shown rows disappear, and subtotals cover the shown rows. Targeted updates
(`reloadData(forRowIndexes:columnIndexes:)`, inserts, removes and moves) move
rows to their new groups and update the subtotals; the selection follows its
records.

To find your way around the groups: ``NGTableView/topLevelGroups``,
``NGTableView/childGroups(of:)``, ``NGTableView/rowIndexes(in:)-(NGRowGroup)`` and
``NGTableView/group(forRow:)``.

### Sections of a diffable data source

``NGTableViewDiffableDataSource`` shows its snapshot's sections as groups
when it has a ``NGTableViewDiffableDataSource/sectionTitleProvider``: each
section gets a header row with that title, collapsible and with subtotals,
like AppKit's section header views. Items moved to another section in an
applied snapshot move to its group.

```swift
dataSource.sectionTitleProvider = { network in network.displayName }
```

## Trees

Where groups gather rows by a column's value under header rows, a tree
(``NGTableView/rowTree``) shows rows that are themselves the nodes, like
`NSOutlineView` or SwiftUI's `Table` with `children:`: a campaign row with
its teaser rows, a folder with its files. Each row names its parent by
identity, so the rows need identities too:

```swift
table.rowIdentifierColumnID = "id"
table.rowTree = NGRowTree(summaryRows: .topLevelRows)

func tableView(_ tableView: NGTableView, parentIdentifierForRow row: Int) -> AnyHashable? {
    items[row].parentID   // nil at the top
}
```

The rows stay in one flat list in your data source, in any order: the table
lays them out depth first, siblings in the table's order (sorted, or the data
source's). The first visible column (or ``NGRowTree/outlineColumnID``) is
indented by depth, with a disclosure triangle on rows with children. A click
on the triangle, or Left Arrow and Right Arrow on a selected row, collapses
and expands it (Left Arrow on a collapsed row goes to its parent, Right Arrow
on an expanded one to its first child); with Option, the rows within it too.
Unlike group headers, every row is a data source row: it's selected, edited,
copied and dragged like any other.

- The filter shows the rows it lets through with their ancestors, so the path
  to each stays visible.
- ``NGRowTree/SummaryRows/topLevelRows`` counts only rows without a parent in
  the summary row, for trees whose parents show their children's totals.
- Live updates keep the tree: a changed row may get another parent, inserted
  rows go under theirs, and the children of a removed row move to the top
  until a row with its identity comes back. Value changes that keep the
  parents and the order cost no layout; inserts and removes lay the tree out
  again (about 5 ms for 200,000 rows).
- Expansion is kept by identity across `reloadData()`.

Use the `NSOutlineView`-like API by data source row:
``NGTableView/isRowExpandable(_:)``, ``NGTableView/isRowExpanded(_:)``,
``NGTableView/expandRow(_:expandChildren:)``,
``NGTableView/collapseRow(_:collapseChildren:)``,
``NGTableView/level(forRow:)``, ``NGTableView/parentRow(forRow:)`` and
``NGTableView/childRows(ofRow:)``. A tree and a grouping don't mix: setting
one ends the other.

The delegate decides like an outline view's: the user's expanding and
collapsing (a click on the triangle, Left and Right, VoiceOver) asks
``NGTableViewDelegate/tableView(_:shouldExpandRow:)`` and
``NGTableViewDelegate/tableView(_:shouldCollapseRow:)`` first; code isn't
asked. "Will" and "did" come as delegate calls and notifications
(``NGTableView/rowWillExpandNotification`` and the others), before and after
the rows change. With ``NGTableView/autosaveExpandedItems`` and an
``NGTableView/autosaveName``, the expanded rows are saved and come back;
rows whose identities are strings or integers are saved.

## Topics

### Grouping

- ``NGRowGrouping``
- ``NGRowGroup``
- ``NGTableView/rowGrouping``

### Collapsing and Expanding

- ``NGTableView/isGroupExpanded(_:)``
- ``NGTableView/expandGroup(_:expandChildren:)``
- ``NGTableView/collapseGroup(_:collapseChildren:)``
- ``NGTableView/groupDidExpandNotification``
- ``NGTableView/groupDidCollapseNotification``

### Trees

- ``NGRowTree``
- ``NGTableView/rowTree``
- ``NGTableViewDataSource/tableView(_:parentIdentifierForRow:)``
- ``NGTableView/isRowExpandable(_:)``
- ``NGTableView/isRowExpanded(_:)``
- ``NGTableView/expandRow(_:expandChildren:)``
- ``NGTableView/collapseRow(_:collapseChildren:)``
- ``NGTableView/level(forRow:)``
- ``NGTableView/parentRow(forRow:)``
- ``NGTableView/childRows(ofRow:)``
- ``NGTableView/autosaveExpandedItems``
- ``NGTableViewDelegate/tableView(_:shouldExpandRow:)``
- ``NGTableViewDelegate/tableView(_:shouldCollapseRow:)``
- ``NGTableView/rowWillExpandNotification``
- ``NGTableView/rowDidExpandNotification``
- ``NGTableView/rowWillCollapseNotification``
- ``NGTableView/rowDidCollapseNotification``
