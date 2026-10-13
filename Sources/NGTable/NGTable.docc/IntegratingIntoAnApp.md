# Integrating into an App

A complete setup for records loaded from a server: columns, data source,
identity, sorting, search, filters, summaries, menus and refreshing.

## Overview

This guide builds a campaigns screen for an advertising CRM step by step. The
same structure fits any list of records: customers, orders, invoices. The
pieces are:

1. a model decoded from the API;
2. column ids and the column definition in one place;
3. a data source that holds the records in display order and sorts them;
4. a view controller that owns the table, the data source and the controls
   around the table.

### The model

Keep the values the table shows in the record, ready to return. Computed
metrics that depend only on the record, like ROI, are cheap as computed
properties:

```swift
struct Campaign: Decodable, Identifiable {
    enum Status: String, Decodable { case active, paused, finished }

    var id: String
    var name: String
    var status: Status
    var channels: [String]
    var spend: Double
    var revenue: Double
    var clicks: Int
    var impressions: Int
    var isFavorite: Bool

    var roi: Double { spend > 0 ? (revenue - spend) / spend : 0 }
    var ctr: Double { impressions > 0 ? Double(clicks) / Double(impressions) : 0 }
}
```

### Column ids and columns

Define the ids once, so the columns, the data source and formulas can't
disagree:

```swift
enum CampaignColumn {
    static let id = "id"
    static let favorite = "favorite"
    static let name = "name"
    static let status = "status"
    static let channels = "channels"
    static let spend = "spend"
    static let revenue = "revenue"
    static let roi = "roi"
    static let clicks = "clicks"
    static let impressions = "impressions"
    static let ctr = "ctr"

    /// ROI of several campaigns: (Σ revenue − Σ spend) / Σ spend.
    static let roiFormula = NGSummaryFormula("roi", using: [spend, revenue],
                                             otherwise: .average, including: .nonZero) { values in
        guard let totalSpend = values.sum(spend), totalSpend != 0,
              let totalRevenue = values.sum(revenue) else { return nil }
        return (totalRevenue - totalSpend) / totalSpend
    }

    /// CTR of several campaigns: Σ clicks / Σ impressions.
    static let ctrFormula = NGSummaryFormula("ctr", using: [clicks, impressions]) { values in
        guard let totalImpressions = values.sum(impressions), totalImpressions != 0,
              let totalClicks = values.sum(clicks) else { return nil }
        return totalClicks / totalImpressions
    }

    static let all: [NGColumnItem] = [
        .column(NGTableColumn(favorite, title: "", width: 30, alignment: .center,
                              isResizable: false, isMovable: false, showsHeaderDivider: false,
                              pin: .leading, toolTip: "Favorite")),
        .column(NGTableColumn(name, title: "Campaign", width: 240, isHideable: false, pin: .leading)),
        .column(NGTableColumn(status, title: "Status", width: 110)),
        .column(NGTableColumn(channels, title: "Channels", width: 180)),
        .group(NGColumnGroup("money", title: "Money", columns: [
            NGTableColumn(spend, title: "Spend", width: 120, alignment: .automatic,
                          format: .currency(code: "EUR"), summary: .aggregate(.sum)),
            NGTableColumn(revenue, title: "Revenue", width: 120, alignment: .automatic,
                          format: .currency(code: "EUR"), summary: .aggregate(.sum)),
            NGTableColumn(roi, title: "ROI", width: 90, alignment: .automatic,
                          format: .percent(fractionDigits: 1), summary: .formula(roiFormula),
                          toolTip: "Total: (Σ revenue − Σ spend) / Σ spend"),
        ])),
        .group(NGColumnGroup("traffic", title: "Traffic", columns: [
            NGTableColumn(clicks, title: "Clicks", width: 100, alignment: .automatic,
                          format: .number(fractionDigits: 0), summary: .aggregate(.sum)),
            NGTableColumn(impressions, title: "Impressions", width: 120, alignment: .automatic,
                          format: .number(fractionDigits: 0), summary: .aggregate(.sum)),
            NGTableColumn(ctr, title: "CTR", width: 80, alignment: .automatic,
                          format: .percent(fractionDigits: 2), summary: .formula(ctrFormula)),
        ])),
    ]
}
```

The `id` column isn't in the definition: the table asks the data source for
it to identify rows, and a search can include it.

### The data source

The data source keeps the records as received and in display order, and
sorts. A mark that is the same for many rows is made once:

