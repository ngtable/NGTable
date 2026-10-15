import NGTable
import SwiftUI
import UIKit

// The app: one screen with the table (NGTableView, a UIKit view, inside
// SwiftUI only to start the app).

@main
struct NGTableIPadApp: App {
    var body: some Scene {
        WindowGroup {
            TableScreen()
        }
    }
}

struct TableScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CampaignsViewController { CampaignsViewController() }
    func updateUIViewController(_ controller: CampaignsViewController, context: Context) {}
}

/// Campaigns with random numbers, their spend changing a few times a second.
final class Campaigns: NGTableViewDataSource {
    struct Campaign {
        var name: String
        var network: String
        var status: String
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
                            status: statuses[Int.random(in: 0..<statuses.count, using: &generator)], clicks: clicks, spend: spend,
                            revenue: spend * Double.random(in: 0.5...2.2, using: &generator),
                            created: Date().addingTimeInterval(-Double(Int.random(in: 0...90 * 86_400, using: &generator))))
        }
    }

    func numberOfRows(in tableView: NGTableView) -> Int { campaigns.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        let campaign = campaigns[row]
        switch column.id {
        case "name": return .text(campaign.name)
        case "network": return .tags([NGTag(campaign.network, color: .blue)])
        case "status":
            let color: NGNamedColor = campaign.status == "Active" ? .green : campaign.status == "Paused" ? .orange : .gray
            return .tags([NGTag(campaign.status, color: color)])
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
        table.columns = [
            .column(NGTableColumn("name", title: "Campaign", width: 180, pin: .leading)),
            .column(NGTableColumn("network", title: "Network", width: 100)),
            .column(NGTableColumn("status", title: "Status", width: 100)),
            .column(NGTableColumn("clicks", title: "Clicks", width: 120, format: .number(fractionDigits: 0), summary: .aggregate(.sum))),
            .column(NGTableColumn("spend", title: "Spend", width: 150, format: .currency(code: "USD"), summary: .aggregate(.sum),
                                  changeHighlight: .direction)),
            .column(NGTableColumn("revenue", title: "Revenue", width: 150, format: .currency(code: "USD"), summary: .aggregate(.sum))),
            .column(NGTableColumn("roi", title: "ROI", width: 90, format: .percent(fractionDigits: 1), summary: .aggregate(.average))),
            .column(NGTableColumn("created", title: "Created", width: 130, format: .date(includesTime: false), summary: .aggregate(.min))),
        ]
        table.dataSource = campaigns
        table.delegate = self
        table.allowsMultipleSelection = true
        table.allowsUserGrouping = true
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
            self.table.reloadData(forRowIndexes: rows, columnIndexes: [2])
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
            self.table.reloadData(forRowIndexes: [row], columnIndexes: [2])
        }
        if edge == .leading { action.backgroundColor = .systemGreen }
        return [action]
    }

    private func tick() {
        table.beginUpdates()
        for _ in 0..<20 {
            let row = Int.random(in: 0..<campaigns.campaigns.count)
            campaigns.campaigns[row].spend += Double(Int.random(in: 1...500)) / 100
            table.reloadData(forRowIndexes: [row], columnIndexes: [4, 6])
        }
        table.endUpdates()
    }
}
