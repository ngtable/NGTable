#if os(macOS)
import AppKit

/// How selected rows are highlighted.
public enum NGSelectionHighlightStyle: Sendable {
    /// Inset from the table edges with rounded corners, like macOS list views.
    case rounded
    /// A rectangle across the whole row.
    case fullWidth
}

/// A table with frozen leading/trailing columns, grouped column headers and a
/// summary row.
///
/// Add it to a view like any other view (it scrolls by itself: don't put it in
/// an `NSScrollView`), give it `columns`, a `dataSource` and optionally a
/// `delegate`, and call `reloadData()` whenever the data changes. The table
/// only displays data; sorting, editing and actions belong to the app, which
/// the table tells about the user's requests through its delegate.
///
/// Row indexes in the API (selection, `clickedRow`, data source and delegate
/// calls) are data source indexes, also while a `rowFilter` hides rows.
/// Everything runs on the main actor.
///
/// How it works:
/// - The table does its own scrolling instead of using `NSScrollView`.
///   Trackpad gestures, momentum and mouse wheels still come from the system as
///   scroll events; the table applies their deltas to its `contentOffset`,
///   with elastic overscroll at the top and bottom (see `bouncesVertically`).
/// - Each region (leading frozen, scrolling, trailing frozen) has a canvas
///   that scrolls with the content. All regions, the header and the summary
///   row are updated in the same pass, so they can never drift apart.
/// - The GPU (Metal) draws the row backgrounds, cells (pictures and videos
///   too), header titles and summary values from a glyph atlas, with Core
///   Text's typesetting, and only when something visible changed.
/// - Scrollers are overlay scrollers the table places and reveals (legacy
///   scrollers when "Show scroll bars: Always" is set in System Settings).
public final class NGTableView: NSView {
    /// Supplies the rows and values. Setting it reloads the table. Held weakly:
    /// keep the data source alive yourself.
    public weak var dataSource: NGTableViewDataSource? {
        didSet {
            // A sort set or restored (see `autosaveName`) before the data
            // source came: it sorts by it like for a change.
            if !sortDescriptors.isEmpty {
                dataSource?.tableView(self, sortDescriptorsDidChange: [])
            }
            reloadData()
        }
    }

    /// Row tints and markers, menus, the pointer over cells and notifications. Held weakly.
    public weak var delegate: NGTableViewDelegate? {
        // Tints and markers come from the delegate.
        didSet {
            rowHeightProvider = delegate as? NGTableViewRowHeights
            forgetAllRowHeights()
            recycleAllCells()
            needsLayout = true
        }
    }

    /// Column definition. Groups and pins are resolved into regions automatically.
    public var columns: [NGColumnItem] = [] {
        didSet {
            identifierColumn = nil
            cachedTableColumns = nil
            tableColumnsVersion &+= 1
            guard !isApplyingLayoutState else { return }
            // The app's definition (not the table's own reorders): its pins
            // are what a layout state without the user's comes back to.
            if !isReorderingColumns { definitionPins = Dictionary(columns.map { ($0.id, $0.pin) }, uniquingKeysWith: { first, _ in first }) }
            let duplicates = NGColumnLayout.duplicateIDs(in: columns)
            assert(duplicates.isEmpty, "NGTableView: duplicate column or group ids \(duplicates.sorted())")
            rebuildColumns()
            // A new definition picks up the user's saved customizations.
            if !isReorderingColumns, let state = autosavedLayoutState {
                applyLayoutState(state)
            }
        }
    }

    /// Which rows the summary row aggregates.
    public var summaryScope: NGSummaryScope = .allRows {
        didSet {
            guard summaryScope != oldValue else { return }
            // Its color shows the scope, even when the totals stay.
            summaryBar.contentView.needsDisplay = true
            updateSummary()
        }
    }

    /// Whether the summary row shows at the bottom of the table (while there
    /// is data, see `emptyStateText`).
    public var showsSummaryRow = true {
        didSet {
            summaryBar.isHidden = !showsSummaryBar
            needsLayout = true
            updateSummaryProgress()
        }
    }

    /// Whether the keyboard moves a focused cell (`focusedCell`) instead of
    /// whole rows: Left and Right go from column to column, Tab and Shift-Tab
    /// too, Up and Down from row to row; a click focuses the cell clicked.
    /// Editable cells edit on Return, a double click or typing.
    public var navigatesByCell = false {
        didSet { setNeedsMetalFrame() }
    }

