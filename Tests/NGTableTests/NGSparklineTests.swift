#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Sparklines: values of a series a cell draws as a small chart. They sort
/// and sum by their last value, copy and export as their numbers (a sheet
/// gets the last one), read out as their last, lowest and highest values,
/// and draw a segment between each pair of values that aren't gaps.
@Suite("Sparklines")
@MainActor
struct NGSparklineTests {
    @MainActor
    final class Series: NGTableViewDataSource {
        var series: [[Double]]
        init(_ series: [[Double]]) { self.series = series }

        func numberOfRows(in tableView: NGTableView) -> Int { series.count }

        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            column.id == "name" ? .text("Row \(row)") : .sparkline(NGSparkline(series[row]))
        }
    }

    private func makeTable(_ source: Series) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [
            .column(NGTableColumn("name", title: "Name", width: 100)),
            .column(NGTableColumn("trend", title: "Trend", width: 140, format: .number(fractionDigits: 1), summary: .aggregate(.sum))),
        ]
        table.dataSource = source
        table.layoutSubtreeIfNeeded()
        return table
    }

    @Test func theModel() {
        let sparkline = NGSparkline([3, .nan, 8, -2, .nan])
        #expect(sparkline.lastValue == -2)
        #expect(sparkline.extremes! == (-2, 8))
        #expect(sparkline.drawnRange == -2...8)
        // A flat series is drawn in the middle of a unit around it.
        #expect(NGSparkline([4, 4]).drawnRange == 3.5...4.5)
        #expect(NGSparkline([.nan]).drawnRange == nil && NGSparkline([.nan]).lastValue == nil)
        #expect(NGCellValue.sparkline(sparkline).numericValue == -2)
        #expect(NGValueFormat.number(fractionDigits: 0).string(for: .sparkline(sparkline), locale: Locale(identifier: "en_US")) == "3  8 -2 ")
        // By the last value; none first, like an empty cell.
        let values: [NGCellValue] = [.sparkline(NGSparkline([1, 9])), .sparkline(NGSparkline([.nan])), .sparkline(NGSparkline([5, 2]))]
        #expect(values.sorted { $0.sortsBefore($1) } == [values[1], values[2], values[0]])
    }

    @Test func sortsSumsAndReadsByItsLastValue() {
        let source = Series([[1, 2, 9], [5, 4, 3], [.nan], [0, 10, 6]])
        let table = makeTable(source)
        defer { withExtendedLifetime(source) {} }
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "trend", ascending: true)]
        #expect((0..<table.numberOfRows).map(table.sourceRow) == [2, 1, 3, 0])
        #expect(table.summaryValue(forColumnID: "trend") == 18)
        let trend = table.tableColumns[1]
        let row = table.displayIndex(ofRow: 0)!
        #expect(table.accessibilityText(row: row, column: trend) == "trend: last 9.0, lowest 1.0, highest 9.0")
        #expect(table.accessibilityText(row: table.displayIndex(ofRow: 2)!, column: trend) == "trend: no values")
    }

    @Test func exportsItsNumbers() async throws {
        let source = Series([[1, 2.5, 9]])
        let table = makeTable(source)
        defer { withExtendedLifetime(source) {} }
        let csv = try #require(String(data: await table.exportedData(as: .csv, options: NGExportOptions(includesSummaryRow: false)), encoding: .utf8))
        let number = { (value: Double) in NGValueFormat.number(fractionDigits: 1).string(for: value) }
        let joined = "\(number(1)) \(number(2.5)) \(number(9))"
        #expect(csv.contains(joined.contains(",") ? "\"\(joined)\"" : joined))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGSparklineTests-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try await table.export(to: url, as: .xlsx)
        let sheet = try #require(NGExportTests().unzip(url, part: "xl/worksheets/sheet1.xml"))
        let document = try XMLDocument(xmlString: sheet)
        let value = try document.nodes(forXPath: "//*[local-name()='row'][2]/*[local-name()='c'][2]/*[local-name()='v']").first?.stringValue
        #expect(Double(value ?? "") == 9)
    }

    /// A segment for each pair of neighbors that aren't gaps; a value alone
    /// between gaps is a dot. Right to left, the chart is mirrored.
    @Test func segmentsBetweenValues() throws {
        let source = Series([[1, 2, 3, 4, 5], [1, .nan, 3, 4, .nan, 9]])
        let table = makeTable(source)
        let window = NSWindow(contentRect: table.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((source, window)) {} }
        let renderer = try #require(table.metalRenderer)
        func segments(_ quads: [NGMetalQuad]) -> [NGMetalQuad] { quads.filter { $0.kind.x == 5 } }
        let quads = table.buildMetalQuads(renderer: renderer, scale: 2)
        // 4 in the first row, 1 (3 to 4) in the second.
        #expect(segments(quads).count == 5)
        #expect(segments(quads).filter { $0.kind.z == 1 }.count == 3)   // Continuing ones: no start cap.
        // Rising: the last point is higher (smaller y) and to the right of the first.
        let first = segments(quads)[0], last = segments(quads)[3]
        #expect(last.source.z > first.source.x && last.source.w < first.source.y)
        table.userInterfaceLayoutDirection = .rightToLeft
        let mirrored = segments(table.buildMetalQuads(renderer: renderer, scale: 2))
        #expect(mirrored[3].source.z < mirrored[0].source.x)
    }
}
#endif
