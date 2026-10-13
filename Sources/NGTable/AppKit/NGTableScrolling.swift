#if os(macOS)
import AppKit

// Scrolling without NSScrollView: scroll events move the table's own
// `contentOffset` (elastic overscroll is in NGElasticScrolling.swift), the
// canvases follow, and the overlay scrollers are laid out and tracked here.
// The header's pointer areas (resize cursors) follow the scrolled columns.

extension NGTableView {
    // MARK: Scrolling

    /// Applies a scroll position. Every region, the header and the summary row
    /// are updated in this single pass.
    /// - Parameter chromeMoved: With `forceLayout`, whether the header and
    ///   summary moved too (a layout pass knows; a batch of cells doesn't).
    func setContentOffset(_ proposed: CGPoint, forceLayout: Bool = false, chromeMoved: Bool = true) {
        let maxOffset = layoutMetrics.maxOffset
        let offset = CGPoint(
            x: min(max(proposed.x, 0), maxOffset.x),
            y: min(max(proposed.y, 0), maxOffset.y)
        )
        guard offset != contentOffset || forceLayout else { return }
        let didScrollHorizontally = offset.x != contentOffset.x
        let didScroll = offset != contentOffset
        contentOffset = offset
        applyScrollPosition(relayoutAll: forceLayout)
        // Told once the rows are laid out at the new position.
        if didScroll { postDidScroll() }

        if didScrollHorizontally || forceLayout && chromeMoved {
            headerView.needsDisplay = true
            summaryBar.contentView.needsDisplay = true
            // Column edges moved: the resize cursor and the tool tip under the
            // pointer follow. Rebuilding cursor areas makes AppKit redo the
            // whole window's, so scrolling does it once it stops.
            if forceLayout {
                updateHeaderPointerAreas()
            } else {
                scheduleHeaderPointerAreasUpdate()
            }
        }
    }

    /// Posted after the scroll position (`contentOffset`) changed, by the
    /// user or in code, with the rows laid out there: what apps observe a
    /// clip view's `boundsDidChangeNotification` for with NSTableView (e.g.
    /// to load the next page when `rowIndexes(in: bounds)` reaches the end).
    /// Not posted for the rubber band past the edges. The object is the table.
    public static let didScrollNotification = Notification.Name("NGTableViewDidScrollNotification")

    func postDidScroll() {
        NotificationCenter.default.post(name: Self.didScrollNotification, object: self)
        if isLiveScrolling { NotificationCenter.default.post(name: Self.didLiveScrollNotification, object: self) }
    }

    // MARK: Live scrolling
    //
    // Like NSScrollView's notifications: a trackpad gesture (or dragging an
    // overlay scroller) starts a live scroll, every step of it is posted,
    // and it ends with the momentum, or with the gesture when none follows.

    /// Posted when the user starts scrolling the table with a gesture or
    /// its scroller, like `NSScrollView.willStartLiveScrollNotification`.
    public static let willStartLiveScrollNotification = Notification.Name("NGTableViewWillStartLiveScrollNotification")
    /// Posted after each step of a live scroll (with `didScrollNotification`),
    /// like `NSScrollView.didLiveScrollNotification`.
    public static let didLiveScrollNotification = Notification.Name("NGTableViewDidLiveScrollNotification")
    /// Posted when a live scroll ended, its momentum too, like
    /// `NSScrollView.didEndLiveScrollNotification`: e.g. to load what came
    /// into view.
    public static let didEndLiveScrollNotification = Notification.Name("NGTableViewDidEndLiveScrollNotification")

    func beginLiveScroll() {
        liveScrollEndGeneration += 1
        guard !isLiveScrolling else { return }
        isLiveScrolling = true
        NotificationCenter.default.post(name: Self.willStartLiveScrollNotification, object: self)
    }

    func endLiveScroll() {
        liveScrollEndGeneration += 1
        guard isLiveScrolling else { return }
        isLiveScrolling = false
        NotificationCenter.default.post(name: Self.didEndLiveScrollNotification, object: self)
    }

