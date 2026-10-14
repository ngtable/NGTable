#if os(macOS)
import AppKit

// Work done on the main actor in slices (reading values for a sort,
// summaries, a search, a grouping, measuring wrapped rows, a copy) shares
// one budget per turn of the run loop, for all of the app's tables: a slice
// takes what is left of the turn's few milliseconds, and once they are spent
// the next one waits for the next turn. `Task.yield()` alone didn't give the
// run loop a turn: the main queue ran one job's slices after another, and
// the four jobs of a reload of a million rows held it for up to 70 ms.
// Slices waiting for a turn go on in the order they came (a ticket each), so
// no job of any table starves. While the run loop doesn't turn (the main
// thread busy with other work, a command line tool, tests in parallel) no
// events wait either: slices only yield to other work, as before.

@MainActor
enum NGBackgroundSlices {
    /// Turns of the main run loop, counted by an observer.
    private static var turn = 0
    private static var observer: CFRunLoopObserver?
    /// When the run loop last turned.
    private static var lastTurn = ContinuousClock.now
    /// The run loop turns (it did lately): slices wait for its turns.
    /// Otherwise (the main thread busy for a while, a command line tool,
    /// tests in parallel) no events wait for them either: they go on.
    private static var isTurning: Bool { ContinuousClock.now - lastTurn < .milliseconds(20) }
    /// The turn the budget is of, and when it runs out.
    private static var budgetTurn = -1
    private static var budgetEnd = ContinuousClock.now
    /// Less than this left of a turn's budget: spent.
    private static let leastSlice: Duration = .microseconds(500)
    /// Slices waited for a turn (for tests).
    static var waitsForTesting = 0
    static var turnForTesting: Int { turn }
    /// Budgets started (for tests).
    static var budgetsForTesting = 0

    private static func observeTurns() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeTimers.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated {
                NGBackgroundSlices.turn &+= 1
                NGBackgroundSlices.lastTurn = ContinuousClock.now
                // The slices waiting run after this turn's events, the one
                // waiting longest first.
                NGBackgroundSlices.resumeAll()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// Waits, if this turn's budget is spent, for the next turn of the run
    /// loop; the first slice of a turn starts its budget, the others share it.
    static func nextSlice() async {
        observeTurns()
        var ticket: Int?
        while true {
            if budgetTurn != turn {
                budgetTurn = turn
                budgetsForTesting += 1
                budgetEnd = ContinuousClock.now.advanced(by: NGTableView.backgroundSlice)
                return
            }
            if ContinuousClock.now < budgetEnd - leastSlice { return }
            // Its place in line, kept until it gets a slice.
            if ticket == nil {
                nextTicket &+= 1
                ticket = nextTicket
            }
            guard isTurning else {
                // Other work on the main actor goes on between slices still.
                await Task.yield()
                budgetTurn = -1
                continue
            }
            waitsForTesting += 1
            // No turn came: a new budget anyway.
            if !(await waitForATurn(ticket: ticket ?? 0)) { budgetTurn = -1 }
        }
    }

    /// Until the run loop turns, or a moment at most without turns: a slice
    /// never waits forever. Woken in ticket order; one too late for the
    /// turn's budget waits again in its place.
    /// - Returns: Whether the run loop turned.
    @discardableResult
    private static func waitForATurn(ticket: Int = .max) async -> Bool {
        let spent = turn
        let waiter = Waiter(ticket: ticket)
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            // In line by ticket: one woken too late for this turn's budget
            // keeps its place ahead of those who came after it.
            let place = waiters.firstIndex { $0.ticket > ticket } ?? waiters.count
            waiters.insert(waiter, at: place)
            watchForMissingTurns()
        }
        return turn != spent
    }

    /// While slices wait: without a turn for a few milliseconds (the main
    /// thread busy with other work, so no events are handled either), they
    /// all go on, each with a budget of its own.
    private static func watchForMissingTurns() {
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor in
            while !waiters.isEmpty {
                let seen = turn
                try? await Task.sleep(for: .milliseconds(4))
                if turn == seen { resumeAll() }
            }
            watchdog = nil
        }
    }

    private static func resumeAll() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// A slice waiting for the next turn, resumed once.
    private final class Waiter {
        let ticket: Int
        init(ticket: Int) { self.ticket = ticket }
        var continuation: CheckedContinuation<Void, Never>?
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// Slices waiting for a turn, by ticket (longest first).
    private static var waiters: [Waiter] = []
    private static var nextTicket = 0
    private static var watchdog: Task<Void, Never>?

    /// Before a step that can't be cut (laying out the rows a job is done
    /// with): waits for a turn of its own, and leaves the rest of it to
    /// the run loop.
    static func turnOfItsOwn() async {
        observeTurns()
        // A turn no slice has started.
        if budgetTurn == turn {
            if isTurning { await waitForATurn() } else { await Task.yield() }
        }
        budgetTurn = turn
        budgetEnd = ContinuousClock.now
    }

    /// When the slice running now must stop: the end of the turn's budget,
    /// or a slice's time from now outside the budget (a first slice taken at
    /// once).
    static func deadline() -> ContinuousClock.Instant {
        let own = ContinuousClock.now.advanced(by: NGTableView.backgroundSlice)
        return budgetTurn == turn ? min(budgetEnd, own) : own
    }
}
#endif
