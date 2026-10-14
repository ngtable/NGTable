import Foundation
import os

// The table's sort, without the table: the rows' sort values per descriptor
// (`NGSortKeys`), a stable sort of them on all cores (numbers by radix, text
// by collation keys when an app provides them), and a cancellation the
// workers look at. `NGSorting` sorts an app's rows with it, and the table its
// own (`sortsRows`).

/// The sort values of every data source row, per descriptor key, by row
/// handle (`rowCount` is the capacity of handles).
struct NGSortKeys {
    let keys: [String]
    var ascending: [Bool]
    /// How each descriptor compares text (its selector).
    let comparisons: [NGTextComparison]
    /// For a descriptor whose values are all numbers (or empty): their order
    /// as `sortsBefore` has it (empty and NaN first) in plain
    /// arrays, compared and moved without copying cell values (comparing is
    /// most of what a live sort does, and a batch moves every row's key).
    private(set) var numbers: [(ranks: [UInt8], values: [Double])?]
    /// The other descriptors' values: `cells[descriptor].values[slots[row]]`
    /// (empty for numbers). Rows move by their slots, plain integers, not by
    /// copying cell values; a changed value takes a new slot, and the values
    /// are compacted when half of them are old.
    private(set) var cells: [(values: [NGCellValue], slots: [Int32])]
    private(set) var rowCount: Int

    init(keys: [String], ascending: [Bool], comparisons: [NGTextComparison]? = nil, values: [[NGCellValue]]) {
        self.init(keys: keys, ascending: ascending, comparisons: comparisons, values: values, numbers: values.map { _ in nil },
                  rowCount: values.first?.count ?? 0)
    }

    /// - Parameter numbers: Descriptors read as numbers already (their
    ///   `values` are left out).
    init(keys: [String], ascending: [Bool], comparisons: [NGTextComparison]? = nil, values: [[NGCellValue]],
         numbers given: [(ranks: [UInt8], values: [Double])?], rowCount: Int) {
        self.keys = keys
        self.ascending = ascending
        self.comparisons = comparisons ?? keys.map { _ in .standard }
        numbers = zip(values, given).map { $1 ?? Self.numbers(of: $0) }
        cells = zip(values, numbers).map { $1 == nil ? ($0, (0..<Int32($0.count)).map { $0 }) : ([], []) }
        self.rowCount = rowCount
    }

    /// Empty (and NaN, which sorts like empty everywhere, as summaries
    /// count it) 0, numbers 1; `nil` if a value is of another kind.
    static func rank(of value: NGCellValue) -> (rank: UInt8, value: Double)? {
        switch value {
        case .empty: (0, 0)
        case .number(let number): number.isNaN ? (0, 0) : (1, number)
        default: nil
        }
    }

    private static func numbers(of values: [NGCellValue]) -> (ranks: [UInt8], values: [Double])? {
        var ranks = [UInt8](repeating: 0, count: values.count)
        var numbers = [Double](repeating: 0, count: values.count)
        for (row, value) in values.enumerated() {
            guard let ranked = rank(of: value) else { return nil }
            ranks[row] = ranked.rank
            numbers[row] = ranked.value
        }
        return (ranks, numbers)
    }

    /// Sets a row's value if it changed, and returns whether it did; a value
    /// that isn't a number turns its descriptor's numbers into cell values.
    mutating func set(_ value: NGCellValue, at index: Int, row: Int) -> Bool {
        if numbers[index] != nil {
            if let ranked = Self.rank(of: value) {
                guard numbers[index]!.ranks[row] != ranked.rank || numbers[index]!.values[row] != ranked.value else { return false }
                numbers[index]!.ranks[row] = ranked.rank
                numbers[index]!.values[row] = ranked.value
                return true
            }
            let (ranks, values) = numbers[index]!
            numbers[index] = nil
            let converted: [NGCellValue] = zip(ranks, values).map { rank, number in
                rank == 1 ? .number(number) : .empty
            }
            cells[index] = (converted, (0..<Int32(converted.count)).map { $0 })
        }
        // (NaN is empty: a NaN that stays NaN isn't a change.)
        let value = value.isNaN ? .empty : value
        let current = cells[index].values[Int(cells[index].slots[row])]
        guard (current.isNaN ? .empty : current) != value else { return false }
        if cells[index].values.count >= 2 * max(rowCount, 1024) {
            // Mostly old values: keep the current ones only.
            let (values, slots) = cells[index]
            cells[index] = (slots.map { values[Int($0)] }, (0..<Int32(slots.count)).map { $0 })
        }
        cells[index].slots[row] = Int32(cells[index].values.count)
        cells[index].values.append(value)
        return true
    }

