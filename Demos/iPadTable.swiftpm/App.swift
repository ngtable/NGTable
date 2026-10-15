import NGTable
import SwiftUI
import UIKit

// The app: one screen with the table (NGTableView, a UIKit view, inside
// SwiftUI only to start the app). Names, the On check boxes and statuses
// (a pop-up) are editable; a long press opens menus, a swipe across a row
// its actions; rows drag out as text and text drops in as campaigns;
// Export shares the rows as a workbook or CSV, Reload shows the veil of an
// update.

@main
struct NGTableIPadApp: App {
    var body: some Scene {
        WindowGroup {
            TableScreen()
        }
    }
}

struct TableScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: CampaignsViewController())
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

/// Campaigns with random numbers, their spend changing a few times a second.
final class Campaigns: NGTableViewDataSource {
    struct Campaign {
        var name: String
        var network: String
        var status: String
        var isOn: Bool
        var clicks: Double
        var spend: Double
        var revenue: Double
        var created: Date
    }

    var campaigns: [Campaign]

    init(count: Int) {
        var generator = SystemRandomNumberGenerator()
        let networks = ["Push", "Native", "Video", "Search", "Social"]
        let statuses = ["Active", "Paused", "Finished"]
        campaigns = (0..<count).map { index in
            let clicks = Double(Int.random(in: 0...50_000, using: &generator))
            let spend = Double(Int.random(in: 0...500_000, using: &generator)) / 100
            return Campaign(name: "Campaign \(index + 1)", network: networks[index % networks.count],
                            status: statuses[Int.random(in: 0..<statuses.count, using: &generator)], isOn: index % 3 != 0,
                            clicks: clicks, spend: spend,
                            revenue: spend * Double.random(in: 0.5...2.2, using: &generator),
                            created: Date().addingTimeInterval(-Double(Int.random(in: 0...90 * 86_400, using: &generator))))
        }
    }

    func numberOfRows(in tableView: NGTableView) -> Int { campaigns.count }

    static let statuses = ["Active", "Paused", "Finished"]

    static func status(_ status: String) -> NGCellValue {
        let color: NGNamedColor = status == "Active" ? .green : status == "Paused" ? .orange : .gray
        return .tags([NGTag(status, color: color)])
    }

    /// A row drags out as its name (into Notes, say).
    func tableView(_ tableView: NGTableView, itemsForBeginning session: any UIDragSession, row: Int) -> [UIDragItem] {
        [UIDragItem(itemProvider: NSItemProvider(object: campaigns[row].name as NSString))]
    }

    /// Text from another app drops between rows as new campaigns.
    func tableView(_ tableView: NGTableView, dropSessionDidUpdate session: any UIDropSession, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> UIDropOperation {
        guard session.localDragSession == nil, session.canLoadObjects(ofClass: NSString.self) else { return .forbidden }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .copy
    }

    func tableView(_ tableView: NGTableView, performDrop session: any UIDropSession, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        _ = session.loadObjects(ofClass: NSString.self) { [weak self, weak tableView] strings in
            guard let self, let tableView else { return }
            let names = strings.compactMap { $0 as? String }.flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) }
            let at = min(row, self.campaigns.count)
            let new = names.map { Campaign(name: $0, network: "Search", status: "Active", isOn: true, clicks: 0, spend: 0, revenue: 0, created: Date()) }
            self.campaigns.insert(contentsOf: new, at: at)
            tableView.insertRows(at: IndexSet(at..<(at + new.count)))
        }
        return true
    }

    func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
        switch (column.id, value) {
        case ("name", .text(let name)): campaigns[row].name = name
        case ("on", .bool(let isOn)): campaigns[row].isOn = isOn
        case ("status", .tags(let tags)): campaigns[row].status = tags.first?.title ?? campaigns[row].status
        default: break
        }
    }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        let campaign = campaigns[row]
        switch column.id {
        case "name": return .text(campaign.name)
        case "network": return .tags([NGTag(campaign.network, color: .blue)])
        case "status": return Self.status(campaign.status)
        case "on": return .bool(campaign.isOn)
        case "report": return .link(NGLink("Report", url: URL(string: "https://example.com/campaigns/\(row + 1)")))
        case "clicks": return .number(campaign.clicks)
        case "spend": return .number(campaign.spend)
        case "revenue": return .number(campaign.revenue)
        case "roi": return campaign.spend > 0 ? .number((campaign.revenue - campaign.spend) / campaign.spend) : .empty
        case "created": return .date(campaign.created)
        default: return .empty
        }
    }
}

