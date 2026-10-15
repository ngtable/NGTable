#if os(iOS)
import UIKit

// AppKit's names for what UIKit calls otherwise, for the code the table's
// views share on both platforms (layout, display, opacity).

extension UIView {
    /// `setNeedsLayout()`, as AppKit's `needsLayout = true`.
    var needsLayout: Bool {
        get { false }
        set { if newValue { setNeedsLayout() } }
    }

    /// `setNeedsDisplay()`, as AppKit's `needsDisplay = true`.
    @objc var needsDisplay: Bool {
        get { false }
        set { if newValue { setNeedsDisplay() } }
    }

    /// `layoutIfNeeded()`, as AppKit's.
    func layoutSubtreeIfNeeded() { layoutIfNeeded() }

    /// `alpha`, as AppKit's `alphaValue`.
    var alphaValue: CGFloat {
        get { alpha }
        set { alpha = newValue }
    }
}

/// Where `addSubview(_:positioned:relativeTo:)` puts a view.
enum NGOrderingMode {
    case below, above
}

extension UIView {
    func addSubview(_ view: UIView, positioned place: NGOrderingMode, relativeTo other: UIView?) {
        guard let other else { return addSubview(view) }
        switch place {
        case .below: insertSubview(view, belowSubview: other)
        case .above: insertSubview(view, aboveSubview: other)
        }
    }

    /// The size Auto Layout gives it, as AppKit's `fittingSize`.
    var fittingSize: CGSize { systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }

    func setFrameOrigin(_ origin: CGPoint) { frame.origin = origin }
    func setFrameSize(_ size: CGSize) { frame.size = size }

    /// Whether it or a view it is in is hidden, as AppKit's.
    var isHiddenOrHasHiddenAncestor: Bool {
        var view: UIView? = self
        while let current = view {
            if current.isHidden { return true }
            view = current.superview
        }
        return false
    }

    /// (No live resize on the iPad.)
    var inLiveResize: Bool { false }

    /// A display link calling `selector` on `target` every frame, as AppKit's.
    func displayLink(target: Any, selector: Selector) -> CADisplayLink {
        CADisplayLink(target: target, selector: selector)
    }
}

extension UIWindow {
    /// The screen's pixel density, as AppKit's `backingScaleFactor`.
    var backingScaleFactor: CGFloat { screen.scale }
    /// Whether it shows, as AppKit's `isVisible`.
    var isVisible: Bool { !isHidden && windowScene?.activationState != .background }
}

extension UILabel {
    /// The text, as an AppKit label's `stringValue`.
    var stringValue: String {
        get { text ?? "" }
        set { text = newValue }
    }
}

extension UIActivityIndicatorView {
    func startAnimation(_ sender: Any?) { startAnimating() }
    func stopAnimation(_ sender: Any?) { stopAnimating() }
}

/// The colors AppKit names, as UIKit's (the table's look is the same on both).
extension UIColor {
    static var labelColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var tertiaryLabelColor: UIColor { .tertiaryLabel }
    static var quaternaryLabelColor: UIColor { .quaternaryLabel }
    static var textColor: UIColor { .label }
    static var headerTextColor: UIColor { .label }
    static var disabledControlTextColor: UIColor { .tertiaryLabel }
    static var linkColor: UIColor { .link }
    static var separatorColor: UIColor { .separator }
    static var gridColor: UIColor { .separator }
    static var controlAccentColor: UIColor { .tintColor }
    static var windowBackgroundColor: UIColor { .systemBackground }
    static var controlBackgroundColor: UIColor { .systemBackground }
    static var selectedContentBackgroundColor: UIColor { .tintColor }
    static var unemphasizedSelectedContentBackgroundColor: UIColor { .systemFill }
    static var alternateSelectedControlTextColor: UIColor { .white }
    static var controlTextColor: UIColor { .label }
    static var alternatingContentBackgroundColors: [UIColor] { [.systemBackground, .secondarySystemBackground] }
    /// (UIKit has no such notification: trait changes come to the view.)
    static let systemColorsDidChangeNotification = Notification.Name("NGSystemColorsDidChange")
}

/// What the table tells VoiceOver, on the Mac (the iPad's comes with stage 3).
enum NSAccessibility {
    struct Notification: Hashable {
        let name: String
        static let rowCountChanged = Notification(name: "rowCountChanged")
        static let selectedRowsChanged = Notification(name: "selectedRowsChanged")
        static let selectedCellsChanged = Notification(name: "selectedCellsChanged")
        static let selectedColumnsChanged = Notification(name: "selectedColumnsChanged")
        static let valueChanged = Notification(name: "valueChanged")
        static let layoutChanged = Notification(name: "layoutChanged")
        static let rowExpanded = Notification(name: "rowExpanded")
        static let rowCollapsed = Notification(name: "rowCollapsed")
        static let focusedUIElementChanged = Notification(name: "focusedUIElementChanged")
    }

    static func post(element: Any, notification: Notification) {}
}

/// NSTableView's types that the table's API uses, on the iPad: the same
/// names, so code written for the Mac's table reads the same.
public enum NSTableView {
    /// How rows animate as they come and go.
    public struct AnimationOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let effectFade = AnimationOptions(rawValue: 1 << 0)
        public static let effectGap = AnimationOptions(rawValue: 1 << 1)
        public static let slideUp = AnimationOptions(rawValue: 1 << 4)
        public static let slideDown = AnimationOptions(rawValue: 1 << 5)
        public static let slideLeft = AnimationOptions(rawValue: 1 << 6)
        public static let slideRight = AnimationOptions(rawValue: 1 << 7)
    }

    /// Whether a drop goes onto a row or above it.
    public enum DropOperation: UInt, Sendable {
        case on, above
    }

    /// The edge a swipe shows a row's actions at.
    public enum RowActionEdge: Int, Sendable {
        case leading, trailing
    }

    /// The grid lines drawn between rows and columns.
    public struct GridLineStyle: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let solidVerticalGridLineMask = GridLineStyle(rawValue: 1 << 0)
        public static let solidHorizontalGridLineMask = GridLineStyle(rawValue: 1 << 1)
        public static let dashedHorizontalGridLineMask = GridLineStyle(rawValue: 1 << 3)
    }

    /// How columns fill the table's width as it changes.
    public enum ColumnAutoresizingStyle: UInt, Sendable {
        case noColumnAutoresizing, uniformColumnAutoresizingStyle, sequentialColumnAutoresizingStyle
        case reverseSequentialColumnAutoresizingStyle, lastColumnOnlyAutoresizingStyle, firstColumnOnlyAutoresizingStyle
    }

    /// How a drop onto the table shows.
    public enum DraggingDestinationFeedbackStyle: Int, Sendable {
        case none = -1, regular = 0, sourceList = 1, gap = 2
    }

    /// The table's style (insets around the rows).
    public enum Style: Int, Sendable {
        case automatic, fullWidth, inset, sourceList, plain
    }

    /// The rows' height for the system's text size.
    public enum RowSizeStyle: Int, Sendable {
        case `default` = -1, custom = 0, small, medium, large
    }
}
#endif
