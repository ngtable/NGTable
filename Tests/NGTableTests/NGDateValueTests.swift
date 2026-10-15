#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Dates by their time (`NGValueFormat.time`), and summaries of dates: a
/// count, the earliest, the latest, shown and exported as dates.
@Suite("Dates")
@MainActor
struct NGDateValueTests {
    @MainActor final class Events: NGTableViewDataSource {
        var dates: [Date]
        init(_ dates: [Date]) { self.dates = dates }
        func numberOfRows(in tableView: NGTableView) -> Int { dates.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            column.id == "time" ? .date(dates[row]) : .text("e\(row)")
        }
    }

    static func date(hour: Int, minute: Int, second: Int, nanosecond: Int = 0, day: Int = 15) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second,
                                                   nanosecond: nanosecond))!
    }

    @Test func timeWithSecondsAndFractions() {
        let date = Self.date(hour: 14, minute: 1, second: 23, nanosecond: 456_700_000)
        let russian = Locale(identifier: "ru_RU"), english = Locale(identifier: "en_US")
        #expect(NGValueFormat.time(fractionDigits: 3).string(for: .date(date), locale: russian) == "14:01:23,456")
        #expect(NGValueFormat.time().string(for: .date(date), locale: russian) == "14:01:23")
        #expect(NGValueFormat.time(fractionDigits: 3).string(for: .date(date), locale: english) == "02:01:23.456\u{202F}PM")
        let withDate = NGValueFormat.time(includesDate: true).string(for: .date(date), locale: english)
        #expect(withDate.hasPrefix("Oct 15, 2026") && withDate.contains("02:01:23"))
        #expect(NGValueFormat.time().isDate && NGValueFormat.date(includesTime: false).isDate && !NGValueFormat.automatic.isDate)
        // A number in a date format is a date's seconds (a summary of dates).
        #expect(NGValueFormat.time().string(for: date.timeIntervalSince1970, locale: russian) == "14:01:23")
    }

    /// A count of dates counts them; the earliest and latest show as dates.
    @Test func summariesOfDates() throws {
        let events = Events([Self.date(hour: 9, minute: 0, second: 5), Self.date(hour: 8, minute: 30, second: 0),
                             Self.date(hour: 11, minute: 15, second: 59)])
        defer { withExtendedLifetime(events) {} }
        func table(_ summary: NGColumnSummary) -> NGTableView {
            let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            table.columns = [.column(NGTableColumn("time", title: "Time", width: 120, format: .time(), summary: summary))]
            table.dataSource = events
            table.locale = Locale(identifier: "ru_RU")
            table.layoutSubtreeIfNeeded()
            return table
        }
        #expect(table(.aggregate(.count)).summaryText(forColumnID: "time") == "3")
        #expect(table(.aggregate(.min)).summaryText(forColumnID: "time") == "08:30:00")
        #expect(table(.aggregate(.max)).summaryText(forColumnID: "time") == "11:15:59")
        // Live: a new earliest.
        let earliest = table(.aggregate(.min))
        events.dates.append(Self.date(hour: 7, minute: 0, second: 1))
        earliest.insertRows(at: [3])
        #expect(earliest.summaryText(forColumnID: "time") == "07:00:01")
        events.dates.removeLast()
    }

    /// A workbook's time column has seconds and thousandths, and the summary
    /// of dates is a date (Excel's days), its count a number.
    @Test func timesInAWorkbook() async throws {
        let events = Events([Self.date(hour: 9, minute: 0, second: 5), Self.date(hour: 8, minute: 30, second: 0)])
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { withExtendedLifetime(events) {} }
        table.columns = [.column(NGTableColumn("time", title: "Time", width: 120, format: .time(fractionDigits: 3), summary: .aggregate(.min)))]
        table.dataSource = events
        table.layoutSubtreeIfNeeded()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGDateValueTests-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try await table.export(to: url, as: .xlsx)
        let tests = NGExportTests()
        let styles = try #require(tests.unzip(url, part: "xl/styles.xml"))
        #expect(styles.contains("hh:mm:ss.000"))
        let sheet = try XMLDocument(xmlString: try #require(tests.unzip(url, part: "xl/worksheets/sheet1.xml")))
        let values = try sheet.nodes(forXPath: "//*[local-name()='c']/*[local-name()='v']").compactMap { Double($0.stringValue ?? "") }
        // Two cells and the summary: the earliest, as Excel's days.
        #expect(values.count == 3)
        #expect(values.allSatisfy { $0 > 46_000 && $0 < 47_000 })
        #expect(values[2] == values[1])
    }
}
#endif
