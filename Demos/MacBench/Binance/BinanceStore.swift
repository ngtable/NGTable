//
//  BinanceStore.swift
//  NGTable Mac Bench
//
//  the rows of Binance's streams and the table's data source, in one of three
//  layouts: a row per pair (24-hour tickers and the best bid and ask), the latest trades
//  (a ring: past `tradeCapacity` the oldest row takes the newest trade), or the order books of
//  some pairs (a row per price level: new levels go at the end, a level whose quantity drops
//  to 0 leaves, the last row taking its place). Values are kept by column, numbers in arrays of
//  Double (NaN: none), written in place; the changed cells are reported to the table once, at
//  the end of the frame's batch, in two groups: rows whose order may change apart from the
//  others, so a table sorted by price doesn't place a row again for a changed quantity.
//

import AppKit
import NGTable

final class BinanceStore: NSObject, BenchRowSource {
    enum Mode: String, CaseIterable {
        case tickers, trades, depth

        var title: String {
            switch self {
            case .tickers: "Тикеры всех пар"
            case .trades: "Сделки"
            case .depth: "Стакан"
            }
        }
    }

    /// A column of a layout: its values are numbers (in `numbers`) or text (in `texts`).
    struct Column {
        enum Kind { case number, text, time }
        let id: String
        let title: String
        let kind: Kind
        var format: NGValueFormat = .automatic
        var width: CGFloat = 100
        var highlight: NGChangeHighlight? = nil
        var summary: NGColumnSummary = .none
        var pin: NGColumnPin = .none
    }

    /// The oldest of this many trades gives its row to the newest.
    var tradeCapacity = 100_000

    private(set) var mode: Mode = .tickers
    private(set) var columns: [Column] = []
    private(set) var count = 0
    /// Each column's values (the other kind's array stays empty).
    @exclusivity(unchecked) private var numbers: [[Double]] = []
    @exclusivity(unchecked) private var texts: [[String]] = []
    private var columnIndex: [String: Int] = [:]

    // Rows by what they show.
    private var rowOfSymbol: [String: Int] = [:]
    private struct LevelKey: Hashable {
        let symbol: String
        let isBid: Bool
        let price: UInt64
    }
    private var rowOfLevel: [LevelKey: Int] = [:]
    private var levelOfRow: [LevelKey] = []
    /// The trade ring's next row to take a trade, once it is full.
    private var nextTradeRow = 0

    /// Rows changed since the table was last told, in two groups (0: a new row or a column the
    /// order may depend on, 1: the others), each with the columns changed; marks keep a row once.
    private var pending: [(rows: [Int], marks: [Bool], columns: IndexSet)] = [([], [], []), ([], [], [])]

    // MARK: Layouts

