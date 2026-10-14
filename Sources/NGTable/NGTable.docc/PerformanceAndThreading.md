# Performance and Threading

What the table asks for and when, so it stays fast with large data.

## Overview

The table is built for tens of thousands of rows and dozens of columns on
large screens, and for values that change many times a second.

The GPU (Metal) draws the rows and default cells. Core Text lays the text out
as always (kerning, ligatures, fallback fonts, truncation); each glyph and icon
is rasterized once into a shared atlas, and every frame is one draw call of
rectangles and glyphs:

- Scrolling only reads the cells that come into view; the cells already in
  view only move. Numbers and text in Latin (with the European letters),
  Greek and Cyrillic that come into view are put together from cached
  glyphs, kerned and truncated like Core Text does (each character and
  character pair is checked against Core Text once), in a few microseconds
  a line and on all cores; other scripts, and characters the font lacks,
  are laid out by Core Text, so a fast flick through a wide table stays
  within a 120 Hz frame.
- A changed value costs no rasterization or upload: the next frame shows its
  glyphs, already in the atlas. Numbers are formatted once per value shown.
- A frame is drawn only when something visible changed (values out of view
  change nothing on screen), right before Core Animation commits, so the rows
  never lag the header or the scrollers.

The header's titles, the summary values, and the pictures and videos of media
cells are drawn by Metal too, over the system's header material and Liquid
Glass. Pictures are downloaded once, decoded off the main thread at their
displayed size and kept within ``NGMediaCache/memoryLimit``.

A table of 100,000 rows scrolls as smoothly as one of 20. What remains is the
cost of your data source and delegate, which this article helps keep low.

### Threading

``NGTableView``, its data source and its delegate are main-actor types: the
table only ever calls them on the main thread. Update your data on the main
thread too, and reload right away:

```swift
func refresh() async throws {
    let campaigns = try await api.campaigns()   // Off the main actor while waiting.
    data.campaigns = campaigns                  // Back on the main actor.
    table.reloadData()
}
```

Large summaries are computed on a background thread from values the table has
already read on the main thread: the data source and delegate are never called
from another thread.
Only the pure closures of ``NGValueFilter`` and ``NGSummaryFormula`` run in the
background.

### What the table reads, and when

| Moment | The table calls |
| --- | --- |
| Rows or columns come into view | `valueFor` for the new cells; `backgroundColorForRow` and `markerColorForRow` for new rows |
| ``NGTableView/reloadData()`` | `numberOfRows`; the visible cells again; every row of the summarized columns and formula inputs; the identity of every row, when rows are selected; `isIncluded` for every row, when filtered |
| ``NGTableView/reloadData(forRowIndexes:columnIndexes:)`` | `valueFor` for those rows: the reported columns' cells, and every summarized column and formula input (summaries follow any column); search words, sort and group keys only when their columns were reported |
| First search after a reload | `valueFor` for every row of the searched columns (then kept in an index), in slices for large tables |
| Summary scope or selection change | Nothing: summaries use values read before |
| ``NGTableView/reorderRows(from:to:)`` after sorting | Nothing: cells, summaries, the search index and the groups move with their rows |
| Double-click on a header divider | `valueFor` for up to 20,000 rows of the column |
| Typing to select a row (type select) | `typeSelectStringFor` (or `valueFor`) of the type select column, row after row from the selected one until one matches |

So:

- **Keep `valueFor` a lookup.** Store the values the table shows in your
  records, ready to return. Don't format, compute from other records, query a
  database or fetch anything in it.
- **Return the same color objects** for tints and markers (static constants).
- **Reload once per change,** not once per record: apply a whole server
  response, then call `reloadData()`. Reloading during a background summary
  computation cancels it, so bursts of reloads are cheap, but each reload still
  reads the visible cells and runs the filter.
- **Use `.number` for numbers,** not preformatted `.text`: numbers are what
  summaries, sorting and formats work with.

