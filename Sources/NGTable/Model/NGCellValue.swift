import CoreGraphics
import Foundation

/// Colors of tags and marks, named like the system colors they are drawn
/// with, so the model stays independent of AppKit and UIKit.
public enum NGNamedColor: String, Sendable, Hashable, Codable, CaseIterable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray
}

/// A small colored label, e.g. a campaign's status or its labels.
public struct NGTag: Sendable, Hashable, Codable {
    /// The text in the capsule.
    public var title: String
    /// The capsule's color; its text uses the same hue.
    public var color: NGNamedColor

    public init(_ title: String, color: NGNamedColor = .gray) {
        self.title = title
        self.color = color
    }
}

/// A small icon, e.g. thumbs up, star or percent, in a mark column.
public struct NGMark: Sendable, Hashable, Codable {
    /// An SF Symbols name, such as `hand.thumbsup.fill`, `star.fill` or `percent`.
    public var symbolName: String
    /// `nil` draws the symbol in the secondary label color.
    public var color: NGNamedColor?
    /// What the mark means, shown as its tool tip and used by VoiceOver,
    /// copying, searching and sorting.
    public var label: String

    public init(_ symbolName: String, color: NGNamedColor? = nil, label: String) {
        self.symbolName = symbolName
        self.color = color
        self.label = label
    }
}

/// A picture or a video with lines of text beside it, e.g. an ad creative:
/// the table loads the picture by URL (cached in memory and on disk),
/// plays the video or animates the GIF under the pointer, and draws the
/// text in up to a few styled lines.
///
/// ```swift
/// .media(NGMedia(image: thumbnailURL, motion: .video(videoURL), badge: "video.fill", lines: [
///     .init(teaser.title, style: .title, maximumLines: 2),
///     .init(teaser.site),
/// ]))
/// ```
public struct NGMedia: Sendable, Hashable {
    /// What plays under the pointer, muted and looping.
    public enum Motion: Sendable, Hashable {
        /// A video file or stream. Its first second gives the still picture
        /// (`image` is the fallback).
        case video(URL)
        /// An animated image (GIF). `image`, or else its first frame, is the still picture.
        case animatedImage(URL)
    }

    /// A line of text beside the picture.
    public struct Line: Sendable, Hashable {
        public enum Style: Sendable, Hashable {
            /// The main line: the table's font, medium weight.
            case title
            /// A smaller line in the secondary label color.
            case secondary
            /// A smaller line in a color, e.g. a comment.
            case colored(NGNamedColor)
        }

        public var text: String
        public var style: Style
        /// Lines it may wrap to; the last one is truncated.
        public var maximumLines: Int

        public init(_ text: String, style: Style = .secondary, maximumLines: Int = 1) {
            self.text = text
            self.style = style
            self.maximumLines = max(1, maximumLines)
        }
    }

    /// The still picture (also of a GIF), loaded by the table.
    public var image: URL?
    public var motion: Motion?
    /// An SF Symbols name shown in the picture's corner, e.g. `video.fill`.
    public var badge: String?
    /// An SF Symbols name shown while there is no picture (yet).
    public var placeholder: String
    /// The picture's size in points; the picture fills it, cropped to its proportions.
    public var thumbnailSize: CGSize
    public var cornerRadius: CGFloat
    public var lines: [Line]
    /// Shown when the pointer rests on the cell; the lines by default.
    public var toolTip: String?

    public init(image: URL?, motion: Motion? = nil, badge: String? = nil, placeholder: String = "photo",
                thumbnailSize: CGSize = CGSize(width: 104, height: 68), cornerRadius: CGFloat = 6,
                lines: [Line] = [], toolTip: String? = nil) {
        self.image = image
        self.motion = motion
        self.badge = badge
        self.placeholder = placeholder
        self.thumbnailSize = thumbnailSize
        self.cornerRadius = cornerRadius
        self.lines = lines
        self.toolTip = toolTip
    }

