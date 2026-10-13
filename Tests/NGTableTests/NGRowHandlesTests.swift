import Foundation
import Testing
@testable import NGTable

/// The table's row handles against an array of them moved row by row.
@Suite("Row handles")
struct NGRowHandlesTests {
    private func expectMatches(_ handles: NGRowHandles, _ reference: [Int32], _ context: String) {
        #expect(handles.count == reference.count, "\(context): count")
        #expect(handles.handles == reference, "\(context): order")
        for (index, handle) in reference.enumerated() {
            #expect(handles.handle(at: index) == handle, "\(context): handle at \(index)")
            #expect(handles.index(of: handle) == index, "\(context): index of \(handle)")
        }
    }

    @Test(arguments: [0, 1, 7, 3000, 10_000])
    func randomChangesMatchAnArray(_ start: Int) {
        var generator = SplitMix64(seed: UInt64(start + 3))
        var handles = NGRowHandles(count: start)
        var reference = (0..<start).map { Int32($0) }
        var removedSinceRelease = Set<Int32>()
        for round in 0..<600 {
            switch generator.next() % 5 {
            case 0, 1:
                let index = Int(generator.next() % UInt64(reference.count + 1))
                let handle = handles.insert(at: index)
                #expect(!reference.contains(handle) && !removedSinceRelease.contains(handle), "round \(round): fresh handle")
                reference.insert(handle, at: index)
            case 2 where !reference.isEmpty:
                let index = Int(generator.next() % UInt64(reference.count))
                let handle = handles.remove(at: index)
                #expect(handle == reference.remove(at: index), "round \(round): removed handle")
                #expect(handles.index(of: handle) == -1)
                removedSinceRelease.insert(handle)
            case 3 where reference.count > 1:
                let from = Int(generator.next() % UInt64(reference.count)), to = Int(generator.next() % UInt64(reference.count))
                handles.move(from: from, to: to)
                reference.insert(reference.remove(at: from), at: to)
            default:
                #expect(Set(handles.releaseRemoved()) == removedSinceRelease)
                removedSinceRelease = []
            }
            if round % 50 == 0 || reference.count < 50 { expectMatches(handles, reference, "round \(round)") }
            #expect(handles.capacity >= reference.count)
        }
        expectMatches(handles, reference, "end")
        // Some rows by ranges.
        var rows = IndexSet()
        for _ in 0..<20 where !reference.isEmpty { rows.insert(Int(generator.next() % UInt64(reference.count))) }
        #expect(handles.handles(of: rows) == rows.map { reference[$0] })
        #expect(handles.indexes(of: handles.handles(of: rows)) == rows)
    }

    @Test func blocksSplitUnderManyInsertsInOnePlace() {
        var handles = NGRowHandles(count: 10)
        var reference = (0..<10).map { Int32($0) }
        for _ in 0..<5_000 {
            reference.insert(handles.insert(at: 5), at: 5)
        }
        expectMatches(handles, reference, "inserts at 5")
        for _ in 0..<4_990 { reference.remove(at: 3); handles.remove(at: 3) }
        expectMatches(handles, reference, "removes at 3")
    }

    @Test func replacingTheOrderKeepsHandlesAndAddsRows() {
        var handles = NGRowHandles(count: 6)
        handles.remove(at: 1)   // Handle 1 goes.
        _ = handles.releaseRemoved()
        // Rows 5, 0, a new one, 3 (2 and 4 go).
        let added = handles.replaceOrder(with: [5, 0, -1, 3])
        #expect(added.count == 1)
        expectMatches(handles, [5, 0, added[0], 3], "replaced")
        #expect(Set(handles.removedHandles) == [2, 4])
        #expect(handles.index(of: 2) == -1)
    }

    /// Rows removed before a remapping in the same batch stay removed (and
    /// are reused after the release) with the ones it drops.
    @Test func replacingTheOrderKeepsEarlierRemoves() {
        var handles = NGRowHandles(count: 4)
        handles.remove(at: 0)   // Handle 0 goes.
        _ = handles.replaceOrder(with: [3, 1])   // Handle 2 goes too.
        #expect(Set(handles.removedHandles) == [0, 2])
        #expect(Set(handles.releaseRemoved()) == [0, 2])
        #expect(Set([handles.insert(at: 0), handles.insert(at: 0)]) == [0, 2])
        #expect(handles.capacity == 4)
    }
}
