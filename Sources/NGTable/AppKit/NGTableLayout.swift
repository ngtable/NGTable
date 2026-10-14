#if os(macOS)
import AppKit

// Layout of the table (`NGTableView.layout()`): the header, the frozen and
// scrolling regions, the summary bar and the scrollers are placed in one pass
// so they never drift apart. Also the screen's pixel density and appearance
// changes, rebuilding the columns after changes, and saving and restoring
// their layout (`autosaveName`).

extension NGTableView {
    // MARK: Layout

    /// Sizes derived from the bounds, columns, rows and scroller style.
    struct LayoutMetrics {
        var headerHeight: CGFloat = 0
        var summaryHeight: CGFloat = 0
        var leadingWidth: CGFloat = 0
        var trailingWidth: CGFloat = 0
        /// Space taken by a legacy (always visible) vertical scroller.
        var verticalScrollerReserve: CGFloat = 0
        /// Space taken by a legacy horizontal scroller above the summary row.
        var horizontalScrollerReserve: CGFloat = 0
        /// Viewport x of the trailing frozen region (at the left, right to left).
        var trailingX: CGFloat = 0
        /// Viewport x of the leading frozen region (at the right, right to left)
        /// and of the scrolling region.
        var leadingX: CGFloat = 0
        var centerX: CGFloat = 0
        /// Visible width of the scrolling columns.
        var centerWidth: CGFloat = 0
        /// Height of the rows area below the header (rows continue under the summary bar).
        var bodyHeight: CGFloat = 0
        /// Rows area covered at the bottom (summary bar and legacy horizontal scroller).
        var bottomInset: CGFloat = 0
        var contentHeight: CGFloat = 0
        var maxOffset = CGPoint.zero
    }

    var headerHeight: CGFloat {
        guard showsGrid, !hidesHeader else { return 0 }
        return headerRowHeight + (columnLayout.hasGroups ? groupHeaderHeight : 0)
    }

    /// Device pixels per point of the screen the table is on.
    var displayScale: CGFloat {
        scaleForTesting ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Width of separator lines: one device pixel, like system separators.
    var hairline: CGFloat {
        1 / displayScale
    }

    /// Rounds a coordinate to the nearest device pixel.
    func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = 1 / hairline
        return (value * scale).rounded() / scale
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutMetalLayer()
        // Hairlines and glyphs depend on the screen's pixel density.
        setNeedsMetalFrame()
        layoutChromeSurface(of: headerView)
        layoutChromeSurface(of: summaryBar.contentView)
        needsLayout = true
        headerView.needsDisplay = true
    }

