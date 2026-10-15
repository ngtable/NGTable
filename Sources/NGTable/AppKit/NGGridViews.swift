#if os(macOS)
import AppKit


extension NGTableColumn {
    /// The column's `id` as an interface item identifier, like
    /// `NSTableColumn.identifier`.
    public var identifier: NSUserInterfaceItemIdentifier {
        get { NSUserInterfaceItemIdentifier(id) }
        set { id = newValue.rawValue }
    }
}

/// A flipped view without drawing, used as a scrollable canvas. Row
/// backgrounds and default cells are drawn by the Metal renderer under it
/// (see NGTableMetal.swift); grid lines are subviews, and the canvas
/// tracks the pointer for tool tips and `hoveredCell`.
final class NGCanvasView: NSView {
    weak var owner: NGTableView?
    weak var region: NGRegionView?
    /// Tool tips of default cells (marks), which aren't views: see `NGHoverToolTip`.
    private let hoverToolTip = NGHoverToolTip()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let region, let owner else { return }
        hoverToolTip.show(owner.cellToolTipFrame(at: convert(event.locationInWindow, from: nil), in: region), in: self)
        owner.updateHoveredCell(atWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverToolTip.show(nil, in: self)
        // Into another region's canvas, or out of the rows.
        owner?.updateHoveredCell(atWindowPoint: event.locationInWindow)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
}

/// A view filled with a (dynamic) color through its layer, so moving it never
/// triggers drawing. Used for row backgrounds and grid lines.
final class NGColorView: NSView {
    var color: NSColor = .clear {
        didSet {
            guard color != oldValue else { return }
            needsDisplay = true
        }
    }

    var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Which corners `cornerRadius` applies to. The view is flipped, and so is
    /// its layer geometry: `MinY` corners are at the top on screen.
    var roundedCorners: CACornerMask = [] {
        didSet {
            guard roundedCorners != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Paints the leading edge of the view (row markers); the rounded corners
    /// clip it, so it follows the row's shape.
    var markerColor: NSColor? {
        didSet {
            guard markerColor != oldValue else { return }
            needsDisplay = true
        }
    }

    private var markerLayer: CALayer?

    /// An outline drawn inside the bounds, e.g. for the row a context menu is for.
    var borderColor: NSColor? {
        didSet {
            guard borderColor != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        // Resolved here, where the view's effective appearance is current.
        layer.backgroundColor = color.cgColor
        layer.cornerRadius = cornerRadius
        layer.maskedCorners = roundedCorners
        layer.cornerCurve = .continuous
        layer.borderColor = borderColor?.cgColor
        layer.borderWidth = borderColor == nil ? 0 : 2
        // Clips the marker to the rounded corners.
        layer.masksToBounds = markerColor != nil
        updateMarkerLayer(in: layer)
    }

    private func updateMarkerLayer(in layer: CALayer) {
        guard let markerColor else {
            markerLayer?.isHidden = true
            return
        }
        let marker = markerLayer ?? {
            let marker = CALayer()
            // Rows move constantly while scrolling; the marker must not animate.
            marker.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
            marker.autoresizingMask = [.layerHeightSizable]
            layer.addSublayer(marker)
            markerLayer = marker
            return marker
        }()
        marker.frame = NSRect(x: 0, y: 0, width: NGMetrics.markerWidth, height: bounds.height)
        marker.backgroundColor = markerColor.cgColor
        marker.isHidden = false
    }
}

/// One horizontal region of the grid (leading frozen, scrolling, trailing
/// frozen). It clips a canvas that the owner moves to scroll the content.
final class NGRegionView: NSView {
    weak var owner: NGTableView? {
        didSet { canvas.owner = owner }
    }
    let pin: NGColumnPin
    let canvas = NGCanvasView()

    init(pin: NGColumnPin) {
        self.pin = pin
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(canvas)
        canvas.region = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// Transparent: the Metal renderer draws the base and the rows under it.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        owner?.rowsMouseDown(event, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.rowsMouseDragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.rowsMouseUp(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.rowsMenu(for: event, in: self)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        owner?.rowsMenuDidClose()
    }

    // The table describes rows and cells itself; don't expose internal views.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        NGTableView.onMainActor { owner?.accessibilityElement(atScreenPoint: point) }
    }

}

extension NGCanvasView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let region else { return "" }
        return owner?.cellToolTip(at: point, in: region) ?? ""
    }
}

/// The lifted image of columns being dragged in the header, with a shadow like
/// NSTableView's column drag. It has an opaque base because the snapshot does
/// not include the translucent header material.
final class NGDragSnapshotView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        alphaValue = 0.9
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        self.shadow = shadow
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer.contents = image
        layer.contentsGravity = .resize
        // An explicit path spares Core Animation deriving the shadow from the
        // image's alpha on every frame of the drag.
        layer.shadowPath = CGPath(rect: bounds, transform: nil)
    }

    // The snapshot is decoration; clicks go to the table underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Column header. The scrolling part follows the horizontal scroll position;
