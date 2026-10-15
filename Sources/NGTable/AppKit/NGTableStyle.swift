#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    public var textColor: NGColor?
    public var secondaryTextColor: NGColor?
    /// Behind the rows (`controlBackgroundColor` by default).
    public var backgroundColor: NGColor?
    /// Alternating row backgrounds, with `usesAlternatingRowBackgroundColors`.
    public var stripeColors: [NGColor]?
    /// Group header rows' background.
    public var groupRowColor: NGColor?

    public init(fontSize: CGFloat? = nil, headerFontSize: CGFloat? = nil, textColor: NGColor? = nil,
                secondaryTextColor: NGColor? = nil, backgroundColor: NGColor? = nil, stripeColors: [NGColor]? = nil,
                groupRowColor: NGColor? = nil) {
        self.fontSize = fontSize
        self.headerFontSize = headerFontSize
        self.textColor = textColor
        self.secondaryTextColor = secondaryTextColor
        self.backgroundColor = backgroundColor
        self.stripeColors = stripeColors
        self.groupRowColor = groupRowColor
    }

    /// The cells' font size.
    var cellFontSize: CGFloat { fontSize ?? NGFont.systemFontSize }
    #if os(macOS)
    var titleFontSize: CGFloat { headerFontSize ?? NGFont.systemFontSize(for: .small) }
    #else
    var titleFontSize: CGFloat { headerFontSize ?? NGFont.smallSystemFontSize }
    #endif
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

extension NGTableView {
    /// The fonts and colors the renderer draws this table with.
    var metalStyle: MetalStyle {
        MetalStyle.resolved(for: effectiveAppearance, style: tableStyle)
    }

    /// The row height for a density with the style's font.
    func rowHeight(for density: NGTableDensity) -> CGFloat {
        let font = NGFont.systemFont(ofSize: tableStyle.cellFontSize)
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