    func reset(mode: Mode) {
        self.mode = mode
        columns = Self.layout(of: mode)
        columnIndex = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1.id, $0) })
        numbers = columns.map { _ in [] }
        texts = columns.map { _ in [] }
        count = 0
        rowOfSymbol = [:]
        rowOfLevel = [:]
        levelOfRow = []
        nextTradeRow = 0
        pending = [([], [], []), ([], [], [])]
    }

    private static func layout(of mode: Mode) -> [Column] {
        let price = NGValueFormat.automatic
        switch mode {
        case .tickers:
            return [
                Column(id: "symbol", title: "Пара", kind: .text, width: 110, pin: .leading),
                Column(id: "last", title: "Цена", kind: .number, format: price, width: 120, highlight: .direction),
                Column(id: "bid", title: "Bid", kind: .number, format: price, width: 120, highlight: .direction),
                Column(id: "bidQty", title: "Bid, кол-во", kind: .number, format: price, width: 110),
                Column(id: "ask", title: "Ask", kind: .number, format: price, width: 120, highlight: .direction),
                Column(id: "askQty", title: "Ask, кол-во", kind: .number, format: price, width: 110),
                Column(id: "spread", title: "Спред", kind: .number, format: .percent(fractionDigits: 3), width: 90),
                Column(id: "change", title: "Изм. 24 ч", kind: .number, format: .percent(fractionDigits: 2), width: 100, highlight: .direction),
                Column(id: "high", title: "Макс. 24 ч", kind: .number, format: price, width: 120),
                Column(id: "low", title: "Мин. 24 ч", kind: .number, format: price, width: 120),
                Column(id: "volume", title: "Объём", kind: .number, format: .number(fractionDigits: 2), width: 130),
                // (In each pair's quote currency: no total.)
                Column(id: "quoteVolume", title: "Оборот", kind: .number, format: .number(fractionDigits: 0), width: 140),
                Column(id: "trades", title: "Сделок", kind: .number, format: .number(fractionDigits: 0), width: 100, summary: .aggregate(.sum)),
                Column(id: "updated", title: "Обновлено", kind: .time, width: 110),
            ]
        case .trades:
            return [
                Column(id: "time", title: "Время", kind: .time, width: 110, pin: .leading),
                Column(id: "symbol", title: "Пара", kind: .text, width: 100),
                Column(id: "side", title: "Сторона", kind: .text, width: 90),
                Column(id: "price", title: "Цена", kind: .number, format: price, width: 120),
                Column(id: "qty", title: "Кол-во", kind: .number, format: price, width: 110),
                Column(id: "amount", title: "Сумма", kind: .number, format: .number(fractionDigits: 2), width: 120, summary: .aggregate(.sum)),
                Column(id: "tradeID", title: "ID сделки", kind: .number, format: .number(fractionDigits: 0), width: 130),
                Column(id: "latency", title: "Задержка, мс", kind: .number, format: .number(fractionDigits: 1), width: 110, summary: .aggregate(.average)),
            ]
        case .depth:
            return [
                Column(id: "symbol", title: "Пара", kind: .text, width: 100, pin: .leading),
                Column(id: "side", title: "Сторона", kind: .text, width: 80),
                Column(id: "price", title: "Цена", kind: .number, format: price, width: 130),
                Column(id: "qty", title: "Кол-во", kind: .number, format: price, width: 120, highlight: .direction),
                Column(id: "amount", title: "Сумма", kind: .number, format: .number(fractionDigits: 2), width: 130, summary: .aggregate(.sum)),
                Column(id: "updated", title: "Обновлено", kind: .time, width: 110),
            ]
        }
    }

    func tableColumns() -> [NGColumnItem] {
        columns.map { spec in
            var column = NGTableColumn(spec.id, title: spec.title, width: spec.width)
            column.format = spec.format
            column.changeHighlight = spec.highlight
            column.summary = spec.summary
            column.pin = spec.pin
            if spec.kind != .text { column.alignment = .trailing }
            return .column(column)
        }
    }

    /// The columns rows are sorted by first in each layout.
    var defaultSort: [NSSortDescriptor] {
        switch mode {
        // (Turnovers are in different currencies: the busiest pairs by trades.)
        case .tickers: [NSSortDescriptor(key: "trades", ascending: false)]
        case .trades: [NSSortDescriptor(key: "time", ascending: false)]
        case .depth: [NSSortDescriptor(key: "symbol", ascending: true), NSSortDescriptor(key: "price", ascending: false)]
        }
    }

    // MARK: Writing

    private func column(_ id: String) -> Int { columnIndex[id]! }

    /// A new row at the end, empty (told to the table).
    private func appendRow(table: some BenchRowUpdates) -> Int {
        for index in columns.indices {
            if columns[index].kind == .text { texts[index].append("") } else { numbers[index].append(.nan) }
        }
        count += 1
        table.benchInsertRows(at: [count - 1])
        return count - 1
    }

    private func write(_ value: Double, _ column: Int, _ row: Int, group: Int) {
        let old = numbers[column][row]
        guard old != value, !(old.isNaN && value.isNaN) else { return }
        numbers[column][row] = value
        note(row, column, group: group)
    }

    private func write(_ text: String, _ column: Int, _ row: Int, group: Int) {
        guard texts[column][row] != text else { return }
        texts[column][row] = text
        note(row, column, group: group)
    }

    private func note(_ row: Int, _ column: Int, group: Int) {
        if pending[group].marks.count < count { pending[group].marks.append(contentsOf: repeatElement(false, count: count - pending[group].marks.count)) }
        if !pending[group].marks[row] {
            pending[group].marks[row] = true
            pending[group].rows.append(row)
        }
        pending[group].columns.insert(column)
    }

    /// Tells the table which cells changed (at the end of a batch, and before rows move).
    func flushUpdates(table: some BenchRowUpdates) {
        for group in pending.indices where !pending[group].rows.isEmpty {
            // (A row that left at the end of the rows is past them.)
            table.benchReloadRows(pending[group].rows.filter { $0 < count }, columns: pending[group].columns)
            for row in pending[group].rows where row < pending[group].marks.count { pending[group].marks[row] = false }
            pending[group].rows.removeAll(keepingCapacity: true)
            pending[group].columns = []
        }
    }

    /// The rows of every pair from REST (tickers), before the streams change them.
    func load(_ tickers: [BinanceTicker], table: some BenchRowUpdates) {
        for ticker in tickers { apply(ticker, table: table) }
    }

    func apply(_ ticker: BinanceTicker, table: some BenchRowUpdates) {
        guard mode == .tickers else { return }
        let row = rowOfSymbol[ticker.symbol] ?? {
            let row = appendRow(table: table)
            rowOfSymbol[ticker.symbol] = row
            write(ticker.symbol, column("symbol"), row, group: 0)
            return row
        }()
        write(ticker.last, column("last"), row, group: 0)
        write(ticker.changePercent / 100, column("change"), row, group: 0)
        write(ticker.high, column("high"), row, group: 0)
        write(ticker.low, column("low"), row, group: 0)
        write(ticker.volume, column("volume"), row, group: 0)
        write(ticker.quoteVolume, column("quoteVolume"), row, group: 0)
        write(ticker.trades, column("trades"), row, group: 0)
        write(Double(ticker.eventTime), column("updated"), row, group: 0)
    }

    func apply(_ book: BinanceBook, table: some BenchRowUpdates) {
        guard mode == .tickers, let row = rowOfSymbol[book.symbol] else { return }
        write(book.bid, column("bid"), row, group: 1)
        write(book.bidQuantity, column("bidQty"), row, group: 1)
        write(book.ask, column("ask"), row, group: 1)
        write(book.askQuantity, column("askQty"), row, group: 1)
        let middle = (book.bid + book.ask) / 2
        write(middle > 0 ? (book.ask - book.bid) / middle : .nan, column("spread"), row, group: 1)
    }

    /// A trade: a new row, or, the ring full, the oldest row. `receivedAt`: µs, for its latency.
    func apply(_ trade: BinanceTrade, receivedAt: Double, table: some BenchRowUpdates) {
        guard mode == .trades else { return }
        let row: Int
        if count < tradeCapacity {
            row = appendRow(table: table)
        } else {
            row = nextTradeRow
            nextTradeRow = (nextTradeRow + 1) % tradeCapacity
        }
        write(Double(trade.tradeTime), column("time"), row, group: 0)
        write(trade.symbol, column("symbol"), row, group: 0)
        write(trade.buyerIsMaker ? "Продажа" : "Покупка", column("side"), row, group: 0)
        write(trade.price, column("price"), row, group: 0)
        write(trade.quantity, column("qty"), row, group: 0)
        write(trade.price * trade.quantity, column("amount"), row, group: 0)
        write(Double(trade.tradeID), column("tradeID"), row, group: 0)
        write((receivedAt - Double(trade.eventTime)) / 1000, column("latency"), row, group: 0)
    }

    /// Order book levels of a pair: a quantity of 0 removes the level. `time`: µs.
    func apply(levels: [BinanceDepth.Level], isBid: Bool, symbol: String, time: Int64, table: some BenchRowUpdates) {
        guard mode == .depth else { return }
        for level in levels {
            let key = LevelKey(symbol: symbol, isBid: isBid, price: level.price.bitPattern)
            if let row = rowOfLevel[key] {
                if level.quantity == 0 {
                    removeLevel(at: row, table: table)
                } else {
                    write(level.quantity, column("qty"), row, group: 1)
                    write(level.price * level.quantity, column("amount"), row, group: 1)
                    write(Double(time), column("updated"), row, group: 1)
                }
            } else if level.quantity != 0 {
                let row = appendRow(table: table)
                rowOfLevel[key] = row
                levelOfRow.append(key)
                write(symbol, column("symbol"), row, group: 0)
                write(isBid ? "Bid" : "Ask", column("side"), row, group: 0)
                write(level.price, column("price"), row, group: 0)
                write(level.quantity, column("qty"), row, group: 0)
                write(level.price * level.quantity, column("amount"), row, group: 0)
                write(Double(time), column("updated"), row, group: 0)
            }
        }
    }

    /// Every level of a pair goes (its book is loaded again).
    func removeLevels(of symbol: String, table: some BenchRowUpdates) {
        let rows = rowOfLevel.filter { $0.key.symbol == symbol }.map(\.value).sorted(by: >)
        for row in rows { removeLevel(at: row, table: table) }
    }

    /// The last row takes the level's place (no shift), told to the table so; a change noted
    /// for the last row moves with it (the changes are told at the end of the batch).
    private func removeLevel(at row: Int, table: some BenchRowUpdates) {
        let last = count - 1
        for group in pending.indices where last < pending[group].marks.count && pending[group].marks[last] {
            pending[group].marks[last] = false
            if !pending[group].marks[row] {
                pending[group].marks[row] = true
                pending[group].rows.append(row)
            }
        }
        rowOfLevel[levelOfRow[row]] = nil
        if row != last {
            levelOfRow[row] = levelOfRow[last]
            rowOfLevel[levelOfRow[row]] = row
            for index in columns.indices {
                if columns[index].kind == .text { texts[index][row] = texts[index][last] } else { numbers[index][row] = numbers[index][last] }
            }
        }
        levelOfRow.removeLast()
        for index in columns.indices {
            if columns[index].kind == .text { texts[index].removeLast() } else { numbers[index].removeLast() }
        }
        count -= 1
        table.benchRemoveRowReplacingWithLast(at: row)
    }

    // MARK: Data source

    func numberOfRows(in tableView: NGTableView) -> Int { count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        benchValue(columnID: column.id, row: row)
    }

    var benchRowCount: Int { count }
    func benchIdentifier(row: Int) -> AnyHashable {
        switch mode {
        case .tickers: texts[column("symbol")][row]
        case .depth: levelOfRow[row]
        case .trades: numbers[column("tradeID")][row]
        }
    }

    func benchValue(columnID: String, row: Int) -> NGCellValue {
        guard row >= 0, row < count, let index = columnIndex[columnID] else { return .empty }
        switch columns[index].kind {
        case .text:
            return .text(texts[index][row])
        case .number:
            let number = numbers[index][row]
            return number.isNaN ? .empty : .number(number)
        case .time:
            let time = numbers[index][row]
            return time.isNaN ? .empty : .text(Self.timeText(microseconds: time))
        }
    }

    /// Times sort as numbers (shown as text).
    func tableView(_ tableView: NGTableView, sortValueFor column: NGTableColumn, row: Int) -> NGCellValue {
        guard let index = columnIndex[column.id], columns[index].kind == .time, row >= 0, row < count else {
            return self.tableView(tableView, valueFor: column, row: row)
        }
        let time = numbers[index][row]
        return time.isNaN ? .empty : .number(time)
    }

    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? {
        row >= 0 && row < count ? benchIdentifier(row: row) : nil
    }

    func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        guard let index = columnIndex[column.id], columns[index].kind == .number, rows.upperBound <= count else { return false }
        numbers[index].withUnsafeBufferPointer { source in
            for (offset, row) in rows.enumerated() { values[offset] = source[row] }
        }
        return true
    }

    func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, atRows rows: UnsafeBufferPointer<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        guard let index = columnIndex[column.id], columns[index].kind == .number else { return false }
        numbers[index].withUnsafeBufferPointer { source in
            for (offset, row) in rows.enumerated() { values[offset] = row >= 0 && row < source.count ? source[row] : .nan }
        }
        return true
    }

    func tableView(_ tableView: NGTableView, sortNumbersFor column: NGTableColumn, rows: Range<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        guard let index = columnIndex[column.id], columns[index].kind != .text, rows.upperBound <= count else { return false }
        numbers[index].withUnsafeBufferPointer { source in
            for (offset, row) in rows.enumerated() { values[offset] = source[row] }
        }
        return true
    }

    func tableView(_ tableView: NGTableView, sortNumbersFor column: NGTableColumn, atRows rows: UnsafeBufferPointer<Int>,
                   into values: UnsafeMutableBufferPointer<Double>) -> Bool {
        guard let index = columnIndex[column.id], columns[index].kind != .text else { return false }
        numbers[index].withUnsafeBufferPointer { source in
            for (offset, row) in rows.enumerated() { values[offset] = row >= 0 && row < source.count ? source[row] : .nan }
        }
        return true
    }

    /// `HH:mm:ss.SSS` in the local time zone (made by hand: a formatter per visible cell
    /// cost more than drawing it).
    static func timeText(microseconds: Double) -> String {
        let milliseconds = Int64(microseconds / 1000) + Int64(localOffset) * 1000
        let day = ((milliseconds % 86_400_000) + 86_400_000) % 86_400_000
        let (hours, minutes, seconds, millis) = (day / 3_600_000, day / 60_000 % 60, day / 1000 % 60, day % 1000)
        func two(_ value: Int64) -> String { value < 10 ? "0\(value)" : "\(value)" }
        let three = millis < 10 ? "00\(millis)" : millis < 100 ? "0\(millis)" : "\(millis)"
        return "\(two(hours)):\(two(minutes)):\(two(seconds)).\(three)"
    }

    private static let localOffset = TimeZone.current.secondsFromGMT()

    #if DEBUG
    /// For tests: a column's value at a row.
    func number(_ id: String, row: Int) -> Double { numbers[column(id)][row] }
    func text(_ id: String, row: Int) -> String { texts[column(id)][row] }
    #endif
}
