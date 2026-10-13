# Keyboard and Accessibility

Use the table without a mouse, and with VoiceOver.

## Overview

The table becomes the first responder when clicked, and Tab and Shift-Tab
move the focus on to the next and previous controls of the window.

| Keys | Action |
| --- | --- |
| Up Arrow, Down Arrow | Select the previous or next row |
| Shift-Up Arrow, Shift-Down Arrow | Extend the selection |
| Left Arrow, Right Arrow | Scroll the scrolling columns by one column |
| Page Up, Page Down | Scroll by a page |
| Home, End | Scroll to the first or last row |
| Command-A | Select all rows shown |
| Command-C | Copy the selected rows (see <doc:MenusAndActions>) |
| Typing letters | Select the next row whose value starts with them |
| Space | Passed on to your app (e.g. for Quick Look), unless it continues a type select search |
| Tab, Shift-Tab | Move the focus to the next or previous control |

With ``NGTableView/navigatesByCell``, the keys move a focused cell instead:

| Keys | Action |
| --- | --- |
| Arrow keys | Move the focused cell (right to left, Left goes on) |
| Shift-arrow keys | Extend a range of cells (``NGTableView/selectedCellRange``) |
| Tab, Shift-Tab | The next or previous cell |
| Return | Edit the focused cell when it's editable (then Return and Tab commit, Escape cancels) |
| Space | Toggle the focused check box |
| Typing | Start editing the focused cell with what's typed |
| Command-C | Copy the range of cells, or the focused cell |
| Escape | Clear the range of cells (the focused cell's row stays selected); with no range, hide the focus ring; then pass Escape on |

Command-A and Command-C come through the Edit menu: include Copy and Select All
in your main menu.

With ``NGTableView/rowGrouping``, Up Arrow and Down Arrow stop on group
header rows too, like in `NSOutlineView`. A header the keyboard is on is drawn
selected, but it isn't part of the selection: no rows are selected while the
keyboard is there. On a header:

| Key | Action |
|---|---|
| Left Arrow | Collapse the group, or go to the group it's in when collapsed |
| Right Arrow | Expand the group, or go to its first row when expanded |
| Option-Left Arrow, Option-Right Arrow | The same, with every group within it |

Shift with the arrows extends the selection over rows only. Users also
collapse and expand groups by clicking the headers or from their context menu
(see <doc:GroupingRows>).

Keys the table doesn't use go on to the next responder, like in other AppKit
views: handle them in your view controller. A space goes on too, unless it is
part of a type select search ("summer sale"), so a Quick Look panel can open on
the space bar:

```swift
override func keyDown(with event: NSEvent) {
    if event.charactersIgnoringModifiers == " " {
        toggleQuickLook()
    } else {
        super.keyDown(with: event)
    }
}
```

While the table updates its data (see ``NGTableView/isUpdatingData``), it
passes on every key, so shortcuts such as Escape to cancel loading still work.

### Type select

Typing the beginning of a value selects the first matching row from the
current one on, like in Finder. Letters typed in quick succession continue
the search; after a pause, typing starts a new search, and typing the same
letter again moves on to the next match. The table searches
``NGTableView/typeSelectColumnID``, or the first shown column when it is `nil`,
ignoring case and diacritics.

The delegate can change that, as with NSTableView:
``NGTableViewDelegate/tableView(_:shouldTypeSelectFor:withCurrentSearch:)``
lets a key go on to the next responder (a shortcut of your own), and
``NGTableViewDelegate/tableView(_:nextTypeSelectMatchFromRow:toRow:for:)``
finds the match itself, e.g. anywhere in the text. Its rows are display
indexes, the order shown.

### VoiceOver

The table presents itself as a table: VoiceOver reads the column headers, the
rows and their cells with the values as displayed (mark labels for marks),
and the summary row. Users can select rows with VoiceOver, and the table
announces changes in the selection and the number of rows. Group header
rows are disclosure rows, like an outline view's: VoiceOver reads their level
and whether they're expanded, and can expand and collapse them. Media cells
are read as their lines of text.

Like an NSTableView's, the table also lists its columns (each with its
header and its cells), the selected cells when navigating by cell, and the
sort direction of sorted columns. A row's swipe actions are actions of the
row in VoiceOver's actions menu (VO-Command-Space), and VoiceOver's "show
menu" (VO-Shift-M) opens the row's context menu.
