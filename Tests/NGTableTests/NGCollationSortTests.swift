#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Text sorts on all cores and by collation keys give exactly the order of
/// comparing with `localizedStandardCompare`. Real keys come from ICU (the
/// NGTableICU tests test those); here the keys are rough on purpose, so
/// equal keys, the check of neighbors and the sort after a wrong pair all run.
@Suite("Collation sorts")
struct NGCollationSortTests {
    /// Keys from folded text: case, accents and widths away, digits as they
    /// are ("file10" before "file2": wrong, which the check has to find).
    struct FoldedKeys: NGCollationKeyProvider {
        final class Maker: NGCollationKeyMaker {
            func makeKey(of text: UnsafeBufferPointer<UInt16>, into key: inout [UInt8]) {
                let folded = String(decoding: text, as: UTF16.self)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                key.append(contentsOf: folded.utf8.prefix(12))
            }
        }
        func makeKeyMaker(collatorIdentifier: String) -> (any NGCollationKeyMaker)? { Maker() }
    }

    /// Varied text: case, accents, Ё, scripts, digits by value, punctuation.
    /// `strict` leaves out what `localizedStandardCompare` itself orders
    /// inconsistently (it isn't transitive with leading zeros together with
    /// ß or case, nor with ligatures and full-width digits): there any two
    /// sorts may differ, and only "every neighbor in order" holds.
    private func corpus(_ count: Int, seed: UInt64 = 1, strict: Bool = true) -> [String] {
        var state = seed
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        let all = NGTextCollation.samples.filter { !$0.isEmpty } + ["Keto", "кето", "Campaign", "campaign"]
        let words = !strict ? all : all.filter { word in
            !word.contains("ß") && !word.contains("ﬁ") && !word.hasPrefix("0") && !word.contains("02")
                && !word.unicodeScalars.contains { (0xFF00...0xFFEF).contains($0.value) }
        }
        return (0..<count).map { _ in
            words[Int(next() % UInt64(words.count))] + [" ", "-", "", "  "][Int(next() % 4)] + String(next() % 300)
                + (next() % 3 == 0 ? " " + words[Int(next() % UInt64(words.count))] : "")
        }
    }

    @Test func workersCompareLikeFoundation() {
        let collation = NGTextCollation.current
        let samples = NGTextCollation.samples
        for worker in 0..<collation.workerCount {
            for lhs in samples.prefix(40) {
                for rhs in samples.suffix(40) {
                    #expect(collation.compare(lhs, rhs, worker: worker) == lhs.localizedStandardCompare(rhs))
                }
            }
        }
    }

    @Test func keysGiveTheComparisonsOrder() throws {
        let texts = corpus(20_000)
        let numbers = texts.indices.map { NGCellValue.number(Double($0 % 7)) }
        let order = NGRowHandles(count: texts.count)
        let rows = Array(texts.indices)
        let collation = NGTextCollation.current
        for ascending in [[true, true], [false, true], [true, false]] {
            let keys = NGSortKeys(keys: ["t", "n"], ascending: ascending, values: [texts.map(NGCellValue.text), numbers])
            let reference = rows.sorted { keys.comesBefore($0, $1, order: order) }
            let byKeys = try #require(keys.collationSorted(rows, order: order, collation: collation, provider: FoldedKeys()))
            #expect(byKeys == reference, "\(ascending)")
            let parallel = NGParallelSort.sorted(rows, workers: collation.workerCount) {
                keys.comesBefore($0, $1, order: order, collation: collation, worker: $2)
            }
            #expect(parallel == reference, "\(ascending)")
        }
    }

    /// Where `localizedStandardCompare` isn't transitive, every neighbor is in order.
    @Test func inconsistentTextIsSortedPairByPair() throws {
        let texts = corpus(20_000, seed: 3, strict: false).map(NGCellValue.text)
        let keys = NGSortKeys(keys: ["t"], ascending: [true], values: [texts])
        let order = NGRowHandles(count: texts.count)
        let rows = Array(texts.indices)
        let byKeys = try #require(keys.collationSorted(rows, order: order, collation: .current, provider: FoldedKeys()))
        #expect(byKeys.sorted() == rows)
        #expect(!zip(byKeys, byKeys.dropFirst()).contains { keys.comesBefore($1, $0, order: order) })
    }

    /// Keys that disagree with the comparison everywhere: the check finds it
    /// and the order is still exact.
    @Test func wrongKeysStillSortExactly() throws {
        /// Keys in the reverse order of the text.
        struct ReversedKeys: NGCollationKeyProvider {
            final class Maker: NGCollationKeyMaker {
                func makeKey(of text: UnsafeBufferPointer<UInt16>, into key: inout [UInt8]) {
                    key.append(contentsOf: String(decoding: text, as: UTF16.self).lowercased().utf8.map { 255 - $0 })
                }
            }
            func makeKeyMaker(collatorIdentifier: String) -> (any NGCollationKeyMaker)? { Maker() }
        }
        struct NoKeys: NGCollationKeyProvider {
            func makeKeyMaker(collatorIdentifier: String) -> (any NGCollationKeyMaker)? { nil }
        }
        let texts = corpus(10_000, seed: 9).map(NGCellValue.text)
        let keys = NGSortKeys(keys: ["t"], ascending: [true], values: [texts])
        let order = NGRowHandles(count: texts.count)
        let rows = Array(texts.indices)
        let reference = rows.sorted { keys.comesBefore($0, $1, order: order) }
        let collation = NGTextCollation.current
        #expect(try #require(keys.collationSorted(rows, order: order, collation: collation, provider: ReversedKeys())) == reference)
        #expect(keys.collationSorted(rows, order: order, collation: collation, provider: NoKeys()) == nil)
    }

    @MainActor
    final class Names: NGTableViewDataSource {
        let names: [String]
        init(_ names: [String]) { self.names = names }
        func numberOfRows(in tableView: NGTableView) -> Int { names.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text(names[row]) }
    }

    /// The table sorts by keys in the background, in Finder's order (rough
    /// keys: the check sorts it right).
    @Test @MainActor func tableSortsTextByKeys() async throws {
        let source = Names(corpus(8_000, seed: 5))
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200))]
        table.collationKeyProvider = FoldedKeys()
        table.synchronousSortLimit = 100
        table.dataSource = source
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        for _ in 0..<30_000 where table.isSortingRows { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!table.isSortingRows)
        let shown = (0..<table.numberOfRows).map { source.names[table.sourceRow($0)] }
        let expected = source.names.indices.sorted { a, b in
            let order = source.names[a].localizedStandardCompare(source.names[b])
            return order == .orderedSame ? a < b : order == .orderedAscending
        }.map { source.names[$0] }
        #expect(shown == expected)
    }
}
#endif
