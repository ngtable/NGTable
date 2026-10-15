//
//  FeedBacklogTests.swift
//  NGTable Mac Bench Tests
//
//  How the ngfeed client keeps up: the connection stops reading at a limit and goes on once
//  taken; changes the client doesn't catch up with are dropped, those it does are kept.
//

import Foundation
import Testing
@testable import NGTable_Mac_Bench

struct FeedBacklogTests {
    /// Reading stops at the limit of frames or bytes, and starts again once taken (before,
    /// a slow client read on and piled up messages without end).
    @Test func readingStopsAtTheLimit() {
        var gate = FeedReadingGate(limit: (bytes: 1000, frames: 10))
        let readsOn = (0..<10).map { _ in gate.received(bytes: 10) }
        #expect(readsOn == Array(repeating: true, count: 9) + [false])
        #expect(gate.isPaused)
        let resumes = [gate.taken(), gate.taken()]
        #expect(resumes == [true, false])   // Paused: reading starts again; then nothing to start.
        let byBytes = [gate.received(bytes: 999), gate.received(bytes: 1)]
        #expect(byBytes == [true, false])
        _ = gate.taken()
        let after = gate.received(bytes: 1)
        #expect(after && gate.frames == 1 && gate.bytes == 1)
    }

    private func update(seq: Int, genTs: Int64) -> FeedMessage {
        .update(seq: seq, genTs: genTs, rows: [], conflated: nil)
    }

    /// Changes older than the limit and no younger a second later are dropped; the other
    /// messages stay, in order.
    @Test func changesNotCaughtUpWithAreDropped() {
        var backlog = FeedBacklog()
        backlog.take([update(seq: 1, genTs: 0), .heartbeat(seq: 1), update(seq: 2, genTs: 0), .end(reason: "x")])
        let start = ContinuousClock.now
        let old = FeedBacklog.staleLimit + 1
        let drops = [
            backlog.dropChangesIfBehind(nowMicros: old, now: start),                                     // First look.
            backlog.dropChangesIfBehind(nowMicros: old + 500_000, now: start + .milliseconds(500)),      // Not a second yet.
            backlog.dropChangesIfBehind(nowMicros: old + 1_000_000, now: start + .seconds(1)),
        ]
        #expect(drops == [false, false, true])
        #expect(backlog.count == 2)
        guard case .heartbeat = backlog.next(), case .end = backlog.next() else {
            Issue.record("the other messages didn't stay")
            return
        }
        #expect(backlog.isEmpty)
    }

    /// After a long snapshot the changes are old but get younger each second, as the client
    /// catches up: kept (the first version dropped them, and asked for a snapshot forever on
    /// a million rows).
    @Test func changesCaughtUpWithAreKept() {
        var backlog = FeedBacklog()
        let start = ContinuousClock.now
        var nowMicros = 4_000_000.0
        var genTs: Int64 = 0
        backlog.take([update(seq: 1, genTs: genTs)])
        for second in 0..<5 {
            // A second later the next change is a second and a half younger.
            let dropped = backlog.dropChangesIfBehind(nowMicros: nowMicros, now: start + .seconds(second))
            #expect(!dropped)
            _ = backlog.next()
            nowMicros += 1_000_000
            genTs += 1_500_000
            backlog.take([update(seq: second + 2, genTs: genTs)])
        }
        // Young enough: not behind at all.
        let dropped = backlog.dropChangesIfBehind(nowMicros: Double(genTs) + 1000, now: start + .seconds(6))
        #expect(!dropped)
    }
}
