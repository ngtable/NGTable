#if os(macOS)
import AppKit

// Printing and PDF: the rows shown (or selected) with the visible columns,
// paginated for the paper, the column titles repeated on every page, group
// header rows, and the summary row at the end. A view of its own draws the
// pages with Core Graphics (paper isn't a Metal layer) in black on white,
// whatever the screen's appearance, values as displayed. Columns wider than
// the paper are scaled down to its width (`printPagination` `.fit`), go on
// across pages in bands of whole columns with the pinned leading columns on
// every band (`.automatic`), or are cut off (`.clip`). The print panel has
// the table's options (selected rows only, the summary row; the preview
// follows them) and the app's own accessories; the print operation shows
// its progress.

extension NGTableView {
    /// Prints the table (File > Print… through the responder chain): the
    /// pages `pagesView(options:printInfo:)` makes, with the print panel.
    public override func printView(_ sender: Any?) {
        guard !ignoresUserInput else { return }
        let operation = makePrintOperation()
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// The print operation `printView(_:)` runs: the pages, the print panel
    /// with the table's options and ``printPanelAccessories``, and the
    /// progress panel.
    public func makePrintOperation() -> NSPrintOperation {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.horizontalPagination = printPagination
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let pages = pagesView(options: NGExportOptions(), printInfo: info)
        let operation = NSPrintOperation(view: pages, printInfo: info)
        operation.jobTitle = exportFileName ?? autosaveName ?? ""
        operation.showsProgressPanel = true
        if let pages = pages as? NGTablePrintView {
            operation.printPanel.addAccessoryController(NGPrintOptionsAccessory(pages: pages))
        }
        for accessory in printPanelAccessories {
            operation.printPanel.addAccessoryController(accessory)
        }
        operation.printPanel.options.insert([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        return operation
    }

    /// The table as a PDF document: the same pages as printing.
    public func pdfData(options: NGExportOptions = NGExportOptions(), printInfo: NSPrintInfo = .shared) -> Data {
        // A print job saved to a file paginates (a PDF operation of a rect
        // would make one long page).
        let info = (printInfo.copy() as? NSPrintInfo) ?? printInfo
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGTable-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.horizontalPagination = printPagination
        info.verticalPagination = .automatic
        let operation = NSPrintOperation(view: pagesView(options: options, printInfo: info), printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// A view that draws the table's pages for a paper size.
    public func pagesView(options: NGExportOptions = NGExportOptions(), printInfo: NSPrintInfo = .shared) -> NSView {
        let columns = columnLayout.allColumns
        // The records to print, by reference, and the summary row, taken
        // again when printing starts (the data may change while the print
        // panel is open); the cells' values are read when a page is drawn
        // (the panel opens without reading them all).
        let content: (NGExportOptions) -> (lines: [NGTablePrintView.Line], summary: [String]?) = { [weak self] options in
            guard let self, dataSource != nil else { return ([], nil) }
            var lines: [NGTablePrintView.Line] = []
            let selected = options.rows == .selected ? selectedRowIndexes : nil
            lines.reserveCapacity(selected?.count ?? numberOfRows)
            for displayRow in 0..<numberOfRows {
                if let node = groupNode(atDisplayRow: displayRow), selected == nil {
                    let group = groupTree.nodes[node]
                    let title = if case .groupTitle(let title) = groupTitleContent(ofNode: node) { title.title } else { "" }
                    lines.append(.group(title: title, level: group.group.level, count: group.rows.count))
                    continue
                }
                let row = sourceRow(displayRow)
                guard row >= 0, selected?.contains(row) ?? true else { continue }
                lines.append(.row(rowRef(ofRow: row)))
            }
            let summary = options.includesSummaryRow && showsSummaryRow ? columns.map { self.summaryText(forColumnID: $0.id) ?? "" } : nil
            return (lines, summary)
        }
        let texts: (NGRowRef) -> [String] = { [weak self] ref in
            guard let self, let dataSource = self.dataSource else { return [] }
            let row = self.row(of: ref)
            guard row >= 0 else { return [] }   // Gone since.
            return columns.map { column in
                var value = dataSource.tableView(self, valueFor: column, row: row)
                // A sparkline prints as its last value (its numbers would run over the page).
                if case .sparkline(let sparkline) = value { value = sparkline.lastValue.map { .number($0) } ?? .empty }
                return value == .empty ? "" : NGFormatIDs.string(for: value, format: column.format, locale: self.locale)
            }
        }
        return NGTablePrintView(
            columns: columns.map { column in
                NGTablePrintView.Column(title: column.menuTitle, width: CGFloat(width(ofColumnID: column.id) ?? column.width),
                                        alignment: column.alignment.textAlignment(isNumeric: column.isNumeric,
                                                                                  layoutDirection: userInterfaceLayoutDirection),
                                        repeats: columnLayout.leading.columns.contains { $0.id == column.id })
            },
            options: options, content: content, texts: texts, printInfo: printInfo, pagination: printPagination,
            fontSize: max(7, tableStyle.cellFontSize - 3), isRightToLeft: isRightToLeft, locale: formattingLocale)
    }
}

/// The pages of a printed table (see `NGTableView.pagesView(options:printInfo:)`).
final class NGTablePrintView: NSView {
    struct Column {
        let title: String
        let width: CGFloat
        let alignment: NSTextAlignment
        /// Printed on every band of columns (pinned at the leading edge).
        var repeats = false
    }

    enum Line {
        case row(NGRowRef)
        case group(title: String, level: Int, count: Int)
    }

    private let columns: [Column]
    /// Which rows and whether the summary row (the print panel changes them).
    var options: NGExportOptions
    /// The lines and the summary row as they are now, for options.
    private let content: (NGExportOptions) -> (lines: [Line], summary: [String]?)
    private var lines: [Line]
    /// A row's texts as displayed, read when its page is drawn.
    private let texts: (NGRowRef) -> [String]
    private var summary: [String]?
    /// The paper the pages are laid out for until a print operation says
    /// otherwise (the print panel changes the orientation and paper size
    /// after the view is made).
    private let printInfo: NSPrintInfo
    private let font: NSFont
    private let boldFont: NSFont
    private let rowHeight: CGFloat
    private let headerHeight: CGFloat
    /// Columns from the right, right to left.
    private let isRightToLeft: Bool
    /// The locale of the group headers' counts.
    private let locale: Locale
    /// How columns wider than the paper print, unless the print operation's
    /// print info says otherwise.
    private let pagination: NSPrintInfo.PaginationMode

    /// The pages for one paper size.
    private struct Layout {
        var pageSize: NSSize
        /// Column widths, scaled to the page width when wider (`.fit`).
        var widths: [CGFloat]
        /// The columns of each band across pages (one band unless `.automatic`).
        var bands: [[Int]]
        var rowsPerPage: Int
        /// Pages down, for the rows; each has a page per band.
        var rowPageCount: Int
        var pageCount: Int { rowPageCount * bands.count }
    }
    private var layout: Layout
    private var pageSize: NSSize { layout.pageSize }
    private var widths: [CGFloat] { layout.widths }
    private var rowsPerPage: Int { layout.rowsPerPage }
    var pageCount: Int { layout.pageCount }
    /// The columns of each band across pages, as indexes of the columns.
    var columnBands: [[Int]] { layout.bands }
    var lineCountForTesting: Int { lines.count }

    init(columns: [Column], options: NGExportOptions = NGExportOptions(),
         content: @escaping (NGExportOptions) -> (lines: [Line], summary: [String]?), texts: @escaping (NGRowRef) -> [String],
         printInfo: NSPrintInfo, pagination: NSPrintInfo.PaginationMode = .fit, fontSize: CGFloat, isRightToLeft: Bool = false,
         locale: Locale = .current) {
        self.isRightToLeft = isRightToLeft
        self.locale = locale
        self.columns = columns
        self.options = options
        self.content = content
        (lines, summary) = content(options)
        self.texts = texts
        self.printInfo = printInfo
        self.pagination = pagination
        font = .systemFont(ofSize: fontSize)
        boldFont = .systemFont(ofSize: fontSize, weight: .semibold)
        rowHeight = ceil(fontSize * 1.6)
        headerHeight = ceil(fontSize * 2)
        layout = Self.layout(for: printInfo, pagination: pagination, columns: columns, lineCount: lines.count + (summary == nil ? 0 : 1),
                             rowHeight: rowHeight, headerHeight: headerHeight)
        super.init(frame: NSRect(x: 0, y: 0, width: layout.pageSize.width, height: layout.pageSize.height * CGFloat(layout.pageCount)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    private static func layout(for info: NSPrintInfo, pagination: NSPrintInfo.PaginationMode, columns: [Column], lineCount: Int,
                               rowHeight: CGFloat, headerHeight: CGFloat) -> Layout {
        let paper = info.paperSize
        let pageSize = NSSize(width: max(1, paper.width - info.leftMargin - info.rightMargin),
                              height: max(1, paper.height - info.topMargin - info.bottomMargin))
        let total = max(1, columns.reduce(0) { $0 + $1.width })
        let rowsPerPage = max(1, Int((pageSize.height - headerHeight) / rowHeight))
        let rowPages = max(1, (lineCount + rowsPerPage - 1) / rowsPerPage)
        let all = Array(columns.indices)
        switch pagination {
        case .automatic where total > pageSize.width:
            return Layout(pageSize: pageSize, widths: columns.map(\.width), bands: bands(of: columns, width: pageSize.width),
                          rowsPerPage: rowsPerPage, rowPageCount: rowPages)
        case .clip, .automatic:
            return Layout(pageSize: pageSize, widths: columns.map(\.width), bands: [all], rowsPerPage: rowsPerPage, rowPageCount: rowPages)
        default:
            let scale = min(1, pageSize.width / total)
            return Layout(pageSize: pageSize, widths: columns.map { $0.width * scale }, bands: [all], rowsPerPage: rowsPerPage,
                          rowPageCount: rowPages)
        }
    }

    /// Bands of whole columns that fit the width, each starting with the
    /// repeated columns (unless they leave no room); a column wider than
    /// what's left has a band of its own, cut off.
    private static func bands(of columns: [Column], width: CGFloat) -> [[Int]] {
        var repeated = columns.indices.filter { columns[$0].repeats }
        var repeatedWidth = repeated.reduce(0) { $0 + columns[$1].width }
        if repeatedWidth >= width * 0.6 {
            repeated = []
            repeatedWidth = 0
        }
        var bands: [[Int]] = []
        var band = repeated
        var used = repeatedWidth
        for index in columns.indices where !repeated.contains(index) {
            if used + columns[index].width > width, band.count > repeated.count {
                bands.append(band)
                band = repeated
                used = repeatedWidth
            }
            band.append(index)
            used += columns[index].width
        }
        if band.count > repeated.count || bands.isEmpty { bands.append(band) }
        return bands
    }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        // The rows and the summary as they are now, together.
        (lines, summary) = content(options)
        // Laid out again for the paper the operation prints on now.
        let info = NSPrintOperation.current?.printInfo ?? printInfo
        // (The table's pagination, whatever an operation's print info says:
        // the print panel doesn't change it, and a default one would clip.)
        layout = Self.layout(for: info, pagination: pagination, columns: columns, lineCount: lines.count + (summary == nil ? 0 : 1),
                             rowHeight: rowHeight, headerHeight: headerHeight)
        setFrameSize(NSSize(width: pageSize.width, height: pageSize.height * CGFloat(pageCount)))
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let first = max(0, Int(dirtyRect.minY / pageSize.height))
        let last = min(pageCount - 1, Int((dirtyRect.maxY - 1) / pageSize.height))
        guard first <= last else { return }
        for page in first...last { drawPage(page) }
    }

    private func drawPage(_ page: Int) {
        let top = CGFloat(page) * pageSize.height
        // Across, then down: every band of columns of a page of rows.
        let band = layout.bands[page % layout.bands.count]
        let rowPage = page / layout.bands.count
        // Cut off at the page's edge (`.clip`, a column wider than a page).
        NSRect(x: 0, y: top, width: pageSize.width, height: pageSize.height).clip()
        // The column titles, on every page.
        drawCells(columns.map(\.title), band: band, y: top, height: headerHeight, font: boldFont, color: .darkGray)
        NSColor.lightGray.setFill()
        NSRect(x: 0, y: top + headerHeight - 1, width: pageSize.width, height: 0.5).fill()
        var y = top + headerHeight
        let start = rowPage * rowsPerPage
        for index in start..<min(start + rowsPerPage, lines.count + (summary == nil ? 0 : 1)) {
            if index == lines.count, let summary {
                NSColor.lightGray.setFill()
                NSRect(x: 0, y: y, width: pageSize.width, height: 0.5).fill()
                drawCells(summary, band: band, y: y, height: rowHeight, font: boldFont, color: .black)
            } else {
                switch lines[index] {
                case .row(let ref):
                    if index.isMultiple(of: 2) == false {
                        NSColor(white: 0.5, alpha: 0.07).setFill()
                        NSRect(x: 0, y: y, width: pageSize.width, height: rowHeight).fill()
                    }
                    drawCells(texts(ref), band: band, y: y, height: rowHeight, font: font, color: .black)
                case .group(let title, let level, let count):
                    NSColor(white: 0.5, alpha: 0.14).setFill()
                    NSRect(x: 0, y: y, width: pageSize.width, height: rowHeight).fill()
                    let text = "\(title)  (\(count.formatted(.number.locale(locale))))"
                    let indent = 4 + CGFloat(level) * 12
                    draw(text, in: NSRect(x: isRightToLeft ? 4 : indent, y: y, width: pageSize.width - 4 - indent, height: rowHeight),
                         font: boldFont, color: .black, alignment: isRightToLeft ? .right : .left)
                }
            }
            y += rowHeight
        }
    }

    private func drawCells(_ values: [String], band: [Int], y: CGFloat, height: CGFloat, font: NSFont, color: NSColor) {
        var x: CGFloat = 0
        for index in band where index < widths.count && index < values.count {
            // Right to left, the first column at the right.
            let left = isRightToLeft ? pageSize.width - x - widths[index] : x
            draw(values[index], in: NSRect(x: left + 3, y: y, width: max(0, widths[index] - 6), height: height), font: font,
                 color: color, alignment: columns[index].alignment)
            x += widths[index]
        }
    }

    private func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        guard !text.isEmpty, rect.width > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let line = NSRect(x: rect.minX, y: rect.minY + (rect.height - lineHeight) / 2, width: rect.width, height: lineHeight)
        (text as NSString).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}
/// The table's options in the print panel: only the selected rows, and the
/// summary row. The preview follows them.
final class NGPrintOptionsAccessory: NSViewController, NSPrintPanelAccessorizing {
    private weak var pages: NGTablePrintView?

    @objc dynamic var printsSelectedRowsOnly = false {
        didSet { pages?.options.rows = printsSelectedRowsOnly ? .selected : .shown }
    }
    @objc dynamic var printsSummaryRow = true {
        didSet { pages?.options.includesSummaryRow = printsSummaryRow }
    }

    init(pages: NGTablePrintView) {
        self.pages = pages
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Table", bundle: .module, comment: "Print panel: the title of the table's options.")
        printsSelectedRowsOnly = pages.options.rows == .selected
        printsSummaryRow = pages.options.includesSummaryRow
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override func loadView() {
        let selected = NSButton(checkboxWithTitle: String(localized: "Selected rows only", bundle: .module,
                                                          comment: "Print panel: prints only the selected rows."),
                                target: self, action: #selector(toggleSelectedRowsOnly(_:)))
        selected.state = printsSelectedRowsOnly ? .on : .off
        let summary = NSButton(checkboxWithTitle: String(localized: "Summary row", bundle: .module,
                                                         comment: "Print panel: prints the summary row at the end."),
                               target: self, action: #selector(toggleSummaryRow(_:)))
        summary.state = printsSummaryRow ? .on : .off
        let stack = NSStackView(views: [selected, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        view = stack
    }

    @objc private func toggleSelectedRowsOnly(_ sender: NSButton) { printsSelectedRowsOnly = sender.state == .on }
    @objc private func toggleSummaryRow(_ sender: NSButton) { printsSummaryRow = sender.state == .on }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        let rows = printsSelectedRowsOnly
            ? String(localized: "Selected", bundle: .module, comment: "Print panel summary: only the selected rows print.")
            : String(localized: "All", bundle: .module, comment: "Print panel summary: all the rows shown print.")
        let summary = printsSummaryRow
            ? String(localized: "On", bundle: .module, comment: "Print panel summary: the summary row prints.")
            : String(localized: "Off", bundle: .module, comment: "Print panel summary: the summary row doesn't print.")
        return [
            [.itemName: String(localized: "Rows", bundle: .module, comment: "Print panel summary: which rows print."), .itemDescription: rows],
            [.itemName: String(localized: "Summary row", bundle: .module, comment: "Print panel: prints the summary row at the end."),
             .itemDescription: summary],
        ]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> { ["printsSelectedRowsOnly", "printsSummaryRow"] }
}
#endif
