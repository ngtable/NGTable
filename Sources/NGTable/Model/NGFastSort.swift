import Foundation

// Sorting a million rows: comparing them one pair at a time through the
// descriptors (`NGSortKeys.comesBefore`) costs most of a sort. Numbers sort
// without comparisons instead, by radix over bits whose order is theirs;
// other values sort on all cores, in chunks merged pairwise.

extension NGSortKeys {
    /// Whether no descriptor compares text (or marks, media, tags): those
    /// compare through their locale's collation, which takes a lock, so
    /// sorting them on all cores is slower than on one.
    var comparesWithoutText: Bool {
        cells.allSatisfy { cell in
            cell.values.allSatisfy { value in
                switch value {
                case .text, .mark, .media, .tags: false
                default: true
                }
            }
        }
    }

    /// Rows (handles in data source order) in the order `comesBefore` gives,
    /// by radix: each descriptor from the last to the first, its numbers and
    /// then its ranks (empty, numbers, NaN), every pass stable, so equal rows
    /// stay in data source order. `nil` if a descriptor isn't all numbers.
    func radixSorted(_ rows: [Int]) -> [Int]? {
        guard !rows.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        let count = rows.count
        var order = rows
        var spareOrder = [Int](repeating: 0, count: count)
        var bits = [UInt64](repeating: 0, count: count)
        var spareBits = [UInt64](repeating: 0, count: count)
        var counts = [Int](repeating: 0, count: 1 << 16)
        for index in keys.indices.reversed() {
            guard let (ranks, values) = numbers[index] else { return nil }
            let ascending = ascending[index]
            // The numbers: bits ordered like the numbers (negative ones
            // flipped, others with the sign bit set), reversed descending.
            order.withUnsafeBufferPointer { order in
                bits.withUnsafeMutableBufferPointer { bits in
                    ranks.withUnsafeBufferPointer { ranks in
                        values.withUnsafeBufferPointer { values in
                            for position in 0..<count {
                                let handle = order[position]
                                var key: UInt64 = 0
                                if ranks[handle] == 1 {
                                    let value = values[handle] == 0 ? 0 : values[handle]   // -0 sorts as 0
                                    let pattern = value.bitPattern
                                    key = pattern & (1 << 63) != 0 ? ~pattern : pattern | (1 << 63)
                                }
                                bits[position] = ascending ? key : ~key
                            }
                        }
                    }
                }
            }
            for shift in stride(from: 0, to: 64, by: 16) {
                Self.radixPass(shift: UInt64(shift), order: &order, bits: &bits, spareOrder: &spareOrder,
                               spareBits: &spareBits, counts: &counts)
            }
            // Then the ranks, stable: empty, numbers, NaN (reversed descending).
            var rankCounts = [0, 0, 0]
            for handle in order { rankCounts[Int(ascending ? ranks[handle] : 2 - ranks[handle])] += 1 }
            var starts = [0, rankCounts[0], rankCounts[0] + rankCounts[1]]
            guard rankCounts.max() != count else { continue }
            for handle in order {
                let rank = Int(ascending ? ranks[handle] : 2 - ranks[handle])
                spareOrder[starts[rank]] = handle
                starts[rank] += 1
            }
            swap(&order, &spareOrder)
        }
        return order
    }

    /// One stable counting pass by 16 bits of the keys; skipped when they
    /// are all the same there (the high bits of similar numbers).
    private static func radixPass(shift: UInt64, order: inout [Int], bits: inout [UInt64], spareOrder: inout [Int],
                                  spareBits: inout [UInt64], counts: inout [Int]) {
        let count = order.count
        var isSame = false
        counts.withUnsafeMutableBufferPointer { counts in
            for slot in counts.indices { counts[slot] = 0 }
            bits.withUnsafeBufferPointer { bits in
                for position in 0..<count { counts[Int((bits[position] >> shift) & 0xFFFF)] += 1 }
                isSame = counts[Int((bits[0] >> shift) & 0xFFFF)] == count
            }
            guard !isSame else { return }
            var total = 0
            for slot in counts.indices {
                let slotCount = counts[slot]
                counts[slot] = total
                total += slotCount
            }
            order.withUnsafeBufferPointer { order in
                bits.withUnsafeBufferPointer { bits in
                    spareOrder.withUnsafeMutableBufferPointer { spareOrder in
                        spareBits.withUnsafeMutableBufferPointer { spareBits in
                            for position in 0..<count {
                                let digit = Int((bits[position] >> shift) & 0xFFFF)
                                let target = counts[digit]
                                counts[digit] = target + 1
                                spareOrder[target] = order[position]
                                spareBits[target] = bits[position]
                            }
                        }
                    }
                }
            }
        }
        guard !isSame else { return }
        swap(&order, &spareOrder)
        swap(&bits, &spareBits)
    }
}

