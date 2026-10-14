# Displaying Values

Return typed values from the data source and let columns format them;
pictures and videos are values too.

## Overview

The data source returns an ``NGCellValue`` for every cell. The value's kind
decides how it is drawn, and the column's ``NGValueFormat`` decides how
numbers and dates are written:

| Value | Shown as | Summaries | Sorted with `sortsBefore` |
| --- | --- | --- | --- |
| `.empty` | Nothing | Left out | First |
| `.text(String)` | The text, truncated with "…" (or wrapped, see below) | Left out | Like Finder (`localizedStandardCompare`) |
| `.number(Double)` | Formatted by the column's `format` | Included | Numerically; NaN last |
| `.bool(Bool)` | "✓" for `true`, nothing for `false` (a check box in editable columns) | Left out | `false` first |
| `.date(Date)` | Formatted by `.date(includesTime:)` | Left out | Chronologically |
| `.tags([NGTag])` | Colored capsules | Left out | By their titles |
| `.mark(NGMark)` | An SF Symbol | Left out | By their labels |
| `.media(NGMedia)` | A picture or video with lines of text | Left out | By its text |
| `.sparkline(NGSparkline)` | A small chart of a series | Its last value | By its last value |
| `.link(NGLink)` | The title in the link color | Left out | By its title |
| `.button(NGCellButton)` | A push button | Left out | By its title |
| `.progress(Double?, total:)` | A progress bar | Its fraction | By its fraction; indeterminate first |
| `.rating(Int, maximum:)` | Stars | The number | By the number |

String, integer and floating-point literals are values too, so
`return "Paused"` and `return 42` work.

Text cells show one line, with digits of numbers in monospaced figures so they
line up in columns. The table only reads values of the cells in view, so
large tables stay fast; see <doc:PerformanceAndThreading>.

### Wrapped text

A column made with ``NGTableColumn/wrappingText(maximumNumberOfLines:)``
wraps its text onto more lines, and its rows grow to fit: the table measures
each row by the most lines its wrapped cells take, as they are drawn, so
there is nothing to compute or tell the table. Log messages, notes and
addresses read in full:

```swift
NGTableColumn("message", title: "Message", width: 420).wrappingText()
// At most three lines, the last one truncated with "…" (its tool tip shows all).
NGTableColumn("notes", title: "Notes", width: 240).wrappingText(maximumNumberOfLines: 3)
```

