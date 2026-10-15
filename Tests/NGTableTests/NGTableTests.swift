import Foundation
import Testing
@testable import NGTable

@Suite("Column layout")
struct NGColumnLayoutTests {
    @Test func pinnedColumnsAreSplitIntoRegions() {
        let layout = NGColumnLayout(items: [
            .column(NGTableColumn("a", title: "A", pin: .leading)),
            .column(NGTableColumn("b", title: "B")),
            .column(NGTableColumn("c", title: "C", pin: .trailing)),
            .column(NGTableColumn("d", title: "D", pin: .leading)),
        ])
        #expect(layout.leading.columns.map(\.id) == ["a", "d"])
        #expect(layout.center.columns.map(\.id) == ["b"])
        #expect(layout.trailing.columns.map(\.id) == ["c"])
        #expect(layout.allColumns.map(\.id) == ["a", "d", "b", "c"])
    }

    @Test func groupPinOverridesMemberPin() {
        let layout = NGColumnLayout(items: [
            .column(NGTableColumn("x", title: "X")),
            .group(NGColumnGroup("g", title: "G", pin: .trailing, columns: [
                NGTableColumn("g1", title: "G1", pin: .leading),
                NGTableColumn("g2", title: "G2"),
            ])),
        ])
        #expect(layout.trailing.columns.map(\.id) == ["g1", "g2"])
        #expect(layout.trailing.columns.allSatisfy { $0.pin == .trailing })
        #expect(layout.trailing.groups == [NGGroupSpan(groupID: "g", title: "G", columnRange: 0..<2)])
        #expect(layout.groupIDByColumnID == ["g1": "g", "g2": "g"])
        #expect(layout.hasGroups)
    }

    @Test func groupSpanStartsAfterPrecedingColumns() {
        let layout = NGColumnLayout(items: [
            .column(NGTableColumn("a", title: "A")),
            .column(NGTableColumn("b", title: "B")),
            .group(NGColumnGroup("g", title: "G", columns: [
                NGTableColumn("g1", title: "G1"),
                NGTableColumn("g2", title: "G2"),
                NGTableColumn("g3", title: "G3"),
            ])),
        ])
        #expect(layout.center.groups.first?.columnRange == 2..<5)
    }
}

@Suite("Grid geometry")
struct NGGridGeometryTests {
    let layout = NGColumnLayout(items: [
        .column(NGTableColumn("name", title: "Name", width: 150, pin: .leading)),
        .group(NGColumnGroup("income", title: "Income", columns: [
            NGTableColumn("s1", title: "S1", width: 100),
            NGTableColumn("s2", title: "S2", width: 80),
        ])),
        .column(NGTableColumn("note", title: "Note", width: 120)),
        .column(NGTableColumn("total", title: "Total", width: 90, pin: .trailing)),
    ])

    @Test func centerColumnsStartAfterLeadingRegion() {
        let geometry = NGGridGeometry(layout: layout)
        #expect(geometry.leading.columns.map(\.x) == [0])
        #expect(geometry.center.columns.map(\.x) == [150, 250, 330])
        #expect(geometry.trailing.columns.map(\.x) == [0])
        #expect(geometry.center.width == 300)
        #expect(geometry.contentWidth == 540)
    }

    @Test func groupFramesSpanTheirColumns() {
        let geometry = NGGridGeometry(layout: layout)
        #expect(geometry.center.groups == [NGGroupFrame(groupID: "income", title: "Income", x: 150, width: 180)])
    }

    @Test func widthsOverrideDefaultsWithinLimits() {
        let geometry = NGGridGeometry(layout: layout, widths: ["s1": 200, "s2": 1])
        #expect(geometry.center.columns.map(\.width) == [200, 40, 120])
    }

    @Test func columnsIntersectingRange() {
        let geometry = NGGridGeometry(layout: layout)
        #expect(geometry.center.columns(intersecting: 260, 300).map(\.column.id) == ["s2"])
        #expect(geometry.center.columns(intersecting: 240, 260).map(\.column.id) == ["s1", "s2"])
        #expect(geometry.center.columns(intersecting: 0, 150).isEmpty)
        #expect(geometry.center.columns(intersecting: 440, 900).map(\.column.id) == ["note"])
        #expect(geometry.center.column(atX: 250)?.column.id == "s2")
        #expect(geometry.center.column(atX: 450) == nil)
    }
}

@Suite("Column reordering")
struct NGColumnReorderTests {
    let items: [NGColumnItem] = [
        .column(NGTableColumn("name", title: "Name", pin: .leading)),
        .column(NGTableColumn("a", title: "A")),
        .group(NGColumnGroup("g", title: "G", columns: [
            NGTableColumn("g1", title: "G1"),
            NGTableColumn("g2", title: "G2"),
            NGTableColumn("g3", title: "G3"),
        ])),
        .column(NGTableColumn("total", title: "Total", pin: .trailing)),
        .column(NGTableColumn("b", title: "B")),
    ]

    @Test func siblingsStayWithinRegionOrGroup() {
        #expect(NGColumnReorder.siblings(of: .item(id: "a"), in: items) == ["a", "g", "b"])
        #expect(NGColumnReorder.siblings(of: .item(id: "g"), in: items) == ["a", "g", "b"])
        #expect(NGColumnReorder.siblings(of: .member(columnID: "g2", groupID: "g"), in: items) == ["g1", "g2", "g3"])
        #expect(NGColumnReorder.siblings(of: .item(id: "name"), in: items) == ["name"])
    }

