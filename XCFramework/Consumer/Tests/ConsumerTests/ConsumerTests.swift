import AppKit
import Testing
import NGTable

@MainActor
private final class Rows: NGTableViewDataSource {
    func numberOfRows(in tableView: NGTableView) -> Int { 1_000 }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        column.id == "n" ? .number(Double(row)) : .text("Row \(row)")
    }
}

/// NGTable linked as the binary XCFramework, used only through its public API.
@MainActor
@Suite struct ConsumerTests {
    /// The framework carries its strings in its own bundle (`Bundle.module`
    /// in a package), with the Russian translation.
    @Test func stringsAreInTheFrameworkBundle() throws {
        let bundle = Bundle(for: NGTableView.self)
        #expect(bundle.bundleURL.lastPathComponent == "NGTable.framework")
        let russian = try #require(bundle.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:)))
        #expect(russian.localizedString(forKey: "ascending", value: nil, table: nil) == "по возрастанию")
    }

    /// The frozen enums are switched over without `@unknown default` (the others, built
    /// with library evolution, need one: a Swift 6 error without it). Compiling is the test.
    @Test func frozenEnumsSwitchExhaustively() {
        let items: [NGColumnItem] = [.column(NGTableColumn("a", title: "A")),
                                     .group(NGColumnGroup("g", title: "G", columns: [NGTableColumn("b", title: "B")]))]
        let count = items.map { item -> Int in
            switch item {
            case .column: 1
            case .group(let group): group.columns.count
            }
        }.reduce(0, +)
        #expect(count == 2)
        let edges = NGColumnPin.allCases.map { pin -> String in
            switch pin {
            case .leading: "leading"
            case .none: "none"
            case .trailing: "trailing"
            }
        }
        #expect(edges == ["leading", "none", "trailing"])
        switch NGColumnVisibility.state(of: "a", in: items, hiddenIDs: []) {
        case .visible: break
        case .partiallyVisible, .hidden: Issue.record("a shown column reads as hidden")
        }
    }

    /// A table lays out and draws its rows from outside the module.
    @Test func tableShowsRows() {
        let rows = Rows()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("name", title: "Name")),
            .column(NGTableColumn("n", title: "N", alignment: .trailing, format: .number(fractionDigits: 0))),
        ]
        table.dataSource = rows
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        #expect(table.numberOfDisplayedRows == 1_000)
    }
}
