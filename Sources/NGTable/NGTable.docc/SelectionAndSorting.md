# Selection and Sorting

Keep the selection on the same records, react to it, and sort when the user
clicks a header.

## Overview

Users select rows like in Finder: click, Shift-click to extend,
Command-click to add or remove, drag across rows (the table scrolls near its
edges), arrow keys with and without Shift, and Select All. The selection API
is `NSTableView`'s, so existing delegates carry over.

### Reading and changing the selection

``NGTableView/selectedRowIndexes`` holds the selected rows as data source
indexes; ``NGTableView/selectedRow``, ``NGTableView/numberOfSelectedRows`` and
``NGTableView/isRowSelected(_:)`` answer the usual questions. Like an
`NSTableView`, the table tells its delegate (and posts
``NGTableView/selectionDidChangeNotification``):

- ``NGTableViewDelegate/tableViewSelectionDidChange(_:)`` when the selection
  changed: by the keyboard, by a click or drag once the mouse is released, in
  code, or when a reload or filter removes rows from it;
- ``NGTableViewDelegate/tableViewSelectionIsChanging(_:)`` while the mouse is
  still down, to follow a growing selection live.

```swift
func tableViewSelectionDidChange(_ notification: Notification) {
    let selected = table.selectedRowIndexes.map { data.campaigns[$0] }
    toolbar.pauseButton.isEnabled = !selected.isEmpty
}
```

`selectedRowIndexes` is in data source order. When the table sorts, filters
or groups the rows, ``NGTableView/selectedRowIndexesInDisplayOrder`` lists them
as shown (the topmost selected record first), and
``NGTableView/displayIndex(ofRow:)`` and ``NGTableView/row(atDisplayIndex:)``
map between data source rows and the rows shown.

Select rows in code with
``NGTableView/selectRowIndexes(_:byExtendingSelection:)``,
``NGTableView/deselectRow(_:)`` and ``NGTableView/deselectAll(_:)``, and bring a
row into view with ``NGTableView/scrollRowToVisible(_:)``. Set
``NGTableView/allowsMultipleSelection`` to `false` to allow at most one row,
and ``NGTableView/allowsEmptySelection`` to `false` to keep at least one.

### Restricting the selection

The delegate decides what the user may select, as for an `NSTableView`.
Selections made in code aren't asked.

- ``NGTableViewDelegate/tableView(_:shouldSelectRow:)`` rejects single rows,
  e.g. archived records. Clicks and drags leave them out, and arrow keys skip
  them.
- ``NGTableViewDelegate/tableView(_:selectionIndexesForProposedSelection:)``
  sees the whole proposed selection and returns the rows to select.
- ``NGTableViewDelegate/selectionShouldChange(in:)`` returns `false` to keep
  the selection as it is, e.g. while an edit isn't saved.

### Selecting columns

With ``NGTableView/allowsColumnSelection`` (off by default) a click on a
column's header selects the column, as in an NSTableView: Command adds or
removes it, Shift extends from the last one, and
``NGTableViewDelegate/tableView(_:shouldSelect:)`` may refuse it; a
sortable column still sorts. In code, use
``NGTableView/selectColumnIndexes(_:byExtendingSelection:)``,
``NGTableView/deselectColumn(_:)``, ``NGTableView/selectedColumnIndexes``
and ``NGTableView/selectedColumn``. Rows or columns are selected, not both,
and the change is one ``NGTableView/selectionDidChangeNotification``.
Selected columns stay selected as they move; hidden ones aren't selected.
They are tinted rather than filled, so their text stays readable.

### Clicks

Clicking the rows sends ``NGTableView/action`` to ``NGTableView/target`` once
the mouse is released, and a double click sends ``NGTableView/doubleAction``,
like a table view's. ``NGTableView/clickedRow`` and
``NGTableView/clickedColumn`` (an index in ``NGTableView/tableColumns``) say
what was clicked; they are -1 below the rows:

```swift
table.target = self
table.doubleAction = #selector(openCampaign(_:))

@objc func openCampaign(_ sender: NGTableView) {
    guard sender.clickedRow >= 0 else { return }
    open(data.campaigns[sender.clickedRow])
}
```

Return with rows selected (and no cell to edit) sends
``NGTableView/returnAction``, like a list's primary action; its
``NGTableView/clickedRow`` is -1, so act on the selected rows. NSTableView has
no such action: leave it `nil` and Return goes on, e.g. to the window's
default button.

``NGTableView/row(at:)`` and ``NGTableView/column(at:)`` find the row and
column at a point, and ``NGTableView/tableColumn(withIdentifier:)`` and
``NGTableView/column(withIdentifier:)`` find columns by their identifier.

