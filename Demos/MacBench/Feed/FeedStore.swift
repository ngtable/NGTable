//
//  FeedStore.swift
//  NGTable Mac Bench
//
//  the rows of an ngfeed stream, by column (numbers as plain arrays of Double, NaN for
//  null; text as arrays of strings), and the table's data source. Messages are applied in order,
//  each telling the table what changed, within the frame's batch: updates write the fields, and
//  the changed cells of all of them are reloaded once, at the end of the batch (`hft` sends a
//  message for every change, 45 000 a second); inserts go at the end, a delete moves the last row
//  into the hole (no shift of a million rows) and tells the table so. Rows are found by their
//  ids' keys (numbered by the decoder), columns are arrays written in place.
//

import AppKit
import NGTable

final class FeedStore: NSObject, BenchRowSource {
    private(set) var schema: [FeedField] = []
    private(set) var ids: [String] = []
    /// Each row's id's key (`FeedRow.key`), and each key's row (-1: gone): found by index, not
    /// by hashing the id (that, and every write retaining a column object, was a fifth of the
    /// main thread under firehose).
    private var keys: [Int32] = []
    private var rowOfKey: [Int32] = []
    /// The columns' values, numbers and text apart, written in place; `slots[field]` says where.
    /// (No dynamic exclusivity checks: every write checked them, a tenth of writing.)
    @exclusivity(unchecked) private var numbers: [[Double]] = []
    @exclusivity(unchecked) private var texts: [[String?]] = []
    private var slots: [(isNumber: Bool, slot: Int)] = []
    /// Schema index by field name (the table's column ids).
    private var fieldIndex: [String: Int] = [:]
    /// Rows updated since the table was last told, with the fields each changed. The table
    /// re-reads (and re-sorts) a row by the columns reported for it: rows that changed a sort
    /// column and those that didn't are told apart, so an order whose fill changed isn't placed
    /// again in a table sorted by price. (Lists, given to the table as they are: no index set of
    /// thousands of scattered rows.)
    private var pendingRows: [Int] = []
    private var pendingFields: [FieldMask] = []

    /// A set of schema fields (128 at most; wider schemas count every field past them as one).
    private struct FieldMask: Hashable {
        var low: UInt64 = 0, high: UInt64 = 0

        mutating func insert(_ field: Int) {
            if field < 64 { low |= 1 << UInt64(field) } else { high |= 1 << UInt64(min(field - 64, 63)) }
        }

        func contains(_ field: Int) -> Bool {
            field < 64 ? low & (1 << UInt64(field)) != 0 : high & (1 << UInt64(min(field - 64, 63))) != 0
        }

        func intersects(_ other: FieldMask) -> Bool { low & other.low != 0 || high & other.high != 0 }

        mutating func formUnion(_ other: FieldMask) {
            low |= other.low
            high |= other.high
        }
    }

    var count: Int { ids.count }

    // MARK: The table's columns

    /// Columns for the schema: text, prices, percents, counts, times.
    func tableColumns() -> [NGColumnItem] {
        schema.map { field in
            var column = NGTableColumn(field.name, title: Self.title(of: field.name), width: field.isNumber ? 100 : 120)
            switch (field.kind, field.name) {
            case (.string, "id"): column.width = 140; column.pin = .leading
            case (.string, "note"): column.width = 220
            case (.string, _): break
            case (.time, _): column.format = .date(includesTime: true); column.width = 170
            case (_, "change"): column.format = .percent(fractionDigits: 2); column.changeHighlight = .direction
            case (_, "bid"), (_, "ask"), (_, "last"), (_, "price"): column.changeHighlight = .direction
            case (_, "volume"), (_, "qty"), (_, "filled"): column.format = .number(fractionDigits: 2); column.summary = .aggregate(.sum)
            case (.i64, _): column.format = .number(fractionDigits: 0); column.summary = .aggregate(.sum)
            default: break
            }
            if field.isNumber, column.alignment == .leading { column.alignment = .trailing }
            return .column(column)
        }
    }

    private static func title(of name: String) -> String {
        ["id": "ID", "symbol": "Символ", "venue": "Площадка", "status": "Статус", "bid": "Bid", "ask": "Ask", "last": "Последняя",
         "open": "Открытие", "change": "Изм.", "volume": "Объём", "trades": "Сделки", "updated": "Обновлено", "note": "Заметка",
         "side": "Сторона", "price": "Цена", "qty": "Кол-во", "filled": "Исполнено", "placed": "Выставлена"][name] ?? name
    }

