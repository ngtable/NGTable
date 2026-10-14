import Foundation
import zlib

// Writing a table's values as a file: CSV (the displayed texts, like copying)
// or an Excel workbook (.xlsx) with numbers, dates and Booleans as such, in
// number formats matching the columns', a bold header row that stays in view
// and the column widths. The rows come in chunks as they are read and go
// into the file at once (a sink: a file, or memory), formatted, and for a
// workbook deflated, in pieces on all cores: an export holds a chunk or two,
// not the whole file. The workbook is a minimal Office Open XML package
// (inline strings; rows beyond Excel's limit of a sheet go on to more sheets)
// in a ZIP archive written here, a sheet's pieces deflated each on its own
// and joined (as pigz does), with zlib (without ZIP64: a workbook of 4 GB or
// more, or a sheet that large before deflating, isn't written).

/// A file format to export a table to (see `NGTableView.exportedData(as:options:)`).
public enum NGExportFormat: Sendable, Hashable {
    /// Comma-separated values as displayed, UTF-8 with a byte order mark (so
    /// Excel reads non-Latin text).
    case csv
    /// An Excel workbook: numbers, dates and check marks as values, in the
    /// columns' formats. Rows beyond what an Excel sheet holds (1,048,576,
    /// with the titles) go on to more sheets, each with the titles.
    case xlsx

    /// The file name extension.
    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .xlsx: "xlsx"
        }
    }
}

/// What an export contains.
public struct NGExportOptions: Sendable, Hashable {
    /// Which rows: those shown (filtered, in display order, without group
    /// headers or rows of collapsed groups), or the selected ones.
    public enum Rows: Sendable, Hashable {
        case shown
        case selected
    }

    public var rows: Rows
    /// Whether the summary row's values follow the rows.
    public var includesSummaryRow: Bool

    public init(rows: Rows = .shown, includesSummaryRow: Bool = true) {
        self.rows = rows
        self.includesSummaryRow = includesSummaryRow
    }
}

/// What an export is of besides its rows, read from the table first.
struct NGExportLayout: Sendable {
    struct Column: Sendable {
        let title: String
        let format: NGValueFormat
        let width: Double
        /// Its summary is a count (written as a plain number).
        var isCount = false
    }

    let columns: [Column]
    /// Rows an Excel sheet holds (titles and summary row included).
    var maxRowsPerSheet = 1_048_576
    /// The locale values are written in as displayed (the table's).
    var locale: Locale = .current
}

/// The summary row, read after the rows: texts as displayed and the values
/// behind them.
struct NGExportSummary: Sendable {
    let texts: [String]
    let values: [Double?]
}

enum NGExportError: Error {
    /// A workbook of 4 GB or more (or a sheet, before deflating): ZIP
    /// without ZIP64 can't hold it.
    case tooLarge
}

/// Where an export's bytes go: a file, or memory. Used by one task at a
/// time (each chunk is written after the one before), so without a lock.
final class NGExportSink: @unchecked Sendable {
    private let file: FileHandle?
    private(set) var contents = Data()
    /// Bytes written.
    private(set) var count = 0

    /// In memory (`contents`).
    init() { file = nil }

    init(file: FileHandle) { self.file = file }

    func write(_ bytes: Data) throws {
        if let file { try file.write(contentsOf: bytes) } else { contents.append(bytes) }
        count += bytes.count
    }

    /// Writes over bytes written before (a ZIP entry's header, once its
    /// size and checksum are known).
    func patch(_ bytes: Data, at offset: Int) throws {
        precondition(offset + bytes.count <= count)
        if let file {
            try file.seek(toOffset: UInt64(offset))
            try file.write(contentsOf: bytes)
            try file.seekToEnd()
        } else {
            contents.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }

    /// Everything written dropped, to start over.
    func truncate() throws {
        if let file { try file.truncate(atOffset: 0) } else { contents = Data() }
        count = 0
    }
}

/// Writes an export as its rows come: `write(rows:)` for each chunk (row
/// after row, a value for each column), `finish(summary:)` at the end;
/// `restart()` drops what was written (the rows are read again).
protocol NGExportWriter: AnyObject, Sendable {
    func write(rows values: [NGCellValue]) throws
    func finish(summary: NGExportSummary?) throws
    func restart() throws
}

enum NGTableExport {
    static func writer(for format: NGExportFormat, layout: NGExportLayout, sink: NGExportSink) -> any NGExportWriter {
        switch format {
        case .csv: NGCSVWriter(layout: layout, sink: sink)
        case .xlsx: NGWorkbookWriter(layout: layout, sink: sink)
        }
    }

