# Defining Columns

Describe the columns, freeze and group them, and let users customize them.

## Overview

``NGTableView/columns`` is an array of ``NGColumnItem``s in display order.
An item is either a single ``NGTableColumn`` or an ``NGColumnGroup`` of
columns under a common header:

```swift
table.columns = [
    .column(NGTableColumn("name", title: "Campaign", width: 220, pin: .leading)),
    .group(NGColumnGroup("ads", title: "Advertising", columns: [
        NGTableColumn("spend", title: "Spend", format: .currency(code: "EUR"), summary: .aggregate(.sum)),
        NGTableColumn("revenue", title: "Revenue", format: .currency(code: "EUR"), summary: .aggregate(.sum)),
    ])),
    .column(NGTableColumn("total", title: "Total", format: .currency(code: "EUR"),
                          summary: .aggregate(.sum), pin: .trailing)),
]
```

### Identifiers

Every column and group needs an `id` that is unique across the whole table,
including columns inside groups. The id is used:

- by the data source, to tell which value to return;
- by ``NGTableView/hiddenColumnIDs``, sort descriptors, summaries and formulas;
- as the key of saved column layouts, so keep ids stable between versions of
  your app.

Duplicate ids are a programming error (an assertion fails in debug builds;
only the first column with an id is shown).

### Column options

``NGTableColumn`` is a value type; everything is set in its initializer and can
be changed later by assigning new `columns`:

| Option | Default | Meaning |
| --- | --- | --- |
| `title` | — | Header title. Empty for narrow icon columns; menus then show `toolTip` or `id`. |
| `width`, `minWidth`, `maxWidth` | 100, 40, 1000 | Initial width and resize limits, in points. |
| `alignment` | `.leading` | Cells and summary. `.automatic` aligns numbers to the trailing edge. |
| `headerAlignment` | `.leading` | The title, independently of the cells, so titles line up at the leading edge even over numbers. Set `.trailing` (or `.center`) to align a title differently. |
| `format` | `.automatic` | How values are displayed (see <doc:DisplayingValues>). |
| `summary` | `.none` | What the summary row shows (see <doc:Summaries>). |
| `isSortable` | `true` | Header clicks sort by the column: an ascending ``NGTableColumn/sortDescriptorPrototype`` by its id. Set the prototype for another key or direction. |
| `isResizable` | `true` | The user can drag the header divider. |
| `isHideable` | `true` | The user can hide the column from the header menu. |
| `isMovable` | `true` | The user can drag the column elsewhere; others can't pass a fixed column. |
| `showsHeaderDivider` | `true` | A divider after the title; turn it off for untitled icon columns. |
| `pin` | `.none` | `.leading` or `.trailing` freezes the column. |
| `toolTip` | `nil` | Shown over the header. |

Leading and trailing follow the interface's direction, not the text's: leading
is the left edge, or the right edge in a right-to-left interface (see
`userInterfaceLayoutDirection`).

### Frozen columns

A column's ``NGColumnPin`` places it in one of three regions:

- `.leading`: frozen at the leading edge, e.g. the campaign name;
- `.none`: scrolls horizontally;
- `.trailing`: frozen at the trailing edge, e.g. a total.

Columns keep their relative order within each region, whatever their order in
`columns`. Frozen regions are never scrolled away, so keep them narrow enough
to leave room for the scrolling columns.

### Groups

An ``NGColumnGroup`` draws its title in a header band above its columns. The
group's `pin` applies to all its columns (their own pins are ignored), so a
group never spans two regions. The band is only shown when there is at least
one group; its height is ``NGTableView/groupHeaderHeight``.

The user can move a whole group by dragging its title, or its columns within
the group; columns never leave their group or region.

### An icon column

Marks (see <doc:DisplayingValues>) go in a narrow column that is untitled,
fixed and frozen, like Mail's flag column:

```swift
NGTableColumn("mark", title: "", width: 30, alignment: .center,
              isResizable: false, isMovable: false, showsHeaderDivider: false,
              pin: .leading, toolTip: "Mark")
```

The `toolTip` doubles as its name in the header menu.

### What users can do

