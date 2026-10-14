#if os(macOS)
import AppKit

// What the table draws, as values: each visible cell and row background is a
// small object the layout passes place, move and reuse (`NGDrawnCell`,
// `NGRowBackground`), and the Metal renderer draws them on every frame (see
// NGTableMetal.swift). They are not layers or views: a moved cell is a
// changed frame, nothing more.

enum NGCellContent: Hashable, Sendable {
    case text(String, alignment: NSTextAlignment, monospacedDigits: Bool)
    /// A number, formatted when it's first drawn (see
    /// `NGDrawnCell.displayedText`), and only for cells in view.
    case number(NGFormattedNumber, alignment: NSTextAlignment)
    case tags([NGTag])
    case mark(NGMark, alignment: NSTextAlignment)
    /// The title of a group header row: a disclosure chevron, the value and
    /// the number of rows, indented by the group's level.
    case groupTitle(NGGroupTitle)
    /// A group header's subtotal, in the summary row's semibold digits.
    case subtotal(String, alignment: NSTextAlignment)
    /// A picture or video with lines of text (see NGTableMedia.swift).
    case media(NGMedia)
    /// A small chart of a series.
    case sparkline(NGSparkline)
    /// A link: its title in the link color.
    case link(NGLink, alignment: NSTextAlignment)
    /// A push button.
    case button(NGCellButton, alignment: NSTextAlignment)
    /// A progress bar (`fraction` `nil`: indeterminate) with the fraction
    /// written beside it, in room for the widest text (`reserved`).
    case progress(fraction: Double?, text: String?, reserved: String?)
    /// Stars (`isEditable`: set by a click, previewed under the pointer).
    case rating(Int, maximum: Int, isEditable: Bool, alignment: NSTextAlignment)

    var alignment: NSTextAlignment {
        switch self {
        case .text(_, let alignment, _), .number(_, let alignment), .mark(_, let alignment), .subtotal(_, let alignment),
             .link(_, let alignment), .button(_, let alignment), .rating(_, _, _, let alignment): alignment
        case .tags, .groupTitle, .media, .sparkline, .progress: .natural
        }
    }
}

/// What a group header's title cell shows.
struct NGGroupTitle: Hashable, Sendable {
    var title: String
    /// The number of rows, or "" when not shown.
    var detail: String
    var level: Int
    var isExpanded: Bool
}

/// A number and its format. Formats are compared by a number the table gives
/// each distinct format (see `NGFormatIDs`): comparing and hashing the format
/// itself for every cell of every frame is measurable.
struct NGFormattedNumber: Hashable, Sendable {
    let value: Double
    let format: NGValueFormat
    let formatID: Int

    static func == (lhs: NGFormattedNumber, rhs: NGFormattedNumber) -> Bool {
        lhs.formatID == rhs.formatID && lhs.value.bitPattern == rhs.value.bitPattern
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value.bitPattern)
        hasher.combine(formatID)
    }

    /// The text it shows, with its format's kept style (main actor).
    @MainActor var text: String { NGFormatIDs.numberStyle(id: formatID, format: format).string(for: value) }
}

/// Numbers for values that are compared often (formats, appearances), given
/// out once and never reused: one per format and locale (a table's
/// `locale`, `nil` for the user's), so a number cell's id says both.
@MainActor
enum NGFormatIDs {
    private struct Key: Hashable {
        let format: NGValueFormat
        let locale: String?
    }
    private static var formats: [Key: Int] = [:]
    /// The locale of each id (`nil`: the user's, `Locale.current`).
    private static var locales: [Locale?] = []
    /// The number style of each id, made when first asked.
    private static var styles: [NGNumberStyle?] = []

    static func id(of format: NGValueFormat, locale: Locale? = nil) -> Int {
        let key = Key(format: format, locale: locale?.identifier)
        if let id = formats[key] { return id }
        let id = formats.count
        formats[key] = id
        locales.append(locale)
        return id
    }

