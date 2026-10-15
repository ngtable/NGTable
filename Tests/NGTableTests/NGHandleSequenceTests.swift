import Foundation
import Testing
@testable import NGTable

/// Blocked orders of handles against arrays changed element by element.
@Suite("Handle sequences")
struct NGHandleSequenceTests {
    private func expectMatches(_ sequence: NGHandleSequence, _ reference: [Int32], _ context: String) {
        #expect(sequence.count == reference.count, "\(context): count")
        #expect(sequence.elements == reference, "\(context): order")
        #expect(sequence.integerElements == reference.map(Int.init), "\(context): integers")
        for (index, handle) in reference.enumerated() {
            #expect(sequence.handle(at: index) == handle, "\(context): handle at \(index)")
            #expect(sequence.index(of: handle) == index, "\(context): index of \(handle)")
        }
        // Handles at ranges of positions, across blocks and empty slots.
        var generator = SplitMix64(seed: UInt64(reference.count))
        for _ in 0..<5 where !reference.isEmpty {
            var positions = IndexSet()
            for _ in 0..<4 {
                let start = Int(generator.next() % UInt64(reference.count))
                positions.insert(integersIn: start..<min(reference.count, start + Int(generator.next() % 700) + 1))
            }
            #expect(sequence.handles(at: positions) == positions.map { reference[$0] }, "\(context): handles at \(positions)")
        }
    }

    /// One stretch emptied and filled again and again: empty slots taken from
    /// either side, blocks made dense, split and freed.
    @Test func holesFilledFromBothSides() {
        var generator = SplitMix64(seed: 21)
        var reference = (0..<3_000).map { Int32($0) }
        var sequence = NGHandleSequence(reference.map(Int.init), capacity: 20_000, maximumBlock: 64)
        var next: Int32 = 3_000
        for round in 0..<6_000 {
            let center = 1_500 + Int(generator.next() % 200) - 100
            if generator.next() % 2 == 0 || reference.count < 2_000 {
                let at = min(reference.count, center + Int(generator.next() % 9))
                sequence.insert(next, at: at)
                reference.insert(next, at: at)
                next += 1
            } else {
                let at = min(reference.count - 1, center + Int(generator.next() % 9))
                #expect(sequence.remove(at: at) == reference.remove(at: at), "round \(round)")
            }
            if round % 1_000 == 0 { expectMatches(sequence, reference, "round \(round)") }
        }
        expectMatches(sequence, reference, "end")
        let positions = Dictionary(uniqueKeysWithValues: reference.enumerated().map { ($1, $0) })
        for cut in [0, 700, 1_499, reference.count] {
            #expect(sequence.partitioningIndex { positions[$0]! >= cut } == cut, "cut \(cut)")
        }
    }

    /// Handles at ascending positions found in one walk over the blocks:
    /// those `handle(at:)` finds, across blocks of every length.
    @Test(arguments: [4, 64, 512])
    func handlesAtAscendingPositions(_ block: Int) {
        var generator = SplitMix64(seed: UInt64(block))
        var reference = (0..<3_000).map { Int32($0) }
        var sequence = NGHandleSequence(reference.map(Int.init), capacity: 10_000, maximumBlock: block)
        var next: Int32 = 3_000
        for _ in 0..<2_000 {
            let at = Int(generator.next() % UInt64(reference.count))
            if generator.next() % 2 == 0 {
                sequence.insert(next, at: at)
                reference.insert(next, at: at)
                next += 1
            } else {
                sequence.remove(at: at)
                reference.remove(at: at)
            }
        }
        var positions = (0..<700).map { _ in Int32(generator.next() % UInt64(reference.count)) }
        positions += [0, Int32(reference.count - 1), 5, 5]
        positions.sort()
        var found: [Int32] = [-9]
        sequence.appendHandles(atAscending: positions, to: &found)
        #expect(found == [-9] + positions.map { reference[Int($0)] })
    }

