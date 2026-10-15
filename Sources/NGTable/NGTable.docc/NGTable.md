# ``NGTable``

A fast AppKit table for business data: frozen columns, column groups, a summary
row with formulas, row grouping with subtotals, search and filters, stable
selection across reloads, and live updates.

## Overview

``NGTableView`` shows rows of values in columns, like `NSTableView`, with what
data-heavy apps such as CRMs and reporting tools need built in:

- **Frozen columns** at the leading and trailing edges that stay in place while
  the other columns scroll horizontally.
- **Column groups**: a header band over related columns, such as "Income" over
  one column per store.
- **A summary row** with sums, averages, counts, minimums and maximums, value
  filters (e.g. the average of non-zero values) and **formulas** over other
  columns (e.g. ROI as a ratio of sums), for all rows, the selected rows, or all
  rows except the selected ones. Large tables are summarized in the background.
- **Row grouping** by column values, several levels deep, under collapsible
  header rows with row counts and subtotals.
- **Search and filters** that leave the data source alone: the table hides rows,
  and row indexes in the API stay the data source's. Column filters in the
  headers, like a spreadsheet's: values with counts, number ranges.
- **Stable selection**: with a row identity (such as a campaign id), the
  selection follows the same records when the data is sorted or reloaded.
- **Live data**: targeted updates (`reloadData(forRowIndexes:columnIndexes:)`,
  inserts, removes, moves) cost what changed, also with 200,000 rows; the
  table can keep the rows sorted itself as values change, flash changed
  values (green or red as numbers go up or down) and animate rows in, out
  and into place.
- **Conditional formats**: data bars, color scales and text colored by rules.
- **Editing in place** and navigation by cell, with Undo.
- **Export** to Excel and CSV, and saved **views** of columns, sort, filters
  and grouping.
- **Context menus** for rows, built by the app, with Finder's rules for which
  rows a click is for.
- **Column customization**: users resize, move, hide and show columns, and the
  table saves and restores their choices.
- Cell values as text, numbers, currencies, percentages, dates, check marks,
  colored **tags**, icon **marks**, and **pictures and videos** (loaded, cached
  and played under the pointer by the table).
- **GPU rendering**: Metal draws the rows from a glyph atlas with Core Text's
  typesetting, and only when something visible changed.
- **NSTableView's API**: data source, delegate, sort descriptors,
  notifications and updates have the same names, so apps migrate without
  reworking their patterns (see <doc:MigratingFromNSTableView>).
- Native look and feel: overlay scrollers, elastic scrolling, a Liquid Glass
  summary bar on macOS 26, dark mode, accent colors, full keyboard navigation,
  type select, copying to spreadsheets and VoiceOver.

The app owns the data: the table reads values from it, and hands back what the
user edits. The table sorts the rows itself with ``NGTableView/sortsRows`` or
leaves sorting to the app, and actions come from the app's own buttons and
menus.

Start with <doc:GettingStarted>. If you integrate the table into an app that
loads records from a server, also read <doc:IntegratingIntoAnApp>.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:IntegratingIntoAnApp>
- <doc:MigratingFromNSTableView>
- <doc:UsingSwiftUI>
- ``NGTableView``
- ``NGTableViewDataSource``
- ``NGTableViewDelegate``

### Data Sources

- ``NGTableViewDiffableDataSource``
- ``NGDiffableDataSourceSnapshot``
- ``NGTableViewDataSourceAdapter``

### Columns

- <doc:DefiningColumns>
- ``NGColumnItem``
- ``NGTableColumn``
- ``NGColumnGroup``
- ``NGColumnPin``
- ``NGColumnAlignment``
- ``NGColumnLayoutState``

### Cell Values

- <doc:DisplayingValues>
- ``NGCellValue``
- ``NGValueFormat``
- ``NGTag``
- ``NGMark``
- ``NGMedia``
- ``NGMediaCache``
- ``NGCellPosition``
- ``NGNamedColor``
- ``NGConditionalFormat``
- ``NGValueRange``
- ``NGColorRule``
- ``NGChangeHighlight``

### Summaries

- <doc:Summaries>
- ``NGColumnSummary``
- ``NGAggregate``
- ``NGValueFilter``
- ``NGSummaryFormula``
- ``NGSummaryValues``
- ``NGSummaryScope``

### Filtering and Search

- <doc:FilteringAndSearch>
- ``NGRowFilter``
- ``NGColumnFilter``
- ``NGDatePeriod``

### Grouping

- <doc:GroupingRows>
- ``NGRowGrouping``
- ``NGRowGroup``

### Selection, Sorting and Actions

- <doc:SelectionAndSorting>
- <doc:MenusAndActions>
- <doc:EditingCells>
- ``NGSorting``

### Appearance and Behavior

- <doc:Appearance>
- <doc:KeyboardAndAccessibility>
- ``NGSelectionHighlightStyle``
- ``NGTableStyle``
- ``NGTableDensity``

### Export

- ``NGExportFormat``
- ``NGExportOptions``

### Performance

- <doc:PerformanceAndThreading>

### Layout Building Blocks

Types the table uses to lay out and reorder columns. Apps rarely need them,
except to compute layouts outside the table, for example in tests.

- ``NGColumnLayout``
- ``NGColumnRegionLayout``
- ``NGGroupSpan``
- ``NGGridGeometry``
- ``NGRegionGeometry``
- ``NGColumnFrame``
- ``NGGroupFrame``
- ``NGColumnReorder``
- ``NGColumnVisibility``
- ``NGSummaryCalculator``
- ``NGAccumulator``
