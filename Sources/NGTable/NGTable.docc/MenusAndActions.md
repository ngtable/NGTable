# Menus and Actions

Offer your app's actions in the rows' context menu, and copy rows to other apps.

## Overview

The table has three context menus:

| Where | Menu | Built by |
| --- | --- | --- |
| Rows | Your actions for the clicked rows | Your delegate |
| Header | Show and hide columns (see <doc:DefiningColumns>) | The table |
| Summary row | Summary scope (see <doc:Summaries>) | The table |

### The rows' context menu

Right-clicking (or Control-clicking) rows asks the delegate for a menu with
``NGTableViewDelegate/tableView(_:menuForRows:clickedRow:column:)``. The table
adds no items of its own. It decides which rows the menu is for, like Finder
and Mail:

- a click on a selected row is for the whole selection;
- a click on another row is for that row only: it gets an outline while the
  menu is open, and the selection stays as it is;
- a click below the last row is for no rows (`rows` is empty, `clickedRow` is
  `nil`), for actions like "New Campaign".

Group header rows (see <doc:GroupingRows>) don't ask the delegate: they show
the table's own menu to collapse or expand the group, or all groups.

```swift
func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet,
               clickedRow: Int?, column: NGTableColumn?) -> NSMenu? {
    guard !rows.isEmpty else { return nil }
    // Keep ids, not row indexes: the data may be reloaded while the menu is open.
    let ids = rows.map { data.campaigns[$0].id }
    let menu = NSMenu()
    let pause = NSMenuItem(title: rows.count == 1 ? "Pause Campaign" : "Pause \(rows.count) Campaigns",
                           action: #selector(pauseCampaigns(_:)), keyEquivalent: "")
    pause.target = self
    pause.representedObject = ids
    menu.addItem(pause)
    return menu
}

@objc func pauseCampaigns(_ sender: NSMenuItem) {
    guard let ids = sender.representedObject as? [String] else { return }
    campaignService.pause(ids)
}
```

Return `nil` to show no menu, or the table's own `menu` if you set one, like
an `NSTableView`'s: an app moving from `NSTableView` can keep its menu and
read ``NGTableView/clickedRow`` in its actions. `column` is the column under
the pointer, for actions like "Copy Value". ``NGTableView/clickedRow`` (and
``NGTableView/clickedColumn``) also hold the clicked row while the menu's
actions run, like `NSTableView.clickedRow`; it is -1 below the rows and after
the data is reloaded or filtered.

### Actions from buttons and the keyboard

For toolbar buttons and menu bar items, act on
``NGTableView/selectedRowIndexes``, and update their state in
``NGTableViewDelegate/tableViewSelectionDidChange(_:)`` or in your
`validateMenuItem(_:)`. For opening a record, set
``NGTableView/doubleAction`` (see <doc:SelectionAndSorting>).

### Anchoring to a cell

``NGTableView/frameOfCell(row:columnID:)`` gives a visible cell's frame in the
table's coordinates, e.g. to show a popover for editing a bid or a budget next
to it:

```swift
func editBudget(row: Int) {
    guard let frame = table.frameOfCell(row: row, columnID: CampaignColumn.spend) else { return }
    budgetPopover.show(relativeTo: frame, of: table, preferredEdge: .maxY)
}
```

It is `nil` when the cell isn't visible (scrolled away, filtered out or in a
hidden column): scroll it into view first with
``NGTableView/scrollRowToVisible(_:)``. For Quick Look's `sourceFrameOnScreen`,
convert it to the screen:

```swift
table.window?.convertToScreen(table.convert(frame, to: nil))
```

### Copying

Edit > Copy (Command-C) copies the selected rows as tab-separated text: the
visible columns in display order, values as displayed. It pastes into Numbers,
Excel and Google Sheets as cells. The table validates Copy and Select All menu
items itself, so the standard Edit menu items work once they are in your main
menu:

```swift
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
```

For "Copy" in the rows' context menu, or to export, use
``NGTableView/copyText(forRows:)``:

```swift
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(table.copyText(forRows: rows), forType: .string)
```

### Dragging rows

Like `NSTableView`, the data source decides: a pasteboard writer for a row
makes it draggable (the selected rows drag together when the row is one of
them), and a table registered for dragged types takes drops between rows.

