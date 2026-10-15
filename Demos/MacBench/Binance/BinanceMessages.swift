//
//  BinanceMessages.swift
//  NGTable Mac Bench
//
//  the messages of Binance's public market data streams (spot), read from the
//  bytes of a frame with the feed's JSON reader (FeedJSONReader): combined-stream frames
//  (`{"stream": …, "data": …}`) of rolling-window tickers of every pair, best bid and ask of a
//  pair, trades and order book changes, and the answers to SUBSCRIBE requests. Prices and
//  quantities come as strings and are read as Doubles; times are in microseconds (the streams
//  are opened with `timeUnit=MICROSECOND`).
//

import Foundation

/// A pair's statistics over the last 24 hours (`!ticker_1d@arr`, every second).
nonisolated struct BinanceTicker: Equatable, Sendable {
    var symbol: String
    var eventTime: Int64
    var last: Double
    var open: Double
    var high: Double
    var low: Double
    var volume: Double
    var quoteVolume: Double
    /// Percent, as Binance gives it (`2.5` is 2.5%).
    var changePercent: Double
    var trades: Double
}

/// A pair's best bid and ask (`<pair>@bookTicker`, as they change). No event time.
nonisolated struct BinanceBook: Equatable, Sendable {
    var symbol: String
    var updateID: Int64
    var bid: Double
    var bidQuantity: Double
    var ask: Double
    var askQuantity: Double
}

/// A trade (`<pair>@trade`, as it happens).
nonisolated struct BinanceTrade: Equatable, Sendable {
    var symbol: String
    var eventTime: Int64
    var tradeID: Int64
    var price: Double
    var quantity: Double
    var tradeTime: Int64
    /// The buyer placed the resting order: the taker sold.
    var buyerIsMaker: Bool
}

/// Changes of a pair's order book (`<pair>@depth@100ms`): the levels whose quantity changed
/// (0: gone), for update IDs `firstID...lastID`.
nonisolated struct BinanceDepth: Equatable, Sendable {
    struct Level: Equatable, Sendable {
        var price: Double
        var quantity: Double
    }

    var symbol: String
    var eventTime: Int64
    var firstID: Int64
    var lastID: Int64
    var bids: [Level]
    var asks: [Level]
}

nonisolated enum BinanceMessage: Equatable, Sendable {
    case tickers([BinanceTicker])
    case book(BinanceBook)
    case trade(BinanceTrade)
    case depth(BinanceDepth)
    /// The answer to a request (`SUBSCRIBE`), by its id.
    case reply(id: Int)
    case error(String)
    /// The connection closed or failed.
    case closed(String)

    /// When Binance sent it (µs since 1970), for its latency; `nil` for a book ticker.
    var eventTime: Int64? {
        switch self {
        case .tickers(let tickers): tickers.first?.eventTime
        case .trade(let trade): trade.eventTime
        case .depth(let depth): depth.eventTime
        default: nil
        }
    }
}

nonisolated enum BinanceDecodingError: Error {
    case unknownStream(String)
    case dataBeforeStream
}

