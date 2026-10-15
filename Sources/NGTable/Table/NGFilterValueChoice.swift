#if os(macOS) || os(iOS)
import Foundation

// What a column filter's popover edits, for both platforms' popovers (the
// Mac's NGColumnFilterViewController, the iPad's NGColumnFilterController):
// the values checked in a value filter and the filter they make, the date
// periods offered, and the bounds typed for numbers.

/// The values a value filter offers and those checked.
struct NGFilterValueChoice {
    /// Every value the column offers, with its rows, and those checked.
    private(set) var values: [(value: String, count: Int)]
    private(set) var checked: Set<String>
    /// Whether the column has more values than the list shows.
    let isTruncated: Bool
    /// Values a filter excluded that the list doesn't show: they stay excluded.
    let excludedElsewhere: Set<String>
    /// A list that doesn't show every value either shows only the values
    /// checked (`true`: opened over such a filter, or after everything was
    /// unchecked) or hides the ones unchecked, so values not listed stay.
    private(set) var showsOnlyChecked: Bool

    @MainActor
    init(table: NGTableView, columnID: String, limit: Int = 1_000) {
        let offered = table.filterValueList(forColumnID: columnID, limit: limit)
        values = offered.values
        isTruncated = offered.isTruncated
        let listed = Set(values.map(\.value))
        switch table.columnFilters[columnID] {
        case .values(let selected)?:
            checked = selected
            showsOnlyChecked = true
            excludedElsewhere = []
        case .excluding(let excluded)?:
            checked = listed.subtracting(excluded)
            excludedElsewhere = excluded.subtracting(listed)
            showsOnlyChecked = false
        default:
            checked = listed
            excludedElsewhere = []
            showsOnlyChecked = false
        }
    }

    /// The values matching a search.
    func shown(matching search: String) -> [(value: String, count: Int)] {
        values.filter { value, _ in
            search.isEmpty || value.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    mutating func set(_ value: String, checked isChecked: Bool) {
        if isChecked { checked.insert(value) } else { checked.remove(value) }
    }

    /// Every value checked: no filter. A list that doesn't show every value
    /// hides the unchecked ones (values not listed, or arriving later, stay
    /// shown), unless it shows only the checked ones: opened over such a
    /// filter, or once nothing is checked. A full list: whichever is shorter.
    mutating func filter() -> NGColumnFilter? {
        let all = Set(values.map(\.value))
        let unchecked = all.subtracting(checked)
        if unchecked.isEmpty, excludedElsewhere.isEmpty {
            showsOnlyChecked = false
            return nil
        }
        if isTruncated || !excludedElsewhere.isEmpty {
            if checked.isEmpty { showsOnlyChecked = true }
            return showsOnlyChecked ? .values(checked) : .excluding(unchecked.union(excludedElsewhere))
        }
        return unchecked.count <= checked.count ? .excluding(unchecked) : .values(checked)
    }

    /// The date periods a date column's filter offers; the last one is two days chosen.
    static let periods: [(period: NGDatePeriod?, title: String)] = [
        (nil, String(localized: "Any Date", bundle: .module, comment: "Column filter: no date period.")),
        (.today, String(localized: "Today", bundle: .module, comment: "Column filter: a date period.")),
        (.yesterday, String(localized: "Yesterday", bundle: .module, comment: "Column filter: a date period.")),
        (.thisWeek, String(localized: "This Week", bundle: .module, comment: "Column filter: a date period.")),
        (.lastWeek, String(localized: "Last Week", bundle: .module, comment: "Column filter: a date period.")),
        (.thisMonth, String(localized: "This Month", bundle: .module, comment: "Column filter: a date period.")),
        (.lastMonth, String(localized: "Last Month", bundle: .module, comment: "Column filter: a date period.")),
        (.thisYear, String(localized: "This Year", bundle: .module, comment: "Column filter: a date period.")),
        (.lastYear, String(localized: "Last Year", bundle: .module, comment: "Column filter: a date period.")),
        (.lastDays(7), String(localized: "Last 7 Days", bundle: .module, comment: "Column filter: a date period.")),
        (.lastDays(30), String(localized: "Last 30 Days", bundle: .module, comment: "Column filter: a date period.")),
        (.between(start: nil, end: nil), String(localized: "Between Two Days", bundle: .module, comment: "Column filter: dates from one day to another.")),
    ]

    /// The filter of the days from one to another (both whole).
    static func days(from first: Date, to last: Date, calendar: Calendar) -> NGColumnFilter {
        let start = calendar.startOfDay(for: min(first, last))
        let end = calendar.startOfDay(for: max(first, last))
        return .dates(.between(start: start, end: calendar.date(byAdding: .day, value: 1, to: end)))
    }

    /// A bound typed for a number column ("25%" in a percent column is 0.25).
    static func bound(_ text: String, format: NGValueFormat, formatter: NumberFormatter) -> Double? {
        let text = text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        let scale: Double = if case .percent = format { 100 } else { 1 }
        return formatter.number(from: text).map { $0.doubleValue / scale }
    }
}
#endif