    /// The results of `body` for consecutive ranges of `count` rows (at
    /// least `minimumRows` each, a few for each core), made on all cores.
    static func inPieces<Piece>(_ count: Int, minimumRows: Int = 256, _ body: (Range<Int>) -> Piece) -> [Piece] {
        guard count > 0 else { return [] }
        let pieceCount = max(1, min(count / minimumRows, ProcessInfo.processInfo.activeProcessorCount * 2))
        if pieceCount == 1 { return [body(0..<count)] }
        var pieces = [Piece?](repeating: nil, count: pieceCount)
        pieces.withUnsafeMutableBufferPointer { buffer in
            let output = NGUncheckedSendable(buffer)
            DispatchQueue.concurrentPerform(iterations: pieceCount) { piece in
                output.value[piece] = body((count * piece / pieceCount)..<(count * (piece + 1) / pieceCount))
            }
        }
        return pieces.map { $0! }
    }

    // MARK: CSV

    /// Text a spreadsheet would run as a formula (starting with =, +, -, @,
    /// a tab or a carriage return: "=HYPERLINK(…)" from a campaign's name)
    /// gets a leading apostrophe, which spreadsheets show as text. Numbers
    /// aren't touched (a negative one starts with "-").
    static func inert(_ text: String) -> String {
        guard let first = text.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) else { return text }
        return "'" + text
    }

    /// A CSV line of fields, quoted where they need it.
    static func appendCSVLine<Fields: Sequence<String>>(_ fields: Fields, to text: inout String) {
        var isFirst = true
        for field in fields {
            if !isFirst { text += "," }
            isFirst = false
            if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                text += "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            } else {
                text += field
            }
        }
        text += "\r\n"
    }

    // MARK: Excel

    /// An Excel number format code for a column format, or `nil` for General.
    static func numberFormatCode(for format: NGValueFormat) -> String? {
        func fraction(_ digits: Int) -> String { digits > 0 ? "." + String(repeating: "0", count: digits) : "" }
        switch format {
        case .automatic: return nil
        case .number(let digits): return "#,##0" + fraction(digits)
        case .percent(let digits): return "0" + fraction(digits) + "%"
        case .currency(let code):
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            let symbol = formatter.currencySymbol ?? code
            return "[$\(symbol.replacingOccurrences(of: "]", with: ""))]#,##0" + fraction(formatter.maximumFractionDigits)
        case .date(let includesTime): return includesTime ? "yyyy-mm-dd hh:mm" : "yyyy-mm-dd"
        }
    }

    /// "A1"-style reference (`column` from 0, `row` from 1).
    static func cellReference(column: Int, row: Int) -> String {
        var letters = ""
        var index = column + 1
        while index > 0 {
            let remainder = (index - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + remainder))) + letters
            index = (index - 1) / 26
        }
        return letters + String(row)
    }

    /// Text for XML: markup characters escaped, characters XML can't hold left out.
    static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default:
                let value = scalar.value
                if value == 0x9 || value == 0xA || value == 0xD || (value >= 0x20 && value != 0xFFFE && value != 0xFFFF) {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}


/// CSV: the titles, the rows as displayed, the summary row's texts; UTF-8
/// with a byte order mark (so Excel reads non-Latin text).
final class NGCSVWriter: NGExportWriter, @unchecked Sendable {
    private let layout: NGExportLayout
    private let sink: NGExportSink
    private let styles: [NGNumberStyle]
    private var hasBegun = false

    init(layout: NGExportLayout, sink: NGExportSink) {
        self.layout = layout
        self.sink = sink
        styles = layout.columns.map { NGNumberStyle($0.format, locale: layout.locale) }
    }

    private func beginIfNeeded() throws {
        guard !hasBegun else { return }
        hasBegun = true
        var text = "\u{FEFF}"
        NGTableExport.appendCSVLine(layout.columns.lazy.map(\.title), to: &text)
        try sink.write(Data(text.utf8))
    }

    func write(rows values: [NGCellValue]) throws {
        try beginIfNeeded()
        let count = layout.columns.count
        guard count > 0 else { return }
        let pieces = NGTableExport.inPieces(values.count / count) { rows -> Data in
            let styles = styles
            var text = ""
            for row in rows {
                NGTableExport.appendCSVLine((0..<count).lazy.map { column in
                    let value = values[row * count + column]
                    if case .number(let number) = value { return styles[column].string(for: number) }
                    return NGTableExport.inert(self.layout.columns[column].format.string(for: value, locale: self.layout.locale))
                }, to: &text)
            }
            return Data(text.utf8)
        }
        for piece in pieces { try sink.write(piece) }
    }