### Large summaries

Reading values for summaries takes time proportional to rows × summarized
columns. Above ``NGTableView/synchronousSummaryLimit`` values (50,000 by
default), the table reads them in slices of a few milliseconds, between
which the app keeps handling events, and computes in the background. See
<doc:Summaries>. Lower the limit if your `valueFor` is slower than a plain
lookup; raise it if you prefer summaries to be ready together with the rows.

Give the numbers of a range of rows in one call to read them much faster:
``NGTableViewDataSource/tableView(_:numbersFor:rows:into:)``. Asking cell by
cell costs about 4 ms per column for 200,000 rows even for a plain lookup;
copying from an array of numbers costs a fraction of it. With 30 summarized
columns over 200,000 rows, a reload had its totals after 330 ms, with numbers
by range after 24 ms:

```swift
func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, rows: Range<Int>,
               into values: UnsafeMutableBufferPointer<Double>) -> Bool {
    guard let metric = Metric(rawValue: column.id) else { return false }   // Cells for the rest.
    for (offset, row) in rows.enumerated() { values[offset] = campaigns[row][metric] }
    return true
}
```

Use NaN for rows without a number, as `.empty` or text would count. The
numbers must be the cells' numbers: they feed the same summaries.

### Sorting a million rows

When the table sorts the rows itself (``NGTableView/sortsRows``), numbers sort
by radix, without comparing rows, and the new order is built in the
background. Give the numbers rows sort by for a range of rows to skip reading
them one by one, ``NGTableViewDataSource/tableView(_:sortNumbersFor:rows:into:)``
(what `sortValueFor` gives as numbers, NaN for none). On 1,000,000 rows a sort
by a number took 0.54 s, now about 40 ms with numbers by range (about 7 ms
of it on the main thread).

Text sorts like Finder (`localizedStandardCompare`). Comparing it on all
cores used to be slower than on one: Foundation fetches the current locale
through a lock on every comparison. The table gives each worker its own
locale object with the same collator (checked against
`localizedStandardCompare` when they are made), so text compares on all
cores. Faster still are collation keys, bytes whose order is the text's
order: set ``NGTableView/collationKeyProvider`` (or
``NGTableView/defaultCollationKeyProvider``) to a provider of them. The table
makes the keys on all cores, sorts the rows by them, orders rows with equal
keys by comparing them, and checks every pair of neighbors by comparing them,
so the order stays `localizedStandardCompare`'s (keys that disagree are
found, and the rows are sorted by comparing). For 1,000,000 shuffled texts
on a 10-core Mac:

| Sort by text | Time |
| --- | --- |
| Comparing on one core (before) | 12–17 s |
| Comparing on all cores | 2.7–3.5 s |
| Collation keys (`NGBundledICUCollation`) | 0.38–0.40 s (0.6 s for the whole sort in a table) |

> Important: **The keys come from the optional NGTableICU library**, not from
> NGTable: it builds ICU into the app, which adds **about 9 MB per
> architecture** (ICU's code and its collation data: about 17 MB in a
> universal app) and some 30 seconds to a clean build. NGTable doesn't
> depend on it, so apps with small tables don't pay for it. Add the library
> (`.product(name: "NGTableICU", package: "NGTable")`) and set `NGTableView.defaultCollationKeyProvider = NGBundledICUCollation()`
> at launch.

macOS has an ICU of its own, but its collation functions have no header in
the SDK: they aren't public API, and the Mac App Store has rejected apps
that call them. The bundled ICU is linked into the app and imports nothing
from the system's; with Xcode's default for apps (Strip Linked Product,
All Symbols) not even its function names stay in the app. Any other source
of keys can implement ``NGCollationKeyProvider``.

Where `localizedStandardCompare` itself is inconsistent (it isn't transitive
with leading zeros together with ß or case, nor with ligatures and
full-width digits), no order agrees with every comparison; the table's is
then sorted pair by pair, like any sort with that comparison.

