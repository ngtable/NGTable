#if os(macOS)
import AppKit
import Testing
@testable import NGTable

@MainActor
private final class TestDataSource: NGTableViewDataSource {
    var rowCount = 50
    var constantValue: NGCellValue?
    var valueRequests = 0

    func numberOfRows(in tableView: NGTableView) -> Int { rowCount }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        valueRequests += 1
        if let constantValue { return constantValue }
        return column.isNumeric ? .number(Double(row + 1)) : .text("\(column.id)\(row)")
    }
}

/// Reads slowly, like a data source that computes its values.
@MainActor
private final class SlowDataSource: NGTableViewDataSource {
    func numberOfRows(in tableView: NGTableView) -> Int { 20_000 }
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        if column.id == "n" { Thread.sleep(forTimeInterval: 0.0001) }
        return .number(1)
    }
}

@MainActor
private final class SummaryUpdateDelegate: NGTableViewDelegate {
    var updates = 0
    func tableViewDidUpdateSummary(_ tableView: NGTableView) { updates += 1 }
}

@MainActor
private final class MarkerDelegate: NGTableViewDelegate {
    func tableView(_ tableView: NGTableView, markerColorForRow row: Int) -> NSColor? { row.isMultiple(of: 2) ? .systemGreen : nil }
}

@MainActor
private final class MenuDelegate: NGTableViewDelegate {
    var lastRows: IndexSet?
    var lastClickedRow: Int??

    func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: NGTableColumn?) -> NSMenu? {
        lastRows = rows
        lastClickedRow = .some(clickedRow)
        return NSMenu()
    }
}

@MainActor
private final class TintDelegate: NGTableViewDelegate {
    func tableView(_ tableView: NGTableView, backgroundColorForRow row: Int) -> NSColor? {
        row.isMultiple(of: 2) ? .systemGreen : nil
    }

    func tableView(_ tableView: NGTableView, markerColorForRow row: Int) -> NSColor? {
        row == 1 ? .systemRed : nil
    }
}

@MainActor
private final class CampaignListDataSource: NGTableViewDataSource {
    var ids: [String]
    var usesIdentifierMethod = false

    init(ids: [String]) {
        self.ids = ids
    }

    func numberOfRows(in tableView: NGTableView) -> Int { ids.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        column.id == "id" || column.id == "name" ? .text(ids[row]) : .number(Double(row))
    }

    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? {
        usesIdentifierMethod ? AnyHashable(ids[row]) : nil
    }
}

@MainActor
private final class MarkDataSource: NGTableViewDataSource {
    func numberOfRows(in tableView: NGTableView) -> Int { 10 }
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        switch column.id {
        case "mark": .mark(NGMark("star.fill", label: "Mark \(row)"))
        case "lead": .mark(NGMark("flag.fill", label: "Lead \(row)"))
        default: .text("Row \(row)")
        }
    }
}

/// Ad campaigns: spend and revenue per row, with ROI as reported per row.
@MainActor
private final class CampaignDataSource: NGTableViewDataSource {
    var spend: [Double] = [100, 10_000, 0]
    var revenue: [Double] = [300, 9_000, 0]
    var providesSpendAndRevenue = true

    func numberOfRows(in tableView: NGTableView) -> Int { spend.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        switch column.id {
        case "spend" where providesSpendAndRevenue: .number(spend[row])
        case "revenue" where providesSpendAndRevenue: .number(revenue[row])
        case "roi": .number(spend[row] > 0 ? (revenue[row] - spend[row]) / spend[row] : 0)
        default: .empty
        }
    }
}

@MainActor
private func makeTable(_ columns: [NGColumnItem], width: CGFloat = 600) -> (NGTableView, TestDataSource) {
    let dataSource = TestDataSource()
    let table = NGTableView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
    table.dataSource = dataSource
    table.columns = columns
    table.layoutSubtreeIfNeeded()
    return (table, dataSource)
}

/// An event AppKit didn't make.
private struct NoEvent: Error {}

@Suite("Table view")
@MainActor
struct NGTableViewTests {
    @Test func headerToolTipsFollowColumns() {
        let (table, _) = makeTable([
            .column(NGTableColumn("a", title: "A", width: 100, pin: .leading, toolTip: "Frozen")),
            .column(NGTableColumn("b", title: "B", width: 300)),
            .column(NGTableColumn("c", title: "C", width: 300, toolTip: "Scrolling")),
            .column(NGTableColumn("d", title: "D", width: 300)),
        ])
        var areas = table.headerToolTipAreas()
        #expect(areas.count == 2)
        #expect(areas.compactMap { table.headerToolTip(at: NSPoint(x: $0.midX, y: $0.midY)) } == ["Scrolling", "Frozen"])
        // Rounded rows add a 10pt margin before the first column.
        #expect(areas.first?.minX == 410)

        // Scrolled columns move with the content and are clipped by the frozen region.
        table.setContentOffset(CGPoint(x: 350, y: 0))
        areas = table.headerToolTipAreas()
        #expect(areas.first?.minX == 110)
        #expect(abs((areas.first?.maxX ?? 0) - 360) < 0.001)
    }

    @Test func hidingColumnsKeepsStateAndWidths() {
        let (table, dataSource) = makeTable([
            .column(NGTableColumn("a", title: "A", width: 100, pin: .leading)),
            .column(NGTableColumn("b", title: "B", width: 300)),
            .group(NGColumnGroup("g", title: "G", columns: [
                NGTableColumn("c", title: "C", width: 300, summary: .aggregate(.sum)),
                NGTableColumn("d", title: "D", width: 300),
            ])),
        ])
        table.setWidth(250, forColumnID: "c")
        table.selectRowIndexes([3, 4], byExtendingSelection: false)
        table.setContentOffset(CGPoint(x: 50, y: 100))

        table.hiddenColumnIDs = ["g"]
        #expect(table.columnLayout.allColumns.map(\.id) == ["a", "b"])
        #expect(table.summaryValue(forColumnID: "c") == nil)
        #expect(table.selectedRowIndexes == [3, 4])
        #expect(table.contentOffset.y == 100)

        table.hiddenColumnIDs = []
        #expect(table.width(ofColumnID: "c") == 250)
        #expect(table.summaryValue(forColumnID: "c") == Double((1...50).reduce(0, +)))

        let menu = table.makeColumnVisibilityMenu()
        #expect(menu?.items.map(\.title) == ["A", "B", "G", "C", "D"])
        #expect(menu?.items.map(\.indentationLevel) == [0, 0, 0, 1, 1])
        withExtendedLifetime(dataSource) {}
    }

