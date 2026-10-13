import Foundation

// How a sort descriptor compares text when the table sorts, from its
// selector, as an app sorting for NSTableView passes it. NSSortDescriptor's
// default, `compare:`, keeps the table's order (`localizedStandardCompare`,
// Finder's: numbers in text by value), so descriptors made without a
// selector sort as before; the localized and case-insensitive comparisons
// are honored. Other selectors (and comparators) aren't called: they compare
// as the default.

/// How text compares for a sort descriptor.
nonisolated enum NGTextComparison: Sendable, Hashable {
    /// `localizedStandardCompare:` (and `compare:`, the default).
    case standard
    /// `localizedCompare:`.
    case localized
    /// `localizedCaseInsensitiveCompare:`.
    case localizedCaseInsensitive
    /// `caseInsensitiveCompare:`: by character, not by the language's rules.
    case caseInsensitive

    init(_ descriptor: NSSortDescriptor) {
        switch descriptor.selector.map(NSStringFromSelector) {
        case "localizedCompare:": self = .localized
        case "localizedCaseInsensitiveCompare:": self = .localizedCaseInsensitive
        case "caseInsensitiveCompare:": self = .caseInsensitive
        default: self = .standard
        }
    }

    /// The options of `compare(_:options:range:locale:)` it is.
    var options: NSString.CompareOptions {
        switch self {
        case .standard: NGTextCollation.options
        case .localized: []
        case .localizedCaseInsensitive, .caseInsensitive: .caseInsensitive
        }
    }

    /// Whether it compares by the current locale's collation.
    var isLocalized: Bool { self != .caseInsensitive }

    func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        switch self {
        case .standard: lhs.localizedStandardCompare(rhs)
        case .localized: lhs.localizedCompare(rhs)
        case .localizedCaseInsensitive: lhs.localizedCaseInsensitiveCompare(rhs)
        case .caseInsensitive: lhs.caseInsensitiveCompare(rhs)
        }
    }
}
