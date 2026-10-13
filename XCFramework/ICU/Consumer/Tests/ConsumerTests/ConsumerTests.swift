import AppKit
import Testing
import NGTable
import NGTableICU

@MainActor
private final class Names: NGTableViewDataSource {
    let names: [String]
    init(_ names: [String]) { self.names = names }
    func numberOfRows(in tableView: NGTableView) -> Int { names.count }
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text(names[row]) }
}

/// NGTableICU linked as the binary XCFramework next to the binary NGTable, used only
/// through their public API.
@MainActor
@Suite struct ConsumerTests {
    /// A table sorts text by the bundled ICU's keys in Finder's order.
    @Test func sortsLikeFinder() async throws {
        var state: UInt64 = 11
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        let words = ["Keto", "keto", "кето", "Ёлка", "елка", "Éclair", "école", "Müller", "café", "Cafe", "zebra", "東京", "file", "File"]
        let source = Names((0..<20_000).map { _ in words[Int(next() % UInt64(words.count))] + " " + String(next() % 3000) })
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 200))]
        table.collationKeyProvider = NGBundledICUCollation()
        table.dataSource = source
        table.sortsRows = true
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        while table.isSortingRows { try await Task.sleep(for: .milliseconds(1)) }
        let shown = try (0..<table.numberOfDisplayedRows).map { source.names[try #require(table.row(atDisplayIndex: $0))] }
        // Names that compare the same keep the data source's order.
        let expected = source.names.indices.sorted { a, b in
            let order = source.names[a].localizedStandardCompare(source.names[b])
            return order == .orderedSame ? a < b : order == .orderedAscending
        }.map { source.names[$0] }
        #expect(shown == expected)
    }

    /// The keys come from the ICU inside the framework: numbers by value.
    @Test func makesKeys() throws {
        let maker = try #require(NGBundledICUCollation().makeKeyMaker(collatorIdentifier: "en"))
        var ten: [UInt8] = [], nine: [UInt8] = []
        Array("file10".utf16).withUnsafeBufferPointer { maker.makeKey(of: $0, into: &ten) }
        Array("file9".utf16).withUnsafeBufferPointer { maker.makeKey(of: $0, into: &nine) }
        #expect(nine.lexicographicallyPrecedes(ten))
    }
}