enum NGParallelSort {
    /// `rows` sorted by `areInIncreasingOrder` (a strict weak order; equal
    /// rows keep their order) on `workers` threads: chunks sorted at once,
    /// then merged pairwise, each merge split among the threads by binary
    /// search (merge path), so the last rounds use them all too. The
    /// comparison gets the worker it runs on (0..<workers, one thread each).
    static func sorted(_ rows: [Int], workers: Int,
                       by areInIncreasingOrder: @escaping @Sendable (Int, Int, Int) -> Bool) -> [Int] {
        let count = rows.count
        let workers = max(1, min(workers, count / 4096))
        guard workers > 1 else { return rows.sorted { areInIncreasingOrder($0, $1, 0) } }
        var buffer = rows
        var spare = [Int](repeating: 0, count: count)
        var bounds = (0...workers).map { $0 * count / workers }
        buffer.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let buffer = buffer
            let chunks = bounds
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                var slice = UnsafeMutableBufferPointer(rebasing: buffer[chunks[worker]..<chunks[worker + 1]])
                slice.sort { areInIncreasingOrder($0, $1, worker) }
            }
        }
        while bounds.count > 2 {
            let runs = bounds
            let pairs = (runs.count) / 2
            // Each pair's merge in parts, about `workers` parts in all.
            let partsPerPair = max(1, workers / pairs)
            buffer.withUnsafeBufferPointer { source in
                spare.withUnsafeMutableBufferPointer { target in
                    nonisolated(unsafe) let source = source
                    nonisolated(unsafe) let target = target
                    let tasks = pairs * partsPerPair
                    DispatchQueue.concurrentPerform(iterations: workers) { worker in
                        for task in stride(from: worker, to: tasks, by: workers) {
                            let pair = task / partsPerPair, part = task % partsPerPair
                            let start = runs[pair * 2]
                            let middle = runs[min(pair * 2 + 1, runs.count - 1)]
                            let end = runs[min(pair * 2 + 2, runs.count - 1)]
                            mergePart(source, into: target, start: start, middle: middle, end: end,
                                      part: part, parts: partsPerPair) { areInIncreasingOrder($0, $1, worker) }
                        }
                    }
                }
            }
            swap(&buffer, &spare)
            bounds = stride(from: 0, to: runs.count, by: 2).map { runs[$0] }
            if bounds.last != count { bounds.append(count) }
        }
        return buffer
    }

    /// One part of merging `source[start..<middle]` and `source[middle..<end]`
    /// into `target[start..<end]`: the output positions of the part, and the
    /// inputs that go there found by binary search. Ties take the left run first.
    private static func mergePart(_ source: UnsafeBufferPointer<Int>, into target: UnsafeMutableBufferPointer<Int>,
                                  start: Int, middle: Int, end: Int, part: Int, parts: Int,
                                  by areInIncreasingOrder: (Int, Int) -> Bool) {
        let leftCount = middle - start, rightCount = end - middle
        let total = leftCount + rightCount
        /// How many of the left run come among the first `k` outputs.
        func coRank(_ k: Int) -> Int {
            var low = max(0, k - rightCount), high = min(k, leftCount)
            while low < high {
                let i = (low + high) / 2, j = k - i
                if j > 0, i < leftCount, !areInIncreasingOrder(source[middle + j - 1], source[start + i]) {
                    low = i + 1
                } else {
                    high = i
                }
            }
            return low
        }
        let firstOut = part * total / parts, lastOut = (part + 1) * total / parts
        guard firstOut < lastOut else { return }
        var left = start + coRank(firstOut), right = middle + (firstOut - (left - start))
        let leftEnd = start + coRank(lastOut), rightEnd = middle + (lastOut - (leftEnd - start))
        var out = start + firstOut
        while left < leftEnd, right < rightEnd {
            if areInIncreasingOrder(source[right], source[left]) {
                target[out] = source[right]
                right += 1
            } else {
                target[out] = source[left]
                left += 1
            }
            out += 1
        }
        while left < leftEnd { target[out] = source[left]; left += 1; out += 1 }
        while right < rightEnd { target[out] = source[right]; right += 1; out += 1 }
    }
}