    func finish(summary: NGExportSummary?) throws {
        try beginIfNeeded()
        guard let summary else { return }
        var text = ""
        NGTableExport.appendCSVLine(summary.texts, to: &text)
        try sink.write(Data(text.utf8))
    }

    func restart() throws {
        try sink.truncate()
        hasBegun = false
    }
}

/// An Excel workbook: a sheet entry of the ZIP open while its rows come
/// (each chunk's XML deflated in pieces on all cores), the next sheet begun
/// when one is full, and the parts that name the sheets written at the end.
final class NGWorkbookWriter: NGExportWriter, @unchecked Sendable {
    /// Number formats of the workbook, from the columns' formats.
    private struct Styles {
        /// Custom number format codes (ids from 164).
        var codes: [String] = []
        /// Cell formats: (number format id, bold).
        var cellFormats: [(numberFormat: Int, bold: Bool)] = [(0, false), (0, true)]
        private var indexes: [String: Int] = [:]

        /// The cell format for a number format code (`nil`: General).
        mutating func cellFormat(code: String?, bold: Bool) -> Int {
            let key = "\(bold)|\(code ?? "")"
            if let index = indexes[key] { return index }
            var numberFormat = 0
            if let code {
                if let existing = codes.firstIndex(of: code) {
                    numberFormat = 164 + existing
                } else {
                    codes.append(code)
                    numberFormat = 163 + codes.count
                }
            }
            cellFormats.append((numberFormat, bold))
            indexes[key] = cellFormats.count - 1
            return cellFormats.count - 1
        }
    }

    private let layout: NGExportLayout
    private let sink: NGExportSink
    private var zip: NGZipWriter
    private let styles: Styles
    private let numberStyles: [Int]
    private let summaryStyles: [Int]
    private let dateStyles: [Int]
    /// Data rows a sheet holds: Excel's rows less the titles and the summary row.
    private let rowsPerSheet: Int
    private var hasBegun = false
    /// Sheets begun; the last is open.
    private var sheetCount = 0
    /// Data rows in the open sheet.
    private var rowsInSheet = 0