/// Reads the frames of a stream connection.
nonisolated enum BinanceDecoder {
    static func decode(_ data: Data) throws -> BinanceMessage? {
        try data.withUnsafeBytes { raw in
            var reader = FeedJSONReader(raw.bindMemory(to: UInt8.self))
            return try decode(&reader)
        }
    }

    private static func decode(_ reader: inout FeedJSONReader) throws -> BinanceMessage? {
        var stream: String?
        var message: BinanceMessage?
        var id: Int?
        var hasResult = false
        var error: String?
        try reader.readObject { reader, key in
            switch key {
            case "stream": stream = try reader.readString()
            case "data":
                // Binance writes the stream's name first.
                guard let stream else { throw BinanceDecodingError.dataBeforeStream }
                message = try data(of: stream, &reader)
            case "result": hasResult = true; try reader.skipValue()
            case "id": id = Int(try reader.readNumber())
            case "code": error = (error ?? "") + "код \(Int(try reader.readNumber())) "
            case "msg": error = (error ?? "") + (try reader.readString())
            case "error":
                try reader.readObject { reader, key in
                    switch key {
                    case "code": error = (error ?? "") + "код \(Int(try reader.readNumber())) "
                    case "msg": error = (error ?? "") + (try reader.readString())
                    default: try reader.skipValue()
                    }
                }
            default: try reader.skipValue()
            }
        }
        if let message { return message }
        if let error { return .error(error) }
        if hasResult, let id { return .reply(id: id) }
        return nil
    }

    private static func data(of stream: String, _ reader: inout FeedJSONReader) throws -> BinanceMessage {
        if stream.hasPrefix("!ticker") {
            var tickers: [BinanceTicker] = []
            try reader.readArray { reader in tickers.append(try ticker(&reader)) }
            return .tickers(tickers)
        }
        if stream.hasSuffix("@bookTicker") { return .book(try book(&reader)) }
        if stream.hasSuffix("@trade") { return .trade(try trade(&reader)) }
        if stream.contains("@depth") { return .depth(try depth(&reader)) }
        throw BinanceDecodingError.unknownStream(stream)
    }

    private static func ticker(_ reader: inout FeedJSONReader) throws -> BinanceTicker {
        var ticker = BinanceTicker(symbol: "", eventTime: 0, last: .nan, open: .nan, high: .nan, low: .nan, volume: .nan,
                                   quoteVolume: .nan, changePercent: .nan, trades: .nan)
        try reader.readObject { reader, key in
            switch key {
            case "s": ticker.symbol = try reader.readString()
            case "E": ticker.eventTime = Int64(try reader.readNumber())
            case "c": ticker.last = try reader.readQuotedNumber()
            case "o": ticker.open = try reader.readQuotedNumber()
            case "h": ticker.high = try reader.readQuotedNumber()
            case "l": ticker.low = try reader.readQuotedNumber()
            case "v": ticker.volume = try reader.readQuotedNumber()
            case "q": ticker.quoteVolume = try reader.readQuotedNumber()
            case "P": ticker.changePercent = try reader.readQuotedNumber()
            case "n": ticker.trades = try reader.readNumber()
            default: try reader.skipValue()
            }
        }
        return ticker
    }

    private static func book(_ reader: inout FeedJSONReader) throws -> BinanceBook {
        var book = BinanceBook(symbol: "", updateID: 0, bid: .nan, bidQuantity: .nan, ask: .nan, askQuantity: .nan)
        try reader.readObject { reader, key in
            switch key {
            case "s": book.symbol = try reader.readString()
            case "u": book.updateID = Int64(try reader.readNumber())
            case "b": book.bid = try reader.readQuotedNumber()
            case "B": book.bidQuantity = try reader.readQuotedNumber()
            case "a": book.ask = try reader.readQuotedNumber()
            case "A": book.askQuantity = try reader.readQuotedNumber()
            default: try reader.skipValue()
            }
        }
        return book
    }

    private static func trade(_ reader: inout FeedJSONReader) throws -> BinanceTrade {
        var trade = BinanceTrade(symbol: "", eventTime: 0, tradeID: 0, price: .nan, quantity: .nan, tradeTime: 0, buyerIsMaker: false)
        try reader.readObject { reader, key in
            switch key {
            case "s": trade.symbol = try reader.readString()
            case "E": trade.eventTime = Int64(try reader.readNumber())
            case "t": trade.tradeID = Int64(try reader.readNumber())
            case "p": trade.price = try reader.readQuotedNumber()
            case "q": trade.quantity = try reader.readQuotedNumber()
            case "T": trade.tradeTime = Int64(try reader.readNumber())
            case "m": trade.buyerIsMaker = try reader.readBool()
            default: try reader.skipValue()
            }
        }
        return trade
    }

    private static func depth(_ reader: inout FeedJSONReader) throws -> BinanceDepth {
        var depth = BinanceDepth(symbol: "", eventTime: 0, firstID: 0, lastID: 0, bids: [], asks: [])
        try reader.readObject { reader, key in
            switch key {
            case "s": depth.symbol = try reader.readString()
            case "E": depth.eventTime = Int64(try reader.readNumber())
            case "U": depth.firstID = Int64(try reader.readNumber())
            case "u": depth.lastID = Int64(try reader.readNumber())
            case "b": depth.bids = try levels(&reader)
            case "a": depth.asks = try levels(&reader)
            default: try reader.skipValue()
            }
        }
        return depth
    }

    /// `[["price", "quantity"], …]`.
    static func levels(_ reader: inout FeedJSONReader) throws -> [BinanceDepth.Level] {
        var levels: [BinanceDepth.Level] = []
        try reader.readArray { reader in
            var pair: [Double] = []
            try reader.readArray { reader in pair.append(try reader.readQuotedNumber()) }
            guard pair.count >= 2 else { throw FeedJSONReader.Malformed(position: reader.position) }
            levels.append(.init(price: pair[0], quantity: pair[1]))
        }
        return levels
    }

    /// A REST order book snapshot (`/api/v3/depth`): its last update ID and levels.
    static func snapshot(_ data: Data) throws -> (lastUpdateID: Int64, bids: [BinanceDepth.Level], asks: [BinanceDepth.Level]) {
        try data.withUnsafeBytes { raw in
            var reader = FeedJSONReader(raw.bindMemory(to: UInt8.self))
            var result: (lastUpdateID: Int64, bids: [BinanceDepth.Level], asks: [BinanceDepth.Level]) = (0, [], [])
            try reader.readObject { reader, key in
                switch key {
                case "lastUpdateId": result.lastUpdateID = Int64(try reader.readNumber())
                case "bids": result.bids = try levels(&reader)
                case "asks": result.asks = try levels(&reader)
                default: try reader.skipValue()
                }
            }
            return result
        }
    }

    /// Every pair's best bid and ask from REST (`/api/v3/ticker/bookTicker`): the book stream
    /// tells only changes, and quiet pairs change rarely.
    static func bookTickers(_ data: Data) throws -> [BinanceBook] {
        try data.withUnsafeBytes { raw in
            var reader = FeedJSONReader(raw.bindMemory(to: UInt8.self))
            var books: [BinanceBook] = []
            try reader.readArray { reader in
                var book = BinanceBook(symbol: "", updateID: 0, bid: .nan, bidQuantity: .nan, ask: .nan, askQuantity: .nan)
                try reader.readObject { reader, key in
                    switch key {
                    case "symbol": book.symbol = try reader.readString()
                    case "bidPrice": book.bid = try reader.readQuotedNumber()
                    case "bidQty": book.bidQuantity = try reader.readQuotedNumber()
                    case "askPrice": book.ask = try reader.readQuotedNumber()
                    case "askQty": book.askQuantity = try reader.readQuotedNumber()
                    default: try reader.skipValue()
                    }
                }
                books.append(book)
            }
            return books
        }
    }

    /// Every pair's 24-hour statistics from REST (`/api/v3/ticker/24hr?type=MINI`), traded pairs
    /// only: the rows the ticker streams then change.
    static func miniTickers(_ data: Data) throws -> [BinanceTicker] {
        try data.withUnsafeBytes { raw in
            var reader = FeedJSONReader(raw.bindMemory(to: UInt8.self))
            var tickers: [BinanceTicker] = []
            try reader.readArray { reader in
                var ticker = BinanceTicker(symbol: "", eventTime: 0, last: .nan, open: .nan, high: .nan, low: .nan, volume: .nan,
                                           quoteVolume: .nan, changePercent: .nan, trades: 0)
                try reader.readObject { reader, key in
                    switch key {
                    case "symbol": ticker.symbol = try reader.readString()
                    case "lastPrice": ticker.last = try reader.readQuotedNumber()
                    case "openPrice": ticker.open = try reader.readQuotedNumber()
                    case "highPrice": ticker.high = try reader.readQuotedNumber()
                    case "lowPrice": ticker.low = try reader.readQuotedNumber()
                    case "volume": ticker.volume = try reader.readQuotedNumber()
                    case "quoteVolume": ticker.quoteVolume = try reader.readQuotedNumber()
                    case "closeTime": ticker.eventTime = Int64(try reader.readNumber()) * 1_000
                    case "count": ticker.trades = try reader.readNumber()
                    default: try reader.skipValue()
                    }
                }
                guard ticker.trades > 0 else { return }
                ticker.changePercent = ticker.open > 0 ? (ticker.last - ticker.open) / ticker.open * 100 : .nan
                tickers.append(ticker)
            }
            return tickers
        }
    }
}
