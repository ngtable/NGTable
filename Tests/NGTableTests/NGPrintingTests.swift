#if os(macOS)
import AppKit
import PDFKit
import Testing
@testable import NGTable

/// Printing and PDF: paginated rows with the titles on every page and the
/// summary row at the end.
@Suite("Printing")
@MainActor
struct NGPrintingTests {
    @Test func pdfPages() throws {
        let records = NGLiveSortingTests.Records(count: 120)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                         .column(NGTableColumn("profit", title: "Profit", width: 120, format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
                         .column(NGTableColumn("status", title: "Status", width: 120))]
        table.dataSource = records
        table.layoutSubtreeIfNeeded()
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)   // A4.
        let view = try #require(table.pagesView(printInfo: info) as? NGTablePrintView)
        let data = table.pdfData(printInfo: info)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == view.pageCount)
        #expect(document.pageCount >= 2)
        let first = document.page(at: 0)?.string ?? ""
        #expect(first.contains("Name") && first.contains("Campaign 0"))
        let last = document.page(at: document.pageCount - 1)?.string ?? ""
        #expect(last.contains("Name"))   // The titles on every page.
        #expect(last.contains(table.summaryText(forColumnID: "profit") ?? "—"))
        // Grouped: header rows with their counts.
        table.rowGrouping = NGRowGrouping(columnID: "status")
        let grouped = PDFDocument(data: table.pdfData(printInfo: info))?.page(at: 0)?.string ?? ""
        #expect(grouped.contains("("))
    }

    /// Pages made for portrait, printed in landscape (as after the print
    /// panel): laid out again, every row printed.
    @Test func pagesFollowThePaperOfThePrintOperation() throws {
        let records = NGLiveSortingTests.Records(count: 200)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                         .column(NGTableColumn("status", title: "Status", width: 120))]
        table.dataSource = records
        let portrait = NSPrintInfo()
        portrait.paperSize = NSSize(width: 595, height: 842)
        let view = table.pagesView(printInfo: portrait)
        let landscape = NSPrintInfo()
        landscape.paperSize = NSSize(width: 842, height: 595)
        landscape.orientation = .landscape
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGTable-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        landscape.jobDisposition = .save
        landscape.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = NSPrintOperation(view: view, printInfo: landscape)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
        let document = try #require(PDFDocument(url: url))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        let missing = (0..<200).filter { text.range(of: "Campaign \($0)(?![0-9])", options: .regularExpression) == nil }
        #expect(missing.isEmpty, "missing rows: \(missing.prefix(10))")
        #expect(document.pageCount > 1)
    }

    /// Pages made before the data changed (a refresh while the print panel
    /// is open) print the rows and the summary as they are when printing
    /// starts, together.
    @Test func pagesMadeBeforeAReloadPrintTheDataAsItIsThen() throws {
        let records = NGLiveSortingTests.Records(count: 60)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                         .column(NGTableColumn("profit", title: "Profit", width: 120, format: .number(fractionDigits: 0), summary: .aggregate(.sum)))]
        table.dataSource = records
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        let view = table.pagesView(printInfo: info)
        // Meanwhile: the data reloads, with one record fewer and one renamed.
        records.records.removeLast()
        records.records[0].name = "Renamed"
        table.reloadData()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGTable-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
        let document = try #require(PDFDocument(url: url))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        let missing = (1..<59).filter { text.range(of: "Campaign \($0)(?![0-9])", options: .regularExpression) == nil }
        #expect(missing.isEmpty, "missing rows: \(missing.prefix(10))")
        #expect(text.contains("Renamed"))
        #expect(!text.contains("Campaign 59"))
        let total = records.records.reduce(0) { $0 + $1.profit }
        #expect(text.contains(table.summaryText(forColumnID: "profit") ?? "?"), "total \(total)")
    }

    @MainActor
    final class Wide: NGTableViewDataSource {
        func numberOfRows(in tableView: NGTableView) -> Int { 30 }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text("\(column.id)-\(row)") }
    }

    private func pdfText(_ data: Data) throws -> [String] {
        let document = try #require(PDFDocument(data: data))
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    /// Columns wider than the paper: `.automatic` prints them across pages,
    /// in bands of whole columns that fit, the columns pinned at the leading
    /// edge on every band; `.fit` (the default) scales them to the page's
    /// width, `.clip` cuts them off.
    @Test func columnsAcrossPages() throws {
        let wide = Wide()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var first = NGTableColumn("name", title: "Name", width: 150)
        first.pin = .leading
        table.columns = [.column(first)] + (1...5).map { .column(NGTableColumn("c\($0)", title: "Col \($0)", width: 200)) }
        table.dataSource = wide
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(wide) {} }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        let pageWidth = 595 - info.leftMargin - info.rightMargin

        table.printPagination = .automatic
        let view = try #require(table.pagesView(printInfo: info) as? NGTablePrintView)
        let bands = view.columnBands
        #expect(bands.count > 1)
        #expect(bands.allSatisfy { $0.first == 0 })   // The pinned column on every band.
        #expect(Set(bands.flatMap { $0 }) == Set(0..<6))
        #expect(bands.allSatisfy { band in band.reduce(0) { $0 + [150, 200, 200, 200, 200, 200][$1] } <= pageWidth })
        let pages = try pdfText(table.pdfData(printInfo: info))
        #expect(pages.count == view.pageCount && pages.count == bands.count)   // 30 rows fit a page.
        for (page, band) in zip(pages, bands) {
            #expect(page.contains("name-0"))
            for column in band.dropFirst() { #expect(page.contains("c\(column)-0")) }
        }

        table.printPagination = .fit
        let fitted = try pdfText(table.pdfData(printInfo: info))
        #expect(fitted.count == 1 && fitted[0].contains("Col 5"))
        table.printPagination = .clip
        let clipped = try pdfText(table.pdfData(printInfo: info))
        #expect(clipped.count == 1 && clipped[0].contains("name-0") && !clipped[0].contains("c5-0"))
    }

    @MainActor
    final class Messages: NGTableViewDataSource {
        func numberOfRows(in tableView: NGTableView) -> Int { 60 }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            column.id == "id" ? .text("Row \(row)")
                : .text("Begin\(row) the request was retried after the upstream server answered slowly, then succeeded on the third attempt End\(row)")
        }
    }

    /// Wrapping columns print their text in full, rows as high as it, each
    /// row on one page; a line limit cuts the text there.
    @Test func wrappedTextPrintsInFull() throws {
        let messages = Messages()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        defer { withExtendedLifetime(messages) {} }
        table.dataSource = messages
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        func pages(_ message: NGTableColumn) throws -> [String] {
            table.columns = [.column(NGTableColumn("id", title: "Id", width: 80)), .column(message)]
            table.layoutSubtreeIfNeeded()
            return try pdfText(table.pdfData(printInfo: info))
        }
        let oneLine = try pages(NGTableColumn("message", title: "Message", width: 200))
        #expect(!oneLine.joined().contains("End0"))
        let wrapped = try pages(NGTableColumn("message", title: "Message", width: 200).wrappingText())
        #expect(wrapped.count > oneLine.count)
        for row in 0..<60 {
            // PDF text breaks lines with newlines: words survive.
            let page = wrapped.first { $0.contains("Begin\(row) ") }
            #expect(page?.contains("End\(row)") == true, "row \(row)")
        }
        let twoLines = try pages(NGTableColumn("message", title: "Message", width: 200).wrappingText(maximumNumberOfLines: 2))
        #expect(twoLines.count < wrapped.count)
        #expect(!twoLines.joined().contains("End0"))
        #expect(twoLines.joined().contains("Begin59"))
    }

    /// The print operation: the progress panel, the table's options in the
    /// print panel (selected rows only, the summary row; the preview follows
    /// them), and the app's own accessories.
    @Test func thePrintOperation() throws {
        let records = NGLiveSortingTests.Records(count: 120)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                         .column(NGTableColumn("profit", title: "Profit", width: 120, format: .number(fractionDigits: 0), summary: .aggregate(.sum)))]
        table.dataSource = records
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(records) {} }
        final class Extra: NSViewController, NSPrintPanelAccessorizing {
            override func loadView() { view = NSView() }
            func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] { [] }
            func keyPathsForValuesAffectingPreview() -> Set<String> { [] }
        }
        let extra = Extra()
        table.printPanelAccessories = [extra]
        let operation = table.makePrintOperation()
        #expect(operation.showsPrintPanel && operation.showsProgressPanel)
        let accessories = operation.printPanel.accessoryControllers
        let options = try #require(accessories.first as? NGPrintOptionsAccessory)
        #expect(accessories.count == 2 && accessories.last === extra)
        #expect(options.keyPathsForValuesAffectingPreview() == ["printsSelectedRowsOnly", "printsSummaryRow"])
        #expect(!options.localizedSummaryItems().isEmpty)
        let view = try #require(operation.view as? NGTablePrintView)
        var range = NSRange()
        #expect(view.knowsPageRange(&range) && range.length > 1)
        table.selectRowIndexes([3, 4, 5], byExtendingSelection: false)
        options.printsSelectedRowsOnly = true
        options.printsSummaryRow = false
        #expect(view.knowsPageRange(&range) && range.length == 1)
        #expect(view.lineCountForTesting == 3)
    }
}
#endif