    @Test func movingTopLevelItemKeepsOtherRegionsInPlace() {
        let moved = NGColumnReorder.moving(.item(id: "b"), to: 0, in: items)
        #expect(moved.map(\.id) == ["name", "b", "a", "total", "g"])
        let layout = NGColumnLayout(items: moved)
        #expect(layout.center.columns.map(\.id) == ["b", "a", "g1", "g2", "g3"])
        #expect(layout.trailing.columns.map(\.id) == ["total"])
    }

    @Test func movingWholeGroup() {
        let moved = NGColumnReorder.moving(.item(id: "g"), to: 2, in: items)
        #expect(NGColumnLayout(items: moved).center.columns.map(\.id) == ["a", "b", "g1", "g2", "g3"])
    }

    @Test func movingColumnInsideGroup() {
        let moved = NGColumnReorder.moving(.member(columnID: "g1", groupID: "g"), to: 2, in: items)
        let layout = NGColumnLayout(items: moved)
        #expect(layout.center.columns.map(\.id) == ["a", "g2", "g3", "g1", "b"])
        #expect(layout.center.groups.first?.columnRange == 1..<4)
    }

    @Test func wideColumnPassesNarrowNeighborAtRegionEdge() {
        // "name" (0...150) is dragged right in a 260pt region; its snapshot is
        // clamped at 110...260, so its center (185) never reaches "city"'s
        // midpoint (205), but its trailing edge does.
        let target = NGColumnReorder.targetIndex(currentIndex: 0, others: [150...260], draggedSpan: 110...260)
        #expect(target == 1)
    }

    @Test func swapsUseEdgesWithHysteresis() {
        // Dragged is second of three (siblings a: 0...100, c: 200...300).
        let others: [ClosedRange<Double>] = [0...100, 200...300]
        // Trailing edge crosses c's midpoint (250): move after c.
        #expect(NGColumnReorder.targetIndex(currentIndex: 1, others: others, draggedSpan: 160...260) == 2)
        // Leading edge crosses a's midpoint (50): move before a.
        #expect(NGColumnReorder.targetIndex(currentIndex: 1, others: others, draggedSpan: 40...140) == 0)
        // In between: stay.
        #expect(NGColumnReorder.targetIndex(currentIndex: 1, others: others, draggedSpan: 90...190) == 1)
        // After moving past c (now c: 100...200, dragged last), going back needs
        // the leading edge to cross c's new midpoint (150), not just a small step.
        #expect(NGColumnReorder.targetIndex(currentIndex: 2, others: [0...100, 100...200], draggedSpan: 160...260) == 2)
        #expect(NGColumnReorder.targetIndex(currentIndex: 2, others: [0...100, 100...200], draggedSpan: 140...240) == 1)
    }

    @Test func indexIsClamped() {
        let moved = NGColumnReorder.moving(.item(id: "a"), to: 99, in: items)
        #expect(NGColumnLayout(items: moved).center.columns.map(\.id) == ["g1", "g2", "g3", "b", "a"])
    }
}

@Suite("Summary")
struct NGSummaryTests {
    let calculator = NGSummaryCalculator(values: [10, nil, 20, 30, 40])

    @Test func allRowsIgnoresSelection() {
        #expect(calculator.value(for: .sum, scope: .allRows, selection: [0, 2]) == 100)
        #expect(calculator.value(for: .count, scope: .allRows, selection: []) == 4)
        #expect(calculator.value(for: .average, scope: .allRows, selection: []) == 25)
    }

    @Test func selectedRowsOnly() {
        #expect(calculator.value(for: .sum, scope: .selectedRows, selection: [0, 1, 3]) == 40)
        #expect(calculator.value(for: .count, scope: .selectedRows, selection: [0, 1, 3]) == 2)
        #expect(calculator.value(for: .max, scope: .selectedRows, selection: [0, 3]) == 30)
        #expect(calculator.value(for: .average, scope: .selectedRows, selection: []) == nil)
    }

    @Test func excludingSelectedRowsSubtractsFromTotal() {
        #expect(calculator.value(for: .sum, scope: .excludingSelectedRows, selection: [4]) == 60)
        #expect(calculator.value(for: .count, scope: .excludingSelectedRows, selection: [1, 4]) == 3)
        #expect(calculator.value(for: .average, scope: .excludingSelectedRows, selection: [4]) == 20)
        #expect(calculator.value(for: .max, scope: .excludingSelectedRows, selection: [4]) == 30)
        #expect(calculator.value(for: .min, scope: .excludingSelectedRows, selection: [0]) == 20)
        #expect(calculator.value(for: .sum, scope: .excludingSelectedRows, selection: []) == 100)
    }

    @Test func outOfRangeSelectionIsIgnored() {
        #expect(calculator.value(for: .sum, scope: .selectedRows, selection: [3, 99]) == 30)
    }