    /// Whether a descriptor's values are all numbers (see `setNumbers`).
    func isNumeric(_ index: Int) -> Bool { numbers[index] != nil }

    /// Sets the numbers of rows (`handles`; NaN for empty) of a numeric
    /// descriptor at once, marking `changed[i]` for those that changed: in
    /// place, without copying the descriptor's arrays per row.
    mutating func setNumbers(at index: Int, handles: [Int], _ values: UnsafeBufferPointer<Double>, changed: inout [Bool]) {
        guard var column = numbers[index] else { return }
        // Taken out, so the arrays are written in place, not copied.
        numbers[index] = nil
        column.ranks.withUnsafeMutableBufferPointer { ranks in
            column.values.withUnsafeMutableBufferPointer { numbers in
                for position in handles.indices {
                    let handle = handles[position], value = values[position]
                    let (rank, number): (UInt8, Double) = value.isNaN ? (0, 0) : (1, value)
                    guard ranks[handle] != rank || numbers[handle] != number else { continue }
                    ranks[handle] = rank
                    numbers[handle] = number
                    changed[position] = true
                }
            }
        }
        numbers[index] = column
    }

    /// An empty value for a new row's handle (beyond the others, or reused).
    mutating func prepare(_ handle: Int) {
        let grows = handle >= rowCount
        for index in keys.indices {
            if numbers[index] != nil {
                if grows {
                    numbers[index]!.ranks.append(contentsOf: repeatElement(0, count: handle - rowCount + 1))
                    numbers[index]!.values.append(contentsOf: repeatElement(0, count: handle - rowCount + 1))
                } else {
                    numbers[index]!.ranks[handle] = 0
                    numbers[index]!.values[handle] = 0
                }
                continue
            }
            if cells[index].values.last != .empty { cells[index].values.append(.empty) }
            let empty = Int32(cells[index].values.count - 1)
            if grows {
                cells[index].slots.append(contentsOf: repeatElement(empty, count: handle - rowCount + 1))
            } else {
                cells[index].slots[handle] = empty
            }
        }
        if grows { rowCount = handle + 1 }
    }

    /// Whether row `a` comes before row `b` (handles): by the descriptors in
    /// turn, then by data source order (a stable sort, like `NGSorting`),
    /// which `order` tells.
    func comesBefore(_ a: Int, _ b: Int, order: NGRowHandles) -> Bool {
        keyOrder(a, b) ?? (order.index(of: Int32(truncatingIfNeeded: a)) < order.index(of: Int32(truncatingIfNeeded: b)))
    }

    /// `comesBefore` with text compared by a worker of `collation`.
    func comesBefore(_ a: Int, _ b: Int, order: NGRowHandles, collation: NGTextCollation?, worker: Int) -> Bool {
        keyOrder(a, b, collation: collation, worker: worker)
            ?? (order.index(of: Int32(truncatingIfNeeded: a)) < order.index(of: Int32(truncatingIfNeeded: b)))
    }

    /// Whether row `a` comes before row `b` by the descriptors, `nil` if
    /// their values are the same.
    func keyOrder(_ a: Int, _ b: Int) -> Bool? {
        keyOrder(a, b, collation: nil, worker: 0)
    }

