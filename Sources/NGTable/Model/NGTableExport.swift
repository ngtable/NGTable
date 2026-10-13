import Foundation
import Compression

// Writing a table's values as a file: CSV (the displayed texts, like copying)
// or an Excel workbook (.xlsx) with numbers, dates and Booleans as such, in
// number formats matching the columns', a bold header row that stays in view
// and the column widths. Pure functions of values read beforehand, so they
// run off the main thread; the workbook is a minimal Office Open XML package
// (inline strings; rows beyond Excel's limit of a sheet go on to more sheets)
// in a ZIP archive written here, deflated with the Compression framework
// (without ZIP64: a workbook of 4 GB or more isn't written).

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

/// The values of an export, read from the table: one column after another
/// for each row.
struct NGExportContent: Sendable {
    struct Column: Sendable {
        let title: String
        let format: NGValueFormat
        let width: Double
    }

    let columns: [Column]
    /// Row after row, `columns.count` values each.
    let values: [NGCellValue]
    /// The summary row: texts as displayed and the values behind them.
    let summaryTexts: [String]?
    let summaryValues: [Double?]?
    /// Which summaries are counts (written as plain numbers).
    var summaryIsCount: [Bool]? = nil
    /// Rows an Excel sheet holds (titles and summary row included).
    var maxRowsPerSheet = 1_048_576
    /// The locale values are written in as displayed (the table's).
    var locale: Locale = .current

    var rowCount: Int { columns.isEmpty ? 0 : values.count / columns.count }
}

enum NGTableExport {
    static func data(_ content: NGExportContent, as format: NGExportFormat) -> Data {
        switch format {
        case .csv: csv(content)
        case .xlsx: xlsx(content)
        }
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

    static func csv(_ content: NGExportContent) -> Data {
        let styles = content.columns.map { NGNumberStyle($0.format, locale: content.locale) }
        var text = "\u{FEFF}"
        func field(_ string: String) {
            if string.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                text += "\"" + string.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            } else {
                text += string
            }
        }
        func line(_ fields: [String]) {
            for (index, value) in fields.enumerated() {
                if index > 0 { text += "," }
                field(value)
            }
            text += "\r\n"
        }
        line(content.columns.map(\.title))
        let count = content.columns.count
        for row in 0..<content.rowCount {
            var fields: [String] = []
            fields.reserveCapacity(count)
            for column in 0..<count {
                let value = content.values[row * count + column]
                if case .number(let number) = value {
                    fields.append(styles[column].string(for: number))
                } else {
                    fields.append(Self.inert(content.columns[column].format.string(for: value, locale: content.locale)))
                }
            }
            line(fields)
        }
        if let summary = content.summaryTexts { line(summary) }
        return Data(text.utf8)
    }

    // MARK: Excel

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

