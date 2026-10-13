import AppKit
import NGTable
import SwiftUI

// The three tables, each showing the feed the way an app would. Sorted by
// amount: NGTable sorts the rows itself (`sortsRows`, moving the changed
// ones); for NSTableView and SwiftUI's Table, which leave sorting to the app,
// the app sorts them again after each tick and reloads the rows in view (or
// sets the model's rows). Unsorted: NGTable and NSTableView reload only the
// changed rows (NSTableView only those in view), and the changed rows of
// SwiftUI's model are set.

/// Rows sorted by amount, largest first (when the feed shows sorted).
func sortedByAmount(_ feed: Feed) -> [Int] {
    var order = Array(0..<feed.count)
    let price = feed.price, quantity = feed.quantity
    order.sort { price[$0] * quantity[$0] > price[$1] * quantity[$1] }
    return order
}

protocol Engine: AnyObject {
    var title: String { get }
    var view: NSView { get }
    /// After a tick of the feed.
    func feedChanged()
}

enum Columns {
    static let ids = ["trade", "pair", "side", "price", "quantity", "amount", "change", "updates"]
    static let titles = ["Trade", "Pair", "Side", "Price", "Quantity", "Amount", "Change %", "Updates"]
    static let widths: [Double] = [80, 110, 60, 110, 100, 130, 90, 80]
    static let isNumber = [true, false, false, true, true, true, true, true]
    static let digits = [0, 0, 0, 2, 2, 2, 2, 0]
}

// MARK: NGTable

final class NGEngine: NSObject, Engine, NGTableViewDataSource {
    let title = "NGTable"
    private let feed: Feed
    private let table = NGTableView(frame: .zero)
    var view: NSView { table }

    init(feed: Feed) {
        self.feed = feed
        super.init()
        table.columns = Columns.ids.indices.map { index in
            .column(NGTableColumn(Columns.ids[index], title: Columns.titles[index], width: Columns.widths[index],
                                  alignment: Columns.isNumber[index] ? .trailing : .leading,
                                  headerAlignment: Columns.isNumber[index] ? .trailing : .leading,
                                  format: Columns.isNumber[index] ? .number(fractionDigits: Columns.digits[index]) : .automatic))
        }
        table.dataSource = self
        if feed.isSorted {
            table.sortsRows = true
            table.sortDescriptors = [NSSortDescriptor(key: "amount", ascending: false)]
        }
    }

    func numberOfRows(in tableView: NGTableView) -> Int { feed.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        switch column.id {
        case "trade": .number(Double(row + 1))
        case "pair": .text(Feed.pairs[feed.pair[row]])
        case "side": .text(feed.isSell[row] ? "Sell" : "Buy")
        case "price": .number(feed.price[row])
        case "quantity": .number(feed.quantity[row])
        case "amount": .number(feed.amount(row))
        case "change": .number(feed.change(row))
        case "updates": .number(Double(feed.updates[row]))
        default: .empty
        }
    }

    func feedChanged() {
        table.reloadData(forRows: feed.changed, columnIndexes: IndexSet([3, 4, 5, 6, 7]))
    }
}

// MARK: NSTableView

final class NSEngine: NSObject, Engine, NSTableViewDataSource, NSTableViewDelegate {
    let title = "NSTableView"
    private let feed: Feed
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// Display row → feed row (sorted by the app, as NSTableView doesn't sort).
    private var order: [Int]
    var view: NSView { scrollView }

    init(feed: Feed) {
        self.feed = feed
        order = feed.isSorted ? sortedByAmount(feed) : Array(0..<feed.count)
        super.init()
        for index in Columns.ids.indices {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Columns.ids[index]))
            column.title = Columns.titles[index]
            column.width = Columns.widths[index]
            if Columns.isNumber[index] { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { feed.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = Columns.ids.firstIndex(of: tableColumn.identifier.rawValue) else { return nil }
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = tableColumn.identifier
            field.font = font
            field.lineBreakMode = .byTruncatingTail
            field.alignment = Columns.isNumber[index] ? .right : .left
        }
        field.stringValue = text(column: index, row: order[row])
        return field
    }