    init(layout: NGExportLayout, sink: NGExportSink) {
        self.layout = layout
        self.sink = sink
        zip = NGZipWriter(sink: sink)
        var styles = Styles()
        numberStyles = layout.columns.map { styles.cellFormat(code: NGTableExport.numberFormatCode(for: $0.format), bold: false) }
        let boldNumberStyles = layout.columns.map { styles.cellFormat(code: NGTableExport.numberFormatCode(for: $0.format), bold: true) }
        // A count is a plain number, not in the column's currency, percent or date.
        summaryStyles = layout.columns.indices.map { layout.columns[$0].isCount ? styles.cellFormat(code: nil, bold: true) : boldNumberStyles[$0] }
        dateStyles = layout.columns.map { column -> Int in
            let includesTime = if case .date(let time) = column.format { time } else { false }
            return styles.cellFormat(code: includesTime ? "yyyy-mm-dd hh:mm" : "yyyy-mm-dd", bold: false)
        }
        self.styles = styles
        rowsPerSheet = max(1, layout.maxRowsPerSheet - 2)
    }

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private func beginIfNeeded() throws {
        guard !hasBegun else { return }
        hasBegun = true
        // First, as packages begin (what tools that guess a file's type look for).
        try zip.add("_rels/.rels", Self.header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(Self.relationships)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
    }

    /// A sheet's beginning: the frozen titles, the widths, the title row.
    private func beginSheet() throws {
        sheetCount += 1
        rowsInSheet = 0
        try zip.begin("xl/worksheets/sheet\(sheetCount).xml")
        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
        """
        // (A sheet without columns has no <cols>: an empty one isn't valid.)
        if !layout.columns.isEmpty {
            sheet += "<cols>"
            for (index, column) in layout.columns.enumerated() {
                // Excel widths are in characters of the default font (about 7 points).
                sheet += "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(max(4, (column.width / 7).rounded()))\" customWidth=\"1\"/>"
            }
            sheet += "</cols>"
        }
        sheet += "<sheetData>"
        sheet += "<row r=\"1\">"
        for (index, column) in layout.columns.enumerated() {
            sheet += Self.inline(column.title, ref: NGTableExport.cellReference(column: index, row: 1), style: 1)
        }
        sheet += "</row>"
        try zip.append(NGZipWriter.piece(Data(sheet.utf8)))
    }

    /// The open sheet's end, with the summary row on the last sheet.
    private func endSheet(summary: NGExportSummary?) throws {
        var sheet = ""
        if let summary {
            let excelRow = rowsInSheet + 2
            sheet += "<row r=\"\(excelRow)\">"
            for column in layout.columns.indices {
                let ref = NGTableExport.cellReference(column: column, row: excelRow)
                if let value = summary.values[column], value.isFinite {
                    sheet += "<c r=\"\(ref)\" s=\"\(summaryStyles[column])\"><v>\(value)</v></c>"
                } else if !summary.texts[column].isEmpty {
                    sheet += Self.inline(summary.texts[column], ref: ref, style: 1)
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"
        try zip.end(Data(sheet.utf8))
    }

    private static func inline(_ text: String, ref: String, style: Int) -> String {
        "<c r=\"\(ref)\" t=\"inlineStr\"\(style > 0 ? " s=\"\(style)\"" : "")><is><t xml:space=\"preserve\">\(NGTableExport.escaped(text))</t></is></c>"
    }

    func write(rows values: [NGCellValue]) throws {
        try beginIfNeeded()
        let count = layout.columns.count
        guard count > 0 else { return }
        let rowCount = values.count / count
        var next = 0
        while next < rowCount {
            if sheetCount == 0 {
                try beginSheet()
            } else if rowsInSheet == rowsPerSheet {
                try endSheet(summary: nil)
                try beginSheet()
            }
            let first = next
            let taken = min(rowCount - next, rowsPerSheet - rowsInSheet)
            let firstExcelRow = rowsInSheet + 2
            let pieces = NGTableExport.inPieces(taken) { rows in
                NGZipWriter.piece(Data(self.rowsXML(values, rows: (first + rows.lowerBound)..<(first + rows.upperBound),
                                                    firstExcelRow: firstExcelRow + rows.lowerBound).utf8))
            }
            for piece in pieces { try zip.append(piece) }
            rowsInSheet += taken
            next += taken
        }
    }

    /// The XML of rows of `values` (indexes of the chunk's rows), the first
    /// as `firstExcelRow`.
    private func rowsXML(_ values: [NGCellValue], rows: Range<Int>, firstExcelRow: Int) -> String {
        let count = layout.columns.count
        var sheet = ""
        for row in rows {
            let excelRow = row - rows.lowerBound + firstExcelRow
            sheet += "<row r=\"\(excelRow)\">"
            for column in 0..<count {
                let ref = NGTableExport.cellReference(column: column, row: excelRow)
                let numberStyle = numberStyles[column] > 0 ? " s=\"\(numberStyles[column])\"" : ""
                switch values[row * count + column] {
                case .empty:
                    continue
                case .number(let number):
                    guard number.isFinite else { continue }
                    sheet += "<c r=\"\(ref)\"\(numberStyle)><v>\(number)</v></c>"
                case .bool(let flag):
                    sheet += "<c r=\"\(ref)\" t=\"b\"><v>\(flag ? 1 : 0)</v></c>"
                case .rating(let value, _):
                    sheet += "<c r=\"\(ref)\"\(numberStyle)><v>\(value)</v></c>"
                case .progress(let value, let total):
                    // The fraction, a number a sheet can use.
                    guard let fraction = NGCellValue.fraction(value, total) else { continue }
                    sheet += "<c r=\"\(ref)\"\(numberStyle)><v>\(fraction)</v></c>"
                case .sparkline(let sparkline):
                    // Its last value, a number a sheet can use (CSV has all of them).
                    guard let last = sparkline.lastValue, last.isFinite else { continue }
                    sheet += "<c r=\"\(ref)\"\(numberStyle)><v>\(last)</v></c>"
                case .date(let date):
                    // Excel counts days from 1899-12-30, in local time.
                    let local = date.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: date))
                    sheet += "<c r=\"\(ref)\" s=\"\(dateStyles[column])\"><v>\(local / 86_400 + 25_569)</v></c>"
                case let value:
                    let text = layout.columns[column].format.string(for: value, locale: layout.locale)
                    if !text.isEmpty { sheet += Self.inline(text, ref: ref, style: 0) }
                }
            }
            sheet += "</row>"
        }
        return sheet
    }

    func finish(summary: NGExportSummary?) throws {
        try beginIfNeeded()
        if sheetCount == 0 { try beginSheet() }
        try endSheet(summary: summary)
        let header = Self.header, relationships = Self.relationships
        try zip.add("[Content_Types].xml", header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        \((1...sheetCount).map { "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        </Types>
        """)
        try zip.add("xl/workbook.xml", header + """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="\(relationships)">\
        <sheets>\((1...sheetCount).map { "<sheet name=\"Sheet\($0)\" sheetId=\"\($0)\" r:id=\"rId\($0)\"/>" }.joined())</sheets></workbook>
        """)
        try zip.add("xl/_rels/workbook.xml.rels", header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \((1...sheetCount).map { "<Relationship Id=\"rId\($0)\" Type=\"\(relationships)/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>" }.joined())\
        <Relationship Id="rId\(sheetCount + 1)" Type="\(relationships)/styles" Target="styles.xml"/></Relationships>
        """)
        try zip.add("xl/styles.xml", stylesXML())
        try zip.finish()
    }

    private func stylesXML() -> String {
        var stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        """
        if !styles.codes.isEmpty {
            stylesXML += "<numFmts count=\"\(styles.codes.count)\">"
            for (index, code) in styles.codes.enumerated() {
                stylesXML += "<numFmt numFmtId=\"\(164 + index)\" formatCode=\"\(NGTableExport.escaped(code))\"/>"
            }
            stylesXML += "</numFmts>"
        }
        stylesXML += """
        <fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        """
        stylesXML += "<cellXfs count=\"\(styles.cellFormats.count)\">"
        for format in styles.cellFormats {
            stylesXML += "<xf numFmtId=\"\(format.numberFormat)\" fontId=\"\(format.bold ? 1 : 0)\" fillId=\"0\" borderId=\"0\" xfId=\"0\""
                + (format.numberFormat > 0 ? " applyNumberFormat=\"1\"" : "") + (format.bold ? " applyFont=\"1\"" : "") + "/>"
        }
        stylesXML += "</cellXfs></styleSheet>"
        return stylesXML
    }

    func restart() throws {
        try sink.truncate()
        zip = NGZipWriter(sink: sink)
        hasBegun = false
        sheetCount = 0
        rowsInSheet = 0
    }
}

/// A ZIP archive written into a sink: whole entries (`add`, deflated, or
/// stored when deflating doesn't help) and entries streamed in deflated
/// pieces (`begin`, `append`, `end`; the header's sizes and checksum written
/// over when it ends); the central directory kept until `finish()`. No ZIP64
/// (entries and the archive under 4 GB).
struct NGZipWriter {
    let sink: NGExportSink
    private var directory = Data()
    private var count = 0
    /// The size an archive stays below: 4 GB without ZIP64 (less in tests).
    var sizeLimit = Int(UInt32.max)
    /// The entry being streamed: where its header is, its checksum and sizes so far.
    private var open: (name: Data, offset: Int, crc: UInt32, size: Int, deflated: Int)?

