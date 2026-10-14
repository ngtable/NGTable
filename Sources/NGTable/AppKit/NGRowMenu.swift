#if os(macOS)
import AppKit

/// Context menus for rows. The table only decides which rows a right-click
/// is for; the menu and its actions come from the delegate, or the table's
/// `menu` like in `NSTableView`.
extension NGTableView {
    func rowsMenu(for event: NSEvent, in region: NGRegionView) -> NSMenu? {
        guard !isHeaderInteracting, !ignoresUserInput else { return nil }
        // The menu's tracking swallows the mouse up that would end a drag.
        stopDragSelectionScroll()
        tracksDragSelection = false
        endSelectionTracking()
        let row = row(atWindowLocation: event.locationInWindow)
        return rowsMenu(forDisplayRow: row, column: column(at: event, in: region))
    }

    /// The menu for a display row (out of range: for no row), from the
    /// delegate or the table's `menu`, as a right-click on it opens it.
    func rowsMenu(forDisplayRow row: Int, column: NGTableColumn?) -> NSMenu? {
        // Group headers have the table's own menu, like the summary row.
        if let node = groupNode(atDisplayRow: row) {
            clickedRow = -1
            clickedColumn = -1
            return groupMenu(forNode: node)
        }
        let clicked = row >= 0 && row < numberOfRows ? row : nil
        // Like Finder and Mail: a click inside the selection is for the whole
        // selection, a click on another row only for that row.
        let rows: IndexSet = clicked.map { displaySelection.contains($0) ? displaySelection : [$0] } ?? []
        // The delegate works with data source rows.
        let sourceClicked = clicked.map(sourceRow)
        clickedRow = sourceClicked ?? -1
        clickedColumn = column.map { self.column(withIdentifier: $0.identifier) } ?? -1
        let delegateMenu = delegate?.tableView(self, menuForRows: IndexSet(rows.map(sourceRow)),
                                               clickedRow: sourceClicked, column: clicked == nil ? nil : column)
        guard let menu = delegateMenu ?? self.menu else { return nil }
        if let clicked, !displaySelection.contains(clicked) {
            showMenuOutline(forRow: clicked)
        }
        return menu
    }

    /// The menu VoiceOver's "show menu" opens on a row: the right-click one.
    func accessibilityMenu(forDisplayRow row: Int) -> NSMenu? {
        guard !ignoresUserInput, row >= 0, row < numberOfRows else { return nil }
        return rowsMenu(forDisplayRow: row, column: nil)
    }

    /// Opens a row's menu for VoiceOver, at the row.
    func showAccessibilityMenu(forDisplayRow row: Int) -> Bool {
        guard let menu = accessibilityMenu(forDisplayRow: row) else { return false }
        let frame = convert(NSRect(x: 0, y: rowGeometry.top(of: row), width: 1, height: rowGeometry.height(of: row)), from: centerRegion.canvas)
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX + 20, y: frame.midY), in: self)
        rowsMenuDidClose()
        return true
    }

    func rowsMenuDidClose() {
        menuOutline?.removeFromSuperview()
        menuOutline = nil
        menuOutlineRow = nil
        menuOutlineRef = nil
    }

    /// The row a menu is for, outlined without changing the selection. It
    /// follows its record when the table scrolls or a live sort moves it.
    func showMenuOutline(forRow row: Int) {
        if menuOutlineRow != row || menuOutlineRef == nil {
            let source = sourceRow(row)
            menuOutlineRef = source >= 0 ? rowRef(ofRow: source) : nil
        }
        menuOutlineRow = row
        menuOutline?.isHidden = false
        let outline = menuOutline ?? NGColorView()
        outline.borderColor = .controlAccentColor
        let metrics = layoutMetrics
        let inset = selectionHighlightStyle == .rounded ? NGMetrics.selectionInset : 0
        outline.cornerRadius = selectionHighlightStyle == .rounded ? NGMetrics.selectionCornerRadius : 0
        outline.roundedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let y = pixelAligned(metrics.headerHeight - renderedOffsetY) + rowGeometry.top(of: row)
        // The columns' span, whichever side the frozen regions are on.
        let left = min(metrics.leadingX, metrics.trailingX, metrics.centerX)
        let right = max(metrics.leadingX + metrics.leadingWidth, metrics.trailingX + metrics.trailingWidth,
                        metrics.centerX + metrics.centerWidth)
        outline.frame = NSRect(x: left + inset, y: y, width: max(0, right - left - 2 * inset), height: rowGeometry.height(of: row))
        // Above the rows, below the header and scrollers.
        if outline.superview !== self {
            addSubview(outline, positioned: .below, relativeTo: headerBackground)
        }
        menuOutline = outline
    }
}
#endif
