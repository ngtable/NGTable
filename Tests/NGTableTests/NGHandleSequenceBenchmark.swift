import Foundation
import Testing
@testable import NGTable

// Handle sequence benchmark: the order of rows by itself, changed at random places like a
// feed's inserts and removes, and looked up like drawing and sorting do. Skipped unless
// NGTABLE_BENCH is set:
//
//     NGTABLE_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter NGHandleSequenceBenchmark

extension NGBenchmarks {
    @Suite("Handle sequence benchmark", .enabled(if: ProcessInfo.processInfo.environment["NGTABLE_BENCH"] != nil))
    struct NGHandleSequenceBenchmark {
        @Test(arguments: [200_000, 1_000_000])
        func changesAndLookups(_ rows: Int) {
            var generator = SplitMix64(seed: 3)
            let operations = 200_000
            func time(_ body: () -> Void) -> Double {
                let start = ContinuousClock.now
                body()
                let elapsed = start.duration(to: .now).components
                return (Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) * 1e9 / Double(operations)
            }
            for (name, make) in [("row order", { NGHandleSequence.changingOrder(0..<rows, capacity: rows + 3 * operations) })] as [(String, () -> NGHandleSequence)] {
                var sequence = make()
                var next = Int32(rows)
                var checksum = 0
                // Remove at a random place, insert at another (the size stays).
                let changes = time {
                    for _ in 0..<operations {
                        let handle = sequence.remove(at: Int(generator.next() % UInt64(sequence.count)))
                        _ = handle
                        sequence.insert(next, at: Int(generator.next() % UInt64(sequence.count + 1)))
                        next += 1
                    }
                }
                let lookups = time {
                    for _ in 0..<operations {
                        checksum &+= sequence.index(of: Int32(rows) + Int32(generator.next() % UInt64(operations)))
                        checksum &+= Int(sequence.handle(at: Int(generator.next() % UInt64(sequence.count))))
                    }
                }
                // Appends and removes at random places, like a feed's swap-removes.
                let feed = time {
                    for _ in 0..<operations {
                        sequence.remove(at: Int(generator.next() % UInt64(sequence.count)))
                        sequence.insert(next, at: sequence.count)
                        next += 1
                    }
                }
                print(String(format: "Handle sequence, %@, %d rows: remove+insert %.0f ns, index(of:)+handle(at:) %.0f ns, feed remove+append %.0f ns (%d)",
                             name, rows, changes, lookups, feed, checksum & 1))
                #expect(sequence.count == rows)
            }
        }
    }
}