    /// After an update in place the total's min and max cover only the
    /// added values: every scope computes them again, also "all except
    /// selected" with nothing selected.
    @Test func minAndMaxAfterAnUpdateInPlace() {
        // Row 2 changes from 20 to 5.
        let source: [Double] = [10, .nan, 5, 30, 40]
        let updated = calculator.updating(source: source, removing: [20], adding: [5])
        for scope in NGSummaryScope.allCases {
            let selection: IndexSet = scope == .selectedRows ? IndexSet(integersIn: 0..<5) : []
            #expect(updated.value(for: .max, scope: scope, selection: selection) == 40, "\(scope)")
            #expect(updated.value(for: .min, scope: scope, selection: selection) == 5, "\(scope)")
            #expect(updated.value(for: .sum, scope: scope, selection: selection) == 85, "\(scope)")
        }
        // Nothing added: still the other rows' min and max.
        let removed = calculator.updating(source: [10, .nan, .nan, 30, 40], removing: [20], adding: [])
        #expect(removed.value(for: .max, scope: .excludingSelectedRows, selection: []) == 40)
        #expect(removed.value(for: .min, scope: .excludingSelectedRows, selection: []) == 10)
    }

    /// A real remainder far below the other values stays; a rounding
    /// residue goes.
    @Test func smallRemaindersStay() {
        let large = NGSummaryCalculator(values: [1e15, 0.25, 0.25])
        #expect(large.value(for: .sum, scope: .excludingSelectedRows, selection: [0]) == 0.5)
        let tenths = NGSummaryCalculator(values: [0.1, 0.2])
        #expect(tenths.value(for: .sum, scope: .excludingSelectedRows, selection: [0, 1]) == nil
                || tenths.value(for: .sum, scope: .excludingSelectedRows, selection: [0, 1]) == 0)
        let mixed = NGSummaryCalculator(values: [0.1, 0.2, 0.3])
        #expect(mixed.value(for: .sum, scope: .excludingSelectedRows, selection: [0, 1]) == 0.3)
        // A remainder under two units in the last place of the large value.
        let fine = NGSummaryCalculator(values: [1e15, 0.05, 0.05, 0.05])
        let rest = fine.value(for: .sum, scope: .excludingSelectedRows, selection: [0]) ?? 0
        #expect(abs(rest - 0.15) < 1e-9, "\(rest)")
    }

    /// Min and max stay known through updates that don't take an extreme
    /// away (no walk over the rows); one that does is walked once.
    @Test func minAndMaxStayExactWhenTheyCan() {
        // [10, -, 20, 30, 40]: a middle value changes.
        let middle = calculator.updating(source: [10, .nan, 25, 30, 40], removing: [20], adding: [25])
        #expect(middle.hasExactMinMax)
        #expect(middle.total.min == 10 && middle.total.max == 40)
        // The largest grows, the smallest shrinks.
        let raised = calculator.updating(source: [10, .nan, 20, 30, 45], removing: [40], adding: [45])
        #expect(raised.hasExactMinMax && raised.total.max == 45)
        let lowered = calculator.updating(source: [7, .nan, 20, 30, 40], removing: [10], adding: [7])
        #expect(lowered.hasExactMinMax && lowered.total.min == 7)
        // The largest falls: walked again, once.
        let fallen = calculator.updating(source: [10, .nan, 20, 30, 15], removing: [40], adding: [15])
        #expect(!fallen.hasExactMinMax)
        let repaired = fallen.withExactMinMax()
        #expect(repaired.hasExactMinMax && repaired.total.max == 30 && repaired.total.min == 10 && repaired.total.sum == 75)
    }
}

@Suite("Values")
struct NGCellValueTests {
    /// Small in arrays: media and icons are boxed.
    @Test func valuesAreSmall() {
        #expect(MemoryLayout<NGCellValue>.stride <= 24, "\(MemoryLayout<NGCellValue>.size) bytes")
    }

    @Test func onlyNumbersAreNumeric() {
        #expect(NGCellValue.number(3).numericValue == 3)
        #expect(NGCellValue.text("3").numericValue == nil)
        #expect(NGCellValue.bool(true).numericValue == nil)
    }

    @Test func formatting() {
        let locale = Locale(identifier: "en_US")
        #expect(NGValueFormat.number(fractionDigits: 2).string(for: 1234.5, locale: locale) == "1,234.50")
        #expect(NGValueFormat.percent(fractionDigits: 0).string(for: 0.25, locale: locale) == "25%")
        #expect(NGValueFormat.automatic.string(for: .text("x"), locale: locale) == "x")
    }

