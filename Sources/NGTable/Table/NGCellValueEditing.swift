#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// A cell's value set by the user (typed, a check box, a rating, a choice),
// with Undo, and the text a value is edited as: the same on both platforms
// (the editors themselves are the platform's, see NGCellEditing.swift).

extension NGTableView {
    /// Gives the data source a cell's new value, reads the row again and
    /// registers the change for Undo (its undo sets the old value back).
    func setValue(_ value: NGCellValue, row: Int, column: NGTableColumn, undoValue: NGCellValue) {
        guard let dataSource, row < numberOfSourceRows else { return }
        dataSource.tableView(self, setValue: value, for: column, row: row)
        if let index = tableColumns.firstIndex(where: { $0.id == column.id }) {
            // The user's own edit moves its record at once, under the pointer too.
            isApplyingUserEdit = true
            defer { isApplyingUserEdit = false }
            reloadData(forRowIndexes: [row], columnIndexes: [index])
        }
        // The record may have moved by the time it's undone: found by its
        // reference (exact, also among rows sharing an identity), or after a
        // reload (references go) by its identity if rows have one; a record
        // that is gone isn't touched, nor another data source's.
        let identifier = identifier(forSourceRow: row)
        let ref = rowRef(ofRow: row)
        undoManager?.registerUndo(withTarget: self) { [weak source = dataSource as AnyObject] table in
            guard let source, table.dataSource as AnyObject === source else { return }
            var current = table.row(of: ref)
            if current < 0, ref.epoch != table.rowHandles.epoch, let identifier { current = table.row(forIdentifier: identifier) }
            guard current >= 0 else { return }
            table.setValue(undoValue, row: current, column: column, undoValue: value)
        }
        undoManager?.setActionName(String(localized: "Edit Cell", bundle: .module, comment: "Undo menu: a cell's value changed."))
    }

    /// The text a value is edited as: numbers without grouping, as typed.
    static func editingText(of value: NGCellValue, format: NGValueFormat, locale: Locale = .current) -> String {
        switch value {
        case .number(let number):
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.maximumFractionDigits = 10
            if case .percent = format { return (formatter.string(from: NSNumber(value: number * 100)) ?? "") + "%" }
            return formatter.string(from: NSNumber(value: number)) ?? ""
        default:
            return format.string(for: value, locale: locale)
        }
    }

    /// The value typed text means for a column: numbers for number formats
    /// (and where the cell held a number), dates for date columns, text
    /// otherwise; `nil` if it isn't a valid number or date where one is due.
    static func value(from text: String, format: NGValueFormat, like original: NGCellValue, locale: Locale = .current) -> NGCellValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        var wantsNumber = format.isNumeric
        if case .number = original { wantsNumber = true }
        if wantsNumber {
            // Letters other than the currency's (and an exponent's e) make it
            // not a number: "10 or 20" isn't 1020.
            var letters = trimmed
            if case .currency(let code) = format {
                let formatter = NumberFormatter()
                formatter.numberStyle = .currency
                formatter.currencyCode = code
                for symbol in [code, formatter.currencySymbol ?? ""] where !symbol.isEmpty {
                    letters = letters.replacingOccurrences(of: symbol, with: "", options: .caseInsensitive)
                }
            }
            guard !letters.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) && $0 != "e" && $0 != "E" }) else {
                return nil
            }
            // Without the currency's code and symbol (a code's E isn't an exponent).
            var cleaned = letters
            var isPercent = false
            if case .percent = format { isPercent = true }
            if cleaned.hasSuffix("%") {
                isPercent = true
                cleaned.removeLast()
            }
            // Currency symbols and spaces aside.
            cleaned = String(cleaned.unicodeScalars.filter {
                CharacterSet.decimalDigits.contains($0) || ",.-−+eE".unicodeScalars.contains($0)
            }).replacingOccurrences(of: "−", with: "-")
            // The user's locale first ("1 234,5"), then the common English
            // way ("1,234.5"), strictly (a lenient reading takes "1300.50" in
            // Swedish or German for 130050), then leniently, then a plain
            // number with either decimal mark.
            func parse(_ locale: Locale, lenient: Bool) -> Double? {
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .decimal
                formatter.isLenient = lenient
                return formatter.number(from: cleaned)?.doubleValue
            }
            let english = Locale(identifier: "en_US")
            let number = parse(locale, lenient: false) ?? parse(english, lenient: false)
                ?? parse(locale, lenient: true) ?? parse(english, lenient: true)
                ?? Double(cleaned.replacingOccurrences(of: ",", with: "."))
            guard let number else { return nil }
            return .number(isPercent ? number / 100 : number)
        }
        if format.isDate {
            let includesTime = if case .date(let time) = format { time } else { true }
            // As displayed first (`string(for:)`), then the usual styles.
            if let date = try? format.dateStyle(locale: .current).parse(trimmed) { return .date(date) }
            for style in [DateFormatter.Style.medium, .short, .long] {
                let formatter = DateFormatter()
                formatter.dateStyle = style
                formatter.timeStyle = includesTime ? .short : .none
                formatter.isLenient = true
                if let date = formatter.date(from: trimmed) { return .date(date) }
            }
            return nil
        }
        return .text(trimmed)
    }
}
#endif
