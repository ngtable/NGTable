import Foundation
import Observation

// The rows every engine shows: a name and six numbers each, some changing
// every frame (a feed). Each row is an observable object, so SwiftUI
// redraws only the rows that changed (its best case); the UIKit engines and
// NGTable read the same objects and are told which rows changed.

@Observable
final class BenchRow: Identifiable {
    let id: Int
    let name: String
    var values: [Double]

    init(id: Int, name: String, values: [Double]) {
        self.id = id
        self.name = name
        self.values = values
    }
}

@MainActor
final class BenchData {
    static let columnTitles = ["Clicks", "Views", "Spend", "Revenue", "Profit", "ROI"]
    private(set) var rows: [BenchRow] = []
    private var generator = SplitMix(seed: 7)

    /// New rows (the old ones are dropped).
    func make(count: Int) {
        var generator = SplitMix(seed: UInt64(count))
        rows = (0..<count).map { index in
            let spend = Double(generator.next() % 500_000) / 100
            let revenue = spend * (0.5 + Double(generator.next() % 170) / 100)
            return BenchRow(id: index, name: "Campaign \(index + 1)",
                            values: [Double(generator.next() % 50_000), Double(generator.next() % 900_000), spend, revenue,
                                     revenue - spend, spend > 0 ? (revenue - spend) / spend : 0])
        }
    }

    /// Changes `count` random rows' spend (and what follows from it); returns the rows changed.
    func tick(changing count: Int) -> [Int] {
        guard !rows.isEmpty, count > 0 else { return [] }
        var changed: [Int] = []
        changed.reserveCapacity(count)
        for _ in 0..<count {
            let index = Int(generator.next() % UInt64(rows.count))
            let row = rows[index]
            var values = row.values
            values[2] += Double(generator.next() % 500) / 100
            values[4] = values[3] - values[2]
            values[5] = values[2] > 0 ? values[4] / values[2] : 0
            row.values = values
            changed.append(index)
        }
        return changed
    }

    /// How the numbers show in the UIKit and SwiftUI engines (NGTable formats its own).
    static func text(_ value: Double, column: Int) -> String {
        switch column {
        case 2, 3, 4: currency.string(from: NSNumber(value: value)) ?? ""
        case 5: percent.string(from: NSNumber(value: value)) ?? ""
        default: integer.string(from: NSNumber(value: value)) ?? ""
        }
    }

    private static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter
    }()

    private static let percent: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

/// A small deterministic random number generator.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