    /// Negative numbers that round to zero, and -0, show as zero (not "-0"),
    /// in every format; the others keep their sign.
    @Test func negativesThatRoundToZeroShowAsZero() {
        let english = Locale(identifier: "en_US"), arabic = Locale(identifier: "ar_EG")
        #expect(NGValueFormat.automatic.string(for: Double(-1e-8), locale: english) == "0")
        #expect(NGValueFormat.automatic.string(for: Double(-0.0), locale: english) == "0")
        #expect(NGValueFormat.number(fractionDigits: 2).string(for: Double(-0.001), locale: english) == "0.00")
        #expect(NGValueFormat.percent(fractionDigits: 2).string(for: Double(-0.00001), locale: english) == "0.00%")
        #expect(NGValueFormat.currency(code: "USD").string(for: Double(-0.001), locale: english) == "$0.00")
        #expect(NGValueFormat.number(fractionDigits: 2).string(for: Double(-0.001), locale: arabic)
                == NGValueFormat.number(fractionDigits: 2).string(for: Double(0), locale: arabic))
        #expect(NGValueFormat.automatic.string(for: Double(-0.4), locale: english) == "-0.4")
        #expect(NGValueFormat.number(fractionDigits: 2).string(for: Double(-0.006), locale: english) == "-0.01")
        #expect(NGValueFormat.number(fractionDigits: 0).string(for: Double(-10), locale: english) == "-10")
        #expect(NGValueFormat.automatic.string(for: -Double.infinity, locale: english) == "-∞")
    }

    @Test func everythingIsLeadingByDefault() {
        let column = NGTableColumn("amount", title: "Amount", format: .currency(code: "EUR"))
        #expect(column.alignment.resolved(isNumeric: column.isNumeric) == .leading)
        #expect(column.headerAlignment.resolved(isNumeric: column.isNumeric) == .leading)
        // Trailing numbers are opt-in, and the title stays independent.
        let automatic = NGTableColumn("amount", title: "Amount", alignment: .automatic, format: .currency(code: "EUR"))
        #expect(automatic.alignment.resolved(isNumeric: automatic.isNumeric) == .trailing)
        #expect(automatic.headerAlignment.resolved(isNumeric: automatic.isNumeric) == .leading)
    }

    /// Like NSTableView: a clicked column sorts first, the others stay as
    /// secondary sorts; the first one reverses, then goes.
    @Test func headerClicksBuildSortDescriptors() {
        // The previous click reversed the first sort (what the table tracks).
        var reversed: [NSSortDescriptor]?
        func click(_ key: String, _ current: [NSSortDescriptor], ascending: Bool = true) -> [NSSortDescriptor] {
            let new = NGSorting.descriptors(afterClicking: NSSortDescriptor(key: key, ascending: ascending), current: current,
                                            reversedByUser: reversed == current && current.first?.key == key)
            reversed = new.first?.key == key && current.first?.key == key ? new : nil
            return new
        }
        func keys(_ descriptors: [NSSortDescriptor]) -> [String] {
            descriptors.map { "\($0.key ?? "")\($0.ascending ? "↑" : "↓")" }
        }
        let a = click("a", [])
        #expect(keys(a) == ["a↑"])
        let aDown = click("a", a)
        #expect(keys(aDown) == ["a↓"])
        #expect(click("a", aDown).isEmpty)
        // Another column goes first; the previous one breaks ties.
        let ba = click("b", aDown)
        #expect(keys(ba) == ["b↑", "a↓"])
        // A secondary column clicked again comes first with its prototype's direction.
        #expect(keys(click("a", ba)) == ["a↑", "b↑"])
        // The third click on the first column leaves the others.
        #expect(keys(click("b", click("b", ba))) == ["a↓"])
        // A prototype's direction is the first click's.
        #expect(keys(click("c", [], ascending: false)) == ["c↓"])
        #expect(keys(click("c", click("c", [], ascending: false), ascending: false)) == ["c↑"])
        // A sort the app set (either way) is reversed by a click, not removed.
        reversed = nil
        #expect(keys(click("p", [NSSortDescriptor(key: "p", ascending: false)])) == ["p↑"])
        reversed = nil
        #expect(keys(click("p", [NSSortDescriptor(key: "p", ascending: true)])) == ["p↓"])
    }

    /// The table tracks the user's clicks: a code-set sort is reversed, and
    /// only a click after the user reversed it removes it.
    @Test @MainActor func headerClicksOnASortSetInCode() {
        let table = NGTableView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let profit = NGTableColumn("profit", title: "Profit", width: 100)
        table.columns = [.column(profit)]
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        // Reversed (the user's first reversal), then removed.
        table.sortByClicking(profit)
        #expect(table.sortDescriptors.map(\.ascending) == [true])
        table.sortByClicking(profit)
        #expect(table.sortDescriptors.isEmpty)
        // From scratch: ascending, descending, removed.
        table.sortByClicking(profit)
        table.sortByClicking(profit)
        #expect(table.sortDescriptors.map(\.ascending) == [false])
        // Set in code between clicks: reversed again, not removed.
        table.sortDescriptors = [NSSortDescriptor(key: "profit", ascending: false)]
        table.sortByClicking(profit)
        #expect(table.sortDescriptors.map(\.ascending) == [true])
    }

    @Test func sortingRowsByDescriptors() {
        let cities = ["Berlin", "Köln", "Berlin", "Köln", "Berlin"]
        let spend: [Double] = [5, 1, 5, 3, 2]
        func value(_ key: String, _ row: Int) -> NGCellValue {
            key == "city" ? .text(cities[row]) : key == "spend" ? .number(spend[row]) : .empty
        }
        #expect(NGSorting.order(ofRows: 5, by: [], value: value) == [0, 1, 2, 3, 4])
        let byCity = [NSSortDescriptor(key: "city", ascending: true)]
        // Ties keep their order.
        #expect(NGSorting.order(ofRows: 5, by: byCity, value: value) == [0, 2, 4, 1, 3])
        let byCityThenSpend = byCity + [NSSortDescriptor(key: "spend", ascending: false)]
        #expect(NGSorting.order(ofRows: 5, by: byCityThenSpend, value: value) == [0, 2, 4, 3, 1])
        let bySpendDown = [NSSortDescriptor(key: "spend", ascending: false), NSSortDescriptor(key: "city", ascending: false)]
        #expect(NGSorting.order(ofRows: 5, by: bySpendDown, value: value) == [0, 2, 3, 4, 1])
    }

    @Test func sortableColumnsHaveAPrototype() {
        var column = NGTableColumn("spend", title: "Spend")
        #expect(column.isSortable)
        #expect(column.sortDescriptorPrototype == NSSortDescriptor(key: "spend", ascending: true))
        column.sortDescriptorPrototype = NSSortDescriptor(key: "amount", ascending: false)
        #expect(column.isSortable)
        #expect(column.sortDescriptorPrototype?.key == "amount")
        column.isSortable = false
        #expect(column.sortDescriptorPrototype == nil)
        #expect(!NGTableColumn("mark", title: "", isSortable: false).isSortable)
    }

    @Test func sorting() {
        #expect(NGCellValue.number(1).sortsBefore(.number(2)))
        #expect(NGCellValue.text("Item 2").sortsBefore(.text("Item 10")))
        #expect(NGCellValue.empty.sortsBefore(.number(0)))
    }
}

