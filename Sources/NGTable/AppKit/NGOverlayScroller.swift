#if os(macOS)
import AppKit
import QuartzCore

/// An overlay-style scroller, drawn by the table itself.
///
/// Standalone `NSScroller`s cannot expand on hover (that behavior lives in
/// `NSScrollView`'s private scroller implementation), so this view recreates the
/// system look: a thin capsule knob that thickens and shows a track while the
/// pointer is over it. Visibility (reveal and fade) is managed by the owner.
final class NGOverlayScroller: NSView {
    enum Orientation {
        case vertical
        case horizontal
    }

    /// Thickness of the view; the knob and track are drawn inside it.
    static let thickness: CGFloat = 16

    let orientation: Orientation
    /// A vertical scroller at the left edge (right to left): its knob hugs
    /// the outer (left) edge, the hairline is on the inner (right) side.
    var isMirrored = false {
        didSet { if isMirrored != oldValue { needsDisplay = true } }
    }

    /// Visible fraction of the content, 0...1.
    var knobProportion: CGFloat = 1 {
        didSet { if knobProportion != oldValue { needsDisplay = true } }
    }

    /// Scroll position, 0...1.
    var value: CGFloat = 0 {
        didSet { if value != oldValue { needsDisplay = true } }
    }

    /// Called with a new value while the knob is dragged or the track is clicked.
    var onScroll: ((CGFloat) -> Void)?
    /// Called with -1 or 1 to scroll by a page when the track is clicked.
    var onPage: ((Int) -> Void)?
    /// Called when hovering or dragging starts or ends.
    var onInteractionChange: (() -> Void)?

    /// Set by the owner while the scroller is shown. Like system overlay scrollers,
    /// it only reacts to the pointer (expands) while shown.
    var isRevealed = false {
        didSet {
            guard isRevealed != oldValue else { return }
            if isRevealed, let window {
                // The scroller may appear under a pointer that is not moving.
                isPointerInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            }
            updateHover()
        }
    }

    private var isPointerInside = false
    private(set) var isHovered = false
    private(set) var isTracking = false
    var isInteracting: Bool { isHovered || isTracking }

    /// 0 = thin knob, 1 = expanded knob with track. Animatable through `animator()`.
    @objc dynamic var expansion: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    private var dragOffset: CGFloat = 0

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "expansion" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    // MARK: Geometry

    private let edgeInset: CGFloat = 2
    private let minimumKnobLength: CGFloat = 24

    private var length: CGFloat {
        orientation == .vertical ? bounds.height : bounds.width
    }

    private var knobThickness: CGFloat {
        6 + 4 * expansion
    }

    private var knobLength: CGFloat {
        let available = length - 2 * edgeInset
        return min(available, max(minimumKnobLength, available * knobProportion))
    }

    /// Distance the knob can travel.
    private var travel: CGFloat {
        max(0, length - 2 * edgeInset - knobLength)
    }

    private var knobRect: NSRect {
        let along = edgeInset + travel * min(max(value, 0), 1)
        let across = orientation == .vertical && isMirrored ? edgeInset + 1 : Self.thickness - edgeInset - 1 - knobThickness
        switch orientation {
        case .vertical:
            return NSRect(x: across, y: along, width: knobThickness, height: knobLength)
        case .horizontal:
            return NSRect(x: along, y: across, width: knobLength, height: knobThickness)
        }
    }

    private func position(of point: NSPoint) -> CGFloat {
        orientation == .vertical ? point.y : point.x
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink: NSColor = isDark ? .white : .black

        if expansion > 0 {
            ink.withAlphaComponent(0.06 * expansion).setFill()
            bounds.fill()
            ink.withAlphaComponent(0.12 * expansion).setFill()
            let hairline = orientation == .vertical
                ? NSRect(x: isMirrored ? bounds.width - 1 : 0, y: 0, width: 1, height: bounds.height)
                : NSRect(x: 0, y: 0, width: bounds.width, height: 1)
            hairline.fill()
        }

        let knob = knobRect
        let radius = min(knob.width, knob.height) / 2
        ink.withAlphaComponent(isTracking ? 0.6 : 0.45 + 0.1 * expansion).setFill()
        NSBezierPath(roundedRect: knob, xRadius: radius, yRadius: radius).fill()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateHover()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateHover()
    }

    private func updateHover() {
        let hovered = isPointerInside && isRevealed
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateExpansion()
    }

    private func updateExpansion() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().expansion = isInteracting ? 1 : 0
        }
        onInteractionChange?()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let knob = knobRect
        let pointPosition = position(of: point)
        let knobStart = position(of: knob.origin)
        let knobEnd = knobStart + knobLength

        isTracking = true
        updateExpansion()

        if pointPosition >= knobStart, pointPosition <= knobEnd {
            dragOffset = pointPosition - knobStart
        } else if UserDefaults.standard.bool(forKey: "AppleScrollerPagingBehavior") {
            // "Jump to the spot that's clicked", then keep dragging from the knob's center.
            dragOffset = knobLength / 2
            scroll(toKnobStart: pointPosition - dragOffset)
        } else {
            let direction = pointPosition < knobStart ? -1 : 1
            onPage?(direction)
            dragOffset = .nan
            // Holding the mouse keeps paging until the knob reaches the pointer,
            // like system scrollers: after a pause, then repeatedly.
            pagingPointer = pointPosition
            pageRepeatTimer?.invalidate()
            pageRepeatTimer = Timer.scheduledTimer(withTimeInterval: Self.pageRepeatDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.startPageRepeat(direction: direction) }
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !dragOffset.isNaN else {
            pagingPointer = position(of: point)
            return
        }
        scroll(toKnobStart: position(of: point) - dragOffset)
    }

    override func mouseUp(with event: NSEvent) {
        stopPageRepeat()
        isTracking = false
        updateExpansion()
    }

    // MARK: Paging while the mouse is held in the track

    private static let pageRepeatDelay: TimeInterval = 0.35
    private static let pageRepeatInterval: TimeInterval = 0.05

    private var pageRepeatTimer: Timer?
    /// Where the mouse holds the track, along the scroller.
    private var pagingPointer: CGFloat = 0

    private func startPageRepeat(direction: Int) {
        pageRepeatTimer = Timer.scheduledTimer(withTimeInterval: Self.pageRepeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.repeatPage(direction: direction) }
        }
        repeatPage(direction: direction)
    }

    private func repeatPage(direction: Int) {
        let knobStart = position(of: knobRect.origin)
        // Stop once the knob has reached the pointer (or the pointer moved past it).
        let reached = direction < 0 ? pagingPointer >= knobStart : pagingPointer <= knobStart + knobLength
        guard isTracking, !reached, NSEvent.pressedMouseButtons & 1 != 0 else {
            stopPageRepeat()
            // The mouse up went elsewhere: don't stay expanded as if still held.
            if NSEvent.pressedMouseButtons & 1 == 0, isTracking {
                isTracking = false
                updateExpansion()
            }
            return
        }
        onPage?(direction)
    }

    private func stopPageRepeat() {
        pageRepeatTimer?.invalidate()
        pageRepeatTimer = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        stopPageRepeat()
        if isTracking {
            isTracking = false
            updateExpansion()
        }
    }

    private func scroll(toKnobStart knobStart: CGFloat) {
        guard travel > 0 else { return }
        let newValue = min(max((knobStart - edgeInset) / travel, 0), 1)
        value = newValue
        onScroll?(newValue)
    }
}
#endif