    /// The number style of a format (`id` is its id, which says the locale),
    /// made once (again when the user's locale changes).
    static func numberStyle(id: Int, format: NGValueFormat) -> NGNumberStyle {
        if id < styles.count, let style = styles[id] { return style }
        let locale = id < locales.count ? locales[id] : nil
        let style = NGNumberStyle(format, locale: locale ?? .current)
        if id >= styles.count { styles += Array(repeating: nil, count: id - styles.count + 1) }
        styles[id] = style
        return style
    }

    static func numberStyle(of format: NGValueFormat, locale: Locale? = nil) -> NGNumberStyle {
        numberStyle(id: id(of: format, locale: locale), format: format)
    }

    /// The text a format gives a value, with the kept number style.
    static func string(for value: NGCellValue, format: NGValueFormat, locale: Locale? = nil) -> String {
        guard case .number(let number) = value else { return format.string(for: value, locale: locale ?? .current) }
        return numberStyle(of: format, locale: locale).string(for: number)
    }

    /// The locale changed: styles are made again.
    static func localeDidChange() {
        styles = []
    }
}

/// Counts changes of what the renderer draws (the cells' contents, frames,
/// highlight, visibility; the rows' colors, shapes, frames), so a layout pass
/// that changed nothing visible draws no frame.
enum NGFrameModel {
    nonisolated(unsafe) private(set) static var changes = 0

    static func noteChange() {
        changes &+= 1
    }
}

/// A visible default cell: its content, where it is and how it's shown.
@MainActor
/// What a cell's text quads were drawn for (`NGDrawnCell.quadCache`).
struct NGQuadKey: Equatable {
    let frame: CGRect
    let clip: CGRect
    let scale: CGFloat
    let color: SIMD4<Float>
    let font: ObjectIdentifier
    /// The glyphs' atlas and its resets: quads point into it.
    let atlas: ObjectIdentifier
    let atlasResets: Int
}

final class NGDrawnCell {
    /// What the cell shows; set by the table.
    var content: NGCellContent = .text("", alignment: .natural, monospacedDigits: false) {
        didSet {
            guard content != oldValue else { return }
            displayedText = nil
            quadCache = nil
            NGFrameModel.noteChange()
        }
    }

    /// Its text's quads as last drawn, and what they were drawn for: a frame
    /// that changes a few rows draws the other cells by copying them, not by
    /// laying out their glyphs again (see `NGTableView.appendContent`).
    var quadCache: (key: NGQuadKey, quads: [NGMetalQuad])?

    /// Its text as last laid out, reused while text, font and width stay
    /// (compared when drawn, so new content needs no reset here).
    var laidOutText: NGLaidOutText?

    /// In the outline column of a tree: the row's depth and triangle.
    var outline: NGOutline? {
        didSet { if outline != oldValue { NGFrameModel.noteChange() } }
    }

    /// The region the cell is in (its frame is in that region's canvas).
    var regionPin: NGColumnPin? {
        didSet { if regionPin != oldValue { NGFrameModel.noteChange() } }
    }

    /// The text a number shows, formatted once (not on every frame).
    var displayedText: String? {
        didSet { if displayedText != oldValue, oldValue != nil { quadCache = nil } }
    }

    /// The pointer is over the cell's control (a link is underlined), or
    /// presses it (`isPressed`).
    var isPointerOver = false {
        didSet { if isPointerOver != oldValue { NGFrameModel.noteChange() } }
    }
    var isPressed = false {
        didSet { if isPressed != oldValue { NGFrameModel.noteChange() } }
    }
    /// The most lines its text shows (1: one line, truncated); from a column
    /// that wraps text.
    var lineLimit = 1 {
        didSet { if lineLimit != oldValue { quadCache = nil; laidOutText = nil; NGFrameModel.noteChange() } }
    }
    /// In an editable column with choices: the pop-up's chevron at the trailing edge.
    var showsChoiceChevron = false {
        didSet { if showsChoiceChevron != oldValue { quadCache = nil; NGFrameModel.noteChange() } }
    }
    /// An editable rating under the pointer: the value a click would set.
    var previewRating: Int? {
        didSet { if previewRating != oldValue { NGFrameModel.noteChange() } }
    }