@Suite("Column visibility")
struct NGColumnVisibilityTests {
    let items: [NGColumnItem] = [
        .column(NGTableColumn("name", title: "Name", isHideable: false, pin: .leading)),
        .column(NGTableColumn("city", title: "City")),
        .group(NGColumnGroup("income", title: "Income", columns: [
            NGTableColumn("s1", title: "S1"),
            NGTableColumn("s2", title: "S2"),
            NGTableColumn("s3", title: "S3"),
        ])),
        .column(NGTableColumn("total", title: "Total", pin: .trailing)),
    ]

    @Test func hiddenColumnsAndGroupsAreLeftOut() {
        var layout = NGColumnLayout(items: items, hiddenIDs: ["city", "s2"])
        #expect(layout.allColumns.map(\.id) == ["name", "s1", "s3", "total"])
        #expect(layout.center.groups.first?.columnRange == 0..<2)

        layout = NGColumnLayout(items: items, hiddenIDs: ["income"])
        #expect(layout.allColumns.map(\.id) == ["name", "city", "total"])
        #expect(!layout.hasGroups)

        // A group whose columns are all hidden disappears.
        layout = NGColumnLayout(items: items, hiddenIDs: ["s1", "s2", "s3"])
        #expect(!layout.hasGroups)
    }

    @Test func groupStates() {
        #expect(NGColumnVisibility.state(of: "income", in: items, hiddenIDs: []) == .visible)
        #expect(NGColumnVisibility.state(of: "income", in: items, hiddenIDs: ["s2"]) == .partiallyVisible)
        #expect(NGColumnVisibility.state(of: "income", in: items, hiddenIDs: ["s1", "s2", "s3"]) == .hidden)
        #expect(NGColumnVisibility.state(of: "s1", in: items, hiddenIDs: ["income"]) == .hidden)
    }

    @Test func togglingGroups() {
        // Hiding a group keeps its columns' own state for when it comes back.
        var hidden = NGColumnVisibility.toggling("income", in: items, hiddenIDs: ["s2"])
        #expect(hidden == ["income", "s2"])
        // Showing it again restores its columns as they were…
        hidden = NGColumnVisibility.toggling("income", in: items, hiddenIDs: hidden)
        #expect(hidden == ["s2"])
        // …or shows all of them if they were all hidden.
        hidden = NGColumnVisibility.toggling("income", in: items, hiddenIDs: ["s1", "s2", "s3"])
        #expect(hidden.isEmpty)
        // Showing one column of a hidden group shows the group with just that column.
        hidden = NGColumnVisibility.toggling("s3", in: items, hiddenIDs: ["income"])
        #expect(NGColumnLayout(items: items, hiddenIDs: hidden).allColumns.map(\.id) == ["name", "city", "s3", "total"])
    }

    @Test func requiredColumnsCannotBeHidden() {
        #expect(!NGColumnVisibility.canToggle("name", in: items, hiddenIDs: []))
        #expect(NGColumnVisibility.canToggle("city", in: items, hiddenIDs: []))
        // Showing is always possible.
        #expect(NGColumnVisibility.canToggle("city", in: items, hiddenIDs: ["city"]))
        // The last visible column stays.
        let single: [NGColumnItem] = [.column(NGTableColumn("a", title: "A")), .column(NGTableColumn("b", title: "B"))]
        #expect(!NGColumnVisibility.canToggle("a", in: single, hiddenIDs: ["b"]))
    }

    @Test func reorderingSkipsHiddenSiblings() {
        let row: [NGColumnItem] = ["a", "b", "c", "d"].map { .column(NGTableColumn($0, title: $0)) }
        #expect(NGColumnReorder.siblings(of: .item(id: "a"), in: row, hiddenIDs: ["b"]) == ["a", "c", "d"])
        // Visible order a c d; moving a after c keeps hidden b before c.
        let moved = NGColumnReorder.moving(.item(id: "a"), to: 1, in: row, hiddenIDs: ["b"])
        #expect(moved.map(\.id) == ["b", "c", "a", "d"])
        // Moving d to the front goes before hidden b too.
        let front = NGColumnReorder.moving(.item(id: "d"), to: 0, in: row, hiddenIDs: ["b"])
        #expect(front.map(\.id) == ["d", "a", "b", "c"])
    }
}