    /// Of an entry being streamed: raw DEFLATE ending on a byte (a sync
    /// flush; the last one ends the stream), the checksum and size of the
    /// bytes deflated.
    struct Piece: Sendable {
        let deflated: Data
        let crc: UInt32
        let size: Int
    }

    init(sink: NGExportSink = NGExportSink()) {
        self.sink = sink
    }

    static func piece(_ contents: Data, isLast: Bool = false) -> Piece {
        Piece(deflated: deflate(contents, finishing: isLast), crc: crc32(contents), size: contents.count)
    }

    mutating func add(_ name: String, _ text: String) throws {
        try add(name, Data(text.utf8))
    }

    mutating func add(_ name: String, _ contents: Data) throws {
        precondition(open == nil)
        let deflated = Self.deflate(contents, finishing: true)
        let stored = deflated.count >= contents.count
        let body = stored ? contents : deflated
        guard sink.count + body.count + 64 < sizeLimit, contents.count < sizeLimit else { throw NGExportError.tooLarge }
        let offset = sink.count
        let nameData = Data(name.utf8)
        let crc = Self.crc32(contents)
        try sink.write(localHeader(name: nameData, method: stored ? 0 : 8, crc: crc, deflated: body.count, size: contents.count) + body)
        addToDirectory(name: nameData, method: stored ? 0 : 8, crc: crc, deflated: body.count, size: contents.count, offset: offset)
    }

