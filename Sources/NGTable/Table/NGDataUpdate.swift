#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import os

/// Updating data: while the app loads new data (another period, a refresh
/// from the server), the table fades and ignores the user, so nobody acts on
/// rows that are about to change.
extension NGTableView {
    /// Runs `work`, typically loading new data and reloading the table, with
    /// the table in its updating state (see `isUpdatingData`). Updates that
    /// overlap (a new period chosen while the previous one still loads) keep
    /// the state until the last one ends, also when one throws.
    ///
    /// ```swift
    /// try await table.updatingData {
    ///     data.replace(with: try await api.campaigns(in: period))
    ///     table.reloadData()
    /// }
    /// ```
    public func updatingData<T>(_ work: () async throws -> T) async rethrows -> T {
        runningDataUpdates += 1
        updateDataUpdateState()
        defer {
            runningDataUpdates -= 1
            updateDataUpdateState()
        }
        return try await work()
    }

    /// Whether the table currently shows and behaves as updating.
    var isDataUpdateActive: Bool {
        isUpdatingData || runningDataUpdates > 0
    }

    /// Whether the rows ignore the user: while the data updates, and while a
    /// batch that moved rows is open across a turn of the run loop (the app
    /// awaits inside it): display rows still mean the rows before its moves,
    /// so a click or a key would act on other records.
    var ignoresUserInput: Bool {
        !isEnabled || isDataUpdateActive || rowUpdateBatch?.displayIsStale == true
    }

    /// Logs, once per batch, a batch that moved rows and is still open when
    /// the run loop turns: awaiting inside `beginUpdates()`/`endUpdates()`
    /// keeps the table from showing and handling its rows until the end. A
    /// log, not an assertion: an app's debug build shouldn't stop in the
    /// table's code for it. Tests of such batches turn it off.
    static var reportsBatchesAcrossRunLoopTurns = true
    private static let updatesLog = Logger(subsystem: "NGTable", category: "Updates")

    func checkBatchAcrossRunLoopTurn() {
        guard rowUpdateBatch?.displayIsStale == true, rowUpdateBatch?.reportedRunLoopTurn == false else { return }
        rowUpdateBatch?.reportedRunLoopTurn = true
        if Self.reportsBatchesAcrossRunLoopTurns {
            Self.updatesLog.error("A batch that moved rows is open across a turn of the run loop; don't await between beginUpdates() and endUpdates(): until endUpdates() the table ignores the user")
        }
    }

    func updateDataUpdateState() {
        let isActive = isDataUpdateActive
        guard isActive != isShowingDataUpdate else { return }
        isShowingDataUpdate = isActive
        dataUpdateGeneration += 1
        if isActive {
            beginDataUpdate()
        } else {
            endDataUpdate()
        }
    }

    /// Fades in after a moment, so an update that is done at once doesn't
    /// flash; the table ignores the user right away.
    private static let dataUpdateFadeDelay: TimeInterval = 0.15

    private func beginDataUpdate() {
        // What the user was doing acts on rows that are about to change.
        if isHeaderInteracting || columnDrag != nil {
            cancelHeaderInteraction()
        }
        stopDragSelectionScroll()
        tracksDragSelection = false
        rowsMenuDidClose()
        // An edit goes in now, while its row is still the record it was typed for.
        endEditing(committing: true)
        closeRowActions()

        let overlay = dataUpdateOverlay
        overlay.frame = bounds
        overlay.showsIndicator = showsDataUpdateIndicator
        overlay.text = dataUpdateText
        overlay.indicatorCenter = CGPoint(x: bounds.midX, y: layoutMetrics.headerHeight
            + max(0, bounds.height - layoutMetrics.headerHeight - layoutMetrics.summaryHeight) / 2)
        overlay.alphaValue = 0
        overlay.isHidden = false
        // Above everything the table shows, including views added since.
        addSubview(overlay)
        refreshPointerAreasForDataUpdate()

        let generation = dataUpdateGeneration
        // A run loop timer in the common modes: it also fires while the user
        // holds the mouse or a menu is open.
        let timer = Timer(timeInterval: Self.dataUpdateFadeDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dataUpdateGeneration == generation else { return }
                self.isDataUpdateVeiled = true
                overlay.startIndicator()
                #if os(macOS)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    overlay.animator().alphaValue = 1
                }
                #else
                UIView.animate(withDuration: 0.2) { overlay.alpha = 1 }
                #endif
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func endDataUpdate() {
        let overlay = dataUpdateOverlay
        let generation = dataUpdateGeneration
        // The user can go on at once; the fade just follows. Still no rows:
        // the empty state comes back.
        isDataUpdateVeiled = false
        refreshPointerAreasForDataUpdate()
        #if os(macOS)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = overlay.alphaValue > 0 ? 0.15 : 0
            overlay.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dataUpdateGeneration == generation else { return }
                overlay.isHidden = true
                overlay.stopIndicator()
            }
        })
        #else
        UIView.animate(withDuration: overlay.alpha > 0 ? 0.15 : 0, animations: { overlay.alpha = 0 }, completion: { [weak self] _ in
            guard let self, self.dataUpdateGeneration == generation else { return }
            overlay.isHidden = true
            overlay.stopIndicator()
        })
        #endif
    }

    /// The resize cursor and tool tips are off while updating.
    private func refreshPointerAreasForDataUpdate() {
        // Out of the way of hit testing as soon as the update ends, even while it fades.
        dataUpdateOverlay.blocksInput = isDataUpdateActive
        #if os(macOS)
        window?.invalidateCursorRects(for: headerView)
        window?.invalidateCursorRects(for: dataUpdateOverlay)
        headerView.refreshToolTip()
        #endif
    }

    func layoutDataUpdateOverlay() {
        guard isShowingDataUpdate else { return }
        dataUpdateOverlay.frame = bounds
        dataUpdateOverlay.indicatorCenter = CGPoint(x: bounds.midX, y: layoutMetrics.headerHeight
            + max(0, bounds.height - layoutMetrics.headerHeight - layoutMetrics.summaryHeight) / 2)
    }
}