    /// Selected rows in a focused table use inverted colors.
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { NGFrameModel.noteChange() } }
    }

    /// The cell's frame in its region's canvas.
    var cellFrame: CGRect = .zero {
        didSet { if cellFrame != oldValue { NGFrameModel.noteChange() } }
    }

    /// Spare cells (in the pool) are hidden.
    var isHidden = false {
        didSet { if isHidden != oldValue { NGFrameModel.noteChange() } }
    }

    /// The column and display row whose value the cell will show, while it
    /// hasn't been read yet.
    var unresolvedSource: (column: NGTableColumn, ordinal: Int, row: Int)?

    /// Whether the cell draws nothing.
    var isEmpty: Bool {
        switch content {
        case .text(let text, _, _): text.isEmpty
        case .tags(let tags): tags.isEmpty
        case .subtotal(let text, _): text.isEmpty
        case .sparkline(let sparkline): sparkline.values.isEmpty
        case .link(let link, _): link.title.isEmpty
        case .button, .progress: false
        case .rating(_, let maximum, _, _): maximum <= 0
        case .number, .mark, .groupTitle, .media: false
        }
    }

    func move(to cellFrame: CGRect) {
        self.cellFrame = cellFrame
    }
}

/// A visible row background: color, rounded corners and a leading marker.
@MainActor
final class NGRowBackground {
    /// In its region's canvas.
    var frame: CGRect = .zero {
        didSet { if frame != oldValue { NGFrameModel.noteChange() } }
    }
    private(set) var color: NSColor?
    private(set) var markerColor: NSColor?
    private(set) var cornerRadius: CGFloat = 0
    private(set) var maskedCorners: CACornerMask = []
    var isHidden = false {
        didSet { if isHidden != oldValue { NGFrameModel.noteChange() } }
    }

    /// Colors are compared by identity: apps give the same color objects, and
    /// dynamic colors are resolved when drawn (for the current appearance).
    func setColors(_ color: NSColor, marker: NSColor?) {
        guard color !== self.color || marker !== markerColor else { return }
        self.color = color
        markerColor = marker
        NGFrameModel.noteChange()
    }

    func setShape(cornerRadius: CGFloat, corners: CACornerMask) {
        guard cornerRadius != self.cornerRadius || corners != maskedCorners else { return }
        self.cornerRadius = cornerRadius
        maskedCorners = corners
        NGFrameModel.noteChange()
    }
}

// MARK: - Fonts, metrics, colors

/// Metrics of the cell fonts, measured once.
struct NGCellTextMetrics: Sendable {
    let textLineHeight: CGFloat
    let tagLineHeight: CGFloat

    @MainActor static let shared = NGCellTextMetrics(
        textLineHeight: ceil(NSAttributedString(string: "Xg", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).size().height),
        tagLineHeight: NSAttributedString(string: "Xg", attributes: [.font: NGCellDrawing.tagFont]).size().height
    )
}

/// The colors cells are drawn with, resolved for one appearance.
final class NGCellPalette: @unchecked Sendable {
    let text: CGColor
    /// Less prominent text, e.g. the row count of a group header.
    let secondaryText: CGColor
    let highlightedText: CGColor
    let highlightedTagFill: CGColor
    let tags: [NGNamedColor: (text: CGColor, fill: CGColor)]

    init(text: CGColor, secondaryText: CGColor, highlightedText: CGColor, highlightedTagFill: CGColor,
         tags: [NGNamedColor: (text: CGColor, fill: CGColor)]) {
        self.text = text
        self.secondaryText = secondaryText
        self.highlightedText = highlightedText
        self.highlightedTagFill = highlightedTagFill
        self.tags = tags
    }

    @MainActor private static var palettes: [NSAppearance.Name: NGCellPalette] = [:]