```swift
@MainActor
final class CampaignTableData: NGTableViewDataSource {
    /// Records in the order the server sent them (the "unsorted" order).
    private(set) var received: [Campaign] = []
    /// Records in display order: row `i` of the table is `campaigns[i]`.
    private(set) var campaigns: [Campaign] = []
    private var sortDescriptors: [NSSortDescriptor] = []

    private static let favoriteMark = NGCellValue.mark(NGMark("star.fill", color: .yellow, label: "Favorite"))

    /// Replaces the records, keeping the current sort. Reload the table right after.
    func replace(with campaigns: [Campaign]) {
        received = campaigns
        applySort()
    }

    /// One record changed, at its row. Tell the table right after.
    func update(_ campaign: Campaign, atRow row: Int) {
        campaigns[row] = campaign
        if let index = received.firstIndex(where: { $0.id == campaign.id }) { received[index] = campaign }
    }

    /// Records added after the others (sorted in with the next sort). Tell the table right after.
    func append(_ new: [Campaign]) {
        received += new
        campaigns += new
    }

    /// A record by its id.
    func campaign(withID id: Campaign.ID) -> Campaign? {
        received.first { $0.id == id }
    }

    /// The user clicked a header, or the app set the table's sort.
    func tableView(_ tableView: NGTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortDescriptors = tableView.sortDescriptors
        applySort()
        tableView.reloadData()
    }

    /// Sorts by the table's sort descriptors (several columns: the first
    /// decides, the others break ties), or keeps the received order.
    private func applySort() {
        campaigns = NGSorting.order(ofRows: received.count, by: sortDescriptors) { key, row in
            Self.value(key, of: received[row])
        }.map { received[$0] }
    }

    func numberOfRows(in tableView: NGTableView) -> Int {
        campaigns.count
    }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        Self.value(column.id, of: campaigns[row])
    }

    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? {
        campaigns[row].id
    }

    static func value(_ columnID: String, of campaign: Campaign) -> NGCellValue {
        switch columnID {
        case CampaignColumn.id: .text(campaign.id)
        case CampaignColumn.favorite: campaign.isFavorite ? favoriteMark : .empty
        case CampaignColumn.name: .text(campaign.name)
        case CampaignColumn.status: .tags([statusTag(campaign.status)])
        case CampaignColumn.channels: .tags(campaign.channels.map { NGTag($0) })
        case CampaignColumn.spend: .number(campaign.spend)
        case CampaignColumn.revenue: .number(campaign.revenue)
        case CampaignColumn.roi: .number(campaign.roi)
        case CampaignColumn.clicks: .number(Double(campaign.clicks))
        case CampaignColumn.impressions: .number(Double(campaign.impressions))
        case CampaignColumn.ctr: .number(campaign.ctr)
        default: .empty
        }
    }

    private static func statusTag(_ status: Campaign.Status) -> NGTag {
        switch status {
        case .active: NGTag("Active", color: .green)
        case .paused: NGTag("Paused", color: .orange)
        case .finished: NGTag("Finished", color: .gray)
        }
    }
}
```

### The view controller

The view controller owns the table and its data source (the table only holds
them weakly), sets the table up once, and connects the controls around it:

```swift
@MainActor
final class CampaignsViewController: NSViewController, NGTableViewDelegate {
    private let data = CampaignTableData()
    private let table = NGTableView(frame: .zero)
    private let searchField = NSSearchField()
    private let activeOnly = NSButton(checkboxWithTitle: "Active only", target: nil, action: nil)

    override func loadView() {
        let root = NSView()

        table.columns = CampaignColumn.all
        table.autosaveName = "Campaigns"      // The user's columns survive relaunches.
        table.typeSelectColumnID = CampaignColumn.name
        table.emptyStateText = "No campaigns in this period"
        table.dataSource = data               // Identity comes from identifierForRow.
        table.delegate = self
        table.target = self                   // Double-clicking a campaign opens it.
        table.doubleAction = #selector(openCampaign(_:))

        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        activeOnly.target = self
        activeOnly.action = #selector(filterChanged(_:))

        let controls = NSStackView(views: [searchField, activeOnly])
        for view in [controls, table] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            table.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}
```

### Loading and refreshing

Replace the records and reload in one go. The selection follows the same
campaigns, the scroll position stays, and the filter and summaries are
applied to the new data:

```swift
extension CampaignsViewController {
    func show(_ campaigns: [Campaign]) {
        data.replace(with: campaigns)   // Keeps the current sort.
        table.reloadData()              // Right away, before anything else.
    }
}
```