    @Test func copiesSelectedRowsAsTabSeparatedText() {
        let (table, dataSource) = makeTable([
            .column(NGTableColumn("a", title: "A", pin: .leading)),
            .column(NGTableColumn("b", title: "B", format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
            .column(NGTableColumn("c", title: "C", pin: .trailing)),
            .column(NGTableColumn("d", title: "D")),
        ])
        table.hiddenColumnIDs = ["c"]
        // Display order: leading, scrolling, trailing; hidden columns are skipped.
        #expect(table.copyText(forRows: [2, 5]) == "a2\t3\td2\na5\t6\td5")
        withExtendedLifetime(dataSource) {}
    }

    /// Sizing a column to fit measures with the renderer's text shaper (the
    /// widths cells are drawn with); they are those of attributed strings.
    @Test func sizingToFitMeasuresLikeAttributedStrings() {
        let names = ["Campaign 12345 — Summer sale", "Кампания «Лето» № 5", "Crème brûlée", "東京タワー", "AVAST LTd", "WAVE Ty"]
        let dataSource = CopiedTextDataSource(names: names)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name"))]
        table.dataSource = dataSource
        #expect(table.metalRenderer != nil)
        table.sizeColumnToFit("name")
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = names.map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.max() ?? 0
        let title = NSAttributedString(string: "Name", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))])
            .size().width + 14
        #expect(table.width(ofColumnID: "name") == Double(ceil(max(widest, title) + 2 * NGMetrics.cellPadding + 2)))
        withExtendedLifetime(dataSource) {}
    }

    /// Tag widths for autofitting come from the text shaper (no Core Text
    /// for simple text) and equal the attributed strings' widths.
    @Test func tagsFitLikeAttributedStrings() throws {
        let shaper = try #require(NGMetalRenderer()).shaper
        for titles in [["Active"], ["Пауза", "Остановлена"], ["MGID", "Taboola", "Ёлка — 5"], ["東京", "Straße"]] {
            let tags = titles.map { NGTag($0, color: .green) }
            #expect(NGCellDrawing.fittingWidth(of: tags, shaper: shaper) == NGCellDrawing.fittingWidth(of: tags), "\(titles)")
        }
    }

    /// Tabs and line breaks in values become spaces; empty rows keep their line.
    @Test func copiedValuesStayInTheirCells() {
        let dataSource = CopiedTextDataSource(names: ["", "tab\there", "two\nlines", "crlf\r\nend", "Ёлка"])
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name"))]
        table.dataSource = dataSource
        // (A carriage return too: Excel would split the cell at it.)
        #expect(table.copyText(forRows: IndexSet(integersIn: 0..<5)) == "\ntab here\ntwo lines\ncrlf  end\nЁлка")
        withExtendedLifetime(dataSource) {}
    }

    @Test func autosavedLayoutIsRestored() {
        let name = "NGTableTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NGTableView Columns \(name)") }
        let items: [NGColumnItem] = [
            .column(NGTableColumn("a", title: "A")),
            .column(NGTableColumn("b", title: "B")),
            .column(NGTableColumn("c", title: "C")),
        ]
        let (table, dataSource) = makeTable(items)
        table.autosaveName = name
        table.applyReorderedColumns(NGColumnReorder.moving(.item(id: "c"), to: 0, in: table.columns))
        table.setWidth(222, forColumnID: "a")
        table.hiddenColumnIDs = ["b"]
        table.autosaveLayoutState()

        // A new table with the same autosave name, set before or after the columns.
        let (other, otherDataSource) = makeTable([])
        other.autosaveName = name
        other.columns = items
        #expect(other.columnLayout.allColumns.map(\.id) == ["c", "a"])
        #expect(other.width(ofColumnID: "a") == 222)
        #expect(other.hiddenColumnIDs == ["b"])

        let (third, thirdDataSource) = makeTable(items)
        third.autosaveName = name
        #expect(third.columnLayoutState == other.columnLayoutState)
        withExtendedLifetime((dataSource, otherDataSource, thirdDataSource)) {}
    }

    /// Like NSTableView: the sort is saved with the columns. A default sort set
    /// before the autosave name gives way to a saved one, and a data source set
    /// afterwards sorts by the restored sort.
    @Test func autosavedSortIsRestored() {
        final class SortingDataSource: NGTableViewDataSource {
            var sorts: [[String]] = []
            func numberOfRows(in tableView: NGTableView) -> Int { 3 }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .number(Double(row)) }
            func tableView(_ tableView: NGTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
                sorts.append(tableView.sortDescriptors.map { "\($0.key ?? "")\($0.ascending ? "↑" : "↓")" })
            }
        }
        let name = "NGTableTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NGTableView Columns \(name)") }
        let items: [NGColumnItem] = [.column(NGTableColumn("a", title: "A")), .column(NGTableColumn("b", title: "B"))]
        let defaultSort = [NSSortDescriptor(key: "a", ascending: true)]

        // Nothing saved yet: the default sort stays, and clicks are saved.
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = items
        table.sortDescriptors = defaultSort
        table.autosaveName = name
        #expect(table.sortDescriptors == defaultSort)
        table.sortByClicking(NGTableColumn("b", title: "B"))
        table.sortByClicking(NGTableColumn("b", title: "B"))

        // The next session: the saved sort replaces the default, and the
        // data source set afterwards sorts by it.
        let next = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        next.columns = items
        next.sortDescriptors = defaultSort
        next.autosaveName = name
        #expect(next.sortDescriptors.map(\.key) == ["b", "a"])
        #expect(next.sortDescriptors.first?.ascending == false)
        let dataSource = SortingDataSource()
        next.dataSource = dataSource
        #expect(dataSource.sorts == [["b↓", "a↑"]])

        // An empty sort is saved too: the default doesn't come back.
        next.sortDescriptors = []
        let third = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        third.columns = items
        third.sortDescriptors = defaultSort
        third.autosaveName = name
        #expect(third.sortDescriptors.isEmpty)
        withExtendedLifetime(dataSource) {}
    }

    @Test func commandClicksToggleRowsEvenWhenFastOrMoved() throws {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A", width: 300))])
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        table.layoutSubtreeIfNeeded()

        func event(_ type: NSEvent.EventType, row: Int, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1, dy: CGFloat = 0) throws -> NSEvent {
            // Window coordinates have their origin at the bottom left.
            let y = table.bounds.height - (table.layoutMetrics.headerHeight + CGFloat(row) * table.rowHeight + table.rowHeight / 2 + dy)
            return try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 100, y: y), modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
            ))
        }
        func click(_ row: Int, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1, jitter: Bool = false) throws {
            table.rowsMouseDown(try event(.leftMouseDown, row: row, modifiers: modifiers, clickCount: clickCount), in: table.centerRegion)
            if jitter {
                // A trackpad click that moves slightly sends a drag.
                table.rowsMouseDragged(try event(.leftMouseDragged, row: row, modifiers: modifiers, clickCount: clickCount, dy: 2))
            }
            table.rowsMouseUp(try event(.leftMouseUp, row: row, modifiers: modifiers, clickCount: clickCount))
        }

        try click(1)
        try click(3, modifiers: .command, jitter: true)
        try click(5, modifiers: .command, jitter: true)
        #expect(table.selectedRowIndexes == [1, 3, 5])

        // Fast Command-clicks on the same row arrive as a double click and still toggle.
        try click(7, modifiers: .command)
        try click(7, modifiers: .command, clickCount: 2)
        #expect(table.selectedRowIndexes == [1, 3, 5])

        // A jittery Command-click that deselects keeps the other rows.
        try click(3, modifiers: .command, jitter: true)
        #expect(table.selectedRowIndexes == [1, 5])
        withExtendedLifetime(dataSource) {}
    }

    @Test func formulaUsesColumnsOutsideTheTableAndFallsBack() {
        let roi = NGSummaryFormula("roi", using: ["spend", "revenue"], otherwise: .average, including: .nonZero) { values in
            guard let spend = values.sum("spend"), spend != 0, let revenue = values.sum("revenue") else { return nil }
            return (revenue - spend) / spend
        }
        let dataSource = CampaignDataSource()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.dataSource = dataSource
        // Only the ROI column is in the table; spend and revenue come from the data source.
        table.columns = [.column(NGTableColumn("roi", title: "ROI", format: .percent(fractionDigits: 1), summary: .formula(roi)))]
        #expect(abs((table.summaryValue(forColumnID: "roi") ?? 0) - (9_300.0 - 10_100) / 10_100) < 1e-9)

        table.summaryScope = .selectedRows
        table.selectRowIndexes([0], byExtendingSelection: false)
        #expect(table.summaryValue(forColumnID: "roi") == 2)

        // Without spend and revenue: the average of non-zero ROI (+200% and −10%).
        dataSource.providesSpendAndRevenue = false
        table.summaryScope = .allRows
        table.reloadData()
        #expect(abs((table.summaryValue(forColumnID: "roi") ?? 0) - 0.95) < 1e-9)
        // Selecting only the 0% campaign leaves nothing to average.
        table.summaryScope = .selectedRows
        table.selectRowIndexes([2], byExtendingSelection: false)
        #expect(table.summaryValue(forColumnID: "roi") == nil)
    }

    @Test func arrowsScrollByColumnAndTypingSelects() {
        let (table, dataSource) = makeTable([
            .column(NGTableColumn("a", title: "A", width: 100, pin: .leading)),
            .column(NGTableColumn("b", title: "B", width: 300)),
            .column(NGTableColumn("c", title: "C", width: 300)),
            .column(NGTableColumn("d", title: "D", width: 300)),
        ])
        table.moveRight(nil)
        #expect(table.contentOffset.x == 300)
        table.moveRight(nil)
        #expect(table.contentOffset.x == table.layoutMetrics.maxOffset.x)
        table.moveLeft(nil)
        #expect(table.contentOffset.x == 300)
        table.moveLeft(nil)
        #expect(table.contentOffset.x == 0)

        // Values of the first column are "a0" … "a49".
        table.insertText("A1")
        #expect(table.selectedRowIndexes == [1])
        table.insertText("7")
        #expect(table.selectedRowIndexes == [17])
        #expect(table.typeSelectMatch(for: "zz") == nil)
        withExtendedLifetime(dataSource) {}
    }

    @Test func reloadDropsSelectionAnchorsPastTheEnd() {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        table.selectRowIndexes([40], byExtendingSelection: false)
        dataSource.rowCount = 10
        table.reloadData()
        #expect(table.selectedRowIndexes.isEmpty)
        // Extending from the old anchor (row 40) would select rows that don't exist.
        table.moveDownAndModifySelection(nil)
        #expect(table.selectedRowIndexes.allSatisfy { $0 < 10 })
        #expect(!table.copyText(forRows: table.selectedRowIndexes).isEmpty)
    }

    @Test func formulaWithRepeatedInputs() {
        let formula = NGSummaryFormula("twice", using: ["a", "a"]) { $0.sum("a") }
        let (table, dataSource) = makeTable([
            .column(NGTableColumn("a", title: "A", format: .number(fractionDigits: 0))),
            .column(NGTableColumn("f", title: "F", summary: .formula(formula))),
        ])
        #expect(table.summaryValue(forColumnID: "f") == Double((1...50).reduce(0, +)))
        withExtendedLifetime(dataSource) {}
    }

    @Test func zeroRowHeightIsClamped() {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        table.rowHeight = 0
        #expect(table.rowHeight == 1)
        withExtendedLifetime(dataSource) {}
    }

    @Test func accessibilityElementsSurviveReload() {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        let row = table.accessibilityRowElement(30)
        let cell = (row.accessibilityChildren() as? [NGAccessibilityCell])?.first
        dataSource.rowCount = 5
        table.reloadData()
        // A stale element (e.g. still focused by VoiceOver) must not ask for row 30.
        #expect(cell?.accessibilityValue() == nil)
        #expect(row.accessibilityFrame() == .zero)
        withExtendedLifetime(dataSource) {}
    }

    /// VoiceOver keeps its element through a value-only update (it reads the
    /// new value), and gets new ones when rows moved.
    @Test func accessibilityElementsStayThroughValueUpdates() {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        let row = table.accessibilityRowElement(3)
        let cell = (row.accessibilityChildren() as? [NGAccessibilityCell])?.first
        #expect(cell?.accessibilityValue() as? String == "a3")
        dataSource.constantValue = .text("changed")
        table.beginUpdates()
        table.reloadData(forRowIndexes: [3], columnIndexes: [0])
        table.endUpdates()
        #expect(table.accessibilityRowElement(3) === row)
        #expect(cell?.accessibilityValue() as? String == "changed")
        // A move: the cached elements are dropped.
        table.beginUpdates()
        table.moveRow(at: 3, to: 0)
        table.endUpdates()
        #expect(table.accessibilityRowElement(3) !== row)
        withExtendedLifetime(dataSource) {}
    }

    @Test func contextMenuRowsFollowFinder() throws {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A", width: 300))])
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        let delegate = MenuDelegate()
        table.delegate = delegate

        func rightClick(row: Int) throws -> NSMenu? {
            let y = table.bounds.height - (table.layoutMetrics.headerHeight + CGFloat(row) * table.rowHeight + table.rowHeight / 2)
            let event = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 100, y: y), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            return table.rowsMenu(for: event, in: table.centerRegion)
        }

        table.selectRowIndexes([1, 2], byExtendingSelection: false)
        // Inside the selection: the menu is for all selected rows.
        _ = try rightClick(row: 2)
        #expect(delegate.lastRows == [1, 2])
        #expect(table.clickedRow == 2)
        #expect(table.menuOutline == nil)

        // Another row: only that row, outlined, and the selection stays.
        _ = try rightClick(row: 5)
        #expect(delegate.lastRows == [5])
        #expect(table.selectedRowIndexes == [1, 2])
        #expect(table.menuOutline != nil)
        table.rowsMenuDidClose()
        #expect(table.menuOutline == nil)

        // Below the last row: no rows.
        dataSource.rowCount = 3
        table.reloadData()
        _ = try rightClick(row: 8)
        #expect(delegate.lastRows == [])
        #expect(table.clickedRow == -1)
    }

    @Test func rowTintsAndMarkers() {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        let delegate = TintDelegate()
        table.delegate = delegate
        #expect(table.rowColor(0) == .systemGreen)
        // Selection wins over the tint.
        table.selectRowIndexes([0], byExtendingSelection: false)
        #expect(table.rowColor(0) != .systemGreen)
        // Filler rows below the data keep the stripes.
        #expect(table.rowColor(60) != .systemGreen)
        table.reloadData()
        #expect(table.rowBackgroundMarkerColors()[1] == .systemRed)
        #expect(table.rowBackgroundMarkerColors()[2] == nil)
        withExtendedLifetime((dataSource, delegate)) {}
    }

    /// Without any data the table shows only its empty state: no header,
    /// stripes or summary row, for the eye or VoiceOver.
    @Test func emptyStateShowsWithoutRows() {
        let (table, dataSource) = makeTable([
            .column(NGTableColumn("lead", title: "L", pin: .leading)),
            .column(NGTableColumn("a", title: "A")),
            .column(NGTableColumn("n", title: "N", summary: .aggregate(.sum), pin: .trailing)),
        ])
        table.emptyStateText = "Nothing here"
        #expect(table.visibleEmptyStateView == nil)
        dataSource.rowCount = 0
        table.reloadData()
        let label = table.visibleEmptyStateView as? NSTextField
        #expect(label?.stringValue == "Nothing here")
        // Centered in the whole table.
        if let frame = label?.frame {
            #expect(abs(frame.midX - table.bounds.midX) <= 1)
            #expect(abs(frame.midY - table.bounds.midY) <= 1)
        }
        #expect(table.headerView.isHidden)
        #expect(table.headerBackground.isHidden)
        #expect(table.regions.allSatisfy { $0.isHidden })
        #expect(table.summaryBar.isHidden)
        #expect(table.accessibilityColumnHeaderUIElements()?.isEmpty == true)
        #expect(table.accessibilityChildren()?.count == 1)
        // A custom view replaces the text.
        let custom = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        table.emptyStateView = custom
        table.layoutSubtreeIfNeeded()
        #expect(table.visibleEmptyStateView === custom)
        // Data brings the grid back.
        dataSource.rowCount = 5
        table.reloadData()
        #expect(table.visibleEmptyStateView == nil)
        #expect(!table.headerView.isHidden)
        #expect(table.regions.allSatisfy { !$0.isHidden })
        #expect(!table.summaryBar.isHidden)
        #expect(table.layoutMetrics.headerHeight == table.headerRowHeight)
    }

    /// A filter that hides every row keeps the columns in view: the empty
    /// state shows in the rows area.
    @Test func emptyStateWithEveryRowFilteredKeepsTheGrid() {
        let (table, dataSource) = makeTable([
            .column(NGTableColumn("a", title: "A")),
            .column(NGTableColumn("n", title: "N", summary: .aggregate(.sum))),
        ])
        table.emptyStateText = "No matches"
        table.rowFilter = NGRowFilter(searchText: "nothing like this")
        #expect(table.numberOfRows == 0)
        let label = table.visibleEmptyStateView as? NSTextField
        #expect(label?.stringValue == "No matches")
        if let frame = label?.frame {
            #expect(frame.minY > table.layoutMetrics.headerHeight)
            #expect(frame.maxY < table.summaryBar.frame.minY)
        }
        #expect(!table.headerView.isHidden)
        #expect(!table.centerRegion.isHidden)
        #expect(!table.summaryBar.isHidden)
        withExtendedLifetime(dataSource) {}
    }

    /// While the data updates, the spinner replaces the empty state (once it
    /// fades in, so quick updates don't flash), and it comes back after.
    @Test func emptyStateGivesWayToDataUpdates() {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        table.emptyStateText = "Nothing here"
        dataSource.rowCount = 0
        table.reloadData()
        #expect(table.visibleEmptyStateView != nil)

        table.isUpdatingData = true
        table.layoutSubtreeIfNeeded()
        #expect(table.visibleEmptyStateView != nil)
        // The spinner centers in the table too, there being no header or summary.
        #expect(abs(table.dataUpdateOverlay.indicatorCenter.y - table.bounds.midY) <= 1)
        // Until the spinner fades in (a run loop timer; tests alongside may
        // hold the main thread past its delay).
        func runLoop(until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                table.layoutSubtreeIfNeeded()
            } while !done() && Date() < deadline
        }
        runLoop { table.visibleEmptyStateView == nil }
        #expect(table.visibleEmptyStateView == nil)

        // Still no rows after the update: the empty state is back at once.
        table.isUpdatingData = false
        table.layoutSubtreeIfNeeded()
        #expect(table.visibleEmptyStateView != nil)

        // An update that brings rows leaves no empty state behind.
        table.isUpdatingData = true
        runLoop { table.isDataUpdateVeiled }
        dataSource.rowCount = 5
        table.reloadData()
        table.isUpdatingData = false
        table.layoutSubtreeIfNeeded()
        #expect(table.visibleEmptyStateView == nil)
    }

    @Test func rowFilterKeepsDataSourceIndexes() {
        let (table, dataSource) = makeTable([
            .column(NGTableColumn("a", title: "A")),
            .column(NGTableColumn("n", title: "N", format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
        ])
        table.selectRowIndexes([4, 14, 20], byExtendingSelection: false)

        // Rows "a4", "a14", "a24", "a34", "a40"…"a49" contain "4".
        table.rowFilter = NGRowFilter(searchText: "A4")
        #expect(table.numberOfSourceRows == 50)
        #expect(table.numberOfRows == 1 + 10)
        // The selection keeps the visible rows, in data source indexes.
        #expect(table.selectedRowIndexes == [4])
        // Summaries cover the rows shown: (4+1) + (40+1)…(49+1).
        #expect(table.summaryValue(forColumnID: "n") == Double(5 + (41...50).reduce(0, +)))
        // Data source rows go in and out of the API.
        table.selectRowIndexes([44, 7], byExtendingSelection: false)
        #expect(table.selectedRowIndexes == [44])
        #expect(table.copyText(forRows: table.selectedRowIndexes) == "a44\t45")

        // A predicate on data source rows combines with the search.
        // Words match from their beginning, like in Finder: 4, 40, 42, 44, 46, 48.
        table.rowFilter = NGRowFilter(searchText: "a4", isIncluded: { $0.isMultiple(of: 2) })
        #expect(table.numberOfRows == 6)
        #expect(table.selectedRowIndexes == [44])

        table.rowFilter = nil
        #expect(table.numberOfRows == 50)
        #expect(table.selectedRowIndexes == [44])
        withExtendedLifetime(dataSource) {}
    }

    /// Scrolling must only read the cells of rows that come into view.
    @Test func scrollingOnlyReadsNewRows() {
        let frame = NSRect(x: 0, y: 0, width: 2400, height: 1400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let dataSource = TestDataSource()
        dataSource.rowCount = 2000
        let table = NGTableView(frame: frame)
        window.contentView = table
        table.columns = (0..<20).map { .column(NGTableColumn("c\($0)", title: "C\($0)", width: 110)) }
        table.dataSource = dataSource
        window.orderFront(nil)
        window.displayIfNeeded()
        CATransaction.flush()

        dataSource.valueRequests = 0
        let steps = 20
        for step in 1...steps {
            table.setContentOffset(CGPoint(x: 0, y: CGFloat(step) * 12))
            window.displayIfNeeded()
            CATransaction.flush()
        }
        // 12pt steps bring in a new row (20 cells) every other step.
        #expect(dataSource.valueRequests <= steps * 20)
        #expect(dataSource.valueRequests > 0)
        window.orderOut(nil)
    }

    @Test func fixedColumnsStayInPlace() {
        let items: [NGColumnItem] = [
            .column(NGTableColumn("mark", title: "", isMovable: false)),
            .column(NGTableColumn("a", title: "A")),
            .column(NGTableColumn("b", title: "B")),
        ]
        // Fixed columns are left out like hidden ones: others can't pass them.
        let moved = NGColumnReorder.moving(.item(id: "b"), to: 0, in: items, hiddenIDs: ["mark"])
        #expect(moved.map(\.id) == ["mark", "b", "a"])
    }

    @Test(arguments: [false, true]) func selectionFollowsRowIdentity(usesMethod: Bool) {
        let dataSource = CampaignListDataSource(ids: ["a", "b", "c", "d", "e"])
        dataSource.usesIdentifierMethod = usesMethod
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name"))]
        if !usesMethod {
            // The id column is not shown; the data source answers it anyway.
            table.rowIdentifierColumnID = "id"
        }
        table.dataSource = dataSource
        table.selectRowIndexes([1, 3], byExtendingSelection: false)  // b, d

        // The data comes again in another order, with "c" gone and "x" new.
        dataSource.ids = ["x", "d", "a", "e", "b"]
        table.reloadData()
        #expect(table.selectedRowIndexes == [1, 4])
        // Shift-extending continues from the same campaigns: the anchor "b" (now
        // row 4) to one above the cursor "d" (now row 1) is every row.
        table.moveUpAndModifySelection(nil)
        #expect(table.selectedRowIndexes == IndexSet(0...4))

        // A selected campaign that disappears leaves the selection.
        table.selectRowIndexes([3, 4], byExtendingSelection: false)  // e, b
        dataSource.ids = ["x", "a", "e"]
        table.reloadData()
        #expect(table.selectedRowIndexes.map { dataSource.ids[$0] } == ["e"])
        withExtendedLifetime(dataSource) {}
    }

    @Test func withoutIdentityTheSelectionKeepsIndexes() {
        let dataSource = CampaignListDataSource(ids: ["a", "b", "c"])
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name"))]
        table.dataSource = dataSource
        table.selectRowIndexes([1], byExtendingSelection: false)
        dataSource.ids = ["c", "a", "b"]
        table.reloadData()
        #expect(table.selectedRowIndexes == [1])
        withExtendedLifetime(dataSource) {}
    }

    @Test func largeSummariesAreComputedInTheBackground() async throws {
        let dataSource = TestDataSource()
        dataSource.rowCount = 20_000
        let delegate = SummaryUpdateDelegate()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.delegate = delegate
        table.columns = [.column(NGTableColumn("n", title: "N", format: .number(fractionDigits: 0), summary: .aggregate(.sum)))]
        table.synchronousSummaryLimit = 1_000
        table.dataSource = dataSource

        // The rows are there at once; the summary follows.
        #expect(table.numberOfRows == 20_000)
        #expect(table.isComputingSummary)
        try await waitForSummary(of: table)
        #expect(table.summaryValue(forColumnID: "n") == Double((1...20_000).reduce(0, +)))
        #expect(delegate.updates == 1)

        // A reload during a computation: only the latest data counts, and the
        // previous total stays shown meanwhile.
        dataSource.rowCount = 15_000
        table.reloadData()
        dataSource.rowCount = 10_000
        table.reloadData()
        #expect(table.summaryValue(forColumnID: "n") == Double((1...20_000).reduce(0, +)))
        try await waitForSummary(of: table)
        #expect(table.summaryValue(forColumnID: "n") == Double((1...10_000).reduce(0, +)))
        #expect(delegate.updates == 2)

        // Small tables compute right away.
        table.synchronousSummaryLimit = 50_000
        dataSource.rowCount = 100
        table.reloadData()
        #expect(!table.isComputingSummary)
        #expect(table.summaryValue(forColumnID: "n") == Double((1...100).reduce(0, +)))
        withExtendedLifetime((dataSource, delegate)) {}
    }

    @Test func slowSummariesShowProgress() async throws {
        let dataSource = SlowDataSource()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("n", title: "N", summary: .aggregate(.sum)))]
        table.synchronousSummaryLimit = 1_000
        table.dataSource = dataSource
        #expect(table.isComputingSummary)
        // Not at once: quick computations don't flash a spinner.
        #expect(!table.isSummaryProgressVisible)
        // Tests run in parallel, so wait for it rather than for a fixed time.
        try await waitWhile { !table.isSummaryProgressVisible && table.isComputingSummary }
        #expect(table.isSummaryProgressVisible)
        try await waitForSummary(of: table)
        #expect(!table.isSummaryProgressVisible)
        #expect(table.summaryValue(forColumnID: "n") == 20_000)
        withExtendedLifetime(dataSource) {}
    }

    @Test func showingAColumnDuringABackgroundComputationKeepsEverySummary() async throws {
        let dataSource = TestDataSource()
        dataSource.rowCount = 20_000
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("a", title: "A", format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
            .column(NGTableColumn("b", title: "B", format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
        ]
        table.hiddenColumnIDs = ["b"]
        table.synchronousSummaryLimit = 1_000
        table.dataSource = dataSource
        #expect(table.isComputingSummary)
        // Showing "b" meanwhile used to leave "a" blank for good.
        table.hiddenColumnIDs = []
        try await waitForSummary(of: table)
        let total = Double((1...20_000).reduce(0, +))
        #expect(table.summaryValue(forColumnID: "a") == total)
        #expect(table.summaryValue(forColumnID: "b") == total)
        withExtendedLifetime(dataSource) {}
    }

    @Test func selectionScopesShowNothingWhileRecomputing() async throws {
        let dataSource = TestDataSource()
        dataSource.rowCount = 20_000
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("a", title: "A", format: .number(fractionDigits: 0), summary: .aggregate(.sum)))]
        table.synchronousSummaryLimit = 1_000
        table.dataSource = dataSource
        try await waitForSummary(of: table)
        table.summaryScope = .selectedRows
        table.selectRowIndexes([0, 1], byExtendingSelection: false)
        #expect(table.summaryValue(forColumnID: "a") == 3)
        // The rows change: until recomputed, old sums of the selection would be wrong.
        dataSource.rowCount = 15_000
        table.reloadData()
        #expect(table.summaryValue(forColumnID: "a") == nil)
        try await waitForSummary(of: table)
        #expect(table.summaryValue(forColumnID: "a") == 3)
        withExtendedLifetime(dataSource) {}
    }

    @Test func rowsSharingAnIdentityAreSelectedTogether() {
        let dataSource = CampaignListDataSource(ids: ["a", "b", "a", "c"])
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("name", title: "Name"))]
        table.rowIdentifierColumnID = "id"
        table.dataSource = dataSource
        table.selectRowIndexes([0], byExtendingSelection: false)
        dataSource.ids = ["c", "a", "b", "a"]
        table.reloadData()
        #expect(table.selectedRowIndexes == [1, 3])

        // Without identities the selection stays on the same rows.
        table.rowIdentifierColumnID = nil
        dataSource.ids = ["a", "b", "c", "d"]
        table.reloadData()
        #expect(table.selectedRowIndexes == [1, 3])
        withExtendedLifetime(dataSource) {}
    }

    @Test func searchFollowsShownColumnsUnlessListed() {
        let (table, dataSource) = makeTable([
            .column(NGTableColumn("a", title: "A")),
            .column(NGTableColumn("b", title: "B")),
        ])
        // Every row has "b<row>" in column B.
        table.rowFilter = NGRowFilter(searchText: "b1")
        #expect(table.numberOfRows == 11)
        // Hiding the column searched filters again.
        table.hiddenColumnIDs = ["b"]
        #expect(table.numberOfRows == 0)
        table.hiddenColumnIDs = []
        #expect(table.numberOfRows == 11)
        // Columns listed explicitly are searched even when hidden.
        table.hiddenColumnIDs = ["b"]
        table.rowFilter = NGRowFilter(searchText: "b1", columnIDs: ["b"])
        #expect(table.numberOfRows == 11)
        withExtendedLifetime(dataSource) {}
    }

    @Test func selectAllAnchorsAtTheTop() {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        table.selectAll(nil)
        table.moveUpAndModifySelection(nil)
        #expect(table.selectedRowIndexes == IndexSet(0...48))
        withExtendedLifetime(dataSource) {}
    }

    @Test func typingTheSameLetterAgainMovesToTheNextMatch() {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        table.selectRowIndexes([3], byExtendingSelection: false)
        table.moveDown(nil)  // Sets the cursor on row 4.
        #expect(table.typeSelectMatch(for: "a", continuing: true) == 4)
        #expect(table.typeSelectMatch(for: "a", continuing: false) == 5)
        withExtendedLifetime(dataSource) {}
    }

    @Test func reloadForgetsTheClickedRow() throws {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        table.clickedRow = 3
        table.reloadData()
        #expect(table.clickedRow == -1)
        table.clickedRow = 3
        table.rowFilter = NGRowFilter(searchText: "a")
        #expect(table.clickedRow == -1)
        withExtendedLifetime(dataSource) {}
    }

    @Test func overlayScrollersDoNotOverlap() {
        let (table, dataSource) = makeTable([
            .column(NGTableColumn("a", title: "A", width: 400)),
            .column(NGTableColumn("b", title: "B", width: 400)),
        ])
        #expect(table.layoutMetrics.maxOffset.y > 0)
        #expect(table.horizontalOverlayScroller.frame.maxX <= table.verticalOverlayScroller.frame.minX)
        withExtendedLifetime(dataSource) {}
    }

    @Test func menuOutlineFollowsScrolling() {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        table.showMenuOutline(forRow: 5)
        let y = table.menuOutline?.frame.minY ?? 0
        table.setContentOffset(CGPoint(x: 0, y: 40))
        #expect(table.menuOutline?.frame.minY == y - 40)
        table.rowsMenuDidClose()
        table.setContentOffset(CGPoint(x: 0, y: 0))
        #expect(table.menuOutline == nil)
        withExtendedLifetime(dataSource) {}
    }

    @Test func marksExplainThemselvesInEveryRegion() {
        let dataSource = MarkDataSource()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("lead", title: "", width: 30, pin: .leading)),
            .column(NGTableColumn("name", title: "Name", width: 200)),
            .column(NGTableColumn("mark", title: "", width: 30)),
        ]
        table.dataSource = dataSource
        table.layoutSubtreeIfNeeded()
        let center = table.geometry.center.columns.first { $0.column.id == "mark" }!
        let lead = table.geometry.leading.columns[0]
        let y = table.rowHeight * 2.5
        #expect(table.cellToolTip(at: NSPoint(x: center.x + 10, y: y), in: table.regions[1]) == "Mark 2")
        #expect(table.cellToolTip(at: NSPoint(x: lead.x + 10, y: y), in: table.regions[0]) == "Lead 2")
        #expect(table.cellToolTip(at: NSPoint(x: center.x - 50, y: y), in: table.regions[1]) == nil)
        withExtendedLifetime(dataSource) {}
    }

    /// The resize cursor follows the column edges as the columns scroll,
    /// without cursor rects.
    @Test func resizeCursorFollowsScrolledEdges() {
        let (table, dataSource) = makeTable([
            .column(NGTableColumn("a", title: "A", width: 200)),
            .column(NGTableColumn("b", title: "B", width: 300)),
            .column(NGTableColumn("c", title: "C", width: 300, isResizable: false)),
        ])
        let y = table.headerRowHeight / 2
        let edge = CGFloat(table.geometry.center.columns[0].maxX) - table.layoutMetrics.leadingWidth
        #expect(table.resizeCursor(at: NSPoint(x: edge, y: y)) != nil)
        #expect(table.resizeCursor(at: NSPoint(x: edge - 40, y: y)) == nil)
        table.setContentOffset(CGPoint(x: 50, y: 0))
        #expect(table.resizeCursor(at: NSPoint(x: edge, y: y)) == nil)
        #expect(table.resizeCursor(at: NSPoint(x: edge - 50, y: y)) != nil)
        withExtendedLifetime(dataSource) {}
    }

    /// Tool tip areas cover just the hovered item, so AppKit hides a tool tip
    /// as soon as the pointer leaves it.
    @Test func toolTipAreasCoverTheHoveredItem() {
        let dataSource = MarkDataSource()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [
            .column(NGTableColumn("lead", title: "", width: 30, pin: .leading, toolTip: "Lead")),
            .column(NGTableColumn("name", title: "Name", width: 200)),
            .column(NGTableColumn("mark", title: "", width: 30)),
        ]
        table.dataSource = dataSource
        table.layoutSubtreeIfNeeded()
        let mark = table.geometry.center.columns.first { $0.column.id == "mark" }!
        let point = NSPoint(x: mark.x + 10, y: table.rowHeight * 2.5)
        #expect(table.cellToolTipFrame(at: point, in: table.regions[1])
            == NSRect(x: CGFloat(mark.x), y: table.rowHeight * CGFloat(2), width: CGFloat(mark.width), height: table.rowHeight))
        #expect(table.cellToolTipFrame(at: NSPoint(x: mark.x - 50, y: point.y), in: table.regions[1]) == nil)

        let y = table.headerRowHeight / 2
        let lead = table.geometry.leading.columns[0]
        #expect(table.headerToolTipRect(at: NSPoint(x: lead.x + 5, y: y))?.width == CGFloat(lead.width))
        #expect(table.headerToolTipRect(at: NSPoint(x: 150, y: y)) == nil)
        withExtendedLifetime(dataSource) {}
    }

    /// While the data updates, the table ignores the user; afterwards it works as before.
    @Test func updatingDataBlocksInteraction() throws {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A", width: 200))])
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        table.selectRowIndexes([2], byExtendingSelection: false)
        let rowPoint = NSPoint(x: 100, y: table.layoutMetrics.headerHeight + table.rowHeight * 5.5)
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let arrowDown = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
                                                      charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))

        table.isUpdatingData = true
        #expect(table.hitTest(table.convert(rowPoint, to: table.superview)) === table.dataUpdateOverlay)
        table.keyDown(with: arrowDown)
        #expect(table.selectedRowIndexes == [2])
        #expect(!table.validateMenuItem(copyItem))
        #expect(table.columnResizeCursorRects().isEmpty)

        table.isUpdatingData = false
        #expect(table.hitTest(table.convert(rowPoint, to: table.superview)) !== table.dataUpdateOverlay)
        table.keyDown(with: arrowDown)
        #expect(table.selectedRowIndexes == [3])
        #expect(table.validateMenuItem(copyItem))
        #expect(!table.columnResizeCursorRects().isEmpty)
        withExtendedLifetime(dataSource) {}
    }

    /// Overlapping updates keep the state until the last one ends, also when one throws.
    @Test func overlappingUpdatesEndTogether() async throws {
        struct Failure: Error {}
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        var first: CheckedContinuation<Void, Never>?
        let firstUpdate = Task { @MainActor in
            await table.updatingData {
                await withCheckedContinuation { first = $0 }
            }
        }
        while first == nil { await Task.yield() }
        #expect(table.isDataUpdateActive)
        await #expect(throws: Failure.self) {
            try await table.updatingData { throw Failure() }
        }
        #expect(table.isDataUpdateActive)
        first?.resume()
        await firstUpdate.value
        #expect(!table.isDataUpdateActive)
        withExtendedLifetime(dataSource) {}
    }

    /// The spinner shows by default; the caption follows `dataUpdateText`, also mid-update.
    @Test func dataUpdateShowsSpinnerAndCaption() {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        #expect(table.showsDataUpdateIndicator)
        table.dataUpdateText = "Loading 18,000 campaigns…"
        table.isUpdatingData = true
        #expect(table.dataUpdateOverlay.text == "Loading 18,000 campaigns…")
        table.dataUpdateText = "Loaded 12,000 of 18,000…"
        #expect(table.dataUpdateOverlay.text == "Loaded 12,000 of 18,000…")
        table.isUpdatingData = false
        withExtendedLifetime(dataSource) {}
    }

    /// A space that doesn't continue a type select search goes on to the next
    /// responder (e.g. for Quick Look); within a search it's part of it.
    @Test func spaceGoesToTheNextResponderOutsideTypeSelect() throws {
        final class Container: NSView {
            var keys: [String] = []
            override func keyDown(with event: NSEvent) { keys.append(event.charactersIgnoringModifiers ?? "") }
        }
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let container = Container(frame: frame)
        window.contentView = container
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A", width: 200))])
        container.addSubview(table)
        func key(_ characters: String, code: UInt16) throws -> NSEvent {
            // (Optional in older SDKs, not in newer ones, where `#require` warns.)
            let event: NSEvent? = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            guard let event else { throw NoEvent() }
            return event
        }
        table.keyDown(with: try key(" ", code: 49))
        #expect(container.keys == [" "])
        // Values are "a0" … "a49": "a" starts a search, the space is part of it.
        table.keyDown(with: try key("a", code: 0))
        table.keyDown(with: try key(" ", code: 49))
        #expect(container.keys == [" "])
        // While updating, the table leaves keys to the app.
        table.isUpdatingData = true
        table.keyDown(with: try key("\u{F701}", code: 125))
        #expect(container.keys == [" ", "\u{F701}"])
        table.isUpdatingData = false
        withExtendedLifetime(dataSource) {}
    }

    @Test func framesOfVisibleCells() {
        let (table, dataSource) = makeTable([
            .column(NGTableColumn("lead", title: "L", width: 100, pin: .leading)),
            .column(NGTableColumn("b", title: "B", width: 300)),
            .column(NGTableColumn("c", title: "C", width: 300)),
            .column(NGTableColumn("d", title: "D", width: 300)),
        ])
        let top = table.layoutMetrics.headerHeight
        let lead = table.frameOfCell(row: 2, columnID: "lead")
        #expect(lead?.minY == top + table.rowHeight * 2)
        #expect(lead?.height == table.rowHeight)
        #expect(lead?.width == CGFloat(table.width(ofColumnID: "lead") ?? 0))
        let b = table.frameOfCell(row: 2, columnID: "b")
        #expect(b.map { abs($0.minX - (lead?.maxX ?? 0)) < 1 } == true)
        // Scrolled out of view, below the rows shown, hidden or unknown: nil.
        #expect(table.frameOfCell(row: 45, columnID: "b") == nil)
        #expect(table.frameOfCell(row: 2, columnID: "d") == nil)
        table.setContentOffset(CGPoint(x: 400, y: 0))
        #expect(table.frameOfCell(row: 2, columnID: "d") != nil)
        #expect(table.frameOfCell(row: 2, columnID: "lead") == lead)
        table.hiddenColumnIDs = ["d"]
        #expect(table.frameOfCell(row: 2, columnID: "d") == nil)
        table.rowFilter = NGRowFilter(isIncluded: { $0 != 2 })
        #expect(table.frameOfCell(row: 2, columnID: "lead") == nil)
        #expect(table.frameOfCell(row: 60, columnID: "nope") == nil)
        withExtendedLifetime(dataSource) {}
    }

    /// Leading and trailing follow the interface's direction, not the text's.
    @Test func alignmentFollowsTheLayoutDirection() {
        for (alignment, numeric, ltr, rtl) in [
            (NGColumnAlignment.leading, false, NSTextAlignment.left, NSTextAlignment.right),
            (.trailing, false, .right, .left),
            (.center, false, .center, .center),
            (.automatic, true, .right, .left),
            (.automatic, false, .left, .right),
        ] {
            #expect(alignment.textAlignment(isNumeric: numeric, layoutDirection: .leftToRight) == ltr)
            #expect(alignment.textAlignment(isNumeric: numeric, layoutDirection: .rightToLeft) == rtl)
        }
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        let column = NGTableColumn("a", title: "A")
        #expect(table.cellContent(for: .text("Mail"), in: column).alignment == .left)
        // Right to left, content is laid out left to right and mirrored when
        // drawn (NGRightToLeft.swift): leading still reads .left here, and
        // shows at the right (see NGRightToLeftTests).
        table.userInterfaceLayoutDirection = .rightToLeft
        #expect(table.cellContent(for: .text("Mail"), in: column).alignment == .left)
        withExtendedLifetime(dataSource) {}
    }

    /// Like NSTableView: every change of the sort descriptors, from a header
    /// click or from code, goes to the data source with the previous ones.
    @Test func sortDescriptorsGoToTheDataSource() {
        final class SortingDataSource: NGTableViewDataSource {
            var changes: [[NSSortDescriptor]] = []
            func numberOfRows(in tableView: NGTableView) -> Int { 3 }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .number(Double(row)) }
            func tableView(_ tableView: NGTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
                changes.append(oldDescriptors)
            }
        }
        let dataSource = SortingDataSource()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var amount = NGTableColumn("b", title: "B")
        amount.sortDescriptorPrototype = NSSortDescriptor(key: "amount", ascending: false)
        table.columns = [.column(NGTableColumn("a", title: "A")), .column(amount),
                         .column(NGTableColumn("c", title: "C", isSortable: false))]
        table.dataSource = dataSource
        table.layoutSubtreeIfNeeded()

        let byA = NSSortDescriptor(key: "a", ascending: false)
        table.sortDescriptors = [byA]
        #expect(dataSource.changes == [[]])
        // The same again changes nothing.
        table.sortDescriptors = [byA]
        #expect(dataSource.changes.count == 1)

        // A click puts the column's prototype first; the previous sort follows.
        table.sortByClicking(amount)
        #expect(table.sortDescriptors == [amount.sortDescriptorPrototype, byA])
        #expect(dataSource.changes.last == [byA])
        #expect(table.sortPosition(ofColumn: amount)?.index == 0)
        #expect(table.sortPosition(ofColumn: amount)?.ascending == false)
        #expect(table.sortPosition(ofColumn: NGTableColumn("a", title: "A"))?.index == 1)
        // Unsortable columns ignore clicks.
        table.sortByClicking(NGTableColumn("c", title: "C", isSortable: false))
        #expect(dataSource.changes.count == 2)

        // Removing a sorted column drops its sort, and the data source sorts again.
        table.columns = [.column(NGTableColumn("a", title: "A"))]
        #expect(table.sortDescriptors == [byA])
        #expect(dataSource.changes.count == 3)
        withExtendedLifetime(dataSource) {}
    }

    /// A filter over many rows and summaries builds the calculators from the
    /// values already read in the background, and the totals follow it.
    @Test func filteredSummariesOfManyValuesAreBuiltInTheBackground() async throws {
        @MainActor final class Numbers: NGTableViewDataSource {
            func numberOfRows(in tableView: NGTableView) -> Int { 3_000 }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
                column.id == "name" ? .text(row.isMultiple(of: 3) ? "keep \(row)" : "drop \(row)") : .number(1)
            }
        }
        let data = Numbers()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = table
        table.synchronousSearchLimit = .max
        table.synchronousSummaryComputeLimit = 1_000
        table.columns = [.column(NGTableColumn("name", title: "Name"))]
            + (0..<8).map { .column(NGTableColumn("n\($0)", title: "N", summary: .aggregate(.sum))) }
        table.dataSource = data
        table.layoutSubtreeIfNeeded()
        try await waitForSummary(of: table)
        #expect(table.summaryValue(forColumnID: "n0") == 3_000)
        table.rowFilter = NGRowFilter(searchText: "keep")
        #expect(table.isComputingSummary)   // More values than the limit: not on the main thread.
        try await waitForSummary(of: table)
        #expect(table.summaryValue(forColumnID: "n7") == 1_000)
        withExtendedLifetime((data, window)) {}
    }

    /// Selection totals follow a selection that grows and shrinks step by
    /// step (from the last ones), always equal to a fresh computation.
    /// The summary's color shows its scope: a new scope draws it again even
    /// when its texts stay the same (nothing selected: all rows' totals).
    @Test func aNewScopeDrawsTheSummaryAgain() throws {
        let (table, dataSource) = makeTable([.column(NGTableColumn("n", title: "N", summary: .aggregate(.sum)))])
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((window, dataSource)) {} }
        let texts = table.summaryTexts
        let surface = try #require(table.summarySurface)
        surface.needsFrame = false
        table.summaryScope = .excludingSelectedRows
        #expect(table.summaryTexts == texts)
        #expect(surface.needsFrame)
    }

    /// Selection totals followed step by step keep a remainder smaller than
    /// a large value's last place: 0.15 after taking 1e15 out.
    @Test func selectionTotalsKeepSmallRemainders() {
        final class Values: NGTableViewDataSource {
            let values: [Double] = [1e15, 0.05, 0.05, 0.05] + [Double](repeating: 0, count: 20)
            func numberOfRows(in tableView: NGTableView) -> Int { values.count }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .number(values[row]) }
        }
        let values = Values()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = [.column(NGTableColumn("n", title: "N", summary: .aggregate(.sum)))]
        table.dataSource = values
        table.summaryScope = .selectedRows
        table.selectRowIndexes(IndexSet(0...3), byExtendingSelection: false)
        table.selectRowIndexes(IndexSet(1...3), byExtendingSelection: false)
        let total = table.summaryValue(forColumnID: "n") ?? 0
        #expect(abs(total - 0.15) < 1e-9, "\(total)")
        withExtendedLifetime(values) {}
    }

    @Test func selectionTotalsFollowEachStep() {
        @MainActor final class Values: NGTableViewDataSource {
            let values = (0..<5_000).map { Double(($0 * 37) % 101) / 4 }
            func numberOfRows(in tableView: NGTableView) -> Int { values.count }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .number(values[row]) }
        }
        let data = Values()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.columns = [.column(NGTableColumn("v", title: "V", summary: .aggregate(.sum))),
                         .column(NGTableColumn("c", title: "C", summary: .aggregate(.count)))]
        table.dataSource = data
        for scope in [NGSummaryScope.selectedRows, .excludingSelectedRows] {
            table.summaryScope = scope
            for end in Array(stride(from: 3_000, through: 4_000, by: 50)) + Array(stride(from: 4_000, through: 2_500, by: -70)) {
                let rows = IndexSet(integersIn: 100..<end)
                table.selectRowIndexes(rows, byExtendingSelection: false)
                let counted = scope == .selectedRows ? Array(rows) : (0..<data.values.count).filter { !rows.contains($0) }
                let expected = counted.reduce(0) { $0 + data.values[$1] }
                let total = table.summaryValue(forColumnID: "v") ?? .nan
                #expect(abs(total - expected) < 1e-9, "\(scope) \(end)")
                #expect(table.summaryValue(forColumnID: "c") == Double(counted.count))
            }
        }
        withExtendedLifetime(data) {}
    }

    private func waitForSummary(of table: NGTableView) async throws {
        try await waitWhile { table.isComputingSummary }
        #expect(!table.isComputingSummary)
    }
}

