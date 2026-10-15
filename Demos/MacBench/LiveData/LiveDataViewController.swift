//
//  LiveDataViewController.swift
//  NGTable Mac Bench
//
//  a test bench for NGTable's targeted row updates. Synthetic campaigns change by
//  themselves on a timer — values, new rows, removed and moved rows — in batches
//  (beginUpdates/endUpdates), with summaries, a search (the table's row filter), row tints by ROI
//  and the time the table takes per tick.
//

import AppKit
import NGTable

final class LiveDataViewController: NSViewController, NGTableViewDelegate {
    private let data = LiveDataSource()
    private let table = NGTableView(frame: .zero)
    private let runButton = NSButton(title: "Пауза", target: nil, action: nil)
    private let rateControl = NSSegmentedControl(labels: ["1 с", "250 мс", "50 мс"], trackingMode: .selectOne, target: nil, action: nil)
    private let sizeControl = NSSegmentedControl(labels: sizes.map { $0.formatted() }, trackingMode: .selectOne, target: nil, action: nil)
    private let valuesBox = NSButton(checkboxWithTitle: "Значения", target: nil, action: nil)
    private let insertsBox = NSButton(checkboxWithTitle: "Вставки", target: nil, action: nil)
    private let removesBox = NSButton(checkboxWithTitle: "Удаления", target: nil, action: nil)
    private let movesBox = NSButton(checkboxWithTitle: "Перемещения", target: nil, action: nil)
    /// Rows that come, go or move (also by the sort) slide and fade.
    private let animationsBox = NSButton(checkboxWithTitle: "Анимации", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")

    private static let rates: [Duration] = [.seconds(1), .milliseconds(250), .milliseconds(50)]
    private static let sizes = [100, 10_000, 100_000]
    private static let profitTint = NSColor.systemGreen.withAlphaComponent(0.10)
    private static let lossTint = NSColor.systemRed.withAlphaComponent(0.10)

    private var isRunning = true
    private var ticker: Task<Void, Never>?
    private var tick = 0

    override func loadView() {
        for (control, action) in [(runButton, #selector(runToggled(_:))), (rateControl, #selector(rateChanged(_:))),
                                  (sizeControl, #selector(sizeChanged(_:))), (searchField, #selector(searchChanged(_:))),
                                  (animationsBox, #selector(animationsToggled(_:)))] as [(NSControl, Selector)] {
            control.target = self
            control.action = action
        }
        runButton.bezelStyle = .rounded
        rateControl.selectedSegment = 1
        sizeControl.selectedSegment = 0
        for box in [valuesBox, insertsBox, removesBox, movesBox] {
            box.state = .on
        }
        searchField.placeholderString = "Поиск"
        searchField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        let bar = NSStackView(views: [runButton, rateControl, sizeControl, valuesBox, insertsBox, removesBox, movesBox, animationsBox,
                                      searchField, NSView(), statusLabel])
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

        table.columns = LiveDataSource.columns
        // The table sorts the rows itself and keeps them sorted under the feed.
        table.sortsRows = true
        // Filters in the column headers, like a spreadsheet's.
        table.allowsColumnFilters = true
        // Saved views (columns, sort, filters, grouping) in the header menu.
        table.allowsNamedViews = true
        // Grouping from the header menu (this screen has no grouping controls of its own).
        table.allowsUserGrouping = true
        // Arrows and Tab move a focused cell, like a spreadsheet.
        table.navigatesByCell = true
        // Rows drag out as text and reorder by dragging within the table.
        table.registerForDraggedTypes([LiveDataSource.rowType])
        // Dragging up or down from an unselected row selects rows (cells); sideways it drags.
        table.verticalMotionCanBeginDrag = false
        table.exportFileName = "Живые данные"
        table.autosaveName = "LiveData"
        table.emptyStateText = "Нет строк"
        table.dataSource = data
        table.delegate = self

        let stack = NSStackView(views: [bar, table])
        stack.orientation = .vertical
        stack.spacing = 0
        for view in [bar, table] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
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
        reset()
    }

    // Runs only while shown.
    override func viewDidAppear() {
        super.viewDidAppear()
        startTicking()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        ticker?.cancel()
        ticker = nil
    }

    // MARK: Controls

    @objc private func runToggled(_ sender: Any?) {
        isRunning.toggle()
        runButton.title = isRunning ? "Пауза" : "Пуск"
        isRunning ? startTicking() : ticker?.cancel()
    }

    @objc private func rateChanged(_ sender: Any?) {
        startTicking()
    }

    @objc private func sizeChanged(_ sender: Any?) {
        reset()
    }

    @objc private func searchChanged(_ sender: Any?) {
        table.rowFilter = searchField.stringValue.isEmpty ? nil : NGRowFilter(searchText: searchField.stringValue)
        table.emptyStateText = table.rowFilter == nil ? "Нет строк" : "Ничего не найдено"
    }

    /// New data of the chosen size: a full reload, the only one.
    private func reset() {
        data.reset(count: Self.sizes[max(0, sizeControl.selectedSegment)])
        table.reloadData()
        tick = 0
        statusLabel.stringValue = "Строк: \(data.records.count.formatted())"
    }

    private func startTicking() {
        ticker?.cancel()
        guard isRunning, view.window != nil else { return }
        let interval = Self.rates[max(0, rateControl.selectedSegment)]
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.step()
            }
        }
    }

    @objc private func animationsToggled(_ sender: NSButton) {
        table.animatesSortMoves = sender.state == .on
    }

    // MARK: Updates

    /// One tick: some values change, a few rows come, go or move, all in one batch. The data
    /// changes first, then the table is told, like for an NSTableView.
    private func step() {
        tick += 1
        let start = ContinuousClock.now
        let allColumns = IndexSet(integersIn: 0..<table.numberOfColumns)
        var changes = 0
        let animation: NSTableView.AnimationOptions = animationsBox.state == .on ? .effectFade : []
        table.beginUpdates()
        if valuesBox.state == .on, !data.records.isEmpty {
            for _ in 0..<min(500, max(1, data.records.count / 50)) {
                let row = Int.random(in: 0..<data.records.count)
                data.change(at: row)
                table.reloadData(forRowIndexes: [row], columnIndexes: allColumns)
                changes += 1
            }
        }
        if insertsBox.state == .on {
            for _ in 0..<Int.random(in: 0...2) {
                let row = Int.random(in: 0...data.records.count)
                data.insertRecord(at: row)
                table.insertRows(at: [row], withAnimation: animation)
                changes += 1
            }
        }
        if removesBox.state == .on, !data.records.isEmpty {
            for _ in 0..<min(data.records.count, Int.random(in: 0...2)) {
                let row = Int.random(in: 0..<data.records.count)
                data.removeRecord(at: row)
                table.removeRows(at: [row], withAnimation: animation)
                changes += 1
            }
        }
        if movesBox.state == .on, data.records.count > 1 {
            let from = Int.random(in: 0..<data.records.count), to = Int.random(in: 0..<data.records.count)
            data.moveRecord(at: from, to: to)
            table.moveRow(at: from, to: to)
            changes += 1
        }
        table.endUpdates()
        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        statusLabel.stringValue = "Тик \(tick) · строк \(data.records.count.formatted()) · изменений \(changes) · \(milliseconds.formatted(.number.precision(.fractionLength(1)))) мс"
    }

    // MARK: NGTableViewDelegate

    func tableView(_ tableView: NGTableView, backgroundColorForRow row: Int) -> NSColor? {
        let roi = data.records[row].roi
        return roi > 0.5 ? Self.profitTint : roi < 0 ? Self.lossTint : nil
    }

    func tableView(_ tableView: NGTableView, markerColorForRow row: Int) -> NSColor? {
        data.records[row].status == .error ? .systemOrange : nil
    }
}

/// Synthetic campaigns that change in place.
@MainActor
final class LiveDataSource: NGTableViewDataSource {
    enum Status: CaseIterable {
        case active, paused, error

        var tag: NGTag {
            switch self {
            case .active: NGTag("Активна", color: .green)
            case .paused: NGTag("Пауза", color: .gray)
            case .error: NGTag("Ошибка", color: .red)
            }
        }
    }

    struct Record {
        let id: Int
        var name: String
        var network: String
        var status: Status
        var autoBid: Bool
        var clicks: Int
        var conversions: Int
        var spend: Double
        var revenue: Double
        var updated: Date

        var roi: Double { spend > 0 ? (revenue - spend) / spend : 0 }
    }

    /// Nonisolated: the summary formulas read them off the main thread.
    private nonisolated enum ID {
        static let id = "id", name = "name", network = "network", status = "status", autoBid = "autoBid", clicks = "clicks"
        static let conversions = "conversions", spend = "spend", revenue = "revenue", roi = "roi", updated = "updated", one = "_one"
    }

    static let columns: [NGColumnItem] = {
        let usd = NGValueFormat.currency(code: "USD"), integer = NGValueFormat.number(fractionDigits: 0)
        let count = NGSummaryFormula("live.count", using: [ID.one]) { $0.sum(ID.one) ?? 0 }
        let roi = NGSummaryFormula("live.roi", using: [ID.spend, ID.revenue]) { values in
            guard let spend = values.sum(ID.spend), spend != 0, let revenue = values.sum(ID.revenue) else { return nil }
            return (revenue - spend) / spend
        }
        return [
            .column(NGTableColumn(ID.id, title: "ID", width: 80, summary: .formula(count), isHideable: false, pin: .leading)),
            .column(NGTableColumn(ID.name, title: "Кампания", width: 220, isHideable: false, pin: .leading, isEditable: true)),
            .column(NGTableColumn(ID.network, title: "Сеть", width: 110)),
            // Edited by choosing: the status from a menu, auto bidding with a check box.
            .column(NGTableColumn(ID.status, title: "Статус", width: 110, isEditable: true,
                                  editChoices: Status.allCases.map { .tags([$0.tag]) })),
            .column(NGTableColumn(ID.autoBid, title: "Автоставка", width: 100, alignment: .center, isEditable: true)),
            .group(NGColumnGroup("live.metrics", title: "Метрики", columns: [
                NGTableColumn(ID.clicks, title: "Клики", width: 90, alignment: .trailing, format: integer, summary: .aggregate(.sum), changeHighlight: .direction),
                NGTableColumn(ID.conversions, title: "Конв.", width: 80, alignment: .trailing, format: integer, summary: .aggregate(.sum), changeHighlight: .direction),
                NGTableColumn(ID.spend, title: "Расход", width: 110, alignment: .trailing, format: usd, summary: .aggregate(.sum), changeHighlight: .direction),
                NGTableColumn(ID.revenue, title: "Доход", width: 110, alignment: .trailing, format: usd, summary: .aggregate(.sum), changeHighlight: .direction,
                              conditionalFormat: .dataBar(.teal)),
                NGTableColumn(ID.roi, title: "ROI", width: 90, alignment: .trailing, format: .percent(fractionDigits: 1), summary: .formula(roi), changeHighlight: .direction,
                              conditionalFormat: .textColor([NGColorRule(.below(0), color: .red), NGColorRule(.above(0), color: .green)])),
            ])),
            .column(NGTableColumn(ID.updated, title: "Обновлена", width: 160, format: .date(includesTime: true))),
        ]
    }()

    private static let networks = ["MGID", "Taboola", "Outbrain", "Adskeeper", "Geozo"]
    private static let words = ["Keto", "Diet", "Joints", "Vision", "Hearing", "Slim", "Cardio", "Detox", "Sleep", "Skin"]
    private static let countries = ["DE", "IT", "ES", "FR", "PL", "RO", "CZ", "HU"]

    private(set) var records: [Record] = []
    private var nextID = 1

    func reset(count: Int) {
        nextID = 1
        records = (0..<count).map { _ in makeRecord() }
    }

    private func makeRecord() -> Record {
        defer { nextID += 1 }
        let spend = Double.random(in: 10...5_000).rounded()
        return Record(id: nextID,
                      name: "\(Self.countries.randomElement() ?? "DE") \(Self.words.randomElement() ?? "Keto") \(nextID)",
                      network: Self.networks.randomElement() ?? "MGID", status: Status.allCases.randomElement() ?? .active, autoBid: Bool.random(),
                      clicks: Int.random(in: 0...20_000), conversions: Int.random(in: 0...400),
                      spend: spend, revenue: (spend * Double.random(in: 0.3...2.5)).rounded(), updated: .now)
    }

    /// Traffic keeps coming: clicks, conversions, spend and revenue grow; now and then the status changes.
    func change(at row: Int) {
        var record = records[row]
        record.clicks += Int.random(in: 0...40)
        record.conversions += Int.random(in: 0...10) == 0 ? 1 : 0
        let spend = Double.random(in: 0...20).rounded()
        record.spend += spend
        record.revenue += (spend * Double.random(in: 0...3)).rounded()
        if Int.random(in: 0...30) == 0 {
            record.status = Status.allCases.randomElement() ?? record.status
        }
        record.updated = .now
        records[row] = record
    }

    func insertRecord(at row: Int) { records.insert(makeRecord(), at: row) }
    func removeRecord(at row: Int) { records.remove(at: row) }
    func moveRecord(at from: Int, to: Int) { records.insert(records.remove(at: from), at: to) }

    // MARK: Dragging

    /// A dragged row's record ID: the feed keeps changing the rows during a
    /// drag, so the drop finds the records again by ID, not by index.
    static let rowType = NSPasteboard.PasteboardType("by.digitalglobe.easycpa.livedata.row")

    /// Makes the text of dragged rows once it's asked for (see `tableView(_:pasteboardWriterForRow:)`).
    private var dragText: LiveDragText?

    /// A dragged row as text: the visible cells, tab-separated, like Copy.
    /// Dragging selected rows, the first one carries all of their lines (a
    /// text editor reads one string). The text is made only when a drop asks
    /// for it, of the records dragged (found by ID: the feed moves them).
    func tableView(_ tableView: NGTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        let selected = tableView.selectedRowIndexes
        if !selected.contains(row) || row == selected.first {
            let ids = selected.contains(row) ? selected.map { records[$0].id } : [records[row].id]
            let provider = LiveDragText { [weak self, weak tableView] in
                guard let self, let tableView else { return "" }
                let wanted = Set(ids)
                let rows = IndexSet(self.records.indices.filter { wanted.contains(self.records[$0].id) })
                return tableView.copyText(forRows: rows)
            }
            dragText = provider
            item.setDataProvider(provider, forTypes: [.string])
        }
        item.setString(String(records[row].id), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NGTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NGTableView) === tableView else { return [] }
        // Rows only reorder: a drop onto a row goes above it.
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    /// Moves the dragged records above the record at `row` (at the end past
    /// the last row), keeping their order. A sorted table shows its own
    /// order, so the sort is dropped first and the rows stay where they went.
    func tableView(_ tableView: NGTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let ids = Set((info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) })
        guard !ids.isEmpty else { return false }
        // The records still there, in data order, and the one to drop above.
        let moved = records.indices.filter { ids.contains(records[$0].id) }
        guard !moved.isEmpty else { return false }
        // Above the first record from `row` on that isn't dragged (else at the end).
        let target = records.indices.dropFirst(min(row, records.count)).first { !ids.contains(records[$0].id) }.map { records[$0].id }
        if !tableView.sortDescriptors.isEmpty { tableView.sortDescriptors = [] }
        tableView.beginUpdates()
        // Each record in turn goes just above the target: they end up in order.
        for id in moved.map({ records[$0].id }) {
            guard let from = records.firstIndex(where: { $0.id == id }) else { continue }
            var to = target.flatMap { target in records.firstIndex { $0.id == target } } ?? records.count
            if from < to { to -= 1 }
            guard from != to else { continue }
            moveRecord(at: from, to: to)
            tableView.moveRow(at: from, to: to)
        }
        tableView.endUpdates()
        return true
    }

    // MARK: NGTableViewDataSource

    func numberOfRows(in tableView: NGTableView) -> Int { records.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        Self.value(column.id, of: records[row])
    }

    /// Names edit as text (Return, a double click or typing on the focused cell), the status
    /// from a menu, auto bidding with a check box.
    func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
        guard row < records.count else { return }
        switch (column.id, value) {
        case (ID.name, .text(let name)): records[row].name = name
        case (ID.autoBid, .bool(let isOn)): records[row].autoBid = isOn
        case (ID.status, .tags(let tags)):
            if let status = Status.allCases.first(where: { [$0.tag] == tags }) { records[row].status = status }
        default: break
        }
    }

    func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? { records[row].id }

    /// The table sorts the rows itself (`sortsRows`) and keeps them sorted as the feed changes
    /// them; ids sort as numbers.
    func tableView(_ tableView: NGTableView, sortValueFor column: NGTableColumn, row: Int) -> NGCellValue {
        column.id == ID.id ? .number(Double(records[row].id)) : Self.value(column.id, of: records[row])
    }

    private static func value(_ columnID: String, of record: Record) -> NGCellValue {
        switch columnID {
        case ID.id: .text(String(record.id))
        case ID.name: .text(record.name)
        case ID.network: .text(record.network)
        case ID.status: .tags([record.status.tag])
        case ID.autoBid: .bool(record.autoBid)
        case ID.clicks: .number(Double(record.clicks))
        case ID.conversions: .number(Double(record.conversions))
        case ID.spend: .number(record.spend)
        case ID.revenue: .number(record.revenue)
        case ID.roi: .number(record.roi)
        case ID.updated: .date(record.updated)
        case ID.one: .number(1)
        default: .empty
        }
    }
}

/// Gives a dragged item's text when a drop reads it.
final class LiveDragText: NSObject, NSPasteboardItemDataProvider {
    private let text: () -> String

    init(_ text: @escaping () -> String) {
        self.text = text
    }

    // AppKit asks on the main thread.
    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let string = MainActor.assumeIsolated { text() }
        item.setString(string, forType: type)
    }
}