final class CampaignsViewController: UIViewController, NGTableViewDelegate {
    private let table = NGTableView(frame: .zero)
    private let frameMeter = FrameMeterLabel()
    private let campaigns = Campaigns(count: 20_000)
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Campaigns"
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Export", image: UIImage(systemName: "square.and.arrow.up"), target: self, action: #selector(exportRows(_:))),
            UIBarButtonItem(title: "Reload", image: UIImage(systemName: "arrow.clockwise"), target: self, action: #selector(reload)),
        ]
        var statusColumn = NGTableColumn("status", title: "Status", width: 110, isEditable: true,
                                         editChoices: Campaigns.statuses.map(Campaigns.status))
        statusColumn.opensChoicesOnClick = true
        table.columns = [
            .column(NGTableColumn("name", title: "Campaign", width: 180, pin: .leading, isEditable: true)),
            .column(NGTableColumn("on", title: "On", width: 60, alignment: .center, isEditable: true)),
            .column(NGTableColumn("network", title: "Network", width: 100)),
            .column(statusColumn),
            .column(NGTableColumn("clicks", title: "Clicks", width: 120, format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
            .column(NGTableColumn("spend", title: "Spend", width: 150, format: .currency(code: "USD"), summary: .aggregate(.sum),
                                  changeHighlight: .direction)),
            .column(NGTableColumn("revenue", title: "Revenue", width: 150, format: .currency(code: "USD"), summary: .aggregate(.sum))),
            .column(NGTableColumn("roi", title: "ROI", width: 90, format: .percent(fractionDigits: 1), summary: .aggregate(.average))),
            .column(NGTableColumn("created", title: "Created", width: 130, format: .date(includesTime: false), summary: .aggregate(.min))),
            .column(NGTableColumn("report", title: "Report", width: 90)),
        ]
        table.dataSource = campaigns
        table.delegate = self
        table.allowsMultipleSelection = true
        table.allowsUserGrouping = true
        table.allowsColumnFilters = true
        table.allowsNamedViews = true
        table.exportFileName = "Campaigns"
        table.sortsRows = true
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        frameMeter.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frameMeter)
        // To the bottom edge: the summary row's strip reaches under the home
        // indicator, its values stay above it.
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            frameMeter.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            frameMeter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -48),
        ])
        // `-scrollTest`: scrolls as a finger would (the table's scroll view), for checking it.
        if ProcessInfo.processInfo.arguments.contains("-scrollTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let scroll = self?.table.subviews.compactMap({ $0 as? UIScrollView }).first else { return }
                scroll.setContentOffset(CGPoint(x: 300, y: 4_000), animated: true)
            }
        }
        // A few spends change, a few times a second.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// A long press on rows: what an app would offer for them.
    func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: NGTableColumn?) -> UIMenu? {
        guard !rows.isEmpty else { return nil }
        let title = rows.count == 1 ? campaigns.campaigns[rows.first!].name : "\(rows.count) campaigns"
        let pause = UIAction(title: "Pause", image: UIImage(systemName: "pause.circle")) { [weak self] _ in
            guard let self else { return }
            for row in rows { self.campaigns.campaigns[row].status = "Paused" }
            self.table.reloadData(forRowIndexes: rows, columnIndexes: [3])
        }
        let copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            UIPasteboard.general.string = rows.compactMap { self?.campaigns.campaigns[$0].name }.joined(separator: "\n")
        }
        return UIMenu(title: title, children: [pause, copy])
    }

    /// A swipe across a row: pause it (trailing), or mark it active (leading).
    func tableView(_ tableView: NGTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NGRowAction] {
        let status = edge == .trailing ? "Paused" : "Active"
        let action = NGRowAction(style: edge == .trailing ? .destructive : .regular, title: edge == .trailing ? "Pause" : "Activate") { [weak self] _, row in
            guard let self else { return }
            self.campaigns.campaigns[row].status = status
            self.table.reloadData(forRowIndexes: [row], columnIndexes: [3])
        }
        if edge == .leading { action.backgroundColor = .systemGreen }
        return [action]
    }

    @objc private func exportRows(_ sender: UIBarButtonItem) {
        table.exportDocument(sender)
    }

    /// An update of a second and a half: the table is veiled meanwhile.
    @objc private func reload() {
        table.dataUpdateText = "Loading campaigns…"
        Task {
            await table.updatingData {
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func tick() {
        table.beginUpdates()
        for _ in 0..<20 {
            let row = Int.random(in: 0..<campaigns.campaigns.count)
            campaigns.campaigns[row].spend += Double(Int.random(in: 1...500)) / 100
            table.reloadData(forRowIndexes: [row], columnIndexes: [5, 7])
        }
        table.endUpdates()
    }
}
