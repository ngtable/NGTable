#if os(macOS)
import Foundation

/// Waits while `condition` holds, for a table's background work (a sort, a
/// search, summaries, a copy) to finish. Tests run in parallel on the main
/// actor, and that work needs the main actor's turns now and then, so it can
/// take long while other tests run there: the deadline only stops a hang.
/// - Returns: Whether the condition ended before the deadline.
@MainActor @discardableResult
func waitWhile(timeout: Duration = .seconds(300), poll: Duration = .milliseconds(2),
               _ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while condition() {
        if ContinuousClock.now >= deadline { return false }
        try await Task.sleep(for: poll)
    }
    return true
}
#endif