    /// Removes that put the last handle in the removed one's place, mixed
    /// with inserts, across emptied blocks: the same as an array's.
    @Test(arguments: [64, 4])
    func removesReplacingWithLastMatchAnArray(_ block: Int) {
        var generator = SplitMix64(seed: UInt64(block))
        var reference = (0..<2_000).map { Int32($0) }
        var sequence = NGHandleSequence(reference.map(Int.init), capacity: 20_000, maximumBlock: block)
        var next: Int32 = 2_000
        for round in 0..<8_000 {
            if generator.next() % 3 == 0 || reference.isEmpty {
                let at = Int(generator.next() % UInt64(reference.count + 1))
                sequence.insert(next, at: at)
                reference.insert(next, at: at)
                next += 1
            } else {
                let at = Int(generator.next() % UInt64(reference.count))
                let removed = reference[at]
                reference[at] = reference[reference.count - 1]
                reference.removeLast()
                #expect(sequence.replaceWithLast(at: at) == removed, "round \(round)")
            }
            if round % 500 == 0 { expectMatches(sequence, reference, "round \(round)") }
        }
        expectMatches(sequence, reference, "end")
        while !reference.isEmpty {
            reference[0] = reference[reference.count - 1]
            reference.removeLast()
            sequence.replaceWithLast(at: 0)
        }
        expectMatches(sequence, reference, "emptied")
    }

    /// Inserts, removes and moves, across block splits; positions found by
    /// `partitioningIndex` are those of a linear search.
    @Test(arguments: [(0, 512), (5, 512), (5000, 512), (5000, 8), (300, 4)])
    func randomChangesMatchAnArray(_ start: Int, _ block: Int) {
        var generator = SplitMix64(seed: UInt64(start + block + 11))
        let capacity = start + 12_000
        var reference = (0..<start).map { Int32($0) }.shuffled(using: &generator)
        var sequence = NGHandleSequence(reference.map(Int.init), capacity: capacity, maximumBlock: block)
        var absent = Array(Int32(start)..<Int32(capacity)).shuffled(using: &generator)
        expectMatches(sequence, reference, "start")
        for round in 0..<9000 {
            switch generator.next() % 4 {
            case 0 where !absent.isEmpty, 1 where !absent.isEmpty:
                let index = Int(generator.next() % UInt64(reference.count + 1))
                let handle = absent.removeLast()
                sequence.insert(handle, at: index)
                reference.insert(handle, at: index)
            case 2 where !reference.isEmpty:
                let handle = reference[Int(generator.next() % UInt64(reference.count))]
                let removed = sequence.remove(handle)
                #expect(removed, "round \(round)")
                reference.removeAll { $0 == handle }
                absent.append(handle)
                #expect(!sequence.contains(handle))
            case 3 where reference.count > 1:
                let from = Int(generator.next() % UInt64(reference.count)), to = Int(generator.next() % UInt64(reference.count))
                sequence.move(from: from, to: to)
                reference.insert(reference.remove(at: from), at: to)
            default:
                break
            }
            if round % 1500 == 0 { expectMatches(sequence, reference, "round \(round)") }
        }
        expectMatches(sequence, reference, "end")
        // A monotone predicate over positions: the first position at or after a cut.
        for cut in [0, 1, reference.count / 3, reference.count - 1, reference.count] where cut >= 0 {
            let positions = Dictionary(uniqueKeysWithValues: reference.enumerated().map { ($1, $0) })
            #expect(sequence.partitioningIndex { positions[$0]! >= cut } == cut, "cut \(cut)")
        }
        if let handle = absent.last {
            let removed = sequence.remove(handle)
            #expect(!removed, "a handle not in it")
        }
    }

    @Test func emptiedSequenceTakesHandlesAgain() {
        var sequence = NGHandleSequence([3, 1], capacity: 4)
        sequence.remove(at: 0)
        sequence.remove(at: 0)
        #expect(sequence.count == 0)
        #expect(sequence.partitioningIndex { _ in true } == 0)
        sequence.insert(2, at: 0)
        sequence.insert(0, at: 1)
        #expect(sequence.elements == [2, 0])
    }

    /// A feed inserting at the end and removing at the start reuses the
    /// blocks it empties instead of adding blocks forever.
    @Test func fifoFeedsReuseTheirBlocks() {
        var sequence = NGHandleSequence(0..<1_000, capacity: 200_000, maximumBlock: 64)
        var next: Int32 = 1_000
        for _ in 0..<100_000 {
            sequence.insert(next, at: sequence.count)
            next += 1
            sequence.remove(at: 0)
        }
        #expect(sequence.count == 1_000)
        #expect(sequence.blockCountForTesting < 100)
        #expect(sequence.elements == Array(next - 1_000..<next))
    }
}
