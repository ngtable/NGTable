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
    /// Rows whose value is a date in the period, in the table's `calendar`
    /// (relative periods such as "this week" are taken from the day the
    /// rows are filtered on). Values that aren't dates don't pass.
    case dates(NGDatePeriod)
    /// Rows whose number is among the `count` largest of the column, like a
    /// spreadsheet's "Top 10": every row with a value at least the
    /// `count`-th largest (rows tied with it too). Of all the rows, whatever
    /// the other filters show; values that aren't numbers don't pass.
    case top(Int)
    /// Rows whose number is among the `count` smallest of the column (see `top`).
    case bottom(Int)

    /// Whether the filter lets every row through (an open range, no text):
    /// the table drops such filters.
    public var isEmpty: Bool {
        switch self {
        case .values, .top, .bottom: false
        case .excluding(let values): values.isEmpty
        case .range(let min, let max): min == nil && max == nil
        case .contains(let text): text.isEmpty
        case .dates(let period): period == .between(start: nil, end: nil)
        }
    }

    /// Whether the filter needs a value's displayed text (ranges, dates and
    /// ranks don't).
    var needsText: Bool {
        switch self {
        case .values, .excluding, .contains: true
        case .range, .dates, .top, .bottom: false
        }
    }

    /// Whether which rows pass depends on the other rows' values (`top`, `bottom`).
    var isRank: Bool {
        switch self {
        case .top, .bottom: true
        default: false
        }
    }

    /// The filter as it applies now: a period from today in the calendar, as
    /// dates between two instants (rank filters are made ranges by the table).
    func resolved(calendar: Calendar, now: Date) -> NGColumnFilter {
        guard case .dates(let period) = self else { return self }
        let interval = period.interval(in: calendar, now: now)
        return .dates(.between(start: interval.start, end: interval.end))
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
        case .dates(let period):
            // (Resolved: between two instants.)
            guard case .date(let date) = value, case .between(let start, let end) = period else { return false }
            if let start, date < start { return false }
            if let end, date >= end { return false }
            return true
        case .top, .bottom:
            // Made ranges by the table, by the column's values.
            return false
        }
    }
}

/// A period of dates for a column filter (`NGColumnFilter.dates`): the days of
/// a calendar around today, the last days, or between two instants.
public enum NGDatePeriod: Codable, Sendable, Hashable {
    case today
    case yesterday
    /// The calendar's week of today (its first weekday by the locale).
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case thisYear
    case lastYear
    /// The last `days` days, today included.
    case lastDays(Int)
    /// From `start` (included) to `end` (not included); `nil` bounds are open.
    case between(start: Date?, end: Date?)

    /// The period's instants: from its first day's start to the start of the
    /// day after its last (`between` as it is).
    public func interval(in calendar: Calendar, now: Date = Date()) -> (start: Date?, end: Date?) {
        func span(_ component: Calendar.Component, back: Int) -> (start: Date?, end: Date?) {
            guard let current = calendar.dateInterval(of: component, for: now),
                  let start = calendar.date(byAdding: component, value: -back, to: current.start),
                  let end = calendar.date(byAdding: component, value: 1, to: start) else { return (nil, nil) }
            return (start, end)
        }
        switch self {
        case .today: return span(.day, back: 0)
        case .yesterday: return span(.day, back: 1)
        case .thisWeek: return span(.weekOfYear, back: 0)
        case .lastWeek: return span(.weekOfYear, back: 1)
        case .thisMonth: return span(.month, back: 0)
        case .lastMonth: return span(.month, back: 1)
        case .thisYear: return span(.year, back: 0)
        case .lastYear: return span(.year, back: 1)
        case .lastDays(let days):
            let today = calendar.startOfDay(for: now)
            return (calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today), calendar.date(byAdding: .day, value: 1, to: today))
        case .between(let start, let end):
            return (start, end)
        }
    }
}