```swift
table.registerForDraggedTypes([.campaignRow])

func tableView(_ tableView: NGTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
    let item = NSPasteboardItem()
    item.setString(campaigns[row].name, forType: .string)
    item.setString(String(row), forType: .campaignRow)
    return item
}

func tableView(_ tableView: NGTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
               proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
    guard (info.draggingSource as? NGTableView) === tableView else { return [] }
    // Rows only reorder: a drop onto a row goes above it.
    if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
    return .move
}

func tableView(_ tableView: NGTableView, acceptDrop info: any NSDraggingInfo, row: Int,
               dropOperation: NSTableView.DropOperation) -> Bool {
    // Move the records, then tell the table (moveRow(at:to:) in a batch).
}
```

Like `NSTableView`, the table proposes a drop onto a row (`.on`) while the
pointer is over the middle of it, and above the nearest row (`.above`)
otherwise. ``NGTableView/setDropRow(_:dropOperation:)`` retargets it from
`validateDrop`: above instead of onto rows for a list that only reorders, or
row -1 with `.on` for the whole table. A line between the rows, a highlight
on the row or a frame around the rows shows where a drop would go. Near the
top or bottom edge of the rows a drag scrolls them, faster closer to the
edge. Rows are data source rows: a drop above a row goes above that record,
at the end the row is ``NGTableView/numberOfSourceRows``.

Draggable rows drag instead of extending the selection by dragging; with
``NGTableView/verticalMotionCanBeginDrag`` set to `false`, dragging up or
down from a row that isn't selected selects rows instead, and a sideways drag
drags it. Pressing one of several selected rows keeps them selected until
the mouse goes up, so they drag together. ``NGTableView/setDraggingSourceOperationMask(_:forLocal:)``
sets what drags allow inside and outside the app.

### Printing

``NGTableView/printView(_:)``, AppKit's `print:` action, prints the rows
shown with the visible columns: the column titles on every page, group header
rows, the summary row at the end, in black on white whatever the screen's
appearance. Columns that wrap text print it wrapped, rows as high as it.
Give the File menu a "Print…" item without a target, and it goes
to the focused table. Columns wider than the paper are scaled to its width;
with ``NGTableView/printPagination`` `.automatic` they go on across pages
instead, in bands of whole columns with the columns pinned at the leading
edge on every band, and `.clip` cuts them off. The print panel has the
table's options (only the selected rows, the summary row; the preview follows
them) and your own ``NGTableView/printPanelAccessories``; the operation shows
its progress. ``NGTableView/makePrintOperation()`` gives that operation to
run yourself, ``NGTableView/pdfData(options:printInfo:)`` makes the same
pages as a PDF, ``NGTableView/pagesView(options:printInfo:)`` the view that
draws them (for a print operation of your own).

### Exporting

``NGTableView/exportDocument(_:)`` asks where to save the rows shown, as an
Excel workbook or CSV, and saves them: give it an "Export…" item in the File
menu, without a target, and it goes to the focused table. It suggests
``NGTableView/exportFileName`` as the name.

```swift
fileMenu.addItem(NSMenuItem(title: "Export…", action: #selector(NGTableView.exportDocument(_:)), keyEquivalent: "E"))
table.exportFileName = "Campaigns"
```

To export from code, ask for the file's contents or write it:

```swift
let data = await table.exportedData(as: .xlsx, options: NGExportOptions(rows: .selected))
try await table.export(to: url, as: .csv)
```

An export has the visible columns in display order and the rows shown
(filtered, sorted, without group headers), or the selected ones, and the
summary row. CSV has the displayed texts, in UTF-8 with a byte order mark so
Excel reads any language. The workbook keeps numbers, dates and check marks
as values, in number formats like the columns' (currency, percent, fraction
digits), with a bold header row that stays in view and the columns' widths.
Values are read in slices, keeping the app responsive (``NGTableView/isExporting``),
and written into the file as they come, formatted (and for a workbook,
compressed) on all cores: an export holds a chunk of rows, not the file, and
the file appears when it is done. A million rows of 20 columns take about
3.5 s as a workbook and 10 s as CSV (formatting numbers as displayed costs
most), with about 50–110 MB more memory meanwhile. `exportedData(as:options:)`
builds the file in memory: for large tables write it with `export(to:as:options:)`.
The summary row is the table's, in its summary scope, also when only the
selected rows are exported.
