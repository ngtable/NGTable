# Filtering and Search

Show only some rows, for a search field or switches like "active only", while
the data source keeps all of them.

## Overview

Set an ``NGRowFilter`` as the table's ``NGTableView/rowFilter``. The table
hides the rows it rejects; your data and its indexes stay as they are. The
table has no search field of its own: use any control you like (an
`NSSearchField` in the toolbar, a button that turns into a field) and set the
filter from its action.

```swift
@objc func searchChanged(_ sender: NSSearchField) {
    updateFilter()
}

func updateFilter() {
    var filter = NGRowFilter(searchText: searchField.stringValue)
    if activeOnly.state == .on {
        filter.isIncluded = { [weak self] row in
            self?.data.campaigns[row].status == .active
        }
    }
    table.rowFilter = filter
}
```

Set `rowFilter` to `nil` to show every row.

### How search matches

Every word of the search text must be the beginning of a word in one of the
searched columns, ignoring case and diacritics, like Finder and Mail:

| Search | Finds | Doesn't find |
| --- | --- | --- |
| `anna` | "Anna Schmidt", "Summer sale — Anna" | "Joanna", "Savannah" |
| `sum sale` | "Summer sale" | "Summer campaign" |
| `cafe` | "Café Berlin" | |
| `cmp-10` | "CMP-10023" | |

Words are runs of letters and digits, so punctuation separates them. By
default the table searches the shown columns with text, tags and marks, as
displayed; columns with a number format (number, currency, percent) aren't
read at all. To search other columns, including hidden ones or formatted
numbers, list them:

```swift
// Search names and campaign ids, even though the id column is not shown.
NGRowFilter(searchText: text, columnIDs: ["name", "id"])
```

The table builds a search index the first time it searches, so typing more
letters only compares prefixes. The index is rebuilt after `reloadData()`.
Tables with at least ``NGTableView/synchronousSearchLimit`` cells to search
(rows × searched text columns, 50,000 by default) read the words in slices
of a few milliseconds, keeping the app
responsive, and show the previous rows until the filter applies
(``NGTableView/isSearchingRows``); the texts read are split into words on all
cores. On 1,000,000 rows with a text column and ten number columns the first
search takes about 0.4 s in all; later ones about 0.1 s. Its last step,
putting the index together, isn't sliced: about 50 to 90 ms on the main
thread for a million rows.

Targeted updates filter only the changed rows again, and read the search
words only of rows whose searched columns changed (as reported by
``NGTableView/reloadData(forRowIndexes:columnIndexes:)``): report only the
columns that changed, and a feed of changing numbers doesn't touch the
words. The totals follow the changed rows too.

### Column filters

With ``NGTableView/allowsColumnFilters``, a column's header shows a filter
button while the pointer is over it (and always while the column has a
filter), like a spreadsheet's: number columns filter by a range or the top
or bottom rows, date columns by a period, other columns by their values,
checked in a list with counts. The filters are in
``NGTableView/columnFilters`` (by column id), so the app can set them too:

```swift
table.allowsColumnFilters = true
table.columnFilters = [
    "status": .values(["Active", "Paused"]),
    "network": .excluding(["Test"]),
    "spend": .range(min: 100, max: nil),
    "name": .contains("summer"),
    "created": .dates(.lastDays(30)),
    "profit": .top(10),
]
```

`.values` shows only the values listed, `.excluding` every value but those:
unchecking a few values in the list gives `.excluding`, so values it doesn't
show (it lists at most 1,000) or that arrive later stay shown; checking a few
among many gives `.values`.

`.dates` takes an ``NGDatePeriod``: today, yesterday, this or last week,
month or year, the last days, or between two instants. Periods are days of
``NGTableView/calendar`` (the user's time zone and first weekday by
default), taken from the day the rows are filtered on: a table left open
overnight shows yesterday's "today" until its rows change or the filter is
set again. `.top(10)` and `.bottom(10)` show the rows with the 10 largest
or smallest numbers of the column, and those tied with the last of them,
like a spreadsheet's "Top 10": of all the rows, whatever the other filters
show (so with another filter there may be fewer). They read the column
again when rows come, go or move or its values change.

By keyboard, Option-Down Arrow on a focused cell (``NGTableView/navigatesByCell``)
opens its column's filter, like a spreadsheet; an app can open one from a
menu with ``NGTableView/showFilter(forColumnID:)``. In the filter, Tab goes
between the controls, Down Arrow from the search field into the values,
and Space checks or unchecks the selected values.

A row shows when it passes every column filter, the search and
`isIncluded`. The table keeps whether each row passes each column filter: a
search keystroke doesn't read the filtered columns again, and live updates
check only the rows whose filtered columns changed; the summaries follow. The filters are saved with
``NGTableView/autosaveName``; the delegate hears of the user's changes in
``NGTableViewDelegate/tableView(_:didChangeColumnFilters:)``. Turn the button
off for a column with ``NGTableColumn/isFilterable``.
``NGTableView/filterValues(forColumnID:limit:)`` gives the values a filter
offers, among the rows everything else lets through (the other column
filters, the search, `isIncluded` and hidden rows).

### Filtering by your own conditions

`isIncluded` receives data source row indexes, so it can look at your model
directly. A row is shown when it passes both the search and `isIncluded`.

- Capture `self` weakly: the table keeps the closure.
- It is called on the main thread for every row whenever the filter is applied,
  so keep it cheap.
- When the condition behind it changes (e.g. a date range picker), set the
  filter again. When the data changes, ``NGTableView/reloadData()`` filters
  again by itself.

### Row indexes while filtering

The API uses data source row indexes throughout, also while rows are hidden:

- ``NGTableView/selectedRowIndexes``, ``NGTableView/clickedRow`` and the rows
  passed to the delegate are indexes into your data;
- ``NGTableView/selectRowIndexes(_:byExtendingSelection:)`` and
  ``NGTableView/scrollRowToVisible(_:)`` take them too, ignoring hidden rows;
- ``NGTableView/numberOfSourceRows`` is the data source's count;
  ``NGTableView/numberOfRows`` (also ``NGTableView/numberOfDisplayedRows``) is the
  number of rows shown.

Summaries, Select All, copying and VoiceOver only cover the rows shown. Rows
the filter hides leave the selection; clearing the search doesn't bring them
back.

### Empty results

While no rows are shown, the table shows ``NGTableView/emptyStateText``, or
your own ``NGTableView/emptyStateView``. When the filter hides every row, it
shows in the rows area and the columns stay in view; without any data at all,
the table shows nothing else (see <doc:Appearance>). Change the text to fit
the situation:

```swift
table.emptyStateText = table.rowFilter?.isEmpty == false
    ? "No campaigns match the search"
    : "No campaigns in this period"
```
