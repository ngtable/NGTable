#if os(macOS)
import AppKit

/// Bottom bar showing the summary row. Uses Liquid Glass on macOS 26 and later,
/// and a header-style visual effect material on earlier systems. Table rows
/// scroll underneath it.
final class NGSummaryBarView: NSView {
    let contentView = NGSummaryContentView(frame: .zero)
    private let effectView: NSView
    private var topSeparator: NSBox?

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 0
            glass.contentView = contentView
            effectView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .headerView
            material.blendingMode = .withinWindow
            material.state = .followsWindowActiveState
            material.addSubview(contentView)
            effectView = material
        }
        super.init(frame: frameRect)
        addSubview(effectView)

        if effectView is NSVisualEffectView {
            let separator = NSBox()
            separator.boxType = .separator
            addSubview(separator)
            topSeparator = separator
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        contentView.frame = effectView.bounds
        topSeparator?.frame = NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1)
    }
}

/// Shows the summary values aligned with the columns of all three regions.
final class NGSummaryContentView: NSView {
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

    // The values are the table's Metal layer inside this view (see
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

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner, !owner.isHeaderInteracting else { return nil }
        return owner.makeSummaryScopeMenu()
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        NGTableView.onMainActor { owner?.accessibilityElement(atScreenPoint: point) }
    }
}
#endif