extension NGSortKeys {
    /// Rows (handles in data source order) sorted like `comesBefore`, by the
    /// collation keys of the first descriptor's text: keys made on all cores,
    /// rows sorted by them without a lock, rows with equal keys ordered by
    /// comparing them, then every pair of neighbors checked by comparing; a
    /// pair out of order (keys that disagree with `localizedStandardCompare`)
    /// sorts again by comparing, from this order. `nil` if the first
    /// descriptor isn't text or the provider makes no keys.
    func collationSorted(_ rows: [Int], order: NGRowHandles, collation: NGTextCollation,
                         provider: any NGCollationKeyProvider) -> [Int]? {
        guard !keys.isEmpty, numbers[0] == nil else { return nil }
        let values = cells[0].values, slots = cells[0].slots
        // Text (and empty values) only: other kinds sort by kind first.
        guard values.allSatisfy({ value in
            switch value {
            case .empty, .text, .mark, .media, .tags: true
            default: false
            }
        }) else { return nil }
        let workers = collation.workerCount
        let makers = (0..<workers).map { _ in provider.makeKeyMaker(collatorIdentifier: collation.collatorIdentifier) }
        guard makers.allSatisfy({ $0 != nil }) else { return nil }
        guard let table = NGCollationKeyTable(values: values, makers: makers.compactMap { $0 }) else { return nil }
        let ascending = ascending[0]

        // Sorted by the keys (equal keys keep data source order).
        var sorted = table.bytes.withUnsafeBufferPointer { bytes in
            nonisolated(unsafe) let bytes = bytes
            return NGParallelSort.sorted(rows, workers: workers) { a, b, _ in
                let (x, y) = (Int(slots[a]), Int(slots[b]))
                guard x != y else { return false }
                let order = table.compare(x, y, bytes: bytes)
                return ascending ? order < 0 : order > 0
            }
        }
        // Rows with equal keys (case, accents, equal texts) by comparing them,
        // the runs spread over the workers.
        var runs: [Range<Int>] = []
        table.bytes.withUnsafeBufferPointer { bytes in
            var start = 0
            for index in 1...sorted.count {
                if index < sorted.count {
                    let (x, y) = (Int(slots[sorted[index - 1]]), Int(slots[sorted[index]]))
                    if x == y || table.compare(x, y, bytes: bytes) == 0 { continue }
                }
                if index - start > 1 { runs.append(start..<index) }
                start = index
            }
        }
        sorted.withUnsafeMutableBufferPointer { sorted in
            nonisolated(unsafe) let sorted = sorted
            let runs = runs
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                for index in stride(from: worker, to: runs.count, by: workers) {
                    var run = UnsafeMutableBufferPointer(rebasing: sorted[runs[index]])
                    run.sort { comesBefore($0, $1, order: order, collation: collation, worker: worker) }
                }
            }
        }
        // Every pair of neighbors in order: the order is the comparison's.
        let inOrder = sorted.withUnsafeBufferPointer { sorted in
            nonisolated(unsafe) let sorted = sorted
            // Each worker its own stretch and result (a shared flag's lock
            // cost more than the comparisons).
            var results = [Bool](repeating: true, count: workers)
            results.withUnsafeMutableBufferPointer { results in
                nonisolated(unsafe) let results = results
                let count = sorted.count
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let start = worker * (count - 1) / workers, end = (worker + 1) * (count - 1) / workers
                    for index in start..<end
                        where comesBefore(sorted[index + 1], sorted[index], order: order, collation: collation, worker: worker) {
                        results[worker] = false
                        return
                    }
                }
            }
            return !results.contains(false)
        }
        guard !inOrder else { return sorted }
        // Keys that disagree: sorted by comparing, on all cores, from the keys' order.
        return NGParallelSort.sorted(sorted, workers: workers) { comesBefore($0, $1, order: order, collation: collation, worker: $2) }
    }
}