/// Records what an NSTableView delegate and action target would be told.
@MainActor
private final class SelectionRecorder: NSObject, NGTableViewDelegate {
    var events: [String] = []
    var unselectableRows: Set<Int> = []
    var allowsChange = true
    var actions: [(name: String, row: Int, column: Int)] = []

    func tableViewSelectionDidChange(_ notification: Notification) {
        events.append("did \(((notification.object as? NGTableView)?.selectedRowIndexes).map(Array.init) ?? [])")
    }
    func tableViewSelectionIsChanging(_ notification: Notification) {
        events.append("is \(((notification.object as? NGTableView)?.selectedRowIndexes).map(Array.init) ?? [])")
    }
    func selectionShouldChange(in tableView: NGTableView) -> Bool { allowsChange }
    func tableView(_ tableView: NGTableView, shouldSelectRow row: Int) -> Bool { !unselectableRows.contains(row) }

    @objc func clicked(_ sender: NGTableView) { actions.append(("click", sender.clickedRow, sender.clickedColumn)) }
    @objc func doubleClicked(_ sender: NGTableView) { actions.append(("double", sender.clickedRow, sender.clickedColumn)) }
}

@Suite("NSTableView compatibility")
@MainActor
struct NGTableViewCompatibilityTests {
    /// A table in a window, with mouse events at rows (window coordinates).
    @MainActor
    private struct Fixture {
        let table: NGTableView
        let dataSource: TestDataSource
        let window: NSWindow