@Suite("Column layout state")
struct NGColumnLayoutStateTests {
    @Test func restoresOrderAndToleratesChangedColumns() throws {
        let saved = NGColumnLayoutState(
            order: ["c", "removed", "g", "a"],
            groupOrders: ["g": ["g2", "g1"]],
            widths: ["a": 80, "removed": 50],
            hiddenIDs: ["g1", "removed"]
        )
        // A newer definition: "new" was added, "removed" is gone.
        let items: [NGColumnItem] = [
            .column(NGTableColumn("a", title: "A")),
            .column(NGTableColumn("new", title: "New")),
            .group(NGColumnGroup("g", title: "G", columns: [
                NGTableColumn("g1", title: "G1"),
                NGTableColumn("g2", title: "G2"),
                NGTableColumn("g3", title: "G3"),
            ])),
            .column(NGTableColumn("c", title: "C")),
        ]
        let restored = saved.applyingOrder(to: items)
        #expect(restored.map(\.id) == ["c", "new", "g", "a"])
        #expect(restored[2].leafColumns.map(\.id) == ["g2", "g1", "g3"])

        let restricted = saved.restricted(to: items)
        #expect(restricted.hiddenIDs == ["g1"])
        #expect(restricted.widths == ["a": 80])

        let data = try PropertyListEncoder().encode(saved)
        #expect(try PropertyListDecoder().decode(NGColumnLayoutState.self, from: data) == saved)
    }
}

@Suite("Edge inset")
struct NGEdgeInsetTests {
    @Test func marginGoesToOutermostRegions() {
        let frozen = NGColumnLayout(items: [
            .column(NGTableColumn("a", title: "A", width: 100, pin: .leading)),
            .column(NGTableColumn("b", title: "B", width: 100)),
            .column(NGTableColumn("c", title: "C", width: 100, pin: .trailing)),
        ])
        var geometry = NGGridGeometry(layout: frozen, edgeInset: 10)
        #expect(geometry.leading.columns.first?.x == 10)
        #expect(geometry.leading.width == 110)
        #expect(geometry.center.columns.first?.x == 110)
        #expect(geometry.center.width == 100)
        #expect(geometry.trailing.columns.first?.x == 0)
        #expect(geometry.trailing.width == 110)

        // Without frozen columns the scrolling region gets both margins.
        let plain = NGColumnLayout(items: [.column(NGTableColumn("b", title: "B", width: 100))])
        geometry = NGGridGeometry(layout: plain, edgeInset: 10)
        #expect(geometry.center.columns.first?.x == 10)
        #expect(geometry.center.width == 120)
    }
}

@Suite("Summary formulas")
struct NGSummaryFormulaTests {
    @Test func filteredAggregatesSkipValues() {
        let values: [Double?] = [0.5, 0, -0.2, nil, 0.3]
        let nonZero = NGSummaryCalculator(values: values, including: .nonZero)
        #expect(nonZero.value(for: .count, scope: .allRows, selection: []) == 3)
        #expect(abs((nonZero.value(for: .average, scope: .allRows, selection: []) ?? 0) - 0.2) < 1e-9)
        let positive = NGSummaryCalculator(values: values, including: .positive)
        #expect(positive.value(for: .average, scope: .allRows, selection: []) == 0.4)
    }

    @Test func ratioOfSumsFollowsTheScope() {
        // A: spend 100, revenue 300 (+200%); B: spend 10 000, revenue 9 000 (−10%).
        let calculators = [
            "spend": NGSummaryCalculator(values: [100, 10_000]),
            "revenue": NGSummaryCalculator(values: [300, 9_000]),
        ]
        let roi = NGSummaryFormula("roi", using: ["spend", "revenue"]) { values in
            guard let spend = values.sum("spend"), spend != 0, let revenue = values.sum("revenue") else { return nil }
            return (revenue - spend) / spend
        }
        func value(_ scope: NGSummaryScope, _ selection: IndexSet) -> Double? {
            roi.value(with: NGSummaryValues(calculators: calculators, scope: scope, selection: selection))
        }
        #expect(abs((value(.allRows, []) ?? 0) - (9_300.0 - 10_100) / 10_100) < 1e-9)
        #expect(value(.selectedRows, [0]) == 2)
        #expect(abs((value(.excludingSelectedRows, [0]) ?? 0) - -0.1) < 1e-9)
        // No selected rows: no input values, so no result.
        #expect(value(.selectedRows, []) == nil)
    }
}

@Suite("Localization")
struct NGLocalizationTests {
    @Test func summaryMenuIsTranslatedToRussian() throws {
        let path = try #require(Bundle.module.path(forResource: "ru", ofType: "lproj"))
        let russian = try #require(Bundle(path: path))
        #expect(russian.localizedString(forKey: "Summarize All Rows", value: nil, table: nil) == "Итог по всем строкам")
    }
}


@Suite("Review regressions")
struct NGReviewRegressionTests {
    @Test func reorderingPastAnEmptyGroup() {
        let items: [NGColumnItem] = [
            .group(NGColumnGroup("empty", title: "E", columns: [])),
            .column(NGTableColumn("a", title: "A")),
            .column(NGTableColumn("b", title: "B")),
        ]
        #expect(NGColumnReorder.siblings(of: .item(id: "a"), in: items, hiddenIDs: []) == ["a", "b"])
        let moved = NGColumnReorder.moving(.item(id: "a"), to: 1, in: items, hiddenIDs: [])
        #expect(moved.map(\.id) == ["empty", "b", "a"])
    }