/// The collation keys of a descriptor's values, by value index: one arena of
/// bytes, each key's range in it, and its first 8 bytes as a number for a
/// quick first comparison.
struct NGCollationKeyTable: @unchecked Sendable {
    let bytes: [UInt8]
    let starts: [Int]
    let lengths: [Int32]
    let prefixes: [UInt64]

    /// Keys made on as many threads as `makers`, each with its own maker.
    init?(values: [NGCellValue], makers: [any NGCollationKeyMaker]) {
        let count = values.count
        let workers = makers.count
        guard count > 0, workers > 0 else { return nil }
        nonisolated(unsafe) let makers = makers
        var arenas = [[UInt8]](repeating: [], count: workers)
        var localStarts = [Int](repeating: 0, count: count)
        var lengths = [Int32](repeating: 0, count: count)
        var prefixes = [UInt64](repeating: 0, count: count)
        arenas.withUnsafeMutableBufferPointer { arenas in
            localStarts.withUnsafeMutableBufferPointer { localStarts in
                lengths.withUnsafeMutableBufferPointer { lengths in
                    prefixes.withUnsafeMutableBufferPointer { prefixes in
                        nonisolated(unsafe) let arenas = arenas
                        nonisolated(unsafe) let localStarts = localStarts
                        nonisolated(unsafe) let lengths = lengths
                        nonisolated(unsafe) let prefixes = prefixes
                        DispatchQueue.concurrentPerform(iterations: workers) { worker in
                            let maker = makers[worker]
                            var arena: [UInt8] = []
                            arena.reserveCapacity((count / workers + 1) * 24)
                            var key: [UInt8] = []
                            var utf16: [UInt16] = []
                            for index in (worker * count / workers)..<((worker + 1) * count / workers) {
                                key.removeAll(keepingCapacity: true)
                                if let text = values[index].sortText, !text.isEmpty {
                                    utf16.removeAll(keepingCapacity: true)
                                    utf16.append(contentsOf: text.utf16)
                                    utf16.withUnsafeBufferPointer { maker.makeKey(of: $0, into: &key) }
                                }
                                localStarts[index] = arena.count
                                lengths[index] = Int32(key.count)
                                var prefix: UInt64 = 0
                                for byte in key.prefix(8) { prefix = prefix << 8 | UInt64(byte) }
                                prefixes[index] = prefix << (8 * UInt64(8 - min(8, key.count)))
                                arena.append(contentsOf: key)
                            }
                            arenas[worker] = arena
                        }
                    }
                }
            }
        }
        // One arena: each worker's keys after the previous ones'.
        var offsets = [Int](repeating: 0, count: workers)
        for worker in 1..<max(1, workers) { offsets[worker] = offsets[worker - 1] + arenas[worker - 1].count }
        for worker in 0..<workers {
            for index in (worker * count / workers)..<((worker + 1) * count / workers) { localStarts[index] += offsets[worker] }
        }
        bytes = arenas.flatMap { $0 }
        starts = localStarts
        self.lengths = lengths
        self.prefixes = prefixes
    }

    /// The order of two keys: negative, zero or positive.
    func compare(_ x: Int, _ y: Int, bytes: UnsafeBufferPointer<UInt8>) -> Int {
        let (p, q) = (prefixes[x], prefixes[y])
        if p != q { return p < q ? -1 : 1 }
        let (m, n) = (Int(lengths[x]), Int(lengths[y]))
        if m > 8, n > 8, let base = bytes.baseAddress {
            let result = memcmp(base + starts[x] + 8, base + starts[y] + 8, min(m, n) - 8)
            if result != 0 { return Int(result) }
        }
        return m == n ? 0 : (m < n ? -1 : 1)
    }
}
