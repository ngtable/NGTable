//
//  Formatters.swift
//  NGTable Mac Bench
//
//  A copy of EasyCPA's campaigns table (as of October 2026) for the campaigns bench: the bench
//  shows NGTable on a real app's table. It doesn't follow EasyCPA's changes.

import Foundation

/// Display formatting for report metrics. Nonisolated so models can build labels off the main actor.
nonisolated enum Formatters {
    /// Money in USD. Metrics use two decimals; per-click prices (CPC/EPC) use three, as in the web UI.
    static func money(_ value: Double, fractionDigits: Int = 2) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(fractionDigits)))
    }

    /// Percentages as returned by the tracker: the API value is already multiplied by 100.
    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(2)))
    }

    static func integer(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// Plain number with up to two decimals (CP/h, hours).
    static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// Accusative, for "Удалить …": "1 кампанию", "3 кампании", "5 кампаний".
    static func campaignCount(_ count: Int) -> String {
        let lastTwo = count % 100
        let last = count % 10
        let word = if (11...14).contains(lastTwo) {
            "кампаний"
        } else if last == 1 {
            "кампанию"
        } else if (2...4).contains(last) {
            "кампании"
        } else {
            "кампаний"
        }
        return "\(count) \(word)"
    }

    private static let utcDay = Date.FormatStyle(date: .numeric, time: .omitted, timeZone: .gmt)

    /// `21.09.2026` or `15.09.2026 – 21.09.2026`, rendered in UTC to match the API day boundaries.
    static func dayRange(_ range: DateRange) -> String {
        let from = range.from.formatted(utcDay)
        let to = range.to.formatted(utcDay)
        return from == to ? from : "\(from) – \(to)"
    }
}
