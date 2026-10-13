#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Exporting the table: CSV as displayed, and an Excel workbook with values
/// in the columns' formats, of the rows shown in display order.
@Suite("Export")
@MainActor
struct NGExportTests {
    typealias Records = NGLiveSortingTests.Records

    private func makeTable(_ records: Records) -> NGTableView {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("name", title: "Name", width: 200)),
            .column(NGTableColumn("profit", title: "Profit", width: 120, format: .currency(code: "USD"), summary: .aggregate(.sum))),
            .column(NGTableColumn("status", title: "Status", width: 100)),
        ]
        table.dataSource = records
        table.sortsRows = true
        table.layoutSubtreeIfNeeded()
        return table
    }

    @Test func csvOfTheRowsShown() async throws {
        let records = Records(count: 20)
        records.records[3].name = "Quote \"me\", please"
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        table.columnFilters = ["status": .values(["Active"])]
        let data = await table.exportedData(as: .csv)
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))   // The byte order mark (decoding drops it).
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.hasPrefix("Name,Profit,Status\r\n"))
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).dropLast()
        let shown = (0..<table.numberOfRows).map(table.sourceRow)
        #expect(lines.count == 1 + shown.count + 1)   // Header, rows, summary.
        let first = records.records[shown[0]]
        let profit = NGValueFormat.currency(code: "USD").string(for: .number(first.profit))
        let quotedProfit = profit.contains(",") ? "\"\(profit)\"" : profit
        #expect(lines[1] == "\(first.name),\(quotedProfit),Active")
        if records.records[3].status == "Active" {
            #expect(text.contains("\"Quote \"\"me\"\", please\""))
        }
        // Only the selected rows.
        table.selectRowIndexes([shown[1]], byExtendingSelection: false)
        let selected = await table.exportedData(as: .csv, options: NGExportOptions(rows: .selected, includesSummaryRow: false))
        #expect(String(data: selected, encoding: .utf8)?.split(separator: "\r\n").count == 2)
    }

    /// A valid workbook: the ZIP and every XML part read back (with Python's
    /// zipfile, which checks the CRCs, and XML parsing), numbers as numbers.
    @Test func excelWorkbook() async throws {
        let records = Records(count: 50)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGExportTests-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try await table.export(to: url, as: .xlsx)
        let sheet = try #require(unzip(url, part: "xl/worksheets/sheet1.xml"))
        for part in ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml"] {
            let xml = try #require(unzip(url, part: part), "\(part)")
            _ = try XMLDocument(xmlString: xml)
        }
        let document = try XMLDocument(xmlString: sheet)
        let rows = try document.nodes(forXPath: "//*[local-name()='row']")
        #expect(rows.count == 1 + 50 + 1)
        // The first data row's profit is a number cell in the currency format.
        let value = try document.nodes(forXPath: "//*[local-name()='row'][2]/*[local-name()='c'][2]/*[local-name()='v']").first?.stringValue
        #expect(Double(value ?? "") == records.records[0].profit)
        let styles = try #require(unzip(url, part: "xl/styles.xml"))
        #expect(styles.contains("#,##0.00"))
        #expect(NGTableExport.cellReference(column: 0, row: 1) == "A1")
        #expect(NGTableExport.cellReference(column: 27, row: 3) == "AB3")
    }

    /// More rows than a sheet holds go on to more sheets, each with the
    /// titles; the summary row is on the last. (With a small limit here.)
    @Test func rowsBeyondASheetGoOnToMoreSheets() async throws {
        let records = Records(count: 25)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.exportMaxRowsPerSheet = 12   // Titles, 10 rows, the summary row.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGExportTests-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try await table.export(to: url, as: .xlsx)
        var rowCounts: [Int] = []
        for sheet in 1...3 {
            let xml = try #require(unzip(url, part: "xl/worksheets/sheet\(sheet).xml"), "sheet \(sheet)")
            rowCounts.append(try XMLDocument(xmlString: xml).nodes(forXPath: "//*[local-name()='row']").count)
        }
        #expect(rowCounts == [11, 11, 1 + 5 + 1])
        #expect(unzip(url, part: "xl/worksheets/sheet4.xml") == nil)
        let workbook = try #require(unzip(url, part: "xl/workbook.xml"))
        #expect(workbook.contains("Sheet3"))
    }

    /// An archive that would pass the ZIP limit (4 GB without ZIP64; small
    /// here) gives nothing rather than a broken file, whether an entry or the
    /// central directory crosses it.
    @Test func zipArchivesStayBelowTheLimit() throws {
        var generator = SplitMix(seed: 7)
        let noise = Data((0..<600).map { _ in UInt8(truncatingIfNeeded: generator.next()) })   // Doesn't deflate.
        var fits = NGZipWriter()
        fits.sizeLimit = 1_000
        fits.add("a.bin", noise)
        #expect(fits.finish() != nil)
        var entry = NGZipWriter()
        entry.sizeLimit = 1_000
        entry.add("a.bin", noise)
        entry.add("b.bin", noise)
        #expect(entry.finish() == nil)
        var directory = NGZipWriter()
        directory.sizeLimit = 700
        directory.add("a-long-name-for-the-central-directory.bin", noise)
        #expect(directory.finish() == nil)
        // At the exact size: the archive and directory must stay under the limit.
        var measured = NGZipWriter()
        measured.add("a.bin", noise)
        let archive = measured.finish()
        let size = try #require(archive).count
        var just = NGZipWriter()
        just.sizeLimit = size + 1
        just.add("a.bin", noise)
        #expect(just.finish()?.count == size)
        var over = NGZipWriter()
        over.sizeLimit = size
        over.add("a.bin", noise)
        #expect(over.finish() == nil)
    }

    /// Text that a spreadsheet would run as a formula is made inert; numbers stay.
    @Test func csvDoesntCarryFormulas() {
        #expect(NGTableExport.inert("=HYPERLINK(\"x\")") == "'=HYPERLINK(\"x\")")
        #expect(NGTableExport.inert("@cmd") == "'@cmd")
        #expect(NGTableExport.inert("Campaign") == "Campaign")
        #expect(NGTableExport.inert("") == "")
    }

    /// A count summary is a plain number, not in its column's currency.
    @Test func countSummariesArePlainNumbers() async throws {
        let records = Records(count: 20)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("profit", title: "Profit", width: 120, format: .currency(code: "USD"), summary: .aggregate(.count)))]
        table.dataSource = records
        defer { withExtendedLifetime(records) {} }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGExportTests-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try await table.export(to: url, as: .xlsx)
        let sheet = try XMLDocument(xmlString: try #require(unzip(url, part: "xl/worksheets/sheet1.xml")))
        let style = try sheet.nodes(forXPath: "//*[local-name()='row'][22]/*[local-name()='c'][1]/@s").first?.stringValue
        let styles = try XMLDocument(xmlString: try #require(unzip(url, part: "xl/styles.xml")))
        let xfs = try styles.nodes(forXPath: "//*[local-name()='cellXfs']/*[local-name()='xf']")
        let format = xfs[Int(style ?? "0") ?? 0] as? XMLElement
        #expect(format?.attribute(forName: "numFmtId")?.stringValue == "0")
    }

    func unzip(_ url: URL, part: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; sys.stdout.write(z.read(sys.argv[2]).decode())",
                             url.path, part]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
#endif
