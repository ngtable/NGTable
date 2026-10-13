import Foundation

// The live data every table shows: trades of a few dozen pairs, a share of
// them changing each 1/60 s (price, quantity, amount, change, updates). The
// tables read it from here; only SwiftUI's needs a copy of its own (rows of
// an observable model), kept by its engine.

final class Feed {
    static let pairs = ["BTC/USDT", "ETH/USDT", "SOL/USDT", "BNB/USDT", "XRP/USDT", "DOGE/USDT", "ADA/USDT", "TRX/USDT",
                        "AVAX/USDT", "LINK/USDT", "DOT/USDT", "TON/USDT", "MATIC/USDT", "LTC/USDT", "BCH/USDT", "NEAR/USDT",
                        "UNI/USDT", "APT/USDT", "ARB/USDT", "OP/USDT", "ATOM/USDT", "FIL/USDT", "ETC/USDT", "XLM/USDT",
                        "ETH/BTC", "SOL/BTC", "BNB/BTC", "XRP/BTC", "SUI/USDT", "PEPE/USDT", "INJ/USDT", "SEI/USDT"]

    let count: Int
    let changesPerTick: Int
    /// The tables show the rows sorted by amount.
    let isSorted: Bool
    private(set) var pair: [Int]
    private(set) var isSell: [Bool]
    private(set) var price: [Double]
    private(set) var quantity: [Double]
    private(set) var open: [Double]
    private(set) var updates: [Int]
    /// Rows changed by the last tick (each once).
    private(set) var changed: [Int] = []
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    init(count: Int, changesPerSecond: Int, isSorted: Bool) {
        self.count = count
        self.isSorted = isSorted
        changesPerTick = changesPerSecond / 60
        pair = []; isSell = []; price = []; quantity = []; open = []; updates = []
        for row in 0..<count {
            let p = Int(next() % UInt64(Self.pairs.count))
            pair.append(p)
            isSell.append(next() % 2 == 0)
            let base = 10 + Double(p * 37 % 900) * (1 + Double(row % 7) / 10)
            price.append(base)
            open.append(base)
            quantity.append(Double(next() % 100_000) / 100)
            updates.append(0)
        }
    }

    func amount(_ row: Int) -> Double { price[row] * quantity[row] }
    func change(_ row: Int) -> Double { (price[row] / open[row] - 1) * 100 }

    /// One 1/60 s of changes.
    func tick() {
        var seen = Set<Int>(minimumCapacity: changesPerTick)
        changed.removeAll(keepingCapacity: true)
        for _ in 0..<changesPerTick {
            let row = Int(next() % UInt64(count))
            let step = Double(Int(next() % 2001) - 1000) / 100_000
            price[row] = max(0.01, price[row] * (1 + step))
            quantity[row] = Double(next() % 100_000) / 100
            updates[row] += 1
            if seen.insert(row).inserted { changed.append(row) }
        }
    }

    private func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
}
