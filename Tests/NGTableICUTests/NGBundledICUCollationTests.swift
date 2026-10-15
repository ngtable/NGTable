#if os(macOS)
import AppKit
import Testing
@testable import NGTable
import NGTableICU

/// The table sorts text by the bundled ICU's keys in Finder's order.
@Suite("Bundled ICU collation")
@MainActor
struct NGBundledICUCollationTests {
    final class Names: NGTableViewDataSource {
        let names: [String]
        init(_ names: [String]) { self.names = names }
        func numberOfRows(in tableView: NGTableView) -> Int { names.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text(names[row]) }
    }

    /// Case, accents, Ё, scripts, numbers by value, punctuation; without
    /// what `localizedStandardCompare` itself orders inconsistently
    /// (leading zeros with ß or case, ligatures, full-width digits).
    static func names(_ count: Int) -> [String] {
        var state: UInt64 = 11
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        let words = ["Keto", "keto", "кето", "Кето", "Ёлка", "елка", "Елка", "Éclair", "école", "Ångström", "Müller", "Mueller",
                     "café", "Cafe", "zebra", "Zebra", "广告", "東京", "Ελλάδα", "naïve", "(copy)", "file", "File", "Campaign", "#tag"]
        return (0..<count).map { _ in
            words[Int(next() % UInt64(words.count))] + [" ", "-", "", "  "][Int(next() % 4)] + String(next() % 3000)
                + (next() % 2 == 0 ? " " + words[Int(next() % UInt64(words.count))] : "")
        }
    }

    @Test func sortsLikeFinder() async throws {
        let source = Names(Self.names(50_000))
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200))]
        table.collationKeyProvider = NGBundledICUCollation()
        table.dataSource = source
        table.sortsRows = true
        for ascending in [true, false] {
            table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: ascending)]
            while table.isSortingRows { try await Task.sleep(for: .milliseconds(1)) }
            let shown = (0..<table.numberOfRows).map { source.names[table.sourceRow($0)] }
            let expected = source.names.indices.sorted { a, b in
                let order = source.names[a].localizedStandardCompare(source.names[b])
                if order == .orderedSame { return a < b }
                return (order == .orderedAscending) == ascending
            }.map { source.names[$0] }
            #expect(shown == expected, "ascending \(ascending)")
        }
    }

    @Test func makesKeys() {
        let maker = NGBundledICUCollation().makeKeyMaker(collatorIdentifier: Locale.current.collatorIdentifier ?? "en")
        #expect(maker != nil)
        var key: [UInt8] = []
        Array("file10".utf16).withUnsafeBufferPointer { maker?.makeKey(of: $0, into: &key) }
        var other: [UInt8] = []
        Array("file9".utf16).withUnsafeBufferPointer { maker?.makeKey(of: $0, into: &other) }
        #expect(other.lexicographicallyPrecedes(key))   // Numbers by value.
    }
}
#endif
