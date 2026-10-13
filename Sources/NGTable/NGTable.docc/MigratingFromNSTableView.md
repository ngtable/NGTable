# Migrating from NSTableView

Move a table from `NSTableView` to ``NGTableView`` keeping your data source,
delegate and controller patterns.

## Overview

``NGTableView`` mirrors `NSTableView`'s API where the two tables do the same
thing: the same names for sorting, selection, clicks, menus, targeted updates
and notifications, with the same semantics. What differs is how cells are
made: an `NSTableView` asks for a view per cell, NGTable asks for a *value*
(``NGCellValue``) and draws it itself. That is why it shows millions of rows
smoothly, and it is the one part of a migration that needs real changes.

A migration usually goes in three steps:

1. Replace the scroll view and table with an ``NGTableView`` and define its
   columns (see <doc:DefiningColumns>).
2. Plug in your existing data source with ``NGTableViewDataSourceAdapter``,
   to see your data in the new table right away.
3. Replace the adapter with an ``NGTableViewDataSource`` returning values,
   or with ``NGTableViewDiffableDataSource`` if you used the diffable one.

### Creating the table

An ``NGTableView`` scrolls by itself, with its header, frozen columns and
summary row: don't put it in an `NSScrollView`. Columns are values, defined
all at once in ``NGTableView/columns`` (with groups, if you need them), not
added one by one.

