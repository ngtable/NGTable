//
//  BinanceTests.swift
//  NGTable Mac Bench Tests
//
//  The Binance client: its messages read from Binance's frames as they are sent, an order
//  book kept in step by Binance's rules, and the store's rows as the table shows them (levels
//  coming and going, trades in a ring).
//

import AppKit
import Foundation
import NGTable
import Testing
@testable import NGTable_Mac_Bench

@MainActor
struct BinanceTests {
    // MARK: Messages

    @Test func framesOfEveryStream() throws {
        let trade = #"{"stream":"btcusdt@trade","data":{"e":"trade","E":1791812055095123,"s":"BTCUSDT","t":5123456789,"p":"62000.01000000","q":"0.00150000","T":1791812055095001,"m":true,"M":true}}"#
        #expect(try BinanceDecoder.decode(Data(trade.utf8)) == .trade(BinanceTrade(
            symbol: "BTCUSDT", eventTime: 1791812055095123, tradeID: 5123456789, price: 62000.01, quantity: 0.0015,
            tradeTime: 1791812055095001, buyerIsMaker: true)))
        let book = #"{"stream":"ethbtc@bookTicker","data":{"u":400900217,"s":"ETHBTC","b":"0.03062000","B":"31.21000000","a":"0.03063000","A":"40.66000000"}}"#
        #expect(try BinanceDecoder.decode(Data(book.utf8)) == .book(BinanceBook(
            symbol: "ETHBTC", updateID: 400900217, bid: 0.03062, bidQuantity: 31.21, ask: 0.03063, askQuantity: 40.66)))
        let tickers = #"{"stream":"!ticker_1d@arr","data":[{"e":"1dTicker","E":1791812055000000,"s":"BNBUSDT","p":"-2.10","P":"-0.350","o":"600.00","h":"610.5","l":"590","c":"597.90","w":"601.2","v":"12345.6","q":"7400000.5","O":1,"C":2,"F":3,"L":4,"n":50000}]}"#
        guard case .tickers(let read) = try BinanceDecoder.decode(Data(tickers.utf8)) else { Issue.record("no tickers"); return }
        #expect(read == [BinanceTicker(symbol: "BNBUSDT", eventTime: 1791812055000000, last: 597.9, open: 600, high: 610.5, low: 590,
                                       volume: 12345.6, quoteVolume: 7400000.5, changePercent: -0.35, trades: 50000)])
        let depth = #"{"stream":"btcusdt@depth@100ms","data":{"e":"depthUpdate","E":1791812055100000,"s":"BTCUSDT","U":157,"u":160,"b":[["62000.00","1.5"],["61999.99","0.00000000"]],"a":[["62000.01","2"]]}}"#
        #expect(try BinanceDecoder.decode(Data(depth.utf8)) == .depth(BinanceDepth(
            symbol: "BTCUSDT", eventTime: 1791812055100000, firstID: 157, lastID: 160,
            bids: [.init(price: 62000, quantity: 1.5), .init(price: 61999.99, quantity: 0)], asks: [.init(price: 62000.01, quantity: 2)])))
        #expect(try BinanceDecoder.decode(Data(#"{"result":null,"id":3}"#.utf8)) == .reply(id: 3))
        #expect(try BinanceDecoder.decode(Data(#"{"error":{"code":2,"msg":"Invalid request"},"id":4}"#.utf8)) == .error("код 2 Invalid request"))
        #expect(throws: BinanceDecodingError.self) { try BinanceDecoder.decode(Data(#"{"stream":"btcusdt@kline_1m","data":{}}"#.utf8)) }
    }

    @Test func restSnapshots() throws {
        let book = #"{"lastUpdateId":1027024,"bids":[["4.00000000","431.00000000"]],"asks":[["4.00000200","12.00000000"],["4.1","0"]]}"#
        let snapshot = try BinanceDecoder.snapshot(Data(book.utf8))
        #expect(snapshot.lastUpdateID == 1027024)
        #expect(snapshot.bids == [.init(price: 4, quantity: 431)] && snapshot.asks.count == 2)
        // Pairs without trades (delisted) are left out.
        let mini = #"[{"symbol":"ETHBTC","openPrice":"0.03","highPrice":"0.031","lowPrice":"0.029","lastPrice":"0.0303","volume":"10","quoteVolume":"0.3","openTime":1,"closeTime":1791812054899,"firstId":1,"lastId":2,"count":24744},{"symbol":"OLDBTC","openPrice":"0","highPrice":"0","lowPrice":"0","lastPrice":"0","volume":"0","quoteVolume":"0","openTime":0,"closeTime":0,"firstId":-1,"lastId":-1,"count":0}]"#
        let books = try BinanceDecoder.bookTickers(Data(#"[{"symbol":"LTCBTC","bidPrice":"4.00000000","bidQty":"431.00000000","askPrice":"4.00000200","askQty":"9.00000000"}]"#.utf8))
        #expect(books == [BinanceBook(symbol: "LTCBTC", updateID: 0, bid: 4, bidQuantity: 431, ask: 4.000002, askQuantity: 9)])
        let tickers = try BinanceDecoder.miniTickers(Data(mini.utf8))
        #expect(tickers.map(\.symbol) == ["ETHBTC"])
        #expect(abs(tickers[0].changePercent - 1) < 1e-9 && tickers[0].eventTime == 1791812054899000)
    }

    // MARK: Order book sync

    private func change(_ first: Int64, _ last: Int64) -> BinanceDepth {
        BinanceDepth(symbol: "BTCUSDT", eventTime: 0, firstID: first, lastID: last, bids: [], asks: [])
    }

    @Test func aBookFollowsBinancesRules() {
        var sync = BinanceBookSync()
        // Buffered until the snapshot.
        #expect(sync.receive(change(100, 105)) == .apply([]))
        #expect(sync.receive(change(106, 110)) == .apply([]))
        // A snapshot older than the first buffered change: fetched again.
        #expect(sync.snapshot(lastUpdateID: 90) == .fetchAgain)
        // Changes it has are dropped; the next ones apply.
        #expect(sync.snapshot(lastUpdateID: 107) == .apply([change(106, 110)]))
        #expect(sync.lastID == 110)
        #expect(sync.receive(change(105, 109)) == .apply([]))
        #expect(sync.receive(change(111, 115)) == .apply([change(111, 115)]))
        // One missed: loaded again, the change buffered.
        #expect(sync.receive(change(120, 125)) == .broken)
        #expect(!sync.isSynced && sync.buffered == [change(120, 125)])
        #expect(sync.snapshot(lastUpdateID: 121) == .apply([change(120, 125)]))
    }

    // MARK: The store and the table

    private func makeTable(_ store: BinanceStore, _ mode: BinanceStore.Mode) -> NGTableView {
        store.reset(mode: mode)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        table.columns = store.tableColumns()
        table.dataSource = store
        table.sortsRows = true
        table.sortDescriptors = store.defaultSort
        table.reloadData()
        return table
    }

    /// Levels come, change and go (most removed ones not at the end) in batches, a changed
    /// last row moving into a removed one's place in the same batch: the table shows the
    /// model's levels, by price, and its total amount.
    @Test func orderBookLevelsAsTheTableShowsThem() {
        let store = BinanceStore()
        let table = makeTable(store, .depth)
        var model: [String: [Double: Double]] = ["BTCUSDT": [:], "ETHUSDT": [:]]   // price → quantity (bids, then asks apart)
        var asks: [String: [Double: Double]] = ["BTCUSDT": [:], "ETHUSDT": [:]]
        var generator = SystemRandomNumberGenerator()
        for round in 0..<40 {
            table.beginUpdates()
            for symbol in ["BTCUSDT", "ETHUSDT"] {
                var bids: [BinanceDepth.Level] = [], sells: [BinanceDepth.Level] = []
                for _ in 0..<30 {
                    let price = Double(Int.random(in: 0..<60, using: &generator)) + (symbol == "BTCUSDT" ? 1000 : 100)
                    let quantity = Bool.random(using: &generator) ? 0 : Double(Int.random(in: 1..<50, using: &generator))
                    if Bool.random(using: &generator) {
                        bids.append(.init(price: price, quantity: quantity))
                        model[symbol]![price] = quantity == 0 ? nil : quantity
                    } else {
                        sells.append(.init(price: price + 60, quantity: quantity))
                        asks[symbol]![price + 60] = quantity == 0 ? nil : quantity
                    }
                }
                store.apply(levels: bids, isBid: true, symbol: symbol, time: Int64(round), table: table)
                store.apply(levels: sells, isBid: false, symbol: symbol, time: Int64(round), table: table)
            }
            store.flushUpdates(table: table)
            table.endUpdates()
            // Shown: symbol ascending, price descending.
            var expected: [(String, Double, Double)] = []
            for symbol in ["BTCUSDT", "ETHUSDT"] {
                let levels = model[symbol]!.map { ($0.key, $0.value) } + asks[symbol]!.map { ($0.key, $0.value) }
                expected += levels.sorted { $0.0 > $1.0 }.map { (symbol, $0.0, $0.1) }
            }
            #expect(table.numberOfRows == expected.count, "round \(round)")
            let columns = Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.id, $0) })
            let shown = (0..<table.numberOfRows).map { row -> (String, Double, Double) in
                let source = table.row(atDisplayIndex: row) ?? -1
                guard case .text(let symbol) = store.tableView(table, valueFor: columns["symbol"]!, row: source),
                      case .number(let price) = store.tableView(table, valueFor: columns["price"]!, row: source),
                      case .number(let quantity) = store.tableView(table, valueFor: columns["qty"]!, row: source) else { return ("", 0, 0) }
                return (symbol, price, quantity)
            }
            #expect(shown.map { $0.0 } == expected.map { $0.0 } && shown.map { $0.1 } == expected.map { $0.1 }
                    && shown.map { $0.2 } == expected.map { $0.2 }, "round \(round)")
            let total = expected.reduce(0) { $0 + $1.1 * $1.2 }
            #expect(abs((table.summaryValue(forColumnID: "amount") ?? .nan) - total) < 1e-6, "round \(round): totals")
        }
        // A pair's book loaded again: its levels go.
        table.beginUpdates()
        store.removeLevels(of: "BTCUSDT", table: table)
        store.flushUpdates(table: table)
        table.endUpdates()
        #expect(table.numberOfRows == model["ETHUSDT"]!.count + asks["ETHUSDT"]!.count)
    }

    /// Past its capacity the oldest trade's row takes the newest: the newest trades shown,
    /// newest first.
    @Test func tradesInARing() {
        let store = BinanceStore()
        store.tradeCapacity = 50
        let table = makeTable(store, .trades)
        store.tradeCapacity = 50
        for batch in 0..<10 {
            table.beginUpdates()
            for index in 0..<17 {
                let id = Int64(batch * 17 + index)
                store.apply(BinanceTrade(symbol: "BTCUSDT", eventTime: id * 1000, tradeID: id, price: 100 + Double(id), quantity: 1,
                                         tradeTime: id * 1000, buyerIsMaker: id % 2 == 0), receivedAt: Double(id * 1000 + 500), table: table)
            }
            store.flushUpdates(table: table)
            table.endUpdates()
        }
        #expect(table.numberOfRows == 50)
        let shown = (0..<50).map { store.number("tradeID", row: (table.row(atDisplayIndex: $0) ?? 0)) }
        #expect(shown == (120..<170).reversed().map(Double.init))
        #expect(store.number("latency", row: (table.row(atDisplayIndex: 0) ?? 0)) == 0.5)
        #expect(store.text("side", row: (table.row(atDisplayIndex: 0) ?? 0)) == "Продажа" || store.text("side", row: (table.row(atDisplayIndex: 0) ?? 0)) == "Покупка")
    }

    /// The other engines show the same rows: SwiftUI's rows get ids of their own (a new trade's
    /// row has no values, so no trade id, when it comes), NSTableView's the store's values
    /// after levels come and go.
    @Test func otherEnginesShowTheStoresRows() throws {
        let trades = BinanceStore()
        trades.reset(mode: .trades)
        let swiftUI = SwiftUIBenchTable(source: trades)
        swiftUI.show(columns: trades.tableColumns(), sort: [])
        swiftUI.beginUpdates()
        for id in 0..<20 {
            trades.apply(BinanceTrade(symbol: "BTCUSDT", eventTime: Int64(id), tradeID: Int64(id), price: 1, quantity: 1, tradeTime: Int64(id),
                                      buyerIsMaker: false), receivedAt: 0, table: swiftUI)
        }
        trades.flushUpdates(table: swiftUI)
        swiftUI.endUpdates()
        #expect(Set(swiftUI.shownRows.map(\.id)).count == 20)
        let tradeIDIndex = try #require(trades.columns.firstIndex { $0.id == "tradeID" })
        #expect(swiftUI.shownRows.map { $0.values[tradeIDIndex] } == (0..<20).map { .number(Double($0)) })

        let depth = BinanceStore()
        depth.reset(mode: .depth)
        let ns = NSBenchTable(source: depth)
        ns.show(columns: depth.tableColumns(), sort: [])
        ns.beginUpdates()
        depth.apply(levels: (0..<30).map { .init(price: Double($0), quantity: 1) }, isBid: true, symbol: "BTCUSDT", time: 1, table: ns)
        depth.apply(levels: [3, 7, 29].map { .init(price: Double($0), quantity: 0) }, isBid: true, symbol: "BTCUSDT", time: 2, table: ns)
        depth.flushUpdates(table: ns)
        ns.endUpdates()
        #expect(ns.nsTableView.numberOfRows == 27)
        #expect(Set((0..<27).map { depth.number("price", row: $0) }) == Set((0..<30).filter { ![3, 7, 29].contains($0) }.map(Double.init)))
    }

    @Test func timesAsText() {
        let offset = Double(TimeZone.current.secondsFromGMT()) * 1_000_000
        // 13:04:05.678 UTC, in the local zone.
        let micros = Double((13 * 3600 + 4 * 60 + 5) * 1_000_000 + 678_000) + 86_400_000_000 * 20_000 - offset
        #expect(BinanceStore.timeText(microseconds: micros) == "13:04:05.678")
    }
}