    /// The lines as one text, for copying, searching, sorting and VoiceOver.
    public var text: String {
        lines.map(\.text).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A small chart of a series in a cell: a trend, a price over the day, wins and losses.
///
/// ```swift
/// .sparkline(NGSparkline(prices, style: .area, showsLastPoint: true))
/// ```
///
/// Drawn by the table as a few hundred vertices, no text: a live feed that
/// appends a value and drops the first redraws only that cell.
public struct NGSparkline: Sendable, Hashable {
    public enum Style: Sendable, Hashable {
        /// A line through the values.
        case line
        /// The line with the area under it filled.
        case area
        /// A bar per value, up from the bottom of the range (or from zero
        /// when the range spans it: negative values hang below).
        case bars
        /// Wins and losses: a bar up for a positive value, down for a
        /// negative one, all of one height (zero draws nothing).
        case winLoss
    }

    /// The series, oldest first; NaN is a gap.
    public var values: [Double]
    /// The values' range the cell's height shows, `nil` for their own
    /// (lowest to highest). Give a shared range to compare rows.
    public var range: ClosedRange<Double>?
    /// `nil` draws in the accent color (wins and losses: green and red).
    public var color: NGNamedColor?
    public var style: Style
    /// A dot on the last value.
    public var showsLastPoint: Bool
    /// Dots on the lowest and the highest values.
    public var showsMinMax: Bool

    public init(_ values: [Double], range: ClosedRange<Double>? = nil, color: NGNamedColor? = nil, style: Style = .line,
                showsLastPoint: Bool = false, showsMinMax: Bool = false) {
        self.values = values
        self.range = range
        self.color = color
        self.style = style
        self.showsLastPoint = showsLastPoint
        self.showsMinMax = showsMinMax
    }

    /// The last value that isn't a gap: what the sparkline sorts by.
    public var lastValue: Double? { values.last { !$0.isNaN } }

    /// The lowest and highest values (gaps left out), `nil` without any.
    public var extremes: (min: Double, max: Double)? {
        var low = Double.infinity, high = -Double.infinity
        for value in values where !value.isNaN {
            low = min(low, value)
            high = max(high, value)
        }
        return low <= high ? (low, high) : nil
    }

    /// The range drawn: `range`, or the values' own (a flat series gets a
    /// unit around it, so it shows as a line in the middle).
    var drawnRange: ClosedRange<Double>? {
        if let range { return range.lowerBound < range.upperBound ? range : (range.lowerBound - 0.5)...(range.upperBound + 0.5) }
        guard let (low, high) = extremes else { return nil }
        return low < high ? low...high : (low - 0.5)...(high + 0.5)
    }
}

/// A link in a cell: its title in the link color, underlined under the
/// pointer, with the pointing hand. A click on it doesn't select the row:
/// it calls the delegate's `tableView(_:didClickLink:in:row:)`, which opens
/// `url` by default.
public struct NGLink: Sendable, Hashable {
    public var title: String
    public var url: URL?

    public init(_ title: String, url: URL? = nil) {
        self.title = title
        self.url = url
    }
}

/// A push button in a cell, drawn like a small `NSButton`: pressed and
/// released over it, it calls the delegate's
/// `tableView(_:didPressButton:in:row:)`; a press beside it selects the row.
public struct NGCellButton: Sendable, Hashable {
    public enum Role: Sendable, Hashable {
        case normal
        /// Its title in red, like a destructive action's.
        case destructive
    }

    public var title: String
    /// An SF Symbol before the title (`nil`: none).
    public var symbolName: String?
    /// A disabled button is dimmed and can't be pressed.
    public var isEnabled: Bool
    public var role: Role

    public init(_ title: String, symbolName: String? = nil, isEnabled: Bool = true, role: Role = .normal) {
        self.title = title
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.role = role
    }
}

/// A value displayed in a table cell.
///
/// 17 bytes, 24 in arrays: icons and media are boxed (`indirect`), so sort
/// keys, values read in the background and export buffers of millions of
/// cells don't pay for the largest payload (128 bytes inline).
public enum NGCellValue: Sendable, Hashable {
    /// No value: an empty cell, left out of summaries.
    case empty
    case text(String)
    /// A number, formatted by the column's `format` and used by summaries.
    /// NaN and infinity count as empty in summaries.
    case number(Double)
    /// `true` shows a check mark, `false` nothing.
    case bool(Bool)
    /// A date, formatted as `.date(includesTime:)` of the column's format
    /// says (abbreviated date, without time otherwise).
    case date(Date)
    /// Labels drawn as colored capsules.
    case tags([NGTag])
    /// An icon (use `.empty` for none).
    indirect case mark(NGMark)
    /// A picture or video with lines of text (see ``NGMedia``).
    indirect case media(NGMedia)
    /// A small chart of a series (see ``NGSparkline``). Sorts and sums by
    /// its last value.
    indirect case sparkline(NGSparkline)
    /// A link (see ``NGLink``). Sorts by its title.
    indirect case link(NGLink)
    /// A push button (see ``NGCellButton``). Sorts by its title.
    indirect case button(NGCellButton)
    /// A progress bar, like `NSProgressIndicator`'s: `value` of `total`
    /// filled; `nil` is indeterminate (a stripe moving along it). With a
    /// format on the column (`.percent`), the fraction is written beside the
    /// bar. Sorts, sums and exports as the fraction (`value / total`).
    indirect case progress(Double?, total: Double = 1)
    /// Stars, `value` of `maximum` filled. In an editable column a click on
    /// a star (or a number key on the focused cell) sets it through
    /// `tableView(_:setValue:for:row:)`. Sorts and sums as the number.
    case rating(Int, maximum: Int = 5)

    /// The value used by summary calculations. Only numbers participate.
    public var numericValue: Double? {
        switch self {
        case .number(let value): value
        case .sparkline(let sparkline): sparkline.lastValue
        case .progress(let value, let total): Self.fraction(value, total)
        case .rating(let value, _): Double(value)
        default: nil
        }
    }

    /// A progress value's fraction, 0...1 (`nil`: indeterminate).
    static func fraction(_ value: Double?, _ total: Double) -> Double? {
        guard let value, !value.isNaN, total > 0 else { return nil }
        return min(1, max(0, value / total))
    }

    /// Ordering used for sorting. Empty values always sort first; values of
    /// different kinds are ordered by kind.
    /// How this value sorts against another, in one comparison (sorting asked
    /// `sortsBefore` both ways, comparing text twice).
    func sortOrder(_ other: NGCellValue) -> ComparisonResult {
        switch (self, other) {
        case let (.text(lhs), .text(rhs)): return lhs.localizedStandardCompare(rhs)
        case let (.mark(lhs), .mark(rhs)): return lhs.label.localizedStandardCompare(rhs.label)
        case let (.media(lhs), .media(rhs)): return lhs.text.localizedStandardCompare(rhs.text)
        case let (.link(lhs), .link(rhs)): return lhs.title.localizedStandardCompare(rhs.title)
        case let (.button(lhs), .button(rhs)): return lhs.title.localizedStandardCompare(rhs.title)
        // Titles joined once each (not twice in each direction).
        case (.tags, .tags): return (sortText ?? "").localizedStandardCompare(other.sortText ?? "")
        default:
            if sortsBefore(other) { return .orderedAscending }
            return other.sortsBefore(self) ? .orderedDescending : .orderedSame
        }
    }

    /// The text a value sorts by when it sorts as text (text, a mark's label,
    /// media's text, tags joined), else `nil`.
    var sortText: String? {
        switch self {
        case .text(let text): text
        case .mark(let mark): mark.label
        case .media(let media): media.text
        case .link(let link): link.title
        case .button(let button): button.title
        case .tags(let tags): tags.map(\.title).joined(separator: ", ")
        default: nil
        }
    }

    /// `sortOrder(_:)` with text compared another way (a descriptor's selector).
    func sortOrder(_ other: NGCellValue, comparison: NGTextComparison) -> ComparisonResult {
        guard comparison != .standard else { return sortOrder(other) }
        switch (self, other) {
        case (.text, .text), (.mark, .mark), (.media, .media), (.tags, .tags), (.link, .link), (.button, .button):
            guard let lhs = sortText, let rhs = other.sortText else { return sortOrder(other) }
            return comparison.compare(lhs, rhs)
        default:
            return sortOrder(other)
        }
    }

    /// `sortOrder(_:)` with text compared by a worker of `collation` (on
    /// several threads at once without a lock).
    func sortOrder(_ other: NGCellValue, collation: NGTextCollation, worker: Int,
                   comparison: NGTextComparison = .standard) -> ComparisonResult {
        switch (self, other) {
        case (.text, .text), (.mark, .mark), (.media, .media), (.tags, .tags), (.link, .link), (.button, .button):
            guard let lhs = sortText, let rhs = other.sortText else { return sortOrder(other) }
            return collation.compare(lhs, rhs, worker: worker, comparison: comparison)
        default:
            return sortOrder(other)
        }
    }

    public func sortsBefore(_ other: NGCellValue) -> Bool {
        // NaN sorts like an empty value, on every path (summaries count it as empty too).
        if isNaN || other.isNaN { return (isNaN ? NGCellValue.empty : self).sortsBefore(other.isNaN ? .empty : other) }
        return switch (self, other) {
        case let (.text(lhs), .text(rhs)): lhs.localizedStandardCompare(rhs) == .orderedAscending
        case let (.number(lhs), .number(rhs)): lhs < rhs
        case let (.bool(lhs), .bool(rhs)): !lhs && rhs
        case let (.date(lhs), .date(rhs)): lhs < rhs
        case let (.rating(lhs, _), .rating(rhs, _)): lhs < rhs
        case let (.progress(lhsValue, lhsTotal), .progress(rhsValue, rhsTotal)):
            // By the fraction; indeterminate first, like an empty cell.
            switch (Self.fraction(lhsValue, lhsTotal), Self.fraction(rhsValue, rhsTotal)) {
            case let (a?, b?): a < b
            case (nil, _?): true
            default: false
            }
        case let (.sparkline(lhs), .sparkline(rhs)):
            // By the last value; one without values first, like an empty cell.
            switch (lhs.lastValue, rhs.lastValue) {
            case let (a?, b?): a < b
            case (nil, _?): true
            default: false
            }
        case let (.mark(lhs), .mark(rhs)):
            lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        case let (.media(lhs), .media(rhs)):
            lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending
        case let (.link(lhs), .link(rhs)):
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case let (.button(lhs), .button(rhs)):
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case let (.tags(lhs), .tags(rhs)):
            // One tag each (the usual case): the titles themselves, no joined copies.
            if lhs.count == 1, rhs.count == 1 {
                lhs[0].title.localizedStandardCompare(rhs[0].title) == .orderedAscending
            } else {
                lhs.map(\.title).joined(separator: ", ").localizedStandardCompare(rhs.map(\.title).joined(separator: ", ")) == .orderedAscending
            }
        default: kindRank < other.kindRank
        }
    }

    /// A number that is NaN (sorted like `.empty`).
    var isNaN: Bool {
        if case .number(let number) = self { return number.isNaN }
        return false
    }

    private var kindRank: Int {
        switch self {
        case .empty: 0
        case .bool: 1
        case .number: 2
        case .date: 3
        case .text: 4
        case .tags: 5
        case .mark: 6
        case .media: 7
        case .sparkline: 8
        case .link: 9
        case .button: 10
        case .progress: 11
        case .rating: 12
        }
    }
}

extension NGCellValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
}

/// How a column turns values into display strings.
public enum NGValueFormat: Sendable, Hashable {
    /// Numbers with the locale's default formatting, text as is.
    case automatic
    /// Numbers with a fixed number of fraction digits, e.g. `1 234,50`.
    case number(fractionDigits: Int)
    /// Amounts in an ISO 4217 currency, e.g. `currency(code: "EUR")`.
    case currency(code: String)
    /// `0.25` is displayed as `25%`.
    case percent(fractionDigits: Int)
    case date(includesTime: Bool)