    static func xlsx(_ content: NGExportContent) -> Data {
        var styles = Styles()
        let count = content.columns.count
        let numberStyles = content.columns.map { styles.cellFormat(code: numberFormatCode(for: $0.format), bold: false) }
        let boldNumberStyles = content.columns.map { styles.cellFormat(code: numberFormatCode(for: $0.format), bold: true) }
        // A count is a plain number, not in the column's currency, percent or date.
        let summaryStyles = content.columns.indices.map { content.summaryIsCount?[$0] == true ? styles.cellFormat(code: nil, bold: true) : boldNumberStyles[$0] }
        let dateStyles = content.columns.map { column -> Int in
            let includesTime = if case .date(let time) = column.format { time } else { false }
            return styles.cellFormat(code: includesTime ? "yyyy-mm-dd hh:mm" : "yyyy-mm-dd", bold: false)
        }

        // Excel's rows a sheet: the titles, the data, the summary row on the last.
        let rowsPerSheet = max(1, content.maxRowsPerSheet - 2)
        let sheetCount = max(1, (content.rowCount + rowsPerSheet - 1) / rowsPerSheet)
        func sheetXML(rows: Range<Int>, isLast: Bool) -> String {
            var sheet = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
            """
            // (A sheet without columns has no <cols>: an empty one isn't valid.)
            if !content.columns.isEmpty {
                sheet += "<cols>"
                for (index, column) in content.columns.enumerated() {
                    // Excel widths are in characters of the default font (about 7 points).
                    sheet += "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(max(4, (column.width / 7).rounded()))\" customWidth=\"1\"/>"
                }
                sheet += "</cols>"
            }
            sheet += "<sheetData>"
            func inline(_ text: String, ref: String, style: Int) -> String {
                "<c r=\"\(ref)\" t=\"inlineStr\"\(style > 0 ? " s=\"\(style)\"" : "")><is><t xml:space=\"preserve\">\(escaped(text))</t></is></c>"
            }
            sheet += "<row r=\"1\">"
            for (index, column) in content.columns.enumerated() {
                sheet += inline(column.title, ref: cellReference(column: index, row: 1), style: 1)
            }
            sheet += "</row>"
            for row in rows {
                let excelRow = row - rows.lowerBound + 2
                sheet += "<row r=\"\(excelRow)\">"
                for column in 0..<count {
                    let ref = cellReference(column: column, row: excelRow)
                    switch content.values[row * count + column] {
                    case .empty:
                        continue
                    case .number(let number):
                        guard number.isFinite else { continue }
                        sheet += "<c r=\"\(ref)\"\(numberStyles[column] > 0 ? " s=\"\(numberStyles[column])\"" : "")><v>\(number)</v></c>"
                    case .bool(let flag):
                        sheet += "<c r=\"\(ref)\" t=\"b\"><v>\(flag ? 1 : 0)</v></c>"
                    case .rating(let value, _):
                        sheet += "<c r=\"\(ref)\"\(numberStyles[column] > 0 ? " s=\"\(numberStyles[column])\"" : "")><v>\(value)</v></c>"
                    case .progress(let value, let total):
                        // The fraction, a number a sheet can use.
                        guard let fraction = NGCellValue.fraction(value, total) else { continue }
                        sheet += "<c r=\"\(ref)\"\(numberStyles[column] > 0 ? " s=\"\(numberStyles[column])\"" : "")><v>\(fraction)</v></c>"
                    case .sparkline(let sparkline):
                        // Its last value, a number a sheet can use (CSV has all of them).
                        guard let last = sparkline.lastValue, last.isFinite else { continue }
                        sheet += "<c r=\"\(ref)\"\(numberStyles[column] > 0 ? " s=\"\(numberStyles[column])\"" : "")><v>\(last)</v></c>"
                    case .date(let date):
                        // Excel counts days from 1899-12-30, in local time.
                        let local = date.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: date))
                        sheet += "<c r=\"\(ref)\" s=\"\(dateStyles[column])\"><v>\(local / 86_400 + 25_569)</v></c>"
                    case let value:
                        let text = content.columns[column].format.string(for: value, locale: content.locale)
                        if !text.isEmpty { sheet += inline(text, ref: ref, style: 0) }
                    }
                }
                sheet += "</row>"
            }
            if isLast, let texts = content.summaryTexts {
                let excelRow = rows.count + 2
                sheet += "<row r=\"\(excelRow)\">"
                for column in 0..<count {
                    let ref = cellReference(column: column, row: excelRow)
                    if let value = content.summaryValues?[column], value.isFinite {
                        sheet += "<c r=\"\(ref)\" s=\"\(summaryStyles[column])\"><v>\(value)</v></c>"
                    } else if !texts[column].isEmpty {
                        sheet += inline(texts[column], ref: ref, style: 1)
                    }
                }
                sheet += "</row>"
            }
            sheet += "</sheetData></worksheet>"
            return sheet
        }

        var stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        """
        if !styles.codes.isEmpty {
            stylesXML += "<numFmts count=\"\(styles.codes.count)\">"
            for (index, code) in styles.codes.enumerated() {
                stylesXML += "<numFmt numFmtId=\"\(164 + index)\" formatCode=\"\(escaped(code))\"/>"
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

        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var zip = NGZipWriter()
        zip.add("[Content_Types].xml", header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        \((1...sheetCount).map { "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        </Types>
        """)
        zip.add("_rels/.rels", header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(relationships)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        zip.add("xl/workbook.xml", header + """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="\(relationships)">\
        <sheets>\((1...sheetCount).map { "<sheet name=\"Sheet\($0)\" sheetId=\"\($0)\" r:id=\"rId\($0)\"/>" }.joined())</sheets></workbook>
        """)
        zip.add("xl/_rels/workbook.xml.rels", header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \((1...sheetCount).map { "<Relationship Id=\"rId\($0)\" Type=\"\(relationships)/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>" }.joined())\
        <Relationship Id="rId\(sheetCount + 1)" Type="\(relationships)/styles" Target="styles.xml"/></Relationships>
        """)
        for sheet in 0..<sheetCount {
            let rows = (sheet * rowsPerSheet)..<min(content.rowCount, (sheet + 1) * rowsPerSheet)
            zip.add("xl/worksheets/sheet\(sheet + 1).xml", sheetXML(rows: rows, isLast: sheet == sheetCount - 1))
        }
        zip.add("xl/styles.xml", stylesXML)
        // Too large for a ZIP without ZIP64: nothing rather than a broken file.
        return zip.finish() ?? Data()
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

/// A ZIP archive written in memory: deflated entries (stored when deflating
/// doesn't help), a central directory, no ZIP64 (entries under 4 GB).
struct NGZipWriter {
    private var data = Data()
    private var directory = Data()
    private var count = 0
    /// An entry or offset past 4 GB (the archive can't be written).
    private var isTooLarge = false
    /// The size an archive stays below: 4 GB without ZIP64 (less in tests).
    var sizeLimit = Int(UInt32.max)

    mutating func add(_ name: String, _ text: String) {
        add(name, Data(text.utf8))
    }

    mutating func add(_ name: String, _ contents: Data) {
        let crc = Self.crc32(contents)
        let deflated = Self.deflate(contents)
        let stored = deflated == nil || deflated!.count >= contents.count
        let body = stored ? contents : deflated!
        let method: UInt16 = stored ? 0 : 8
        let nameData = Data(name.utf8)
        guard !isTooLarge, data.count + body.count + 64 < sizeLimit, contents.count < sizeLimit else {
            isTooLarge = true
            return
        }
        let offset = UInt32(data.count)
        // Local file header.
        data.append(le32(0x0403_4b50))
        data.append(le16(20)); data.append(le16(0x0800)); data.append(le16(method))
        data.append(le16(0)); data.append(le16(0x21))   // Time 00:00, date 1980-01-01.
        data.append(le32(crc)); data.append(le32(UInt32(body.count))); data.append(le32(UInt32(contents.count)))
        data.append(le16(UInt16(nameData.count))); data.append(le16(0))
        data.append(nameData)
        data.append(body)
        // Central directory entry.
        directory.append(le32(0x0201_4b50))
        directory.append(le16(20)); directory.append(le16(20)); directory.append(le16(0x0800)); directory.append(le16(method))
        directory.append(le16(0)); directory.append(le16(0x21))
        directory.append(le32(crc)); directory.append(le32(UInt32(body.count))); directory.append(le32(UInt32(contents.count)))
        directory.append(le16(UInt16(nameData.count))); directory.append(le16(0)); directory.append(le16(0))
        directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(0)); directory.append(le32(offset))
        directory.append(nameData)
        count += 1
    }

    /// The archive, or `nil` if it would be 4 GB or more.
    mutating func finish() -> Data? {
        // With the end record (22 bytes).
        guard !isTooLarge, data.count + directory.count + 22 < sizeLimit else { return nil }
        var result = data
        let directoryOffset = UInt32(result.count)
        result.append(directory)
        result.append(le32(0x0605_4b50))
        result.append(le16(0)); result.append(le16(0))
        result.append(le16(UInt16(count))); result.append(le16(UInt16(count)))
        result.append(le32(UInt32(directory.count))); result.append(le32(directoryOffset))
        result.append(le16(0))
        return result
    }

    private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    /// Raw DEFLATE (what `COMPRESSION_ZLIB` writes), or `nil` if it fails.
    static func deflate(_ contents: Data) -> Data? {
        guard !contents.isEmpty else { return nil }
        let capacity = contents.count + contents.count / 10 + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outputBuffer in
            contents.withUnsafeBytes { inputBuffer in
                compression_encode_buffer(outputBuffer.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          inputBuffer.bindMemory(to: UInt8.self).baseAddress!, contents.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    static func crc32(_ contents: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        contents.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