Rows are measured again when they are reloaded, when a wrapping column's
width changes and when the font or ``NGTableView/rowHeight`` (the height of
one line's row) does; heights follow their records through sorting,
filtering and grouping. The other cells of a taller row keep to its first
line. Tables of up to 2,000 rows are measured at once; in larger ones the rows
in view are, and the others in the background (a million log messages in
about 2 seconds), counting as one line until then; the rows in view don't
move while those above them grow. Rows whose heights
the app knows itself come from the delegate instead (``NGTableViewRowHeights``).
Printing wraps the text the same way, each row on one page. In SwiftUI it is
``NGDataColumn/lineLimit(_:)``.

### Formats

A column's `format` applies to its numbers and dates, in cells, the summary
row, copied text, search and VoiceOver:

| Format | Example | Typical use |
| --- | --- | --- |
| `.automatic` | `1,234.5` | Counts, plain numbers |
| `.number(fractionDigits: 0)` | `1,235` | Clicks, impressions |
| `.currency(code: "EUR")` | `€1,234.50` | Spend, revenue |
| `.percent(fractionDigits: 1)` | `12.5%` for `0.125` | ROI, CTR, conversion rates |
| `.date(includesTime: true)` | `Sep 29, 2026 at 14:05` | Start dates, last changes |

Formatting follows the user's locale, or the table's
``NGTableView/locale`` when you set one (cells, summaries, group titles,
search, copying, export, printing and VoiceOver alike). Percent values are fractions: store
`0.125` for 12.5 %. To show text in a way no format covers, format it yourself
and return `.text`, but then the column has no numbers to summarize or sort
numerically, so prefer `.number` with a format whenever the value is a number.

### Conditional formats

A number column's ``NGTableColumn/conditionalFormat`` makes its cells show
their values at a glance, like a spreadsheet's conditional formatting:

```swift
NGTableColumn("profit", title: "Profit", format: .currency(code: "USD"),
              conditionalFormat: .dataBar(.green, negative: .red))
NGTableColumn("cr", title: "CR", format: .percent(fractionDigits: 1),
              conditionalFormat: .colorScale(low: .red, high: .green))
NGTableColumn("roi", title: "ROI", format: .percent(fractionDigits: 1),
              conditionalFormat: .textColor([NGColorRule(.below(0), color: .red),
                                             NGColorRule(.above(0.5), color: .green)]))
```

- ``NGConditionalFormat/dataBar(_:negative:range:)``: a bar behind the value;
  negative values grow the other way from zero.
- ``NGConditionalFormat/colorScale(low:high:range:)``: a background between
  two colors.
- ``NGConditionalFormat/textColor(_:)``: the text in the color of the first
  rule the value passes.

Bars and scales span the values of the rows the filter shows, rows in
collapsed groups too (``NGValueRange/automatic``), kept up to date as values
change, or fixed bounds. Selected rows keep their selection colors for text.

### Tags

``NGTag`` shows short labels as colored capsules, several per cell, for
example a campaign's channels or labels:

```swift
case "labels":
    return .tags(campaign.labels.map { NGTag($0.name, color: $0.isUrgent ? .red : .gray) })
```

Tags that don't fit are cut off at the end of the cell. Colors are
``NGNamedColor``s: named like the system colors, adapting to light and dark
mode, the accent color and increased contrast. They are drawn in white on the
selection highlight. Searching finds tags by their titles.

### Marks

``NGMark`` shows a single SF Symbols icon, for example a rating or a flag:

```swift
case "mark":
    guard let rating = campaign.rating else { return .empty }
    switch rating {
    case .recommended: return .mark(NGMark("hand.thumbsup.fill", color: .green, label: "Recommended"))
    case .favorite: return .mark(NGMark("star.fill", color: .yellow, label: "Favorite"))
    case .discounted: return .mark(NGMark("percent", color: .blue, label: "Discount"))
    }
```

The `label` says what the mark means. It is shown as the mark's tool tip and
used by VoiceOver, copying, searching and sorting, so always set it. Marks
without a color use the secondary label color. Use a name from the SF Symbols
app; an unknown name draws nothing. Put marks in a narrow, fixed column (see
<doc:DefiningColumns>).

Create marks once (for example as static constants) when you have many rows:
this avoids building the same values again for every cell.

### Sparklines

A ``NGSparkline`` value draws a series as a small chart in the cell: a line,
the line with the area under it (`.area`), a bar per value (`.bars`, from zero
when the values cross it) or wins and losses (`.winLoss`: up for a positive
value, down for a negative one). NaN is a gap in the line.

```swift
case "price":
    return .sparkline(NGSparkline(lastPrices, style: .area, showsLastPoint: true))
case "results":
    return .sparkline(NGSparkline(wins.map { $0 ? 1 : -1 }, style: .winLoss))
```

- The cell's height shows the values' own range; give `range` to put rows
  on one scale. `color` picks a named color (the accent color by default);
  `showsMinMax` marks the lowest and highest values.
- It sorts and sums by its last value, copies and exports to CSV as its
  numbers in the column's format (an Excel sheet gets the last value as a
  number), prints its last value, and VoiceOver reads its last, lowest and
  highest values.
- It's drawn as a few hundred vertices, without text: a feed that appends a
  value and drops the first redraws only that cell (reload it with
  `reloadData(forRowIndexes:columnIndexes:)`).

### Links

A ``NGLink`` value shows its title in the link color; under the pointer it's
underlined and the cursor is the pointing hand. A click on it (pressed and
released in the cell) calls the delegate's
``NGTableViewDelegate/tableView(_:didClickLink:in:row:)``, which opens the
link's `url` with `NSWorkspace` unless you implement it; the row isn't
selected by that click (Command- and Shift-clicks still select). Space on the
focused cell and VoiceOver's press do the same.

```swift
case "site":
    return .link(NGLink(campaign.domain, url: campaign.landingURL))
```

### Buttons

