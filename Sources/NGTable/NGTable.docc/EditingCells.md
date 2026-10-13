# Editing Cells

Let users move from cell to cell with the keyboard and edit values in place,
like a spreadsheet.

## Overview

Two independent options:

- ``NGTableView/navigatesByCell`` gives the table a focused cell
  (``NGTableView/focusedCell``): Left and Right move it from column to
  column, Tab and Shift-Tab too, Up and Down from row to row (selecting the
  row), and a click focuses the cell clicked. A ring shows it once the keys
  move it; a click, Escape or the table losing the focus hide the ring.
- Columns that are ``NGTableColumn/isEditable`` edit in place.

```swift
NGTableColumn("name", title: "Name", isEditable: true)
NGTableColumn("budget", title: "Budget", format: .currency(code: "USD"), isEditable: true)

table.navigatesByCell = true
```

### Ranges of cells

With navigation by cell, Shift with the arrow keys, a Shift-click or a drag
selects a rectangle of cells from the focused cell
(``NGTableView/selectedCellRange``, an ``NGCellRange`` of two corner cells).
Its rows are the selected rows, so the summary row's "selected rows" scope
covers them; Copy copies the range's cells (or just the focused cell) as
tab-separated text, which pastes into Numbers and Excel as cells; Escape
drops the range. The corners are data source rows and column ids, so after a
sort the range spans the rows between them as shown.

### Editing

A double click on an editable cell, Return on the focused cell, or typing on
it (the text replaces the value) opens a text field over the cell. Typed keys
go to the field itself, so input methods (Japanese, Chinese, accents held
down) compose there as in any text field; the selection keeps its focused
look while the cell is edited. Return
commits and moves down, Tab commits and moves on, Escape cancels; clicking
elsewhere commits. ``NGTableView/editCell(row:columnID:text:)`` starts
editing from code, and so does
``NGTableView/editColumn(_:row:with:select:)``, as with `NSTableView`.
``NGTableView/editedRow`` and ``NGTableView/editedColumn`` tell which cell is
being edited (-1 when none; the row follows its record as rows move), and
``NGTableView/abortEditing()`` throws the text away, e.g. before the app
replaces the data.

The text is read by the column's format: numbers in the user's locale or with
English separators (currency symbols aside, "25%" as 0.25 in percent
columns), dates for date columns, text otherwise; an empty field is `.empty`.
Text that isn't a number where one is due changes nothing.

The data source receives the value, like `NSTableView`'s
`tableView(_:setObjectValue:for:row:)`:

```swift
func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
    switch (column.id, value) {
    case ("name", .text(let name)): campaigns[row].name = name
    case ("budget", .number(let budget)): campaigns[row].budget = budget
    default: break
    }
}
```

The table then reads the row again (its summaries, filter, sort and groups
follow), and registers the change with the window's undo manager: Undo sets
the old value back through the same method. The delegate's
``NGTableViewDelegate/tableView(_:shouldEdit:row:)`` can keep a cell from
being edited.

### Check boxes and lists

Boolean cells of an editable column show a check box. A click on the box
toggles it (and selects the row), as do Space on the focused cell, Return and
a double click. A column with ``NGTableColumn/editChoices`` edits in a menu
of those values instead of a text field: Return or a double click opens it
under the cell, with the current value checked (typing doesn't). Both reach
the data source and Undo the same way as text:

```swift
NGTableColumn("autoBid", title: "Auto bid", alignment: .center, isEditable: true)
NGTableColumn("status", title: "Status", isEditable: true, editChoices: [
    .tags([NGTag("Active", color: .green)]),
    .tags([NGTag("Paused", color: .gray)]),
])
```

Menu items show the values as the column displays them, tags with their
color.

### Ratings

An editable column of `.rating` values is edited without a field: a click on
a star sets it, just before the first one clears it, and a number key sets
the focused cell (see <doc:DisplayingValues>).

### Choices that open on a click

Every cell of an editable column with ``NGTableColumn/editChoices`` shows a
pop-up button's up-down chevron at its trailing edge, so it reads as a menu
before it's clicked. Set ``NGTableColumn/opensChoicesOnClick`` to open the
menu on a single click (selecting the row too), like an `NSPopUpButton` in a
cell; otherwise it opens on a double click or Return.
