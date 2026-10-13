# Using NGTable in SwiftUI

Show rows in SwiftUI like with `Table`, with NGTable's speed and features.

## Overview

``NGDataTable`` mirrors SwiftUI's `Table`: an array of `Identifiable` rows,
columns of values, and a selection and a sort order bound to your state.
Columns are ``NGDataColumn``s (like `TableColumn(_:value:)`) built in a closure,
with `if` and `for` like `TableColumnBuilder`:

```swift
struct CampaignsView: View {
    @State private var campaigns: [Campaign] = []
    @State private var selection: Set<Campaign.ID> = []

    var body: some View {
        NGDataTable(campaigns, selection: $selection) {
            NGDataColumn("Name", value: \.name)
                .width(min: 120, ideal: 220)
            NGDataColumnGroup("Metrics") {
                NGDataColumn("Spend", value: \.spend, format: .currency(code: "USD"), summary: .aggregate(.sum))
                NGDataColumn("Clicks", value: \.clicks, format: .number(fractionDigits: 0), summary: .aggregate(.sum))
            }
        }
        .rowContextMenu { ids in
            Button("Archive") { archive(ids) }
        } primaryAction: { ids in
            open(ids)
        }
    }
}
```

Like `Table`, a double click on a row and Return run `primaryAction` for
the rows (the clicked one, or the selection); a selection binding of one
`Row.ID?` allows one row at a time. The menu's content gets the view's
environment (`@Environment` values such as your model).

Values are what ``NGCellValueConvertible`` types give: strings, numbers,
`Decimal`, dates, Booleans, ``NGTag``s, ``NGMark``s, ``NGMedia``, optionals of
them, or an ``NGCellValue``. A column of anything else takes a closure:
`NGDataColumn("Status", id: "status") { .tags([$0.status.tag]) }`.

### Updates

SwiftUI hands the view the whole new array on every update; an AppKit app
tells the table what changed instead (`reloadData(forRowIndexes:columnIndexes:)`,
`insertRows(at:)`). So ``NGDataTable`` finds the changes itself, by the rows'
identities: it walks the old and the new array together, and a feed's few
inserted, removed and moved rows become the same targeted inserts, removes
and moves an AppKit app would make (when very many rows moved, all are mapped
to their new places at once). For rows that are `Equatable`, only the rows
whose values changed are read again; make your rows `Equatable`, or every
row is. Rows are best values (structs). Rows that are `@Observable` objects
work too, as a `Table`'s cells follow them: the table follows the values it
reads of each row, and rows that change are read again together on the next
turn of the run loop (their cells, the summaries, the sort and the search).
Following costs once per row when the table first reads it (100,000 rows of
10 summed columns open in about 100 ms instead of 15 ms). Objects that
aren't `@Observable` change without a new array, so the table can't see it
(it warns once, in the log).

The same live feed on 200,000 rows, a tick of 500 changed values, 2 inserts
and 2 removes:

| | Per tick |
| --- | --- |
| AppKit, the app telling the table what changed | 2.2 ms |
| SwiftUI, ``NGDataTable`` finding it | 2.9 ms |

Everything else (drawing, scrolling, sorting, summaries, search) is the same
``NGTableView`` either way.

The selection binding follows the same records when rows move. Selections are
`Set<Row.ID>`, or `Row.ID?` for one row at most.

### Editing

Like SwiftUI's `Table($rows)`, pass a binding of the rows, and mark columns
``NGDataColumn/editable(_:choices:)``: the table edits their cells and writes
the values into your array, with Undo.

```swift
NGDataTable($tasks) {
    NGDataColumn("Title", value: \.title).editable()                 // Typed in place.
    NGDataColumn("Hours", value: \.hours, format: .number(fractionDigits: 1)).editable()
    NGDataColumn("Done", value: \.isDone).editable()                 // A check box.
    NGDataColumn("Priority", value: \.priority).editable(choices: [
        .tags([NGTag("Low")]), .tags([NGTag("High", color: .red)]),
    ])                                                               // A menu.
}
```

Text and numbers are parsed by the column's format, as in the AppKit table
(see <doc:EditingCells>). A column edits when its key path is writable and its
type is ``NGCellValueEditable`` (strings, numbers, `Decimal`, Booleans, dates,
tags, optionals of them); computed properties and tables of plain arrays
don't edit.

``NGDataTable/onSubmit(_:)`` runs after the user's edit of a cell is written
into its row, like `onSubmit` on a `Table`'s text fields (not for Undo).

### Sorting

There are two ways, as you choose:

- With a `sortOrder` binding of `KeyPathComparator`s, as with SwiftUI's
  `Table`: a click on a column's header sets the comparators, and you sort
  the array (`campaigns.sort(using: sortOrder)`). Columns of `Comparable`
  values sort; others don't.
