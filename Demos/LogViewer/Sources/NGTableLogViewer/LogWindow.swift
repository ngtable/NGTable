import AppKit
import NGTable

// The window: a toolbar (live or the last hour, pause, search), the table of
// entries and a status line (entries, shown, a second, and the frames a
// second the window gets and how busy the main thread is). Entries come in
// the order they were logged and aren't sorted; the table follows the newest
// while scrolled to the end.

final class LogWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    let table = NGTableView()
    private let strings = LogStrings()
    private lazy var entries = LogEntries(strings: strings)
    private var reader: LogReader?
    private let status = NSTextField(labelWithString: "")
    private let sourceControl = NSSegmentedControl(labels: ["Live", "Last Hour"], trackingMode: .selectOne, target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let searchField = NSSearchField()
    private var isPaused = false
    /// Entries a second, over the last second.
    private var arrivals: [(time: CFTimeInterval, count: Int)] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Log Viewer"
        window.setFrameAutosaveName("NGTableLogViewer")
        super.init(window: window)
        window.delegate = self
        setUpTable()
        setUpWindow(window)
        // `--last <minutes>`: a stretch of the past instead of the live logs.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--last"), index + 1 < arguments.count, let minutes = Int(arguments[index + 1]) {
            sourceControl.selectedSegment = 1
            pauseButton.isEnabled = false
            start(.last(minutes: minutes))
        } else {
            start(.live)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setUpTable() {
        table.columns = [
            .column(NGTableColumn("time", title: "Time", width: 120, format: .time(fractionDigits: 3), summary: .aggregate(.count))),
            .column(NGTableColumn("level", title: "Level", width: 80)),
            .column(NGTableColumn("process", title: "Process", width: 150)),
            .column(NGTableColumn("pid", title: "PID", width: 70, format: .number(fractionDigits: 0))),
            .column(NGTableColumn("subsystem", title: "Subsystem", width: 190)),
            .column(NGTableColumn("category", title: "Category", width: 110)),
            .column(NGTableColumn("message", title: "Message", width: 520, maxWidth: 4_000).wrappingText(maximumNumberOfLines: 4)),
        ]
        // In the order logged: no sorting by a column.
        table.columns = table.columns.map { item in
            guard case .column(var column) = item else { return item }
            column.isSortable = false
            return .column(column)
        }
        table.dataSource = entries
        table.allowsColumnFilters = true
        table.allowsUserGrouping = true
        table.allowsMultipleSelection = true
        table.navigatesByCell = true
        table.showsSummaryRow = true
        table.exportFileName = "Logs"
        table.autosaveName = "NGTableLogViewer"
    }

    private func setUpWindow(_ window: NSWindow) {
        let toolbar = NSToolbar(identifier: "LogViewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        sourceControl.selectedSegment = 0
        sourceControl.target = self
        sourceControl.action = #selector(sourceChanged(_:))
        pauseButton.target = self
        pauseButton.action = #selector(togglePause(_:))
        pauseButton.bezelStyle = .toolbar
        searchField.placeholderString = "Search Messages, Processes, Subsystems"
        searchField.delegate = self
        status.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        status.textColor = .secondaryLabelColor
        // The table under the toolbar, the status line under it.
        let content = NSView()
        for view in [table, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        window.contentView = content
        meter.start(on: table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: table.bottomAnchor, constant: 5),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        window.initialFirstResponder = table
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showStatus() }
        }
    }

    // MARK: Toolbar

    private static let sourceItem = NSToolbarItem.Identifier("source")
    private static let pauseItem = NSToolbarItem.Identifier("pause")
    private static let searchItem = NSToolbarItem.Identifier("search")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sourceItem, Self.pauseItem, .flexibleSpace, Self.searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField = searchField
            return item
        case Self.sourceItem, Self.pauseItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = identifier == Self.sourceItem ? sourceControl : pauseButton
            return item
        default:
            return nil
        }
    }

    // MARK: Entries

    private func start(_ source: LogReader.Source) {
        reader?.stop()
        reader = nil
        entries.removeAll()
        table.reloadData()
        arrivals = []
        let started = CACurrentMediaTime()
        reader = LogReader(source, strings: strings, deliver: { [weak self] batch in self?.add(batch) },
                           finished: { [weak self] in
                               guard let self else { return }
                               // What reading took, and the memory (now and at most).
                               var info = task_vm_info_data_t()
                               var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
                               _ = withUnsafeMutablePointer(to: &info) {
                                   $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
                               }
                               FileHandle.standardError.write(Data(String(format: "Read %d entries in %.1f s, footprint %d MB, peak %d MB\n", self.entries.count,
                                                                          CACurrentMediaTime() - started, Int(info.phys_footprint >> 20),
                                                                          Int(info.ledger_phys_footprint_peak >> 20)).utf8))
                               self.showStatus()
                           })
    }

    private func add(_ batch: LogBatch) {
        arrivals.append((CACurrentMediaTime(), batch.count))
        guard !isPaused else { return }
        // At the end before: it stays there, with the newest entries in view.
        let follows = isScrolledToEnd
        let before = entries.count
        let dropped = entries.append(batch)
        table.beginUpdates()
        if dropped > 0 { table.removeRows(at: IndexSet(integersIn: 0..<dropped)) }
        table.insertRows(at: IndexSet(integersIn: (before - dropped)..<entries.count))
        table.endUpdates()
        if follows, table.numberOfRows > 0 { table.scrollRowToVisible(entries.count - 1) }
    }

    /// The last entry (newest, sorted by time) is in view, or there are none.
    private var isScrolledToEnd: Bool {
        guard entries.count > 0 else { return true }
        let last = table.rect(ofRow: entries.count - 1)
        return last.isEmpty || last.minY < table.visibleRect.maxY
    }

    private let meter = FrameMeter()

    private func showStatus() {
        let now = CACurrentMediaTime()
        arrivals.removeAll { now - $0.time > 1 }
        let rate = arrivals.reduce(0) { $0 + $1.count }
        let shown = table.numberOfRows
        var text = "\(entries.count.formatted()) entries"
        if shown != entries.count { text += ", \(shown.formatted()) shown" }
        if sourceControl.selectedSegment == 0 { text += isPaused ? " — paused" : " — \(rate.formatted()) a second" }
        if table.isSearchingRows { text += " — searching…" }
        let (frames, busy) = meter.lastSecond()
        text += String(format: "    %d fps, main thread %.0f%% busy", frames, busy * 100)
        status.stringValue = text
    }

    @objc private func sourceChanged(_ sender: NSSegmentedControl) {
        isPaused = false
        pauseButton.title = "Pause"
        pauseButton.isEnabled = sender.selectedSegment == 0
        start(sender.selectedSegment == 0 ? .live : .last(minutes: 60))
    }

    @objc private func togglePause(_ sender: NSButton) {
        isPaused.toggle()
        sender.title = isPaused ? "Resume" : "Pause"
        showStatus()
    }

    func controlTextDidChange(_ notification: Notification) {
        table.rowFilter = searchField.stringValue.isEmpty ? nil
            : NGRowFilter(searchText: searchField.stringValue, columnIDs: ["message", "process", "subsystem", "category"])
    }

    func windowWillClose(_ notification: Notification) {
        reader?.stop()
        NSApp.terminate(nil)
    }
}