    /// The cell the keyboard acts on, with `navigatesByCell` (drawn with a
    /// ring), or `nil`.
    /// Kept by row handle, so it stays on its record as live updates insert,
    /// remove and move rows (a removed record's cell is no longer focused).
    public var focusedCell: NGCellPosition? {
        get { focusedHandleCell.flatMap(position(of:)) }
        set {
            let cell = newValue.flatMap(handleCell(of:))
            guard cell != focusedHandleCell else { return }
            focusedHandleCell = cell
            setNeedsMetalFrame()
        }
    }
    var focusedHandleCell: NGHandleCell? {
        didSet {
            // Its record's identity, read while the data is the one shown: a
            // reload finds the record by it (the data has changed by then).
            guard focusedHandleCell?.ref != oldValue?.ref else { return }
            let row = focusedHandleCell.map { self.row(of: $0.ref) } ?? -1
            focusedIdentity = row >= 0 ? identifier(forSourceRow: row) : nil
        }
    }
    var focusedIdentity: AnyHashable?
    /// The locale changed while a batch was open: its keys are read when it ends.
    var localeChangedDuringBatch = false
    /// Tests and benchmarks draw in windows that aren't on screen.
    var drawsWhileUnseenForTesting = false
    /// What the header and summary were last laid out by (see `layout()`).
    var lastChromeLayoutKey: Int?
    /// The group whose header row the keyboard is on (see NGGroupKeyboard.swift).
    var keyboardGroup: NGRowGroup? {
        didSet { if keyboardGroup != oldValue { refreshSelectionAppearance() } }
    }
    /// Whether the focused cell's ring shows: only after moving it with the
    /// keyboard (like `:focus-visible`). A click hides it and so does the table
    /// losing the focus; the focused cell stays, for the keys to go on from.
    var showsFocusRing = false {
        didSet { if showsFocusRing != oldValue { setNeedsMetalFrame() } }
    }
    /// A rectangle of cells the user selected with navigation by cell
    /// (Shift with arrows, a Shift-click, a drag), or `nil`; its rows are
    /// the selected rows, and Copy copies its cells (see NGCellSelection.swift).
    /// Its corners are kept by row handle, like `focusedCell`.
    public var selectedCellRange: NGCellRange? {
        get {
            guard let range = selectedHandleRange, let anchor = position(of: range.anchor), let end = position(of: range.end) else { return nil }
            return NGCellRange(anchor: anchor, end: end)
        }
        set {
            let range = newValue.flatMap { range in
                handleCell(of: range.anchor).flatMap { anchor in handleCell(of: range.end).map { (anchor, $0) } }
            }
            guard range?.0 != selectedHandleRange?.anchor || range?.1 != selectedHandleRange?.end else { return }
            selectedHandleRange = range.map { (anchor: $0.0, end: $0.1) }
            setNeedsMetalFrame()
        }
    }
    var selectedHandleRange: (anchor: NGHandleCell, end: NGHandleCell)?
    /// A press on a draggable row, until it turns into a drag (see NGRowDragging.swift).
    var rowDragPress: (location: NSPoint, ref: NGRowRef, wasSelected: Bool)?
    /// The display row a drop opens a gap at (`.gap` feedback), and when it
    /// began to open.
    var dropGap: (displayRow: Int, start: CFTimeInterval)?
    var dropGapLink: CADisplayLink?
    /// What deleting the selected rows does (Delete, Backspace, Edit >
    /// Delete), `NGDataTable`'s `onDelete`; `nil`: the keys go on.
    var rowDeletion: ((IndexSet) -> Void)?
    /// The records being dragged out (see `draggedRowIndexes`).
    var draggedRowRefs: [NGRowRef] = []
    /// Selected columns by id (they move and hide with their columns), and
    /// the last one selected (see NGColumnSelection.swift).
    var selectedColumnIDs: Set<String> = []
    var lastSelectedColumnID: String?
    var allowsColumnSelectionStorage = false
    /// The locale values are formatted in (cells, summaries, group titles,
    /// search, copying, export and printing, VoiceOver), like a SwiftUI
    /// view's `\.locale`; `nil` (the default) is the user's, following its
    /// changes. Sorting text follows the user's language either way.
    public var locale: Locale? {
        didSet {
            guard locale?.identifier != oldValue?.identifier else { return }
            columnFormatIDs = []
            currentLocaleDidChange(Notification(name: NSLocale.currentLocaleDidChangeNotification))
            reloadData()
        }
    }
    /// The locale values are formatted in: `locale`, or the user's.
    var formattingLocale: Locale { locale ?? .current }
    /// Whether the table responds to the mouse and keyboard, like an
    /// NSControl's (`NSTableView.isEnabled`): off, it ignores the user, can't
    /// become first responder, and shows dimmed.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.5
            if !isEnabled, window?.firstResponder === self { window?.makeFirstResponder(nil) }
            if !isEnabled { endEditing(committing: true) }
        }
    }
    /// How columns wider than the paper print, like the print info's
    /// horizontal pagination: `.fit` (the default) scales them to the page's
    /// width, `.automatic` prints them across pages in bands of whole
    /// columns (the columns pinned at the leading edge on every band),
    /// `.clip` cuts them off.
    public var printPagination: NSPrintInfo.PaginationMode = .fit
    /// The app's own controllers in the print panel, after the table's options.
    public var printPanelAccessories: [NSViewController & NSPrintPanelAccessorizing] = []
    /// How a drop onto the table shows, like NSTableView's: `.regular` (and
    /// `.sourceList`, which looks the same) draws a line between rows or a
    /// highlight on the row, `.gap` opens a gap between the rows instead of
    /// the line, `.none` shows nothing.
    public var draggingDestinationFeedbackStyle: NSTableView.DraggingDestinationFeedbackStyle = .regular {
        didSet { setNeedsMetalFrame() }
    }
    /// A plain press on one of several selected rows selects only it when the
    /// mouse goes up without dragging, like NSTableView (so the selected rows
    /// can be dragged together).
    var pendingClickRow: NGRowRef?
    /// Whether dragging up or down from a row that wasn't selected drags it,
    /// like NSTableView's: with `false` such a drag selects rows (or cells),
    /// and a sideways one drags. Selected rows drag in any direction.
    public var verticalMotionCanBeginDrag = true
    /// Where a drop would go (a data source row, or the count at the end).
    var dropIndicatorRow: Int?
    /// Whether a drop would go above `dropIndicatorRow` or onto it (-1 with
    /// `.on`: onto the whole table).
    var dropIndicatorOperation: NSTableView.DropOperation = .above
    /// Set by `setDropRow(_:dropOperation:)` while the data source validates a drop.
    var dropRetarget: (row: Int, operation: NSTableView.DropOperation)?
    /// Scrolls while a drag stays near the top or bottom of the rows.
    var dropScrollLink: CADisplayLink?
    var dropScrollInfo: (any NSDraggingInfo)?
    var draggingSourceOperationMaskWithinApplication: NSDragOperation = .every
    var draggingSourceOperationMaskOutside: NSDragOperation = .copy
    /// The cell being edited (see NGCellEditing.swift).
    var editor: NGCellEditor?
    /// Ends editing on Return, Tab and Escape.
    var editorDelegate: NGCellEditorDelegate {
        if let cellEditorDelegate { return cellEditorDelegate }
        let delegate = NGCellEditorDelegate()
        delegate.table = self
        cellEditorDelegate = delegate
        return delegate
    }
    var cellEditorDelegate: NGCellEditorDelegate?

    /// Whether a cell is being edited.
    public var isEditingCell: Bool { editor != nil }

    /// Fonts and colors beyond the system defaults (see `NGTableStyle`).
    public var tableStyle = NGTableStyle() {
        didSet {
            guard tableStyle != oldValue else { return }
            applyTableStyle()
        }
    }

    /// Sets `rowHeight` for the style's font with some room around the text
    /// (`nil`: `rowHeight` as set). `.regular` is the default 24 points at
    /// the system font size.
    public var density: NGTableDensity? {
        didSet {
            guard density != oldValue, let density else { return }
            rowHeight = rowHeight(for: density)
        }
    }

    /// Height of every row, in points (at least 1), unless the delegate gives
    /// rows heights of their own (`NGTableViewRowHeights`) or a column wraps
    /// text (`NGTableColumn.wrappingText()`: a row of one line has it, each
    /// line more adds the font's line height); group header rows have it in
    /// any case.
    public var rowHeight: CGFloat = 24 {
        didSet {
            // Rows are laid out by dividing by the height.
            if rowHeight < 1 { rowHeight = 1 }
            guard rowHeight != oldValue else { return }
            rowGeometryCache = nil
            // The data is unchanged: only cells move, summaries stay.
            recycleAllCells()
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    /// Where the display rows are: their tops and heights, the row at a y.
    /// With a delegate that gives rows their heights (`NGTableViewRowHeights`)
    /// or a column that wraps text (rows measured, see NGWrappedRows.swift),
    /// built when asked after the rows shown or their heights changed.
    var rowGeometry: NGRowGeometry {
        guard rowHeightProvider != nil || wrapsTextInSomeColumn else { return NGRowGeometry(rowHeight: rowHeight, count: numberOfRows) }
        if let rowGeometryCache, rowGeometryCache.count == numberOfRows { return rowGeometryCache }
        let geometry = buildRowGeometry(rowHeightProvider)
        rowGeometryCache = geometry
        return geometry
    }

    /// The delegate as one that gives rows their heights.
    var rowHeightProvider: NGTableViewRowHeights?
    /// The rows' heights by handle (NaN: not asked or measured yet); used
    /// only with a `rowHeightProvider` or a column that wraps text.
    var rowHeightsByHandle: [CGFloat] = []
    /// What the measured heights were measured for (see `measureRowsInView`).
    var lastMeasuredRowsKey: [Double] = []
    /// Measuring the rows of a large table in the background (see
    /// NGWrappedRows.swift): the task, the next handle it looks at, whether
    /// rows may be left to measure, the handles forgotten while a slice is
    /// measured, and a count of the times every height was forgotten.
    var measuringTask: Task<Void, Never>?
    var measuringNext = 0
    var rowsLeftToMeasure = false
    var measuringForgotten = IndexSet()
    var measuringGeneration = 0
    /// Tests: called when a slice of rows was read for measuring, before
    /// their lines are counted.
    var measuringSliceWasReadForTesting: (() -> Void)?

    /// Forgets every row's height (asked or measured again).
    func forgetAllRowHeights() {
        rowHeightsByHandle = []
        rowGeometryCache = nil
        measuringGeneration &+= 1
        measuringNext = 0
        rowsLeftToMeasure = true
    }
    /// The geometry of rows of their own heights, until the rows shown or
    /// their heights change.
    var rowGeometryCache: NGRowGeometry?

    /// The display rows' heights, asking the provider for those it hasn't
    /// given yet (without one, rows not measured yet count as `rowHeight`):
    /// group header rows have `rowHeight`. One pass over the rows into their
    /// tops (a million rows: about a millisecond).
    private func buildRowGeometry(_ provider: NGTableViewRowHeights?) -> NGRowGeometry {
        if rowHeightsByHandle.count < rowHandles.capacity {
            rowHeightsByHandle.append(contentsOf: repeatElement(.nan, count: rowHandles.capacity - rowHeightsByHandle.count))
        }
        let count = numberOfRows
        let rowHeight = rowHeight
        let identity = rowHandles.isIdentity
        let sorted = groupedDisplay == nil ? sortedDisplay : nil
        // The display rows' handles (-1: a group header), in order, by buffers.
        func forEachHandle(_ body: (Int) -> Void) {
            if let groupedDisplay {
                groupedDisplay.withUnsafeBufferPointer { for entry in $0 { body(entry) } }
            } else if let sorted {
                sorted.forEachBlock { for handle in $0 { body(Int(handle)) } }
            } else if let rowMap {
                rowMap.withUnsafeBufferPointer { for handle in $0 { body(handle) } }
            } else if identity {
                for row in 0..<min(count, rowHandles.capacity) { body(row) }
            } else {
                for row in 0..<count { body(handle(ofRow: row)) }
            }
        }
        if let provider {
            // Heights not given yet, asked first (in display order).
            forEachHandle { handle in
                guard handle >= 0, handle < rowHeightsByHandle.count, rowHeightsByHandle[handle].isNaN else { return }
                let row = row(ofHandle: handle)
                guard row >= 0 else { return }
                rowHeightsByHandle[handle] = max(1, provider.tableView(self, heightOfRow: row))
            }
        }
        let tops = rowHeightsByHandle.withUnsafeBufferPointer { heights in
            [CGFloat](unsafeUninitializedCapacity: count + 1) { tops, initialized in
                tops[0] = 0
                var written = 1
                var y: CGFloat = 0
                forEachHandle { handle in
                    // In the middle of a batch the orders may not match the count yet.
                    guard written <= count else { return }
                    let height = handle >= 0 && handle < heights.count ? heights[handle] : rowHeight
                    y += height.isNaN ? rowHeight : height
                    tops[written] = y
                    written += 1
                }
                while written <= count {
                    y += rowHeight
                    tops[written] = y
                    written += 1
                }
                initialized = written
            }
        }
        return NGRowGeometry(rowHeight: rowHeight, tops: tops)
    }

    /// Forgets the heights of rows (handles) the app reloaded: they are
    /// asked for (or measured) again.
    func forgetRowHeights(ofHandles handles: some Sequence<Int>) {
        guard rowHeightProvider != nil || wrapsTextInSomeColumn else { return }
        for handle in handles where handle >= 0 && handle < rowHeightsByHandle.count {
            rowHeightsByHandle[handle] = .nan
            if measuringTask != nil { measuringForgotten.insert(handle) }
        }
        rowsLeftToMeasure = true
        rowGeometryCache = nil
    }

    /// Height of the summary row.
    public var summaryRowHeight: CGFloat = 30 {
        didSet { needsLayout = true }
    }

    /// Height of the leaf column header row.
    public var headerRowHeight: CGFloat = 28 {
        didSet { needsLayout = true }
    }

    /// Height of the group header band (only shown when groups exist).
    public var groupHeaderHeight: CGFloat = 24 {
        didSet { needsLayout = true }
    }

    /// Whether rows alternate between the system's two content background
    /// colors. Row tints from the delegate replace the stripes of their rows.
    public var usesAlternatingRowBackgroundColors = true {
        didSet { refreshSelectionAppearance() }
    }

    /// Whether thin lines separate the columns in the rows.
    public var showsVerticalGridLines = false {
        didSet { if showsVerticalGridLines != oldValue { setNeedsMetalFrame() } }
    }
    /// See `showsHeader`, `gridStyleMask`, `gridColor` and `intercellSpacing`.
    var hidesHeader = false
    /// Right to left: the visible width the scrolling columns were mirrored in.
    var mirroredCenterSpan: CGFloat = 0
    var horizontalGridLines = NGHorizontalGridLines.none
    var gridLineColor = NSColor.gridColor
    var cellSpacing = NSSize.zero
    /// See `columnAutoresizingStyle`.
    var autoresizingStyle = NSTableView.ColumnAutoresizingStyle.noColumnAutoresizing
    var lastAutoresizedWidth: CGFloat?
    /// Width rounding left out of the last autoresize (see `autoresizeColumns`).
    var autoresizeCarry = 0.0
    /// Swipe actions (see NGRowSwipeActions.swift).
    var rowSwipe: NGRowSwipe?
    var swipeCandidate: NSPoint?
    var swipeTookGesture = false
    var rowActionButtons: NSView?
    /// The choice menu being shown, and its record (see NGChoiceEditing.swift).
    var openChoiceMenu: (menu: NSMenu, ref: NGRowRef)?

    /// Whether several rows can be selected (with Shift, Command, dragging and
    /// Select All). With `false`, at most one row is selected.
    public var allowsMultipleSelection = true

    /// Whether the user can leave no row selected, like `NSTableView`'s:
    /// with `false`, clicks below the rows and Command-clicks on the last
    /// selected row keep it selected (code can still clear the selection).
    public var allowsEmptySelection = true

    /// How selected rows are highlighted.
    public var selectionHighlightStyle: NGSelectionHighlightStyle = .rounded {
        didSet {
            guard selectionHighlightStyle != oldValue else { return }
            // Rounded rows come with margins at the table edges.
            updateGeometry()
            needsLayout = true
            headerView.needsDisplay = true
            summaryBar.contentView.needsDisplay = true
            refreshSelectionAppearance()
        }
    }

    /// Identifiers of hidden columns and groups. Hiding a group hides all of its
    /// columns; a group whose columns are all hidden disappears as well. Users
    /// change this from the header's context menu (see `allowsColumnHiding`).
    public var hiddenColumnIDs: Set<String> = [] {
        didSet {
            guard hiddenColumnIDs != oldValue, !isApplyingLayoutState else { return }
            isChangingColumnVisibility = true
            rebuildColumns()
            isChangingColumnVisibility = false
            scheduleLayoutAutosave()
        }
    }

    /// Whether the header's context menu lets the user show and hide columns.
    public var allowsColumnHiding = true

    /// When set, column order, widths and hidden columns are saved in the
    /// user defaults under this name and restored, like
    /// `NSTableView.autosaveName` with `autosaveTableColumns`: the user's
    /// changes, and widths and hidden columns set in code or given by
    /// `columnAutoresizingStyle` (once those settle). Set it after setting up
    /// the columns, or the setup is saved over what the user had.
    public var autosaveName: String? {
        didSet {
            guard autosaveName != oldValue else { return }
            reloadSavedExpansion()
            guard let state = autosavedLayoutState else { return }
            applyLayoutState(state)
        }
    }

    /// Column order, widths, hidden columns and the sort, e.g. to store them
    /// yourself. Setting it applies the state to the current `columns` (and
    /// its sort, if it has one, to `sortDescriptors`).
    public var columnLayoutState: NGColumnLayoutState {
        get {
            var state = NGColumnLayoutState(items: columns, widths: columnWidths, hiddenIDs: hiddenColumnIDs, sortDescriptors: sortDescriptors)
            state.filters = columnFilters
            state.pins = userPins.isEmpty ? nil : userPins
            // The user's grouping, when the user groups.
            if allowsUserGrouping { state.grouping = rowGrouping?.columnIDs ?? [] }
            return state
        }
        set { applyLayoutState(newValue) }
    }

    /// Whether the user can move columns by dragging their headers. Columns never
    /// leave their region or group; a group can be moved as a whole by its title.
    public var allowsColumnReordering = true

    /// Whether the header's context menu lets the user pin a column (or its
    /// group) to the leading or trailing edge, or unpin it, for columns that
    /// are ``NGTableColumn/isMovable``. Saved with `autosaveName`.
    public var allowsColumnPinning = true

    /// Whether the header's context menu offers named views: saving the
    /// columns, sort, column filters and grouping under a name and switching
    /// between them (see `saveView(named:)`). Kept under `autosaveName`.
    public var allowsNamedViews = false
    /// The view last saved or applied (see NGNamedViews.swift).
    public internal(set) var currentViewName: String?
    /// Named views of a table without `autosaveName`, for this run.
    var unsavedNamedViews: [(name: String, view: NGNamedView)] = []

    /// Whether the user can resize columns by dragging their header dividers
    /// (and size them to fit by double-clicking), like NSTableView's;
    /// ``NGTableColumn/isResizable`` turns it off per column.
    public var allowsColumnResizing = true

    /// Whether typing selects the first row whose value in the
    /// `typeSelectColumnID` column starts with the typed text, like
    /// NSTableView's.
    public var allowsTypeSelect = true

    /// Whether column headers show a filter button (columns that are
    /// ``NGTableColumn/isFilterable``) that opens a filter for the column's
    /// values, like a spreadsheet's (see `columnFilters`).
    public var allowsColumnFilters = false {
        didSet {
            guard allowsColumnFilters != oldValue else { return }
            setNeedsChromeFrame(headerView)
        }
    }

    /// How long a changed value's flash lasts (columns with a
    /// ``NGTableColumn/changeHighlight``); 0 turns flashes off.
    public var changeHighlightDuration: TimeInterval = 1.0
    /// The cells flashing, by row handle and column (see NGChangeHighlight.swift).
    var changeHighlights: [NGChangeKey: NGChangeFlash] = [:]
    /// The column ordinals that have flashed since there were none: what a
    /// reused handle looks up, instead of going through every flash.
    var changeHighlightOrdinals: Set<Int> = []
    var changeHighlightLink: CADisplayLink?

    /// Whether rows that the table's own sort (`sortsRows`) moves slide to
    /// their new places, as rows inserted, removed or moved with an animation
    /// do. Off by default: a feed that ticks many times a second reads better
    /// without motion.
    public var animatesSortMoves = false

    /// Whether the table's own sort (`sortsRows`) holds the rows in place
    /// while the pointer rests over them or a selection is dragged, so the
    /// row about to be clicked doesn't move away. Their values still change;
    /// rows that came meanwhile wait at the end. When the pointer leaves the
    /// rows (or the drag ends), they move to where they go. The user's own
    /// edits (a check box, a choice, an edited cell) move their record at
    /// once. On by default.
    public var pausesLiveSortUnderPointer = true {
        didSet { if !pausesLiveSortUnderPointer { resumeLiveSortIfNeeded() } }
    }
    /// Whether the user's own edit of a cell is being applied (it isn't held).
    var isApplyingUserEdit = false
    /// Whether the mouse button went down in the rows and is still down.
    var isPressingRows = false {
        didSet { if !isPressingRows { resumeLiveSortIfNeeded() } }
    }
    /// The running row animation (see NGRowAnimation.swift).
    var rowAnimation: NGRowAnimation?
    var rowAnimationLink: CADisplayLink?

    /// Titles of the summary row context menu, localized (English, Russian) by default.
    public var summaryScopeTitles: [NGSummaryScope: String] = [
        .allRows: String(localized: "Summarize All Rows", bundle: .module,
                         comment: "Summary row context menu: totals over all rows."),
        .selectedRows: String(localized: "Summarize Selected Rows", bundle: .module,
                              comment: "Summary row context menu: totals over the selected rows only."),
        .excludingSelectedRows: String(localized: "Summarize All Except Selected", bundle: .module,
                                       comment: "Summary row context menu: selected rows are subtracted from the total."),
    ]

    /// Resolved column layout of the current `columns`.
    public internal(set) var columnLayout = NGColumnLayout() {
        didSet { wrapsTextInSomeColumn = columnLayout.allColumns.contains { $0.wrapsText } }
    }
    /// Whether a shown column wraps text: rows are as high as their text then,
    /// and the cells of a taller row keep to its top.
    private(set) var wrapsTextInSomeColumn = false {
        didSet { if wrapsTextInSomeColumn != oldValue { rowGeometryCache = nil } }
    }

    /// The table's sort, like `NSTableView`'s: the first descriptor decides,
    /// the others order rows it finds equal. Empty: the original order.
    ///
    /// A click on a sortable header puts its column's
    /// `sortDescriptorPrototype` first (the others stay as secondary sorts);
    /// clicking the first column again reverses it, and a third click removes
    /// it. Every change, by the user or from code, calls the data source's
    /// `tableView(_:sortDescriptorsDidChange:)`, which sorts the data (a data
    /// source set later is told the current sort): the table only shows the
    /// sort in its header.
    ///
    /// With an `autosaveName` the sort is saved with the columns and restored,
    /// like `NSTableView`'s. For a default sort, set it before `autosaveName`:
    /// a saved sort (also an empty one) replaces it.
    public var sortDescriptors: [NSSortDescriptor] = [] {
        didSet {
            // Set by the app: no click of the user's reversed it.
            if !isSortingByClick { sortReversedByUser = nil }
            guard sortDescriptors != oldValue else { return }
            headerView.needsDisplay = true
            // Saved with the columns (not while being restored).
            if !isApplyingLayoutState {
                autosaveLayoutState()
            }
            if sortsRows { applyTableSort() }
            dataSource?.tableView(self, sortDescriptorsDidChange: oldValue)
        }
    }

    /// Whether the table orders the rows by `sortDescriptors` itself, and
    /// keeps them in order as values change: live sorting, e.g. for a
    /// trading screen. Off by default, like `NSTableView`, whose data source
    /// sorts.
    ///
    /// The table sorts by each row's `tableView(_:sortValueFor:row:)` (the
    /// cell value unless the data source says otherwise), compared like
    /// `NGCellValue.sortsBefore(_:)`; rows that compare equal keep the data
    /// source's order. The data source keeps its order: row indexes in the
    /// API stay data source indexes, as with `rowFilter`, and
    /// `tableView(_:sortDescriptorsDidChange:)` is only a notification.
    /// Targeted updates move only the rows whose sort values changed.
    public var sortsRows = false {
        didSet {
            guard sortsRows != oldValue else { return }
            applyTableSort()
        }
    }

    /// While the table sorts: every row's sort values, rows whose values
    /// are read again, all data source rows in order, and the filtered ones
    /// shown (display row → data source row, and back; -1: not shown).
    var sortKeys: NGSortKeys?
    var sortKeysToRead = IndexSet()
    /// Rows put in their place again even if their values didn't change
    /// (moved in the data source), and whether the whole order is.
    var sortRowsToPlace = IndexSet()
    var sortOrderNeedsRebuild = false

    /// Tables with at least this many rows read the sort values of a full
    /// sort (after a reload or a new sort) in slices and sort them off the
    /// main thread while the previous order shows; smaller ones sort at once.
    /// Rows count by what comparing them costs: rows of text count 16 each
    /// (their values are read at once, then sorted in the background), so a
    /// sort by text goes to the background from about 3,100 rows, by numbers
    /// from 50,000 (either holds the main thread at most about 25 ms on an
    /// M1 Max). Live updates move the changed rows at once, unless a table
    /// this large changes more of them in a batch than `synchronousPlacementLimit`.
    public var synchronousSortLimit = 50_000

    /// How much placing a batch's changed rows in a live sort may cost on the
    /// main thread, as rows × log₂(the table's rows) (20,000: about 1.5 ms).
    /// Past it, in tables of `synchronousSortLimit` rows or more, the changed
    /// rows keep their places (their values show at once) and are put where
    /// they go in the background, all of them together, a few times a second:
    /// a feed changing hundreds of thousands of sort values a second in a
    /// million rows doesn't hold the main thread placing them one by one.
    public var synchronousPlacementLimit = 20_000

    /// Whether changed rows wait to be placed in the sort (see `synchronousPlacementLimit`).
    var isSettlingSort: Bool { sortSettle.isInFlight || sortSettle.hasPending }
    /// Rows waiting to be placed, and the round placing them in the background.
    var sortSettle = NGSortSettle()

    /// Whether a full sort runs in the background (see `synchronousSortLimit`).
    public internal(set) var isSortingRows = false
    /// Collation keys for sorting text, which sort a million rows in a
    /// fraction of the time comparing them takes (see `NGCollationKeyProvider`):
    /// e.g. `NGBundledICUCollation()` from the optional NGTableICU library
    /// (it adds about 9 MB per architecture to the app). The
    /// order stays `localizedStandardCompare`'s: rows with equal keys are
    /// compared, and every pair of neighbors is checked. `nil` (the default:
    /// `NGTableView.defaultCollationKeyProvider`) compares text, on all cores.
    public var collationKeyProvider: (any NGCollationKeyProvider)? = NGTableView.defaultCollationKeyProvider
    /// The `collationKeyProvider` of tables made from now on.
    /// (On the main actor, like the tables: set it at launch.)
    public static var defaultCollationKeyProvider: (any NGCollationKeyProvider)?
    var sortTask: Task<Void, Never>?
    var sortGeneration = 0
    /// What the background sort sorts by, the values it reads and how the
    /// rows moved meanwhile (see `NGBackgroundSort`).
    var backgroundSort: NGBackgroundSort?
    /// All rows (handles) in sorted order, and with a filter the ones it
    /// shows: blocked sequences (`NGHandleSequence`), so a row that changed
    /// is taken out and put back by binary search, and a display row's row
    /// and a row's display row are lookups, without arrays of every row.
    var sortedOrder: NGHandleSequence? {
        didSet { rowGeometryCache = nil }
    }
    var filteredSortedOrder: NGHandleSequence? {
        didSet { rowGeometryCache = nil }
    }
    /// Rows (handles) whose filter match changed since the sort last looked
    /// (`nil`: unknown, after a full evaluation).
    var filterFlippedRows: IndexSet?

    /// Number of rows shown, after the row filter (also `numberOfDisplayedRows`).
    /// Unlike the other row indexes of the API, these are display rows; use
    /// `numberOfSourceRows` for the data source's count.
    public internal(set) var numberOfRows = 0 {
        didSet { rowGeometryCache = nil }
    }

    /// Number of rows shown, after the row filter.
    public var numberOfDisplayedRows: Int { numberOfRows }

    /// Selected rows as data source row indexes (also when a filter hides rows).
    public var selectedRowIndexes: IndexSet {
        // In a batch that moved rows the display rows follow at its end; the
        // batch keeps the selection in data source rows meanwhile.
        if rowUpdateBatch?.displayIsStale == true {
            syncBatchSelection()
            return rowUpdateBatch!.selection
        }
        return sourceRows(forDisplayRows: displaySelection)
    }

    /// Selected rows as displayed (after the row filter). In a batch whose
    /// display rows are current, the batch follows it. Built from the
    /// selection kept by handle when that is out of date (`keptSelection`).
    var displaySelection: IndexSet {
        get {
            if displaySelectionIsStale { buildDisplaySelection() }
            return storedDisplaySelection
        }
        set {
            // What it was, in rows, for the identities' diff (`rememberedSelection`).
            if displaySelectionIsStale, !selectionIsLarge { buildDisplaySelection() }
            keptSelection = nil
            displaySelectionIsStale = false
            storedDisplaySelection = newValue
            guard rowUpdateBatch?.displayIsStale == false else { return }
            rowUpdateBatch!.selectionByHandle = nil
            rowUpdateBatch!.selection = sourceRows(forDisplayRows: newValue)
            rowUpdateBatch!.selectionSetByCalls = true
        }
    }

    /// The display selection from the selection by handle (kept between
    /// batches, or a batch's while its display rows are current). In a batch
    /// that moved rows, the display rows are the old ones: it waits.
    private func buildDisplaySelection() {
        if rowUpdateBatch?.displayIsStale == true { return }
        let bits = keptSelection?.bits ?? rowUpdateBatch?.selectionByHandle
        keptSelection = nil
        displaySelectionIsStale = false
        let rows = bits.map { Self.rows(ofSelectedHandles: $0, in: rowHandles) } ?? []
        storedDisplaySelection = displayRows(forSourceRows: rows)
        // The identities are those of these rows already (kept by handle).
        if !selectionIsLarge { rememberedSelection = rows }
    }

    /// Keeps a large selection of a sorted table by handle (see
    /// `keptSelection`): its display rows are scattered among the data
    /// source rows, and every look at it in rows mapped them all through the
    /// order. Whether it does.
    func keepLargeSortedSelection() -> Bool {
        guard keptSelection == nil, !displaySelectionIsStale, groupedDisplay == nil, rowMap == nil,
              let sorted = sortedDisplay, sorted.count == numberOfSourceRows else { return false }
        let selection = storedDisplaySelection
        guard selection.count > Self.sortedSelectionKeptByHandle, canKeepSelectionByHandle(count: selection.count) else { return false }
        var bits = [Bool](repeating: false, count: rowHandles.capacity)
        bits.withUnsafeMutableBufferPointer { bits in
            sorted.forEachHandle(at: selection) { bits[Int($0)] = true }
        }
        keepSelection((bits, selection.count))
        return true
    }

    /// Selected rows past which a sorted table keeps them by handle.
    static let sortedSelectionKeptByHandle = 4_096

    /// Whether a display row is selected: by handle while the selection is
    /// kept so (drawing the rows in view doesn't build the display selection).
    func isDisplayRowSelected(_ row: Int) -> Bool {
        guard row >= 0, row < numberOfRows else { return false }
        if let kept = keptSelection {
            let source = sourceRow(row)
            guard source >= 0 else { return false }
            let handle = Int(rowHandles.handle(at: source))
            return handle < kept.bits.count && kept.bits[handle]
        }
        return displaySelection.contains(row)
    }

    /// Rows shown, e.g. for a search field. Row indexes in the API (selection,
    /// delegate and data source calls) stay data source indexes; summaries,
    /// selection, copying and VoiceOver only cover the rows shown. When the
    /// data changes, call `reloadData()` (it filters again), or a targeted
    /// update (it filters the changed rows again; the other rows keep their
    /// match); set the filter again when only the condition behind
    /// `isIncluded` changed. `isIncluded` is kept by the table: capture
    /// `self` weakly in it. The first search of a large table reads its words
    /// in the background (see `synchronousSearchLimit`).
    public var rowFilter: NGRowFilter? {
        didSet {
            // Typing on: a search whose words each extend one of the last
            // search's matches only rows that matched it, so only they are
            // checked again (the others keep not matching).
            if let old = oldValue, let new = rowFilter, old.isIncluded == nil, new.isIncluded == nil,
               old.columnIDs == new.columnIDs, !old.searchWords.isEmpty,
               old.searchWords.allSatisfy({ word in new.searchWords.contains { $0.hasPrefix(word) } }),
               !filterNeedsFullEvaluation, searchBuild == nil, rowMap != nil,
               let matches = filterMatches, matches.count == rowHandles.capacity {
                filterChecksLastMatches = true
            } else {
                filterChecksLastMatches = false
                filterNeedsFullEvaluation = true
            }
            applyRowFilter()
        }
    }

    /// Groups the rows by the values of some columns, under header rows with
    /// subtotals that the user collapses and expands (see `NGRowGrouping`).
    /// `nil` shows the rows as they come. Header rows are display rows
    /// (they count in `numberOfRows`) but not data source rows: they're never
    /// selected, and `row(at:)` gives -1 for them (see `group(at:)`).
    /// Setting another grouping keeps the selected rows that stay shown and
    /// forgets which groups were collapsed; setting the one it is changes
    /// nothing (its groups stay collapsed or expanded).
    public var rowGrouping: NGRowGrouping? {
        didSet {
            guard rowGrouping != oldValue else { return }
            // Groups and a tree don't mix: the grouping takes the tree's place.
            if rowGrouping != nil, rowTree != nil { rowTree = nil }
            groupsExpandedByDefault = !(rowGrouping?.startsCollapsed ?? false)
            toggledGroups = []
            if rowGrouping == nil { cancelGroupingJob() }
            previousGroupSubtotals = [:]
            updateDisplayedRows(rebuildingSummaries: false) { computeDisplayRows() }
            if allowsUserGrouping, !isApplyingLayoutState { autosaveLayoutState() }
        }
    }

    /// Shows the rows as a tree, like `NSOutlineView` (see `NGRowTree`): each
    /// row names its parent (`tableView(_:parentIdentifierForRow:)`), which
    /// needs row identities (`tableView(_:identifierForRow:)` or
    /// `rowIdentifierColumnID`). Setting it ends a `rowGrouping`.
    public var rowTree: NGRowTree? {
        didSet {
            guard rowTree != oldValue else { return }
            if rowTree != nil, rowGrouping != nil { rowGrouping = nil }
            if rowTree?.startsCollapsed != oldValue?.startsCollapsed {
                treeExpandedByDefault = !(rowTree?.startsCollapsed ?? false)
                toggledTreeRows = []
                restoreExpandedRows()
            }
            treeParentHandles = []
            updateDisplayedRows(rebuildingSummaries: false) { computeDisplayRows() }
            // Other rows counted: the summaries read their values again.
            if rowTree?.summaryRows != oldValue?.summaryRows { reloadSummary() }
        }
    }
    /// By handle: the parent's handle (-1: none), and the parent's identity.
    var treeParentHandles: [Int32] = []
    var treeParentIdentities: [AnyHashable?] = []
    /// Rows (handles) whose parents must be read: inserted or changed.
    var treeParentsToRead = IndexSet()
    /// Handles removed since the tree was laid out (children look their parents up again).
    var treeRemovedHandles = Set<Int32>()
    /// Rows were inserted since the tree was laid out.
    var rowsInsertedSinceTreeLayout = false
    /// Parents were read in a batch before the tree was laid out again.
    var treeParentsChangedSinceLayout = false
    /// Rows (handles) that got or lost a parent since the summaries read them
    /// (with `.topLevelRows` they count or stop counting).
    var treeSummaryFlips: [Int] = []
    /// Rows (handles) whose parent row changed since the last batch read
    /// them: with a filter, which of their descendants count may change.
    var treeReparentedHandles: [Int] = []
    /// The summary row's last sums of the selection (or the rest), by key,
    /// for the calculators of a version (see `selectionAccumulator`).
    var selectionAccumulators: [SummaryKey: (version: Int, scope: NGSummaryScope, selection: IndexSet, accumulator: NGAccumulator)] = [:]
    /// The summarized values were masked with a filter (see `maskTreeSummaryValues`).
    var treeSummaryMasksWereFiltered = false
    /// By handle: the depth of shown rows (-1: not shown); the shown
    /// children of each row are `treeChildren[treeChildStarts[h]..<treeChildStarts[h + 1]]`.
    var treeLevels: [Int32] = []
    var treeChildStarts: [Int] = []
    var treeChildren: [Int32] = []
    /// Rows (by identity) whose expansion isn't `treeExpandedByDefault`.
    var toggledTreeRows = Set<AnyHashable>()
    var treeExpandedByDefault = true

    /// Whether a tree's expanded rows are saved under ``autosaveName`` and
    /// brought back, like `NSOutlineView.autosaveExpandedItems`. Rows are
    /// saved by identity when it's a string or an integer (NSOutlineView's
    /// `persistentObjectForItem`), apart for trees that start expanded and
    /// collapsed (``NGRowTree/startsCollapsed``).
    public var autosaveExpandedItems = false {
        didSet {
            guard autosaveExpandedItems, !oldValue else { return }
            reloadSavedExpansion()
        }
    }

    /// Shows the saved expansion, if there is one.
    func reloadSavedExpansion() {
        guard restoreExpandedRows(), isShowingRowTree else { return }
        updateDisplayedRows(rebuildingSummaries: false) { buildTreeDisplay() }
    }

    /// Whether the header's context menu lets the user group the rows by a
    /// column (adding levels) and ungroup them; the grouping is then saved
    /// with `autosaveName` too.
    public var allowsUserGrouping = false

    /// Whether the headers of the groups scrolled into keep floating at the
    /// top of the rows, each level under the one above, like NSTableView's
    /// `floatsGroupRows`; the next group's header pushes them up.
    public var floatsGroupRows = true {
        didSet {
            guard floatsGroupRows != oldValue else { return }
            lastVisibleRange = nil
            needsLayout = true
        }
    }
    /// Per group node: its header's display row and the display row after
    /// its group (see `buildGroupedDisplay`).
    var groupHeaderDisplayRows: [Int] = []
    var groupDisplayEnds: [Int] = []
    /// Header rows placed for floating (they may be out of the visible rows).
    var floatingHeaderRows: Set<Int> = []

    /// The group keys of the data source rows, kept until the data changes.
    var groupKeys: NGGroupKeys?
    /// Rows whose group keys must be read (changed or inserted ones).
    var groupKeysToRead = IndexSet()
    var groupTree = NGGroupTree()
    /// Counts the times the group tree was built (see `NGRowUpdateBatch.removedLeaves`).
    var groupTreeGeneration = 0
    /// Display rows while rows are grouped: a data source row (>= 0) or a
    /// group header (-1 - its node index).
    var groupedDisplay: [Int]? {
        didSet { rowGeometryCache = nil }
    }
    /// The display row of each data source row while grouped (-1: hidden).
    var displayRowOfSource: [Int] = []
    /// Groups whose expansion isn't `groupsExpandedByDefault`.
    var toggledGroups = Set<NGRowGroup>()
    var groupsExpandedByDefault = true
    /// Subtotal texts by group, for `summaryValuesVersion`, and the last
    /// ones shown, kept while new values are computed in the background.
    var groupSubtotals: [NGRowGroup: [String: String]] = [:]
    var previousGroupSubtotals: [NGRowGroup: [String: String]] = [:]
    var groupSubtotalsVersion = 0
    /// Changes whenever the summarized values or calculators do.
    var summaryValuesVersion = 0
    /// Handles of rows whose values changed while a background computation
    /// read them: it reads them again before it builds the calculators. A
    /// list (duplicates dropped now and then), not an IndexSet: a feed's
    /// scattered handles made each union cost every range gathered so far.
    var summaryRowsChangedWhileComputing: [Int32] = []
    /// The column a background computation is reading, and the ones after it.
    var summaryBuild: NGSummaryBuild?
    /// Counts the times the rows moved, so a background computation knows
    /// whether its calculators are for the rows as they are.
    var summaryRowsMoved = 0

    /// The filtered rows: their data source rows while a filter is active
    /// (the order summaries count them in; grouping lays them out).
    var rowMap: [Int]? {
        didSet { rowGeometryCache = nil }
    }
    /// The handles of `rowMap` as a blocked sequence (index in `rowMap`
    /// of a handle, and back), kept in step by `computeRowMap`.
    var filteredRows: NGHandleSequence?
    /// Rows (handles) moved in the data source since `filteredRows` was
    /// last in step: their place among the filtered rows may change.
    var filteredRowsToPlace = IndexSet()
    /// Whether each data source row passes the filter, kept so targeted
    /// updates check only the changed rows (`filterRowsToCheck`).
    var filterMatches: [Bool]?
    /// Set by targeted updates before the display rows are computed: the
    /// rows whose values changed (or are new); the others keep their match.
    var filterRowsToCheck: IndexSet?
    /// Set by a search narrowing the last one: only the rows that matched it
    /// are checked again (read from `filterMatches`, not listed).
    var filterChecksLastMatches = false
    /// Rows were inserted, removed or moved since `rowMap` was in step.
    var rowMapNeedsRebuild = false
    /// Counts the times the filter evaluated every row (the totals can't
    /// follow a batch's changes across one).
    var filterEvaluations = 0
    /// The filter or its words changed: every row is evaluated next time
    /// (`filterMatches` still shows the previous result meanwhile).
    var filterNeedsFullEvaluation = false
    /// Filters on columns' values, by column id, like a spreadsheet's: a row
    /// shows when it passes all of them (and the `rowFilter`). The user sets
    /// them from the header when `allowsColumnFilters` is on; they are saved
    /// with `autosaveName`. Filters that let every row through are dropped.
    public var columnFilters: [String: NGColumnFilter] = [:] {
        didSet {
            // (Setting it here doesn't call didSet again.)
            let kept = columnFilters.filter { !$0.value.isEmpty }
            if kept != columnFilters { columnFilters = kept }
            guard columnFilters != oldValue else { return }
            filterNeedsFullEvaluation = true
            applyRowFilter()
            setNeedsChromeFrame(headerView)
            if !isApplyingLayoutState { autosaveLayoutState() }
        }
    }

    /// By column id, whether each row (by handle) passes that column's
    /// filter, for the filter that was checked: a search keystroke or a
    /// targeted update doesn't read and format every row's filtered values
    /// again. Rows whose filtered columns changed are checked again
    /// (`columnFilterRowsToCheck`); a reload or new columns drop them.
    var columnFilterPasses: [String: (filter: NGColumnFilter, passes: [Bool])] = [:]
    var columnFilterRowsToCheck = IndexSet()

    /// The sort descriptors right after a header click reversed the first
    /// one: the next click on it removes it (see `sortByClicking`).
    var sortReversedByUser: [NSSortDescriptor]?
    /// The regions the user moved items to from the header menu (saved with
    /// the layout instead of every item's pin).
    var userPins: [String: NGColumnPin] = [:]
    /// The pins of the top-level items as the app defined them.
    var definitionPins: [String: NGColumnPin] = [:]
    var isSortingByClick = false

    /// The column whose header is under the pointer (its filter button shows).
    var hoveredHeaderColumnID: String?
    /// The open column filter, if any.
    var columnFilterPopover: NSPopover?
    /// Handles of the rows hidden with `hideRows(at:withAnimation:)`.
    var hiddenRowHandles = Set<Int>()
    /// A search index being built in slices (see `synchronousSearchLimit`),
    /// and which of its rows were read; both by row handle, so rows
    /// inserted, removed or moved meanwhile move nothing.
    var searchBuild: (index: NGSearchIndex, read: [Bool])?
    var searchBuildTask: Task<Void, Never>?
    /// The texts read for a search index being built, split into words on
    /// all cores once every row is read: by handle, with the columns that
    /// gave them.
    var searchBuildTexts: [(handle: Int32, texts: [String], textColumns: UInt64)] = []
    /// Rows the data source has, filtered or not.
    public internal(set) var numberOfSourceRows = 0
    /// The table's numbers for the data source's rows (see `NGRowHandles`),
    /// and all of them in data source order until rows move.
    var rowHandles = NGRowHandles()
    var allRowHandlesCache: [Int]?

    /// Whether the header, the rows and the summary row show. Without any
    /// data (the data source has no rows) the table shows only its empty
    /// state. Rows hidden by the `rowFilter` leave the grid in place, so the
    /// columns stay in view while nothing matches.
    var showsGrid: Bool { numberOfSourceRows > 0 }

    /// Whether the summary bar shows: when asked for, and with a grid.
    var showsSummaryBar: Bool { showsSummaryRow && showsGrid }

    /// A column whose value identifies a row (e.g. a campaign id), so the
    /// selection follows the same records across `reloadData()`. The column
    /// doesn't need to be shown or even defined: its value is asked from the
    /// data source by id. `tableView(_:identifierForRow:)` takes precedence.
    ///
    /// Identities should be unique; rows sharing one are all selected again.
    public var rowIdentifierColumnID: String? {
        didSet {
            guard rowIdentifierColumnID != oldValue else { return }
            // Identities of the old column mean nothing for the new one.
            identifierColumn = nil
            identityIndex = nil
            selectedIdentifiers = [:]
            rememberedSelection = []
            rememberSelectionIdentity()
            anchorIdentifier = anchorRow.flatMap { identifier(forSourceRow: sourceRow($0)) }
            cursorIdentifier = cursorRow.flatMap { identifier(forSourceRow: sourceRow($0)) }
        }
    }

    /// Identities of the selected rows by row handle, kept up to date as the
    /// selection changes: by the time the data is replaced, the old rows can
    /// no longer be asked. By handle, inserts and removes leave them be.
    var selectedIdentifiers: [Int32: AnyHashable] = [:]
    /// The selected data source rows `selectedIdentifiers` was last updated for.
    var rememberedSelection = IndexSet()
    /// Selections larger than this keep their data source rows across
    /// `reloadData()` instead of their identities (asking 200,000 identities
    /// would cost more than selecting); all rows selected stay all selected.
    static let identitySelectionLimit = 10_000
    /// The selection is too large for identities (see `identitySelectionLimit`).
    var selectionIsLarge = false
    /// Every row is selected (and more than `identitySelectionLimit`).
    var selectionIsAllRows = false
    private var identifierColumn: NGTableColumn?
    /// Rows by identity, built by the first `row(forIdentifier:)`.
    var identityIndex: NGIdentityIndex?
    private var anchorIdentifier: AnyHashable?
    private var cursorIdentifier: AnyHashable?

    /// The data source row of a record by its identity
    /// (`tableView(_:identifierForRow:)` or `rowIdentifierColumnID`), or -1,
    /// like `NSOutlineView.row(forItem:)`. For a feed that addresses records
    /// by id: the first lookup reads every row's identity, then lookups take
    /// constant time while rows are inserted, removed and moved (only new
    /// rows are read). Identities should be unique and stay with their
    /// records; a record whose identity changes is removed and inserted.
    public func row(forIdentifier identifier: AnyHashable) -> Int {
        guard let handle = handle(forIdentifier: identifier) else { return -1 }
        return row(ofHandle: Int(handle))
    }

    /// The handle of a record by its identity (see `row(forIdentifier:)`).
    func handle(forIdentifier identifier: AnyHashable) -> Int32? {
        updateIdentityIndex()
        return identityIndex?.handle(of: identifier)
    }

    /// Builds the index of identities, or reads the rows inserted since.
    func updateIdentityIndex() {
        if identityIndex == nil {
            var index = NGIdentityIndex()
            index.reserve(numberOfSourceRows)
            if let dataSource {
                // Handles are the row indexes after a reload: no lookup per row.
                let isIdentity = rowHandles.isIdentity
                for row in 0..<numberOfSourceRows {
                    if let identity = identifier(forSourceRow: row, from: dataSource) {
                        index.set(identity, for: isIdentity ? Int32(row) : rowHandles.handle(at: row))
                    }
                }
            }
            identityIndex = index
        } else if identityIndex?.pending.isEmpty == false, let pending = identityIndex?.takePending() {
            guard let dataSource else { return }
            for handle in pending {
                let row = row(ofHandle: Int(handle))
                if row >= 0, row < numberOfSourceRows, let identity = identifier(forSourceRow: row, from: dataSource) {
                    identityIndex?.set(identity, for: handle)
                }
            }
        }
    }

    /// The identity of a data source row, if the app provides one.
    public func identifier(forRow row: Int) -> AnyHashable? {
        identifier(forSourceRow: row)
    }

    /// The identity of a data source row, if the app provides one.
    func identifier(forSourceRow row: Int) -> AnyHashable? {
        guard let dataSource, row >= 0, row < numberOfSourceRows else { return nil }
        return identifier(forSourceRow: row, from: dataSource)
    }

    /// The same for a row known to exist, from a data source taken once
    /// (loops over every row: it's held weakly).
    func identifier(forSourceRow row: Int, from dataSource: NGTableViewDataSource) -> AnyHashable? {
        if let identifier = dataSource.tableView(self, identifierForRow: row) {
            return identifier
        }
        guard let columnID = rowIdentifierColumnID else { return nil }
        // Asked for every row on reload: resolve the column once.
        if identifierColumn?.id != columnID {
            identifierColumn = columns.flatMap(\.leafColumns).first { $0.id == columnID } ?? NGTableColumn(columnID, title: columnID)
        }
        guard let column = identifierColumn else { return nil }
        let value = dataSource.tableView(self, valueFor: column, row: row)
        return value == .empty ? nil : AnyHashable(value)
    }

    /// Records the identities of newly selected rows and forgets deselected
    /// ones: the work follows the change, so growing a selection by dragging
    /// stays cheap. Rows without an identity are simply not remembered.
    func rememberSelectionIdentity(_ selection: IndexSet? = nil) {
        let rows = selection ?? selectedRowIndexes
        if rows.count > Self.identitySelectionLimit {
            selectedIdentifiers = [:]
            // Nothing to diff against while large (it starts over below the
            // limit): kept empty, not shifted by every update of a batch.
            rememberedSelection = []
            selectionIsLarge = true
            selectionIsAllRows = rows.count == numberOfSourceRows
            return
        }
        if selectionIsLarge {
            // Back under the limit: identities from scratch.
            selectionIsLarge = false
            selectionIsAllRows = false
            selectedIdentifiers = [:]
            rememberedSelection = []
        }
        for row in rememberedSelection.subtracting(rows) {
            selectedIdentifiers[rowHandles.handle(at: row)] = nil
        }
        for row in rows.subtracting(rememberedSelection) {
            if let identifier = identifier(forSourceRow: row) {
                selectedIdentifiers[rowHandles.handle(at: row)] = identifier
            }
        }
        rememberedSelection = rows
    }

    /// After a reload, selects the rows with the remembered identities.
    /// Returns `false` if nothing selected had an identity, or rows have none
    /// (the caller keeps the selected data source rows instead).
    private func restoreSelectionIdentity(_ identifiers: Set<AnyHashable>, anchor: AnyHashable?, cursor: AnyHashable?) -> Bool {
        guard !identifiers.isEmpty else { return false }
        // Every row is asked (rows sharing an identity are selected together,
        // so a record found where it was doesn't end the search): only the
        // anchor's and the cursor's first rows are kept, not every identity
        // (a dictionary of 200,000 of them cost more than asking).
        var anchorSource: Int?, cursorSource: Int?
        var hasIdentities = false
        var selectedSource = IndexSet()
        var restored: [Int32: AnyHashable] = [:]
        guard let dataSource else { return false }
        for row in 0..<numberOfSourceRows {
            guard let identifier = identifier(forSourceRow: row, from: dataSource) else { continue }
            hasIdentities = true
            if anchorSource == nil, identifier == anchor { anchorSource = row }
            if cursorSource == nil, identifier == cursor { cursorSource = row }
            if identifiers.contains(identifier) {
                selectedSource.insert(row)
                restored[rowHandles.handle(at: row)] = identifier
            }
        }
        guard hasIdentities else { return false }
        var shown = displayRows(forSourceRows: selectedSource)
        let cursorShown = cursorSource.flatMap(displayRow(forSourceRow:))
        if !allowsMultipleSelection, shown.count > 1, let first = shown.first {
            // Rows sharing the identity: one stays selected, like in
            // NSTableView (the cursor's if it is one of them).
            shown = [cursorShown.flatMap { shown.contains($0) ? $0 : nil } ?? first]
        }
        displaySelection = shown
        anchorRow = anchorSource.flatMap(displayRow(forSourceRow:))
        cursorRow = cursorShown
        // The identities were just read: no need to ask for them again.
        let selected = selectedRowIndexes
        selectedIdentifiers = restored.filter { selected.contains(row(ofHandle: Int($0.key))) }
        rememberedSelection = selected
        return true
    }

    // MARK: Rows and handles

    /// The handle of a data source row (see `NGRowHandles`): what the
    /// table's per-row data is stored by, and what its orders of rows list.
    func handle(ofRow row: Int) -> Int { Int(rowHandles.handle(at: row)) }

    /// The data source row of a handle, or -1 if its record is gone.
    func row(ofHandle handle: Int) -> Int { rowHandles.index(of: Int32(truncatingIfNeeded: handle)) }

    /// A reference to a row's record that outlives batches, not `reloadData()` (see `NGRowRef`).
    func rowRef(ofRow row: Int) -> NGRowRef { rowHandles.ref(at: row) }

    /// The data source row of a kept record, or -1 if it is gone.
    func row(of ref: NGRowRef) -> Int { rowHandles.index(of: ref) }

    /// Data source rows in the order shown (those not shown after them, in
    /// their order): what Copy and Export list.
    func inDisplayOrder(_ rows: IndexSet) -> [Int] {
        guard groupedDisplay != nil || sortedDisplay != nil || rowMap != nil else { return Array(rows) }
        let shown = displayRows(forSourceRows: rows)
        var ordered: [Int] = []
        ordered.reserveCapacity(rows.count)
        var isShown = IndexSet()
        for displayRow in shown {
            let row = sourceRow(displayRow)
            guard row >= 0 else { continue }
            ordered.append(row)
            isShown.insert(row)
        }
        if ordered.count < rows.count { ordered.append(contentsOf: rows.subtracting(isShown)) }
        return ordered
    }

    /// Every row's handle in data source order, kept until rows move.
    var allRowHandles: [Int] {
        if let allRowHandlesCache, allRowHandlesCache.count == numberOfSourceRows { return allRowHandlesCache }
        let handles = rowHandles.integerHandles
        allRowHandlesCache = handles
        allRowHandlesBuilds += 1
        return handles
    }
    /// How many times `allRowHandles` copied every handle (for tests).
    var allRowHandlesBuilds = 0

    /// The sorted rows the table shows: those the filter shows, or all of
    /// them (`nil`: the table doesn't sort).
    var sortedDisplay: NGHandleSequence? {
        rowMap != nil ? filteredSortedOrder : sortedOrder
    }

    /// The rows shown in sorted order as an array (one pass over the blocks),
    /// for the grouping, which groups them in that order.
    var displayOrder: [Int]? { sortedDisplay?.integerElements }

    /// All rows (handles) in sorted order as an array.
    var sortedRows: [Int]? { sortedOrder?.integerElements }

    /// The rows the summaries count, as handles in data source order: the
    /// filtered ones, or all of them. Selections in the summaries' row space
    /// are positions in it.
    var summaryRows: [Int] { rowMap ?? allRowHandles }

    /// The data source row shown at a display row; -1 for a group header
    /// (or, in the middle of a batch, a record gone).
    func sourceRow(_ displayRow: Int) -> Int {
        if let groupedDisplay {
            guard displayRow >= 0, displayRow < groupedDisplay.count else { return displayRow }
            let entry = groupedDisplay[displayRow]
            return entry < 0 ? -1 : row(ofHandle: entry)
        }
        if let sorted = sortedDisplay {
            return displayRow >= 0 && displayRow < sorted.count ? row(ofHandle: Int(sorted.handle(at: displayRow))) : displayRow
        }
        guard let rowMap else { return displayRow }
        return displayRow >= 0 && displayRow < rowMap.count ? row(ofHandle: rowMap[displayRow]) : displayRow
    }

    /// Where a data source row is shown: its index among the rows the table
    /// shows now (sorted by the table, filtered, grouped, group header rows
    /// counted), or `nil` if it isn't shown (filtered out, in a collapsed
    /// group). Without a sort, filter or groups it is the row itself.
    public func displayIndex(ofRow row: Int) -> Int? {
        displayRow(forSourceRow: row)
    }

    /// The data source row shown at an index of the rows shown (see
    /// `displayIndex(ofRow:)`), or `nil` for a group header row or an index
    /// out of range.
    public func row(atDisplayIndex index: Int) -> Int? {
        guard index >= 0, index < numberOfRows else { return nil }
        return sourceRowIfAny(index)
    }

    /// The selected data source rows in the order shown, e.g. the topmost
    /// selected record of a table that sorts its rows (`selectedRowIndexes`
    /// is in data source order).
    public var selectedRowIndexesInDisplayOrder: [Int] {
        inDisplayOrder(selectedRowIndexes)
    }

    /// The data source row shown at a display row, `nil` for a group header.
    func sourceRowIfAny(_ displayRow: Int) -> Int? {
        let row = sourceRow(displayRow)
        return row >= 0 ? row : nil
    }

    /// Where a data source row is shown, or `nil` if it is filtered out (or
    /// in a collapsed group).
    func displayRow(forSourceRow row: Int) -> Int? {
        let sorted = groupedDisplay == nil ? sortedDisplay : nil
        guard groupedDisplay != nil || sorted != nil || rowMap != nil else {
            return row >= 0 && row < numberOfRows ? row : nil
        }
        guard row >= 0, row < numberOfSourceRows else { return nil }
        let handle = handle(ofRow: row)
        if let sorted {
            let position = sorted.index(of: Int32(truncatingIfNeeded: handle))
            return position >= 0 ? position : nil
        }
        if groupedDisplay == nil {
            let position = filteredRows?.index(of: Int32(truncatingIfNeeded: handle)) ?? -1
            return position >= 0 ? position : nil
        }
        let positions = displayRowOfSource
        guard handle < positions.count, positions[handle] >= 0 else { return nil }
        return positions[handle]
    }

    // Loops over every row with a closure are nonisolated: a main-actor
    // closure is checked for its executor on every call (half of a search
    // keystroke over a million rows).

    /// The handles whose match is true, in their order.
    nonisolated static func matching(_ handles: [Int], _ matches: [Bool]) -> [Int] {
        handles.filter { $0 < matches.count && matches[$0] }
    }

    /// The matches by row of handles in row order.
    nonisolated static func matchesByRow(_ handles: [Int], _ matches: [Bool]) -> [Bool] {
        handles.map { $0 < matches.count && matches[$0] }
    }

    /// The rows of handles (those that have one), in their order.
    nonisolated static func rows(of handles: [Int], handles rowHandles: NGRowHandles) -> [Int] {
        handles.compactMap { handle in
            let row = rowHandles.index(of: Int32(truncatingIfNeeded: handle))
            return row >= 0 ? row : nil
        }
    }

    /// The positions of `rows` in a table of positions (-1: none). Nonisolated,
    /// so a closure doesn't check the executor per row.
    /// Many rows (all selected, say) are marked in a bitmap and gathered by
    /// runs: inserting scattered positions one by one costs far more.
    /// - Parameter limit: Positions are below it.
    nonisolated static func positions(of rows: IndexSet, in positions: [Int], limit: Int) -> IndexSet {
        var result = IndexSet()
        guard rows.count > 256 else {
            for row in rows where row >= 0 && row < positions.count && positions[row] >= 0 && positions[row] < limit {
                result.insert(positions[row])
            }
            return result
        }
        var marked = [Bool](repeating: false, count: max(0, limit))
        marked.withUnsafeMutableBufferPointer { marked in
            positions.withUnsafeBufferPointer { positions in
                for range in rows.rangeView {
                    for row in range where row >= 0 && row < positions.count {
                        let position = positions[row]
                        if position >= 0, position < marked.count { marked[position] = true }
                    }
                }
            }
        }
        return runs(of: marked)
    }

    /// The same for keys in an array (handles, in no particular order).
    nonisolated static func positions(ofKeys keys: [Int32], in positions: [Int], limit: Int) -> IndexSet {
        guard keys.count > 256 else {
            var result = IndexSet()
            for key in keys where key >= 0 && Int(key) < positions.count {
                let position = positions[Int(key)]
                if position >= 0, position < limit { result.insert(position) }
            }
            return result
        }
        var marked = [Bool](repeating: false, count: max(0, limit))
        marked.withUnsafeMutableBufferPointer { marked in
            positions.withUnsafeBufferPointer { positions in
                keys.withUnsafeBufferPointer { keys in
                    for key in keys where key >= 0 && Int(key) < positions.count {
                        let position = positions[Int(key)]
                        if position >= 0, position < marked.count { marked[position] = true }
                    }
                }
            }
        }
        return runs(of: marked)
    }

    /// The positions of handles in a sequence, as an index set (many are
    /// marked in a bitmap and gathered by runs).
    nonisolated static func positions(ofKeys keys: [Int32], in sequence: NGHandleSequence) -> IndexSet {
        guard keys.count > 256 else {
            var result = IndexSet()
            for key in keys {
                let position = sequence.index(of: key)
                if position >= 0 { result.insert(position) }
            }
            return result
        }
        var marked = [Bool](repeating: false, count: sequence.count)
        marked.withUnsafeMutableBufferPointer { marked in
            for key in keys {
                let position = sequence.index(of: key)
                if position >= 0 { marked[position] = true }
            }
        }
        return runs(of: marked)
    }

    /// The data source rows of the handles at some positions of a sequence.
    nonisolated static func rows(at positions: IndexSet, in sequence: NGHandleSequence, handles: NGRowHandles) -> IndexSet {
        let keys = sequence.handles(at: positions)
        guard keys.count > 256 else {
            var result = IndexSet()
            for key in keys {
                let row = handles.index(of: key)
                if row >= 0 { result.insert(row) }
            }
            return result
        }
        var marked = [Bool](repeating: false, count: handles.count)
        marked.withUnsafeMutableBufferPointer { marked in
            for key in keys {
                let row = handles.index(of: key)
                if row >= 0 { marked[row] = true }
            }
        }
        return runs(of: marked)
    }

    /// The data source rows of the handles at some positions of an order
    /// (negative entries, group headers, have none).
    nonisolated static func rows(at positions: IndexSet, in order: [Int], handles: NGRowHandles) -> IndexSet {
        guard positions.count > 256 else {
            var result = IndexSet()
            for position in positions where position >= 0 && position < order.count && order[position] >= 0 {
                let row = handles.index(of: Int32(truncatingIfNeeded: order[position]))
                if row >= 0 { result.insert(row) }
            }
            return result
        }
        var marked = [Bool](repeating: false, count: handles.count)
        marked.withUnsafeMutableBufferPointer { marked in
            order.withUnsafeBufferPointer { order in
                for range in positions.rangeView {
                    for position in range where position >= 0 && position < order.count && order[position] >= 0 {
                        let row = handles.index(of: Int32(truncatingIfNeeded: order[position]))
                        if row >= 0 { marked[row] = true }
                    }
                }
            }
        }
        return runs(of: marked)
    }

    /// The marked positions as ranges.
    nonisolated static func runs(of marked: [Bool]) -> IndexSet {
        var result = IndexSet()
        var start = -1
        marked.withUnsafeBufferPointer { marked in
            for position in marked.indices {
                if marked[position] {
                    if start < 0 { start = position }
                } else if start >= 0 {
                    result.insert(integersIn: start..<position)
                    start = -1
                }
            }
        }
        if start >= 0 { result.insert(integersIn: start..<marked.count) }
        return result
    }

    func displayRows(forSourceRows rows: IndexSet) -> IndexSet {
        let sorted = groupedDisplay == nil ? sortedDisplay : nil
        guard groupedDisplay != nil || sorted != nil || rowMap != nil else {
            // (An intersection walks a set of many ranges index by index.)
            return Self.clamped(rows, to: numberOfRows)
        }
        if let sorted {
            // Every row (all selected): every display row, without mapping each.
            if rowMap == nil, sorted.count == numberOfSourceRows, Self.isEveryRow(rows, count: numberOfSourceRows) { return rows }
            return Self.positions(ofKeys: rowHandles.handles(of: rows), in: sorted)
        }
        if groupedDisplay == nil { return filteredRows.map { Self.positions(ofKeys: rowHandles.handles(of: rows), in: $0) } ?? [] }
        return Self.positions(ofKeys: rowHandles.handles(of: rows), in: displayRowOfSource, limit: numberOfRows)
    }

    /// The data source rows of display rows (group headers have none).
    func sourceRows(forDisplayRows rows: IndexSet) -> IndexSet {
        if groupedDisplay == nil, let sorted = sortedDisplay {
            // A sorted order of every row: all its rows are all the rows.
            if rowMap == nil, sorted.count == numberOfSourceRows, Self.isEveryRow(rows, count: sorted.count) { return rows }
            return Self.rows(at: rows, in: sorted, handles: rowHandles)
        }
        guard let order = groupedDisplay ?? rowMap else { return rows }
        return Self.rows(at: rows, in: order, handles: rowHandles)
    }

    /// Whether rows are `0..<count` (one range: no walk over them).
    nonisolated static func isEveryRow(_ rows: IndexSet, count: Int) -> Bool {
        count > 0 && rows.first == 0 && rows.last == count - 1 && rows.rangeView.count == 1
    }

    /// The selection in the summaries' row space: positions in
    /// `summaryRows` (the filtered rows, or all, in data source order),
    /// whatever the grouping or the sort shows.
    var summarySelection: IndexSet {
        guard groupedDisplay != nil || sortedDisplay != nil else { return displaySelection }
        let rows = selectedRowIndexes
        guard rowMap != nil else { return rows }
        return filteredRows.map { Self.positions(ofKeys: rowHandles.handles(of: rows), in: $0) } ?? []
    }

    /// The searchable words of every data source row, built on the first search
    /// and kept until the data or columns change, so typing in a search field
    /// only compares prefixes. Without explicit columns only text is searched:
    /// `textColumns` has a bit per searched column (up to 64) whose value in
    /// the row gave words, so a targeted update of number columns skips rows
    /// whose changed columns neither gave nor give words.
    var searchIndex: NGSearchIndex?

    /// The search index for a filter, or `nil` while it is being built in
    /// the background (large tables).
    func searchIndex(for filter: NGRowFilter, dataSource: NGTableViewDataSource) -> NGSearchIndex? {
        // Listed columns are searched even when hidden; otherwise what is
        // shown, but not columns with a number format: only their text
        // would give words, and reading every row's 30 metrics to find none
        // was most of building the index.
        let searched = filter.columnIDs.map { ids in columns.flatMap(\.leafColumns).filter { ids.contains($0.id) } }
            ?? columnLayout.allColumns.filter { !$0.format.isNumeric }
        let ids = Set(searched.map(\.id))
        let explicit = filter.columnIDs != nil
        if let searchIndex, searchIndex.columnIDs == ids, searchIndex.explicit == explicit {
            return searchIndex
        }
        let tracksColumns = !explicit && searched.count <= 64
        // Reading the words costs a read of every searched column of every row.
        if numberOfSourceRows.multipliedReportingOverflow(by: max(1, searched.count)).partialValue >= synchronousSearchLimit {
            if let build = searchBuild, build.index.columnIDs == ids, build.index.explicit == explicit { return nil }
            startSearchBuild(NGSearchIndex(columnIDs: ids, explicit: explicit, columns: searched,
                                           rowCount: rowHandles.capacity, tracksTextColumns: tracksColumns))
            return nil
        }
        cancelSearchBuild()
        // By handle; rows read in data source order.
        var words = [[String]](repeating: [], count: rowHandles.capacity)
        var textColumns = [UInt64](repeating: 0, count: tracksColumns ? rowHandles.capacity : 0)
        for (row, handle) in allRowHandles.enumerated() {
            let entry = searchEntry(ofRow: row, in: searched, explicit: explicit, dataSource: dataSource)
            words[handle] = entry.words
            if tracksColumns { textColumns[handle] = entry.textColumns }
        }
        let index = NGSearchIndex(columnIDs: ids, explicit: explicit, columns: searched, words: words, textColumns: textColumns)
        searchIndex = index
        // Rows matched other words.
        filterNeedsFullEvaluation = true
        return index
    }

    /// Reads the words of every row in slices of a few milliseconds, giving
    /// the run loop a turn in between; the filter applies when all are read.
    /// Words are kept by handle, so inserts and removes meanwhile only add
    /// rows to read, and rows changed meanwhile are read again: a live feed
    /// doesn't keep it from finishing.
    private func startSearchBuild(_ index: NGSearchIndex) {
        cancelSearchBuild()
        searchBuild = (index, [Bool](repeating: false, count: index.rowCount))
        // (Grown row by row it was copied again and again.)
        searchBuildTexts.reserveCapacity(index.rowCount)
        isSearchingRows = true
        searchBuildTask = Task { [weak self] in
            var next = 0
            // The first pass's texts are split on all cores; rows read again
            // after it (a feed changed them) are split at once, so a feed that
            // never pauses doesn't keep it from finishing.
            var isFirstPass = true
            // Every row read once: the filter applies in a turn of its own.
            var waitedForATurn = false
            while true {
                // Every row read: their texts are split into words off the
                // main thread, on all cores (most of the work), then indexed.
                if isFirstPass, let table = self, table.searchBuild?.read.firstIndex(of: false) == nil, !table.searchBuildTexts.isEmpty {
                    isFirstPass = false
                    let texts = table.searchBuildTexts
                    table.searchBuildTexts = []
                    let words = await Task.detached(priority: .userInitiated) { NGRowFilter.words(of: texts) }.value
                    // Into the index in slices too (a million rows' words
                    // held the main thread ~60 ms).
                    var position = 0
                    while position < texts.count {
                        guard !Task.isCancelled, let table = self, var build = table.searchBuild.take() else { return }
                        let deadline = NGBackgroundSlices.deadline()
                        while position < texts.count {
                            let entry = texts[position]
                            let handle = Int(entry.handle)
                            // Rows marked unread meanwhile are read again.
                            if handle < build.read.count, build.read[handle], table.row(ofHandle: handle) >= 0 {
                                build.index.set(words[position], textColumns: entry.textColumns, row: handle)
                            }
                            position += 1
                            if position.isMultiple(of: 1_024), ContinuousClock.now >= deadline { break }
                        }
                        table.searchBuild = build
                        if position < texts.count { await NGBackgroundSlices.nextSlice() }
                    }
                    // A million rows' texts freed on another thread (~35 ms here).
                    NGTableView.releaseInBackground(consume texts)
                    NGTableView.releaseInBackground(consume words)
                }
                await NGBackgroundSlices.nextSlice()
                guard !Task.isCancelled, let table = self, let dataSource = table.dataSource else { return }
                guard var build = table.searchBuild.take() else { return }
                guard table.rowUpdateBatch != nil || table.numberOfSourceRows == dataSource.numberOfRows(in: table) else {
                    // The data changed without telling the table: the reload starts over.
                    table.cancelSearchBuild()
                    return
                }
                let deadline = NGBackgroundSlices.deadline()
                // By handle; rows changed or inserted since were marked unread.
                next = build.read.firstIndex(of: false) ?? build.read.count
                while next < build.read.count, ContinuousClock.now < deadline {
                    let end = min(build.read.count, next + 256)
                    for handle in next..<end where !build.read[handle] {
                        let row = table.row(ofHandle: handle)
                        if row >= 0, isFirstPass {
                            let entry = table.searchTexts(ofRow: row, in: build.index.columns, explicit: build.index.explicit,
                                                          dataSource: dataSource)
                            table.searchBuildTexts.append((Int32(handle), entry.texts, entry.textColumns))
                        } else if row >= 0 {
                            let entry = table.searchEntry(ofRow: row, in: build.index.columns, explicit: build.index.explicit,
                                                          dataSource: dataSource)
                            build.index.set(entry.words, textColumns: entry.textColumns, row: handle)
                        }
                        build.read[handle] = true
                    }
                    next = end
                }
                guard next >= build.read.count, build.read.firstIndex(of: false) == nil, table.searchBuildTexts.isEmpty else {
                    table.searchBuild = build
                    continue
                }
                if !waitedForATurn {
                    waitedForATurn = true
                    table.searchBuild = build
                    await NGBackgroundSlices.turnOfItsOwn()
                    continue
                }
                table.searchIndex = build.index
                table.searchBuildTask = nil
                table.isSearchingRows = false
                table.filterNeedsFullEvaluation = true
                table.applyRowFilter()
                return
            }
        }
    }

    func cancelSearchBuild() {
        searchBuildTask?.cancel()
        searchBuildTask = nil
        searchBuild = nil
        searchBuildTexts = []
        isSearchingRows = false
    }

    /// The searchable words of one data source row, and the columns (bits by
    /// position in `columns`) whose values gave them.
    func searchEntry(ofRow row: Int, in columns: [NGTableColumn], explicit: Bool,
                     dataSource: NGTableViewDataSource) -> (words: [String], textColumns: UInt64) {
        let entry = searchTexts(ofRow: row, in: columns, explicit: explicit, dataSource: dataSource)
        return (entry.texts.flatMap(NGRowFilter.words(in:)), entry.textColumns)
    }

    /// The searchable texts of one data source row (before they are split
    /// into words), and the columns (bits by position in `columns`) that gave them.
    func searchTexts(ofRow row: Int, in columns: [NGTableColumn], explicit: Bool,
                     dataSource: NGTableViewDataSource) -> (texts: [String], textColumns: UInt64) {
        var texts: [String] = []
        var textColumns: UInt64 = 0
        // By index: the columns are passed without copying them.
        for position in columns.indices {
            let value = dataSource.tableView(self, valueFor: columns[position], row: row)
            // Without explicit columns only text is searched: formatting every
            // number would be slow and matching them is rarely wanted.
            guard explicit || value.givesSearchWords else { continue }
            texts.append(NGFormatIDs.string(for: value, format: columns[position].format, locale: locale))
            if position < 64 { textColumns |= 1 << UInt64(position) }
        }
        return (texts, textColumns)
    }

    /// Evaluates the filter over all data source rows, or after targeted
    /// updates over the changed rows only (`filterRowsToCheck`, handles):
    /// the others keep their match, so a live feed doesn't search 200,000
    /// rows a tick. Matches are kept by handle; `filteredRows` holds the
    /// matching rows in data source order (an `NGHandleSequence`: rows whose
    /// match changed, that moved or that went are taken out and put back,
    /// without a pass over every row), and `rowMap` lists them.
    func computeRowMap() {
        let rowsToCheck = filterRowsToCheck.take()
        let checksLastMatches = filterChecksLastMatches
        filterChecksLastMatches = false
        let hidesRows = !hiddenRowHandles.isEmpty
        let filter = rowFilter ?? NGRowFilter()
        let byColumn = resolvedColumnFilters
        guard !filter.isEmpty || hidesRows || !byColumn.isEmpty, let dataSource else {
            if rowMap != nil { filterEvaluations += 1 }
            // Without column filters nothing keeps their passes up to date:
            // a filter set again checks every row.
            columnFilterPasses = [:]
            columnFilterRowsToCheck = []
            rowMap = nil
            filteredRows = nil
            filterMatches = nil
            filterFlippedRows = nil
            filteredRowsToPlace = []
            rowMapNeedsRebuild = false
            return
        }
        let words = filter.searchWords
        if words.isEmpty { cancelSearchBuild() }
        let index = words.isEmpty ? nil : searchIndex(for: filter, dataSource: dataSource)
        let capacity = rowHandles.capacity
        if !words.isEmpty, index == nil {
            // Reading the words: the rows shown so far stay (their matches are
            // kept by handle); without a previous filter, all of them.
            if let kept = filterMatches, kept.count == capacity {
                if rowMapNeedsRebuild || rowMap == nil { updateFilteredRows(placing: []) }
            } else {
                rowMap = nil
                filteredRows = nil
                filterFlippedRows = nil
            }
            return
        }
        let columnPasses = updateColumnFilterPasses(byColumn, dataSource: dataSource).map(\.passes)
        func matches(_ handle: Int) -> Bool {
            if hidesRows, hiddenRowHandles.contains(handle) { return false }
            for passes in columnPasses where handle >= passes.count || !passes[handle] { return false }
            if let index, !NGRowFilter.matches(searchWords: words, rowWords: index.words(ofRow: handle)) { return false }
            if let isIncluded = filter.isIncluded {
                let row = row(ofHandle: handle)
                guard row >= 0, isIncluded(row) else { return false }
            }
            return true
        }
        if rowsToCheck != nil || checksLastMatches, !filterNeedsFullEvaluation, rowMap != nil,
           var kept = filterMatches.take(), kept.count == capacity {
            // Into an array, the last matches straight from their flags: a
            // keystroke checks every one, and listing them or growing an
            // index set one by one cost as much as checking them.
            var flipped: [Int] = []
            func check(_ handle: Int) {
                let match = rowHandles.contains(Int32(handle)) && matches(handle)
                if match != kept[handle] {
                    kept[handle] = match
                    flipped.append(handle)
                }
            }
            if checksLastMatches {
                let lastMatches = kept
                for handle in 0..<capacity where lastMatches[handle] { check(handle) }
            }
            // A row checked twice flips once: the second check finds its flag set.
            for range in rowsToCheck?.rangeView ?? IndexSet().rangeView {
                for handle in range where handle < capacity { check(handle) }
            }
            if checksLastMatches, rowsToCheck != nil { flipped.sort() }
            filterMatches = kept
            guard !flipped.isEmpty || rowMapNeedsRebuild else { return }
            if Self.placesFewer(flipped.count, than: capacity) {
                let placing = IndexSet(flipped)
                filterFlippedRows?.formUnion(placing)
                updateFilteredRows(placing: placing)
            } else {
                // Most matches changed (a keystroke that narrows the search):
                // the rows are built again in one pass, like the sorted ones.
                filterFlippedRows = nil
                filteredRows = nil
                updateFilteredRows(placing: [])
            }
            return
        }
        var all = [Bool](repeating: false, count: capacity)
        if filter.isIncluded == nil, numberOfSourceRows >= Self.parallelFilterRows {
            // Every row against the words and column filters, on all cores
            // (a million rows held the main thread ~50 ms); the app's own
            // condition, if any, is asked on the main actor as before.
            all = Self.matchesOnAllCores(allRowHandles, capacity: capacity, hidden: hidesRows ? hiddenRowHandles : [],
                                         columnPasses: columnPasses, index: index, words: words)
        } else {
            for handle in allRowHandles { all[handle] = matches(handle) }
        }
        filterMatches = all
        filterFlippedRows = nil
        filterEvaluations += 1
        filterNeedsFullEvaluation = false
        filteredRows = nil
        updateFilteredRows(placing: [])
    }

    /// Lets go of a large value (a million rows' words or keys) on another
    /// thread: its last release frees millions of objects, ~6 ms of a reload.
    nonisolated static func releaseInBackground<Value>(_ value: Value?) {
        guard let value else { return }
        let box = NGUncheckedSendable(value)
        DispatchQueue.global(qos: .utility).async { withExtendedLifetime(box) {} }
    }

    /// The rows of an order below a count (a closure made here would check
    /// the main actor on every row: a million rows' reload paid ~8 ms).
    nonisolated static func rows(_ order: [Int], below count: Int) -> [Int] {
        order.filter { $0 < count }
    }

    /// From this many rows, a filter without the app's condition checks every
    /// row on all cores.
    static let parallelFilterRows = 50_000

    /// Whether each row (handle) passes the hidden rows, the column filters
    /// and the search words, checked on all cores.
    nonisolated static func matchesOnAllCores(_ handles: [Int], capacity: Int, hidden: Set<Int>, columnPasses: [[Bool]],
                                             index: NGSearchIndex?, words: [String]) -> [Bool] {
        var all = [Bool](repeating: false, count: capacity)
        let input = NGUncheckedSendable((handles, hidden, columnPasses, index, words))
        all.withUnsafeMutableBufferPointer { buffer in
            let output = NGUncheckedSendable(buffer)
            let chunks = max(1, min(handles.count / 4_096, ProcessInfo.processInfo.activeProcessorCount * 4))
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let (handles, hidden, columnPasses, index, words) = input.value
                let start = handles.count * chunk / chunks, end = handles.count * (chunk + 1) / chunks
                for handle in handles[start..<end] {
                    var match = !hidden.contains(handle)
                    if match {
                        for passes in columnPasses where handle >= passes.count || !passes[handle] { match = false; break }
                    }
                    if match, let index, !NGRowFilter.matches(searchWords: words, rowWords: index.words(ofRow: handle)) { match = false }
                    output.value[handle] = match
                }
            }
        }
        return all
    }

    /// The filtered rows in step with rows an open batch inserted, removed or
    /// moved, for summaries computed before the display rows are (a column
    /// shown during a batch).
    func updateRowMapAfterMoves() {
        guard rowMapNeedsRebuild, rowMap != nil, let matches = filterMatches, matches.count == rowHandles.capacity else { return }
        updateFilteredRows(placing: [])
    }

    /// `filteredRows` and `rowMap` after rows changed their match
    /// (`placing`), moved in the data source (`filteredRowsToPlace`) or went
    /// (the handles removed since the last release): only those are taken
    /// out and put back where their index goes. Built from `filterMatches`
    /// when there is none yet.
    private func updateFilteredRows(placing: IndexSet) {
        rowMapNeedsRebuild = false
        let matches = filterMatches ?? []
        let toPlace = filteredRowsToPlace
        filteredRowsToPlace = []
        guard var rows = filteredRows.take() else {
            let all = Self.matching(allRowHandles, matches)
            let sequence = NGHandleSequence.changingOrder(all, capacity: rowHandles.capacity)
            filteredRows = sequence
            rowMap = all
            return
        }
        rows.reserve(capacity: rowHandles.capacity)
        var candidates = placing.union(toPlace)
        for handle in rowHandles.removedHandles { candidates.insert(Int(handle)) }
        let changed = Self.place(candidates, inSourceOrder: &rows, matches: matches, handles: rowHandles)
        filteredRows = rows
        if changed || rowMap == nil { rowMap = rows.integerElements }
    }

    /// The filtered rows (data source order) with `candidates` taken out and
    /// those that match (and are rows) put back where their index goes, by
    /// binary search over the blocks. Returns whether the rows changed.
    private nonisolated static func place(_ candidates: IndexSet, inSourceOrder rows: inout NGHandleSequence, matches: [Bool],
                                          handles: NGRowHandles) -> Bool {
        var placing: [(handle: Int32, was: Int)] = []
        var changed = false
        // Where they were, before any of them is taken out.
        for handle in candidates {
            let key = Int32(truncatingIfNeeded: handle)
            let was = rows.index(of: key)
            if handle < matches.count, matches[handle], handles.contains(key) {
                placing.append((key, was))
                if was < 0 { changed = true }
            } else if was >= 0 {
                changed = true
            }
        }
        for handle in candidates { rows.remove(Int32(truncatingIfNeeded: handle)) }
        for (handle, _) in placing {
            let index = handles.index(of: handle)
            rows.insert(handle, at: rows.partitioningIndex { handles.index(of: $0) > index })
        }
        if !changed {
            for (handle, was) in placing where rows.index(of: handle) != was {
                changed = true
                break
            }
        }
        return changed
    }

    /// Whether `count` rows are put in their places one by one rather than
    /// building the order of `capacity` rows again in one pass: each place
    /// costs a lookup and a block's shift, a pass a few nanoseconds per row.
    nonisolated static func placesFewer(_ count: Int, than capacity: Int) -> Bool {
        count <= max(4_096, capacity / 64)
    }

    /// Re-filters the same data, keeping the selected rows that stay visible.
    func applyRowFilter() {
        updateDisplayedRows(rebuildingSummaries: true) { computeDisplayRows() }
    }

    /// Shows other rows of the same data (filtered, grouped, collapsed),
    /// keeping the selected rows that stay shown.
    /// - Parameters:
    ///   - rebuildingSummaries: Whether the summaries cover other rows now
    ///     (the filter changed), from the values already read.
    ///   - keepingCells: The records show what they showed (rows only move):
    ///     their cells in view move with them instead of being read and
    ///     laid out again (a settling sort's rounds).
    ///   - change: Lays out the new display rows.
    func updateDisplayedRows(rebuildingSummaries: Bool, keepingCells: Bool = false, _ change: () -> Void) {
        // Rows only move: a selection kept by handle stays as it is, the
        // same records (mapping a large one through the order both ways was
        // most of a settling sort's round).
        if keepingCells, !rebuildingSummaries, keptSelection != nil || keepLargeSortedSelection() {
            let anchorSource = anchorRow.flatMap(sourceRowIfAny)
            let cursorSource = cursorRow.flatMap(sourceRowIfAny)
            finishRowAnimation()
            var sourcesInView: [Int: Int] = [:]
            for row in Set(visibleCells.keys.map(\.row)) {
                if let source = sourceRowIfAny(row) { sourcesInView[row] = source }
            }
            change()
            anchorRow = anchorSource.flatMap { displayRow(forSourceRow: $0) }
            cursorRow = cursorSource.flatMap { displayRow(forSourceRow: $0) }
            dragSelectionBase = []
            clickedRow = -1
            accessibilityRowCache.removeAll()
            NSAccessibility.post(element: self, notification: .rowCountChanged)
            moveVisibleCells { [self] oldRow in sourcesInView[oldRow].flatMap { displayRow(forSourceRow: $0) } }
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }
        let selectedSourceRows = selectedRowIndexes
        let anchorSource = anchorRow.flatMap(sourceRowIfAny)
        let cursorSource = cursorRow.flatMap(sourceRowIfAny)
        // Other display rows: a running row animation's would be wrong.
        finishRowAnimation()
        var sourcesInView: [Int: Int] = [:]
        if keepingCells {
            for row in Set(visibleCells.keys.map(\.row)) {
                if let source = sourceRowIfAny(row) { sourcesInView[row] = source }
            }
        }
        change()
        displaySelection = displayRows(forSourceRows: selectedSourceRows)
        anchorRow = anchorSource.flatMap { displayRow(forSourceRow: $0) }
        cursorRow = cursorSource.flatMap { displayRow(forSourceRow: $0) }
        dragSelectionBase = []
        clickedRow = -1
        rememberSelectionIdentity()
        accessibilityRowCache.removeAll()
        NSAccessibility.post(element: self, notification: .rowCountChanged)
        if keepingCells {
            moveVisibleCells { [self] oldRow in sourcesInView[oldRow].flatMap { displayRow(forSourceRow: $0) } }
        } else {
            recycleAllCells()
        }
        // Same data: the values fetched for the summaries are only re-indexed.
        if rebuildingSummaries {
            rebuildSummaryCalculators(reusingSourceValues: true, computingInBackground: true)
            updateSummary()
        } else if summaryScope != .allRows, selectedRowIndexes != selectedSourceRows {
            updateSummary()
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if selectedRowIndexes != selectedSourceRows {
            NSAccessibility.post(element: self, notification: .selectedRowsChanged)
            postSelectionNotification(Self.selectionDidChangeNotification)
        }
    }

    /// Shown while there are no rows, e.g. "No campaigns in this period".
    /// `nil` shows nothing.
    ///
    /// Without any data (the data source has no rows) the table shows only
    /// this, centered, without the header, row stripes and summary row. When
    /// the `rowFilter` hides every row, it shows centered in the rows area
    /// and the columns stay. While the data updates (see `isUpdatingData`)
    /// it gives way to the spinner, and comes back if there are still no rows.
    public var emptyStateText: String? {
        didSet {
            emptyStateLabel.stringValue = emptyStateText ?? ""
            needsLayout = true
        }
    }

    /// A custom view shown instead of `emptyStateText` while there are no rows
    /// (e.g. with an image and a button). It is sized to its fitting size and
    /// centered; use Auto Layout inside it.
    public var emptyStateView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            needsLayout = true
        }
    }

    private lazy var emptyStateLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        return label
    }()

    /// The empty state view while it is shown.
    var visibleEmptyStateView: NSView? {
        [emptyStateView, emptyStateLabel].compactMap { $0 }.first { $0.superview === self && !$0.isHidden }
    }

    func layoutEmptyState(_ metrics: LayoutMetrics) {
        // An update's spinner replaces the empty state once it fades in: it
        // may bring rows. Quick updates don't make the text flash.
        let isEmpty = numberOfRows == 0 && !isDataUpdateVeiled
        let view: NSView? = emptyStateView ?? (emptyStateText?.isEmpty == false ? emptyStateLabel : nil)
        if emptyStateView != nil, emptyStateLabel.superview != nil {
            emptyStateLabel.removeFromSuperview()
        }
        guard let view, isEmpty else {
            emptyStateView?.isHidden = true
            emptyStateLabel.isHidden = true
            return
        }
        if view.superview !== self {
            // Above the rows, below the header, summary and scrollers.
            addSubview(view, positioned: .below, relativeTo: headerBackground)
        }
        view.isHidden = false
        // The area between the header and the summary row.
        let area = NSRect(x: 0, y: metrics.headerHeight, width: bounds.width,
                          height: max(0, bounds.height - metrics.headerHeight - metrics.summaryHeight))
        let maxWidth = max(0, area.width - 40)
        if view === emptyStateLabel {
            emptyStateLabel.preferredMaxLayoutWidth = maxWidth
        }
        var size = view.fittingSize
        size.width = min(size.width, maxWidth)
        view.frame = NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                            width: size.width, height: size.height)
    }

    /// The data source row the user last clicked or right-clicked, or -1
    /// (below the rows, or after a reload), like `NSTableView.clickedRow`:
    /// for the `action`, `doubleAction` and menu actions.
    public internal(set) var clickedRow = -1

    /// The index in `tableColumns` of the column last clicked, or -1, like
    /// `NSTableView.clickedColumn`.
    public internal(set) var clickedColumn = -1

    /// Receives `action` and `doubleAction`; `nil` sends them along the
    /// responder chain. Held weakly, like a control's target.
    public weak var target: AnyObject?

    /// Sent to `target` when the user clicks the rows (once the mouse is
    /// released, also below the last row), like `NSTableView`'s action.
    /// Read `clickedRow` and `clickedColumn` in it.
    public var action: Selector?

    /// Sent to `target` when the user double-clicks (without Command or
    /// Shift), like `NSTableView.doubleAction`. `clickedRow` is -1 below the
    /// last row.
    public var doubleAction: Selector?

    /// Sent to `target` when the user presses Return with rows selected and
    /// no cell to edit, like a list's primary action (NSTableView has none:
    /// `nil` passes Return on, e.g. to the window's default button).
    /// `clickedRow` is -1; act on the selected rows.
    public var returnAction: Selector?
    /// `returnAction` is being sent (not a click).
    var isSendingReturnAction = false

    /// Outlines the row a context menu is for while the menu is open.
    var menuOutline: NGColorView?
    /// The display row `menuOutline` outlines.
    var menuOutlineRow: Int?
    /// The record `menuOutline` outlines.
    var menuOutlineRef: NGRowRef?

    /// Scroll position: x within the scrolling columns, y within the rows.
    public internal(set) var contentOffset = CGPoint.zero

    /// Whether the app is updating the table's data, e.g. loading another
    /// period or refreshing from a server. The table then fades and ignores the
    /// user (clicks, scrolling, menus, the keyboard), so nobody acts on rows that
    /// are about to change; reloading it from code works as usual. The fade
    /// starts after a moment, so updates that finish at once don't flash.
    ///
    /// Set it around the update, or use `updatingData(_:)` with async code.
    public var isUpdatingData = false {
        didSet {
            guard isUpdatingData != oldValue else { return }
            updateDataUpdateState()
        }
    }

    /// Whether a spinner shows in the middle of the table while it updates, so
    /// it's clear the table is loading, not stuck.
    public var showsDataUpdateIndicator = true {
        didSet { dataUpdateOverlay.showsIndicator = showsDataUpdateIndicator }
    }

    /// A caption under the spinner while the table updates, e.g. "Loading
    /// 18,000 campaigns…". It can change during the update (to show progress)
    /// and shows on its own when the spinner is off. `nil` shows none.
    public var dataUpdateText: String? {
        didSet { dataUpdateOverlay.text = dataUpdateText }
    }

    /// Updates running in `updatingData(_:)`.
    var runningDataUpdates = 0
    /// Whether the updating state is shown (see `updateDataUpdateState()`).
    var isShowingDataUpdate = false
    /// Tells a delayed fade-in whether its update is still the current one.
    var dataUpdateGeneration = 0
    /// Whether the update's veil has faded in (after its delay); the empty
    /// state is hidden meanwhile.
    var isDataUpdateVeiled = false {
        didSet {
            guard isDataUpdateVeiled != oldValue else { return }
            needsLayout = true
        }
    }
    lazy var dataUpdateOverlay = NGDataUpdateOverlay()

    /// Elastic overscroll ("bounce") at the top and bottom edges with trackpads,
    /// like system scroll views. Mouse wheels never bounce.
    public var bouncesVertically = true {
        didSet {
            guard !bouncesVertically else { return }
            // Turned off mid-pull: nothing would spring the rows back.
            stopElasticAnimation()
            verticalOverscroll = 0
            rawVerticalOverscroll = 0
            applyScrollPosition()
        }
    }

    // Elastic scrolling state (see NGElasticScrolling.swift).
    /// Displayed distance past the top (negative) or bottom (positive) edge.
    var verticalOverscroll: CGFloat = 0
    /// Unresisted distance the finger has pulled past the edge.
    var rawVerticalOverscroll: CGFloat = 0
    var elasticAnimation: ElasticAnimation?
    var elasticLink: CADisplayLink?
    /// Momentum after releasing an overscroll, or after a bounce, is ignored.
    var ignoresMomentum = false
    var lastScrollEventTimestamp: TimeInterval = 0

    // MARK: Views

    /// Translucent header material; rows scroll underneath it.
    let headerBackground = NSVisualEffectView()
    let headerView = NGGridHeaderView()
    let leadingRegion = NGRegionView(pin: .leading)
    let centerRegion = NGRegionView(pin: .none)
    let trailingRegion = NGRegionView(pin: .trailing)
    let leadingSeparator = NGColorView()
    let trailingSeparator = NGColorView()
    let summaryBar = NGSummaryBarView(frame: .zero)
    // Legacy scrollers. NSScroller takes its orientation from the frame it is created with.
    let verticalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 100))
    let horizontalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 16))
    let verticalOverlayScroller = NGOverlayScroller(orientation: .vertical)
    let horizontalOverlayScroller = NGOverlayScroller(orientation: .horizontal)

    // MARK: State

    private(set) var geometry = NGGridGeometry()
    /// Widths set by the user or `setWidth(_:forColumnID:)`; others use the column default.
    var columnWidths: [String: Double] = [:]

    /// A column being resized by dragging its edge in the header.
    struct ColumnResize {
        var columnID: String
        var pin: NGColumnPin
        var startX: CGFloat
        var startWidth: Double
    }

    var activeColumnResize: ColumnResize?

    /// A mouse press on a column header that has not become a drag yet.
    struct HeaderPress {
        var startLocation: NSPoint
        /// The column whose title was pressed (not a group's band): a click on it
        /// is reported on mouse up.
        var columnID: String?
        /// The column to sort on mouse up, if the press is on a sortable leaf title.
        var sortColumnID: String?
        /// What would move if the press turns into a drag.
        var reorderUnit: NGColumnReorder.Unit?
        var pin: NGColumnPin
    }

    var headerPress: HeaderPress?

    /// Columns being moved by dragging a header.
    struct ColumnDrag {
        var unit: NGColumnReorder.Unit
        var pin: NGColumnPin
        /// Snapshot of the dragged columns (header, cells, summary) following the pointer.
        var snapshot: NSView
        /// Pointer x relative to the snapshot's leading edge.
        var grabOffset: CGFloat
        /// Columns hidden while dragged, leaving an empty slot.
        var columnIDs: Set<String>
        /// Column definition when the drag began, to tell whether anything moved.
        var originalColumns: [NGColumnItem]
        /// Released: the snapshot is gliding into its slot and ignores the mouse.
        var isLanding = false
    }

    /// Pointer position during a column drag, for scrolling at the edges.
    var columnDragPointerX: CGFloat = 0
    /// Scrolls while a dragged column is held near an edge of the scrolling area.
    var columnDragScrollLink: CADisplayLink?

    /// The window whose cursor rects are disabled during a header interaction.
    weak var cursorRectsSuspendedWindow: NSWindow?

    var columnDrag: ColumnDrag?

    /// Row updates since `beginUpdates()` (see NGRowUpdates.swift), and how
    /// many `beginUpdates()` are open (0: no batch).
    var rowUpdateBatch: NGRowUpdateBatch?
    var rowUpdateDepth = 0
    /// `tableColumns` until `columns` change.
    var cachedTableColumns: [NGTableColumn]?
    /// Counts the changes of `columns`: what a column index means.
    var tableColumnsVersion = 0

    /// Selection a drag starts from: Command-drags add to (or remove from) it.
    var dragSelectionBase = IndexSet()
    var dragSelectionAdds = true
    /// Whether the current mouse press selected rows and may extend by dragging.
    var tracksDragSelection = false
    /// Pointer location (window coordinates) while selecting rows by dragging.
    var dragSelectionLocation: NSPoint?
    /// Scrolls while the pointer is dragged past the top or bottom of the rows.
    var dragSelectionLink: CADisplayLink?

    /// Temporary horizontal offsets that make reordered columns slide to their
    /// new positions; they decay to zero while `columnSlideLink` runs.
    var columnSlideOffsets: [String: CGFloat] = [:]
    var columnSlideStartOffsets: [String: CGFloat] = [:]
    var columnSlideStart: CFTimeInterval = 0
    var columnSlideLink: CADisplayLink?

    /// Where a column is drawn right now: its layout position plus any slide offset.
    func slideOffset(forColumnID columnID: String) -> CGFloat {
        columnSlideOffsets[columnID] ?? 0
    }

    func isHiddenForDrag(_ columnID: String) -> Bool {
        columnDrag?.columnIDs.contains(columnID) ?? false
    }

    var layoutMetrics = LayoutMetrics()
    /// The visible default cells, drawn by the Metal renderer.
    var visibleCells: [NGCellKey: NGDrawnCell] = [:]
    /// Numbers of column ids for `NGCellKey`; never reused while the table lives.
    var columnOrdinals: [String: Int] = [:]
    var visibleRows: [NGRowKey: NGRowBackground] = [:]
    /// The visible row backgrounds, for the Metal renderer's frames.
    var visibleRowEntries: [NGRowKey: NGRowBackground] { visibleRows }
    var visibleRowLayers: [NGRowBackground] { Array(visibleRows.values) + rowPool }

    var metalRenderer: NGMetalRenderer?
    var metalLayer: CAMetalLayer?
    /// Frames of the rows' layer the GPU hasn't finished (see `NGFramePacer`).
    let metalPacer = NGFramePacer()
    /// The header's and the summary row's content (see NGTableChrome.swift).
    var headerSurface: NGMetalSurface?
    var summarySurface: NGMetalSurface?
    /// The cell under the pointer (also after scrolling under a resting
    /// pointer), or `nil` outside the rows. See the delegate's
    /// `tableView(_:pointerDidEnterRow:column:)`.
    public internal(set) var hoveredCell: NGCellPosition?
    /// The hovered cell's record (see `setHoveredCell`).
    var hoveredCellRef: NGRowRef?
    /// The video or GIF of the media cell under the pointer.
    var mediaPlayer: NGMediaPlayer?
    /// Whether another window covered the table at a screen position of the
    /// pointer (the window server is asked once per position, for a moment:
    /// windows move without the pointer moving).
    var pointerCoverCheck: (location: NSPoint, isCovered: Bool, time: CFTimeInterval)?
    /// The control in a cell (a link) the mouse pressed, while it's held.
    var cellPress: (ref: NGRowRef, columnID: String)?
    /// The cell whose control the pointer is over, and whether the cursor
    /// is the pointing hand for it (see NGTableControls.swift).
    weak var pointerOverCell: NGDrawnCell?
    var showsPointingHand = false
    /// Where the pointer last was (window coordinates), for an editable rating's preview.
    var pointerWindowLocation: NSPoint? {
        didSet { if isLiveSortPaused != wasLiveSortPaused { wasLiveSortPaused = isLiveSortPaused; resumeLiveSortIfNeeded() } }
    }
    /// Whether the live sort was held when the pointer last moved.
    var wasLiveSortPaused = false
    /// Asks for frames while an indeterminate progress bar is drawn (see `syncProgressAnimation`).
    var progressLink: CADisplayLink?
    var drawsIndeterminateProgress = false
    /// The time the indeterminate stripe is drawn at, for tests.
    var progressAnimationTimeForTesting: CFTimeInterval?
    /// Takes a choice menu instead of popping it up (a modal loop), for tests.
    nonisolated(unsafe) static var choiceMenuShownForTesting: ((NSMenu) -> Void)?
    /// Opens links' URLs instead of the workspace, for tests.
    nonisolated(unsafe) static var openURLForTesting: ((URL) -> Void)?
    /// The pointer in window coordinates, for tests (no mouse there).
    var pointerLocationForTesting: NSPoint?
    /// Called on the main thread when a frame of the rows is on the screen:
    /// when it was drawn and when it showed (both `CACurrentMediaTime()`),
    /// for measuring how long data takes to show (a live feed's latency).
    /// Dropped frames aren't told.
    public var framePresented: ((_ drawnAt: CFTimeInterval, _ presentedAt: CFTimeInterval) -> Void)?
    /// Called on the main thread when the GPU has drawn a frame of the rows,
    /// with how long that took on the GPU (seconds), for measuring what
    /// drawing costs. Frames aren't timed unless this is set.
    public var frameRendered: ((_ gpuTime: CFTimeInterval) -> Void)?
    /// See `displaySelection`.
    var storedDisplaySelection = IndexSet()
    var displaySelectionIsStale = false
    /// A large, fragmented selection kept by row handle between batches of
    /// a feed (see `canKeepSelectionByHandle`), and how many it selects:
    /// `displaySelection` is built from it only when read.
    var keptSelection: (bits: [Bool], count: Int)?
    /// Set during `layout()`: the delegate hears about the pointer after it.
    var isInLayoutPass = false
    /// The layout direction for the length of a pass (a layout, a frame's
    /// quads): `userInterfaceLayoutDirection` asks AppKit up the view tree,
    /// which read for every cell was a noticeable part of a feed's frame.
    var passIsRightToLeft: Bool?
    /// Times the layout direction was asked of AppKit, for tests.
    var layoutDirectionReads = 0
    /// The cell under the pointer is found again on the next run loop turn.
    var isHoverUpdateScheduled = false

    /// Textures of the frame being built (pictures of media cells), by the
    /// slot their quads name.
    var metalTextures: [MTLTexture] = []
    var needsMetalFrame = false
    nonisolated(unsafe) var metalObserver: CFRunLoopObserver?
    /// Spare default cells; they stay hidden.
    var cellLayerPool: [NGDrawnCell] = []
    var rowPool: [NGRowBackground] = []
    /// Row where a range selection starts (shift-click, shift-arrows).
    var anchorRow: Int? {
        didSet {
            anchorIdentifier = anchorRow.flatMap { identifier(forSourceRow: sourceRow($0)) }
            if rowUpdateBatch?.displayIsStale == false { rowUpdateBatch!.anchor = anchorRow.flatMap(sourceRowIfAny) }
        }
    }
    /// Row moved by the arrow keys.
    var cursorRow: Int? {
        didSet {
            cursorIdentifier = cursorRow.flatMap { identifier(forSourceRow: sourceRow($0)) }
            if rowUpdateBatch?.displayIsStale == false { rowUpdateBatch!.cursor = cursorRow.flatMap(sourceRowIfAny) }
        }
    }
    /// Scroll gestures are locked to the axis they start on.
    var scrollAxis: NSEvent.GestureAxis?
    /// Whether the current scroll gesture (and its momentum) goes to the
    /// view containing the table: it's on an axis with nothing to scroll.
    var forwardsScrollGesture = false
    /// A live scroll is going on (see `willStartLiveScrollNotification`),
    /// by a scroller's drag; a pending end is undone by a new generation.
    var isLiveScrolling = false
    var liveScrollByScroller = false
    var liveScrollEndGeneration = 0
    /// The events of the current gesture before its axis was known, for the
    /// container to get the whole gesture if it goes there.
    var scrollGestureStart: [NSEvent] = []
    var scrollerFadeTasks: [NSEvent.GestureAxis: Task<Void, Never>] = [:]
    var scrollerLastActivity: [NSEvent.GestureAxis: TimeInterval] = [:]
    /// Accessibility elements, kept stable for VoiceOver until data or columns change.
    var accessibilityRowCache: [Int: NGAccessibilityRow] = [:]
    var accessibilityHeaderCache: [String: NGAccessibilityColumnHeader] = [:]
    var accessibilityColumnCache: [String: NGAccessibilityColumn] = [:]
    private(set) lazy var accessibilitySummaryElement = NGAccessibilitySummary(table: self)

    /// Values of a column for the summary, with only the values a filter includes.
    struct SummaryKey: Hashable, Sendable {
        var columnID: String
        var filter: NGValueFilter
    }

    var summaryCalculators: [SummaryKey: NGSummaryCalculator] = [:]
    /// The calculators of groups' subtotals, kept to update them in place.
    var groupSummaryCalculators: [NGRowGroup: [SummaryKey: NGSummaryCalculator]] = [:]
    /// Numeric values of every data source row by column id, until the next reload.
    var summarySourceValues: [String: [Double]] = [:]
    /// Changes whenever the data changes, so values read for older data are
    /// never kept.
    var summaryDataGeneration = 0
    /// A synchronous computation replaced a background one: tell the delegate
    /// once the summary row shows the result.
    var notifiesSummaryUpdate = false
    /// A background computation was stopped when the table left its window.
    var needsSummaryRebuild = false

    /// Up to this many values to read (data source rows × summarized columns),
    /// summaries are computed right away. Above it, `reloadData()` shows the
    /// rows at once and the summary row follows when it has been computed in
    /// the background, keeping the app responsive with large data.
    public var synchronousSummaryLimit = 50_000
    /// Up to this many values (rows × summaries), calculators are built from
    /// values already read right away (a few milliseconds); above, after a
    /// filter or search, in the background.
    var synchronousSummaryComputeLimit = 2_000_000
    /// How long work done on the main actor in slices (reading values for a
    /// sort, summaries, a search, a copy) takes before giving the run loop a
    /// turn: well within a 120 Hz frame, which drawing needs too.
    nonisolated static let backgroundSlice: Duration = .milliseconds(5)
    /// Rows a sheet of an exported workbook holds (Excel's limit; smaller in tests).
    var exportMaxRowsPerSheet = 1_048_576
    /// The ids of the columns defined (see `rebuildColumns`).
    var definedColumnIDs: Set<String> = []

    /// Tables with at least this many cells to search (rows × searched text
    /// columns) read the words of their first search (or of other searched
    /// columns) in slices of a few milliseconds,
    /// keeping the app responsive, and show the previous rows meanwhile
    /// (`isSearchingRows`); smaller ones search at once. Later searches use
    /// the words read and are immediate.
    public var synchronousSearchLimit = 50_000

    /// Up to this many values (selected rows × visible columns), `copy(_:)`
    /// puts the text on the pasteboard at once; larger selections are read
    /// in slices and formatted on all cores (`isCopying`).
    public var synchronousCopyLimit = 50_000

    /// The file name `exportDocument(_:)` suggests (without extension);
    /// `autosaveName` or "Table" by default.
    public var exportFileName: String?

    /// Whether an export is reading the table (see `exportedData(as:options:)`).
    public internal(set) var isExporting = false
    var exportsRunning = 0

    /// Whether a large copy is being prepared (see `synchronousCopyLimit`).
    public internal(set) var isCopying = false
    var copyTask: Task<Void, Never>?
    /// Counts the background copies: only the latest ends `isCopying`.
    var copyGeneration = 0
    /// Where `copy(_:)` puts the text (tests use a pasteboard of their own).
    var copyPasteboard = NSPasteboard.general

    /// Whether the words of a search are being read (see `synchronousSearchLimit`).
    public internal(set) var isSearchingRows = false

    /// Up to this many group keys to read (data source rows × grouping
    /// columns not grouped by before), rows are grouped at once. Above it,
    /// the keys are read in slices of a few milliseconds, keeping the app
    /// responsive, and the rows show as they were grouped before meanwhile
    /// (`isGroupingRows`). Columns grouped by keep their keys: collapsing,
    /// filtering and grouping by them again are immediate.
    public var synchronousGroupingLimit = 50_000
    /// Whether the keys of a grouping are being read (see `synchronousGroupingLimit`).
    public internal(set) var isGroupingRows = false
    /// The keys of a grouping being read, and the task reading them.
    var groupingJob: NGGroupingJob?
    var groupingTask: Task<Void, Never>?

    /// Whether summaries are being computed in the background; the summary row
    /// shows the previous values meanwhile.
    public internal(set) var isComputingSummary = false

    /// Whether a spinner shows in the summary row, and its values dim, while a
    /// background computation takes more than a moment. Turn it off to show
    /// progress in your own UI (see `isComputingSummary`).
    public var showsSummaryProgress = true {
        didSet { updateSummaryProgress() }
    }

    /// The spinner is shown only after a short delay, so quick computations
    /// don't flash it.
    var isSummaryProgressVisible = false {
        didSet {
            guard isSummaryProgressVisible != oldValue else { return }
            updateSummaryProgress()
        }
    }

    private lazy var summaryProgress: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .mini
        indicator.isDisplayedWhenStopped = false
        indicator.isHidden = true
        return indicator
    }()

    /// The spinner's side (a mini control's fitting size, asked once).
    private var summaryProgressSize: CGFloat?
    private var isSummaryProgressShowing: Bool { showsSummaryProgress && isSummaryProgressVisible && showsSummaryBar }

    private func updateSummaryProgress() {
        let visible = isSummaryProgressShowing
        if visible, summaryProgress.superview !== summaryBar.contentView {
            summaryBar.contentView.addSubview(summaryProgress)
        }
        if visible {
            layoutSummaryProgress()
        }
        summaryProgress.isHidden = !visible
        if visible {
            summaryProgress.startAnimation(nil)
        } else {
            summaryProgress.stopAnimation(nil)
        }
        summaryBar.contentView.needsDisplay = true
    }

    /// At the leading edge of the summary row, in the table's edge margin.
    func layoutSummaryProgress() {
        // (Hidden it's left alone: its fitting size is an Auto Layout pass,
        // which every layout of a live table paid for.)
        guard summaryProgress.superview != nil, !summaryProgress.isHidden || isSummaryProgressShowing else { return }
        if summaryProgressSize == nil {
            let fitting = summaryProgress.fittingSize.height
            summaryProgressSize = fitting > 0 ? fitting : 10
        }
        let size = summaryProgressSize ?? 10
        let bounds = summaryBar.contentView.bounds
        summaryProgress.frame = NSRect(x: 6, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
    }

    var summaryTask: Task<Void, Never>?
    /// Identifies the current background computation; newer ones win.
    var summaryGeneration = 0
    /// Display strings of the summary row, recomputed only when data, selection or scope change.
    var summaryTexts: [String: String] = [:]

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        if let metalObserver { CFRunLoopObserverInvalidate(metalObserver) }
        // Background work for no one: a sort's cores stop comparing at once.
        sortTask?.cancel()
        summaryTask?.cancel()
        searchBuildTask?.cancel()
        groupingTask?.cancel()
        measuringTask?.cancel()
        copyTask?.cancel()
    }

    private func commonInit() {
        clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(currentLocaleDidChange(_:)),
                                               name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaCacheDidChange(_:)),
                                               name: NGMediaCache.didChangeNotification, object: nil)

        for region in regions {
            region.owner = self
            addSubview(region)
        }
        for separator in [leadingSeparator, trailingSeparator] {
            separator.color = .separatorColor
            addSubview(separator)
        }
        headerBackground.material = .headerView
        headerBackground.blendingMode = .withinWindow
        headerBackground.state = .followsWindowActiveState
        addSubview(headerBackground)
        headerView.owner = self
        addSubview(headerView)
        summaryBar.contentView.owner = self
        addSubview(summaryBar)
        setUpScrollers()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferredScrollerStyleDidChange(_:)),
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )

        rebuildColumns()
        setUpMetalRenderer()
    }

    var regions: [NGRegionView] { [leadingRegion, centerRegion, trailingRegion] }

    public override var isFlipped: Bool { true }

    /// Tests fix what otherwise depends on the screen, the window and System
    /// Settings: the pixel density, whether the selection is emphasized (key
    /// window and focus), and the accent color of emphasized selections.
    var scaleForTesting: CGFloat?
    var emphasisForTesting: Bool?
    var accentColorForTesting: NSColor?

    // State of the sections in other files (stored properties stay in the class).
    /// Set while columns are only being reordered, so the rebuild keeps the scroll
    /// position and sort and does not reload data.
    var isReorderingColumns = false
    var isChangingColumnVisibility = false
    var isApplyingLayoutState = false
    /// A save of the layout waits for the end of this turn of the run loop
    /// (or of a live resize), see `scheduleLayoutAutosave()`.
    var layoutAutosavePending = false
    var layoutAutosaveScheduled = false
    var headerPointerAreasGeneration = 0
    var lastVisibleRange: VisibleRange?
    /// A batch moved rows but every row in view shows the same record,
    /// unchanged: the next layout pass doesn't place the rows again (a feed's
    /// inserts and removes out of view).
    var keepsVisibleRowsInNextLayout = false
    /// Display rows in view the next layout pass places again (their records changed).
    var rowsToPlaceAgain = Set<Int>()
    /// Rows (handles) inserted since the sorted order was last updated.
    var sortRowsInserted: [Int32] = []
    /// Whether the previous sorted order was looked through for every row
    /// since the last time this was reset (for tests).
    var sortScannedAllRows = false
    /// How many times a row was placed (for tests).
    var rowPlacements = 0
    /// The scrolling columns the last layout pass placed cells for.
    var lastCenterColumns: [PlacedColumn] = []
    /// Format ids by column number, found once per column (reset when the
    /// columns change, as a column's format may).
    var columnFormatIDs: [Int?] = []
    /// Tracked here because while becoming or resigning first responder the
    /// window still reports the previous first responder.
    var hasFocus = false
    /// The data source rows selected when a mouse press began, while the
    /// press lasts: its changes are "is changing" until the mouse is released.
    var selectionTrackingStart: IndexSet?
    /// Whether the mouse up of the current press sends `action`.
    var sendsClickAction = false
    var typeSelectBuffer = ""
    var lastTypeSelectTime: TimeInterval = 0
    /// The key event being interpreted, for the delegate's type select hook.
    var typeSelectEvent: NSEvent?

    // MARK: Public API

    /// Reads the data again: the number of rows, the visible cells, the
    /// summaries, the filter and the search index.
    ///
    /// Call it right after the data changed, before anything else touches the
    /// table: until then it still asks about the old rows. With row
    /// identities (`rowIdentifierColumnID` or the data source's
    /// `tableView(_:identifierForRow:)`) the selection follows the same records
    /// to their new rows; without them it stays on the same row indexes, as
    /// do selections of more than `identitySelectionLimit` (10,000) rows. All
    /// rows selected stay all selected. Only the visible cells are read at once; summaries of large tables are
    /// computed in the background (see `synchronousSummaryLimit`).
    public func reloadData() {
        let previousSelection = selectedRowIndexes
        let previousAnchor = anchorRow.flatMap(sourceRowIfAny)
        let previousCursor = cursorRow.flatMap(sourceRowIfAny)
        let identifiers = Set(selectedIdentifiers.values)
        let (anchor, cursor) = (anchorIdentifier, cursorIdentifier)
        let selectedAllRows = selectionIsAllRows
        // The previous matches and order, by row (handles start over below).
        let previousMatches = filterMatches.map { matches in Self.matchesByRow(allRowHandles, matches) }
        let handles = rowHandles
        let previousOrder = sortedRows.map { order in Self.rows(of: order, handles: handles) }
        let hiddenRows = hiddenRowIndexes
        let (focused, cellRange) = (focusedCell, selectedCellRange)
        numberOfSourceRows = dataSource?.numberOfRows(in: self) ?? 0
        rowHandles.reset(count: numberOfSourceRows)
        forgetAllRowHeights()
        rowGeometryCache = nil
        sortRowsInserted = []
        // Other records: identities are read again on the next lookup, and
        // a tree's parents.
        identityIndex = nil
        treeParentHandles = []
        treeSummaryFlips = []
        columnFilterPasses = [:]
        columnFilterRowsToCheck = []
        // The focused cell and cell range keep their row indexes, like the
        // selection (dropped beyond the rows); with identities the focused
        // cell follows its record, below.
        let focusedIdentity = self.focusedIdentity
        focusedHandleCell = focused.flatMap(handleCell(of:))
        selectedHandleRange = nil
        // The hovered cell keeps its row index too (it's the same cell to the pointer).
        hoveredCellRef = hoveredCell.flatMap { $0.row < numberOfSourceRows ? rowRef(ofRow: $0.row) : nil }
        selectedCellRange = cellRange
        // The records may be others: nothing flashes on, or moves, or edits;
        // an open batch's cells don't follow the rows they showed before.
        rowUpdateBatch?.visibleHandles = [:]
        endEditing(committing: false)
        closeRowActions()
        clearChangeHighlights()
        finishRowAnimation()
        // The same row indexes stay hidden, like in NSTableView (handles
        // start over as the row indexes).
        hiddenRowHandles = Set(Self.clamped(hiddenRows, to: numberOfSourceRows))
        allRowHandlesCache = nil
        Self.releaseInBackground(searchIndex.take())
        cancelSearchBuild()
        // The previous matches show while a large table reads its words again
        // (if the rows are as many); every row is evaluated again.
        filterMatches = previousMatches?.count == numberOfSourceRows ? previousMatches : nil
        filterNeedsFullEvaluation = true
        rowMapNeedsRebuild = true
        filteredRows = nil
        filteredRowsToPlace = []
        Self.releaseInBackground(groupKeys.take())
        groupKeysToRead = []
        cancelGroupingJob()
        // Everything is read again: what an open batch noted is done.
        if rowUpdateBatch != nil {
            rowUpdateBatch!.dirtyRows = []
            rowUpdateBatch!.pendingDirtyRows = []
            rowUpdateBatch!.newRows = []
            rowUpdateBatch!.movedRows = []
            rowUpdateBatch!.removedValues = [:]
            rowUpdateBatch!.removedLeaves = []
            rowUpdateBatch!.groupLeavesAreUnknown = true
        }
        // Values are read again; a large table shows the previous order
        // (`sortedOrder`, now handles of the same rows) while it sorts them
        // in the background.
        cancelBackgroundSort()
        Self.releaseInBackground(sortKeys.take())
        sortKeysToRead = []
        sortRowsToPlace = []
        let rowCount = numberOfSourceRows
        cancelSortSettle()
        sortedOrder = previousOrder.map { NGHandleSequence.changingOrder(Self.rows($0, below: rowCount), capacity: rowCount) }
        filteredSortedOrder = nil
        filterFlippedRows = nil
        computeDisplayRows()
        // The rows it referred to may have changed.
        clickedRow = -1
        // With row identities the selection follows the same records; otherwise
        // it stays on the same data source rows (also when a filter shows others).
        if let focusedIdentity, let columnID = focused?.columnID, identifier(forSourceRow: 0) != nil {
            let row = row(forIdentifier: focusedIdentity)
            focusedHandleCell = row >= 0 ? handleCell(of: NGCellPosition(row: row, columnID: columnID)) : nil
        }
        if !restoreSelectionIdentity(identifiers, anchor: anchor, cursor: cursor) {
            let rowCount = numberOfSourceRows
            let kept = selectedAllRows ? IndexSet(integersIn: 0..<rowCount) : Self.clamped(previousSelection, to: rowCount)
            displaySelection = displayRows(forSourceRows: kept)
            // Anchors past the end would extend selections to rows that no longer exist.
            anchorRow = previousAnchor.flatMap { $0 < rowCount ? displayRow(forSourceRow: $0) : nil }
            cursorRow = previousCursor.flatMap { $0 < rowCount ? displayRow(forSourceRow: $0) : nil }
            selectedIdentifiers = [:]
            rememberedSelection = []
            rememberSelectionIdentity()
        }
        dragSelectionBase = []
        accessibilityRowCache.removeAll()
        NSAccessibility.post(element: self, notification: .rowCountChanged)
        recycleAllCells()
        rebuildSummaryCalculators()
        updateSummary()
        needsLayout = true
        layoutSubtreeIfNeeded()
        headerView.needsDisplay = true
        if selectedRowIndexes != previousSelection {
            NSAccessibility.post(element: self, notification: .selectedRowsChanged)
            postSelectionNotification(Self.selectionDidChangeNotification)
        }
    }

    /// Recomputes the summary row without reloading cells.
    public func reloadSummary() {
        rebuildSummaryCalculators()
        updateSummary()
    }

    /// Selects data source rows; rows hidden by the filter are ignored.
    public func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        if rowUpdateBatch?.displayIsStale == true {
            syncBatchSelection()
        }
        if rowUpdateBatch?.displayIsStale == true, let batch = rowUpdateBatch {
            // Display rows still mean the rows before the batch's moves: the
            // batch keeps the selection, and the end of the batch shows it
            // (without the rows the filter or collapsed groups hide).
            var valid = Self.clamped(indexes, to: numberOfSourceRows)
            if extend, valid.isEmpty { return }
            if !allowsMultipleSelection, let last = valid.last { valid = [last] }
            rowUpdateBatch!.selection = extend && allowsMultipleSelection ? batch.selection.union(valid) : valid
            rowUpdateBatch!.selectionSetByCalls = true
            if let last = valid.last {
                rowUpdateBatch!.anchor = valid.first
                rowUpdateBatch!.cursor = last
            }
            return
        }
        selectDisplayRows(displayRows(forSourceRows: indexes), byExtendingSelection: extend)
    }

    func selectDisplayRows(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        // Group headers aren't selected (nor anchor a selection).
        var valid = Self.clamped(indexes, to: numberOfRows)
        if let groupedDisplay { valid = Self.removingHeaders(from: valid, groupedDisplay) }
        // Extending by nothing changes nothing.
        if extend, valid.isEmpty { return }
        if !allowsMultipleSelection, let last = valid.last {
            valid = [last]
        }
        let selection = extend && allowsMultipleSelection ? displaySelection.union(valid) : valid
        // Keyboard and Shift-click extend from the programmatic selection.
        if let last = valid.last {
            anchorRow = valid.first
            cursorRow = last
        }
        setSelection(selection)
    }

    /// Scrolls so that `point` becomes the content offset (clamped to the content).
    public func scroll(to point: CGPoint) {
        setContentOffset(point)
    }

    /// Scrolls a data source row into view (if the filter shows it).
    public func scrollRowToVisible(_ row: Int) {
        guard let displayRow = displayRow(forSourceRow: row) else { return }
        scrollDisplayRowToVisible(displayRow)
    }

    func scrollDisplayRowToVisible(_ row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        // Rows of wrapped text not measured yet would put it out of view.
        if measuresRowHeights { measureRows(around: row) }
        let metrics = layoutMetrics
        let visibleHeight = metrics.bodyHeight - metrics.bottomInset
        let rowLayout = rowGeometry
        let rowMinY = rowLayout.top(of: row)
        let rowMaxY = rowMinY + rowLayout.height(of: row)
        var y = contentOffset.y
        if rowMinY < y + floatingHeadersCover(atOffset: y, except: row) {
            // Up: the row goes just below the headers that float there, which
            // depend on where it's scrolled to: at most one row per level of
            // groups above it, the least that uncovers it.
            let levels = groupedDisplay == nil ? 0 : max(1, rowGrouping?.columnIDs.count ?? 1)
            y = max(0, rowMinY - CGFloat(levels) * rowHeight)
            for level in 0..<levels {
                let candidate = max(0, rowMinY - CGFloat(level) * rowHeight)
                if floatingHeadersCover(atOffset: candidate, except: row) <= rowMinY - candidate {
                    y = candidate
                    break
                }
            }
        } else if rowMaxY > y + visibleHeight {
            y = rowMaxY - visibleHeight
        }
        setContentOffset(CGPoint(x: contentOffset.x, y: y))
    }

    /// The summary row text of a column, as displayed.
    public func summaryText(forColumnID columnID: String) -> String? {
        summaryTexts[columnID]
    }

    /// The current summary value of a column (an aggregate or a formula) in the
    /// current `summaryScope`, or `nil` if it has none. While a background
    /// computation runs (`isComputingSummary`), values that depend on the
    /// selection are `nil`.
    public func summaryValue(forColumnID columnID: String) -> Double? {
        guard let column = columnLayout.columnsByID[columnID] else { return nil }
        return summaryValue(of: column)
    }

    /// The frame of a cell in the table's coordinates, while any of it is
    /// visible: for anchoring a popover to it or animating from it (e.g.
    /// Quick Look's `sourceFrameOnScreen`). `row` is a data source row.
    ///
    /// Returns `nil` when the cell isn't on screen: its row or column is
    /// scrolled out of view, hidden by the row filter, or the column is hidden.
    /// A partly visible cell gives its whole frame. For screen coordinates:
    /// `window.convertToScreen(table.convert(frame, to: nil))`.
    public func frameOfCell(row: Int, columnID: String) -> NSRect? {
        guard let placement = cellPlacement(row: row, columnID: columnID), !placement.isRegionHidden,
              !placement.frame.intersection(placement.visible).isEmpty else { return nil }
        return placement.frame
    }

    /// Where a cell is, shown or not (in the table's coordinates), and the
    /// part of the table where its region shows rows (between the header and
    /// the summary row); `nil` if its row isn't shown or its column is hidden.
    func cellPlacement(row: Int, columnID: String) -> (frame: NSRect, visible: NSRect, isRegionHidden: Bool)? {
        guard let displayRow = displayRow(forSourceRow: row), displayRow < numberOfRows else { return nil }
        for (pin, region) in [(NGColumnPin.leading, leadingRegion), (.none, centerRegion), (.trailing, trailingRegion)] {
            guard let column = geometry[pin].columns.first(where: { $0.column.id == columnID }) else { continue }
            let inCanvas = NSRect(x: CGFloat(column.x) + slideOffset(forColumnID: columnID), y: rowGeometry.top(of: displayRow),
                                  width: CGFloat(column.width), height: rowGeometry.height(of: displayRow))
            let frame = convert(inCanvas, from: region.canvas)
            let metrics = layoutMetrics
            // Below the group headers floating at the top (other than its own).
            let cover = groupedDisplay == nil ? 0 : floatingHeadersCover(atOffset: contentOffset.y, except: displayRow)
            let top = metrics.headerHeight + cover
            let visible = region.frame.intersection(NSRect(x: 0, y: top, width: bounds.width,
                                                           height: max(0, bounds.height - top - metrics.summaryHeight)))
            return (frame, visible, region.isHidden)
        }
        return nil
    }

    /// The current width of a column.
    public func width(ofColumnID columnID: String) -> Double? {
        let frames = geometry.leading.columns + geometry.center.columns + geometry.trailing.columns
        return frames.first { $0.column.id == columnID }?.width
    }

    func updateGeometry() {
        let edgeInset = selectionHighlightStyle == .rounded ? NGMetrics.contentEdgeInset : 0
        geometry = NGGridGeometry(layout: columnLayout, widths: columnWidths, edgeInset: Double(edgeInset),
                                  isRightToLeft: isRightToLeft, centerSpan: Double(mirroredCenterSpan))
    }

    /// Sets a column's width, clamped to its minimum and maximum. Widths survive
    /// `reloadData()` and rebuilding `columns` (for columns with the same id).
    public func setWidth(_ width: Double, forColumnID columnID: String) {
        guard let column = columnLayout.columnsByID[columnID] else { return }
        // Whole device pixels keep every column edge to the right sharp.
        let clamped = min(max(Double(pixelAligned(CGFloat(width))), column.minWidth), column.maxWidth)
        guard columnWidths[columnID] != clamped else { return }
        let oldWidth = self.width(ofColumnID: columnID) ?? column.width
        columnWidths[columnID] = clamped
        updateGeometry()
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard oldWidth != clamped else { return }
        let notification = Notification(name: Self.columnDidResizeNotification, object: self,
                                        userInfo: ["NSTableColumn": column, "NSOldWidth": NSNumber(value: oldWidth)])
        delegate?.tableViewColumnDidResize(notification)
        NotificationCenter.default.post(notification)
        scheduleLayoutAutosave()
    }

    /// Posted whenever a column's width changed, like
    /// `NSTableView.columnDidResizeNotification` (see the delegate's
    /// `tableViewColumnDidResize(_:)`). The object is the table.
    public static let columnDidResizeNotification = Notification.Name("NGTableViewColumnDidResizeNotification")

    /// Posted when the user moved a column, like
    /// `NSTableView.columnDidMoveNotification` (see the delegate's
    /// `tableViewColumnDidMove(_:)`). The object is the table.
    public static let columnDidMoveNotification = Notification.Name("NGTableViewColumnDidMoveNotification")

    /// After the user moved columns by dragging: saves the layout and tells
    /// the delegate, the NGTable way (the new definition) and the NSTableView
    /// way (each moved column's old and new index).
    func reportColumnsMoved(from originalColumns: [NGColumnItem], dragged draggedIDs: Set<String>) {
        guard columns != originalColumns else { return }
        autosaveLayoutState()
        delegate?.tableView(self, didReorderColumns: columns)
        let oldIDs = originalColumns.flatMap(\.leafColumns).map(\.id)
        let newIndex = Dictionary(tableColumns.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (oldIndex, id) in oldIDs.enumerated() where draggedIDs.contains(id) {
            guard let new = newIndex[id], new != oldIndex else { continue }
            let notification = Notification(name: Self.columnDidMoveNotification, object: self,
                                            userInfo: ["NSOldColumn": NSNumber(value: oldIndex), "NSNewColumn": NSNumber(value: new)])
            delegate?.tableViewColumnDidMove(notification)
            NotificationCenter.default.post(notification)
        }
    }

    /// At the end of a column drag, moved or not: the delegate's `didDrag`
    /// for each column dragged, like NSTableView's.
    func reportColumnsDragged(_ draggedIDs: Set<String>) {
        for column in tableColumns where draggedIDs.contains(column.id) {
            delegate?.tableView(self, didDrag: column)
        }
    }

    /// Resizes a column to fit its title, values and summary text (media
    /// cells: the picture and the widest line).
    public func sizeColumnToFit(_ columnID: String) {
        guard let column = columnLayout.columnsByID[columnID] else { return }
        // Each text is measured once per font (columns repeat their values),
        // by the renderer's text shaper: the widths cells are drawn with, and
        // text of simple lines without Core Text (the shaper keeps it for
        // drawing too). Without a renderer, by attributed strings.
        let shaper = metalRenderer?.shaper
        var measured: [ObjectIdentifier: (attributes: [NSAttributedString.Key: Any], texts: Set<String>)] = [:]
        func width(of text: String, font: NSFont) -> CGFloat {
            guard !text.isEmpty else { return 0 }
            let key = ObjectIdentifier(font)
            if measured[key] == nil { measured[key] = ([.font: font], []) }
            guard measured[key]!.texts.insert(text).inserted else { return 0 }
            if let shaper { return shaper.shape(text, font: font, width: .greatestFiniteMagnitude).width }
            return NSAttributedString(string: text, attributes: measured[key]!.attributes).size().width
        }

        let size = tableStyle.cellFontSize
        // Room for the sort indicator, which appears next to the title.
        var widest = width(of: column.title, font: .systemFont(ofSize: tableStyle.titleFontSize)) + 14
        if let dataSource {
            let textFont = NSFont.systemFont(ofSize: size)
            let digitFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
            // Measuring is linear in rows; cap it so a double-click stays instant.
            // In a batch that moved rows, display rows don't mean the data
            // source's rows yet: its rows are measured as they are.
            let displayIsStale = rowUpdateBatch?.displayIsStale == true
            for row in 0..<min(displayIsStale ? numberOfSourceRows : numberOfRows, 20_000) where displayIsStale || !isGroupRow(row) {
                let value = dataSource.tableView(self, valueFor: column, row: displayIsStale ? row : sourceRow(row))
                if case .tags(let tags) = value {
                    widest = max(widest, NGCellDrawing.fittingWidth(of: tags, shaper: shaper) - 2 * NGMetrics.cellPadding)
                    continue
                }
                if case .mark(let mark) = value {
                    widest = max(widest, NGCellDrawing.fittingWidth(of: mark) - 2 * NGMetrics.cellPadding)
                    continue
                }
                if case .sparkline = value {
                    // Room for a readable chart.
                    widest = max(widest, NGMetrics.sparklineFittingWidth - 2 * NGMetrics.cellPadding)
                    continue
                }
                if case .media(let media) = value {
                    // The picture and the widest line beside it.
                    let lines = media.lines.map { line in
                        width(of: line.text, font: line.style == .title ? NSFont.systemFont(ofSize: size, weight: .medium)
                                                                         : NSFont.preferredFont(forTextStyle: .caption1))
                    }
                    widest = max(widest, NGMetrics.mediaInset + media.thumbnailSize.width + NGMetrics.mediaTextSpacing
                                 + (lines.max() ?? 0) + NGMetrics.mediaInset - 2 * NGMetrics.cellPadding)
                    continue
                }
                let isNumeric = value.numericValue != nil || column.isNumeric
                widest = max(widest, width(of: NGFormatIDs.string(for: value, format: column.format, locale: locale), font: isNumeric ? digitFont : textFont))
            }
        }
        // Cells with choices keep room for the pop-up chevron.
        if Self.showsChoiceChevron(column), let chevron = Self.choiceChevronImage {
            widest += chevron.size.width + NGMetrics.choiceChevronSpacing
        }
        if let summary = summaryTexts[columnID] {
            widest = max(widest, width(of: summary, font: .monospacedDigitSystemFont(ofSize: size, weight: .semibold)))
        }
        setWidth(Double(ceil(widest + 2 * NGMetrics.cellPadding + 2)), forColumnID: columnID)
    }

    /// The column searched when the user types the beginning of a value, like
    /// Finder's type select. `nil` uses the first displayed column.
    public var typeSelectColumnID: String?
}

extension NGTableView: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        // Nothing to copy or select while the data is about to change.
        case #selector(copy(_:)): !ignoresUserInput && !displaySelection.isEmpty
        case #selector(selectAll(_:)): !ignoresUserInput && allowsMultipleSelection && numberOfRows > 0
        case #selector(exportDocument(_:)): !ignoresUserInput && !isExporting && window != nil
        case #selector(printView(_:)): !ignoresUserInput && dataSource != nil
        case #selector(NSText.delete(_:)): rowDeletion != nil && !ignoresUserInput && !displaySelection.isEmpty
        default: true
        }
    }
}

#endif