    // MARK: Messages

    /// A new schema: no rows until the snapshot.
    func reset(schema: [FeedField]) {
        self.schema = schema
        fieldIndex = Dictionary(uniqueKeysWithValues: schema.enumerated().map { ($1.name, $0) })
        lastColumn = ("", nil)
        (ids, keys, rowOfKey) = ([], [], [])
        (pendingRows, pendingFields) = ([], [])
        var numberCount = 0, textCount = 0
        slots = schema.map { field in
            defer { if field.isNumber { numberCount += 1 } else { textCount += 1 } }
            return field.isNumber ? (true, numberCount) : (false, textCount)
        }
        numbers = Array(repeating: [], count: numberCount)
        texts = Array(repeating: [], count: textCount)
    }

    /// A whole snapshot instead of the rows (the table reloads).
    func load(_ snapshot: FeedSnapshot) {
        // The rows before are freed off the main thread (a million strings took it 30 ms).
        let old = Leftovers(ids: ids, texts: texts, numbers: numbers)
        ids = snapshot.ids
        // Row i has key i (see `FeedSnapshot`).
        keys = (0..<Int32(snapshot.ids.count)).map { $0 }
        rowOfKey = keys
        for (field, column) in snapshot.columns.enumerated() {
            switch column {
            case .numbers(let values): numbers[slots[field].slot] = values
            case .texts(let values): texts[slots[field].slot] = values
            }
        }
        (pendingRows, pendingFields) = ([], [])
        DispatchQueue.global(qos: .utility).async { withExtendedLifetime(old) {} }
    }

    /// Storage no one else holds, to be freed elsewhere.
    private final class Leftovers: @unchecked Sendable {
        let ids: [String]
        let texts: [[String?]]
        let numbers: [[Double]]

        init(ids: [String], texts: [[String?]], numbers: [[Double]]) {
            (self.ids, self.texts, self.numbers) = (ids, texts, numbers)
        }
    }

    /// The row of a key, if it has one.
    private func row(ofKey key: Int32) -> Int? {
        let key = Int(key)
        guard key >= 0, key < rowOfKey.count, rowOfKey[key] >= 0 else { return nil }
        return Int(rowOfKey[key])
    }

    /// Changed fields of rows: written; the table hears of them in `flushUpdates`.
    func update(_ rows: [FeedRow]) {
        for row in rows {
            guard let index = self.row(ofKey: row.key) else { continue }
            var fields = FieldMask()
            for (field, value) in row.fields {
                write(value, field: field, row: index)
                fields.insert(field)
            }
            pendingRows.append(index)
            pendingFields.append(fields)
        }
    }

