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
    /// here) gives nothing rather than a broken file, whether an entry, a
    /// streamed entry's piece or the central directory crosses it.
    @Test func zipArchivesStayBelowTheLimit() throws {
        var generator = SplitMix(seed: 7)
        let noise = Data((0..<600).map { _ in UInt8(truncatingIfNeeded: generator.next()) })   // Doesn't deflate.
        var fits = NGZipWriter()
        fits.sizeLimit = 1_000
        try fits.add("a.bin", noise)
        try fits.finish()
        var entry = NGZipWriter()
        entry.sizeLimit = 1_000
        try entry.add("a.bin", noise)
        #expect(throws: NGExportError.self) { try entry.add("b.bin", noise) }
        var streamed = NGZipWriter()
        streamed.sizeLimit = 1_000
        try streamed.begin("a.bin")
        try streamed.append(NGZipWriter.piece(noise))
        #expect(throws: NGExportError.self) { try streamed.append(NGZipWriter.piece(noise)) }
        var directory = NGZipWriter()
        directory.sizeLimit = 700
        try directory.add("a-long-name-for-the-central-directory.bin", noise)
        #expect(throws: NGExportError.self) { try directory.finish() }
        // At the exact size: the archive and directory must stay under the limit.
        var measured = NGZipWriter()
        try measured.add("a.bin", noise)
        try measured.finish()
        let size = measured.sink.count
        var just = NGZipWriter()
        just.sizeLimit = size + 1
        try just.add("a.bin", noise)
        try just.finish()
        #expect(just.sink.count == size)
        var over = NGZipWriter()
        over.sizeLimit = size
        try over.add("a.bin", noise)
        #expect(throws: NGExportError.self) { try over.finish() }
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

    /// Values of every kind, in columns of every format (and a summary of
    /// each kind), for comparing whole files.
    @MainActor final class Kinds: NGTableViewDataSource {
        let count: Int
        init(count: Int) { self.count = count }
        func numberOfRows(in tableView: NGTableView) -> Int { count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            let texts = ["plain", "with, comma", "quote \"q\"", "=HYPERLINK(\"x\")", "-minus", "line\nbreak", "tab\there",
                         "ctl\u{1}char", "emoji 👩‍👩‍👧 <&>", "", "@cmd", "Кириллица"]
            switch column.id {
            case "text": return .text(texts[row % texts.count])
            case "number":
                let numbers = [1.5, -2.25, 0, -0.0, .nan, .infinity, 1e15, 123_456.789]
                return .number(numbers[row % numbers.count])
            case "currency": return row % 7 == 0 ? .empty : .number(Double(row) * 1.37 - 50)
            case "percent": return .number(Double(row % 100) / 100)
            case "date": return .date(Date(timeIntervalSince1970: 1_700_000_000 + Double(row) * 3_600))
            case "bool": return .bool(row % 2 == 0)
            case "tags": return .tags([NGTag("a"), NGTag("b, c")])
            case "rating": return .rating(row % 6)
            case "progress": return row % 5 == 0 ? .progress(nil) : .progress(Double(row % 10), total: 10)
            case "sparkline": return .sparkline(NGSparkline([1, 2, Double(row)]))
            case "link": return .link(NGLink("Link \(row)", url: URL(string: "https://example.com/\(row)")))
            default: return .empty
            }
        }
    }

    /// The rows go to the writer in chunks, each formatted (and deflated)
    /// in pieces on all cores: however they are cut, row by row or a sheet
    /// at once, the file is the same (CSV byte for byte; a workbook's parts,
    /// read back with their checksums checked), across sheets too.
    @Test func chunksDontChangeTheFile() async throws {
        let kinds = Kinds(count: 2_345)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        defer { withExtendedLifetime(kinds) {} }
        table.columns = [
            .column(NGTableColumn("text", title: "Text, \"titled\"", width: 200)),
            .column(NGTableColumn("number", title: "Number", width: 90, format: .number(fractionDigits: 2), summary: .aggregate(.sum))),
            .column(NGTableColumn("currency", title: "Currency", width: 90, format: .currency(code: "EUR"), summary: .aggregate(.count))),
            .column(NGTableColumn("percent", title: "Percent", width: 90, format: .percent(fractionDigits: 1), summary: .aggregate(.average))),
            .column(NGTableColumn("date", title: "Date", width: 120, format: .date(includesTime: true))),
            .column(NGTableColumn("bool", title: "Bool", width: 40)),
            .column(NGTableColumn("tags", title: "Tags", width: 90)),
            .column(NGTableColumn("rating", title: "Rating", width: 90, summary: .aggregate(.max))),
            .column(NGTableColumn("progress", title: "Progress", width: 90, format: .percent(fractionDigits: 0))),
            .column(NGTableColumn("sparkline", title: "Sparkline", width: 90)),
            .column(NGTableColumn("link", title: "Link", width: 90)),
        ]
        table.dataSource = kinds
        table.exportMaxRowsPerSheet = 700
        table.layoutSubtreeIfNeeded()
        let columns = table.columns.count
        var csv: [Data] = []
        var workbooks: [String] = []
        for cells in [1_000_000, columns * 37, columns] {
            table.exportChunkCells = cells
            csv.append(await table.exportedData(as: .csv))
            let workbook = await table.exportedData(as: .xlsx)
            workbooks.append(try #require(try parts(of: workbook)))
        }
        #expect(csv[0].count > 100_000)
        #expect(csv.allSatisfy { $0 == csv[0] })
        #expect(workbooks[0].contains("== xl/worksheets/sheet4.xml"))
        #expect(workbooks.allSatisfy { $0 == workbooks[0] })
    }

    /// A reload while the rows are read and written: the file starts over
    /// with the new rows, once.
    @Test(arguments: [NGExportFormat.csv, .xlsx])
    func aReloadStartsTheFileOver(_ format: NGExportFormat) async throws {
        let records = Records(count: 300)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.exportChunkCells = 1   // A row at a time: the export takes many turns.
        let reads = records.nameReads
        let export = Task { await table.exportedData(as: format, options: NGExportOptions(includesSummaryRow: false)) }
        while records.nameReads < reads + 20 { await Task.yield() }
        records.records = (0..<120).map { .init(id: $0, name: "New \($0)", profit: Double($0), status: "Active") }
        table.reloadData()
        let data = await export.value
        let text: String
        if format == .csv {
            text = try #require(String(data: data, encoding: .utf8))
            #expect(text.components(separatedBy: "Name,Profit,Status").count == 2)
        } else {
            text = try #require(try parts(of: data))
            #expect(text.components(separatedBy: "== xl/worksheets/sheet1.xml").count == 2)
        }
        #expect(!text.contains("Campaign"))
        #expect((0..<120).allSatisfy { text.contains("New \($0)") })
    }

    /// A cancelled export leaves a file already there as it was.
    @Test func aCancelledExportLeavesTheFile() async throws {
        let records = Records(count: 300)
        let table = makeTable(records)
        defer { withExtendedLifetime(records) {} }
        table.exportChunkCells = 1
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGExportTests-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("before".utf8).write(to: url)
        let reads = records.nameReads
        let export = Task { try await table.export(to: url, as: .csv) }
        while records.nameReads < reads + 20 { await Task.yield() }
        export.cancel()
        await #expect(throws: CocoaError.self) { try await export.value }
        #expect(try Data(contentsOf: url) == Data("before".utf8))
        #expect(!table.isExporting)
        // And one that ends replaces it.
        table.exportChunkCells = 1_000
        try await table.export(to: url, as: .csv)
        #expect(String(data: try Data(contentsOf: url), encoding: .utf8)?.hasPrefix("Name,Profit,Status") == true)
    }

    /// Every part of a workbook by name, as one text (the checksums checked).
    func parts(of data: Data) throws -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGExportTests-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return python(["import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; "
                       + "[sys.stdout.write('== ' + n + '\\n' + z.read(n).decode() + '\\n') for n in sorted(z.namelist())]", url.path])
    }

    func unzip(_ url: URL, part: String) -> String? {
        python(["import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; sys.stdout.write(z.read(sys.argv[2]).decode())",
                url.path, part])
    }

    private func python(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
#endif