    /// Dynamic colors are resolved for the appearance a frame is drawn in, so
    /// light/dark and accent changes draw a new frame.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The same rows and cells in other colors.
        setNeedsMetalFrame()
        setNeedsChromeFrame(headerView)
        setNeedsChromeFrame(summaryBar.contentView)
        layoutVisibleContent()
    }

    func computeLayoutMetrics() -> LayoutMetrics {
        var metrics = LayoutMetrics()
        metrics.headerHeight = headerHeight
        metrics.summaryHeight = showsSummaryBar ? summaryRowHeight : 0
        metrics.leadingWidth = CGFloat(geometry.leading.width)
        metrics.trailingWidth = CGFloat(geometry.trailing.width)
        metrics.bodyHeight = max(0, bounds.height - metrics.headerHeight)
        metrics.contentHeight = rowGeometry.totalHeight
        let centerContentWidth = CGFloat(geometry.center.width)

        // Legacy scrollers take space; overlay scrollers float over the content.
        if NSScroller.preferredScrollerStyle == .legacy {
            let thickness = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            let fixedWidth = metrics.leadingWidth + metrics.trailingWidth
            var needsVertical = metrics.contentHeight + metrics.summaryHeight > metrics.bodyHeight
            let needsHorizontal = centerContentWidth > bounds.width - fixedWidth - (needsVertical ? thickness : 0)
            if needsHorizontal, !needsVertical {
                needsVertical = metrics.contentHeight + metrics.summaryHeight + thickness > metrics.bodyHeight
            }
            metrics.verticalScrollerReserve = needsVertical ? thickness : 0
            metrics.horizontalScrollerReserve = needsHorizontal ? thickness : 0
        }

        if isRightToLeft {
            // Mirrored: leading columns at the right, trailing ones (and the
            // vertical scroller) at the left.
            metrics.trailingX = metrics.verticalScrollerReserve
            metrics.leadingX = bounds.width - metrics.leadingWidth
            metrics.centerX = metrics.trailingX + metrics.trailingWidth
            metrics.centerWidth = max(0, metrics.leadingX - metrics.centerX)
        } else {
            metrics.trailingX = bounds.width - metrics.verticalScrollerReserve - metrics.trailingWidth
            metrics.leadingX = 0
            metrics.centerX = metrics.leadingWidth
            metrics.centerWidth = max(0, metrics.trailingX - metrics.leadingWidth)
        }
        metrics.bottomInset = metrics.summaryHeight + metrics.horizontalScrollerReserve
        metrics.maxOffset = CGPoint(
            x: max(0, centerContentWidth - metrics.centerWidth),
            y: max(0, metrics.contentHeight + metrics.bottomInset - metrics.bodyHeight)
        )
        return metrics
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        isInLayoutPass = true
        passIsRightToLeft = isRightToLeft
        defer {
            isInLayoutPass = false
            passIsRightToLeft = nil
        }
        // A new size is drawn in this pass, not when the run loop next waits:
        // window animations (zoom, tiling) resize step by step without
        // returning to the run loop, and Core Animation would stretch the old
        // frame to the new size meanwhile.
        let resized = layoutMetalLayer()
        defer { if resized { drawMetalFrameIfNeeded() } }
        endColumnDragForResize()
        autoresizeColumns(toWidth: bounds.width)
        // Rows of wrapped text in view get their heights before the content
        // height is known.
        measureRowsInView()
        var metrics = computeLayoutMetrics()
        // Right to left, narrower scrolling columns start at the right: mirrored
        // within the visible width.
        if isRightToLeft, metrics.centerWidth != mirroredCenterSpan {
            mirroredCenterSpan = metrics.centerWidth
            updateGeometry()
            metrics = computeLayoutMetrics()
        }
        layoutMetrics = metrics
        let top = metrics.headerHeight

        // Without any data only the empty state shows: no header, stripes or summary.
        let showsGrid = showsGrid
        headerView.isHidden = !showsGrid || hidesHeader
        headerBackground.isHidden = !showsGrid || hidesHeader
        headerView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        headerBackground.frame = headerView.frame
        // Regions span the full height so rows can scroll underneath the header.
        leadingRegion.frame = NSRect(x: metrics.leadingX, y: 0, width: metrics.leadingWidth, height: bounds.height)
        centerRegion.frame = NSRect(x: metrics.centerX, y: 0, width: metrics.centerWidth, height: bounds.height)
        trailingRegion.frame = NSRect(x: metrics.trailingX, y: 0, width: metrics.trailingWidth, height: bounds.height)
        leadingRegion.isHidden = !showsGrid || geometry.leading.isEmpty
        centerRegion.isHidden = !showsGrid
        trailingRegion.isHidden = !showsGrid || geometry.trailing.isEmpty

        leadingSeparator.isHidden = leadingRegion.isHidden
        // Between the frozen regions and the scrolling one.
        let leadingEdge = isRightToLeft ? metrics.leadingX : metrics.leadingWidth - hairline
        let trailingEdge = isRightToLeft ? metrics.trailingX + metrics.trailingWidth - hairline : metrics.trailingX
        leadingSeparator.frame = NSRect(x: leadingEdge, y: top, width: hairline, height: metrics.bodyHeight)
        trailingSeparator.isHidden = trailingRegion.isHidden
        trailingSeparator.frame = NSRect(x: trailingEdge, y: top, width: hairline, height: metrics.bodyHeight)

        summaryBar.isHidden = !showsSummaryBar
        summaryBar.frame = NSRect(x: 0, y: bounds.height - metrics.summaryHeight, width: bounds.width, height: metrics.summaryHeight)
        layoutSummaryProgress()
        layoutDataUpdateOverlay()

        layoutScrollers(metrics)
        layoutEmptyState(metrics)
        layoutSummaryProgress()

        // Canvases cover the whole content so hit testing reaches every cell.
        let canvasHeight = max(metrics.contentHeight, metrics.bodyHeight)
        leadingRegion.canvas.setFrameSize(NSSize(width: metrics.leadingWidth, height: canvasHeight))
        centerRegion.canvas.setFrameSize(NSSize(width: centerCanvasWidth, height: canvasHeight))
        trailingRegion.canvas.setFrameSize(NSSize(width: metrics.trailingWidth, height: canvasHeight))
        layoutGridLines(height: canvasHeight)

        // The header and summary (and the header's cursor areas) only when
        // what they show moved: a batch of cells lays the rows out, not them.
        let chrome = chromeLayoutKey(metrics)
        let chromeMoved = chrome != lastChromeLayoutKey
        lastChromeLayoutKey = chrome
        if keepsVisibleRowsInNextLayout, !chromeMoved {
            // The rows in view stay: the canvases follow a clamped offset, and
            // only rows coming into view are placed (like a scroll step).
            keepsVisibleRowsInNextLayout = false
            let offset = contentOffset
            setContentOffset(offset)
            if contentOffset == offset { applyScrollPosition() }
        } else {
            keepsVisibleRowsInNextLayout = false
            setContentOffset(contentOffset, forceLayout: true, chromeMoved: chromeMoved)
        }
        if chromeMoved {
            headerView.needsDisplay = true
            summaryBar.contentView.needsDisplay = true
        }
    }

    /// What the header and summary are laid out by: sizes, scale, the
    /// horizontal offset and every column's place.
    private func chromeLayoutKey(_ metrics: LayoutMetrics) -> Int {
        var hasher = Hasher()
        hasher.combine(bounds.width)
        hasher.combine(bounds.height)
        hasher.combine(displayScale)
        hasher.combine(metrics.headerHeight)
        hasher.combine(metrics.summaryHeight)
        hasher.combine(contentOffset.x)
        hasher.combine(tableColumnsVersion)
        for region in [geometry.leading, geometry.center, geometry.trailing] {
            for frame in region.columns {
                hasher.combine(frame.column.id)
                hasher.combine(frame.x)
                hasher.combine(frame.width)
            }
        }
        return hasher.finalize()
    }

    /// The center canvas uses document x (center columns start after the leading
    /// region) and is at least as wide as the viewport, so stripes fill it.
    var centerCanvasWidth: CGFloat {
        layoutMetrics.leadingWidth + max(CGFloat(geometry.center.width), layoutMetrics.centerWidth)
    }

    func rebuildColumns() {
        columnLayout = NGColumnLayout(items: columns, hiddenIDs: hiddenColumnIDs)
        columnFormatIDs = []
        // Formats may have changed what filtered values display as.
        columnFilterPasses = [:]
        // Hidden columns keep their width for when they are shown again.
        let columnIDs = Set(columns.flatMap(\.leafColumns).map(\.id))
        // The same columns defined again (a title or format changed): the rows stay where they are.
        let sameColumns = columnIDs == definedColumnIDs
        definedColumnIDs = columnIDs
        columnWidths = columnWidths.filter { columnIDs.contains($0.key) }
        updateGeometry()
        // Rows cache their cells in column order.
        accessibilityRowCache.removeAll()
        accessibilityHeaderCache.removeAll()
        accessibilityColumnCache.removeAll()
        NSAccessibility.post(element: self, notification: .layoutChanged)
        if isChangingColumnVisibility {
            // Keep the scroll position, sort and selection; only columns that
            // become visible need their summary computed. Group headers show
            // the subtotals of the shown columns (their calculators stay).
            addMissingSummaryCalculators()
            previousGroupSubtotals.merge(groupSubtotals) { _, new in new }
            groupSubtotals = [:]
            updateSummary()
            // A search looks at the shown columns, which just changed.
            if let rowFilter, !rowFilter.searchWords.isEmpty, rowFilter.columnIDs == nil {
                applyRowFilter()
            }
        }
        if isReorderingColumns || isChangingColumnVisibility {
            needsLayout = true
            layoutSubtreeIfNeeded()
            headerView.needsDisplay = true
            summaryBar.contentView.needsDisplay = true
            return
        }
        // Sorts by columns that are still defined stay (the data is still
        // sorted); those of removed columns go, and the data source sorts again.
        let sortKeys = Set(columns.flatMap(\.leafColumns).compactMap { $0.sortDescriptorPrototype?.key })
        let keptSorts = sortDescriptors.filter { $0.key.map(sortKeys.contains) ?? false }
        if keptSorts.count != sortDescriptors.count {
            // Not saved: the saved customizations are applied to the new
            // definition next (saving now would overwrite them with its defaults).
            let wasApplying = isApplyingLayoutState
            isApplyingLayoutState = true
            sortDescriptors = keptSorts
            isApplyingLayoutState = wasApplying
        }
        let scrollsBack = !sameColumns && contentOffset != .zero
        if !sameColumns {
            contentOffset = .zero
            stopElasticAnimation()
            verticalOverscroll = 0
            rawVerticalOverscroll = 0
        }
        reloadData()
        if scrollsBack { postDidScroll() }
    }

    private var autosaveKey: String? {
        autosaveName.map { "NGTableView Columns \($0)" }
    }

    var autosavedLayoutState: NGColumnLayoutState? {
        guard let autosaveKey, let data = UserDefaults.standard.data(forKey: autosaveKey) else { return nil }
        return try? PropertyListDecoder().decode(NGColumnLayoutState.self, from: data)
    }

    /// Saves the column customizations after the user changed them.
    /// Saves the layout once this turn of the run loop is over (a live
    /// resize: when it ends), for changes that come in many steps: widths
    /// set in code or by autoresizing, columns hidden in code. A resize by
    /// the user saves when the mouse goes up.
    func scheduleLayoutAutosave() {
        guard autosaveName != nil, !isApplyingLayoutState, activeColumnResize == nil else { return }
        layoutAutosavePending = true
        guard !inLiveResize, !layoutAutosaveScheduled else { return }
        layoutAutosaveScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flushLayoutAutosave() }
        }
    }

    func flushLayoutAutosave() {
        layoutAutosaveScheduled = false
        guard layoutAutosavePending, !inLiveResize else { return }
        layoutAutosavePending = false
        autosaveLayoutState()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        flushLayoutAutosave()
    }

    func autosaveLayoutState() {
        guard let autosaveKey, let data = try? PropertyListEncoder().encode(columnLayoutState) else { return }
        UserDefaults.standard.set(data, forKey: autosaveKey)
    }

    func applyLayoutState(_ state: NGColumnLayoutState) {
        guard !columns.isEmpty else { return }
        var state = state.restricted(to: columns)
        // The state's pins, over the definition's: pins the user made since
        // are undone, and what is shown is what is saved.
        if let pins = state.pins {
            userPins = pins
        } else if let legacy = state.legacyPins {
            userPins = legacy.filter { id, pin in definitionPins[id].map { $0 != pin } ?? false }
        } else {
            userPins = [:]
        }
        state.pins = userPins
        let defined = columns.map { $0.withPin(definitionPins[$0.id] ?? $0.pin) }
        isApplyingLayoutState = true
        columns = state.applyingOrder(to: defined)
        hiddenColumnIDs = state.hiddenIDs
        columnWidths = state.widths
        isApplyingLayoutState = false
        // Keeps the scroll position, sort and selection like a visibility change.
        isChangingColumnVisibility = true
        rebuildColumns()
        isChangingColumnVisibility = false
        // A saved sort replaces the current one (the data source sorts by it);
        // a state without one keeps it.
        if let sort = state.sortDescriptors {
            isApplyingLayoutState = true
            sortDescriptors = sort
            isApplyingLayoutState = false
        }
        // A saved grouping (of columns still defined), like the sort.
        if let grouping = state.grouping {
            let ids = grouping.filter { id in tableColumns.contains { $0.id == id } }
            if ids != (rowGrouping?.columnIDs ?? []) {
                isApplyingLayoutState = true
                rowGrouping = regrouped(by: ids)
                isApplyingLayoutState = false
            }
        }
        // Saved column filters, like the sort: a state without them keeps the current ones.
        if let filters = state.filters {
            isApplyingLayoutState = true
            columnFilters = filters
            isApplyingLayoutState = false
        }
    }

    /// Applies a new column order coming from a header drag.
    func applyReorderedColumns(_ items: [NGColumnItem]) {
        isReorderingColumns = true
        columns = items
        isReorderingColumns = false
    }
}
#endif
