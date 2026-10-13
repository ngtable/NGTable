#if os(macOS)
import AppKit

// The table's look beyond the system defaults (see `NGTableView.tableStyle`
// and `density`): the cells' and the header's font sizes, the text,
// background, stripe and group row colors, and how tall rows are for the
// font. Everything the renderer draws with comes from `MetalStyle`, made once
// per appearance and style.

/// Fonts and colors of a table; `nil` keeps the system default.
public struct NGTableStyle: Hashable {
    /// The size of the cells' and the summary row's text (the system font
    /// size by default).
    public var fontSize: CGFloat?
    /// The size of the column titles (the small system size by default).
    public var headerFontSize: CGFloat?
    public var textColor: NSColor?
    public var secondaryTextColor: NSColor?
    /// Behind the rows (`controlBackgroundColor` by default).
    public var backgroundColor: NSColor?
    /// Alternating row backgrounds, with `usesAlternatingRowBackgroundColors`.
    public var stripeColors: [NSColor]?
    /// Group header rows' background.
    public var groupRowColor: NSColor?

    public init(fontSize: CGFloat? = nil, headerFontSize: CGFloat? = nil, textColor: NSColor? = nil,
                secondaryTextColor: NSColor? = nil, backgroundColor: NSColor? = nil, stripeColors: [NSColor]? = nil,
                groupRowColor: NSColor? = nil) {
        self.fontSize = fontSize
        self.headerFontSize = headerFontSize
        self.textColor = textColor
        self.secondaryTextColor = secondaryTextColor
        self.backgroundColor = backgroundColor
        self.stripeColors = stripeColors
        self.groupRowColor = groupRowColor
    }

    /// The cells' font size.
    var cellFontSize: CGFloat { fontSize ?? NSFont.systemFontSize }
    var titleFontSize: CGFloat { headerFontSize ?? NSFont.systemFontSize(for: .small) }
}

/// How much room rows give their text, like Finder's and Mail's list sizes.
public enum NGTableDensity: Sendable, Hashable, CaseIterable {
    case compact
    case regular
    case spacious

    /// Room above and below the text, in points.
    var padding: CGFloat {
        switch self {
        case .compact: 2
        case .regular: 4
        case .spacious: 8
        }
    }
}

/// Single-line heights of fonts, as AppKit lays a line out (measured once
/// per font: no formula of the font's metrics gives AppKit's).
@MainActor
enum NGLineHeights {
    private static var heights: [NSFont: CGFloat] = [:]
    /// The font asked last: a frame asks for the same few fonts cell after
    /// cell, and hashing an `NSFont` costs more than comparing pointers.
    private static var last: (font: NSFont, height: CGFloat)?

    static func height(of font: NSFont) -> CGFloat {
        if let last, last.font === font { return last.height }
        let height = heights[font] ?? ceil(NSAttributedString(string: "Xg", attributes: [.font: font]).size().height)
        heights[font] = height
        last = (font, height)
        return height
    }
}

extension NGTableView {
    /// The fonts and colors the renderer draws this table with.
    var metalStyle: MetalStyle {
        MetalStyle.resolved(for: effectiveAppearance, style: tableStyle)
    }

    /// The row height for a density with the style's font.
    func rowHeight(for density: NGTableDensity) -> CGFloat {
        let font = NSFont.systemFont(ofSize: tableStyle.cellFontSize)
        // With the room `intercellSpacing` adds between rows.
        return NGLineHeights.height(of: font) + 2 * density.padding + cellSpacing.height
    }

    /// The style changed: everything is drawn again with it.
    func applyTableStyle() {
        if let density { rowHeight = rowHeight(for: density) }
        recycleAllCells()
        needsLayout = true
        setNeedsMetalFrame()
        setNeedsChromeFrame(headerView)
        setNeedsChromeFrame(summaryBar.contentView)
    }
}
#endif