    /// The cells updated since the last call reloaded, at once. Before rows move and at the end
    /// of the batch.
    func flushUpdates(table: some BenchRowUpdates) {
        guard !pendingRows.isEmpty else { return }
        var sortFields = FieldMask()
        for key in table.benchSortKeys { if let field = fieldIndex[key] { sortFields.insert(field) } }
        // Rows that changed a sort column, and the others: each with the fields any of them changed.
        var groups: [(fields: FieldMask, rows: [Int])] = [(FieldMask(), []), (FieldMask(), [])]
        for (row, fields) in zip(pendingRows, pendingFields) {
            let group = fields.intersects(sortFields) ? 0 : 1
            groups[group].fields.formUnion(fields)
            groups[group].rows.append(row)
        }
        // The table's columns by field (the user may have moved them).
        let position = Dictionary(table.benchColumnIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for (fields, rows) in groups where !rows.isEmpty {
            let columnIndexes = IndexSet(schema.indices.compactMap { fields.contains($0) ? position[schema[$0].name] : nil })
            table.benchReloadRows(rows, columns: columnIndexes)
        }
        pendingRows.removeAll(keepingCapacity: true)
        pendingFields.removeAll(keepingCapacity: true)
    }

    /// New rows, at the end.
    func insert(_ rows: [FeedRow], table: some BenchRowUpdates) {
        let first = ids.count
        for row in rows where self.row(ofKey: row.key) == nil {
            let index = ids.count
            ids.append(row.id)
            keys.append(row.key)
            let key = Int(row.key)
            if key >= rowOfKey.count { rowOfKey.append(contentsOf: repeatElement(-1, count: key - rowOfKey.count + 1)) }
            rowOfKey[key] = Int32(index)
            for slot in numbers.indices { numbers[slot].append(.nan) }
            for slot in texts.indices { texts[slot].append(nil) }
            for (field, value) in row.fields { write(value, field: field, row: index) }
        }
        guard ids.count > first else { return }
        table.benchInsertRows(at: IndexSet(integersIn: first..<ids.count))
    }

    /// Rows gone: the last row takes each one's place.
    func delete(_ removed: [Int32], table: some BenchRowUpdates) {
        flushUpdates(table: table)   // The rows of the updates move.
        for key in removed {
            guard let index = row(ofKey: key) else { continue }
            rowOfKey[Int(key)] = -1
            let last = ids.count - 1
            if index != last {
                ids[index] = ids[last]
                keys[index] = keys[last]
                rowOfKey[Int(keys[index])] = Int32(index)
                for slot in numbers.indices { numbers[slot][index] = numbers[slot][last] }
                for slot in texts.indices { texts[slot][index] = texts[slot][last] }
            }
            ids.removeLast()
            keys.removeLast()
            for slot in numbers.indices { numbers[slot].removeLast() }
            for slot in texts.indices { texts[slot].removeLast() }
            table.benchRemoveRowReplacingWithLast(at: index)
        }
    }

    // MARK: Storage

    private func write(_ value: FeedValue, field: Int, row: Int) {
        let (isNumber, slot) = slots[field]
        if isNumber {
            if case .number(let number) = value { numbers[slot][row] = number } else { numbers[slot][row] = .nan }
        } else if case .text(let text) = value {
            texts[slot][row] = text
        } else {
            texts[slot][row] = nil
        }
    }

    // MARK: NGTableViewDataSource

    func numberOfRows(in tableView: NGTableView) -> Int { ids.count }

    /// The last column asked for and its field: the table reads a column's rows one after another
    /// (a dictionary lookup hashed the id on every call).
    private var lastColumn: (id: String, field: Int?) = ("", nil)

    private func field(of column: NGTableColumn) -> Int? { field(of: column.id) }

    private func field(of id: String) -> Int? {
        if id == lastColumn.id { return lastColumn.field }
        let field = fieldIndex[id]
        lastColumn = (id, field)
        return field
    }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        benchValue(columnID: column.id, row: row)
    }

    var benchRowCount: Int { ids.count }

    func benchValue(columnID: String, row: Int) -> NGCellValue {
        guard row >= 0, row < ids.count, let field = field(of: columnID) else { return .empty }
        let (isNumber, slot) = slots[field]
        guard isNumber else { return texts[slot][row].map { .text($0) } ?? .empty }
        let number = numbers[slot][row]
        if number.isNaN { return .empty }
        return schema[field].kind == .time ? .date(Date(timeIntervalSince1970: number / 1_000_000)) : .number(number)
    }

    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? {
        row >= 0 && row < ids.count ? ids[row] : nil
    }

    /// Numbers of a range of rows at once: summaries and sorting read them so.
    func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        guard let field = field(of: column), slots[field].isNumber, rows.upperBound <= ids.count else { return false }
        numbers[slots[field].slot].withUnsafeBufferPointer { source in
            for (offset, row) in rows.enumerated() { values[offset] = source[row] }
        }
        return true
    }

    /// Numbers of rows here and there at once: the summaries read a batch's changed rows so.
    func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, atRows rows: UnsafeBufferPointer<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        guard let field = field(of: column), slots[field].isNumber else { return false }
        numbers[slots[field].slot].withUnsafeBufferPointer { source in
            for (offset, row) in rows.enumerated() { values[offset] = row >= 0 && row < source.count ? source[row] : .nan }
        }
        return true
    }

    func tableView(_ tableView: NGTableView, sortNumbersFor column: NGTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        self.tableView(tableView, numbersFor: column, rows: rows, into: values)
    }

    /// The sort numbers of a batch's changed rows at once (the live sort reads them so).
    func tableView(_ tableView: NGTableView, sortNumbersFor column: NGTableColumn, atRows rows: UnsafeBufferPointer<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        self.tableView(tableView, numbersFor: column, atRows: rows, into: values)
    }
}
