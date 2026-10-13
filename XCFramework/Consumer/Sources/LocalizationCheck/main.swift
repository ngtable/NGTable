import AppKit
import NGTable

// VoiceOver reads a sorted column's order with a string the table looks up
// in its own bundle. Run with `-AppleLanguages "(ru)"`; exits with 1 unless
// the string is the Russian one.

@MainActor
final class Rows: NGTableViewDataSource {
    func numberOfRows(in tableView: NGTableView) -> Int { 10 }
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .number(Double(row)) }
}

let rows = Rows()
let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
table.columns = [.column(NGTableColumn("n", title: "N"))]
table.dataSource = rows
table.sortDescriptors = [NSSortDescriptor(key: "n", ascending: true)]
table.reloadData()
table.layoutSubtreeIfNeeded()

let header = table.accessibilityColumnHeaderUIElements()?.first as? NSAccessibilityElement
let value = header?.accessibilityValue() as? String
print("Sorted column reads: \(value ?? "nil")")
exit(value == "по возрастанию" ? 0 : 1)
