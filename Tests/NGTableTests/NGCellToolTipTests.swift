#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Cell tool tips: the whole text of cells too narrow for it, and the
/// delegate's tool tips for any cell.
@Suite("Cell tool tips")
@MainActor
struct NGCellToolTipTests {
    @MainActor
    final class Source: NGTableViewDataSource, NGTableViewDelegate {
        var toolTips: [Int: String] = [:]
        func numberOfRows(in tableView: NGTableView) -> Int { 10 }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            switch column.id {
            case "name": .text(row == 0 ? "A campaign with a name far too long for its column" : "Short")
            case "amount": .number(row == 0 ? 123_456_789.25 : 1)
            default: .tags([NGTag("Active", color: .green), NGTag("Retargeting", color: .blue), NGTag("Summer", color: .orange)])
            }
        }
        func tableView(_ tableView: NGTableView, toolTipForRow row: Int, column: NGTableColumn) -> String? {
            toolTips[row]
        }
    }

    @Test func truncatedCellsShowTheirText() throws {
        let source = Source()
        let frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { withExtendedLifetime((window, source)) {} }
        let table = NGTableView(frame: frame)
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 120)),
                         .column(NGTableColumn("amount", title: "Amount", width: 60, format: .number(fractionDigits: 2))),
                         .column(NGTableColumn("tags", title: "Tags", width: 90))]
        window.contentView = table
        table.dataSource = source
        table.delegate = source
        table.layoutSubtreeIfNeeded()
        let region = table.centerRegion
        func toolTip(row: Int, column: String) -> String? {
            let x = table.geometry.center.columns.first { $0.column.id == column }.map { CGFloat($0.x + $0.width / 2) } ?? 0
            return table.cellToolTip(at: NSPoint(x: x, y: (CGFloat(row) + 0.5) * table.rowHeight), in: region)
        }
        #expect(toolTip(row: 0, column: "name") == "A campaign with a name far too long for its column")
        #expect(toolTip(row: 1, column: "name") == nil)
        #expect(toolTip(row: 0, column: "amount") == NGValueFormat.number(fractionDigits: 2).string(for: .number(123_456_789.25)))
        #expect(toolTip(row: 1, column: "amount") == nil)
        #expect(toolTip(row: 1, column: "tags") == "Active, Retargeting, Summer")
        // The delegate's, for any cell; an empty string hides one.
        source.toolTips = [1: "Paused by the rules", 0: ""]
        #expect(toolTip(row: 1, column: "name") == "Paused by the rules")
        #expect(toolTip(row: 0, column: "name") == nil)
    }
}
#endif
