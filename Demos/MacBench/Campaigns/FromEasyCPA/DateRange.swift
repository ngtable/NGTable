//
//  DateRange.swift
//  NGTable Mac Bench
//
//  A copy of EasyCPA's campaigns table (as of October 2026) for the campaigns bench: the bench
//  shows NGTable on a real app's table. It doesn't follow EasyCPA's changes.

import Foundation

/// GraphQL `Range` input. Both bounds are sent as `NaiveDateTime` in UTC (see `JSONCoding`).
nonisolated struct DateRange: Encodable, Sendable, Hashable {
    var from: Date
    var to: Date

    /// UTC calendar used for all report day boundaries. The API treats naive timestamps as UTC.
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Whole UTC days from the calendar day of `firstDay` through the calendar day of `lastDay`.
    ///
    /// The days are taken as the user sees them in the local calendar (what a `DatePicker` returns),
    /// then re-anchored to UTC midnight so the wire strings read `YYYY-MM-DDT00:00:00`.
    static func wholeDays(fromLocalDay firstDay: Date, toLocalDay lastDay: Date) -> DateRange {
        let start = utcStartOfDay(matchingLocalDay: min(firstDay, lastDay))
        let end = utcStartOfDay(matchingLocalDay: max(firstDay, lastDay))
        return DateRange(from: start, to: endOfDay(startingAt: end))
    }

    /// UTC midnight of the local calendar day containing `date`.
    static func utcStartOfDay(matchingLocalDay date: Date) -> Date {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return utcCalendar.date(from: components) ?? utcCalendar.startOfDay(for: date)
    }

    /// 23:59:59 of the UTC day that starts at `start`.
    static func endOfDay(startingAt start: Date) -> Date {
        (utcCalendar.date(byAdding: .day, value: 1, to: start) ?? start).addingTimeInterval(-1)
    }
}

/// Report period presets, mirroring the web UI list.
nonisolated enum DateRangePreset: String, CaseIterable, Identifiable, Sendable, Hashable {
    case today
    case yesterday
    case thisWeek
    case last2Days
    case last7Days
    case last14Days
    case last30Days
    case previousMonth
    case thisMonth
    case last90Days
    case last180Days
    case thisYear
    case allTime
    case custom

    var id: String { rawValue }

    /// Full name for menus.
    var title: String {
        switch self {
        case .today: "Сегодня"
        case .yesterday: "Вчера"
        case .thisWeek: "Эта неделя"
        case .last2Days: "Последние 2 дня"
        case .last7Days: "Последние 7 дней"
        case .last14Days: "Последние 14 дней"
        case .last30Days: "Последние 30 дней"
        case .previousMonth: "Предыдущий месяц"
        case .thisMonth: "Этот месяц"
        case .last90Days: "Последние 90 дней"
        case .last180Days: "Последние 180 дней"
        case .thisYear: "Этот год"
        case .allTime: "За всё время"
        case .custom: "Выбрать даты…"
        }
    }

    /// Compact name for the toolbar button.
    var shortTitle: String {
        switch self {
        case .today: "Сегодня"
        case .yesterday: "Вчера"
        case .thisWeek: "Неделя"
        case .last2Days: "2 дня"
        case .last7Days: "7 дней"
        case .last14Days: "14 дней"
        case .last30Days: "30 дней"
        case .previousMonth: "Прошлый месяц"
        case .thisMonth: "Этот месяц"
        case .last90Days: "90 дней"
        case .last180Days: "180 дней"
        case .thisYear: "Этот год"
        case .allTime: "Всё время"
        case .custom: "Диапазон"
        }
    }

    /// Presets shown in the period menu, in web order. `custom` is handled separately.
    static let menuPresets: [DateRangePreset] = allCases.filter { $0 != .custom }

    /// Start of history in the tracker; used by `allTime`.
    static let allTimeStart = DateRange.utcCalendar.date(
        from: DateComponents(year: 2022, month: 1, day: 1, hour: 0, minute: 0, second: 1)
    ) ?? Date(timeIntervalSince1970: 1_640_995_201)

    /// Resolves the preset to concrete UTC bounds. `custom` returns `customRange` unchanged.
    func dateRange(now: Date = .now, customRange: DateRange) -> DateRange {
        let calendar = DateRange.utcCalendar
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = DateRange.endOfDay(startingAt: startOfToday)

        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: startOfToday) ?? startOfToday
        }

        func startOfMonth(offset: Int = 0) -> Date {
            let components = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: components) ?? startOfToday
            return calendar.date(byAdding: .month, value: offset, to: start) ?? start
        }

        switch self {
        case .today:
            return DateRange(from: startOfToday, to: endOfToday)
        case .yesterday:
            return DateRange(from: daysAgo(1), to: startOfToday.addingTimeInterval(-1))
        case .thisWeek:
            // Weeks start on Monday; `weekday` is 1 for Sunday.
            let weekday = calendar.component(.weekday, from: startOfToday)
            let daysSinceMonday = (weekday + 5) % 7
            return DateRange(from: daysAgo(daysSinceMonday), to: endOfToday)
        case .last2Days:
            return DateRange(from: daysAgo(1), to: endOfToday)
        case .last7Days:
            return DateRange(from: daysAgo(6), to: endOfToday)
        case .last14Days:
            return DateRange(from: daysAgo(13), to: endOfToday)
        case .last30Days:
            return DateRange(from: daysAgo(29), to: endOfToday)
        case .previousMonth:
            return DateRange(from: startOfMonth(offset: -1), to: startOfMonth().addingTimeInterval(-1))
        case .thisMonth:
            return DateRange(from: startOfMonth(), to: endOfToday)
        case .last90Days:
            return DateRange(from: daysAgo(89), to: endOfToday)
        case .last180Days:
            return DateRange(from: daysAgo(179), to: endOfToday)
        case .thisYear:
            let components = calendar.dateComponents([.year], from: now)
            return DateRange(from: calendar.date(from: components) ?? startOfToday, to: endOfToday)
        case .allTime:
            return DateRange(from: DateRangePreset.allTimeStart, to: endOfToday)
        case .custom:
            return customRange
        }
    }
}

/// The user's period choice: a preset, or an explicit range picked in the calendar.
nonisolated struct ReportPeriod: Hashable, Sendable {
    var preset: DateRangePreset = .today
    var customRange: DateRange = DateRange.wholeDays(fromLocalDay: .now, toLocalDay: .now)

    func dateRange(now: Date = .now) -> DateRange {
        preset.dateRange(now: now, customRange: customRange)
    }

    /// Label for the toolbar: preset name, or the picked dates for a custom range.
    var title: String {
        preset == .custom ? Formatters.dayRange(customRange) : preset.shortTitle
    }
}