    /// Whether the format is for numbers (their columns align to the trailing
    /// edge with `.automatic` alignment).
    public var isNumeric: Bool {
        switch self {
        case .number, .currency, .percent: true
        case .automatic, .date: false
        }
    }

    /// The text a cell shows for a value.
    public func string(for value: NGCellValue, locale: Locale = .current) -> String {
        switch value {
        case .empty:
            return ""
        case .text(let text):
            return text
        case .number(let number):
            return string(for: number, locale: locale)
        case .bool(let flag):
            return flag ? "✓" : ""
        case .date(let date):
            let includesTime = if case .date(let time) = self { time } else { false }
            let style = Date.FormatStyle(date: .abbreviated, time: includesTime ? .shortened : .omitted)
            return date.formatted(style.locale(locale))
        case .tags(let tags):
            return tags.map(\.title).joined(separator: ", ")
        case .mark(let mark):
            return mark.label
        case .media(let media):
            return media.text
        case .link(let link):
            return link.title
        case .button(let button):
            return button.title
        case .rating(let value, _):
            return string(for: Double(value), locale: locale)
        case .progress(let value, let total):
            // The fraction in the column's format ("45%"), as a percentage without one.
            guard let fraction = NGCellValue.fraction(value, total) else { return "" }
            if case .automatic = self { return NGValueFormat.percent(fractionDigits: 0).string(for: fraction, locale: locale) }
            return string(for: fraction, locale: locale)
        case .sparkline(let sparkline):
            // Its values in the column's format, oldest first (copied and exported so).
            return sparkline.values.map { $0.isNaN ? "" : string(for: $0, locale: locale) }.joined(separator: " ")
        }
    }

