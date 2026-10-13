import Foundation

/// A filter on one column's values, like a spreadsheet's column filter (see
/// `NGTableView.columnFilters`). A row is shown when it passes every column
/// filter, the `rowFilter` and isn't hidden.
public enum NGColumnFilter: Codable, Sendable, Hashable {
    /// Rows whose value, as displayed, is one of these; empty cells display
    /// as "". An empty set shows no rows.
    case values(Set<String>)
    /// Rows whose value, as displayed, is none of these: what unchecking a
    /// few values among many gives, so values the list didn't show (beyond
    /// its limit, or arriving later) stay shown.
    case excluding(Set<String>)
    /// Rows whose value is a number within the bounds (inclusive); `nil`
    /// bounds are open. Values that aren't numbers don't pass.
    case range(min: Double?, max: Double?)
    /// Rows whose value, as displayed, contains the text (ignoring case and
    /// diacritics).
    case contains(String)

    /// Whether the filter lets every row through (an open range, no text):
    /// the table drops such filters.
    public var isEmpty: Bool {
        switch self {
        case .values: false
        case .excluding(let values): values.isEmpty
        case .range(let min, let max): min == nil && max == nil
        case .contains(let text): text.isEmpty
        }
    }

    /// Whether the filter needs a value's displayed text (`range` doesn't).
    var needsText: Bool {
        if case .range = self { return false }
        return true
    }

    /// Whether a value passes; `text` is its displayed text.
    func matches(_ value: NGCellValue, text: String) -> Bool {
        switch self {
        case .values(let values):
            return values.contains(text)
        case .excluding(let values):
            return !values.contains(text)
        case .range(let min, let max):
            guard let number = value.numericValue, !number.isNaN else { return false }
            if let min, number < min { return false }
            if let max, number > max { return false }
            return true
        case .contains(let needle):
            return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