- Without one, the table sorts the rows itself (``NGTableView/sortsRows``),
  live as values change, and your array keeps its order.

### Rows with children

Like `Table(_:children:)`, rows with a key path to their children show as a
tree, collapsed at first; the user opens rows with the triangle, the arrow
keys or VoiceOver. ``NGDataTable/expandedRows(_:)`` binds the open rows,
like `DisclosureTableRow(isExpanded:)` for each of them:

```swift
NGDataTable(folders, children: \.subfolders) {
    NGDataColumn("Name", value: \.name)
    NGDataColumn("Size", value: \.size, summary: .aggregate(.sum))
}
.expandedRows($openFolders)
```

The table sorts siblings among themselves. A row that moves to another
parent goes there with the next update.

### Deleting, moving and dropping rows

As on a `Table`'s `ForEach`, ``NGDataTable/onDelete(perform:)`` deletes the
selected rows (Delete, Backspace, Edit > Delete),
``NGDataTable/onMove(perform:)`` lets the user drag rows to another place, and
``NGDataTable/dropDestination(for:action:)`` takes `Transferable` values
dropped between rows. They give offsets in your array:

```swift
NGDataTable(tasks) { … }
    .onDelete { tasks.remove(atOffsets: $0) }
    .onMove { tasks.move(fromOffsets: $0, toOffset: $1) }
    .dropDestination(for: String.self) { titles, offset in
        tasks.insert(contentsOf: titles.map(Task.init), at: offset)
    }
```

`dropDestination(for:action:)` needs macOS 15.2 to know the types a value
comes as; before, pass them (`contentTypes: [.plainText]`).

### Customizing columns

Like a `Table`'s, columns say what the user may change and how they start:
``NGDataColumn/customizationID(_:)`` gives the stable id saved
customizations know a column by, ``NGDataColumn/defaultVisibility(_:)``
hides it at first, and ``NGDataColumn/disabledCustomizationBehavior(_:)``
keeps the user from moving, resizing or hiding it. To keep what the user
chose, pass SwiftUI's `TableColumnCustomization` as with a `Table`; the
table follows and sets its visibility (`customization[visibility: "spend"]`),
which is all that type lets another view read and write. To keep the order,
widths and pins too, store an ``NGColumnCustomization`` instead:

```swift
@SceneStorage("CampaignColumns") private var columns = NGColumnCustomization()

NGDataTable(campaigns) {
    NGDataColumn("Name", value: \.name).customizationID("name")
        .disabledCustomizationBehavior(.visibility)
    NGDataColumn("Note", value: \.note).customizationID("note")
        .defaultVisibility(.hidden)
}
.columnCustomization($columns)
```

### The environment

The table follows the environment as a `Table`'s cells would: values are
formatted in `\.locale`, `\.layoutDirection` mirrors it, and `.disabled(_:)`
turns it off (it ignores the mouse and keyboard and shows dimmed, like a
disabled NSTableView).

```swift
NGDataTable(campaigns) { … }
    .environment(\.locale, Locale(identifier: "de_DE"))   // 1.234,50
```

### What isn't SwiftUI

The menu of ``NGDataTable/rowContextMenu(menu:primaryAction:)`` is SwiftUI
content (buttons, sections, submenus; macOS 14.4 or later), shown through
AppKit: use this modifier rather than SwiftUI's `contextMenu`, which
wouldn't reach the table.
``NGDataTable/rowFilter(searchText:columnIDs:id:isIncluded:)`` and
``NGDataTable/rowGrouping(_:)`` filter and group the rows. A filter's
condition tests rows; like `task(id:)`, it applies to every row again when
its `id` changes, so give it what the condition depends on besides the row:

```swift
.rowFilter(searchText: query, id: minimumSpend) { $0.spend >= minimumSpend }
```

(``NGDataTable/rowFilter(_:)`` takes an ``NGRowFilter``, whose condition
receives row indexes: it applies to every row again on every update.) For everything
else (summary scope, style, saved layout, collation keys), configure the
underlying ``NGTableView``:

```swift
.tableConfiguration { table in
    table.autosaveName = "Campaigns"
    table.summaryScope = .selectedRows
}
```

Column ids default to the key path (`"\Campaign.name"`): saved layouts, sort
descriptors and summary formulas refer to them, so give columns an explicit
`id` if you rename properties. Cells show values only: there are no SwiftUI
views in cells (the table draws them with Metal), and editors are the
table's (a text field, a check box, a menu).

## Topics

- ``NGDataTable``
- ``NGDataColumn``
- ``NGDataColumnGroup``
- ``NGDataColumnBuilder``
- ``NGCellValueConvertible``
- ``NGCellValueEditable``
