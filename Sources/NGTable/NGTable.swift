#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Supplies rows and cell values to an `NGTableView`.
///
/// Call `reloadData()` right after changing the rows, before anything else
/// (selecting, scrolling, returning to the run loop): until then the table
/// still asks about the old rows, which may no longer exist. Summaries of
/// large tables are computed in the background from values read on the main
/// thread, so the data source is never called from another thread.
@MainActor
public protocol NGTableViewDataSource: AnyObject {
    /// The number of rows the data source has, before any `rowFilter`.
    func numberOfRows(in tableView: NGTableView) -> Int
    /// The value of a cell. `row` is a data source row index (never a filtered
    /// display index), and `column` can be any column the table asks about: a
    /// shown one, a hidden one, or one that is not defined at all, such as the
    /// inputs of a summary formula or the `rowIdentifierColumnID`.
    ///
    /// It is called often (for every cell that comes into view, for searches
    /// and summaries), so keep it cheap: look the value up, don't compute or
    /// fetch it here. Return `.empty` for columns the row has no value for.
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue
    /// A stable identity of a row, e.g. the campaign's id. With it, the
    /// selection follows the same records across `reloadData()` even when rows
    /// move, appear or disappear. Alternatively set `rowIdentifierColumnID`.
    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable?
    /// The identity of a row's parent while the table shows a tree
    /// (`NGTableView.rowTree`), or `nil` for a row at the top. A parent that
    /// isn't among the rows puts the row at the top.
    func tableView(_ tableView: NGTableView, parentIdentifierForRow row: Int) -> AnyHashable?
    /// A column's numbers for a range of rows at once, optional: fill
    /// `values[i]` with the number of row `rows.lowerBound + i` (NaN for a
    /// row without one, as `.empty` or text would count) and return `true`.
    /// The summaries read every row's numbers (on reloads, ~4 ms per column
    /// for 200,000 rows one cell at a time); a copy from an array of numbers
    /// takes a fraction of that. The default returns `false`: the table asks
    /// for the cells.
    func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool
    /// A column's numbers for rows given one by one (scattered, in any
    /// order), optional: fill `values[i]` with the number of row `rows[i]`
    /// (NaN for a row without one) and return `true`. The summaries read the
    /// rows a batch of targeted updates changed so: a feed's thousands a
    /// frame, one cell at a time, cost more than the summing. The default
    /// returns `false`: the table asks for the cells.
    func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, atRows rows: UnsafeBufferPointer<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool
    /// The numbers rows sort by in a column, for a range of rows at once,
    /// optional, while the table sorts the rows itself (`sortsRows`): what
    /// `tableView(_:sortValueFor:row:)` gives as numbers, NaN for a row
    /// without one (it sorts like `.empty`). Fill `values[i]` for row
    /// `rows.lowerBound + i` and return `true`. A sort of 1,000,000 rows by
    /// a number then takes a fraction of the time it takes reading their
    /// values one by one. The default returns `false`. The buffer starts as
    /// NaN; returning `false` after writing some of it is fine (nothing is
    /// read), returning `true` means every row was written.
    func tableView(_ tableView: NGTableView, sortNumbersFor column: NGTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool
    /// The numbers rows sort by in a column, for rows given one by one
    /// (scattered, in any order), optional: like
    /// `tableView(_:sortNumbersFor:rows:into:)`, `values[i]` for row
    /// `rows[i]`. A live sort reads the rows a batch of targeted updates
    /// changed so: a feed's thousands a frame, one value at a time, cost
    /// more than placing them. The default returns `false`.
    func tableView(_ tableView: NGTableView, sortNumbersFor column: NGTableColumn, atRows rows: UnsafeBufferPointer<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool
    /// Called when `sortDescriptors` changed, like `NSTableViewDataSource`'s:
    /// the user clicked a sortable header, or the app set them. Sort the data
    /// by `tableView.sortDescriptors` (empty: the original order, see
    /// `NGSorting`) and call `reloadData()`. The table doesn't sort itself,
    /// unless `sortsRows` is on: then this is only a notification.
    func tableView(_ tableView: NGTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor])
    /// The value a row sorts by in a column while the table sorts the rows
    /// itself (`NGTableView.sortsRows`): the cell value by default. Return
    /// another one where the display differs from the order, e.g. a number
    /// for a budget shown as "CPA $5.00".
    func tableView(_ tableView: NGTableView, sortValueFor column: NGTableColumn, row: Int) -> NGCellValue
    /// A value the user entered in an editable cell (see
    /// ``NGTableColumn/isEditable``), like NSTableView's
    /// `tableView(_:setObjectValue:for:row:)`: store it; the table then reads
    /// the row again. `.empty` when the user cleared the cell.
    func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int)
    #if os(macOS)
    /// What a dragged row puts on the pasteboard, like NSTableView's; `nil`
    /// (the default) doesn't let the row be dragged.
    func tableView(_ tableView: NGTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)?
    /// Whether a drop may go above `row` (a data source row, or the number of
    /// rows at the end), like NSTableView's; `[]` refuses it. The table must
    /// be registered for the dragged types (`registerForDraggedTypes(_:)`).
    func tableView(_ tableView: NGTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation
    /// Takes a drop above `row`, like NSTableView's; returns whether it did.
    func tableView(_ tableView: NGTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool
    /// Rows start to drag, like NSTableView's: the data source rows dragged
    /// (``NGTableView/draggedRowIndexes`` follows them as rows move).
    func tableView(_ tableView: NGTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet)
    /// A drag of rows ended, like NSTableView's, e.g. with `.delete` on the
    /// Trash. ``NGTableView/draggedRowIndexes`` still has the rows.
    func tableView(_ tableView: NGTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation)
    /// A drag entered the table, like NSTableView's: the items' images may
    /// change for it (`enumerateDraggingItems`).
    func tableView(_ tableView: NGTableView, updateDraggingItemsForDrag draggingInfo: any NSDraggingInfo)
    #endif
}

public extension NGTableViewDataSource {
    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { nil }
    func tableView(_ tableView: NGTableView, parentIdentifierForRow row: Int) -> AnyHashable? { nil }
    func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool { false }
    func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, atRows rows: UnsafeBufferPointer<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool { false }
    func tableView(_ tableView: NGTableView, sortNumbersFor column: NGTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool { false }
    func tableView(_ tableView: NGTableView, sortNumbersFor column: NGTableColumn, atRows rows: UnsafeBufferPointer<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool { false }
    func tableView(_ tableView: NGTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {}
    func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {}
    #if os(macOS)
    func tableView(_ tableView: NGTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? { nil }
    func tableView(_ tableView: NGTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation { [] }
    func tableView(_ tableView: NGTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool { false }
    func tableView(_ tableView: NGTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {}
    func tableView(_ tableView: NGTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {}
    func tableView(_ tableView: NGTableView, updateDraggingItemsForDrag draggingInfo: any NSDraggingInfo) {}
    #endif
    func tableView(_ tableView: NGTableView, sortValueFor column: NGTableColumn, row: Int) -> NGCellValue {
        self.tableView(tableView, valueFor: column, row: row)
    }
}

/// A cell of the table: a data source row and a column.
public struct NGCellPosition: Hashable, Sendable {
    /// A data source row, like every row index in the API.
    public var row: Int
    public var columnID: String

    public init(row: Int, columnID: String) {
        self.row = row
        self.columnID = columnID
    }
}

/// A delegate whose rows have heights of their own, like `NSTableViewDelegate`'s
/// `tableView(_:heightOfRow:)`. Conform the table's `delegate` to it:
///
/// ```swift
/// final class LogDelegate: NGTableViewDelegate, NGTableViewRowHeights {
///     func tableView(_ tableView: NGTableView, heightOfRow row: Int) -> CGFloat {
///         entries[row].isExpanded ? 72 : tableView.rowHeight
///     }
/// }
/// ```
///
/// The table asks for a row's height once and keeps it with the record, so
/// it follows the record when rows are sorted, filtered or grouped; it asks
/// again for rows the app reloads (`reloadData()`, the targeted updates) and
/// for new ones. There is no `noteHeightOfRows(withIndexesChanged:)`:
/// reload the rows whose heights changed. Group header rows keep `rowHeight`.
@MainActor
public protocol NGTableViewRowHeights: AnyObject {
    /// The height of a data source row, in points (at least 1).
    func tableView(_ tableView: NGTableView, heightOfRow row: Int) -> CGFloat
}

/// Optional customization and notifications of an `NGTableView`.
@MainActor
public protocol NGTableViewDelegate: AnyObject {
    /// Called when the selection changed, like `NSTableViewDelegate`'s: by the
    /// keyboard, by a click or drag once the mouse is released, by
    /// `selectRowIndexes(_:byExtendingSelection:)`, or when `reloadData()` or a
    /// `rowFilter` drops rows from it. The notification's object is the table
    /// (also posted as `NGTableView.selectionDidChangeNotification`); read the
    /// selection from `selectedRowIndexes` (data source rows).
    func tableViewSelectionDidChange(_ notification: Notification)
    /// Called while the user changes the selection with the mouse, before the
    /// button is released (`tableViewSelectionDidChange(_:)` follows), like
    /// `NSTableViewDelegate`'s. Use it to follow a growing selection live.
    func tableViewSelectionIsChanging(_ notification: Notification)
    /// Whether the user may change the selection at all right now.
    func selectionShouldChange(in tableView: NGTableView) -> Bool
    /// Whether the user may select a row (a data source row). Not asked for
    /// selections made from code. Arrow keys skip rows it rejects.
    func tableView(_ tableView: NGTableView, shouldSelectRow row: Int) -> Bool
    /// The rows to select when the user proposes a selection (data source
    /// rows), like `NSTableViewDelegate`'s. By default, the proposed rows
    /// `tableView(_:shouldSelectRow:)` accepts.
    func tableView(_ tableView: NGTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet
    /// Called when the user changes the summary scope from the summary row's context menu.
    func tableView(_ tableView: NGTableView, summaryScopeDidChange scope: NGSummaryScope)
    /// Called when the user finishes resizing a column in the header, e.g. to persist widths.
    func tableView(_ tableView: NGTableView, didResizeColumn column: NGTableColumn, width: Double)
    /// Called when the user finishes moving columns by dragging their headers.
    /// `columns` is the new column definition (also available as `tableView.columns`).
    func tableView(_ tableView: NGTableView, didReorderColumns columns: [NGColumnItem])
    /// Called when the user shows or hides columns or groups from the header menu.
    func tableView(_ tableView: NGTableView, didChangeHiddenColumns hiddenColumnIDs: Set<String>)
    /// Called when the user changed a column filter from the header (see
    /// `NGTableView.columnFilters`).
    func tableView(_ tableView: NGTableView, didChangeColumnFilters filters: [String: NGColumnFilter])
    /// Called when the user grouped or ungrouped the rows from the header
    /// (see `NGTableView.allowsUserGrouping`).
    func tableView(_ tableView: NGTableView, didChangeRowGrouping grouping: NGRowGrouping?)
    /// Called whenever a column's width changed, by the user (also while
    /// dragging) or from code, like `NSTableViewDelegate`'s. The userInfo has
    /// the column under `"NSTableColumn"` and its previous width under
    /// `"NSOldWidth"`; also posted as `NGTableView.columnDidResizeNotification`.
    func tableViewColumnDidResize(_ notification: Notification)
    /// Called when the user moved a column by dragging its header, like
    /// `NSTableViewDelegate`'s, once per moved column (a group moves several).
    /// The userInfo has its index in `tableColumns` before and after under
    /// `"NSOldColumn"` and `"NSNewColumn"`; also posted as
    /// `NGTableView.columnDidMoveNotification`.
    func tableViewColumnDidMove(_ notification: Notification)
    /// Called when the user clicked a column's title (not dragged it), after
    /// any sort it asked for, like `NSTableViewDelegate`'s.
    func tableView(_ tableView: NGTableView, didClick tableColumn: NGTableColumn)
    /// Called when the mouse goes down in a column's title, before it turns
    /// into a click or a drag, like `NSTableViewDelegate`'s.
    func tableView(_ tableView: NGTableView, mouseDownInHeaderOf tableColumn: NGTableColumn)
    /// Called after the user dragged a column to another place, once per
    /// moved column, like `NSTableViewDelegate`'s (see also
    /// `tableViewColumnDidMove(_:)`).
    func tableView(_ tableView: NGTableView, didDrag tableColumn: NGTableColumn)
    /// Whether the user may drag the column at `columnIndex` to `newColumnIndex`
    /// (indexes in `tableColumns`), asked as a dragged column passes another,
    /// like `NSTableViewDelegate`'s. Whole groups move without asking.
    func tableView(_ tableView: NGTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool
    /// The width for a column whose header divider the user double-clicked,
    /// like `NSTableViewDelegate`'s; `nil` (the default) sizes it to fit its
    /// title, values and summary.
    func tableView(_ tableView: NGTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat?
    /// Whether the header menu lets the user show or hide a column, like
    /// `NSTableViewDelegate`'s (see also `allowsColumnHiding`).
    func tableView(_ tableView: NGTableView, userCanChangeVisibilityOf column: NGTableColumn) -> Bool
    /// Called after the user showed or hid columns from the header menu, with
    /// the columns that changed, like `NSTableViewDelegate`'s.
    func tableView(_ tableView: NGTableView, userDidChangeVisibilityOf columns: [NGTableColumn])
    /// The text that typing matches for a row (`tableColumn` is the
    /// `typeSelectColumnID` column), like `NSTableViewDelegate`'s. `nil` (the
    /// default) matches the cell's text; an empty string leaves the row out.
    #if os(macOS)
    /// Whether a typed key selects rows by type select, like NSTableView's
    /// `tableView(_:shouldTypeSelectFor:withCurrentSearch:)`: `false` lets the
    /// key go on to the next responder. `searchString` is the search typed
    /// so far, `nil` before one began.
    func tableView(_ tableView: NGTableView, shouldTypeSelectFor event: NSEvent, withCurrentSearch searchString: String?) -> Bool
    #endif
    /// The first row in `startRow..<endRow` matching what was typed, or -1,
    /// like NSTableView's `tableView(_:nextTypeSelectMatchFromRow:toRow:for:)`.
    /// Rows here are display indexes (see `NGTableView.row(atDisplayIndex:)`),
    /// the order shown when the table sorts, filters or groups. A search that
    /// wraps asks for the rows after the current one, then from the top,
    /// so `endRow` is never less than `startRow`. By default the table's own
    /// match: the text of the type select column starting with the string.
    func tableView(_ tableView: NGTableView, nextTypeSelectMatchFromRow startRow: Int, toRow endRow: Int, for searchString: String) -> Int
    func tableView(_ tableView: NGTableView, typeSelectStringFor tableColumn: NGTableColumn?, row: Int) -> String?
    /// The tool tip of a cell, like `NSTableViewDelegate`'s
    /// `tableView(_:toolTipFor:rect:tableColumn:row:mouseLocation:)`. `nil`
    /// (the default) shows the whole text of a cell too narrow for it, a
    /// mark's label or a media cell's text; an empty string shows none.
    func tableView(_ tableView: NGTableView, toolTipForRow row: Int, column: NGTableColumn) -> String?
    /// Actions a swipe across a row shows at an edge, like NSTableView's
    /// `tableView(_:rowActionsForRow:edge:)`; none by default.
    func tableView(_ tableView: NGTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NGRowAction]
    /// Whether the user may edit a cell of an editable column, like
    /// NSTableView's `tableView(_:shouldEdit:row:)`.
    func tableView(_ tableView: NGTableView, shouldEdit tableColumn: NGTableColumn, row: Int) -> Bool
    #if os(macOS)
    /// The context menu for a right-click (or Control-click) in the rows. The
    /// table adds no items of its own: build the menu with your app's actions.
    ///
    /// - Parameters:
    ///   - tableView: The table that was clicked.
    ///   - rows: The rows the menu acts on, like in Finder and Mail: the whole
    ///     selection when the clicked row is selected, otherwise just the
    ///     clicked row (which is outlined, while the selection stays as it is).
    ///     Empty for clicks below the last row.
    ///   - clickedRow: The row under the pointer, or `nil` below the last row.
    ///     Also available as `tableView.clickedRow` (-1 below the last row)
    ///     while the actions run.
    ///   - column: The column under the pointer.
    /// - Returns: The menu, or `nil` for the table's `menu` (like an
    ///   `NSTableView`'s, with `clickedRow` set), if it has one.
    func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: NGTableColumn?) -> NSMenu?
    #else
    /// The context menu for a long press (or a secondary click with a pointer)
    /// in the rows. The table adds no items of its own: build the menu with
    /// your app's actions.
    ///
    /// - Parameters:
    ///   - tableView: The table that was pressed.
    ///   - rows: The rows the menu acts on: the whole selection when the
    ///     pressed row is selected, otherwise just the pressed row (which is
    ///     outlined, while the selection stays as it is). Empty below the last row.
    ///   - clickedRow: The row pressed, or `nil` below the last row. Also
    ///     available as `tableView.clickedRow` while the actions run.
    ///   - column: The column pressed.
    /// - Returns: The menu, or `nil` for none.
    func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: NGTableColumn?) -> UIMenu?
    #endif
    /// A tint for a row's background instead of the alternating stripes, e.g. a
    /// pale green for profitable campaigns. Use light, translucent colors (like
    /// `NGColor.systemGreen.withAlphaComponent(0.12)`) so text stays readable,
    /// and return the same color objects each time (e.g. static constants):
    /// this is asked for every visible row while scrolling.
    /// Selected rows show the selection color instead.
    func tableView(_ tableView: NGTableView, backgroundColorForRow row: Int) -> NGColor?
    /// A bright mark a few points wide at the leading edge of a row, e.g. a
    /// campaign's status. Purely decorative; `nil` shows none.
    func tableView(_ tableView: NGTableView, markerColorForRow row: Int) -> NGColor?
    /// Called when summaries computed in the background (see
    /// `NGTableView.synchronousSummaryLimit`) are ready and shown.
    func tableViewDidUpdateSummary(_ tableView: NGTableView)
    /// The title of a group's header row (see `NGTableView.rowGrouping`),
    /// e.g. a name for an id, or `nil` for the displayed value ("No Value"
    /// for rows without one). Asked for visible headers as they are drawn.
    func tableView(_ tableView: NGTableView, titleFor group: NGRowGroup) -> String?
    /// Called after the user or the app expanded a group, like
    /// `NSOutlineViewDelegate.outlineViewItemDidExpand(_:)`. The userInfo has
    /// the group under `"NGRowGroup"`; also posted as
    /// `NGTableView.groupDidExpandNotification`.
    func tableViewGroupDidExpand(_ notification: Notification)
    /// Called after a group collapsed; see `tableViewGroupDidExpand(_:)`.
    func tableViewGroupDidCollapse(_ notification: Notification)
    /// Whether the user may select a column by clicking its header (see
    /// `NGTableView.allowsColumnSelection`), like NSTableView's
    /// `tableView(_:shouldSelect:)`; code isn't asked.
    func tableView(_ tableView: NGTableView, shouldSelect tableColumn: NGTableColumn?) -> Bool
    /// Whether the user may expand a row of a tree (`NGTableView.rowTree`),
    /// like `outlineView(_:shouldExpandItem:)`: asked for clicks on the
    /// triangle, the keys and VoiceOver, not for `expandRow(_:expandChildren:)`.
    /// With Option, also for each row within; rows refused stay as they are.
    func tableView(_ tableView: NGTableView, shouldExpandRow row: Int) -> Bool
    /// Whether the user may collapse a row of a tree; see `tableView(_:shouldExpandRow:)`.
    func tableView(_ tableView: NGTableView, shouldCollapseRow row: Int) -> Bool
    /// Called before a row of a tree expands, like `outlineViewItemWillExpand(_:)`;
    /// also posted as `NGTableView.rowWillExpandNotification`. The userInfo
    /// has the row's identity under `"NGRowIdentifier"`.
    func tableViewRowWillExpand(_ notification: Notification)
    /// Called after a row of a tree expanded (`NGTableView.rowDidExpandNotification`).
    func tableViewRowDidExpand(_ notification: Notification)
    /// Called before a row of a tree collapses (`NGTableView.rowWillCollapseNotification`).
    func tableViewRowWillCollapse(_ notification: Notification)
    /// Called after a row of a tree collapsed (`NGTableView.rowDidCollapseNotification`).
    func tableViewRowDidCollapse(_ notification: Notification)
    /// Called when the pointer comes over a cell (see `NGTableView.hoveredCell`),
    /// like SwiftUI's `onContinuousHover`: also when the rows scroll or change
    /// under a resting pointer. Group header rows and the header and summary
    /// rows have no cell events.
    func tableView(_ tableView: NGTableView, pointerDidEnterRow row: Int, column: NGTableColumn)
    /// Called when the pointer leaves a cell, before it enters the next one.
    /// `row` is the row it had when the pointer entered.
    func tableView(_ tableView: NGTableView, pointerDidExitRow row: Int, column: NGTableColumn)
    /// A link cell (``NGLink``) was clicked (pressed and released in it, or
    /// pressed with Space or VoiceOver); the row isn't selected by it. The
    /// default opens the link's URL with `NSWorkspace`.
    func tableView(_ tableView: NGTableView, didClickLink link: NGLink, in column: NGTableColumn, row: Int)
    /// A button cell (``NGCellButton``) was pressed: pressed and released over
    /// it, or pressed with Space or VoiceOver. The row isn't selected by it.
    func tableView(_ tableView: NGTableView, didPressButton button: NGCellButton, in column: NGTableColumn, row: Int)
}

public extension NGTableViewDelegate {
    func tableViewSelectionDidChange(_ notification: Notification) {}
    func tableView(_ tableView: NGTableView, pointerDidEnterRow row: Int, column: NGTableColumn) {}
    func tableView(_ tableView: NGTableView, pointerDidExitRow row: Int, column: NGTableColumn) {}
    func tableView(_ tableView: NGTableView, didClickLink link: NGLink, in column: NGTableColumn, row: Int) {
        NGTableView.open(link)
    }
    func tableView(_ tableView: NGTableView, didPressButton button: NGCellButton, in column: NGTableColumn, row: Int) {}
    func tableViewSelectionIsChanging(_ notification: Notification) {}
    func selectionShouldChange(in tableView: NGTableView) -> Bool { true }
    func tableView(_ tableView: NGTableView, shouldSelectRow row: Int) -> Bool { true }
    func tableView(_ tableView: NGTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        // A loop, not a closure per row (closures check the executor on every
        // call), gathering runs of accepted rows: selecting all of 200,000
        // rows asks each of them.
        var accepted = IndexSet()
        for range in proposedSelectionIndexes.rangeView {
            var start = -1
            for row in range {
                if self.tableView(tableView, shouldSelectRow: row) {
                    if start < 0 { start = row }
                } else if start >= 0 {
                    accepted.insert(integersIn: start..<row)
                    start = -1
                }
            }
            if start >= 0 { accepted.insert(integersIn: start..<range.upperBound) }
        }
        return accepted
    }
    func tableView(_ tableView: NGTableView, summaryScopeDidChange scope: NGSummaryScope) {}
    func tableView(_ tableView: NGTableView, didResizeColumn column: NGTableColumn, width: Double) {}
    func tableView(_ tableView: NGTableView, didReorderColumns columns: [NGColumnItem]) {}
    func tableView(_ tableView: NGTableView, didChangeHiddenColumns hiddenColumnIDs: Set<String>) {}
    func tableView(_ tableView: NGTableView, didChangeColumnFilters filters: [String: NGColumnFilter]) {}
    func tableView(_ tableView: NGTableView, didChangeRowGrouping grouping: NGRowGrouping?) {}
    func tableViewColumnDidResize(_ notification: Notification) {}
    func tableViewColumnDidMove(_ notification: Notification) {}
    func tableView(_ tableView: NGTableView, didClick tableColumn: NGTableColumn) {}
    func tableView(_ tableView: NGTableView, mouseDownInHeaderOf tableColumn: NGTableColumn) {}
    func tableView(_ tableView: NGTableView, didDrag tableColumn: NGTableColumn) {}
    func tableView(_ tableView: NGTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool { true }
    func tableView(_ tableView: NGTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat? { nil }
    func tableView(_ tableView: NGTableView, userCanChangeVisibilityOf column: NGTableColumn) -> Bool { true }
    func tableView(_ tableView: NGTableView, userDidChangeVisibilityOf columns: [NGTableColumn]) {}
    func tableView(_ tableView: NGTableView, typeSelectStringFor tableColumn: NGTableColumn?, row: Int) -> String? { nil }
    #if os(macOS)
    func tableView(_ tableView: NGTableView, shouldTypeSelectFor event: NSEvent, withCurrentSearch searchString: String?) -> Bool { true }
    #endif
    func tableView(_ tableView: NGTableView, nextTypeSelectMatchFromRow startRow: Int, toRow endRow: Int, for searchString: String) -> Int {
        tableView.typeSelectMatch(from: startRow, to: endRow, for: searchString)
    }
    func tableView(_ tableView: NGTableView, toolTipForRow row: Int, column: NGTableColumn) -> String? { nil }
    func tableView(_ tableView: NGTableView, shouldEdit tableColumn: NGTableColumn, row: Int) -> Bool { true }
    func tableView(_ tableView: NGTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NGRowAction] { [] }
    #if os(macOS)
    func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: NGTableColumn?) -> NSMenu? { nil }
    #else
    func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: NGTableColumn?) -> UIMenu? { nil }
    #endif
    func tableView(_ tableView: NGTableView, backgroundColorForRow row: Int) -> NGColor? { nil }
    func tableView(_ tableView: NGTableView, markerColorForRow row: Int) -> NGColor? { nil }
    func tableViewDidUpdateSummary(_ tableView: NGTableView) {}
    func tableView(_ tableView: NGTableView, titleFor group: NGRowGroup) -> String? { nil }
    func tableViewGroupDidExpand(_ notification: Notification) {}
    func tableViewGroupDidCollapse(_ notification: Notification) {}
    func tableView(_ tableView: NGTableView, shouldSelect tableColumn: NGTableColumn?) -> Bool { true }
    func tableView(_ tableView: NGTableView, shouldExpandRow row: Int) -> Bool { true }
    func tableView(_ tableView: NGTableView, shouldCollapseRow row: Int) -> Bool { true }
    func tableViewRowWillExpand(_ notification: Notification) {}
    func tableViewRowDidExpand(_ notification: Notification) {}
    func tableViewRowWillCollapse(_ notification: Notification) {}
    func tableViewRowDidCollapse(_ notification: Notification) {}
}
#endif
