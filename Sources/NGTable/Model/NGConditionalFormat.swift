import Foundation

/// How a number column's cells look by their values (see
/// ``NGTableColumn/conditionalFormat``): bars in proportion to the value, a
/// background on a color scale, or the text colored by rules, like a
/// spreadsheet's conditional formatting. Only numbers are formatted.
public enum NGConditionalFormat: Sendable, Hashable {
    /// A bar behind the value, as long as the value is within `range`;
    /// negative values grow the other way from zero, in `negative`.
    case dataBar(NGNamedColor = .blue, negative: NGNamedColor = .red, range: NGValueRange = .automatic)
    /// A background from `low` (the smallest value of `range`) to `high`.
    case colorScale(low: NGNamedColor, high: NGNamedColor, range: NGValueRange = .automatic)
    /// The text in the color of the first rule the value passes.
    case textColor([NGColorRule])

    /// The range of values the format scales over, if it has one.
    var range: NGValueRange? {
        switch self {
        case .dataBar(_, _, let range), .colorScale(_, _, let range): range
        case .textColor: nil
        }
    }
}

/// The values a data bar or color scale spans.
public enum NGValueRange: Sendable, Hashable {
    /// From the smallest to the largest value of the rows the filter shows,
    /// rows of collapsed groups included (kept up to date as values change).
    case automatic
    /// Fixed bounds; values outside them count as the nearest bound.
    case fixed(min: Double, max: Double)
}

/// A rule of a `.textColor` format: a condition on the value and a color.
public struct NGColorRule: Sendable, Hashable {
    public enum Condition: Sendable, Hashable {
        case below(Double)
        case above(Double)
        /// Inclusive.
        case between(Double, Double)
    }

    public var condition: Condition
    public var color: NGNamedColor

    public init(_ condition: Condition, color: NGNamedColor) {
        self.condition = condition
        self.color = color
    }

    /// Whether a value passes the rule.
    public func matches(_ value: Double) -> Bool {
        switch condition {
        case .below(let bound): value < bound
        case .above(let bound): value > bound
        case .between(let low, let high): value >= low && value <= high
        }
    }
}