### Row identity

When the data is reloaded, the rows may be in a different order, and some may
have appeared or disappeared: after sorting, a refresh from the server, or a
record deleted elsewhere. To keep the selection on the same records, tell the
table what identifies a row. Either name a column whose value is the id:

```swift
table.rowIdentifierColumnID = "id"
```

The column doesn't need to be shown or defined: the table asks the data
source for `"id"` like for any column. Or answer
``NGTableViewDataSource/tableView(_:identifierForRow:)``, which takes
precedence:

```swift
func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? {
    campaigns[row].id
}
```

With an identity, ``NGTableView/reloadData()`` selects the rows that have the
same ids as the ones selected before, wherever they are now, and Shift-extending
continues from the same records. Selected records that are gone leave the
selection, and the delegate is told. Ids should be unique: rows that share one
are all selected. Rows whose id is `nil` are never selected again.

Without an identity, the selection stays on the same row indexes, which only
suits data that never changes order.

### Finding rows by identity

A feed often addresses records by id ("campaign 123 changed"), while the
table takes row indexes, which inserts and removes keep shifting.
``NGTableView/row(forIdentifier:)`` gives a record's current data source row
(or -1), like `NSOutlineView`'s `row(forItem:)`:

```swift
let row = table.row(forIdentifier: update.campaignID)
if row >= 0 {
    campaigns[row].apply(update)
    table.reloadData(forRowIndexes: [row], columnIndexes: changedColumns)
}
```

The first lookup reads every row's identity (about 75 ms for 200,000 rows),
then lookups take constant time (well under a microsecond) while rows are
inserted, removed and moved; only inserted rows are read, on the next lookup.
`reloadData()` starts over. Identities should stay with their records: remove
and insert a row whose identity changes.

### Sorting

Sorting works like in `NSTableView`, so existing sorting code carries over.
The table doesn't sort: your data source does, because only it knows the full
data and how to order it (for example by a server-side field).

- Every sortable column has a ``NGTableColumn/sortDescriptorPrototype``: by
  default an ascending sort by the column's id. Set your own for another key,
  the first click's direction, or a selector for `NSSortDescriptor` sorting.
  `isSortable: false` (or a `nil` prototype) turns sorting off for a column.
- ``NGTableView/sortDescriptors`` holds the sort, several columns deep: the
  first descriptor decides, the others order the rows it finds equal.
- A click on a sortable header puts its column's prototype first; the
  previous sorts stay as secondary ones. Clicking the first column again
  reverses it, and a click after the user reversed it removes it, back to
  the original order when there's no other sort (a sort your code set is
  reversed by the first click). The header shows the first sort's indicator, and
  dimmed ones for the secondary sorts.
- Every change of the sort descriptors, from a click or from your code, calls
  the data source's
  ``NGTableViewDataSource/tableView(_:sortDescriptorsDidChange:)``. Sort your
  data and tell the table (see <doc:#Re-sorting-without-reloading> for large
  tables):

```swift
func tableView(_ tableView: NGTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
    sort(by: tableView.sortDescriptors)   // Empty: the original order.
    tableView.reloadData()                // With row identity, the selection follows.
}
```

Records that are key-value coding compliant sort with the descriptors
themselves, like for an `NSTableView`:

```swift
campaigns = (received as NSArray).sortedArray(using: tableView.sortDescriptors) as! [Campaign]
```

Swift values sort with ``NGSorting/order(ofRows:by:value:)``, which orders by
cell values: ``NGCellValue/sortsBefore(_:)`` sorts text like Finder, numbers
numerically and empty values first. Give it the value lookup of your data
source, by the descriptors' keys (the column ids, unless your prototypes say
otherwise):

```swift
static func value(_ columnID: String, of campaign: Campaign) -> NGCellValue {
    switch columnID {
    case "name": .text(campaign.name)
    case "spend": .number(campaign.spend)
    default: .empty
    }
}

func sort(by descriptors: [NSSortDescriptor]) {
    // Each row's value is looked up once per key, not on every comparison.
    campaigns = NGSorting.order(ofRows: received.count, by: descriptors) { key, row in
        Self.value(key, of: received[row])
    }.map { received[$0] }
}
```

#### Re-sorting without reloading

A sort changes the order of the rows, not their values, so the table doesn't
need to read them again. Keep the order as indexes into your data and tell
the table how the rows moved with ``NGTableView/reorderRows(from:to:)``: the
cells, the selection, the summarized values, the search index and the row
groups move with their rows, so even 200,000 rows re-sort at once, and
group subtotals stay on screen instead of being computed again.