    /// NaN sorts like an empty value (first ascending), as summaries count it,
    /// on every path: compared values and the table's number keys.
    @Test func nanSortsLikeEmpty() {
        let values: [NGCellValue] = [.number(3), .number(.nan), .number(1), .empty, .number(.nan), .number(2)]
        let sorted = values.sorted { $0.sortsBefore($1) }
        #expect(sorted.prefix(3).allSatisfy { $0 == .empty || $0.isNaN })
        #expect(sorted.suffix(3).map(\.numericValue) == [1, 2, 3])
        #expect(NGSortKeys.rank(of: .number(.nan))?.rank == NGSortKeys.rank(of: .empty)?.rank)
        // NaN staying NaN isn't a change (the row doesn't move).
        var keys = NGSortKeys(keys: ["a"], ascending: [true], values: [[.number(.nan), .text("x")]])
        let changed = keys.set(.number(.nan), at: 0, row: 0)
        #expect(!changed)
    }

    @Test func nonFiniteValuesAreIgnored() {
        let calculator = NGSummaryCalculator(values: [1, .infinity, 2, .nan])
        #expect(calculator.value(for: .sum, scope: .allRows, selection: []) == 3)
        #expect(calculator.value(for: .sum, scope: .excludingSelectedRows, selection: [1]) == 3)
        #expect(calculator.value(for: .count, scope: .allRows, selection: []) == 2)
    }

    @Test func excludingSelectedRowsStaysExact() {
        var calculator = NGSummaryCalculator(values: [1e17, 3])
        #expect(calculator.value(for: .sum, scope: .excludingSelectedRows, selection: [0]) == 3)
        calculator = NGSummaryCalculator(values: [0.1, 5, 0.2, -5])
        let rest = calculator.value(for: .sum, scope: .excludingSelectedRows, selection: [0, 2])
        #expect(rest == 0)
        #expect(rest?.sign == .plus)
        #expect(calculator.value(for: .max, scope: .excludingSelectedRows, selection: [0, 1]) == 0.2)
        // A small selection is subtracted from the total; the rounding residue
        // of that subtraction is not shown as a value.
        calculator = NGSummaryCalculator(values: [0.1, 0.2, 5, -5, 1, -1, 2, -2])
        let residue = calculator.value(for: .sum, scope: .excludingSelectedRows, selection: [0, 1])
        #expect(residue == 0)
    }

    @Test func layoutStateDecodesWithMissingKeys() throws {
        let data = try JSONSerialization.data(withJSONObject: ["order": ["a", "b"]])
        let state = try JSONDecoder().decode(NGColumnLayoutState.self, from: data)
        #expect(state.order == ["a", "b"])
        #expect(state.widths.isEmpty && state.hiddenIDs.isEmpty)
        // States saved before sorts were: no sort, not an empty one.
        #expect(state.sort == nil)
    }

    @Test func savedSortsKeepKeyDirectionAndSelector() throws {
        let descriptors = [
            NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:))),
            NSSortDescriptor(key: "spend", ascending: false),
        ]
        let state = NGColumnLayoutState(items: [], widths: [:], hiddenIDs: [], sortDescriptors: descriptors)
        #expect(state.sort == [NGColumnLayoutState.Sort(key: "name", ascending: true, selector: "localizedStandardCompare:"),
                               NGColumnLayoutState.Sort(key: "spend", ascending: false)])
        let decoded = try PropertyListDecoder().decode(NGColumnLayoutState.self, from: PropertyListEncoder().encode(state))
        #expect(decoded.sortDescriptors == descriptors)
        // Sorts by columns that no longer exist (or aren't sortable) go.
        let restricted = decoded.restricted(to: [.column(NGTableColumn("spend", title: "S")),
                                                 .column(NGTableColumn("name", title: "N", isSortable: false))])
        #expect(restricted.sort?.map(\.key) == ["spend"])
    }

    @Test func duplicateIDsAreFound() {
        let items: [NGColumnItem] = [
            .column(NGTableColumn("total", title: "T")),
            .group(NGColumnGroup("total", title: "G", columns: [NGTableColumn("x", title: "X"), NGTableColumn("x", title: "X")])),
        ]
        #expect(NGColumnLayout.duplicateIDs(in: items) == ["total", "x"])
    }
}

@Suite("Fix review regressions")
struct NGFixReviewTests {
    @Test func smallRemaindersAreNotSnappedAway() {
        let calculator = NGSummaryCalculator(values: [5e15, -5e15, 0.25, 0.5])
        #expect(calculator.value(for: .sum, scope: .excludingSelectedRows, selection: [3]) == 0.25)
    }

    @Test func accumulatorsCompareByAggregates() {
        var a = NGAccumulator()
        var b = NGAccumulator()
        for value in [1.0, 2, 3] { a.add(value) }
        for value in [3.0, 1, 2] { b.add(value) }
        #expect(a == b)
    }
}


@Suite("Tags")
struct NGTagTests {
    @Test func tagsFormatAndSortByTitle() {
        let a: NGCellValue = .tags([NGTag("Акция", color: .green)])
        let b: NGCellValue = .tags([NGTag("Тест", color: .blue), NGTag("Новая", color: .orange)])
        #expect(NGValueFormat.automatic.string(for: b) == "Тест, Новая")
        #expect(a.sortsBefore(b))
        #expect(!b.sortsBefore(a))
        #expect(a.numericValue == nil)
    }
}

@Suite("Marks")
struct NGMarkTests {
    @Test func markFormatsAsLabelAndSortsByMeaning() {
        let star: NGCellValue = .mark(NGMark("star.fill", color: .yellow, label: "Избранная"))
        let percent: NGCellValue = .mark(NGMark("percent", label: "Скидка"))
        #expect(NGValueFormat.automatic.string(for: star) == "Избранная")
        #expect(star.sortsBefore(percent))
        #expect(NGCellValue.empty.sortsBefore(star))
    }
}


