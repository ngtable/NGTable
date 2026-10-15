//
//  FeedBacklog.swift
//  NGTable Mac Bench
//
//  how the feed client keeps up, or knows it can't. The connection stops reading
//  while too much waits for the main thread (FeedReadingGate), so the server conflates for a
//  slow client; the main thread applies what it took for a frame's budget and takes no more
//  until it is through (FeedBacklog), and drops the changes waiting for a new snapshot when they
//  are old and getting no younger. Without these a client slower than the feed fell ever
//  further behind, each frame longer than the last, until the app hung (`orders`, Debug build).
//

import Foundation

/// Whether a connection reads on: it stops when the frames received and not taken yet reach
/// a limit, and goes on once they are taken. Used under the connection's lock.
nonisolated struct FeedReadingGate {
    let limit: (bytes: Int, frames: Int)
    private(set) var bytes = 0
    private(set) var frames = 0
    private(set) var isPaused = false

    init(limit: (bytes: Int, frames: Int)) {
        self.limit = limit
    }

    /// A frame received: whether to read the next one.
    mutating func received(bytes: Int) -> Bool {
        self.bytes += bytes
        frames += 1
        isPaused = self.bytes >= limit.bytes || frames >= limit.frames
        return !isPaused
    }

    /// The frames taken: whether reading, paused, starts again.
    mutating func taken() -> Bool {
        (bytes, frames) = (0, 0)
        defer { isPaused = false }
        return isPaused
    }
}

/// The messages the main thread took and hasn't applied yet, in order.
nonisolated struct FeedBacklog {
    /// How old (from the generator) the next change may be before the client is behind, µs.
    static let staleLimit: Double = 2_000_000

    private var messages: [FeedMessage] = []
    private var start = 0
    /// The age of the next change when last checked (once a second), µs.
    private var lastAge: (checked: ContinuousClock.Instant, age: Double)?

    var count: Int { messages.count - start }
    var isEmpty: Bool { start == messages.count }

    /// New messages, once the ones before are through.
    mutating func take(_ new: [FeedMessage]) {
        precondition(isEmpty, "the backlog takes more only when it's through")
        (messages, start) = (new, 0)
    }

    mutating func next() -> FeedMessage? {
        guard start < messages.count else { return nil }
        defer {
            start += 1
            if start == messages.count { (messages, start) = ([], 0) }
        }
        return messages[start]
    }

    mutating func removeAll() {
        (messages, start, lastAge) = ([], 0, nil)
    }

    /// Whether the client is behind: the next change is older than `staleLimit` and no
    /// younger than a second ago. After a long snapshot the changes are old too, but caught
    /// up with: younger each second. Then the changes waiting are dropped (the other messages
    /// stay, in order) for a new snapshot.
    mutating func dropChangesIfBehind(nowMicros: Double, now: ContinuousClock.Instant = .now) -> Bool {
        guard start < messages.count else {
            lastAge = nil
            return false
        }
        let genTs: Int64? = switch messages[start] {
        case .update(_, let genTs, _, _), .insert(_, let genTs, _, _), .delete(_, let genTs, _, _): genTs
        default: nil
        }
        guard let genTs else { return false }
        let age = nowMicros - Double(genTs)
        guard age > Self.staleLimit else {
            lastAge = nil
            return false
        }
        guard let last = lastAge else {
            lastAge = (now, age)
            return false
        }
        guard last.checked.duration(to: now) >= .seconds(1) else { return false }
        lastAge = (now, age)
        guard age >= last.age else { return false }   // Catching up.
        messages = messages[start...].filter { message in
            switch message {
            case .update, .insert, .delete: false
            default: true
            }
        }
        (start, lastAge) = (0, nil)
        return true
    }
}
