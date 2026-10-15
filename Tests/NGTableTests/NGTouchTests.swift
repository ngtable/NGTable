#if os(iOS)
import Testing
import UIKit
@testable import NGTable

// The table on the iPad: taps select rows and sort by a title, the finger's
// scroll view moves the table, and the summary row stays above the home
// indicator. Run on an iOS simulator:
//
//     xcodebuild test -scheme NGTable-Package -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M2)' -only-testing:NGTableTests/NGTouchTests

@MainActor
private final class Numbers: NSObject, NGTableViewDataSource {
    var values: [Double] = (0..<200).map { Double(($0 * 37) % 101) }
    var actions: [Int] = []
    var doubleActions: [Int] = []

    func numberOfRows(in tableView: NGTableView) -> Int { values.count }
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        column.id == "name" ? .text("Row \(row)") : .number(values[row])
    }

    @objc func tapped(_ sender: NGTableView) { actions.append(sender.clickedRow) }
    @objc func doubleTapped(_ sender: NGTableView) { doubleActions.append(sender.clickedRow) }
}

@MainActor
struct NGTouchTests {
    /// A table filling a window's view controller, laid out.
    private func makeTable(_ data: Numbers, bottomSafeArea: CGFloat = 0) -> (NGTableView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        controller.additionalSafeAreaInsets.bottom = bottomSafeArea
        window.rootViewController = controller
        window.isHidden = false
        let table = NGTableView(frame: controller.view.bounds)
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 150)),
                         .column(NGTableColumn("value", title: "Value", width: 100, summary: .aggregate(.sum)))]
        table.dataSource = data
        table.target = data
        table.action = #selector(Numbers.tapped(_:))
        table.doubleAction = #selector(Numbers.doubleTapped(_:))
        controller.view.addSubview(table)
        window.layoutIfNeeded()
        table.layoutIfNeeded()
        return (table, window)
    }

    /// The middle of a row in view, in the table's coordinates.
    private func point(ofRow row: Int, in table: NGTableView) -> CGPoint {
        CGPoint(x: 60, y: table.layoutMetrics.headerHeight + (CGFloat(row) + 0.5) * table.rowHeight - table.contentOffset.y)
    }

    @Test func aTapSelectsTheRowAndSendsTheAction() {
        let data = Numbers()
        let (table, window) = makeTable(data)
        defer { withExtendedLifetime(window) {} }
        table.tapped(at: point(ofRow: 3, in: table))
        #expect(table.selectedRowIndexes == [3])
        #expect(data.actions == [3])
        // Another row replaces the selection.
        table.tapped(at: point(ofRow: 5, in: table))
        #expect(table.selectedRowIndexes == [5])
        #expect(data.actions == [3, 5])
        table.doubleTapped(at: point(ofRow: 5, in: table))
        #expect(data.doubleActions == [5])
        // The summary row is no row: nothing changes, nothing is sent.
        table.tapped(at: CGPoint(x: 60, y: table.bounds.height - 5))
        #expect(table.selectedRowIndexes == [5])
        #expect(data.actions == [3, 5])
    }

    @Test func aTapOnATitleSorts() {
        let data = Numbers()
        let (table, window) = makeTable(data)
        defer { withExtendedLifetime(window) {} }
        let title = CGPoint(x: 150 + 50, y: table.layoutMetrics.headerHeight / 2)
        table.tapped(at: title)
        #expect(table.sortDescriptors.map(\.key) == ["value"])
        #expect(table.sortDescriptors.map(\.ascending) == [true])
        table.tapped(at: title)
        #expect(table.sortDescriptors.map(\.ascending) == [false])
        // A title isn't a row.
        #expect(table.selectedRowIndexes.isEmpty)
        #expect(data.actions.isEmpty)
    }

    @Test func theFingersScrollViewMovesTheTable() throws {
        let data = Numbers()
        let (table, window) = makeTable(data)
        defer { withExtendedLifetime(window) {} }
        let scroll = try #require(table.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(scroll.contentSize.height == scroll.frame.height + table.layoutMetrics.maxOffset.y)
        scroll.contentOffset = CGPoint(x: 0, y: 1_000)
        #expect(table.contentOffset.y == 1_000)
        // Past the end (the rubber band): the table stops at its last row.
        scroll.contentOffset = CGPoint(x: 0, y: table.layoutMetrics.maxOffset.y + 50)
        #expect(table.contentOffset.y == table.layoutMetrics.maxOffset.y)
        // Scrolled in code: the scroll view follows.
        table.scrollRowToVisible(0)
        table.layoutIfNeeded()
        #expect(scroll.contentOffset.y == table.contentOffset.y)
    }

    @Test func theSummaryStaysAboveTheHomeIndicator() {
        let data = Numbers()
        let (table, window) = makeTable(data, bottomSafeArea: 20)
        defer { withExtendedLifetime(window) {} }
        #expect(table.safeAreaInsets.bottom == 20)
        // The bar reaches the bottom; its values sit above the safe area.
        #expect(table.summaryBar.frame.maxY == table.bounds.height)
        #expect(table.summaryBar.frame.height == table.summaryRowHeight + 20)
        table.summaryBar.layoutIfNeeded()
        #expect(table.summaryBar.contentView.frame.height == table.summaryRowHeight)
        // The last row scrolls to above the summary.
        let metrics = table.layoutMetrics
        #expect(metrics.maxOffset.y == metrics.contentHeight + table.summaryRowHeight + 20 - metrics.bodyHeight)
        // Without a summary the rows scroll above the home indicator.
        table.showsSummaryRow = false
        table.layoutIfNeeded()
        #expect(table.layoutMetrics.maxOffset.y == metrics.contentHeight + 20 - metrics.bodyHeight)
    }

    // MARK: Taps like clicks

    @Test func theDelegateDecidesWhatATapSelects() {
        final class OnlyEven: NGTableViewDelegate {
            func tableView(_ tableView: NGTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
                proposed.filteredIndexSet { $0 % 2 == 0 }
            }
        }
        let data = Numbers()
        let (table, window) = makeTable(data)
        let delegate = OnlyEven()
        defer { withExtendedLifetime((window, delegate)) {} }
        table.delegate = delegate
        table.tapped(at: point(ofRow: 3, in: table))
        #expect(table.selectedRowIndexes.isEmpty)
        table.tapped(at: point(ofRow: 4, in: table))
        #expect(table.selectedRowIndexes == [4])
    }

    @Test func commandAndShiftTapsWithAKeyboard() {
        let data = Numbers()
        let (table, window) = makeTable(data)
        defer { withExtendedLifetime(window) {} }
        table.allowsMultipleSelection = true
        table.tapped(at: point(ofRow: 2, in: table))
        table.tapped(at: point(ofRow: 6, in: table), modifiers: .command)
        #expect(table.selectedRowIndexes == [2, 6])
        table.tapped(at: point(ofRow: 2, in: table), modifiers: .command)
        #expect(table.selectedRowIndexes == [6])
        // From the row tapped last (the anchor, like a click on the Mac).
        table.tapped(at: point(ofRow: 9, in: table), modifiers: .shift)
        #expect(table.selectedRowIndexes == IndexSet(2...9))
        // A plain tap selects one row again.
        table.tapped(at: point(ofRow: 1, in: table))
        #expect(table.selectedRowIndexes == [1])
    }

    @Test func aTapOnALinkOrACheckBoxActs() {
        final class Cells: NSObject, NGTableViewDataSource, NGTableViewDelegate {
            var on = [Bool](repeating: false, count: 20)
            var clicked: [Int] = []
            func numberOfRows(in tableView: NGTableView) -> Int { on.count }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
                column.id == "link" ? .link(NGLink("Open \(row)", url: URL(string: "https://example.com/\(row)"))) : .bool(on[row])
            }
            func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
                if case .bool(let new) = value { on[row] = new }
            }
            func tableView(_ tableView: NGTableView, didClickLink link: NGLink, in column: NGTableColumn, row: Int) { clicked.append(row) }
        }
        let cells = Cells()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let table = NGTableView(frame: window.bounds)
        defer { withExtendedLifetime((window, cells)) {} }
        table.columns = [.column(NGTableColumn("link", title: "Link", width: 150)),
                         .column(NGTableColumn("on", title: "On", width: 120, isEditable: true))]
        table.dataSource = cells
        table.delegate = cells
        window.addSubview(table)
        window.isHidden = false
        table.layoutIfNeeded()
        // A link: the delegate hears of it, the row isn't selected.
        table.tapped(at: point(ofRow: 2, in: table))
        #expect(cells.clicked == [2])
        #expect(table.selectedRowIndexes.isEmpty)
        // A check box toggles at a tap anywhere in its cell (and the row is selected).
        var cell = point(ofRow: 4, in: table)
        cell.x = 150 + 110
        table.tapped(at: cell)
        #expect(cells.on[4])
        #expect(table.selectedRowIndexes == [4])
        // The double tap's second tap toggles it back, and edits nothing.
        table.tapped(at: cell)
        table.doubleTapped(at: cell)
        #expect(!cells.on[4])
        #expect(!table.isEditingCell)
    }

    @Test func aDoubleTapEditsAndReturnCommits() throws {
        final class Spend: NSObject, NGTableViewDataSource {
            var values: [Double] = Array(repeating: 10, count: 20)
            func numberOfRows(in tableView: NGTableView) -> Int { values.count }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .number(values[row]) }
            func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
                if case .number(let new) = value { values[row] = new }
            }
        }
        let spend = Spend()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let table = NGTableView(frame: window.bounds)
        defer { withExtendedLifetime((window, spend)) {} }
        table.locale = Locale(identifier: "en_US")
        table.navigatesByCell = true
        table.columns = [.column(NGTableColumn("spend", title: "Spend", width: 150, format: .number(fractionDigits: 0), isEditable: true))]
        table.dataSource = spend
        window.addSubview(table)
        window.isHidden = false
        table.layoutIfNeeded()
        table.tapped(at: point(ofRow: 3, in: table))
        table.doubleTapped(at: point(ofRow: 3, in: table))
        #expect(table.isEditingCell)
        #expect(table.editedRow == 3)
        let field = try #require(table.editor?.field)
        #expect(field.text == "10")
        field.text = "42"
        // Return: committed, and the cell below is focused.
        _ = field.delegate?.textFieldShouldReturn?(field)
        #expect(!table.isEditingCell)
        #expect(spend.values[3] == 42)
        #expect(table.focusedCell == NGCellPosition(row: 4, columnID: "spend"))
        // Escape throws the text away.
        #expect(table.editCell(row: 5, columnID: "spend"))
        table.editor?.field.text = "7"
        table.abortEditing()
        #expect(spend.values[5] == 10)
    }

    // MARK: Context menus

    /// The titles of a menu's actions, its inline sections flattened.
    private func titles(_ menu: UIMenu?) -> [String] {
        (menu?.children ?? []).flatMap { element -> [String] in
            if let submenu = element as? UIMenu, submenu.options.contains(.displayInline) { return titles(submenu) }
            return [element is UIMenu ? (element as! UIMenu).title + "…" : (element as? UIAction)?.title ?? "?"]
        }
    }

    @Test func aRowsMenuComesFromTheDelegate() {
        final class Menus: NGTableViewDelegate {
            var asked: [(rows: IndexSet, clicked: Int?, column: String?)] = []
            func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: NGTableColumn?) -> UIMenu? {
                asked.append((rows, clickedRow, column?.id))
                return UIMenu(children: [UIAction(title: "Archive") { _ in }])
            }
        }
        let data = Numbers()
        let (table, window) = makeTable(data)
        let menus = Menus()
        defer { withExtendedLifetime((window, menus)) {} }
        table.delegate = menus
        table.allowsMultipleSelection = true
        table.selectRowIndexes([1, 2], byExtendingSelection: false)
        // In the selection: for the selection.
        #expect(titles(table.contextMenu(at: point(ofRow: 2, in: table))) == ["Archive"])
        #expect(menus.asked.last?.rows == [1, 2])
        #expect(menus.asked.last?.clicked == 2)
        #expect(menus.asked.last?.column == "name")
        #expect(table.menuOutline == nil)
        // Another row: only it, outlined, the selection kept.
        _ = table.contextMenu(at: point(ofRow: 5, in: table))
        #expect(menus.asked.last?.rows == [5])
        #expect(table.clickedRow == 5)
        #expect(table.menuOutlineRow == 5)
        #expect(table.selectedRowIndexes == [1, 2])
        table.rowsMenuDidClose()
        #expect(table.menuOutline == nil)
    }

    @Test func theHeaderAndSummaryHaveTheTablesMenus() {
        let data = Numbers()
        let (table, window) = makeTable(data)
        defer { withExtendedLifetime(window) {} }
        table.allowsColumnHiding = true
        let valueTitle = CGPoint(x: 150 + 50, y: table.layoutMetrics.headerHeight / 2)
        let header = titles(table.headerMenu(at: valueTitle))
        #expect(header.prefix(2) == ["Sort Ascending", "Sort Descending"])
        #expect(header.last == "Columns…")
        let columns = table.headerMenu(at: valueTitle)?.children.last as? UIMenu
        #expect(columns?.children.compactMap { ($0 as? UIAction)?.title } == ["Name", "Value"])
        #expect(columns?.children.compactMap { ($0 as? UIAction)?.state } == [.on, .on])
        table.sort(by: table.tableColumns[1], ascending: false)
        #expect(table.sortDescriptors.map(\.key) == ["value"])
        #expect(table.sortDescriptors.map(\.ascending) == [false])
        // The header menu shows the sort.
        let sorted = table.headerMenu(at: valueTitle)?.children.first as? UIMenu
        #expect(sorted?.children.compactMap { ($0 as? UIAction)?.state } == [.off, .on])
        // The summary row: which rows it sums.
        let summary = table.contextMenu(at: CGPoint(x: 60, y: table.bounds.height - 5))
        #expect(summary?.children.count == NGSummaryScope.allCases.count)
        #expect((summary?.children.first as? UIAction)?.state == .on)
    }

    // MARK: Columns by touch

    @Test func draggingAnEdgeResizesAColumn() throws {
        final class Widths: NGTableViewDelegate {
            var resized: [(String, Double)] = []
            func tableView(_ tableView: NGTableView, didResizeColumn column: NGTableColumn, width: Double) { resized.append((column.id, width)) }
        }
        let data = Numbers()
        let (table, window) = makeTable(data)
        let widths = Widths()
        defer { withExtendedLifetime((window, widths)) {} }
        table.delegate = widths
        let y = table.layoutMetrics.headerHeight / 2
        let edge = try #require(table.resizeHandles().first { $0.frame.column.id == "name" }?.edgeX)
        // A finger beside the edge (farther than the Mac's pointer may be) still grabs it.
        #expect(table.headerPanShouldBegin(at: CGPoint(x: edge + 8, y: y)))
        table.headerPanBegan(at: CGPoint(x: edge + 8, y: y))
        table.headerPanChanged(to: CGPoint(x: edge + 48, y: y))
        #expect(table.width(ofColumnID: "name") == 190)
        #expect(widths.resized.isEmpty)
        table.headerPanEnded()
        #expect(widths.resized.map(\.0) == ["name"])
        #expect(widths.resized.map(\.1) == [190])
        // A pan in the rows is the scroll view's.
        #expect(!table.headerPanShouldBegin(at: point(ofRow: 2, in: table)))
    }

    @Test func draggingATitleMovesAColumn() async throws {
        let data = Numbers()
        let (table, window) = makeTable(data)
        defer { withExtendedLifetime(window) {} }
        let y = table.layoutMetrics.headerHeight / 2
        #expect(table.headerPanShouldBegin(at: CGPoint(x: 60, y: y)))
        table.headerPanBegan(at: CGPoint(x: 60, y: y))
        #expect(table.isHeaderInteracting)
        table.headerPanChanged(to: CGPoint(x: 200, y: y))
        table.headerPanChanged(to: CGPoint(x: 240, y: y))
        #expect(table.tableColumns.map(\.id) == ["value", "name"])
        table.headerPanEnded()
        #expect(!table.isHeaderInteracting)
        // The lifted snapshot lands and goes.
        try await waitWhile(timeout: .seconds(5), poll: .milliseconds(10)) { table.columnDrag != nil }
        #expect(!table.subviews.contains { $0.frame.width == 150 && $0.layer.shadowOpacity > 0 })
        // Fixed columns don't move.
        table.allowsColumnReordering = false
        #expect(!table.headerPanShouldBegin(at: CGPoint(x: 60, y: y)))
    }

    @Test func aDoubleTapOnAnEdgeFitsTheColumn() throws {
        let data = Numbers()
        let (table, window) = makeTable(data)
        defer { withExtendedLifetime(window) {} }
        let y = table.layoutMetrics.headerHeight / 2
        let edge = try #require(table.resizeHandles().first { $0.frame.column.id == "name" }?.edgeX)
        table.doubleTapped(at: CGPoint(x: edge - 8, y: y))
        // "Row 199" is narrower than 150 points.
        #expect((table.width(ofColumnID: "name") ?? 150) < 150)
    }

    // MARK: A hardware keyboard

    @Test func arrowsAndCommandAMoveTheSelection() {
        let data = Numbers()
        let (table, window) = makeTable(data)
        defer { withExtendedLifetime(window) {} }
        table.allowsMultipleSelection = true
        table.tapped(at: point(ofRow: 3, in: table))
        #expect(table.isFirstResponder)
        #expect(table.handleKey(.keyboardDownArrow))
        #expect(table.selectedRowIndexes == [4])
        table.handleKey(.keyboardDownArrow, modifiers: .shift)
        table.handleKey(.keyboardDownArrow, modifiers: .shift)
        #expect(table.selectedRowIndexes == IndexSet(4...6))
        table.handleKey(.keyboardUpArrow)
        #expect(table.selectedRowIndexes == [5])
        table.handleKey(.keyboardA, modifiers: .command, characters: "a")
        #expect(table.selectedRowIndexes.count == 200)
        // End scrolls to the last row.
        table.handleKey(.keyboardEnd)
        #expect(table.contentOffset.y == table.layoutMetrics.maxOffset.y)
        // Keys the table doesn't use go on (a plain space outside type select).
        #expect(!table.handleKey(.keyboardSpacebar, characters: " "))
        #expect(!table.handleKey(.keyboardC, modifiers: .command, characters: "c"))
    }

    @Test func typingSelectsByTypeSelectAndEditsAFocusedCell() {
        final class Names: NSObject, NGTableViewDataSource {
            var names = ["Anna", "Boris", "Bella", "Clara", "Dmitry"]
            func numberOfRows(in tableView: NGTableView) -> Int { names.count }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text(names[row]) }
            func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
                if case .text(let new) = value { names[row] = new }
            }
        }
        let names = Names()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let table = NGTableView(frame: window.bounds)
        defer { withExtendedLifetime((window, names)) {} }
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 150))]
        table.dataSource = names
        window.addSubview(table)
        window.isHidden = false
        table.layoutIfNeeded()
        table.handleKey(.keyboardB, characters: "b")
        table.handleKey(.keyboardE, characters: "e")
        #expect(table.selectedRowIndexes == [2])
        // Editable cells, navigated by cell: typing edits the focused one.
        table.navigatesByCell = true
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 150, isEditable: true))]
        table.tapped(at: point(ofRow: 0, in: table))
        table.handleKey(.keyboardZ, characters: "Z")
        #expect(table.isEditingCell)
        #expect(table.editor?.field.text == "Z")
        _ = table.editor.map { $0.field.delegate?.textFieldShouldReturn?($0.field) }
        #expect(names.names[0] == "Z")
        // Return moved down: Return again edits that cell.
        #expect(table.handleKey(.keyboardReturnOrEnter))
        #expect(table.editedRow == 1)
    }

    // MARK: A pointer

    @Test func thePointerFindsTheCellUnderIt() {
        final class Hover: NGTableViewDelegate {
            var entered: [Int] = []
            func tableView(_ tableView: NGTableView, pointerDidEnterRow row: Int, column: NGTableColumn) { entered.append(row) }
        }
        let data = Numbers()
        let (table, window) = makeTable(data)
        let hover = Hover()
        defer { withExtendedLifetime((window, hover)) {} }
        table.delegate = hover
        table.pointerMoved(to: point(ofRow: 2, in: table))
        #expect(table.hoveredCell == NGCellPosition(row: 2, columnID: "name"))
        // The rows scroll under the resting pointer: another row is under it.
        table.scrollRowToVisible(100)
        table.layoutIfNeeded()
        table.updateHoveredCellFromPointer()
        #expect(table.hoveredCell?.row != 2)
        #expect(hover.entered.count == 2)
        table.pointerMoved(to: nil)
        #expect(table.hoveredCell == nil)
        // Over a column's edge: the beam's region.
        let edge = table.resizeHandles().first?.edgeX ?? 0
        #expect(table.pointerRegion(at: CGPoint(x: edge + 3, y: 5)) != nil)
        #expect(table.pointerRegion(at: CGPoint(x: 60, y: 5)) == nil)
    }

    // MARK: Swipe actions

    @Test func aSwipeOpensARowsActionsAndATapPressesOne() {
        final class Actions: NGTableViewDelegate {
            var archived: [Int] = []
            func tableView(_ tableView: NGTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NGRowAction] {
                guard edge == .trailing else { return [] }
                return [NGRowAction(style: .destructive, title: "Archive") { [weak self] _, row in self?.archived.append(row) }]
            }
        }
        let data = Numbers()
        let (table, window) = makeTable(data)
        let actions = Actions()
        defer { withExtendedLifetime((window, actions)) {} }
        table.delegate = actions
        let row = point(ofRow: 4, in: table)
        // Sideways to the left (the columns fit: nothing to scroll first).
        #expect(table.rowSwipeShouldBegin(at: row, velocity: CGPoint(x: -500, y: 20)))
        table.moveRowSwipe(by: -120)
        table.finishRowSwipe()
        #expect(table.rowActionsVisible)
        #expect(table.swipedDisplayRow == 4)
        let buttons = try? #require(table.rowActionButtons)
        #expect(buttons?.frame.width ?? 0 > 0)
        // A tap on the button performs its action and closes them.
        table.tapped(at: CGPoint(x: (buttons?.frame.midX ?? 0), y: row.y))
        #expect(actions.archived == [4])
        #expect(!table.rowActionsVisible)
        // To the right there are no actions: the pan is the scroll view's.
        #expect(!table.rowSwipeShouldBegin(at: row, velocity: CGPoint(x: 500, y: 0)))
        // Mostly down: a scroll.
        #expect(!table.rowSwipeShouldBegin(at: row, velocity: CGPoint(x: -100, y: 400)))
        // Open, then a tap elsewhere closes them without selecting.
        _ = table.rowSwipeShouldBegin(at: row, velocity: CGPoint(x: -500, y: 0))
        table.moveRowSwipe(by: -120)
        table.finishRowSwipe()
        table.tapped(at: point(ofRow: 8, in: table))
        #expect(!table.rowActionsVisible)
        #expect(table.selectedRowIndexes.isEmpty)
    }

    // MARK: VoiceOver

    @Test func voiceOverReadsADataTable() throws {
        final class Actions: NGTableViewDelegate {
            func tableView(_ tableView: NGTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NGRowAction] {
                edge == .trailing ? [NGRowAction(style: .destructive, title: "Archive") { _, _ in }] : []
            }
        }
        let data = Numbers()
        let (table, window) = makeTable(data)
        let actions = Actions()
        defer { withExtendedLifetime((window, actions)) {} }
        table.delegate = actions
        table.locale = Locale(identifier: "en_US")
        #expect(table.accessibilityContainerType == .dataTable)
        let elements = try #require(table.accessibilityElements)
        // Two titles, two cells for each row in view, the summary.
        let rows = table.accessibilityRowsInView
        #expect(rows.lowerBound == 0 && rows.count > 10)
        #expect(elements.count == 2 + 2 * rows.count + 1)
        let title = try #require(elements[1] as? NGTouchAccessibilityHeader)
        #expect(title.accessibilityLabel == "Value")
        let cell = try #require(table.accessibilityDataTableCellElement(forRow: 4, column: 1) as? NGTouchAccessibilityCell)
        #expect(cell.accessibilityLabel == table.accessibilityText(row: 3, column: table.tableColumns[1]))
        #expect(cell.accessibilityLabel == "\(Int(data.values[3]))")
        #expect(cell.accessibilityColumnRange().location == 1)
        #expect((table.accessibilityHeaderElements(forColumn: 1)?.first as? NGTouchAccessibilityHeader) === title)
        // The same element while the row stays (VoiceOver's focus).
        #expect(table.accessibilityDataTableCellElement(forRow: 4, column: 1) as? NGTouchAccessibilityCell === cell)
        // A double tap selects the row; it reads as selected.
        #expect(cell.accessibilityActivate())
        #expect(table.selectedRowIndexes == [3])
        #expect(cell.accessibilityTraits.contains(.selected))
        #expect(cell.accessibilityCustomActions?.map(\.name) == ["Archive"])
        // A title's double tap sorts.
        #expect(title.accessibilityActivate())
        #expect(title.accessibilityValue == "ascending")
        // The summary reads its values.
        let summary = try #require(elements.last as? NGAccessibilitySummary)
        #expect(summary.accessibilityValue?.hasPrefix("Value: ") == true)
    }

    // MARK: Filters and choices

    @Test func aColumnsFilterOpensFromItsMenuAndFilters() throws {
        final class Cities: NSObject, NGTableViewDataSource {
            let cities = ["Berlin", "Köln", "Berlin", "Wien", "Köln", "Berlin"]
            let spend: [Double] = [5, 1, 7, 3, 2, 9]
            func numberOfRows(in tableView: NGTableView) -> Int { cities.count }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
                column.id == "city" ? .text(cities[row]) : .number(spend[row])
            }
        }
        let cities = Cities()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        let table = NGTableView(frame: controller.view.bounds)
        controller.view.addSubview(table)
        var shown: NGColumnFilterController?
        NGTableView.columnFilterShownForTesting = { shown = $0 }
        defer {
            NGTableView.columnFilterShownForTesting = nil
            withExtendedLifetime((window, cities)) {}
        }
        table.allowsColumnFilters = true
        table.columns = [.column(NGTableColumn("city", title: "City", width: 150)),
                         .column(NGTableColumn("spend", title: "Spend", width: 100, format: .number(fractionDigits: 0)))]
        table.dataSource = cities
        table.layoutIfNeeded()
        let cityTitle = CGPoint(x: 60, y: table.layoutMetrics.headerHeight / 2)
        let menu = table.headerMenu(at: cityTitle)
        #expect(titles(menu).contains("Filter…"))
        #expect(table.showFilter(forColumnID: "city"))
        let values = try #require(shown)
        values.loadViewIfNeeded()
        // Berlin, Köln, Wien: unchecking Köln leaves 4 rows.
        #expect(values.tableView(values.tableView, numberOfRowsInSection: 0) == 4)
        values.toggle(1)
        #expect(table.columnFilters["city"] == .excluding(["Köln"]))
        #expect(table.numberOfRows == 4)
        // Select All checks them all again: no filter.
        values.toggle(nil)
        #expect(table.columnFilters["city"] == nil)
        // A number column: a range typed.
        #expect(table.showFilter(forColumnID: "spend"))
        let numbers = try #require(shown)
        numbers.minField.text = "3"
        numbers.applyNumbers(changed: numbers.minField)
        #expect(table.columnFilters["spend"] == .range(min: 3, max: nil))
        #expect(table.numberOfRows == 4)
        // Its filter button, a tap away, opens it again.
        shown = nil
        let edge = try #require(table.resizeHandles().first { $0.frame.column.id == "spend" }?.edgeX)
        table.tapped(at: CGPoint(x: edge - 14, y: table.layoutMetrics.headerHeight / 2))
        #expect(shown != nil)
        #expect(table.sortDescriptors.isEmpty)
    }

    @Test func aChoiceColumnOpensItsChoices() throws {
        final class Status: NSObject, NGTableViewDataSource {
            var statuses = ["Active", "Paused"]
            func numberOfRows(in tableView: NGTableView) -> Int { statuses.count }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text(statuses[row]) }
            func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
                if case .text(let new) = value { statuses[row] = new }
            }
        }
        let status = Status()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        let table = NGTableView(frame: controller.view.bounds)
        controller.view.addSubview(table)
        var sheet: UIAlertController?
        NGTableView.choicesShownForTesting = { sheet = $0 }
        defer {
            NGTableView.choicesShownForTesting = nil
            withExtendedLifetime((window, status)) {}
        }
        table.columns = [.column(NGTableColumn("status", title: "Status", width: 150, isEditable: true,
                                               editChoices: [.text("Active"), .text("Paused"), .text("Finished")]))]
        table.dataSource = status
        table.layoutIfNeeded()
        table.doubleTapped(at: point(ofRow: 1, in: table))
        let shown = try #require(sheet)
        #expect(shown.actions.map(\.title) == ["Active", "✓ Paused", "Finished", "Cancel"])
        table.choose(NGChoice(ref: table.rowRef(ofRow: 1), columnID: "status", index: 2))
        #expect(status.statuses[1] == "Finished")
    }

    // MARK: Updating data

    @Test func theVeilCoversTheTableWhileDataUpdates() async throws {
        let data = Numbers()
        let (table, window) = makeTable(data)
        defer { withExtendedLifetime(window) {} }
        try await table.updatingData {
            #expect(table.ignoresUserInput)
            #expect(table.dataUpdateOverlay.superview === table)
            #expect(table.dataUpdateOverlay.hitTest(CGPoint(x: 10, y: 100), with: nil) === table.dataUpdateOverlay)
            // Taps meanwhile do nothing.
            table.tapped(at: point(ofRow: 2, in: table))
            #expect(table.selectedRowIndexes.isEmpty)
            try await Task.sleep(for: .milliseconds(300))
            #expect(table.dataUpdateOverlay.alpha > 0)
        }
        #expect(!table.ignoresUserInput)
        #expect(table.dataUpdateOverlay.hitTest(CGPoint(x: 10, y: 100), with: nil) == nil)
        table.tapped(at: point(ofRow: 2, in: table))
        #expect(table.selectedRowIndexes == [2])
    }
}
#endif