@Suite("Search")
struct NGSearchTests {
    @Test func wordsMatchFromTheirBeginning() {
        let anna = NGRowFilter.words(in: "Анна #1") + NGRowFilter.words(in: "Berlin")
        let galina = NGRowFilter.words(in: "Галина #4") + NGRowFilter.words(in: "Избранная")
        let search = NGRowFilter(searchText: "анна").searchWords
        #expect(NGRowFilter.matches(searchWords: search, rowWords: anna))
        #expect(!NGRowFilter.matches(searchWords: search, rowWords: galina))
        // Every word must match, in any column; case and diacritics are ignored.
        #expect(NGRowFilter.matches(searchWords: NGRowFilter(searchText: "BER ан").searchWords, rowWords: anna))
        #expect(!NGRowFilter.matches(searchWords: NGRowFilter(searchText: "ber гал").searchWords, rowWords: anna))
        #expect(NGRowFilter.words(in: "Café-Crème") == ["cafe", "creme"])
    }
}


@Suite("Calculator ranges")
struct NGCalculatorRangeTests {
    @Test func largeSelectionsUseTheComplement() {
        let values: [Double?] = (0..<1000).map { $0 % 7 == 0 ? nil : Double($0) }
        let calculator = NGSummaryCalculator(values: values)
        let selection = IndexSet(integersIn: 10..<990)
        let expected: Double = (10..<990).compactMap { values[$0] }.reduce(0, +)
        #expect(calculator.value(for: .sum, scope: .selectedRows, selection: selection) == expected)
        #expect(calculator.value(for: .count, scope: .selectedRows, selection: selection) == Double((10..<990).filter { values[$0] != nil }.count))
        #expect(calculator.value(for: .max, scope: .selectedRows, selection: selection) == 989)
        let head: Double = (0..<10).compactMap { values[$0] }.reduce(0, +)
        let tail: Double = (990..<1000).compactMap { values[$0] }.reduce(0, +)
        let rest = head + tail
        #expect(calculator.value(for: .sum, scope: .excludingSelectedRows, selection: selection) == rest)
    }

    @Test func sharedSourcesWithARowMap() {
        let source: [Double] = [1, 2, .nan, 4, 5]
        let calculator = NGSummaryCalculator(source: source, rowMap: [4, 0, 2], including: .all)
        #expect(calculator.count == 3)
        #expect(calculator.value(for: .sum, scope: .allRows, selection: []) == 6)
        #expect(calculator.value(atRow: 2) == nil)
    }
}

/// The search's own word splitting gives what Foundation's folding gives.
@Test func searchWordsMatchFoundationFolding() {
    let samples = ["Campaign 123", "MGID_Push-Ads", "ЁЛКА ёлка", "Йошкар-Ола", "Привет, Мир!", "Mixed Кейс 42x",
                   "  spaces  ", "", "a.b.c", "Über straße", "Café crème", "日本語 テキスト", "emoji 🙂 here", "ЪЫЬЭЮЯ"]
    for text in samples {
        #expect(NGRowFilter.words(in: text) == NGRowFilter.foldedWords(in: text), "\(text)")
    }
}

/// Words are split where `Character`s that are neither letters nor digits
/// are: marks that folding keeps (viramas) and joiners stay in their word.
@Test func searchWordsKeepMarksAndJoinersInTheirWords() {
    let samples = ["कि नमस्ते", "தமிழ் மொழி", "ಕನ್ನಡ", "မြန်မာ", "ខ្មែរ", "می\u{200C}خواهم", "a\u{200D}b", "Їжак Євген і",
                   "Ђорђе ѐ ѝ", "e\u{301}cole", "x²+y³ ½", "東京タワー 한국어", "مرحبا ١٢٣", "1️⃣ 🇺🇸 👨‍👩‍👧", "ＡＢＣ１２３", "don't"]
    for text in samples {
        let characters = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        #expect(NGRowFilter.words(in: text) == characters, "\(text)")
    }
}

/// Number styles made once give the text that formatting each number with
/// a new style gives.
@Test func keptNumberStylesFormatLikeNewOnes() {
    let formats: [NGValueFormat] = [.automatic, .number(fractionDigits: 0), .number(fractionDigits: 3), .currency(code: "USD"),
                                    .currency(code: "RUB"), .percent(fractionDigits: 1), .date(includesTime: false)]
    // (-0 shows as 0 on purpose: `negativesThatRoundToZeroShowAsZero`.)
    let numbers: [Double] = [0, 1, -1.5, 1234567.891, 0.000123, 99.995, .nan, .infinity, -.infinity, 1e15]
    for identifier in ["en_US", "ru_RU", "de_DE", "ja_JP", "ar_EG"] {
        let locale = Locale(identifier: identifier)
        for format in formats {
            let style = NGNumberStyle(format, locale: locale)
            for number in numbers {
                let expected: String = switch format {
                case .number(let digits): number.formatted(.number.precision(.fractionLength(digits)).locale(locale))
                case .currency(let code): number.formatted(.currency(code: code).locale(locale))
                case .percent(let digits): number.formatted(.percent.precision(.fractionLength(digits)).locale(locale))
                case .automatic, .date, .time: number.formatted(.number.locale(locale))
                }
                #expect(style.string(for: number) == expected, "\(identifier) \(format) \(number)")
            }
        }
    }
}
