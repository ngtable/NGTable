#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Slices of work on the main actor share one budget per turn of the run
/// loop (NGBackgroundSlices.swift), so the turn's events don't wait for
/// every job's slice in a row.
@MainActor
@Suite("Background slices", .serialized)
struct NGBackgroundSlicesTests {
    @MainActor final class Log {
        var slices: [(budget: Int, turn: Int, job: Int, time: Duration)] = []
    }

    /// Two jobs slicing as fast as they may: the slices that share a budget
    /// (a turn's) add up to one, and both jobs get slices. (Tests running
    /// in parallel keep the main actor busy for long stretches: each job
    /// takes slices until it has had a few, however long that takes.)
    @Test func jobsShareATurnsBudget() async throws {
        let log = Log()
        let end = ContinuousClock.now.advanced(by: .seconds(240))
        func slice(_ job: Int) async {
            while ContinuousClock.now < end, log.slices.filter({ $0.job == job }).count < 3 {
                await NGBackgroundSlices.nextSlice()
                let start = ContinuousClock.now
                let deadline = NGBackgroundSlices.deadline()
                while ContinuousClock.now < deadline {}
                log.slices.append((NGBackgroundSlices.budgetsForTesting, NGBackgroundSlices.turnForTesting, job, ContinuousClock.now - start))
            }
        }
        let firstTurn = NGBackgroundSlices.turnForTesting
        let jobs = [Task { await slice(0) }, Task { await slice(1) }]
        for job in jobs { await job.value }
        // By the budget they took their time from (a turn's, or a moment's
        // without turns of the run loop).
        var byTurn: [Int: Duration] = [:]
        for slice in log.slices { byTurn[slice.budget, default: .zero] += slice.time }
        let budget = NGTableView.backgroundSlice + .milliseconds(1)
        #expect(byTurn.values.allSatisfy { $0 <= budget }, "\(byTurn.values.max() ?? .zero)")
        #expect(Set(log.slices.map(\.job)) == [0, 1])
        #expect(log.slices.count >= 6)
        // The run loop turning all along (not tests keeping the main actor
        // busy): a turn's slices add up to one budget.
        if NGBackgroundSlices.turnForTesting - firstTurn >= log.slices.count {
            var perTurn: [Int: Duration] = [:]
            for slice in log.slices { perTurn[slice.turn, default: .zero] += slice.time }
            #expect(perTurn.values.allSatisfy { $0 <= budget }, "\(perTurn.values.max() ?? .zero)")
        }
    }

    /// A step that can't be cut gets a turn of its own: a slice after it
    /// waits for the next.
    @Test func aStepGetsATurnOfItsOwn() async {
        await NGBackgroundSlices.nextSlice()
        let sliced = NGBackgroundSlices.turnForTesting
        await NGBackgroundSlices.turnOfItsOwn()
        let own = NGBackgroundSlices.turnForTesting
        #expect(own != sliced)
        await NGBackgroundSlices.nextSlice()
        #expect(NGBackgroundSlices.turnForTesting != own)
    }
}
#endif