```swift
var order: [Int] = []   // Rows of `campaigns` in display order.

func show(_ received: [Campaign]) {
    campaigns = received
    // The order must cover every row before the table reads one.
    order = NGSorting.order(ofRows: campaigns.count, by: tableView.sortDescriptors) { key, row in
        Self.value(key, of: campaigns[row])
    }
    tableView.reloadData()
}

func numberOfRows(in tableView: NGTableView) -> Int {
    order.count
}

func tableView(_ tableView: NGTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
    let previous = order
    order = NGSorting.order(ofRows: campaigns.count, by: tableView.sortDescriptors) { key, row in
        Self.value(key, of: campaigns[row])
    }
    tableView.reorderRows(from: previous, to: order)
}

func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
    Self.value(column.id, of: campaigns[order[row]])
}
```

When the table doesn't show those rows yet (a sort restored before the first
reload), it reloads instead. If values changed along with the order, reload.
With your own reordering, ``NGTableView/reorderRows(fromOldIndexes:)`` takes
the previous index of every row, and ``NGSorting/oldIndexes(from:to:)``
computes them from two orders.

When new data arrives, sort it by ``NGTableView/sortDescriptors`` before
reloading, so it stays in the order the header shows. If you replace `columns`
with a definition that no longer has a sorted column, the table drops its sort
and tells the data source.

Set ``NGTableView/sortDescriptors`` yourself for a default sort. The data
source sorts as for a click (a data source set later is told the current
sort), and header clicks continue from it.

### Sorting by the table, live

For live data (a trading screen, a dashboard fed by a socket), let the table
sort: with ``NGTableView/sortsRows`` it orders the rows by
``NGTableView/sortDescriptors`` itself and keeps them in order as values
change. The data source keeps its order and doesn't sort:

```swift
table.sortsRows = true
table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
// A tick of the feed: change the records, then tell the table.
table.reloadData(forRowIndexes: changedRows, columnIndexes: allColumns)
```

- Rows are compared by their cell values (``NGCellValue/sortsBefore(_:)``);
  rows that compare equal keep the data source's order. Where the display
  differs from the order (a budget shown as "CPA $5.00"), return the value to
  sort by from ``NGTableViewDataSource/tableView(_:sortValueFor:row:)``.
  Text sorts like Finder (`localizedStandardCompare:`, numbers in text by
  value), also for `NSSortDescriptor`'s default selector `compare:`; a
  descriptor with `localizedCompare:`, `localizedCaseInsensitiveCompare:`
  or `caseInsensitiveCompare:` sorts its text that way, as an app sorting
  for an NSTableView would. Other selectors and comparator blocks aren't
  called. Targeted updates read a row's sort value again when its column is among
  the reported columns (or isn't a column of the table): if the value
  depends on other columns, report its column too.
- Every row's sort value is read once. Targeted updates read the changed
  rows' values again and move only the rows whose value changed (binary
  search), so on 200,000 rows a tick of 500 changed rows with inserts and
  removes takes about 3 ms; the first sort of 200,000 numbers takes about
  40 ms.
- Full sorts (a reload, a new sort) of tables with at least
  ``NGTableView/synchronousSortLimit`` rows run in the background, where rows
  of text count 16 each (comparing text costs that much more: from about
  3,100 rows of text, 50,000 of numbers, so neither holds the main thread
  more than about 25 ms): the table
  reads the values in slices of a few milliseconds and sorts them off the
  main thread, showing the previous order meanwhile (reversed when only the
  direction changed) while ``NGTableView/isSortingRows`` is `true`. Rows
  that change, come or move meanwhile take their place when it's done, so a
  live feed doesn't keep it from finishing.
- Row indexes in the API stay data source indexes, as with ``NGTableView/rowFilter``:
  the selection, ``NGTableView/clickedRow`` and the delegate follow the
  records wherever they move. Filters show their rows in sorted order, and
  groups keep their rows sorted.
- ``NGTableViewDataSource/tableView(_:sortDescriptorsDidChange:)`` is still
  called, as a notification: don't sort the data there.

### Remembering the sort

With an ``NGTableView/autosaveName``, the sort is saved with the columns
(each descriptor's key, direction and selector, like `NSTableView` saves them)
and restored next time. Set a default sort before the autosave name: a saved
sort replaces it, also an empty one the user chose, and without a saved sort it
stays:

```swift
table.columns = columns
table.sortDescriptors = [NSSortDescriptor(key: "clicks", ascending: false)]
table.autosaveName = "Teasers"   // A saved sort replaces the default.
table.dataSource = data           // Sorts by whichever sort is in effect.
```

Descriptors with a comparator block can't be saved; use a key and a selector.
