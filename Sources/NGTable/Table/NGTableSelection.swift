#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Selection: how selected rows look (focus, key window, system colors, and
// moving between windows), mouse and programmatic selection with
// NSTableView's API and notifications, drag selection with autoscrolling,
// clicks and their actions, column lookup and hit testing, and copying rows.

extension NGTableView {
    // MARK: Selection appearance

    /// Selection is emphasized (accent colored) only while the table has focus.
    private var isEmphasized: Bool {
        if let emphasisForTesting { return emphasisForTesting }
        guard let window else { return false }
        return window.isKeyWindow && hasEffectiveFocus
    }

    /// The table has the keyboard, or its cell editor has it (the selection
    /// stays emphasized while a cell is edited, like NSTableView's).
    var hasEffectiveFocus: Bool { hasFocus || editor != nil }

    func isHighlighted(row: Int) -> Bool {
        isEmphasized && (isDisplayRowSelected(row) || isKeyboardGroupRow(row))
    }

    func rowColor(_ row: Int) -> NGColor {
        if row < numberOfRows, isDisplayRowSelected(row) || isKeyboardGroupRow(row) {
            return isEmphasized ? accentColorForTesting ?? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        }
        if isGroupRow(row) {
            return tableStyle.groupRowColor ?? Self.groupRowColor
        }
        if row < numberOfRows, let tint = delegate?.tableView(self, backgroundColorForRow: sourceRow(row)) {
            return tint
        }
        guard usesAlternatingRowBackgroundColors else { return .clear }
        let stripes = tableStyle.stripeColors.flatMap { $0.isEmpty ? nil : $0 } ?? NGColor.alternatingContentBackgroundColors
        return stripes[row % stripes.count]
    }

    func refreshSelectionAppearance() {
        // Highlights change here, before the layout pass that would notice.
        setNeedsMetalFrame()
        for (key, cell) in visibleCells {
            cell.isHighlighted = isHighlighted(row: key.row)
        }
        // Row backgrounds depend on their neighbors' selection (merged rounded
        // blocks); cells render their new highlight.
        layoutVisibleContent()
    }