#if os(macOS)
/// Covers the table while its data updates: a veil of the window's background
/// color, which pales it, and a wall for every mouse and trackpad event.
final class NGDataUpdateOverlay: NGPlatformView {
    /// Whether events stop here (off while the veil fades out).
    var blocksInput = true

    var showsIndicator = false {
        didSet {
            guard showsIndicator != oldValue else { return }
            if !showsIndicator {
                indicator?.stopAnimation(nil)
            } else if isShowingProgress {
                startIndicator()
            }
            layoutIndicator()
        }
    }

    /// The caption under the spinner.
    var text: String? {
        didSet {
            guard text != oldValue else { return }
            label.stringValue = text ?? ""
            label.isHidden = !isShowingProgress || (text ?? "").isEmpty
            layoutIndicator()
        }
    }

    /// The middle of the rows area, where the spinner and caption go.
    var indicatorCenter: CGPoint = .zero {
        didSet { layoutIndicator() }
    }

    #if os(macOS)
    private var indicator: NSProgressIndicator?
    #endif
    /// Whether the spinner and caption are showing (after the fade-in delay).
    private var isShowingProgress = false

    #if os(macOS)
    private lazy var label: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: NGFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.isHidden = true
        plate.addSubview(label)
        return label
    }()
    #endif

    /// The spinner and caption sit on a plate, readable over the pale rows.
    private lazy var plate: NGDataUpdatePlate = {
        let plate = NGDataUpdatePlate()
        plate.isHidden = true
        addSubview(plate)
        return plate
    }()

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NGColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    #if os(macOS)
    func startIndicator() {
        isShowingProgress = true
        label.isHidden = (text ?? "").isEmpty
        defer { layoutIndicator() }
        guard showsIndicator else { return }
        let indicator = indicator ?? {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .regular
            indicator.isDisplayedWhenStopped = false
            plate.addSubview(indicator)
            self.indicator = indicator
            return indicator
        }()
        layoutIndicator()
        indicator.startAnimation(nil)
    }
    #endif

    func stopIndicator() {
        isShowingProgress = false
        indicator?.stopAnimation(nil)
        label.isHidden = true
    }

    /// The spinner above the caption, centered together on their plate.
    private func layoutIndicator() {
        let spinner = showsIndicator && isShowingProgress ? indicator.map { $0.fittingSize } ?? .zero : .zero
        let showsLabel = !label.isHidden
        let padding = CGSize(width: 18, height: 14)
        let spacing: CGFloat = spinner.height > 0 && showsLabel ? 8 : 0
        var labelSize = CGSize.zero
        if showsLabel {
            label.preferredMaxLayoutWidth = max(0, min(bounds.width - 40 - 2 * padding.width, 380))
            labelSize = label.fittingSize
            labelSize.width = min(ceil(labelSize.width), label.preferredMaxLayoutWidth)
        }
        let content = CGSize(width: max(spinner.width, labelSize.width), height: spinner.height + spacing + labelSize.height)
        plate.isHidden = content.height == 0
        let plateSize = CGSize(width: content.width + 2 * padding.width, height: content.height + 2 * padding.height)
        plate.frame = CGRect(x: (indicatorCenter.x - plateSize.width / 2).rounded(), y: (indicatorCenter.y - plateSize.height / 2).rounded(),
                             width: plateSize.width, height: plateSize.height)
        indicator?.frame = CGRect(x: ((plateSize.width - spinner.width) / 2).rounded(), y: padding.height,
                                  width: spinner.width, height: spinner.height)
        label.frame = CGRect(x: ((plateSize.width - labelSize.width) / 2).rounded(), y: padding.height + spinner.height + spacing,
                             width: labelSize.width, height: labelSize.height)
    }

    override func hitTest(_ point: CGPoint) -> NGPlatformView? {
        blocksInput ? super.hitTest(point).map { _ in self } : nil
    }

    #if os(macOS)
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    #endif

    // Every event that reaches the overlay ends here.
    #if os(macOS)
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    #endif

    #if os(macOS)
    override func resetCursorRects() {
        if blocksInput {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
    #endif
}
/// The rounded plate under the spinner and caption, in the window's
/// background color, like the panels of system progress.
final class NGDataUpdatePlate: NGPlatformView {
    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NGColor.windowBackgroundColor.cgColor
        layer?.borderColor = NGColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
    }
}
#endif
#endif