    func keyOrder(_ a: Int, _ b: Int, collation: NGTextCollation?, worker: Int) -> Bool? {
        for index in keys.indices {
            if let numbers = numbers[index] {
                let (x, y) = (numbers.ranks[a], numbers.ranks[b])
                if x != y { return (x < y) == ascending[index] }
                let (p, q) = (numbers.values[a], numbers.values[b])
                if p != q { return (p < q) == ascending[index] }
                continue
            }
            let cells = cells[index]
            let (x, y) = (Int(cells.slots[a]), Int(cells.slots[b]))
            // The same slot is the same value (changed values take new slots).
            guard x != y else { continue }
            let order = if let collation {
                cells.values[x].sortOrder(cells.values[y], collation: collation, worker: worker, comparison: comparisons[index])
            } else {
                cells.values[x].sortOrder(cells.values[y], comparison: comparisons[index])
            }
            switch order {
            case .orderedAscending: return ascending[index]
            case .orderedDescending: return !ascending[index]
            case .orderedSame: continue
            }
        }
        return nil
    }
}

/// Tells a sort running on worker threads that no one waits for it any more.
final class NGSortCancellation: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}

/// Looks at a cancellation from comparisons on worker threads without
/// contending for it: each worker counts in a slot of its own (a cache line
/// apart) and looks every 4,096 comparisons.
final class NGSortCancellationProbe: @unchecked Sendable {
    private let cancellation: NGSortCancellation?
    private static let workers = 64, stride = 8
    private let slots: UnsafeMutablePointer<Int>

    init(_ cancellation: NGSortCancellation?) {
        self.cancellation = cancellation
        slots = .allocate(capacity: Self.workers * Self.stride)
        slots.initialize(repeating: 0, count: Self.workers * Self.stride)
    }

    deinit { slots.deallocate() }

    /// Whether the sort was cancelled, as a worker saw it last.
    func isCancelled(worker: Int) -> Bool {
        guard let cancellation else { return false }
        let slot = slots + (worker % Self.workers) * Self.stride
        slot.pointee &+= 1
        if slot.pointee & 4095 == 0 { slot[1] = cancellation.isCancelled ? 1 : 0 }
        return slot[1] != 0
    }
}

/// The rows' order by sort keys.
enum NGRowSort {
    /// Rows (handles) in order (a stable sort).
    /// - Parameter rows: Handles in data source order (equal rows keep it).
    /// - Parameter keyProvider: Collation keys for text (see `collationKeyProvider`).
    nonisolated static func sortedRows(_ rows: [Int], keys: NGSortKeys, order: NGRowHandles,
                                       keyProvider: (any NGCollationKeyProvider)?,
                                       cancellation: NGSortCancellation? = nil) -> [Int] {
        // Numbers by radix (comparisons are most of a sort).
        if rows.count >= 4096, let sorted = keys.radixSorted(rows) { return sorted }
        let cores = NGParallelism.backgroundWorkers
        // Cancelled: every comparison answers at once (the result is thrown away).
        let probe = NGSortCancellationProbe(cancellation)
        guard !keys.comparesWithoutText else {
            return NGParallelSort.sorted(rows, workers: cores) { a, b, worker in
                !probe.isCancelled(worker: worker) && keys.comesBefore(a, b, order: order)
            }
        }
        // Text: by collation keys when an app provides them (keys are
        // `localizedStandardCompare`'s order), else compared on all cores, a
        // locale object per worker.
        let collation = NGTextCollation.current
        if rows.count >= 4096, let keyProvider, cancellation?.isCancelled != true, keys.comparisons.first == .standard,
           let sorted = keys.collationSorted(rows, order: order, collation: collation, provider: keyProvider) {
            return sorted
        }
        return NGParallelSort.sorted(rows, workers: collation.workerCount) {
            !probe.isCancelled(worker: $2) && keys.comesBefore($0, $1, order: order, collation: collation, worker: $2)
        }
    }
}