    #if os(macOS)
    public override var acceptsFirstResponder: Bool { isEnabled }
    #else
    public override var canBecomeFirstResponder: Bool { isEnabled }
    #endif

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { hasFocus = true }
        refreshSelectionAppearance()
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            hasFocus = false
            showsFocusRing = false
        }
        refreshSelectionAppearance()
        return result
    }

    #if os(macOS)
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        setHoveredCell(nil)
        // Display links retain the table and pause without a window: stop them,
        // and end interactions that would otherwise be stuck when it comes back.
        endSelectionTracking()
        stopElasticAnimation()
        if verticalOverscroll != 0 || rawVerticalOverscroll != 0 {
            verticalOverscroll = 0
            rawVerticalOverscroll = 0
            applyScrollPosition()
        }
        stopDragSelectionScroll()
        tracksDragSelection = false
        if isHeaderInteracting || columnDrag != nil || cursorRectsSuspendedWindow != nil {
            cancelHeaderInteraction()
        }
        // A slide can outlive the drop that started it; its link retains the table.
        stopColumnSlide()
        stopProgressAnimation()
        stopColumnDragScrolling()
        endDropScrolling()
        // The new window has its own first responder.
        hasFocus = false
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: window)
        }
        if newWindow == nil {
            // Off screen there is nobody to show a summary to.
            if cancelSummaryComputation() {
                needsSummaryRebuild = true
            }
            // Off screen, spare cells and views are only memory; nothing flashes.
            cellLayerPool.removeAll()
            clearChangeHighlights()
            finishRowAnimation()
            NotificationCenter.default.removeObserver(self, name: NGColor.systemColorsDidChangeNotification, object: nil)
        }
    }
    #endif

    #if os(macOS)
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyStateDidChange(_:)), name: name, object: window)
        }
        // Frames wait while the window can't be seen (see `isWindowUnseen`).
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityDidChange(_:)), name: name, object: window)
        }
        NotificationCenter.default.removeObserver(self, name: NSApplication.didUnhideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityDidChange(_:)),
                                               name: NSApplication.didUnhideNotification, object: nil)
        if needsSummaryRebuild {
            needsSummaryRebuild = false
            rebuildSummaryCalculators(reusingSourceValues: true)
            updateSummary()
        }
        NotificationCenter.default.removeObserver(self, name: NGColor.systemColorsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemColorsDidChange(_:)),
                                               name: NGColor.systemColorsDidChangeNotification, object: nil)
    }
    #endif

    /// The accent and highlight colors changed in System Settings: resolved
    /// colors are resolved again.
    @objc private func systemColorsDidChange(_ notification: Notification) {
        NGCellPalette.removeAll()
        MetalStyle.removeAll()
        setNeedsMetalFrame()
        layoutVisibleContent()
        headerView.needsDisplay = true
        summaryBar.contentView.needsDisplay = true
    }

    /// Seen again: the frame that waited is drawn.
    @objc private func windowVisibilityDidChange(_ notification: Notification) {
        guard !isWindowUnseen else { return }
        setNeedsMetalFrame()
        setNeedsChromeFrame(headerView)
        setNeedsChromeFrame(summaryBar.contentView)
    }

    @objc private func windowKeyStateDidChange(_ notification: Notification) {
        refreshSelectionAppearance()
    }

    // MARK: Selection

    /// Posted when the selection changed, like
    /// `NSTableView.selectionDidChangeNotification`. The object is the table.
    public static let selectionDidChangeNotification = Notification.Name("NGTableViewSelectionDidChangeNotification")
    /// Posted while the user changes the selection with the mouse, like
    /// `NSTableView.selectionIsChangingNotification`. The object is the table.
    public static let selectionIsChangingNotification = Notification.Name("NGTableViewSelectionIsChangingNotification")

    /// Changes the displayed selection. A change the user makes (`byUser`) is
    /// first put to the delegate, like in `NSTableView`: it may refuse any
    /// change, or pick the rows it accepts from the proposed ones.
    /// `rows` without group headers (negative entries of the display).
    nonisolated static func removingHeaders(from rows: IndexSet, _ display: [Int]) -> IndexSet {
        var result = IndexSet()
        for range in rows.rangeView {
            var start = -1
            for row in range where row < display.count {
                if display[row] >= 0 {
                    if start < 0 { start = row }
                } else if start >= 0 {
                    result.insert(integersIn: start..<row)
                    start = -1
                }
            }
            if start >= 0 { result.insert(integersIn: start..<min(range.upperBound, display.count)) }
        }
        return result
    }

    func setSelection(_ proposed: IndexSet, byUser: Bool = false) {
        // Group headers aren't selected.
        var rows = Self.clamped(proposed, to: numberOfRows)
        if let groupedDisplay { rows = Self.removingHeaders(from: rows, groupedDisplay) }
        // Rows selected: the keyboard leaves the header row it was on.
        if !rows.isEmpty { keyboardGroup = nil }
        guard rows != displaySelection else { return }
        if byUser, let delegate {
            guard delegate.selectionShouldChange(in: self) else { return }
            let accepted = delegate.tableView(self, selectionIndexesForProposedSelection: sourceRows(forDisplayRows: rows))
            rows = displayRows(forSourceRows: accepted)
            guard rows != displaySelection else { return }
        }
        // Without empty selections, the user can't deselect the last row.
        if byUser, !allowsEmptySelection, rows.isEmpty, !displaySelection.isEmpty { return }
        // Rows or columns are selected, not both (one notice for the change).
        if !rows.isEmpty, !selectedColumnIDs.isEmpty { clearColumnSelection() }
        displaySelection = rows
        rememberSelectionIdentity()
        refreshSelectionAppearance()
        // Totals over all rows don't depend on the selection.
        if summaryScope != .allRows {
            updateSummary()
        }
        NSAccessibility.post(element: self, notification: .selectedRowsChanged)
        if selectionTrackingStart != nil {
            postSelectionNotification(Self.selectionIsChangingNotification)
        } else {
            postSelectionNotification(Self.selectionDidChangeNotification)
        }
    }

    /// Tells the delegate and observers about a selection change.
    func postSelectionNotification(_ name: Notification.Name) {
        let notification = Notification(name: name, object: self)
        if name == Self.selectionIsChangingNotification {
            delegate?.tableViewSelectionIsChanging(notification)
        } else {
            delegate?.tableViewSelectionDidChange(notification)
        }
        NotificationCenter.default.post(notification)
    }

    /// Ends a mouse press's selection changes: "did change" if the selection
    /// is no longer what it was when the press began.
    func endSelectionTracking() {
        guard let start = selectionTrackingStart else { return }
        selectionTrackingStart = nil
        if selectedRowIndexes != start {
            postSelectionNotification(Self.selectionDidChangeNotification)
        }
    }

    /// The row the arrow keys move to from `row` by `delta`: the next one the
    /// delegate lets the user select, or `nil` if there is none that way.
    func selectableRow(from row: Int, by delta: Int) -> Int? {
        var candidate = min(max(row + delta, 0), numberOfRows - 1)
        guard delegate != nil || groupedDisplay != nil else { return candidate }
        // Group headers are skipped like rows the delegate rejects.
        while candidate >= 0, candidate < numberOfRows {
            if !isGroupRow(candidate), delegate?.tableView(self, shouldSelectRow: sourceRow(candidate)) ?? true { return candidate }
            candidate += delta > 0 ? 1 : -1
        }
        return nil
    }

    // MARK: Selection (NSTableView API)

    /// The last row selected or added to the selection (a data source row),
    /// or -1 without a selection, like `NSTableView.selectedRow`.
    public var selectedRow: Int {
        if rowUpdateBatch?.displayIsStale == true { syncBatchSelection() }
        if rowUpdateBatch?.displayIsStale == true, let batch = rowUpdateBatch {
            if let cursor = batch.cursor, batch.selection.contains(cursor) { return cursor }
            return batch.selection.last ?? -1
        }
        if let cursorRow, displaySelection.contains(cursorRow) { return sourceRow(cursorRow) }
        return selectedRowIndexes.last ?? -1
    }

    /// Number of selected rows (that the filter shows).
    public var numberOfSelectedRows: Int {
        if rowUpdateBatch?.displayIsStale == true {
            syncBatchSelection()
            return rowUpdateBatch!.selection.count
        }
        if let keptSelection { return keptSelection.count }
        return displaySelection.count
    }

    /// Whether a data source row is selected.
    public func isRowSelected(_ row: Int) -> Bool {
        if rowUpdateBatch?.displayIsStale == true {
            if let bits = rowUpdateBatch!.selectionByHandle {
                guard row >= 0, row < numberOfSourceRows else { return false }
                let handle = Int(rowHandles.handle(at: row))
                return handle < bits.count && bits[handle]
            }
            return rowUpdateBatch!.selection.contains(row)
        }
        return displayRow(forSourceRow: row).map(displaySelection.contains) ?? false
    }

    /// Deselects a data source row.
    public func deselectRow(_ row: Int) {
        if rowUpdateBatch?.displayIsStale == true {
            // Shown at the end of the batch (see `selectRowIndexes`).
            syncBatchSelection()
            rowUpdateBatch!.selection.remove(row)
            rowUpdateBatch!.selectionSetByCalls = true
            return
        }
        guard let displayRow = displayRow(forSourceRow: row), displaySelection.contains(displayRow) else { return }
        setSelection(displaySelection.subtracting([displayRow]))
    }

    /// Deselects all rows (if `allowsEmptySelection`), like `NSTableView`'s action.
    @IBAction public func deselectAll(_ sender: Any?) {
        guard allowsEmptySelection else { return }
        if rowUpdateBatch?.displayIsStale == true {
            rowUpdateBatch!.selectionByHandle = nil
            rowUpdateBatch!.selection = []
            rowUpdateBatch!.selectionSetByCalls = true
            return
        }
        setSelection([])
    }

    /// The content row under a window location (may be out of range).
    /// Measured in the canvas, which is where rows are actually drawn.
    func row(atWindowLocation location: CGPoint) -> Int {
        displayRow(atCanvasY: centerRegion.canvas.convert(location, from: nil).y)
    }

    /// The display row drawn at a y of the canvases (may be out of range):
    /// a floating group header covers the rows under it.
    func displayRow(atCanvasY y: CGFloat) -> Int {
        if let header = floatingGroupHeader(atCanvasY: y) { return header }
        return Int(floor(rowGeometry.position(atY: y)))
    }

    #if os(macOS)
    func rowsMouseDown(_ event: NSEvent, in region: NGRegionView) {
        // Display rows don't mean the data source's rows in a batch that moved them.
        guard !ignoresUserInput else { return }
        isPressingRows = true
        // A header interaction still going on lost its mouse up (e.g. to a menu).
        if isHeaderInteracting {
            cancelHeaderInteraction()
        }
        // A press that lost its mouse up (e.g. to a menu) ends first.
        endSelectionTracking()
        // A click closes open swipe actions.
        closeRowActions()
        sendsClickAction = false
        window?.makeFirstResponder(self)
        tracksDragSelection = false
        // The mouse picks cells: the keyboard's ring goes until the keys move.
        showsFocusRing = false
        keyboardGroup = nil
        var row = row(atWindowLocation: event.locationInWindow)
        // A click on a tree row's triangle collapses or expands it (with
        // Option, the rows within too); the selection stays.
        if let handle = treeDisclosureHit(atWindowLocation: event.locationInWindow, displayRow: row) {
            clickedRow = -1
            clickedColumn = -1
            setTreeRow(handle: handle, expanded: !isTreeRowExpanded(handle: handle),
                       includingChildren: event.modifierFlags.contains(.option), byUser: true)
            return
        }
        // A click on a group header collapses or expands it (with Option, the
        // groups within it too), like in Finder; the selection stays. Every
        // click toggles: quick clicks arrive as double clicks.
        if isGroupRow(row) {
            clickedRow = -1
            clickedColumn = -1
            toggleGroup(atDisplayRow: row, includingChildren: event.modifierFlags.contains(.option))
            return
        }
        // A plain press on a link (a control in a cell) is the control's, not the selection's.
        if beginControlPress(event, displayRow: row, columnID: column(at: event, in: region)?.id) { return }
        let isOnRow = row >= 0 && row < numberOfRows
        let wasSelected = isOnRow && displaySelection.contains(row)
        pendingClickRow = nil
        // Like NSTableView: what was clicked, while the actions run.
        clickedRow = isOnRow ? sourceRow(row) : -1
        clickedColumn = column(at: event, in: region).map { column(withIdentifier: $0.identifier) } ?? -1

        let modifiers = event.modifierFlags
        // Fast Command- or Shift-clicks arrive as double clicks; they still change
        // the selection. Only a plain double click sends the double action
        // (below the rows too, with clickedRow -1, like NSTableView).
        // The cell clicked takes the keyboard's focus (navigation by cell).
        let clickedColumnID = clickedColumn >= 0 && clickedColumn < tableColumns.count ? tableColumns[clickedColumn].id : nil
        if navigatesByCell, isOnRow, let clickedColumnID {
            // Shift-click: a range of cells from the focused one.
            if modifiers.contains(.shift), focusedCell != nil {
                extendCellRange(toDisplayRow: row, columnID: clickedColumnID)
                tracksDragSelection = true
                return
            }
            focusedCell = NGCellPosition(row: sourceRow(row), columnID: clickedColumnID)
            selectedCellRange = nil
        }
        // A click on a check box toggles it (the row is selected as well);
        // quick clicks toggle again rather than editing.
        let clickedRef = isOnRow ? rowRef(ofRow: sourceRow(row)) : nil
        let toggledCheckBox = isOnRow && modifiers.isDisjoint(with: [.command, .shift, .control]) && clickedColumnID.map {
            checkBoxHit(atWindowLocation: event.locationInWindow, row: sourceRow(row), columnID: $0)
                && toggleCheckBox(row: sourceRow(row), columnID: $0)
        } == true
        // Toggling may move the record (sorted by the column) or hide it
        // (filtered by it): the row selected is where it is now.
        if toggledCheckBox, let clickedRef {
            guard let moved = displayRow(forSourceRow: self.row(of: clickedRef)) else { return }
            row = moved
        }
        if event.clickCount == 2, !toggledCheckBox, modifiers.isDisjoint(with: [.command, .shift]) {
            // A double click edits an editable cell, like NSTableView.
            if isOnRow, let clickedColumnID, editCell(row: sourceRow(row), columnID: clickedColumnID) { return }
            sendAction(doubleAction)
            return
        }

        // Until the mouse is released, changes are "is changing".
        selectionTrackingStart = selectedRowIndexes
        sendsClickAction = true
        guard isOnRow else {
            if modifiers.isDisjoint(with: [.command, .shift]) {
                setSelection([], byUser: true)
                // Below the rows: no cell keeps the focus either.
                focusedCell = nil
                selectedCellRange = nil
            }
            return
        }

        // Asked once per press (the data source makes a pasteboard writer).
        let isDraggable = canDragRow(displayRow: row)
        if allowsMultipleSelection, modifiers.contains(.command) {
            var rows = displaySelection
            let selects = !rows.contains(row)
            if selects { rows.insert(row) } else { rows.remove(row) }
            // Dragging on adds (or removes) rows without touching the rest.
            dragSelectionBase = displaySelection
            dragSelectionAdds = selects
            anchorRow = row
            setSelection(rows, byUser: true)
        } else if allowsMultipleSelection, modifiers.contains(.shift), let anchorRow {
            dragSelectionBase = []
            dragSelectionAdds = true
            setSelection(IndexSet(integersIn: min(anchorRow, row)...max(anchorRow, row)), byUser: true)
        } else if allowsMultipleSelection, wasSelected, displaySelection.count > 1, isDraggable {
            // One of several selected rows: they may be dragged together; a
            // click without dragging selects only it on mouse up.
            dragSelectionBase = []
            dragSelectionAdds = true
            anchorRow = row
            pendingClickRow = rowRef(ofRow: sourceRow(row))
        } else {
            dragSelectionBase = []
            dragSelectionAdds = true
            anchorRow = row
            setSelection([row], byUser: true)
        }
        cursorRow = row
        // A column of pop-up choices that opens on a click: the row is selected, and its menu opens.
        if event.clickCount == 1, modifiers.isDisjoint(with: [.command, .shift, .control]), let clickedColumnID,
           let column = columnLayout.columnsByID[clickedColumnID], column.opensChoicesOnClick, Self.showsChoiceChevron(column),
           canEdit(row: sourceRow(row), columnID: clickedColumnID) {
            sendsClickAction = false
            endSelectionTracking()
            _ = showChoiceMenu(row: sourceRow(row), column: column)
            return
        }
        tracksDragSelection = true
        notePressForRowDrag(event, displayRow: row, wasSelected: wasSelected, isDraggable: isDraggable)
    }
    #endif

    #if os(macOS)
    /// Sends an action message to `target` (or along the responder chain).
    private func sendAction(_ action: Selector?) {
        guard let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
    #endif

    #if os(macOS)
    func rowsMouseDragged(_ event: NSEvent) {
        if dragControlPress(event) { return }
        // Draggable rows drag instead of extending the selection.
        if !ignoresUserInput, dragRowsIfNeeded(event) { return }
        guard !ignoresUserInput, tracksDragSelection, allowsMultipleSelection, anchorRow != nil, numberOfRows > 0 else { return }
        dragSelectionLocation = event.locationInWindow
        extendDragSelection()
        // Past the top or bottom of the visible rows, keep scrolling on every
        // frame even while the mouse stands still, like NSTableView.
        if dragSelectionOverflow() != 0 {
            if dragSelectionLink == nil {
                let link = displayLink(target: self, selector: #selector(stepDragSelectionScroll(_:)))
                link.add(to: .main, forMode: .common)
                dragSelectionLink = link
            }
        } else {
            stopDragSelectionScroll()
        }
    }
    #endif

    #if os(macOS)
    func rowsMouseUp(_ event: NSEvent) {
        defer { isPressingRows = false }
        if endControlPress(event) { return }
        rowDragPress = nil
        // (The record may have moved since the press: found where it is now.)
        if let ref = pendingClickRow.take(), !ignoresUserInput, let row = displayRow(forSourceRow: row(of: ref)) {
            setSelection([row], byUser: true)
        }
        tracksDragSelection = false
        stopDragSelectionScroll()
        dragSelectionLocation = nil
        endSelectionTracking()
        // Like NSTableView: a click sends the action once the mouse is released.
        if sendsClickAction {
            sendsClickAction = false
            // Not with a batch that moved rows open: `clickedRow` means another record.
            if !ignoresUserInput { sendAction(action) }
        }
    }
    #endif

    /// How far the dragging pointer is above (negative) or below (positive) the visible rows.
    private func dragSelectionOverflow() -> CGFloat {
        guard let location = dragSelectionLocation else { return 0 }
        let y = centerRegion.convert(location, from: nil).y - layoutMetrics.headerHeight
        let visibleHeight = layoutMetrics.bodyHeight - layoutMetrics.bottomInset
        if y < 0 { return y }
        if y > visibleHeight { return y - visibleHeight }
        return 0
    }

    private func extendDragSelection() {
        guard let anchorRow, let location = dragSelectionLocation, numberOfRows > 0 else { return }
        let row = min(max(row(atWindowLocation: location), 0), numberOfRows - 1)
        // With navigation by cell, dragging makes a range of cells.
        if navigatesByCell, focusedCell != nil, let columnID = columnID(atWindowLocation: location) ?? selectedCellRange?.end.columnID {
            if !isGroupRow(row) { extendCellRange(toDisplayRow: row, columnID: columnID) }
            return
        }
        let range = IndexSet(integersIn: min(anchorRow, row)...max(anchorRow, row))
        setSelection(dragSelectionAdds ? dragSelectionBase.union(range) : dragSelectionBase.subtracting(range), byUser: true)
        cursorRow = row
    }

    #if os(macOS)
    @objc private func stepDragSelectionScroll(_ link: CADisplayLink) {
        let overflow = dragSelectionOverflow()
        guard overflow != 0, NSEvent.pressedMouseButtons & 1 != 0 else {
            stopDragSelectionScroll()
            return
        }
        // Speed grows with the distance past the edge (points per second).
        let speed = min(abs(overflow) * 12 + 120, 3000)
        let elapsed = min(max(link.targetTimestamp - link.timestamp, 1.0 / 120), 1.0 / 30)
        let step = (overflow < 0 ? -speed : speed) * elapsed
        setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y + step))
        extendDragSelection()
    }
    #endif

    func stopDragSelectionScroll() {
        dragSelectionLink?.invalidate()
        dragSelectionLink = nil
    }

    #if os(macOS)
    func column(at event: NSEvent, in region: NGRegionView) -> NGTableColumn? {
        // Canvas x is the columns' own coordinate space (document x for the center).
        let x = Double(region.canvas.convert(event.locationInWindow, from: nil).x)
        return geometry[region.pin].column(atX: x)?.column
    }
    #endif

    // MARK: Columns and hit testing (NSTableView API)

    /// Every leaf column, hidden ones included, like `NSTableView.tableColumns`,
    /// in the order of `columns` (the user's moves change it; frozen columns
    /// show in their region whatever their place here). Column indexes of the
    /// API refer to it.
    public var tableColumns: [NGTableColumn] {
        // Kept until `columns` change: apps ask for it (and `numberOfColumns`)
        // with every targeted update.
        if let cachedTableColumns { return cachedTableColumns }
        let all = columns.flatMap(\.leafColumns)
        cachedTableColumns = all
        return all
    }

    /// Number of leaf columns, hidden ones included.
    public var numberOfColumns: Int { tableColumns.count }

    #if os(macOS)
    /// The column with an identifier, like `NSTableView`'s.
    public func tableColumn(withIdentifier identifier: NSUserInterfaceItemIdentifier) -> NGTableColumn? {
        tableColumns.first { $0.id == identifier.rawValue }
    }
    #endif

    #if os(macOS)
    /// The index in `tableColumns` of the column with an identifier, or -1.
    public func column(withIdentifier identifier: NSUserInterfaceItemIdentifier) -> Int {
        tableColumns.firstIndex { $0.id == identifier.rawValue } ?? -1
    }
    #endif

    /// The data source row at a point in the table's coordinates, or -1 (in
    /// the header or summary row, below the last row, or outside), like
    /// `NSTableView.row(at:)`.
    public func row(at point: CGPoint) -> Int {
        let metrics = layoutMetrics
        guard rowHeight > 0, bounds.contains(point), point.y >= metrics.headerHeight,
              point.y < bounds.height - metrics.summaryHeight else { return -1 }
        let row = displayRow(atCanvasY: centerRegion.canvas.convert(point, from: self).y)
        return row >= 0 && row < numberOfRows ? sourceRow(row) : -1
    }

    /// The index in `tableColumns` of the column at a point in the table's
    /// coordinates (rows or header), or -1, like `NSTableView.column(at:)`.
    public func column(at point: CGPoint) -> Int {
        guard bounds.contains(point), let region = regions.first(where: { !$0.isHidden && $0.frame.contains(point) }) else {
            return -1
        }
        let x = Double(region.canvas.convert(point, from: self).x)
        guard let column = geometry[region.pin].column(atX: x)?.column else { return -1 }
        return tableColumns.firstIndex { $0.id == column.id } ?? -1
    }

    // MARK: Copy

    /// Copies the selected rows as tab-separated text (in the order shown,
    /// visible columns in display order, values as displayed), which pastes into Numbers and Excel as cells.
    /// Selections of more than `synchronousCopyLimit` values are read in
    /// slices and formatted on all cores: the text reaches the pasteboard a
    /// moment later (`isCopying`), and the app stays responsive.
    #if os(macOS)
    @IBAction public func copy(_ sender: Any?) {
        copySelection()
    }
    #else
    public override func copy(_ sender: Any?) {
        copySelection()
    }
    #endif

    func copySelection() {
        guard !ignoresUserInput else { return }
        // A range of cells (or the focused cell) copies its block; a large
        // one in the background, like rows.
        if let block = cellBlockToCopy() {
            guard block.rows.count * max(1, block.columns.count) > synchronousCopyLimit else {
                cancelCopy()
                if let text = copyTextOfCellRange() { putOnPasteboard(text) }
                return
            }
            copyInBackground(columns: block.columns) { $0.rowHandles.refs(atIndexes: $0.cellBlockToCopy()?.rows ?? []) }
            return
        }
        guard !displaySelection.isEmpty else { return }
        let rows = selectedRowIndexes
        let columns = columnLayout.allColumns
        guard rows.count * max(1, columns.count) > synchronousCopyLimit else {
            cancelCopy()
            putOnPasteboard(copyText(forRows: rows))
            return
        }
        copyInBackground(columns: columns) { $0.rowHandles.refs(atIndexes: $0.inDisplayOrder($0.selectedRowIndexes)) }
    }

    private func putOnPasteboard(_ text: String) {
        let pasteboard = copyPasteboard
        #if os(macOS)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(text, forType: .tabularText)
        #else
        pasteboard.string = text
        #endif
    }

    /// Reads the values on the main actor (the data source lives there) in
    /// slices of a few milliseconds, then formats them on all cores. Rows
    /// are followed by reference (`NGRowRef`), so rows that a live feed moves
    /// meanwhile are still the selected records; removed ones are left out.
    private func copyInBackground(columns: [NGTableColumn], rows: @escaping (NGTableView) -> [NGRowRef]) {
        cancelCopy()
        let formats = columns.map(\.format)
        // Number styles made once on the main actor; the cores format with copies.
        let styles = formats.map { NGFormatIDs.numberStyle(of: $0, locale: locale) }
        let textLocale = formattingLocale
        isCopying = true
        copyGeneration += 1
        let generation = copyGeneration
        copyTask = Task { [weak self] in
            guard let values = await self?.readValues(columns: columns, rows: rows) else {
                // Cancelled by a newer copy: that one is copying now.
                if let table = self, table.copyGeneration == generation {
                    table.copyTask = nil
                    table.isCopying = false
                }
                return
            }
            let text = await Task.detached(priority: .userInitiated) {
                Self.copyText(of: values, columnCount: columns.count, formats: formats, styles: styles, locale: textLocale)
            }.value
            guard !Task.isCancelled, let table = self, table.copyGeneration == generation else { return }
            table.putOnPasteboard(text)
            table.copyTask = nil
            table.isCopying = false
        }
    }

    /// The values of some rows' cells, row after row, read on the main actor
    /// in slices of a few milliseconds (for Copy). `nil` if the task is
    /// cancelled or the data source goes. See `readValues(columns:rows:chunkRows:into:)`.
    func readValues(columns: [NGTableColumn], rows: (NGTableView) -> [NGRowRef]) async -> [NGCellValue]? {
        var values: [NGCellValue] = []
        let read = await readValues(columns: columns, rows: rows, chunkRows: .max) { chunk in
            switch chunk {
            case .restart: values = []
            case .values(let chunk): if values.isEmpty { values = chunk } else { values += chunk }
            }
            return true
        }
        return read ? values : nil
    }

    /// The values of some rows' cells, row after row, read on the main actor
    /// in slices of a few milliseconds and handed on in chunks of
    /// `chunkRows` rows (for Export, which writes one while the next is
    /// read). Rows are kept by reference (`rows` gives them in the order to
    /// read), so a live feed may move them
    /// meanwhile and removed ones are left out. If the table reloads its
    /// data in the meantime (the records may be others), it starts over
    /// (`.restart`) with the rows `rows` gives, up to three times, then
    /// reads them all at once. `false` if the task is cancelled, the data
    /// source goes, or `handOn` says to stop.
    func readValues(columns: [NGTableColumn], rows: (NGTableView) -> [NGRowRef], chunkRows: Int,
                    into handOn: (NGReadChunk) async -> Bool) async -> Bool {
        var attempts = 0
        start: while true {
            attempts += 1
            if attempts > 1 { guard await handOn(.restart) else { return false } }
            let epoch = rowHandles.epoch
            let refs = rows(self)
            var values: [NGCellValue] = []
            values.reserveCapacity(min(refs.count, chunkRows) * columns.count)
            var next = 0
            var rowsInChunk = 0
            while next < refs.count {
                guard !Task.isCancelled, let dataSource else { return false }
                if rowHandles.epoch != epoch {
                    if attempts < 3 { continue start }
                    // Reloaded again and again: the rows are read at once,
                    // without a turn in which another reload could come.
                    guard await handOn(.restart) else { return false }
                    var values: [NGCellValue] = []
                    for ref in rows(self) {
                        let row = row(of: ref)
                        guard row >= 0 else { continue }
                        for column in columns { values.append(dataSource.tableView(self, valueFor: column, row: row)) }
                    }
                    return await handOn(.values(consume values))
                }
                let deadline = NGBackgroundSlices.deadline()
                while next < refs.count, rowsInChunk < chunkRows, ContinuousClock.now < deadline {
                    let end = min(refs.count, next + min(256, chunkRows - rowsInChunk))
                    for index in next..<end {
                        let row = row(of: refs[index])
                        guard row >= 0 else { continue }   // Removed meanwhile.
                        for column in columns { values.append(dataSource.tableView(self, valueFor: column, row: row)) }
                    }
                    rowsInChunk += end - next
                    next = end
                }
                if rowsInChunk == chunkRows, next < refs.count {
                    // Moved on: the chunk is freed where it's written, not here.
                    guard await handOn(.values(consume values)) else { return false }
                    values = []
                    values.reserveCapacity(min(refs.count - next, chunkRows) * columns.count)
                    rowsInChunk = 0
                }
                if next < refs.count { await NGBackgroundSlices.nextSlice() }
            }
            return await handOn(.values(consume values))
        }
    }

    func cancelCopy() {
        copyTask?.cancel()
        copyTask = nil
        isCopying = false
    }

    /// Tab-separated text of values read row after row, formatted in chunks
    /// of rows on all cores and joined.
    private nonisolated static func copyText(of values: [NGCellValue], columnCount: Int, formats: [NGValueFormat],
                                             styles: [NGNumberStyle], locale: Locale) -> String {
        guard columnCount > 0, values.count >= columnCount else { return "" }
        let rowCount = values.count / columnCount
        let chunkCount = max(1, min(rowCount / 1024, ProcessInfo.processInfo.activeProcessorCount * 4))
        var chunks = [String](repeating: "", count: chunkCount)
        chunks.withUnsafeMutableBufferPointer { buffer in
            let output = NGUncheckedSendable(buffer)
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let rows = (rowCount * chunk / chunkCount)..<(rowCount * (chunk + 1) / chunkCount)
                var text = ""
                for row in rows {
                    if row > rows.lowerBound { text.append("\n") }
                    for column in 0..<columnCount {
                        if column > 0 { text.append("\t") }
                        let value = values[row * columnCount + column]
                        let string: String
                        if case .number(let number) = value {
                            string = styles[column].string(for: number)
                        } else {
                            string = formats[column].string(for: value, locale: locale)
                        }
                        appendCellText(string, to: &text)
                    }
                }
                output.value[chunk] = text
            }
        }
        // Every chunk has rows (at least 1,024 each, or one chunk).
        return chunks.joined(separator: "\n")
    }

    /// Tab-separated text of data source rows, as `copy(_:)` puts on the
    /// pasteboard (rows in the order shown, visible columns in display order,
    /// values as displayed).
    public func copyText(forRows rows: IndexSet) -> String {
        guard let dataSource else { return "" }
        let rows = inDisplayOrder(rows)
        let columns = columnLayout.allColumns
        // One string built in loops: copying all of 200,000 rows mapped and
        // joined arrays and searched every value twice through Foundation.
        var text = ""
        var isFirst = true
        for row in rows {
            if !isFirst { text.append("\n") }
            isFirst = false
            for (index, column) in columns.enumerated() {
                if index > 0 { text.append("\t") }
                Self.appendCellText(NGFormatIDs.string(for: dataSource.tableView(self, valueFor: column, row: row), format: column.format,
                                                         locale: locale),
                                    to: &text)
            }
        }
        return text
    }

    /// A value for copied rows: tabs and line breaks (also a carriage
    /// return) would split it into several cells, they become spaces.
    nonisolated static func appendCellText(_ value: String, to text: inout String) {
        guard value.utf8.contains(where: { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) else {
            text.append(value)
            return
        }
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            scalars.append(scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D ? " " : scalar)
        }
        text.append(String(scalars))
    }
}
#endif