Call it with every response, whether the first load, a periodic refresh or a
change of period. When only some records change, tell the table which (see
<doc:IntegratingIntoAnApp#Live-updates>) instead of reloading everything.

While a request is running, put the table in its updating state: it fades and
ignores clicks, scrolling, menus and the keyboard, so nobody acts on rows that
are about to change. ``NGTableView/updatingData(_:)`` wraps async work in it:

```swift
extension CampaignsViewController {
    func load(_ period: DateInterval) async {
        do {
            try await table.updatingData {
                show(try await api.campaigns(in: period))
            }
        } catch {
            presentError(error)
        }
    }
}
```

The table stays usable when the request fails, and loads that overlap (the
user picks another period while one loads) keep it updating until the last one
ends. The fade starts after a moment, so a quick response doesn't flash, and a
spinner shows in the middle of the table (turn it off with
``NGTableView/showsDataUpdateIndicator``). For long requests, add a caption
under it with ``NGTableView/dataUpdateText``, e.g. "Loading 18,000
campaigns…"; it can change while loading, to show progress. The spinner also
takes the place of the empty state, so there's no need to clear
``NGTableView/emptyStateText`` while loading: it shows again if the response
has no rows. Set it with the first response, so a table that hasn't loaded yet
doesn't say there's nothing. For code that isn't async, set
``NGTableView/isUpdatingData`` instead.

### Live updates

For data that changes a few records at a time (statuses from a socket, a
campaign paused from a menu), tell the table what changed, like an
`NSTableView`: change your data first, then call

- ``NGTableView/reloadData(forRowIndexes:columnIndexes:)`` for changed values
  (`columnIndexes` are indexes in ``NGTableView/tableColumns``). The rows'
  summaries follow every column, but their search words, sort and group keys
  and column filters are read again only for the columns you name: report
  every column that changed (a renamed campaign: its name column too), or
  all of them;
- ``NGTableView/insertRows(at:withAnimation:)``,
  ``NGTableView/removeRows(at:withAnimation:)`` and
  ``NGTableView/moveRow(at:to:)`` for records that come, go or move;
- ``NGTableView/noteNumberOfRowsChanged()`` for records added at or removed
  from the end.

The selection, its anchor and the summaries follow the rows; only the changed
rows are read again, and a frame is drawn only when one of them is visible. Wrap
several updates in ``NGTableView/beginUpdates()`` and
``NGTableView/endUpdates()`` to finish them once: each update's indexes refer
to the rows after the updates before it, and the table reads the values at the
end. Row indexes are data source rows, as everywhere. Don't `await` between
the two: after inserts, removes or moves the rows show and take clicks and
keys again only at `endUpdates()` (the table logs such a batch, subsystem "NGTable").

```swift
extension CampaignsViewController {
    func statusChanged(_ campaign: Campaign) {
        // The table finds rows by their identity (`identifierForRow` above).
        let row = table.row(forIdentifier: campaign.id)
        guard row >= 0 else { return }
        data.update(campaign, atRow: row)
        table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(0..<table.numberOfColumns))
    }

    func campaignsArrived(_ new: [Campaign]) {
        data.append(new)
        table.noteNumberOfRowsChanged()   // The new rows at the end.
    }
}
```

The data source must have the rows the updates make, or the table reads
everything again (and asserts in debug builds). With an animation
(`withAnimation:` options other than none, or a diffable data source applying
with `animatingDifferences`), the batch's rows in view slide to their new
places, new rows fade in and removed ones fade out; without one, rows change
at once. Moves by the table's own sort animate with
``NGTableView/animatesSortMoves``, off by default: a feed ticking several
times a second reads better without motion.
With ``NGTableView/sortsRows`` the table keeps the rows sorted as values
change; otherwise sort and move the row, or sort and call
``NGTableView/reorderRows(from:to:)``
(see <doc:SelectionAndSorting#Re-sorting-without-reloading>).

To show what changed, give columns a ``NGTableColumn/changeHighlight``: a
visible cell whose value an update changed flashes and fades, green or red for
numbers that went up or down with ``NGChangeHighlight/direction``. Values
reported but unchanged don't flash, a flash follows its record when the sort
moves it, and ``NGTableView/changeHighlightDuration`` sets how long it lasts
(0 turns flashes off).

```swift
NGTableColumn("spend", title: "Spend", format: .currency(code: "USD"), changeHighlight: .direction)
```

When working out the changes is the hard part (a server returns the whole list
again, sorted differently), let ``NGTableViewDiffableDataSource`` do it, as
`NSTableViewDiffableDataSource` does: apply a snapshot of record ids, and it
inserts, removes and moves rows to match in one pass. Mark changed records with
``NGDiffableDataSourceSnapshot/reloadItems(_:)``; records in both snapshots
are not read again.

```swift
let dataSource = NGTableViewDiffableDataSource<Int, Campaign.ID>(tableView: table) { [weak data] _, column, _, id in
    data?.campaign(withID: id).map { CampaignTableData.value(column.id, of: $0) } ?? .empty
}

func campaignsArrived(_ campaigns: [Campaign], changed: [Campaign.ID]) {
    data.replace(with: campaigns)
    var snapshot = NGDiffableDataSourceSnapshot<Int, Campaign.ID>()
    snapshot.appendSections([0])
    snapshot.appendItems(campaigns.map(\.id))
    snapshot.reloadItems(changed)
    dataSource.apply(snapshot)
}
```

The diffable data source makes itself the table's data source; keep a
reference to it. Sort in its ``NGTableViewDiffableDataSource/sortDescriptorsDidChange``
by applying a snapshot in the new order. Sections are flattened into one list
of rows; group rows by a column with ``NGTableView/rowGrouping`` instead (see
<doc:GroupingRows>).

### Sorting

The data source above sorts in
``NGTableViewDataSource/tableView(_:sortDescriptorsDidChange:)``, as for an
`NSTableView`. Clicking a header sorts by its column first and keeps the
previous sorts for ties, so "Status, then Spend" is two clicks. For a default
sort, set it once the data source is in place:

```swift
table.dataSource = data
table.sortDescriptors = [NSSortDescriptor(key: CampaignColumn.spend, ascending: false)]
```

Reloading after a sort is simple and fine for a few thousand rows. For large
tables, or with row grouping (whose subtotals would be computed again), keep
the order as indexes and call ``NGTableView/reorderRows(from:to:)`` instead:
nothing is read again (see
<doc:SelectionAndSorting#Re-sorting-without-reloading>).

If the server sorts instead (for paged data), request the new order in the
same method and call `show(_:)` with the response.

### Search and filters

```swift
extension CampaignsViewController {
    @objc func filterChanged(_ sender: Any?) {
        var filter = NGRowFilter(searchText: searchField.stringValue,
                                 columnIDs: [CampaignColumn.name, CampaignColumn.id, CampaignColumn.channels])
        if activeOnly.state == .on {
            filter.isIncluded = { [weak self] row in
                self?.data.campaigns[row].status == .active
            }
        }
        table.rowFilter = filter
        table.emptyStateText = filter.isEmpty ? "No campaigns in this period" : "No matching campaigns"
    }
}
```

Listing `columnIDs` makes the search find campaign ids, which aren't shown.
After `show(_:)`, the filter applies to the new data by itself.

### Actions

Menus and buttons act on records, identified by their ids. Read the ids when
the menu is built or the button is clicked, not later, because the data may
be reloaded in between:

```swift
extension CampaignsViewController {
    func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet,
                   clickedRow: Int?, column: NGTableColumn?) -> NSMenu? {
        guard !rows.isEmpty else { return nil }
        let ids = rows.map { data.campaigns[$0].id }
        let menu = NSMenu()
        let pause = NSMenuItem(title: "Pause", action: #selector(pause(_:)), keyEquivalent: "")
        pause.target = self
        pause.representedObject = ids
        menu.addItem(pause)
        return menu
    }

    @objc func pause(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String] else { return }
        print("Pause", ids)  // Call your API, then `show(_:)` the updated campaigns.
    }

    /// The table's `doubleAction`, with `table.target = self`.
    @objc func openCampaign(_ sender: NGTableView) {
        guard sender.clickedRow >= 0 else { return }
        print("Open", data.campaigns[sender.clickedRow].id)
    }

    /// The campaigns a toolbar button acts on.
    var selectedCampaignIDs: [String] {
        table.selectedRowIndexes.map { data.campaigns[$0].id }
    }
}
```

### Highlighting

```swift
extension CampaignsViewController {
    private static let lossTint = NSColor.systemRed.withAlphaComponent(0.10)

    func tableView(_ tableView: NGTableView, backgroundColorForRow row: Int) -> NSColor? {
        data.campaigns[row].roi < 0 ? Self.lossTint : nil
    }

    func tableView(_ tableView: NGTableView, markerColorForRow row: Int) -> NSColor? {
        data.campaigns[row].status == .active ? .systemGreen : nil
    }
}
```

## Checklist

- Call ``NGTableView/reloadData()`` immediately after every change of the
  data, before selecting, scrolling or returning to the run loop.
- Give rows an identity (`identifierForRow` or
  ``NGTableView/rowIdentifierColumnID``), unique per record.
- Keep the data source and delegate alive; the table holds them weakly.
- Capture `self` weakly in `isIncluded`.
- Row indexes are only valid until the next reload: store ids, not
  indexes, in menus, undo actions and asynchronous work.
- Row indexes in the API are data source indexes, also while filtering.
- Keep `valueFor` a cheap lookup that returns `.empty` for unknown columns.
- Return static color constants for tints and markers.
- Sort new data by ``NGTableView/sortDescriptors`` before reloading; when
  only the order changes, call ``NGTableView/reorderRows(from:to:)`` instead.
- Keep column ids stable between versions: saved layouts refer to them.
- Give every table its own ``NGTableView/autosaveName``.
- Give every different formula and value filter its own name.
- Add Copy and Select All to the Edit menu of your main menu.
