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
}
#endif