        init(columns: [NGColumnItem] = [.column(NGTableColumn("a", title: "A", width: 200)), .column(NGTableColumn("b", title: "B", width: 200))]) {
            (table, dataSource) = makeTable(columns)
            window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = table
            table.layoutSubtreeIfNeeded()
        }

        func event(_ type: NSEvent.EventType, row: Int, x: CGFloat = 100, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) throws -> NSEvent {
            let y = table.bounds.height - (table.layoutMetrics.headerHeight + CGFloat(row) * table.rowHeight + table.rowHeight / 2)
            return try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: y), modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
            ))
        }

        func press(_ row: Int, x: CGFloat = 100, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) throws {
            table.rowsMouseDown(try event(.leftMouseDown, row: row, x: x, modifiers: modifiers, clickCount: clickCount), in: table.centerRegion)
        }

        func drag(to row: Int) throws {
            table.rowsMouseDragged(try event(.leftMouseDragged, row: row))
        }

        func release(_ row: Int) throws {
            table.rowsMouseUp(try event(.leftMouseUp, row: row))
        }
    }

    /// Like NSTableView: a mouse press reports "is changing" until it is
    /// released; the keyboard and code report "did change" at once.
    @Test func selectionNotificationsFollowTheMouse() throws {
        let fixture = Fixture()
        let recorder = SelectionRecorder()
        fixture.table.delegate = recorder
        // (Posted on the main thread, where the test reads it.)
        nonisolated(unsafe) var observed = 0
        let observer = NotificationCenter.default.addObserver(forName: NGTableView.selectionDidChangeNotification,
                                                              object: fixture.table, queue: nil) { _ in observed += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        try fixture.press(2)
        try fixture.drag(to: 4)
        #expect(recorder.events == ["is [2]", "is [2, 3, 4]"])
        try fixture.release(4)
        #expect(recorder.events.last == "did [2, 3, 4]")
        #expect(observed == 1)

        // A press that changes nothing reports nothing.
        recorder.events = []
        try fixture.press(4, modifiers: .shift)
        try fixture.release(4)
        #expect(recorder.events.isEmpty)

        fixture.table.moveDown(nil)
        #expect(recorder.events == ["did [5]"])
        fixture.table.selectRowIndexes([7], byExtendingSelection: false)
        #expect(recorder.events.last == "did [7]")
        #expect(observed == 3)

        // A press whose mouse up went elsewhere ends with the next press.
        recorder.events = []
        try fixture.press(9)
        try fixture.press(10)
        #expect(recorder.events == ["is [9]", "did [9]", "is [10]"])
        withExtendedLifetime(fixture.dataSource) {}
    }

    @Test func theDelegateDecidesWhatTheUserSelects() throws {
        let fixture = Fixture()
        let table = fixture.table
        let recorder = SelectionRecorder()
        recorder.unselectableRows = [3]
        table.delegate = recorder

        // Clicks and drags only select rows the delegate accepts.
        try fixture.press(3)
        try fixture.release(3)
        #expect(table.selectedRowIndexes.isEmpty)
        try fixture.press(1)
        try fixture.drag(to: 5)
        try fixture.release(5)
        #expect(table.selectedRowIndexes == [1, 2, 4, 5])
        table.selectAll(nil)
        #expect(!table.isRowSelected(3) && table.numberOfSelectedRows == table.numberOfRows - 1)

        // Arrow keys skip unselectable rows.
        table.selectRowIndexes([2], byExtendingSelection: false)
        table.moveDown(nil)
        #expect(table.selectedRowIndexes == [4])
        #expect(table.selectedRow == 4)

        // Code isn't asked.
        table.selectRowIndexes([3], byExtendingSelection: false)
        #expect(table.selectedRowIndexes == [3])

        // A delegate can freeze the selection.
        recorder.allowsChange = false
        try fixture.press(8)
        try fixture.release(8)
        #expect(table.selectedRowIndexes == [3])
        recorder.allowsChange = true

        // Without empty selections, the user can't deselect the last row.
        table.allowsEmptySelection = false
        table.selectRowIndexes([6], byExtendingSelection: false)
        try fixture.press(6, modifiers: .command)
        try fixture.release(6)
        #expect(table.selectedRowIndexes == [6])
        table.deselectAll(nil)
        #expect(table.selectedRowIndexes == [6])
        table.allowsEmptySelection = true
        table.deselectRow(6)
        #expect(table.selectedRowIndexes.isEmpty && table.selectedRow == -1)
        withExtendedLifetime(fixture.dataSource) {}
    }

    @Test func clicksSendActionsWithTheClickedCell() throws {
        let fixture = Fixture()
        let table = fixture.table
        let recorder = SelectionRecorder()
        table.target = recorder
        table.action = #selector(SelectionRecorder.clicked(_:))
        table.doubleAction = #selector(SelectionRecorder.doubleClicked(_:))

        // The action follows the mouse up; the double action the second press.
        try fixture.press(2, x: 300)
        #expect(recorder.actions.isEmpty)
        try fixture.release(2)
        try fixture.press(2, x: 300, clickCount: 2)
        try fixture.release(2)
        #expect(recorder.actions.map(\.name) == ["click", "double"])
        #expect(recorder.actions.allSatisfy { $0.row == 2 && $0.column == 1 })

        // Below the rows: clickedRow -1. A reload forgets the clicked row.
        fixture.dataSource.rowCount = 5
        table.reloadData()
        try fixture.press(8, clickCount: 2)
        #expect(recorder.actions.last?.name == "double")
        #expect(recorder.actions.last?.row == -1)
        try fixture.press(1)
        table.reloadData()
        #expect(table.clickedRow == -1)
        withExtendedLifetime(fixture.dataSource) {}
    }

    @Test func columnsAndPointsAreFoundLikeInNSTableView() {
        let fixture = Fixture(columns: [
            .column(NGTableColumn("lead", title: "L", width: 100, pin: .leading)),
            .group(NGColumnGroup("g", title: "G", columns: [NGTableColumn("b", title: "B", width: 150),
                                                             NGTableColumn("c", title: "C", width: 150)])),
        ])
        let table = fixture.table
        #expect(table.tableColumns.map(\.id) == ["lead", "b", "c"])
        #expect(table.numberOfColumns == 3)
        #expect(table.column(withIdentifier: NSUserInterfaceItemIdentifier("c")) == 2)
        #expect(table.column(withIdentifier: NSUserInterfaceItemIdentifier("nope")) == -1)
        #expect(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("b"))?.title == "B")
        #expect(NGTableColumn("x", title: "X").identifier.rawValue == "x")

        let top = table.layoutMetrics.headerHeight
        let rowFive = NSPoint(x: 50, y: top + table.rowHeight * 5.5)
        #expect(table.row(at: rowFive) == 5)
        #expect(table.column(at: rowFive) == 0)
        #expect(table.column(at: NSPoint(x: table.layoutMetrics.leadingWidth + 20, y: rowFive.y)) == 1)
        // In the header there is no row, but a column.
        #expect(table.row(at: NSPoint(x: 50, y: top / 2)) == -1)
        #expect(table.column(at: NSPoint(x: 50, y: top / 2)) == 0)
        #expect(table.row(at: NSPoint(x: -10, y: rowFive.y)) == -1)
        // Rows are data source rows while a filter hides some.
        table.rowFilter = NGRowFilter(isIncluded: { $0 >= 10 })
        #expect(table.row(at: rowFive) == 15)
        withExtendedLifetime(fixture.dataSource) {}
    }

    /// Without a menu from the delegate, the table's `menu` shows, like an NSTableView's.
    @Test func theTablesMenuIsTheFallback() throws {
        final class MenuProvider: NGTableViewDelegate {
            let menu: NSMenu
            init(menu: NSMenu) { self.menu = menu }
            func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: NGTableColumn?) -> NSMenu? { menu }
        }
        let fixture = Fixture()
        let table = fixture.table
        let menu = NSMenu(title: "Rows")
        table.menu = menu
        #expect(table.rowsMenu(for: try fixture.event(.rightMouseDown, row: 3), in: table.centerRegion) === menu)
        #expect(table.clickedRow == 3)
        #expect(table.clickedColumn == 0)
        let provider = MenuProvider(menu: NSMenu(title: "Delegate"))
        table.delegate = provider
        #expect(table.rowsMenu(for: try fixture.event(.rightMouseDown, row: 3), in: table.centerRegion) === provider.menu)
        withExtendedLifetime(provider) {}
        withExtendedLifetime(fixture.dataSource) {}
    }

    /// Column notifications like NSTableView's: resizes with the old width,
    /// moves with the old and new index, clicks on a title.
    @Test func columnNotificationsLikeNSTableView() throws {
        final class ColumnRecorder: NGTableViewDelegate {
            var resizes: [(id: String, oldWidth: Double)] = []
            var moves: [(old: Int, new: Int)] = []
            var clicks: [String] = []
            func tableViewColumnDidResize(_ notification: Notification) {
                guard let column = notification.userInfo?["NSTableColumn"] as? NGTableColumn,
                      let old = notification.userInfo?["NSOldWidth"] as? NSNumber else { return }
                resizes.append((column.id, old.doubleValue))
            }
            func tableViewColumnDidMove(_ notification: Notification) {
                guard let old = notification.userInfo?["NSOldColumn"] as? NSNumber,
                      let new = notification.userInfo?["NSNewColumn"] as? NSNumber else { return }
                moves.append((old.intValue, new.intValue))
            }
            func tableView(_ tableView: NGTableView, didClick tableColumn: NGTableColumn) { clicks.append(tableColumn.id) }
        }
        let fixture = Fixture(columns: [
            .column(NGTableColumn("a", title: "A", width: 200)),
            .column(NGTableColumn("b", title: "B", width: 200)),
            .column(NGTableColumn("c", title: "C", width: 200, isSortable: false)),
        ])
        let table = fixture.table
        let recorder = ColumnRecorder()
        table.delegate = recorder
        // (Posted on the main thread, where the test reads it.)
        nonisolated(unsafe) var posted = 0
        let observer = NotificationCenter.default.addObserver(forName: NGTableView.columnDidResizeNotification,
                                                              object: table, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        table.setWidth(250, forColumnID: "b")
        #expect(recorder.resizes.count == 1)
        #expect(recorder.resizes.first?.id == "b")
        #expect(recorder.resizes.first?.oldWidth == 200)
        #expect(posted == 1)
        table.setWidth(250, forColumnID: "b")
        #expect(recorder.resizes.count == 1)

        // Moving "c" first: one notification for it, 2 → 0.
        let original = table.columns
        table.applyReorderedColumns(NGColumnReorder.moving(.item(id: "c"), to: 0, in: table.columns))
        table.reportColumnsMoved(from: original, dragged: ["c"])
        #expect(recorder.moves.count == 1)
        #expect(recorder.moves.first?.old == 2 && recorder.moves.first?.new == 0)

        // A click on a title, sortable or not, is reported after its sort.
        func headerEvent(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            // (Optional in older SDKs, not in newer ones, where `#require` warns.)
            let event: NSEvent? = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: table.bounds.height - table.headerRowHeight / 2), modifierFlags: [],
                timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
            guard let event else { throw NoEvent() }
            return event
        }
        // "c" is now first, at the leading edge.
        table.headerMouseDown(try headerEvent(.leftMouseDown, x: 60), in: table.headerView)
        table.headerMouseUp(try headerEvent(.leftMouseUp, x: 60))
        #expect(recorder.clicks == ["c"])
        #expect(table.sortDescriptors.isEmpty)
        withExtendedLifetime((recorder, fixture.dataSource)) {}
    }

    /// Dragging a header title moves its column, unless the delegate says no;
    /// the order then stays as it was.
    @Test func headerDragsAskTheDelegate() throws {
        final class Gate: NGTableViewDelegate {
            var allows = false
            var asked = 0
            func tableView(_ tableView: NGTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
                asked += 1
                return allows
            }
        }
        let fixture = Fixture(columns: [
            .column(NGTableColumn("a", title: "A", width: 200)),
            .column(NGTableColumn("b", title: "B", width: 200)),
            .column(NGTableColumn("c", title: "C", width: 200)),
        ])
        let table = fixture.table
        let gate = Gate()
        table.delegate = gate
        func headerEvent(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            // (Optional in older SDKs, not in newer ones, where `#require` warns.)
            let event: NSEvent? = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: table.bounds.height - table.headerRowHeight / 2), modifierFlags: [],
                timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
            guard let event else { throw NoEvent() }
            return event
        }
        func drag(from start: CGFloat, to end: CGFloat) throws {
            table.headerMouseDown(try headerEvent(.leftMouseDown, x: start), in: table.headerView)
            for x in stride(from: start + 10, through: end, by: 20) {
                table.headerMouseDragged(try headerEvent(.leftMouseDragged, x: x))
            }
            table.headerMouseUp(try headerEvent(.leftMouseUp, x: end))
        }
        try drag(from: 100, to: 500)
        #expect(gate.asked > 0)
        #expect(table.tableColumns.map(\.id) == ["a", "b", "c"])
        #expect(table.sortDescriptors.isEmpty)   // A drag isn't a click.
        gate.allows = true
        try drag(from: 100, to: 500)
        #expect(table.tableColumns.map(\.id).last == "a")
        withExtendedLifetime((gate, fixture.dataSource)) {}
    }

    /// A press on a column divider tells the delegate of a resize only when
    /// the width changed.
    @Test func dividerPressesWithoutAMoveAreNoResize() throws {
        final class Recorder: NGTableViewDelegate {
            var resized: [String] = []
            func tableView(_ tableView: NGTableView, didResizeColumn column: NGTableColumn, width: Double) { resized.append(column.id) }
        }
        let fixture = Fixture(columns: [
            .column(NGTableColumn("a", title: "A", width: 200)),
            .column(NGTableColumn("b", title: "B", width: 200)),
        ])
        let table = fixture.table
        let recorder = Recorder()
        table.delegate = recorder
        func headerEvent(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            // (Optional in older SDKs, not in newer ones, where `#require` warns.)
            let event: NSEvent? = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: table.bounds.height - table.headerRowHeight / 2), modifierFlags: [],
                timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
            guard let event else { throw NoEvent() }
            return event
        }
        let edge = table.rect(ofColumn: 0).maxX - 1
        table.headerMouseDown(try headerEvent(.leftMouseDown, x: edge), in: table.headerView)
        table.headerMouseUp(try headerEvent(.leftMouseUp, x: edge))
        #expect(recorder.resized.isEmpty)
        table.headerMouseDown(try headerEvent(.leftMouseDown, x: edge), in: table.headerView)
        table.headerMouseDragged(try headerEvent(.leftMouseDragged, x: edge + 30))
        table.headerMouseUp(try headerEvent(.leftMouseUp, x: edge + 30))
        #expect(recorder.resized == ["a"])
        withExtendedLifetime((recorder, fixture.dataSource)) {}
    }

    /// The group header menu collapses and expands its group, and all of them.
    @Test func groupMenuCollapsesAndExpands() throws {
        let (table, dataSource) = makeTable([.column(NGTableColumn("a", title: "A"))])
        dataSource.constantValue = .text("one")
        table.rowGrouping = NGRowGrouping(columnIDs: ["a"])
        #expect(table.numberOfRows == 51)
        func choose(_ index: Int) throws {
            let items = table.groupMenu(forNode: 0).items
            try #require(items.indices.contains(index))
            let item = items[index]
            NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        }
        try choose(0)   // Collapse Group.
        #expect(table.numberOfRows == 1)
        try choose(0)   // Expand Group.
        #expect(table.numberOfRows == 51)
        try choose(2)   // Collapse All Groups.
        #expect(table.numberOfRows == 1)
        try choose(3)   // Expand All Groups.
        #expect(table.numberOfRows == 51)
        withExtendedLifetime(dataSource) {}
    }

    /// The summary row's menu checks the current scope and sets another.
    @Test func summaryScopeMenu() throws {
        let (table, dataSource) = makeTable([.column(NGTableColumn("n", title: "N", summary: .aggregate(.sum)))])
        let menu = table.makeSummaryScopeMenu()
        #expect(menu.items.count == NGSummaryScope.allCases.count)
        #expect(menu.items.filter { $0.state == .on }.map(\.tag) == [NGSummaryScope.allCases.firstIndex(of: table.summaryScope)])
        let selected = try #require(NGSummaryScope.allCases.firstIndex(of: .selectedRows))
        let item = menu.items[selected]
        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        #expect(table.summaryScope == .selectedRows)
        #expect(table.makeSummaryScopeMenu().items[selected].state == .on)
        withExtendedLifetime(dataSource) {}
    }
}
/// Names to copy.
@MainActor
private final class CopiedTextDataSource: NGTableViewDataSource {
    let names: [String]
    init(names: [String]) { self.names = names }
    func numberOfRows(in tableView: NGTableView) -> Int { names.count }
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text(names[row]) }
}
#endif