- **Resize** a column by dragging the divider after its title, and fit it to
  its content by double-clicking the divider. The table reports finished
  resizes with ``NGTableViewDelegate/tableView(_:didResizeColumn:width:)``,
  and every width change (also while dragging, and from code) like
  `NSTableView` with ``NGTableViewDelegate/tableViewColumnDidResize(_:)``
  (`NSTableColumn` and `NSOldWidth` in the userInfo).
- **Move** columns and groups by dragging their headers; near the edges the
  table scrolls. Reported with
  ``NGTableViewDelegate/tableView(_:didReorderColumns:)``; ``NGTableView/columns``
  then holds the new order. Like `NSTableView`,
  ``NGTableViewDelegate/tableViewColumnDidMove(_:)`` also reports each moved
  column's index in ``NGTableView/tableColumns`` before and after
  (`NSOldColumn`, `NSNewColumn`). Turn moving off with
  ``NGTableView/allowsColumnReordering``.
- **Click** a title: ``NGTableViewDelegate/tableView(_:didClick:)``, after
  the sort it asks for.
- **Hide and show** columns and groups from the header's context menu, which
  lists all of them with check marks. At least one column always stays
  visible, and columns with `isHideable: false` can't be hidden. Reported with
  ``NGTableViewDelegate/tableView(_:didChangeHiddenColumns:)``. Turn it off with
  ``NGTableView/allowsColumnHiding``.
- **Sort** by clicking a sortable header (see <doc:SelectionAndSorting>).
- **Save views**: with ``NGTableView/allowsNamedViews``, the header's context
  menu saves the columns, sort, column filters and grouping under a name and
  switches between the saved views (``NGTableView/saveView(named:)``,
  ``NGTableView/applyView(named:)``, ``NGTableView/savedViewNames``). They are
  kept under ``NGTableView/autosaveName``.
- **Pin** a column, or its whole group, to the left or right edge, and unpin
  it, from the header's context menu (columns that are movable). Reported with
  ``NGTableViewDelegate/tableView(_:didReorderColumns:)``. Turn it off with
  ``NGTableView/allowsColumnPinning``.

In code, use ``NGTableView/setWidth(_:forColumnID:)``,
``NGTableView/width(ofColumnID:)``, ``NGTableView/sizeColumnToFit(_:)`` and
``NGTableView/hiddenColumnIDs``. Hiding columns keeps the scroll position,
sort, selection and the other columns' widths.

### Saving the user's columns

Set ``NGTableView/autosaveName`` and the table saves column order, widths,
hidden columns and the sort in the user defaults whenever the user changes
them, and applies them when the columns are set (see
<doc:SelectionAndSorting> for the sort). Like NSTableView's, widths and
hidden columns set in code and the widths autoresizing gives are saved too
(once they settle, at the end of a live resize), so set the autosave name
after setting up the columns:

```swift
table.columns = columns
table.autosaveName = "CampaignsTable"
```

Use a different name for every table (the key is
`"NGTableView Columns <name>"`). Tables open at once under the same name
(windows of one kind) share the saved layout, but each saves its whole
layout when the user changes it: the last change wins, and an open window
doesn't take another's changes until it opens again. Saved states survive changes to the column
definition: new columns appear where you defined them, and removed ones are
ignored. To store the state yourself, for example per user on a server, read
and assign ``NGTableView/columnLayoutState``, which is `Codable`:

```swift
let data = try JSONEncoder().encode(table.columnLayoutState)
// Later, after setting the columns:
table.columnLayoutState = try JSONDecoder().decode(NGColumnLayoutState.self, from: data)
```

### Changing the column definition

Assign new `columns` at any time, for example to add a column for a new
metric. Widths the user set, hidden columns and the saved layout carry over to
columns with the same ids. A new definition reloads the data (the selection
stays, see <doc:SelectionAndSorting>) and scrolls back to the top. Sorts by
columns that no longer exist are dropped from
``NGTableView/sortDescriptors``, and the data source sorts again with
``NGTableViewDataSource/tableView(_:sortDescriptorsDidChange:)``.

Hiding, showing and moving columns, and applying a saved layout, don't reload
or scroll.