    /// A lifted finger ends the live scroll unless momentum follows (it
    /// begins right after).
    private func endLiveScrollUnlessMomentumFollows() {
        liveScrollEndGeneration += 1
        let generation = liveScrollEndGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.liveScrollEndGeneration == generation else { return }
                self.endLiveScroll()
            }
        }
    }

    /// Follows a gesture's phases for the live scroll notifications.
    private func trackLiveScroll(_ event: NSEvent) {
        if event.phase.contains(.began) || event.phase.contains(.changed) && !isLiveScrolling {
            beginLiveScroll()
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            endLiveScrollUnlessMomentumFollows()
        }
        if event.momentumPhase.contains(.began) {
            beginLiveScroll()
        } else if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            endLiveScroll()
        }
    }

    private func scheduleHeaderPointerAreasUpdate() {
        headerPointerAreasGeneration += 1
        let generation = headerPointerAreasGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.headerPointerAreasGeneration == generation else { return }
                self.updateHeaderPointerAreas()
            }
        }
    }

    private func updateHeaderPointerAreas() {
        headerPointerAreasGeneration += 1
        // Interactions that move columns rebuild them when they end.
        if cursorRectsSuspendedWindow == nil {
            window?.invalidateCursorRects(for: headerView)
        }
        headerView.refreshToolTip()
    }

    /// Whether the table is laid out right to left (see `userInterfaceLayoutDirection`).
    var isRightToLeft: Bool {
        if let passIsRightToLeft { return passIsRightToLeft }
        layoutDirectionReads += 1
        return userInterfaceLayoutDirection == .rightToLeft
    }

    /// Runs a pass with the layout direction read once (see `passIsRightToLeft`).
    func withLayoutDirectionFixed<Result>(_ pass: () -> Result) -> Result {
        guard passIsRightToLeft == nil else { return pass() }
        passIsRightToLeft = isRightToLeft
        defer { passIsRightToLeft = nil }
        return pass()
    }

    /// How far the scrolling columns are scrolled from their left end:
    /// `contentOffset.x` (from the leading end) left to right, mirrored right
    /// to left, where the leading end is at the right.
    var physicalOffsetX: CGFloat {
        isRightToLeft ? layoutMetrics.maxOffset.x - contentOffset.x : contentOffset.x
    }

    /// Moves the canvases to the displayed position: the scroll position plus any
    /// elastic vertical overscroll. All regions move together.
    func applyScrollPosition(relayoutAll: Bool = false) {
        // Row 0 starts below the header; rows scrolled past it go underneath.
        // Aligned to device pixels, so text and hairlines stay sharp at
        // fractional trackpad offsets.
        let canvasY = pixelAligned(layoutMetrics.headerHeight - renderedOffsetY)
        let centerOrigin = NSPoint(x: -pixelAligned(layoutMetrics.leadingWidth + physicalOffsetX), y: canvasY)
        // With Metal, the rows are drawn where the canvases now are, on every
        // step that moves them (not only when rows come into view, below).
        if leadingRegion.canvas.frame.minY != canvasY || centerRegion.canvas.frame.origin != centerOrigin {
            setNeedsMetalFrame()
        }
        leadingRegion.canvas.setFrameOrigin(NSPoint(x: 0, y: canvasY))
        centerRegion.canvas.setFrameOrigin(centerOrigin)
        trailingRegion.canvas.setFrameOrigin(NSPoint(x: 0, y: canvasY))
        // Moving the canvases scrolls; cells only change when rows or columns
        // come into or out of view.
        layoutVisibleContent(onlyIfVisibleRangeChanged: !relayoutAll)
        updateScrollers()
        if menuOutlineRow != nil {
            // Where its record is now (gone or hidden: no outline).
            if let ref = menuOutlineRef, let row = displayRow(forSourceRow: row(of: ref)) {
                showMenuOutline(forRow: row)
            } else {
                menuOutline?.isHidden = true
            }
        }
        layoutCellEditor()
        // Open row actions stay with their record (or close when it's not shown).
        if let swipe = rowSwipe, !swipe.isTracking { layoutRowActionButtons() }
        // The rows moved under the pointer.
        updateHoveredCellFromPointer()
    }

    /// The vertical position rows are displayed at, including elastic overscroll.
    var renderedOffsetY: CGFloat {
        contentOffset.y + verticalOverscroll
    }

    public override func scrollWheel(with event: NSEvent) {
        let isGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            scrollAxis = nil
            forwardsScrollGesture = false
            scrollGestureStart = []
        }
        // A gesture on an axis with nothing to scroll goes on to the end of
        // its momentum (a new gesture decides again).
        if isGesture, forwardsScrollGesture {
            super.scrollWheel(with: event)
            return
        }
        // A swipe across a row for its actions.
        if handleRowSwipe(event) { return }
        if isGesture { trackLiveScroll(event) }
        // Scrolling closes open actions.
        if rowSwipe != nil, event.momentumPhase.isEmpty { closeRowActions() }
        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            // Line-based mouse wheels report lines, not points.
            deltaX *= rowHeight
            deltaY *= rowHeight
        }
        // Scrolling only on axes with nothing to scroll scrolls whatever
        // contains the table, like a nested NSScrollView: a short table in a
        // form scrolls the form.
        let maxOffset = layoutMetrics.maxOffset
        func canScroll(_ axis: NSEvent.GestureAxis) -> Bool {
            axis == .horizontal ? maxOffset.x > 0 : maxOffset.y > 0
        }
        if !isGesture, deltaX == 0 || !canScroll(.horizontal), deltaY == 0 || !canScroll(.vertical) {
            super.scrollWheel(with: event)
            return
        }

        // Trackpad gestures (and their momentum) are locked to the axis they start
        // on, like NSScrollView's predominant-axis scrolling. Plain mouse wheels
        // have no phases and scroll freely.
        if isGesture {
            if scrollAxis == nil, deltaX != 0 || deltaY != 0 {
                let axis: NSEvent.GestureAxis = abs(deltaX) > abs(deltaY) ? .horizontal : .vertical
                scrollAxis = axis
                // Vertically, alone in a window, the rows still bounce.
                if !canScroll(axis), axis == .horizontal || enclosingScrollView != nil || !bouncesVertically {
                    // The container gets the gesture from its beginning
                    // (and its live scroll: the table's ends).
                    forwardsScrollGesture = true
                    endLiveScroll()
                    for start in scrollGestureStart { super.scrollWheel(with: start) }
                    scrollGestureStart = []
                    super.scrollWheel(with: event)
                    return
                }
                scrollGestureStart = []
            } else if scrollAxis == nil, !event.phase.isEmpty {
                scrollGestureStart.append(event)
            }
            switch scrollAxis {
            case .horizontal: deltaY = 0
            case .vertical: deltaX = 0
            default: break
            }
        }

        let bounces = bouncesVertically && isGesture
        if bounces {
            handleElasticPhases(of: event)
            // Lifting the finger springs back; its last delta must not pull further.
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                deltaY = 0
            }
        } else if deltaY != 0, verticalOverscroll != 0 || elasticAnimation != nil {
            // A mouse wheel during a bounce: settle at the edge, then scroll.
            stopElasticAnimation()
            rawVerticalOverscroll = 0
            setVerticalOverscroll(0)
        }
        if deltaX != 0 {
            // Content follows the fingers: right to left, the offset grows to the left.
            setContentOffset(CGPoint(x: contentOffset.x + (isRightToLeft ? deltaX : -deltaX), y: contentOffset.y))
            repositionColumnDragAfterScroll()
            revealScroller(.horizontal)
        }
        if deltaY != 0 {
            if bounces {
                scrollVerticallyWithElasticity(by: deltaY, event: event)
            } else {
                setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y - deltaY))
            }
            revealScroller(.vertical)
        }
    }

    // MARK: Scrollers
    //
    // Overlay style (the default on trackpad Macs) uses the table's own
    // NGOverlayScroller, which reveals per axis, fades out and expands on hover.
    // Legacy style ("always show scroll bars") uses standard NSScrollers that are
    // always visible and take up space.

    private var isOverlayStyle: Bool {
        NSScroller.preferredScrollerStyle == .overlay
    }

    func setUpScrollers() {
        for scroller in [verticalScroller, horizontalScroller] {
            scroller.scrollerStyle = .legacy
            scroller.target = self
            scroller.action = #selector(legacyScrollerDidScroll(_:))
            scroller.isEnabled = true
            addSubview(scroller)
        }
        for (scroller, axis) in [(verticalOverlayScroller, NSEvent.GestureAxis.vertical), (horizontalOverlayScroller, .horizontal)] {
            scroller.onScroll = { [weak self] value in
                self?.scrollToFraction(value, along: axis)
            }
            scroller.onPage = { [weak self] direction in
                self?.scrollByPage(CGFloat(direction), along: axis)
            }
            scroller.onInteractionChange = { [weak self, weak scroller] in
                guard let self else { return }
                self.revealScroller(axis)
                // Dragging the scroller is a live scroll too.
                let tracking = scroller?.isTracking ?? false
                if tracking != self.liveScrollByScroller {
                    self.liveScrollByScroller = tracking
                    if tracking { self.beginLiveScroll() } else { self.endLiveScroll() }
                }
            }
            scroller.alphaValue = 0
            scroller.isHidden = true
            addSubview(scroller)
        }
    }

    @objc func preferredScrollerStyleDidChange(_ notification: Notification) {
        for scroller in [verticalOverlayScroller, horizontalOverlayScroller] {
            scroller.isRevealed = false
            scroller.alphaValue = 0
            scroller.isHidden = true
        }
        needsLayout = true
    }

    func layoutScrollers(_ metrics: LayoutMetrics) {
        verticalOverlayScroller.isMirrored = isRightToLeft
        let top = metrics.headerHeight
        let verticalHeight = max(0, metrics.bodyHeight - metrics.bottomInset)
        let summaryTop = bounds.height - metrics.summaryHeight

        let legacyThickness = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        // Right to left, the vertical scroller is at the left edge.
        let rtl = isRightToLeft
        verticalScroller.frame = NSRect(x: rtl ? 0 : bounds.width - legacyThickness, y: top, width: legacyThickness, height: verticalHeight)
        horizontalScroller.frame = NSRect(x: metrics.centerX, y: summaryTop - legacyThickness, width: metrics.centerWidth, height: legacyThickness)

        let overlayThickness = NGOverlayScroller.thickness
        verticalOverlayScroller.frame = NSRect(x: rtl ? 0 : bounds.width - overlayThickness, y: top, width: overlayThickness, height: verticalHeight)
        // Without frozen columns at the vertical scroller's side the horizontal scroller would run under it.
        let reserve = metrics.maxOffset.y > 0 ? overlayThickness : 0
        let overlayStart = rtl ? max(metrics.centerX, reserve) : metrics.centerX
        let overlayEnd = rtl ? metrics.centerX + metrics.centerWidth : min(metrics.centerX + metrics.centerWidth, bounds.width - reserve)
        horizontalOverlayScroller.frame = NSRect(x: overlayStart, y: summaryTop - overlayThickness, width: max(0, overlayEnd - overlayStart), height: overlayThickness)
    }

    private func updateScrollers() {
        let metrics = layoutMetrics
        let visibleHeight = metrics.bodyHeight - metrics.bottomInset
        // While bouncing, the knob shrinks by the overscroll and hugs its edge,
        // like system scrollers.
        let overscroll = abs(verticalOverscroll)
        let verticalProportion = metrics.contentHeight > 0
            ? min(1, max(0, visibleHeight - overscroll) / metrics.contentHeight)
            : 1
        let verticalValue: CGFloat = if verticalOverscroll < 0 {
            0
        } else if verticalOverscroll > 0 {
            1
        } else {
            metrics.maxOffset.y > 0 ? contentOffset.y / metrics.maxOffset.y : 0
        }
        let contentWidth = CGFloat(geometry.center.width)
        let horizontalProportion = contentWidth > 0 ? min(1, metrics.centerWidth / contentWidth) : 1
        let horizontalValue = metrics.maxOffset.x > 0 ? physicalOffsetX / metrics.maxOffset.x : 0

        verticalScroller.knobProportion = verticalProportion
        verticalScroller.doubleValue = verticalValue
        horizontalScroller.knobProportion = horizontalProportion
        horizontalScroller.doubleValue = horizontalValue
        verticalOverlayScroller.knobProportion = verticalProportion
        verticalOverlayScroller.value = verticalValue
        horizontalOverlayScroller.knobProportion = horizontalProportion
        horizontalOverlayScroller.value = horizontalValue

        let isLegacy = !isOverlayStyle
        verticalScroller.isHidden = !(isLegacy && metrics.maxOffset.y > 0)
        horizontalScroller.isHidden = !(isLegacy && metrics.maxOffset.x > 0)
        if isLegacy {
            verticalOverlayScroller.isHidden = true
            horizontalOverlayScroller.isHidden = true
        }
    }

    private func overlayScroller(for axis: NSEvent.GestureAxis) -> NGOverlayScroller {
        axis == .vertical ? verticalOverlayScroller : horizontalOverlayScroller
    }

    private func canScroll(_ axis: NSEvent.GestureAxis) -> Bool {
        axis == .vertical ? layoutMetrics.maxOffset.y > 0 : layoutMetrics.maxOffset.x > 0
    }

    /// Shows an overlay scroller and fades it out after a moment of inactivity.
    /// It stays visible while hovered or dragged. Like system overlay scrollers,
    /// it only appears when scrolling, never just because the pointer is near.
    func revealScroller(_ axis: NSEvent.GestureAxis) {
        guard isOverlayStyle else { return }
        let scroller = overlayScroller(for: axis)
        guard canScroll(axis) else {
            // Nothing to scroll (any more): don't leave a scroller behind.
            scrollerFadeTasks[axis]?.cancel()
            scrollerFadeTasks[axis] = nil
            scroller.isRevealed = false
            scroller.alphaValue = 0
            scroller.isHidden = true
            return
        }
        scroller.isHidden = false
        scroller.isRevealed = true
        // Called for every scroll event: only animate when it isn't shown yet.
        if scroller.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                scroller.animator().alphaValue = 1
            }
        }

        scrollerLastActivity[axis] = ProcessInfo.processInfo.systemUptime
        guard !scroller.isInteracting else {
            scrollerFadeTasks[axis]?.cancel()
            scrollerFadeTasks[axis] = nil
            return
        }
        // One pending fade per axis, pushed back by further activity.
        guard scrollerFadeTasks[axis] == nil else { return }
        scrollerFadeTasks[axis] = Task { @MainActor [weak self, weak scroller] in
            while let self, let lastActivity = self.scrollerLastActivity[axis] {
                let remaining = lastActivity + 1 - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { break }
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
            }
            self?.scrollerFadeTasks[axis] = nil
            guard let scroller, !scroller.isInteracting else { return }
            // A fading scroller no longer reacts to the pointer.
            scroller.isRevealed = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                scroller.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    // Hidden scrollers must not catch clicks meant for the rows.
                    if scroller.alphaValue == 0 {
                        scroller.isHidden = true
                    }
                }
            }
        }
    }

    func scrollToFraction(_ fraction: CGFloat, along axis: NSEvent.GestureAxis) {
        let maxOffset = layoutMetrics.maxOffset
        if axis == .vertical {
            setContentOffset(CGPoint(x: contentOffset.x, y: fraction * maxOffset.y))
        } else {
            // The scroller's fraction is physical: from the right, right to left.
            setContentOffset(CGPoint(x: (isRightToLeft ? 1 - fraction : fraction) * maxOffset.x, y: contentOffset.y))
        }
        revealScroller(axis)
    }

    func scrollByPage(_ direction: CGFloat, along axis: NSEvent.GestureAxis) {
        let metrics = layoutMetrics
        if axis == .vertical {
            let page = max(rowHeight, metrics.bodyHeight - metrics.bottomInset - rowHeight)
            setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y + direction * page))
        } else {
            let logical = isRightToLeft ? -direction : direction
            setContentOffset(CGPoint(x: contentOffset.x + logical * metrics.centerWidth * 0.9, y: contentOffset.y))
        }
        revealScroller(axis)
    }

    @objc private func legacyScrollerDidScroll(_ sender: NSScroller) {
        let axis: NSEvent.GestureAxis = sender === verticalScroller ? .vertical : .horizontal
        switch sender.hitPart {
        case .knob, .knobSlot:
            scrollToFraction(sender.doubleValue, along: axis)
        case .decrementPage:
            scrollByPage(-1, along: axis)
        case .incrementPage:
            scrollByPage(1, along: axis)
        default:
            break
        }
    }
}
#endif
