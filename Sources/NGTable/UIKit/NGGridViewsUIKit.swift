#if os(iOS)
import UIKit

// The table's views on the iPad, with the members the shared code uses of
// their Mac counterparts (NGGridViews.swift, NGSummaryBarView.swift,
// NGOverlayScroller.swift): regions with a scrolling canvas, the header,
// the summary bar. They draw nothing themselves: the Metal layer under them
// does (NGTableMetal.swift).

/// A region's content, moved to scroll (the rows' coordinates).
final class NGCanvasView: UIView {
    weak var owner: NGTableView?
    weak var region: NGRegionView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }
}

/// A part of the rows (the frozen columns at an edge, or the scrolling ones),
/// clipping its canvas.
final class NGRegionView: UIView {
    weak var owner: NGTableView? {
        didSet { canvas.owner = owner }
    }
    let pin: NGColumnPin
    let canvas = NGCanvasView()

    init(pin: NGColumnPin) {
        self.pin = pin
        super.init(frame: .zero)
        clipsToBounds = true
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        addSubview(canvas)
        canvas.region = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }
}

/// The header row's place; the Metal layer in it draws the titles.
final class NGGridHeaderView: UIView {
    weak var owner: NGTableView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var needsDisplay: Bool {
        get { false }
        set { if newValue { owner?.setNeedsChromeFrame(self) } }
    }

    override func setNeedsDisplay() {
        super.setNeedsDisplay()
        owner?.setNeedsChromeFrame(self)
    }

    /// Its Metal layer covers it at its new size.
    override func layoutSubviews() {
        super.layoutSubviews()
        owner?.layoutChromeSurface(of: self)
    }
}

/// The summary row at the bottom, over the rows scrolling under it.
final class NGSummaryBarView: UIView {
    let contentView = NGSummaryContentView(frame: .zero)
    private let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(effectView)
        effectView.contentView.addSubview(contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.frame = bounds
        contentView.frame = effectView.contentView.bounds
    }
}

/// The summary values' place; the Metal layer in it draws them.
final class NGSummaryContentView: UIView {
    weak var owner: NGTableView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var needsDisplay: Bool {
        get { false }
        set { if newValue { owner?.setNeedsChromeFrame(self) } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        owner?.layoutChromeSurface(of: self)
    }
}

/// A plain rectangle of a color (separators, outlines), optionally rounded,
/// with a marker at its leading edge or a border.
final class NGColorView: UIView {
    var color: UIColor = .clear {
        didSet { backgroundColor = color }
    }
    var cornerRadius: CGFloat = 0 {
        didSet { layer.cornerRadius = cornerRadius }
    }
    var roundedCorners: CACornerMask = [] {
        didSet { layer.maskedCorners = roundedCorners }
    }
    var markerColor: UIColor?
    var borderColor: UIColor? {
        didSet {
            layer.borderColor = borderColor?.cgColor
            layer.borderWidth = borderColor == nil ? 0 : 1
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }
}

/// The table's own scroll indicator, as on the Mac (the iPad's scroll view
/// shows its own: this one stays hidden).
final class NGOverlayScroller: UIView {
    enum Orientation {
        case vertical, horizontal
    }

    let orientation: Orientation
    var isMirrored = false
    var knobProportion: CGFloat = 1
    var value: CGFloat = 0
    var onScroll: ((CGFloat) -> Void)?
    var onPage: ((Int) -> Void)?
    var onInteractionChange: (() -> Void)?
    var isRevealed = false
    var isInteracting: Bool { false }
    static let thickness: CGFloat = 0

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }
}
#endif
