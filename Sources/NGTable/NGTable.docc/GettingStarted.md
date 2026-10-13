# Getting Started

Add the package, show a table and fill it with data.

## Overview

A table needs three things: a column definition, a data source that answers
how many rows there are and what each cell's value is, and a place in a view
hierarchy. Everything else is optional.

### Add the package

NGTable is a Swift package for macOS 14 and later.

- **In Xcode:** choose File > Add Package Dependencies, click Add Local to pick
  the package folder (or enter its Git URL), and add the `NGTable` library to
  your app target.
- **In a `Package.swift`:**

```swift
dependencies: [
    .package(url: "https://github.com/ngtable/NGTable", from: "1.0.0"),  // or .package(path: "../NGTable")
],
targets: [
    .target(name: "MyApp", dependencies: ["NGTable"]),
]
```

Then `import NGTable` where you use it.

> Note: Linked as the binary `NGTable.xcframework`, NGTable's enums may get
> new cases in later versions, so a `switch` over one needs `@unknown default`
> (an error in Swift 6 without it). ``NGColumnItem``, ``NGDataColumnItem``,
> ``NGColumnPin`` and ``NGColumnVisibility/State`` are frozen: their cases are
> all there will be.

### Define the columns

Columns are values of ``NGTableColumn``, listed as ``NGColumnItem``s. Each
column has an `id`, which is also the key the data source answers values for:

```swift
let columns: [NGColumnItem] = [
    .column(NGTableColumn("name", title: "Campaign", width: 220, pin: .leading)),
    .column(NGTableColumn("status", title: "Status", width: 120)),
    .column(NGTableColumn("spend", title: "Spend", width: 120,
                          alignment: .automatic, format: .currency(code: "EUR"),
                          summary: .aggregate(.sum))),
    .column(NGTableColumn("clicks", title: "Clicks", width: 100,
                          alignment: .automatic, format: .number(fractionDigits: 0),
                          summary: .aggregate(.sum))),
]
```

`pin: .leading` freezes the name column at the leading edge; `alignment:
.automatic` aligns numbers to the trailing edge. See <doc:DefiningColumns>.

### Provide the data

The data source is any class that adopts ``NGTableViewDataSource``. Keep your
records in an array and answer from it:

```swift
struct Campaign {
    var id: String
    var name: String
    var status: String
    var spend: Double
    var clicks: Int
}

@MainActor
final class CampaignTableData: NGTableViewDataSource {
    var campaigns: [Campaign] = []

    func numberOfRows(in tableView: NGTableView) -> Int {
        campaigns.count
    }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        let campaign = campaigns[row]
        switch column.id {
        case "id": return .text(campaign.id)
        case "name": return .text(campaign.name)
        case "status": return .text(campaign.status)
        case "spend": return .number(campaign.spend)
        case "clicks": return .number(Double(campaign.clicks))
        default: return .empty
        }
    }
}
```

Return `.empty` for columns you don't know: the table may ask about columns
that aren't shown, such as the inputs of a summary formula.

### Show the table

``NGTableView`` is an `NSView` that scrolls by itself. Add it directly to your
view (not inside an `NSScrollView`) and pin it with Auto Layout:

```swift
final class CampaignsViewController: NSViewController, NGTableViewDelegate {
    private let data = CampaignTableData()
    private let table = NGTableView(frame: .zero)

    override func loadView() {
        let root = NSView()
        table.columns = columns
        table.rowIdentifierColumnID = "id"          // Keeps the selection on the same campaigns.
        table.autosaveName = "CampaignsTable"       // Remembers the user's columns.
        table.emptyStateText = "No campaigns"
        table.dataSource = data
        table.delegate = self
        table.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: root.topAnchor),
            table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}
```

The table holds its data source and delegate weakly: keep them alive, as the
view controller above does with `data`.

### Update the data

Whenever the records change, change them and call
``NGTableView/reloadData()`` right away:

```swift
func show(_ campaigns: [Campaign]) {
    data.campaigns = campaigns
    table.reloadData()
}
```

> Important: Call `reloadData()` immediately after replacing the data, before
> selecting rows, scrolling or returning to the run loop. Until then the table
> still asks about the old rows, which may no longer exist, and an index out
> of range would crash your data source.

Setting ``NGTableView/dataSource`` also reloads the table.

### Try the demo

The package contains a demo app with ad campaign data. Open the package in
Xcode, choose the `NGTableDemo` scheme and run it (Command-R). It shows frozen
and grouped columns, marks, a ROI formula, search, a filter checkbox, summary
scopes, row tints, a context menu and row counts up to 100,000. Its source,
`Sources/NGTableDemo/NGTableDemo.swift`, is a complete example.

## Next Steps

- <doc:IntegratingIntoAnApp> walks through a complete setup for records from
  a server: identities, sorting, search, filters, menus and refreshing.
- <doc:DefiningColumns>, <doc:DisplayingValues> and <doc:Summaries> describe
  the column options.