    /// Begins an entry whose deflated pieces come with `append` and `end`.
    mutating func begin(_ name: String) throws {
        precondition(open == nil)
        let nameData = Data(name.utf8)
        guard sink.count + nameData.count + 64 < sizeLimit else { throw NGExportError.tooLarge }
        open = (nameData, sink.count, 0, 0, 0)
        try sink.write(localHeader(name: nameData, method: 8, crc: 0, deflated: 0, size: 0))
    }

    mutating func append(_ piece: Piece) throws {
        guard var entry = open else { preconditionFailure("No entry begun") }
        guard sink.count + piece.deflated.count + 64 < sizeLimit, entry.size + piece.size < sizeLimit else { throw NGExportError.tooLarge }
        try sink.write(piece.deflated)
        entry.crc = entry.size == 0 ? piece.crc : UInt32(crc32_combine(uLong(entry.crc), uLong(piece.crc), piece.size))
        entry.size += piece.size
        entry.deflated += piece.deflated.count
        open = entry
    }

    /// Ends the streamed entry with its last bytes.
    mutating func end(_ last: Data) throws {
        try append(Self.piece(last, isLast: true))
        guard let entry = open else { return }
        open = nil
        try sink.patch(localHeader(name: entry.name, method: 8, crc: entry.crc, deflated: entry.deflated, size: entry.size),
                       at: entry.offset)
        addToDirectory(name: entry.name, method: 8, crc: entry.crc, deflated: entry.deflated, size: entry.size, offset: entry.offset)
    }

    /// The central directory and its end record.
    mutating func finish() throws {
        precondition(open == nil)
        // With the end record (22 bytes).
        guard sink.count + directory.count + 22 < sizeLimit else { throw NGExportError.tooLarge }
        let directoryOffset = UInt32(sink.count)
        var end = directory
        end.append(le32(0x0605_4b50))
        end.append(le16(0)); end.append(le16(0))
        end.append(le16(UInt16(count))); end.append(le16(UInt16(count)))
        end.append(le32(UInt32(directory.count))); end.append(le32(directoryOffset))
        end.append(le16(0))
        try sink.write(end)
    }

    private func localHeader(name: Data, method: UInt16, crc: UInt32, deflated: Int, size: Int) -> Data {
        var header = Data()
        header.append(le32(0x0403_4b50))
        header.append(le16(20)); header.append(le16(0x0800)); header.append(le16(method))
        header.append(le16(0)); header.append(le16(0x21))   // Time 00:00, date 1980-01-01.
        header.append(le32(crc)); header.append(le32(UInt32(deflated))); header.append(le32(UInt32(size)))
        header.append(le16(UInt16(name.count))); header.append(le16(0))
        header.append(name)
        return header
    }

    private mutating func addToDirectory(name: Data, method: UInt16, crc: UInt32, deflated: Int, size: Int, offset: Int) {
        directory.append(le32(0x0201_4b50))
        directory.append(le16(20)); directory.append(le16(20)); directory.append(le16(0x0800)); directory.append(le16(method))
        directory.append(le16(0)); directory.append(le16(0x21))
        directory.append(le32(crc)); directory.append(le32(UInt32(deflated))); directory.append(le32(UInt32(size)))
        directory.append(le16(UInt16(name.count))); directory.append(le16(0)); directory.append(le16(0))
        directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(0)); directory.append(le32(UInt32(offset)))
        directory.append(name)
        count += 1
    }

    private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    /// Raw DEFLATE of `contents` on its own, ending on a byte boundary: with
    /// the stream's end (`finishing`), or a sync flush that the next piece's
    /// DEFLATE may follow.
    static func deflate(_ contents: Data, finishing: Bool) -> Data {
        var stream = z_stream()
        // Raw DEFLATE (negative window bits), zlib's default level.
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { preconditionFailure("deflateInit2 failed") }
        defer { deflateEnd(&stream) }
        // The bound, and a sync flush's empty block.
        let capacity = Int(deflateBound(&stream, uLong(contents.count))) + 16
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outputBuffer in
            contents.withUnsafeBytes { inputBuffer -> Int in
                stream.next_in = UnsafeMutablePointer(mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(contents.count)
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                let result = zlib.deflate(&stream, finishing ? Z_FINISH : Z_SYNC_FLUSH)
                precondition(result == (finishing ? Z_STREAM_END : Z_OK) && stream.avail_in == 0, "deflate failed")
                return capacity - Int(stream.avail_out)
            }
        }
        return output.prefix(written)
    }

    static func crc32(_ contents: Data) -> UInt32 {
        contents.withUnsafeBytes { buffer in
            UInt32(zlib.crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
        }
    }
}