| NSTableView | NGTableView |
| --- | --- |
| `NSScrollView` + `NSTableView` | ``NGTableView`` alone |
| `addTableColumn(_:)`, `removeTableColumn(_:)` | ``NGTableView/columns`` = `[.column(…), .group(…)]` |
| `NSTableColumn(identifier:)` | ``NGTableColumn`` `("id", title:)`; ``NGTableColumn/identifier`` |
| `tableColumns`, `numberOfColumns` | ``NGTableView/tableColumns``, ``NGTableView/numberOfColumns`` (hidden ones included, in the order of ``NGTableView/columns``: frozen columns show in their region) |
| `tableColumn(withIdentifier:)`, `column(withIdentifier:)` | the same |
| `column.isHidden` | ``NGTableView/hiddenColumnIDs`` |
| `column.width`, `minWidth`, `maxWidth`, `resizingMask` | ``NGTableColumn/width``, ``NGTableColumn/minWidth``, ``NGTableColumn/maxWidth``, ``NGTableColumn/isResizable``; ``NGTableView/setWidth(_:forColumnID:)`` |
| `column.headerToolTip` | ``NGTableColumn/toolTip`` |
| `allowsColumnReordering`, `allowsColumnResizing` | the same, and ``NGTableColumn/isMovable``, ``NGTableColumn/isResizable`` per column |
| `moveColumn(_:toColumn:)`, `scrollColumnToVisible(_:)` | the same (moves keep groups together and columns in their frozen region) |
| `rect(ofColumn:)`, `columnIndexes(in:)` | the same (the column over the rows area) |
| `autosaveName`, `autosaveTableColumns` | ``NGTableView/autosaveName`` (order, widths, hidden columns and sort) |
| `rowHeight`, `usesAlternatingRowBackgroundColors` | the same |
| `gridStyleMask`, `gridColor` | the same (vertical, solid and dashed horizontal lines) |
| `backgroundColor` | the same (the table style's background) |
| `intercellSpacing` | the same, added to the table's own spacing (`.zero` by default) |
| `style` | the same: inset, source list and automatic draw rows inset and rounded; full width and plain across the table |
| `rowSizeStyle` | the same, as ``NGTableView/density`` (small, medium, large; custom is a `rowHeight` of your own) |
| `headerView = nil` | ``NGTableView/showsHeader`` `= false` |
| `columnAutoresizingStyle`, `sizeLastColumnToFit()`, `sizeToFit()` | the same; the default is no autoresizing (NSTableView's is uniform) |
| `selectionHighlightStyle` | ``NGTableView/selectionHighlightStyle`` |

Frozen columns (``NGColumnPin``), column groups and the summary row have no
`NSTableView` counterpart; see <doc:DefiningColumns> and <doc:Summaries>.

### The data source

Rows are data source rows as in `NSTableView`; the cell is a value:

| NSTableView | NGTableView |
| --- | --- |
| `numberOfRows(in:)` | ``NGTableViewDataSource/numberOfRows(in:)`` |
| `tableView(_:objectValueFor:row:)` | ``NGTableViewDataSource/tableView(_:valueFor:row:)`` returning an ``NGCellValue`` |
| `tableView(_:viewFor:row:)` with a cell view | a value and a column ``NGTableColumn/format``; pictures and videos as ``NGMedia`` (see <doc:DisplayingValues>) |
| `tableView(_:sortDescriptorsDidChange:)` | the same: sort, then `reloadData()`, or ``NGTableView/reorderRows(from:to:)`` so nothing is read again |
| — | ``NGTableViewDataSource/tableView(_:identifierForRow:)``: a stable identity, so the selection follows records |
| `NSTableViewDiffableDataSource` | ``NGTableViewDiffableDataSource`` with a value provider |
| `NSDiffableDataSourceSnapshot` | ``NGDiffableDataSourceSnapshot``, same methods (or convert one) |

Cell views map to values: a text field to `.text` or `.number` with a
format, a check box to `.bool`, a date picker to `.date`, a row of badges to
`.tags`, an image view (with labels beside it) to `.media`. There are no
custom cell views: every cell is drawn by the table's GPU renderer.

#### Plugging in an existing data source

``NGTableViewDataSourceAdapter`` makes an `NSTableViewDataSource` work
unchanged: it gives it an `NSTableView` stand-in whose columns, sort
descriptors and selection are the table's, and whose `reloadData()`,
`insertRows(at:withAnimation:)` and the like go to the ``NGTableView``. Object
values become cell values (strings, numbers, Booleans, dates, attributed
strings), or convert them yourself. Edits go back through
`tableView(_:setObjectValue:for:row:)`, and dragging rows through
`tableView(_:pasteboardWriterForRow:)`, `validateDrop` and `acceptDrop`, so
an editable or reorderable table keeps working too.

```swift
let adapter = NGTableViewDataSourceAdapter(campaignsDataSource)
adapter.identifierForRow = { [weak campaignsDataSource] row in campaignsDataSource?.campaigns[row].id }
table.dataSource = adapter   // Keep the adapter: the table holds it weakly.
```

The adapter is a bridge: each value goes through `Any`, and view-based cells
don't carry over. Once the table works, write an ``NGTableViewDataSource``
with the same methods returning values.

#### Diffable data sources

``NGTableViewDiffableDataSource`` takes snapshots like AppKit's, with a value
provider instead of a cell provider. Rename the snapshot type; your code that
builds snapshots stays as it is:

```swift
// Before
let dataSource = NSTableViewDiffableDataSource<Section, Campaign.ID>(tableView: table) { table, column, row, id in
    let cell = table.makeView(withIdentifier: column.identifier, owner: nil) as! NSTableCellView
    cell.textField?.stringValue = store.text(of: id, for: column.identifier)
    return cell
}
var snapshot = NSDiffableDataSourceSnapshot<Section, Campaign.ID>()

// After
let dataSource = NGTableViewDiffableDataSource<Section, Campaign.ID>(tableView: table) { _, column, _, id in
    store.value(of: id, for: column.id)
}
var snapshot = NGDiffableDataSourceSnapshot<Section, Campaign.ID>()

snapshot.appendSections([.main])
snapshot.appendItems(store.ids)
snapshot.reloadItems(changedIDs)
dataSource.apply(snapshot)
```

Unlike AppKit's, the snapshot remembers ``NGDiffableDataSourceSnapshot/reloadItems(_:)``,
so only the changed records are read again. Sorting goes to the data source's
``NGTableViewDiffableDataSource/sortDescriptorsDidChange`` closure: apply a
snapshot in the new order. Sections show as groups with
``NGTableViewDiffableDataSource/sectionTitleProvider`` (otherwise they are
flattened into one list of rows); to group by a column, see <doc:GroupingRows>.

### The delegate

Selection, clicks and column notifications have the same names and the same
notification objects and userInfo keys:

| NSTableView | NGTableView |
| --- | --- |
| `tableViewSelectionDidChange(_:)`, `tableViewSelectionIsChanging(_:)` | the same; also ``NGTableView/selectionDidChangeNotification`` |
| `selectionShouldChange(in:)`, `tableView(_:shouldSelectRow:)` | the same |
| `tableView(_:selectionIndexesForProposedSelection:)` | the same |
| `tableViewColumnDidResize(_:)`, `tableViewColumnDidMove(_:)` | the same (`NSTableColumn`, `NSOldWidth`, `NSOldColumn`, `NSNewColumn`) |
| `tableView(_:didClick:)`, `tableView(_:mouseDownInHeaderOf:)`, `tableView(_:didDrag:)` | the same |
| `tableView(_:shouldReorderColumn:toColumn:)` | the same, for single columns (whole groups move without asking) |
| `tableView(_:sizeToFitWidthOfColumn:)` | the same; `nil` sizes the column to fit |
| `tableView(_:userCanChangeVisibilityOf:)`, `tableView(_:userDidChangeVisibilityOf:)` | the same, for the header menu |
| `tableView(_:toolTipFor:rect:tableColumn:row:mouseLocation:)` | ``NGTableViewDelegate/tableView(_:toolTipForRow:column:)``; cells too narrow for their text show it by default |
| `tableView(_:typeSelectStringFor:row:)` | the same; `nil` matches the cell's text, an empty string leaves the row out |
| `tableView(_:shouldTypeSelectFor:withCurrentSearch:)` | the same; `false` passes the key on |
| `tableView(_:nextTypeSelectMatchFromRow:toRow:for:)` | the same, by display index; a search that wraps asks twice instead of with `endRow < startRow` |
| `tableView(_:rowViewForRow:)` for tints | ``NGTableViewDelegate/tableView(_:backgroundColorForRow:)``, ``NGTableViewDelegate/tableView(_:markerColorForRow:)`` |
| `menuNeedsUpdate` with `clickedRow` | ``NGTableViewDelegate/tableView(_:menuForRows:clickedRow:column:)``, or the table's `menu` with ``NGTableView/clickedRow`` |
| `tableView(_:heightOfRow:)` | one ``NGTableView/rowHeight`` for all rows |

### Selection, actions and sorting

| NSTableView | NGTableView |
| --- | --- |
| `selectedRowIndexes`, `selectedRow`, `numberOfSelectedRows` | the same |
| `selectRowIndexes(_:byExtendingSelection:)`, `deselectRow(_:)`, `deselectAll(_:)`, `isRowSelected(_:)` | the same |
| `allowsMultipleSelection`, `allowsEmptySelection` | the same |
| `allowsColumnSelection`, `selectColumnIndexes(_:byExtendingSelection:)`, `selectedColumnIndexes`, `selectedColumn`, `tableView(_:shouldSelect:)` | the same; `allowsColumnSelection` is `false` by default |
| `target`, `action`, `doubleAction` | the same, and ``NGTableView/returnAction`` for Return with rows selected (NSTableView has none) |
| `clickedRow`, `clickedColumn` (-1 when none) | the same |
| `row(at:)`, `column(at:)` | the same |
| `sortDescriptors`, `column.sortDescriptorPrototype` | the same; the data source sorts, or the table with ``NGTableView/sortsRows`` (live) |
| `allowsTypeSelect` | the same; ``NGTableView/typeSelectColumnID`` picks the column |
| `scrollRowToVisible(_:)` | the same |
| `rect(ofRow:)` | the same |
| `rows(in:)` | ``NGTableView/rowIndexes(in:)-(NSRect)`` (an `IndexSet`: shown rows needn't be consecutive data source rows) |
| `frameOfCell(atColumn:row:)` | the same, also for rows out of view; ``NGTableView/frameOfCell(row:columnID:)`` for visible cells |
| `tableView(_:rowActionsForRow:edge:)`, `rowActionsVisible` | the same, with ``NGRowAction`` instead of `NSTableViewRowAction` (same initializer, style and `backgroundColor`; AppKit keeps that class's handler to itself) |

### Updating rows

| NSTableView | NGTableView |
| --- | --- |
| `reloadData()` | the same; the selection follows records with row identities |
| `reloadData(forRowIndexes:columnIndexes:)` | the same; the rows' summaries follow every column, their search words, sort and group keys and column filters the columns named |
| `insertRows(at:withAnimation:)`, `removeRows(at:withAnimation:)`, `moveRow(at:to:)` | the same; any animation option slides, fades in and fades out (`moveRow` animates in an animated batch) |
| `beginUpdates()`, `endUpdates()` | the same |
| `noteNumberOfRowsChanged()` | the same |
| `hideRows(at:withAnimation:)`, `unhideRows(at:withAnimation:)`, `hiddenRowIndexes` | the same (no animations yet); hidden rows leave the summaries too |
| — | ``NGTableView/reorderRows(from:to:)``: the same rows in another order (after sorting), nothing read again |

See <doc:IntegratingIntoAnApp> for live updates.

## Differences from NSTableView

Everything not listed here works like `NSTableView`, with the same names.
These are the deliberate differences, and why.

### Model

- term Cells are values, not views: The data source returns an
  ``NGCellValue`` (text, number, date, tags, media…) and the table draws it
  with Metal. There's no `tableView(_:viewFor:row:)`, `rowView(forRow:)`,
  `makeView(withIdentifier:owner:)`, `NSCell`, cell nibs or Interface Builder
  tables: build the table in code. Drawing values is what keeps 100,000 rows
  and live updates fast.
- term Controls in cells are values too: What apps put in `NSTableCellView`s
  has a value kind the table draws and tracks:

  | In an NSTableView cell | In NGTable |
  | --- | --- |
  | `NSButton` check box | `.bool` in an editable column (a check box; Space toggles it) |
  | `NSButton` push button | `.button(NGCellButton)`; the delegate's `tableView(_:didPressButton:in:row:)` |
  | `NSPopUpButton` | `editChoices` on the column (a menu of choices, with the chevron); `opensChoicesOnClick` for a single click |
  | A link (`NSTextField` with a link, an inline `NSButton`) | `.link(NGLink)`; the delegate's `tableView(_:didClickLink:in:row:)` |
  | `NSImageView`, `AVPlayerView` | `.media(NGMedia)` (pictures and videos by URL) |
  | `NSProgressIndicator` (bar) | `.progress(value, total:)`, `nil` for indeterminate |
  | `NSLevelIndicator` (rating style) | `.rating(value, maximum:)`, set by clicks in an editable column |
  | `NSLevelIndicator`, a bar | a data bar (``NGConditionalFormat``) |
  | A custom chart view | `.sparkline(NGSparkline)` |
- term Columns are values: ``NGTableColumn`` is a struct with a string `id`
  (NSTableView's `NSTableColumn` objects with `NSUserInterfaceItemIdentifier`),
  set as a whole in ``NGTableView/columns``. Column groups and frozen columns
  have no NSTableView counterpart.
- term Shown rows and data source rows: ``NGTableView/numberOfRows`` is the
  number of rows *shown* (after filters, with group header rows, without
  collapsed rows); every other row index in the API is a data source row, and
  ``NGTableView/numberOfSourceRows`` is the data source's count. NSTableView has
  only one kind of row. ``NGTableView/displayIndex(ofRow:)`` and
  ``NGTableView/row(atDisplayIndex:)`` go between the two, and
  ``NGTableView/selectedRowIndexesInDisplayOrder`` lists the selected rows as
  shown (when the table sorts, filters or groups them).
- term Selection identity: With ``NGTableViewDataSource/tableView(_:identifierForRow:)``
  the selection follows records across `reloadData()`; NSTableView keeps row
  indexes.

### Rows

- term One row height: There's no `tableView(_:heightOfRow:)` or
  `usesAutomaticRowHeights`: every row has ``NGTableView/rowHeight`` (deferred:
  dense tables keep one height, and rows under the pointer never shift).
- term Group rows: Built in (``NGTableView/rowGrouping``) instead of the
  delegate's `tableView(_:isGroupRow:)` and the app inserting header rows.
- term Outline views: Trees are ``NGTableView/rowTree``: rows name their
  parents (`parentIdentifierForRow`) instead of an outline data source
  answering `child(_:ofItem:)`, and `expandItem`, `collapseItem`,
  `level(forRow:)` and `parent(forItem:)` become
  ``NGTableView/expandRow(_:expandChildren:)``,
  ``NGTableView/collapseRow(_:collapseChildren:)``, ``NGTableView/level(forRow:)``
  and ``NGTableView/parentRow(forRow:)``, by data source row. A diffable data
  source's sections show as groups with `sectionTitleProvider`.
- term Search, filters and sorting: Built in (``NGTableView/rowFilter``,
  ``NGTableView/columnFilters``, and ``NGTableView/sortsRows`` to let the table
  sort); without them the data source sorts, as with NSTableView.
- term Header clicks: Like NSTableView's, a click puts the column's sort first
  and a click on the first sort reverses it; one more click after the user
  reversed it removes it (NSTableView keeps reversing), back to the data's
  order when no other sort is left. A sort set in code is reversed by a click.
- term Animations: The `withAnimation:` options look as NSTableView's: moved
  rows slide, and rows come and go fading (`.effectFade`), sliding up, down,
  left or right (`.slideUp`…, fading too) or in a gap (`.effectGap`).
  `hideRows` and `unhideRows` animate like removes and inserts. A batch
  takes its first update's options.

### Appearance

- term Two looks: ``NGTableView/style`` and ``NGTableView/selectionHighlightStyle``
  choose rows inset with rounded corners (`.inset`, `.sourceList`,
  `.automatic`; ``NGSelectionHighlightStyle/rounded``) or across the table
  (`.fullWidth`, `.plain`; ``NGSelectionHighlightStyle/fullWidth``). There's no
  sidebar (source list) look and no `.none` highlight.
- term The header: ``NGTableView/showsHeader`` instead of setting `headerView`
  to `nil`; there are no custom header views or `cornerView`.
- term Spacing: ``NGTableView/intercellSpacing`` is added to the table's own
  spacing and is `.zero` by default (NSTableView's default is 3 × 2 points).
- term Row size: ``NGTableView/rowSizeStyle`` sets ``NGTableView/density``;
  `.custom` means a ``NGTableView/rowHeight`` of your own.
- term Right to left: Mirrored like NSTableView, with one difference in
  ``NGTableView/contentOffset``: it counts from the leading end (0 shows the
  first columns, at the right), where a scroll view's origin is at the left.
- term Scrolling: The table scrolls itself, without an `NSScrollView`
  of its own. Observe
  ``NGTableView/didScrollNotification`` instead of the clip view's
  `boundsDidChangeNotification` and the table's live scroll notifications
  instead of the scroll view's, and scroll with ``NGTableView/scroll(to:)``
  instead of the clip view's `scroll(to:)`.
- term Column autoresizing: ``NGTableView/columnAutoresizingStyle`` is
  `.noColumnAutoresizing` by default (NSTableView's is uniform), so existing
  widths stay when the table resizes.

### Interaction

- term Swipe actions: ``NGTableViewDelegate/tableView(_:rowActionsForRow:edge:)``
  returns ``NGRowAction``s, not `NSTableViewRowAction`s: AppKit keeps that
  class's handler private. The initializer, style and `backgroundColor` are
  the same. A table that scrolls sideways scrolls first; actions open at its
  edge.
- term Editing: Columns that are ``NGTableColumn/isEditable`` edit in a text
  field, a check box or a menu of ``NGTableColumn/editChoices`` over the cell;
  the data source receives the value in
  ``NGTableViewDataSource/tableView(_:setValue:for:row:)`` (NSTableView's
  `setObjectValue`), with Undo. There are no editor views of your own (see
  <doc:EditingCells>).
- term Cell frames: ``NGTableView/frameOfCell(atColumn:row:)`` works like
  NSTableView's, also out of view; ``NGTableView/frameOfCell(row:columnID:)``
  gives only visible cells.
- term Drag and drop: The same data source methods (`pasteboardWriterForRow`,
  `validateDrop`, `acceptDrop`), drops between and onto rows,
  `setDropRow(_:dropOperation:)`, `verticalMotionCanBeginDrag` and scrolling
  near the edges while dragging, and the dragging session calls
  (`draggingSession(_:willBeginAt:forRowIndexes:)`,
  `draggingSession(_:endedAt:operation:)` for drags to the Trash,
  `updateDraggingItemsForDrag`) with
  ``NGTableView/draggedRowIndexes`` following the records meanwhile.
  ``NGTableView/draggingDestinationFeedbackStyle`` works the same: `.gap`
  opens a gap between the rows where the drop goes, `.none` shows nothing.
  The proposed and accepted rows are data source rows (with
  ``NGTableView/sortsRows`` or groups, not the rows shown). A table that
  sorts its rows puts moved rows back in sort order, so to reorder by
  dragging, clear ``NGTableView/sortDescriptors`` in `acceptDrop` before
  moving the rows.
