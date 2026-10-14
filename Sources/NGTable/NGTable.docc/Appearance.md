# Appearance

Adjust sizes, highlight rows by their data, and choose how selection and
scrolling look.

## Overview

The table follows the system look by default: system fonts and colors,
alternating row backgrounds, a rounded selection like the Finder sidebar,
overlay scrollers, light and dark mode, the user's accent color, and a Liquid
Glass summary bar on macOS 26 (a header material on earlier systems). Rows
scroll underneath the summary bar.

### Sizes

| Property | Default | |
| --- | --- | --- |
| ``NGTableView/rowHeight`` | 24 | The rows' height, unless the delegate gives rows their own (``NGTableViewRowHeights``). |
| ``NGTableView/headerRowHeight`` | 28 | The column titles. |
| ``NGTableView/groupHeaderHeight`` | 24 | The group band, only shown when there are groups. |
| ``NGTableView/summaryRowHeight`` | 30 | The summary row. |

### Fonts, colors and density

The table uses the system fonts and colors, following light and dark mode,
accent color and contrast settings. ``NGTableView/tableStyle`` changes them
where an app needs its own look; anything left `nil` stays the system's:

```swift
table.tableStyle = NGTableStyle(
    fontSize: 15,                      // cells and the summary row
    headerFontSize: 12,                // column titles
    textColor: .labelColor,
    backgroundColor: NSColor(named: "TableBackground"),
    stripeColors: [.clear, NSColor(named: "Stripe")!],
    groupRowColor: NSColor(named: "GroupRow"))
table.density = .compact               // or .regular (24 points), .spacious
```

``NGTableView/density`` sets ``NGTableView/rowHeight`` for the style's font,
with a little, some or more room around the text, like Finder's list sizes;
it follows a later font size change. Give the style the same color objects
each time (the renderer resolves each color once per appearance).

### Rows and selection

- ``NGTableView/usesAlternatingRowBackgroundColors`` stripes the rows with the
  system's alternating content colors.
- ``NGTableView/showsVerticalGridLines`` draws thin lines between columns.
- ``NGTableView/selectionHighlightStyle`` is `.rounded` (inset, rounded
  corners, like macOS lists; the table then keeps a small margin at its edges)
  or `.fullWidth` (a plain band across the whole row, like classic tables).
  The selection is shown in the accent color while the table is focused and
  in gray otherwise.

### Highlighting rows by their data

The delegate can tint a row's background and put a colored marker at its
leading edge, for example green for profitable campaigns and red for losing
ones:

```swift
// Created once: the table asks for every visible row while scrolling.
static let profitTint = NSColor.systemGreen.withAlphaComponent(0.10)
static let lossTint = NSColor.systemRed.withAlphaComponent(0.10)

func tableView(_ tableView: NGTableView, backgroundColorForRow row: Int) -> NSColor? {
    let roi = data.campaigns[row].roi
    return roi > 0 ? Self.profitTint : roi < 0 ? Self.lossTint : nil
}

func tableView(_ tableView: NGTableView, markerColorForRow row: Int) -> NSColor? {
    data.campaigns[row].isOverBudget ? .systemOrange : nil
}
```

- Use light, translucent tints so text stays readable, and return the same
  color objects every time (static constants): the table compares them to skip
  unchanged rows.
- Tints replace the alternating stripes of their rows. Selected rows show the
  selection instead of the tint, and keep the marker.
- System colors like `systemGreen` adapt to dark mode and accent changes by
  themselves.
- The table asks when rows come into view and on
  ``NGTableView/reloadData()``. If the condition behind a tint changes
  without a data change, call `reloadData()`.

### Empty state

While there are no rows, the table shows ``NGTableView/emptyStateText``, or
your own ``NGTableView/emptyStateView`` (for example with a button to create
the first record). The table places it; the app says what it is.

- Without any data (the data source has no rows), the table shows only the
  empty state, centered: no header, row stripes or summary row.
- When a ``NGTableView/rowFilter`` hides every row, the columns stay and the
  empty state shows in the rows area. See <doc:FilteringAndSearch>.
- While the data updates (see ``NGTableView/isUpdatingData``), the spinner
  takes its place, and it comes back if there are still no rows. There's no
  need to clear the text while loading.

### Scrolling

The table scrolls by itself, like a scroll view:

- trackpads scroll with momentum and bounce at the top and bottom; turn the
  bounce off with ``NGTableView/bouncesVertically``;
- gestures lock to the axis they start on, so vertical scrolling doesn't drift
  sideways;
- overlay scrollers appear while scrolling and expand under the pointer;
  with "Show scroll bars: Always" in System Settings, the table shows classic
  scrollers that take up space;
- clicking the scroller track pages, and holding it keeps paging;
- scrolling on an axis the table has nothing to scroll on goes to the view
  that contains it, like a nested scroll view's: a table of a few rows in a
  form scrolls the form (alone in a window, its rows still bounce).

In code, read ``NGTableView/contentOffset`` and scroll with
``NGTableView/scroll(to:)`` or ``NGTableView/scrollRowToVisible(_:)``.
``NGTableView/didScrollNotification`` tells every change of
``NGTableView/contentOffset`` once the rows are laid out there, where
NSTableView apps watch the clip view's bounds: for example, load the next
page when `rowIndexes(in: table.bounds)` reaches the last rows.
``NGTableView/willStartLiveScrollNotification``,
``NGTableView/didLiveScrollNotification`` and
``NGTableView/didEndLiveScrollNotification`` follow the user's scrolling
like a scroll view's: a trackpad gesture or a drag of the overlay scroller,
ending with its momentum. Never make
the table the document of an `NSScrollView` (a form around it in one is
fine).

### Localization

The table's own texts — its menus (the summary scope, columns, grouping,
views), the column filter and save view dialogs, Undo names and what
VoiceOver reads — are localized in English and Russian; the summary scope
titles can be replaced with ``NGTableView/summaryScopeTitles``. Everything
else the user reads — column
titles, tool tips, menus, empty state texts, tags and mark labels — comes from
your app, localized as you like. Numbers and dates are formatted in the user's
locale.

### Right-to-left languages

In a right-to-left interface (Arabic, Hebrew; the table follows
``NGTableView/userInterfaceLayoutDirection``, which AppKit sets from the app's
language) the whole table is mirrored, like AppKit's own controls:

- The first column is at the right; leading frozen columns stay at the right
  edge and trailing ones at the left; the vertical scroller is at the left.
- Each cell's content is mirrored within it: leading text at the right,
  numbers aligned to the trailing side (the left), tags listed from the right,
  data bars growing from the right, outline and group indents and their
  disclosure triangles at the right, the triangles of collapsed rows pointing
  left. Text itself reads as written: every line moves whole, so Arabic,
  Hebrew and mixed text keep their order.
- Column titles put the filter button and the sort arrow at their left;
  columns resize from their left edge and move by dragging the other way.
- Left Arrow goes to the next column and Right Arrow back (on group headers
  and tree rows, Right Arrow collapses and Left Arrow expands); Tab still goes
  to the next column. Swiping a row to the right shows its trailing actions,
  at the left.
- ``NGTableView/contentOffset`` still counts from the leading end: 0 shows the
  first columns, at the right. Printing and PDF put the first column at the
  right too.

Set `userInterfaceLayoutDirection` yourself to show one table mirrored or not,
whatever the app's language.
