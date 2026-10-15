//
//  BinanceBookSync.swift
//  NGTable Mac Bench
//
//  keeping a local order book of a pair in step with Binance, as its docs say:
//  the stream's changes are buffered until a REST snapshot comes; a snapshot older than the
//  first buffered change is fetched again; changes up to the snapshot's last update ID are
//  dropped; then each change applies if it goes on from the book (ignored if older, and the
//  book is loaded again if one was missed).
//

import Foundation

nonisolated struct BinanceBookSync {
    /// Changes waiting for a snapshot, and the book's last update ID once loaded.
    private(set) var buffered: [BinanceDepth] = []
    private(set) var lastID: Int64?
    var isSynced: Bool { lastID != nil }

    enum Outcome: Equatable {
        /// Apply these changes, in order.
        case apply([BinanceDepth])
        /// The snapshot is older than the buffered changes: fetch another.
        case fetchAgain
        /// A change was missed: drop the book, buffer, and fetch a snapshot.
        case broken
    }

    /// A change from the stream.
    mutating func receive(_ change: BinanceDepth) -> Outcome {
        guard let lastID else {
            buffered.append(change)
            return .apply([])
        }
        if change.lastID <= lastID { return .apply([]) }
        guard change.firstID <= lastID + 1 else {
            reset()
            buffered.append(change)
            return .broken
        }
        self.lastID = change.lastID
        return .apply([change])
    }

    /// A snapshot loaded with this last update ID: the buffered changes that go on from it.
    mutating func snapshot(lastUpdateID: Int64) -> Outcome {
        if let first = buffered.first, lastUpdateID < first.firstID - 1 { return .fetchAgain }
        lastID = lastUpdateID
        let waiting = buffered
        buffered = []
        var applied: [BinanceDepth] = []
        for change in waiting {
            switch receive(change) {
            case .apply(let changes): applied += changes
            case .broken: return .broken
            case .fetchAgain: return .fetchAgain
            }
        }
        return .apply(applied)
    }

    /// Back to buffering (the book is loaded again).
    mutating func reset() {
        lastID = nil
        buffered = []
    }
}
