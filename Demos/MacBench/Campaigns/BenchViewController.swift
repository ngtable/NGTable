//
//  BenchViewController.swift
//  NGTable Mac Bench
//
//  A test bench for NGTable on the real campaigns table (its columns, column groups,
//  summary formulas, tags and marks, and its data source), fed with synthetic campaigns
//  (`BenchCampaigns`) instead of the server's. Offline, without signing in. The bar sets the size
//  and the share of empty values, groups by up to three columns, filters, and changes campaigns
//  live; the status line shows what the last operations cost.
//

import AppKit
import NGTable

final class BenchViewController: NSViewController, NGTableViewDelegate {
    private let data = CampaignTableData()
    private let table = NGTableView(frame: .zero)
    /// The bench's own copy of the campaigns, changed by the live updates.
    private var rows: [CampaignRow] = []
    private var seed: UInt64 = 1
    private var generation = 0

    private let sizePopup = NSPopUpButton()
    private let emptyPopup = NSPopUpButton()
    private let newDataButton = NSButton(title: "Новые данные", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let activeOnlyBox = NSButton(checkboxWithTitle: "Только активные", target: nil, action: nil)
    private let groupPopups = (0..<3).map { _ in NSPopUpButton() }
    private let collapsedBox = NSButton(checkboxWithTitle: "Свёрнуты", target: nil, action: nil)
    private let collapseAllButton = NSButton(title: "Свернуть все", target: nil, action: nil)
    private let expandAllButton = NSButton(title: "Развернуть все", target: nil, action: nil)
    private let liveBox = NSButton(checkboxWithTitle: "Живые обновления", target: nil, action: nil)
    private let ratePopup = NSPopUpButton()
    private let perTickPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")

    private static let sizes = [1_000, 10_000, 18_000, 50_000, 100_000, 200_000]
    private static let emptyShares = [0.0, 0.05, 0.25, 0.5]
    private static let groupings: [(title: String, columnID: String?)] = [
        ("—", nil), ("Сеть", CampaignsTable.networkID), ("Источник", CampaignColumn.source.rawValue),
        ("Аккаунт", CampaignColumn.account.rawValue), ("Группа", CampaignColumn.group.rawValue),
        ("Владелец", CampaignColumn.owner.rawValue), ("Статус", CampaignColumn.status.rawValue),
    ]
    /// Pauses between ticks (after each tick, so the real rate is lower: the status shows it).
    private static let rates: [(title: String, interval: Duration)] = [
        ("1 с", .seconds(1)), ("250 мс", .milliseconds(250)), ("50 мс", .milliseconds(50)),
        ("10 мс", .milliseconds(10)), ("5 мс", .milliseconds(5)), ("3 мс", .milliseconds(3)), ("1 мс", .milliseconds(1)),
    ]
    private static let perTick = [1, 10, 100, 1_000]
    private static let problemMarker = NSColor.systemOrange

    private var ticker: Task<Void, Never>?
    private var timings: [String: Duration] = [:]

    override func loadView() {
        sizePopup.addItems(withTitles: Self.sizes.map { "\($0.formatted()) строк" })
        sizePopup.selectItem(at: 2)
        emptyPopup.addItems(withTitles: Self.emptyShares.map { "Пустых \(Int($0 * 100)) %" })
        emptyPopup.selectItem(at: 1)
        for popup in groupPopups {
            popup.addItems(withTitles: Self.groupings.map(\.title))
        }
        groupPopups[0].toolTip = "Группировка, первый уровень"
        ratePopup.addItems(withTitles: Self.rates.map(\.title))
        ratePopup.selectItem(at: 1)
        perTickPopup.addItems(withTitles: Self.perTick.map { "по \($0.formatted())" })
        perTickPopup.selectItem(at: 1)
        collapsedBox.state = .on
        applyLaunchArguments()
        searchField.placeholderString = "Поиск"
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actions: [(NSControl, Selector)] = [
            (sizePopup, #selector(regenerate(_:))), (emptyPopup, #selector(regenerate(_:))),
            (newDataButton, #selector(newData(_:))), (searchField, #selector(filterChanged(_:))),
            (activeOnlyBox, #selector(filterChanged(_:))), (collapsedBox, #selector(groupingChanged(_:))),
            (collapseAllButton, #selector(collapseAll(_:))), (expandAllButton, #selector(expandAll(_:))),
            (liveBox, #selector(liveChanged(_:))), (ratePopup, #selector(liveChanged(_:))), (perTickPopup, #selector(liveChanged(_:))),
        ] + groupPopups.map { ($0, #selector(groupingChanged(_:))) }
        for (control, action) in actions {
            control.target = self
            control.action = action
        }
        for button in [newDataButton, collapseAllButton, expandAllButton] {
            button.bezelStyle = .rounded
        }

        let dataBar = bar([sizePopup, emptyPopup, newDataButton, separator(), searchField, activeOnlyBox, NSView(), statusLabel])
        let groupLabel = NSTextField(labelWithString: "Группировка:")
        let groupBar = bar([groupLabel] + groupPopups + [collapsedBox, collapseAllButton, expandAllButton, separator(),
                                                         liveBox, ratePopup, perTickPopup, NSView()])

        // Live numbers flash green or red as they go up or down.
        table.columns = CampaignsTable.columns.map { item in
            func highlighted(_ column: NGTableColumn) -> NGTableColumn {
                var column = column
                if column.isNumeric { column.changeHighlight = .direction }
                // Profit as bars, ROI colored by sign, like a dashboard.
                if column.id == CampaignColumn.profit.rawValue { column.conditionalFormat = .dataBar(.green, negative: .red) }
                if column.id == CampaignColumn.roi.rawValue {
                    column.conditionalFormat = .textColor([NGColorRule(.below(0), color: .red), NGColorRule(.above(0), color: .green)])
                }
                return column
            }
            switch item {
            case .column(let column):
                return .column(highlighted(column))
            case .group(var group):
                group.columns = group.columns.map(highlighted)
                return .group(group)
            }
        }
        // The table sorts the rows itself and keeps them sorted under live updates.
        table.sortsRows = true
        // Filters in the column headers, like a spreadsheet's.
        table.allowsColumnFilters = true
        // Saved views (columns, sort, filters, grouping) in the header menu.
        table.allowsNamedViews = true
        table.exportFileName = "Стенд"
        table.autosaveName = "Bench"
        table.typeSelectColumnID = CampaignColumn.name.rawValue
        table.emptyStateText = "Нет кампаний"
        table.dataUpdateText = "Генерация кампаний…"
        table.dataSource = data
        table.delegate = self
        // -BenchSort profit: the table sorts by that column, descending, and keeps it sorted live
        // (after `autosaveName`, which restores the saved sort).
        if let key = UserDefaults.standard.string(forKey: "BenchSort") {
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: false)]
        }

        let stack = NSStackView(views: [dataBar, groupBar, table])
        stack.orientation = .vertical
        stack.spacing = 0
        for view in [dataBar, groupBar, table] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            // Below the toolbar of the full-size content view.
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        generate()
    }

    /// Settings from launch arguments, for profiling runs: -BenchRows 18000 -BenchGroups network,status
    /// -BenchCollapsed NO -BenchLive 1000 (changed campaigns per tick, at 250 ms).
    private func applyLaunchArguments() {
        let defaults = UserDefaults.standard
        if let rows = defaults.object(forKey: "BenchRows") as? Int ?? Int(defaults.string(forKey: "BenchRows") ?? ""),
           let index = Self.sizes.firstIndex(of: rows) {
            sizePopup.selectItem(at: index)
        }
        if let groups = defaults.string(forKey: "BenchGroups") {
            for (popup, id) in zip(groupPopups, groups.split(separator: ",")) {
                if let index = Self.groupings.firstIndex(where: { $0.columnID == String(id) }) { popup.selectItem(at: index) }
            }
        }
        if defaults.object(forKey: "BenchCollapsed") != nil {
            collapsedBox.state = defaults.bool(forKey: "BenchCollapsed") ? .on : .off
        }
        // -BenchRate 50: milliseconds between ticks (1000, 250, 50, 10, 5, 3 or 1).
        if let rate = Int(defaults.string(forKey: "BenchRate") ?? ""),
           let index = Self.rates.firstIndex(where: { $0.interval == .milliseconds(rate) }) {
            ratePopup.selectItem(at: index)
        }
        if let live = Int(defaults.string(forKey: "BenchLive") ?? ""), let index = Self.perTick.firstIndex(of: live) {
            perTickPopup.selectItem(at: index)
            liveBox.state = .on
        }
    }

    private func bar(_ views: [NSView]) -> NSStackView {
        let bar = NSStackView(views: views)
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        return bar
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    // Live updates run only while shown.
    override func viewDidAppear() {
        super.viewDidAppear()
        liveChanged(nil)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        ticker?.cancel()
        ticker = nil
    }

    // MARK: Data

    @objc private func regenerate(_ sender: Any?) {
        generate()
    }

    @objc private func newData(_ sender: Any?) {
        seed &+= 1
        generate()
    }

    /// Makes the campaigns off the main thread (with their cell values), then reloads.
    private func generate() {
        generation += 1
        let generation = generation
        let count = Self.sizes[max(0, sizePopup.indexOfSelectedItem)]
        let emptyShare = Self.emptyShares[max(0, emptyPopup.indexOfSelectedItem)]
        let seed = seed
        table.isUpdatingData = true
        Task { [weak self] in
            let start = ContinuousClock.now
            let (rows, cells) = await Task.detached(priority: .userInitiated) {
                let rows = BenchCampaigns.make(count: count, emptyShare: emptyShare, seed: seed)
                return (rows, CampaignTableData.cells(of: rows))
            }.value
            guard let self, self.generation == generation else { return }
            self.record("генерация", ContinuousClock.now - start)
            self.rows = rows
            let reload = ContinuousClock.now
            self.data.replace(with: rows, cells: cells)
            self.table.reloadData()
            self.applyGrouping()
            self.record("reloadData", ContinuousClock.now - reload)
            self.table.isUpdatingData = false
        }
    }

    // MARK: Filter and grouping

    @objc private func filterChanged(_ sender: Any?) {
        let start = ContinuousClock.now
        let text = searchField.stringValue
        let activeOnly = activeOnlyBox.state == .on
        var filter = NGRowFilter(searchText: text)
        if activeOnly {
            filter.isIncluded = { [weak self] row in self?.data.campaign(at: row).status == .active }
        }
        table.rowFilter = filter.isEmpty ? nil : filter
        table.emptyStateText = table.rowFilter == nil ? "Нет кампаний" : "Ничего не найдено"
        record("фильтр", ContinuousClock.now - start)
    }

    @objc private func groupingChanged(_ sender: Any?) {
        let start = ContinuousClock.now
        applyGrouping()
        record("группировка", ContinuousClock.now - start)
    }

    private func applyGrouping() {
        let columnIDs = groupPopups.compactMap { Self.groupings[max(0, $0.indexOfSelectedItem)].columnID }
        table.rowGrouping = columnIDs.isEmpty ? nil
            : NGRowGrouping(columnIDs: columnIDs, startsCollapsed: collapsedBox.state == .on)
    }

    @objc private func collapseAll(_ sender: Any?) {
        let start = ContinuousClock.now
        table.collapseGroup(nil, collapseChildren: true)
        record("свернуть", ContinuousClock.now - start)
    }

    @objc private func expandAll(_ sender: Any?) {
        let start = ContinuousClock.now
        table.expandGroup(nil, expandChildren: true)
        record("развернуть", ContinuousClock.now - start)
    }

    // MARK: Live updates

    @objc private func liveChanged(_ sender: Any?) {
        ticker?.cancel()
        ticker = nil
        guard liveBox.state == .on, view.window != nil else { return }
        let interval = Self.rates[max(0, ratePopup.indexOfSelectedItem)].interval
        let perTick = Self.perTick[max(0, perTickPopup.indexOfSelectedItem)]
        // -BenchLiveSeconds 10: stop after that long (to see what memory does afterwards).
        let seconds = Int(UserDefaults.standard.string(forKey: "BenchLiveSeconds") ?? "")
        let stop = seconds.map { ContinuousClock.now.advanced(by: .seconds($0)) }
        ticker = Task { [weak self] in
            var random = BenchCampaigns.Random(seed: UInt64(Date.now.timeIntervalSince1970))
            while !Task.isCancelled, stop.map({ ContinuousClock.now < $0 }) ?? true {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.tick(changing: perTick, random: &random)
            }
        }
    }

    /// Advances some campaigns and tells the table which rows changed.
    private func tick(changing count: Int, random: inout BenchCampaigns.Random) {
        guard !rows.isEmpty, !table.isUpdatingData else { return }
        let start = ContinuousClock.now
        var changed: [CampaignRow] = []
        for _ in 0..<min(count, rows.count) {
            let index = Int.random(in: 0..<rows.count, using: &random)
            rows[index] = BenchCampaigns.advanced(rows[index], random: &random)
            changed.append(rows[index])
        }
        let tableRows = data.update(changed)
        let tableStart = ContinuousClock.now
        table.reloadData(forRowIndexes: tableRows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        let end = ContinuousClock.now
        // The bench's own work (new campaigns and their cells) and the table's, apart.
        timings["тик: таблица"] = end - tableStart
        record("тик", end - start)
        logTick(total: end - start, table: end - tableStart)
    }

    // -BenchLog YES: averages of the ticks once a second on stdout, for measuring runs
    // (start the app's binary from a terminal to see them).
    private var logged: (ticks: Int, total: Duration, table: Duration, since: ContinuousClock.Instant) = (0, .zero, .zero, .now)

    private func logTick(total: Duration, table: Duration) {
        guard UserDefaults.standard.bool(forKey: "BenchLog") else { return }
        logged.ticks += 1
        logged.total += total
        logged.table += table
        guard ContinuousClock.now - logged.since >= .seconds(1) else { return }
        print("BENCH rows=\(rows.count) ticks=\(logged.ticks) tick=\(Self.milliseconds(logged.total / logged.ticks)) table=\(Self.milliseconds(logged.table / logged.ticks))")
        fflush(stdout)
        logged = (0, .zero, .zero, .now)
    }

    // MARK: Status

    private static let timingOrder = ["генерация", "reloadData", "фильтр", "группировка", "свернуть", "развернуть",
                                      "тик", "тик: таблица"]

    private func record(_ name: String, _ duration: Duration) {
        timings[name] = duration
        if name == "тик" { countTick() }
        let parts = Self.timingOrder.compactMap { name in
            timings[name].map { "\(name) \(Self.milliseconds($0))" }
        }
        let rate = ticker != nil && ticksPerSecond > 0 ? ["\(ticksPerSecond) тиков/с"] : []
        statusLabel.stringValue = (["\(rows.count.formatted()) кампаний"] + parts + rate).joined(separator: " · ")
    }

    /// Ticks in the last whole second: the real rate of the live updates.
    private var ticksPerSecond = 0
    private var tickCount = 0
    private var tickCountStart = ContinuousClock.now

    private func countTick() {
        tickCount += 1
        let now = ContinuousClock.now
        guard now - tickCountStart >= .seconds(1) else { return }
        ticksPerSecond = tickCount
        tickCount = 0
        tickCountStart = now
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        return ms < 10 ? String(format: "%.1f мс", ms) : "\(Int(ms.rounded())) мс"
    }

    // MARK: NGTableViewDelegate

    func tableView(_ tableView: NGTableView, markerColorForRow row: Int) -> NSColor? {
        data.hasProblems(at: row) ? Self.problemMarker : nil
    }
}