A ``NGCellButton`` value draws a push button like a small `NSButton`, as wide
as its title (and optional `symbolName`) needs, placed by the column's
alignment. Pressed and released over it, it calls the delegate's
``NGTableViewDelegate/tableView(_:didPressButton:in:row:)``; a press beside it
selects the row, and a double click on it is not the table's `doubleAction`.
A disabled button (`isEnabled: false`) is dimmed and can't be pressed;
`role: .destructive` draws the title in red. Space on the focused cell and
VoiceOver's press press it too.

```swift
case "action":
    return .button(NGCellButton("Stop", symbolName: "stop.fill", isEnabled: campaign.isRunning, role: .destructive))
```

### Progress bars

`.progress(value, total:)` draws a bar like `NSProgressIndicator`'s, filled
`value / total` in the accent color (`total` is 1 by default); `nil` is
indeterminate: a stripe moves along the bar, animated only while such a cell
is in view. With a format on the column (`.percent(fractionDigits:)`), the
fraction is written beside the bar, the bars of a column all of one length.
It sorts, sums (an average is the mean progress) and exports as the fraction;
VoiceOver reads the percentage, or "in progress".

```swift
case "upload":
    return .progress(upload.isPreparing ? nil : Double(upload.sentBytes), total: Double(upload.totalBytes))
```

### Ratings

`.rating(value, maximum:)` draws `maximum` stars (5 by default), `value` of
them filled. In an editable column (``NGTableColumn/isEditable``) a click on a
star sets the rating to it and a click just before the first one clears it,
through ``NGTableViewDataSource/tableView(_:setValue:for:row:)`` with Undo; a
number key on the focused cell does the same, and under the pointer the
stars preview the value a click would set. That click doesn't select the
row. It sorts and sums (an average rating) as the number; VoiceOver reads
"3 of 5 stars".

### Pictures and videos

A ``NGMedia`` value shows a picture at the cell's leading edge with up to a
few lines of text beside it, such as an ad creative with its title and site.
The table loads the picture from its URL itself, like SwiftUI's `AsyncImage`:

```swift
case "creative":
    return .media(NGMedia(
        image: teaser.thumbnailURL,
        motion: teaser.isVideo ? .video(teaser.videoURL) : nil,
        badge: teaser.isVideo ? "video.fill" : nil,
        lines: [
            .init(teaser.title, style: .title, maximumLines: 2),
            .init(teaser.site),
            .init(teaser.comment, style: .colored(.orange)),
        ]))
```

- Files are downloaded once into the app's Caches folder (within
  ``NGMediaCache``'s `diskLimit`, 1 GB, the least recently used deleted first)
  and decoded off the main thread at the picture's size, cropped to fill it;
  the decoded pictures stay in memory within its `memoryLimit`. A few load at
  a time, the latest shown first: after a flick, the rows in view load next
  and those scrolled past don't. A placeholder symbol shows while a picture
  loads, a warning symbol if it can't.
- `motion` plays under the pointer, muted and looping: a video, whose frame
  from its first second is also the still picture (`image` is the fallback),
  or an animated GIF. The GPU draws it like the rest of the table, so it is
  clipped under frozen columns and the header.
- A `.title` line uses the table's font and may wrap; other lines are
  smaller. The last line a text may take is truncated with "…".
- Set the rows' height for the picture with ``NGTableView/rowHeight`` (the
  default thumbnail is 104 × 68 points; set `thumbnailSize`).
- Copying, searching, sorting, type select and VoiceOver use the lines' text;
  the tool tip shows them, or `toolTip`.
- For Quick Look, ``NGTableView/frameOfMediaThumbnail(row:columnID:)`` and
  ``NGTableView/mediaThumbnailImage(row:columnID:)`` give where the picture is
  and what it shows, and ``NGMediaCache/file(for:)`` its file (with the real
  type's extension).

### The pointer over cells

``NGTableView/hoveredCell`` is the cell under the pointer, and the delegate's
``NGTableViewDelegate/tableView(_:pointerDidEnterRow:column:)`` and
``NGTableViewDelegate/tableView(_:pointerDidExitRow:column:)`` follow it, like
SwiftUI's `onContinuousHover`. Unlike AppKit's tracking areas, they also
follow when the rows scroll or change under a resting pointer. Group header
rows, the header and the summary row have no cell. When a layout pass (a
resize, a reload) brings another cell under the pointer, the delegate hears
about it right after the pass, on the next run loop turn, so it can reload
that row from there.