    @MainActor static func resolved(for appearance: NSAppearance) -> NGCellPalette {
        if let palette = palettes[appearance.name] { return palette }
        var palette: NGCellPalette?
        appearance.performAsCurrentDrawingAppearance {
            var tags: [NGNamedColor: (text: CGColor, fill: CGColor)] = [:]
            for color in NGNamedColor.allCases {
                tags[color] = (color.systemColor.cgColor, color.systemColor.withAlphaComponent(0.16).cgColor)
            }
            palette = NGCellPalette(
                text: NSColor.labelColor.cgColor,
                secondaryText: NSColor.secondaryLabelColor.cgColor,
                // On an emphasized selection text, tags and marks turn white.
                highlightedText: NSColor.alternateSelectedControlTextColor.cgColor,
                highlightedTagFill: NSColor.white.withAlphaComponent(0.22).cgColor,
                tags: tags
            )
        }
        palettes[appearance.name] = palette
        return palette!
    }

    /// System colors changed (accent, contrast): resolve them again.
    @MainActor static func removeAll() {
        palettes.removeAll()
    }
}

/// Fonts, shapes and measuring of default cells.
@MainActor
extension NGCellDrawing {
    static let tagFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)


    /// A disclosure chevron like an outline view's: pointing to the trailing
    /// side when collapsed, down when expanded (in a context whose y axis points down).
    static func drawChevron(in rect: CGRect, expanded: Bool, color: CGColor, context: CGContext) {
        let size: CGFloat = 3.5
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if expanded {
            context.move(to: CGPoint(x: center.x - size, y: center.y - size / 2))
            context.addLine(to: CGPoint(x: center.x, y: center.y + size / 2))
            context.addLine(to: CGPoint(x: center.x + size, y: center.y - size / 2))
        } else {
            context.move(to: CGPoint(x: center.x - size / 2, y: center.y - size))
            context.addLine(to: CGPoint(x: center.x + size / 2, y: center.y))
            context.addLine(to: CGPoint(x: center.x - size / 2, y: center.y + size))
        }
        context.strokePath()
        context.restoreGState()
    }

    /// Where a mark of `size` goes in a cell.
    static func markRect(size: CGSize, alignment: NSTextAlignment, in bounds: CGRect) -> CGRect {
        let x: CGFloat = switch alignment {
        case .center: ((bounds.width - size.width) / 2).rounded()
        case .right: bounds.width - NGMetrics.cellPadding - size.width
        default: NGMetrics.cellPadding
        }
        return CGRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    /// White symbol images by name (tinted when drawn), made once.
    private static var markImages: [String: NSImage] = [:]

    /// A checked check box: a filled square with the checkmark cut out (the
    /// atlas tints icons in one color, which would fill a symbol's checkmark too).
    static let checkedBoxName = "ngtable.checkbox.checked"

    static func markImage(_ name: String) -> NSImage? {
        if let image = markImages[name] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: NGMetrics.markPointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if name == checkedBoxName {
            guard let box = NSImage(systemSymbolName: "square.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration),
                  let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: NGMetrics.markPointSize * 0.62, weight: .bold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))) else { return nil }
            let image = NSImage(size: box.size, flipped: false) { rect in
                box.draw(in: rect)
                let size = check.size
                check.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .destinationOut, fraction: 1)
                return true
            }
            markImages[name] = image
            return image
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        markImages[name] = image
        return image
    }

    /// The column width that shows all tags, for autofitting: measured by
    /// the renderer's text shaper (the widths tags are drawn with), or by
    /// attributed strings without one.
    static func fittingWidth(of tags: [NGTag], shaper: NGTextShaper? = nil) -> CGFloat {
        guard !tags.isEmpty else { return 0 }
        func width(of title: String) -> CGFloat {
            if let shaper { return shaper.shape(title, font: tagFont, width: .greatestFiniteMagnitude).width }
            return NSAttributedString(string: title, attributes: [.font: tagFont]).size().width
        }
        let widths = tags.map { ceil(width(of: $0.title)) + 2 * NGMetrics.tagPadding }
        return widths.reduce(0, +) + CGFloat(tags.count - 1) * NGMetrics.tagSpacing + 2 * NGMetrics.cellPadding
    }

    /// The column width that shows a mark, for autofitting.
    static func fittingWidth(of mark: NGMark) -> CGFloat {
        guard let width = markImage(mark.symbolName)?.size.width else { return 0 }
        return width + 2 * NGMetrics.cellPadding
    }
}

#endif
