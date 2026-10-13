#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Background work (full sorts, summaries, the first search of large
/// tables) finishes under a live feed that inserts and removes rows all the
/// time, and its result matches the data.
@Suite("Background work under a feed")
@MainActor
struct NGBackgroundFeedTests {
    typealias Feed = NGConsistencyTests.Feed

    /// Ticks of a feed (an insert, a remove and a changed value) a
    /// millisecond apart until `done`, for at most `ticks` ticks; whether
    /// `done` came. Counted, not timed: tests running alongside hold the
    /// main actor for seconds, which slows the ticks and the background
    /// work's slices alike (each tick leaves about one slice a turn).
    static func feed(_ table: NGTableView, _ feed: Feed, ticks: Int = 3_000,
                     until done: () -> Bool) async throws -> Bool {
        for _ in 0..<ticks {
            if done() { return true }
            table.beginUpdates()
            let index = feed.random(feed.records.count + 1)
            feed.records.insert(feed.makeRecord(), at: index)
            table.insertRows(at: [index])
            let removed = feed.random(feed.records.count)
            feed.records.remove(at: removed)
            table.removeRows(at: [removed])
            let changed = feed.random(feed.records.count)
            feed.change(&feed.records[changed], columns: ["profit", "name"])
            table.reloadData(forRowIndexes: [changed], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            table.endUpdates()
            try await Task.sleep(for: .milliseconds(1))
        }
        return done()
    }

    @Test func fullSortsFinish() async throws {
        let feed = Feed(count: 20_000, seed: 7)
        let configuration = NGConsistencyTests.Configuration(sortsRows: true, sort: [NSSortDescriptor(key: "name", ascending: true)])
        let table = NGConsistencyTests.makeTable(feed, configuration)
        defer { withExtendedLifetime(feed) {} }
        table.synchronousSortLimit = 1_000
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        #expect(table.isSortingRows)
        let finished = try await Self.feed(table, feed) { !table.isSortingRows }
        #expect(finished)
        var done = configuration
        done.sort = table.sortDescriptors
        NGConsistencyTests.expectSame(table, feed, done, "after the sort")
    }

    @Test func summariesFinish() async throws {
        let feed = Feed(count: 20_000, seed: 8)
        let table = NGConsistencyTests.makeTable(feed, .init())
        defer { withExtendedLifetime(feed) {} }
        table.synchronousSummaryLimit = 1_000
        table.reloadData()
        #expect(table.isComputingSummary)
        let finished = try await Self.feed(table, feed) { !table.isComputingSummary }
        #expect(finished)
        NGConsistencyTests.expectSame(table, feed, .init(), "after the summaries")
    }

    @Test func searchesFinish() async throws {
        let feed = Feed(count: 20_000, seed: 9)
        let table = NGConsistencyTests.makeTable(feed, .init())
        defer { withExtendedLifetime(feed) {} }
        table.synchronousSearchLimit = 1_000
        var configuration = NGConsistencyTests.Configuration(searchText: "a")
        table.rowFilter = configuration.filter(feed)
        #expect(table.isSearchingRows)
        let finished = try await Self.feed(table, feed) { !table.isSearchingRows }
        #expect(finished)
        NGConsistencyTests.expectSame(table, feed, configuration, "after the search")
        configuration.searchText = "al"
        table.rowFilter = configuration.filter(feed)
        NGConsistencyTests.expectSame(table, feed, configuration, "the next search")
    }

    /// A sort, a search and summaries at once, while grouped and fed.
    @Test func allAtOnceFinish() async throws {
        let feed = Feed(count: 20_000, seed: 10)
        var configuration = NGConsistencyTests.Configuration(grouping: ["status"])
        let table = NGConsistencyTests.makeTable(feed, configuration)
        defer { withExtendedLifetime(feed) {} }
        (table.synchronousSortLimit, table.synchronousSearchLimit, table.synchronousSummaryLimit) = (1_000, 1_000, 1_000)
        table.reloadData()
        configuration.sortsRows = true
        configuration.sort = [NSSortDescriptor(key: "name", ascending: false)]
        table.sortsRows = true
        table.sortDescriptors = configuration.sort
        configuration.searchText = "е"
        configuration.condition = true
        table.rowFilter = configuration.filter(feed)
        #expect(table.isSortingRows && table.isSearchingRows && table.isComputingSummary)
        let finished = try await Self.feed(table, feed) {
            !table.isSortingRows && !table.isSearchingRows && !table.isComputingSummary
        }
        #expect(finished)
        NGConsistencyTests.expectSame(table, feed, configuration, "after all of them")
    }

    /// A batch can span an `await`: the slices of background work wait for
    /// its end instead of reading rows the data source already moved.
    @Test func backgroundWorkWaitsForABatchThatMovedRows() async throws {
        // These batches span an `await` on purpose.
        NGTableView.reportsBatchesAcrossRunLoopTurns = false
        let feed = Feed(count: 5_000, seed: 12)
        var configuration = NGConsistencyTests.Configuration(sortsRows: true, sort: [NSSortDescriptor(key: "profit", ascending: true)])
        let table = NGConsistencyTests.makeTable(feed, configuration)
        defer { withExtendedLifetime(feed) {} }
        (table.synchronousSortLimit, table.synchronousSearchLimit, table.synchronousSummaryLimit) = (1_000, 1_000, 1_000)
        table.reloadData()
        configuration.searchText = "a"
        table.rowFilter = configuration.filter(feed)
        #expect(table.isSearchingRows && table.isSortingRows && table.isComputingSummary)
        // As many rows, other rows at the same indexes.
        table.beginUpdates()
        feed.records.insert(feed.makeRecord(), at: 0)
        table.insertRows(at: [0])
        feed.records.removeLast()
        table.removeRows(at: [feed.records.count])
        for _ in 0..<50 { await Task.yield() }
        table.endUpdates()
        for _ in 0..<2_000 where table.isSearchingRows || table.isSortingRows || table.isComputingSummary {
            try await Task.sleep(for: .milliseconds(2))
        }
        NGConsistencyTests.expectSame(table, feed, configuration, "after the batch")
    }
}
#endif