/// frozen parts stay pinned. Redrawn on horizontal scrolling (it is small).
final class NGGridHeaderView: NSView {
    weak var owner: NGTableView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // A layer of its own for the Metal layer inside it, also in windows
        // that aren't layer-backed.
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("made in code")
    }

    override var isFlipped: Bool { true }

    // The content is the table's Metal layer inside this view (see
    // NGTableChrome.swift): asking the view to redraw marks it.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    override var needsDisplay: Bool {
        didSet { if needsDisplay { owner?.setNeedsChromeFrame(self) } }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        owner?.setNeedsChromeFrame(self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        owner?.layoutChromeSurface(of: self)
    }

    override func resetCursorRects() {
        for (rect, cursor) in owner?.columnResizeCursorRects() ?? [] {
            addCursorRect(rect, cursor: cursor)
        }
    }

    /// Column tool tips: see `NGHoverToolTip`.
    private let hoverToolTip = NGHoverToolTip()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hoverToolTip.show(owner?.headerToolTipRect(at: point), in: self)
        owner?.updateHoveredHeaderColumn(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverToolTip.show(nil, in: self)
        owner?.updateHoveredHeaderColumn(at: nil)
    }

    /// Updates the tool tip for the column now under a resting pointer, e.g.
    /// after the columns scrolled.
    func refreshToolTip() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hoverToolTip.show(bounds.contains(point) ? owner?.headerToolTipRect(at: point) : nil, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.headerMouseDown(event, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.headerMouseDragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.headerMouseUp(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // A menu opened mid-drag would swallow the mouse up that ends it.
        guard let owner, !owner.isHeaderInteracting else { return nil }
        return owner.makeColumnVisibilityMenu(at: convert(event.locationInWindow, from: nil))
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        NGTableView.onMainActor { owner?.accessibilityElement(atScreenPoint: point) }
    }
}

extension NGGridHeaderView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        owner?.headerToolTip(at: point) ?? ""
    }
}

/// A tool tip area over just the item under the pointer (a column title, a
/// mark), registered again only when the pointer moves to another item.
///
/// Areas for every item would have to be registered again whenever the items
/// move (every scroll step), which makes AppKit rebuild the cursor areas of
/// the whole window. One area over the whole view would keep a tool tip on
/// screen while the pointer moves on to other items. With an area for the
/// hovered item only, AppKit hides the tool tip as the pointer leaves it.
@MainActor
final class NGHoverToolTip {
    private var rect: NSRect?

    func show(_ rect: NSRect?, in view: NSView & NSViewToolTipOwner) {
        guard rect != self.rect else { return }
        self.rect = rect
        view.removeAllToolTips()
        if let rect {
            view.addToolTip(rect, owner: view, userData: nil)
        }
    }
}
#endif