    /// The text for a number, e.g. a summary value.
    public func string(for number: Double, locale: Locale = .current) -> String {
        NGNumberStyle(self, locale: locale).string(for: number)
    }
}

/// The number style of a value format, made once: making the style for
/// every number cost about a fifth of formatting it. A value (`Sendable`),
/// so the table makes it on the main actor and formats with copies of it on
/// every core, without a lock. Gives the text of `NGValueFormat.string(for:locale:)`.
struct NGNumberStyle: Sendable {
    private enum Style: Sendable {
        case number(FloatingPointFormatStyle<Double>)
        case currency(FloatingPointFormatStyle<Double>.Currency)
        case percent(FloatingPointFormatStyle<Double>.Percent)
    }

    private let style: Style

    init(_ format: NGValueFormat, locale: Locale = .current) {
        style = switch format {
        case .number(let digits): .number(FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(digits)))
        case .currency(let code): .currency(FloatingPointFormatStyle<Double>.Currency(code: code, locale: locale))
        case .percent(let digits): .percent(FloatingPointFormatStyle<Double>.Percent(locale: locale).precision(.fractionLength(digits)))
        case .automatic, .date: .number(FloatingPointFormatStyle<Double>(locale: locale))
        }
    }

    func string(for number: Double) -> String {
        let text = formatted(number)
        // A negative number that rounds to zero (or -0) shows as zero: "-0",
        // "-0.00%" and "-$0.00" say nothing more, and look like a sign error.
        guard number.sign == .minus, number.isFinite,
              !text.contains(where: { ($0.wholeNumberValue ?? 0) != 0 }) else { return text }
        return formatted(0)
    }

    private func formatted(_ number: Double) -> String {
        switch style {
        case .number(let style): style.format(number)
        case .currency(let style): style.format(number)
        case .percent(let style): style.format(number)
        }
    }
}