### Grouping a million rows

Grouping reads every row's value of each grouping column once, by
`valueFor` on the main actor, and keeps the keys: collapsing, expanding,
filtering and grouping by the same columns again use them (a few
milliseconds on a million rows), and grouping by one more column reads only
that column. Above ``NGTableView/synchronousGroupingLimit`` keys to read
(rows × columns not read yet, 50,000 by default) they are read in slices of
a few milliseconds, between which the app keeps handling events; the rows
show as they were grouped before meanwhile (``NGTableView/isGroupingRows``),
and rows the app changes or inserts meanwhile are read again. On 1,000,000
rows (release, M1 Max) grouping held the main thread 87 ms, a second level
176 ms; now the longest hold is about 9 ms (building the groups when every
key is read), the groups showing after about 130 ms.

### Live updates

Targeted updates (see <doc:IntegratingIntoAnApp#Live-updates>) cost what
changed, not the size of the table:

- only the changed rows are read again;
- without a row filter, totals change by the changed values (min and max are
  computed again only when shown); with one, the summaries are rebuilt from
  the values read before, without asking the data source;
- with ``NGTableView/rowGrouping``, only changed rows are grouped again, and
  group subtotals change by the changed values like the totals;
- visible cells move with their records, in one layout pass per batch, and a
  frame is drawn only when a visible row changed.

Batch the updates of one event (a socket message, a timer tick) with
``NGTableView/beginUpdates()`` and ``NGTableView/endUpdates()``. On 100,000
rows, a batch of 500 changed values and a few inserted, removed and moved
rows takes a few milliseconds. The table keeps its per-row data (filter
results, search words, sort and group keys, summarized values) by its own
row handles rather than by index: inserts, removes and moves update only
the handles, in blocks of a few thousand rows, and renumber nothing, so 500
single-row inserts in one batch cost about as much as one insert of 500 rows. Outside a batch every update is a batch of its own. With
``NGTableView/sortsRows`` the table keeps the rows sorted as they change: only
rows whose sort values changed move, by binary search over blocks of the
sorted rows, without a pass over every row; full sorts of large
tables run in the background (``NGTableView/synchronousSortLimit``). Background
sorts, summaries, groupings and first searches go on under a feed that inserts and removes
rows: what they read is kept by row handle, and the rows that changed or came
meanwhile are read when they're done. Debug builds are several times slower, and a
feed with pauses runs slower than a busy one while the system keeps the
processor at a lower speed.

### Memory

- The table keeps a small object for each visible cell plus a small pool for
  scrolling; no bitmaps per cell.
- All tables share one glyph atlas (a 2048 × 2048 texture, 16 MB; started
  over when full, and grown once to 4096 × 4096, 64 MB, if one frame's
  glyphs don't fit) and a cache of recently laid out text (20,000 strings).
- Summary values are stored as one `Double` per row and summarized column,
  shared between filtered views of the same data.
- An export holds what it writes until the file is done: about 100 bytes a
  cell for CSV and 280 for a workbook (about 5.6 GB for 1,000,000 rows of 20
  columns as xlsx). Export very large tables as CSV, or the selected rows.
- The search index holds the words of the searched columns of every row. It
  is created on the first search and dropped on reload.
- Per row, measured on a million rows: about 23 bytes the table always
  keeps, 8 per summarized column, and for what you use: row identities
  (`row(forIdentifier:)`, selections followed by identity) about 130, the
  search index about 200, a text sort by the table about 40, grouping about
  40. With all of them, plan for about 450 bytes a row, 450 MB for a million
  rows, besides your own data.
- When the table is removed from its window, it releases its pools and stops
  its timers and background summaries, computed again when it is shown
  again. Background sorts, first searches and copies finish: they follow
  the rows, and the table shows their result when it is back.

The table holds its data source and delegate weakly and keeps no references
to your records, only the values it was given.