    private func text(column: Int, row: Int) -> String {
        let number: Double
        switch Columns.ids[column] {
        case "trade": number = Double(row + 1)
        case "pair": return Feed.pairs[feed.pair[row]]
        case "side": return feed.isSell[row] ? "Sell" : "Buy"
        case "price": number = feed.price[row]
        case "quantity": number = feed.quantity[row]
        case "amount": number = feed.amount(row)
        case "change": number = feed.change(row)
        default: number = Double(feed.updates[row])
        }
        return number.formatted(.number.precision(.fractionLength(Columns.digits[column])))
    }

    func feedChanged() {
        let visible = table.rows(in: table.visibleRect)
        if feed.isSorted {
            // Sorted again; the rows in view may all be others now.
            order = sortedByAmount(feed)
            table.reloadData(forRowIndexes: IndexSet(integersIn: Range(visible) ?? 0..<0), columnIndexes: IndexSet(integersIn: 0..<Columns.ids.count))
            return
        }
        // Only the changed rows in view: the rest are made when they scroll in.
        let rows = IndexSet(feed.changed.filter { visible.contains($0) })
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet([3, 4, 5, 6, 7]))
    }
}

// MARK: SwiftUI Table

struct TradeRow: Identifiable {
    let id: Int
    var pair: String
    var side: String
    var price: Double
    var quantity: Double
    var amount: Double
    var change: Double
    var updates: Int
}

@Observable final class TradeRows {
    var rows: [TradeRow] = []
}

struct TradeTable: View {
    let model: TradeRows

    var body: some View {
        Table(model.rows) {
            TableColumn("Trade") { Text($0.id + 1, format: .number) }.width(80)
            TableColumn("Pair", value: \.pair).width(110)
            TableColumn("Side", value: \.side).width(60)
            TableColumn("Price") { Text($0.price, format: .number.precision(.fractionLength(2))) }.width(110)
            TableColumn("Quantity") { Text($0.quantity, format: .number.precision(.fractionLength(2))) }.width(100)
            TableColumn("Amount") { Text($0.amount, format: .number.precision(.fractionLength(2))) }.width(130)
            TableColumn("Change %") { Text($0.change, format: .number.precision(.fractionLength(2))) }.width(90)
            TableColumn("Updates") { Text($0.updates, format: .number) }.width(80)
        }
        .monospacedDigit()
    }
}

final class SwiftUIEngine: Engine {
    let title = "SwiftUI Table"
    private let feed: Feed
    private let model = TradeRows()
    let view: NSView

    init(feed: Feed) {
        self.feed = feed
        let order = feed.isSorted ? sortedByAmount(feed) : Array(0..<feed.count)
        model.rows = order.map { row in
            TradeRow(id: row, pair: Feed.pairs[feed.pair[row]], side: feed.isSell[row] ? "Sell" : "Buy", price: feed.price[row],
                     quantity: feed.quantity[row], amount: feed.amount(row), change: feed.change(row), updates: feed.updates[row])
        }
        view = NSHostingView(rootView: TradeTable(model: model))
    }

    func feedChanged() {
        if feed.isSorted {
            // Sorted again by the app (Table shows the rows in the order given).
            model.rows = sortedByAmount(feed).map { row in
                TradeRow(id: row, pair: Feed.pairs[feed.pair[row]], side: feed.isSell[row] ? "Sell" : "Buy", price: feed.price[row],
                         quantity: feed.quantity[row], amount: feed.amount(row), change: feed.change(row), updates: feed.updates[row])
            }
            return
        }
        // The rows out of the model while they change (one copy, one change
        // the view sees), then back.
        var rows: [TradeRow] = []
        swap(&rows, &model.rows)
        for row in feed.changed {
            rows[row].price = feed.price[row]
            rows[row].quantity = feed.quantity[row]
            rows[row].amount = feed.amount(row)
            rows[row].change = feed.change(row)
            rows[row].updates = feed.updates[row]
        }
        model.rows = rows
    }
}
