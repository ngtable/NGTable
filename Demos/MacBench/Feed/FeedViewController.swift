//
//  FeedViewController.swift
//  NGTable Mac Bench
//
//  NGTable on a live feed over the network. Connects to an ngfeed server (../ngfeed,
//  in Docker: `docker compose up -d`), shows its rows and applies what comes once per frame of the
//  screen, in one batch: deletes, inserts and updates in the order they came. A frame applies
//  for `frameBudget` at most and takes nothing new while some is left; changes the client
//  can't catch up with are dropped for a new snapshot (FeedBacklog). The status line
//  tells messages and rows a second, megabytes, the time to decode (off the main thread) and to
//  apply (on it), the latency from the server's generator to the applied batch, gaps in `seq`
//  and conflated messages (the server merges changes for a client that falls behind).
//

import AppKit
import NGTable

final class FeedViewController: NSViewController, NGTableViewDelegate {
    private static let scenarios = ["dashboard", "trading", "hft", "firehose", "churn", "orders", "burst", "wide"]
    private static let rowChoices: [Int?] = [nil, 10_000, 100_000, 1_000_000]
    /// How long a frame applies messages at most: a 120 Hz frame. (It was a 60 Hz one while
    /// NGTable's inserts and removes cost more: 8 ms then left no time to draw, and `orders`
    /// fell behind.)
    private static let frameBudget: Duration = .milliseconds(8)

    private let store = FeedStore()
    /// The table, of the engine chosen (NGTable unless compared with NSTableView or SwiftUI).
    private lazy var table: BenchTable = makeTable(.ngTable)
    private let enginePopUp = NSPopUpButton()
    private let mainThreadLoad = MainThreadLoad()
    private var stack: NSStackView?
    private let addressField = NSTextField(string: "ws://127.0.0.1:9001/feed")
    private let scenarioPopUp = NSPopUpButton()
    private let rowsPopUp = NSPopUpButton()
    private let connectButton = NSButton(title: "Подключить", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Пауза", target: nil, action: nil)
    private let resnapshotButton = NSButton(title: "Новый снимок", target: nil, action: nil)
    private let resnapshotOnGapBox = NSButton(checkboxWithTitle: "Снимок при пропуске", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "Не подключено")

    private var connection: FeedConnection?
    private var displayLink: CADisplayLink?
    private var isPaused = false
    private var didAutostart = false
    private var backlog = FeedBacklog()

    // State of the stream.
    private var lastSeq: Int?
    private var waitsForSnapshot = true
    private var gaps = 0
    private var conflatedMessages = 0
    private var staleDrops = 0
    /// What the last snapshot cost on the main thread: the store, the table's reload (seconds), rows.
    private var snapshotCost: (store: Double, table: Double, rows: Int)?
    private var serverMessage = ""

    // Statistics of the current second.
    private var secondStart = ContinuousClock.now
    private var frames = 0
    /// Frames of the screen (display link callbacks): a message waits for the next one.
    private var screenFrames = 0
    private var bytes = 0
    private var decoding: Double = 0
    private var applying: Double = 0
    private var worstApply: Double = 0
    private var changedRows = 0
    private var latencies: [Double] = []
    /// The latency by stage (ms from `gen_ts`): off the network, decoded, its batch applied, and
    /// on the screen (when the first frame drawn after the batch showed: `framePresented`).
    private var receivedAges: [Double] = [], decodedAges: [Double] = [], appliedAges: [Double] = [], shownAges: [Double] = []
    /// `gen_ts` of the changes in the batch being applied.
    private var batchGenTs: [Int64] = []
    /// Ages of applied changes waiting for a frame to show them, with when they were applied
    /// (`CACurrentMediaTime`).
    private var waitingToShow: [(appliedAt: CFTimeInterval, ages: [Double])] = []
    /// From drawing a frame to its showing, ms.
    private var drawnToShown: [Double] = []

    override func loadView() {
        for (control, action) in [(connectButton, #selector(connectToggled(_:))), (pauseButton, #selector(pauseToggled(_:))),
                                  (resnapshotButton, #selector(resnapshot(_:))), (searchField, #selector(searchChanged(_:)))]
            as [(NSControl, Selector)] {
            control.target = self
            control.action = action
        }
        enginePopUp.addItems(withTitles: BenchEngine.allCases.map(\.title))
        enginePopUp.target = self
        enginePopUp.action = #selector(engineChanged(_:))
        scenarioPopUp.addItems(withTitles: Self.scenarios)
        scenarioPopUp.selectItem(withTitle: "trading")
        rowsPopUp.addItems(withTitles: Self.rowChoices.map { $0.map { "\($0.formatted()) строк" } ?? "Строк по сценарию" })
        addressField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        for button in [connectButton, pauseButton, resnapshotButton] { button.bezelStyle = .rounded }
        pauseButton.isEnabled = false
        resnapshotButton.isEnabled = false
        resnapshotOnGapBox.state = .on
        searchField.placeholderString = "Поиск"
        searchField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [addressField, scenarioPopUp, rowsPopUp, enginePopUp, connectButton, pauseButton, resnapshotButton,
                                      resnapshotOnGapBox, NSView(), searchField])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 4, right: 16)
        let status = NSStackView(views: [statusLabel])
        status.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 6, right: 16)

        let stack = NSStackView(views: [bar, status, table.view])
        stack.orientation = .vertical
        stack.spacing = 0
        for view in [bar, status, table.view] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        self.stack = stack
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Launched with -FeedAutostart <scenario> [-FeedRows <count>]: connects once by itself;
        // -FeedSort <column> sorts by it, descending; -FeedSelectAll YES selects every row of
        // each snapshot (how the table copes with a sorted feed and a huge selection).
        guard !didAutostart, let scenario = UserDefaults.standard.string(forKey: "FeedAutostart") else { return }
        didAutostart = true
        // -FeedEngine nsTable|swiftUI: the same feed in another table.
        if let name = UserDefaults.standard.string(forKey: "FeedEngine"), let engine = BenchEngine(rawValue: name) {
            enginePopUp.selectItem(at: BenchEngine.allCases.firstIndex(of: engine) ?? 0)
            replaceTable(with: engine)
        }
        scenarioPopUp.selectItem(withTitle: scenario)
        let rows = UserDefaults.standard.integer(forKey: "FeedRows")
        if let index = Self.rowChoices.firstIndex(of: rows) { rowsPopUp.selectItem(at: index) }
        connect()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        disconnect(reason: "Не подключено")
    }

    // MARK: Connecting

    @objc private func connectToggled(_ sender: Any?) {
        connection == nil ? connect() : disconnect(reason: "Отключено")
    }

    private func connect() {
        guard var components = URLComponents(string: addressField.stringValue) else { return }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "scenario", value: scenarioPopUp.titleOfSelectedItem))
        if let rows = Self.rowChoices[max(0, rowsPopUp.indexOfSelectedItem)] { query.append(URLQueryItem(name: "rows", value: String(rows))) }
        components.queryItems = query
        guard let url = components.url else { return }
        let connection = FeedConnection(url: url)
        self.connection = connection
        (lastSeq, waitsForSnapshot, gaps, conflatedMessages, serverMessage, isPaused) = (nil, true, 0, 0, "", false)
        (staleDrops, snapshotCost) = (0, nil)
        backlog.removeAll()
        resetSecond()
        connection.start()
        connectButton.title = "Отключить"
        for button in [pauseButton, resnapshotButton] { button.isEnabled = true }
        pauseButton.title = "Пауза"
        statusLabel.stringValue = "Подключение к \(url.absoluteString)…"
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func disconnect(reason: String) {
        connection?.close()
        connection = nil
        displayLink?.invalidate()
        displayLink = nil
        connectButton.title = "Подключить"
        for button in [pauseButton, resnapshotButton] { button.isEnabled = false }
        statusLabel.stringValue = reason
        if didAutostart { FileHandle.standardError.write(Data("feed: \(reason)\n".utf8)) }
    }

    @objc private func pauseToggled(_ sender: Any?) {
        isPaused.toggle()
        connection?.send(["type": isPaused ? "pause" : "resume"])
        pauseButton.title = isPaused ? "Продолжить" : "Пауза"
    }

    @objc private func resnapshot(_ sender: Any?) {
        waitsForSnapshot = true
        connection?.send(["type": "resnapshot"])
    }

    @objc private func searchChanged(_ sender: Any?) {
        table.search(searchField.stringValue)
    }

    // MARK: The engine

    private func makeTable(_ engine: BenchEngine) -> BenchTable {
        let table = engine.makeTable(source: store)
        if let ngTable = (table as? NGBenchTable)?.table { ngTable.delegate = self }
        table.framePresented = { [weak self] drawnAt, presentedAt in self?.framePresented(drawnAt: drawnAt, presentedAt: presentedAt) }
        return table
    }

    @objc private func engineChanged(_ sender: Any?) {
        replaceTable(with: BenchEngine.allCases[max(0, enginePopUp.indexOfSelectedItem)])
    }

    /// Another engine's table in the same place; connected, the feed starts again with a snapshot.
    private func replaceTable(with engine: BenchEngine) {
        guard engine != table.engine, let stack else { return }
        let wasConnected = connection != nil
        if wasConnected { disconnect(reason: "Смена таблицы") }
        let old = table.view
        table = makeTable(engine)
        stack.insertArrangedSubview(table.view, at: stack.arrangedSubviews.firstIndex(of: old) ?? stack.arrangedSubviews.count)
        old.removeFromSuperview()
        table.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        // Search: NGTable filters; the others show every row.
        searchField.isEnabled = engine == .ngTable
        if !store.schema.isEmpty { table.show(columns: store.tableColumns(), sort: []) }
        if wasConnected { connect() }
    }

    // MARK: A frame of the screen

    /// Applies what came, in one batch, for `frameBudget` at most; takes more only when all
    /// that was taken is applied.
    @objc private func frame(_ link: CADisplayLink) {
        guard let connection else { return }
        screenFrames += 1
        if backlog.isEmpty {
            let received = connection.take()
            bytes += received.bytes
            frames += received.frames
            decoding += received.decoding
            receivedAges += received.receivedAges
            decodedAges += received.decodedAges
            backlog.take(received.messages)
        }
        if !waitsForSnapshot, backlog.dropChangesIfBehind(nowMicros: Date().timeIntervalSince1970 * 1_000_000) {
            staleDrops += 1
            waitsForSnapshot = true
            connection.send(["type": "resnapshot"])
        }
        if !backlog.isEmpty {
            let start = ContinuousClock.now
            apply(until: start + Self.frameBudget)
            let seconds = Self.seconds(start.duration(to: .now))
            applying += seconds
            worstApply = max(worstApply, seconds)
        }
        if secondStart.duration(to: .now) >= .seconds(1) { showSecond() }
    }

    /// Applies messages of the backlog in order until `deadline` (one at least).
    private func apply(until deadline: ContinuousClock.Instant) {
        let now = Double(Date().timeIntervalSince1970 * 1_000_000)
        var batch = false
        func beginBatch() {
            guard !batch else { return }
            table.beginUpdates()
            batch = true
        }
        func endBatch() {
            guard batch else { return }
            store.flushUpdates(table: table)
            table.endUpdates()
            batch = false
            let applied = Date().timeIntervalSince1970 * 1_000_000
            let ages = batchGenTs.map { (applied - Double($0)) / 1000 }
            appliedAges += ages
            if waitingToShow.count < 64 { waitingToShow.append((CACurrentMediaTime(), ages)) }
            batchGenTs.removeAll(keepingCapacity: true)
        }
        var first = true
        while first || ContinuousClock.now < deadline, let message = backlog.next() {
            first = false
            switch message {
            case .hello(let schema, _):
                endBatch()
                if schema != store.schema || table.benchColumnIDs.isEmpty {
                    store.reset(schema: schema)
                    let sort = didAutostart ? UserDefaults.standard.string(forKey: "FeedSort").map { [NSSortDescriptor(key: $0, ascending: false)] } : nil
                    table.show(columns: store.tableColumns(), sort: sort ?? [])
                }
            case .snapshot(let snapshot):
                endBatch()
                let start = ContinuousClock.now
                store.load(snapshot)
                let loaded = ContinuousClock.now
                table.reloadAll()
                snapshotCost = (Self.seconds(start.duration(to: loaded)), Self.seconds(loaded.duration(to: .now)), snapshot.ids.count)
                if didAutostart, UserDefaults.standard.bool(forKey: "FeedSelectAll") { table.selectAll() }
                lastSeq = snapshot.seq
                waitsForSnapshot = false
            case .update(let seq, let genTs, let rows, let conflated):
                guard accept(seq, conflated: conflated) else { continue }
                beginBatch()
                store.update(rows)
                changedRows += rows.count
                latencies.append((now - Double(genTs)) / 1000)
                batchGenTs.append(genTs)
            case .insert(let seq, let genTs, let rows, let conflated):
                guard accept(seq, conflated: conflated) else { continue }
                beginBatch()
                store.insert(rows, table: table)
                changedRows += rows.count
                latencies.append((now - Double(genTs)) / 1000)
                batchGenTs.append(genTs)
            case .delete(let seq, let genTs, let keys, let conflated):
                guard accept(seq, conflated: conflated) else { continue }
                beginBatch()
                store.delete(keys, table: table)
                changedRows += keys.count
                latencies.append((now - Double(genTs)) / 1000)
                batchGenTs.append(genTs)
            case .checksum, .heartbeat, .pong:
                break
            case .end(let reason):
                serverMessage = "Конец потока: \(reason)"
            case .error(let code, let message):
                serverMessage = "Ошибка сервера \(code): \(message)"
            case .closed(let reason):
                endBatch()
                backlog.removeAll()
                disconnect(reason: serverMessage.isEmpty ? "Соединение закрыто: \(reason)" : serverMessage)
                return
            }
        }
        endBatch()
    }

    /// Whether a change follows the state: its `seq` is the next one (a conflated message may
    /// skip ahead). A gap waits for a new snapshot when asked to.
    private func accept(_ seq: Int, conflated: Int?) -> Bool {
        guard !waitsForSnapshot, let last = lastSeq else { return false }
        if let conflated {
            conflatedMessages += 1
            _ = conflated
            guard seq > last else { return false }
        } else if seq != last + 1 {
            gaps += 1
            if resnapshotOnGapBox.state == .on {
                waitsForSnapshot = true
                connection?.send(["type": "resnapshot"])
                return false
            }
        }
        lastSeq = seq
        return true
    }

    /// A frame showed: the batches applied before it was drawn are on the screen.
    private func framePresented(drawnAt: CFTimeInterval, presentedAt: CFTimeInterval) {
        drawnToShown.append((presentedAt - drawnAt) * 1000)
        let shown = waitingToShow.prefix { $0.appliedAt <= drawnAt }
        for batch in shown {
            let wait = (presentedAt - batch.appliedAt) * 1000
            shownAges += batch.ages.map { $0 + wait }
        }
        waitingToShow.removeFirst(shown.count)
    }

    // MARK: Statistics

    private func showSecond() {
        let elapsed = Self.seconds(secondStart.duration(to: .now))
        latencies.sort()
        func percentile(_ fraction: Double) -> String {
            guard !latencies.isEmpty else { return "—" }
            let value = latencies[min(latencies.count - 1, Int(Double(latencies.count) * fraction))]
            return value.formatted(.number.precision(.fractionLength(1)))
        }
        let perSecond = { (value: Double) in (value / elapsed).formatted(.number.precision(.fractionLength(0))) }
        var parts = [
            table.engine.title,
            "Строк: \(store.count.formatted())",
            "главный поток занят \((mainThreadLoad.takeBusyShare() * 100).formatted(.number.precision(.fractionLength(0))))%",
            "кадров/с \(perSecond(Double(frames)))",
            "экран \(perSecond(Double(screenFrames))) Гц",
            "изменений/с \(perSecond(Double(changedRows)))",
            "МБ/с \((Double(bytes) / elapsed / 1_048_576).formatted(.number.precision(.fractionLength(1))))",
            "разбор \((decoding / elapsed * 100).formatted(.number.precision(.fractionLength(0))))% ядра",
            "таблица \((applying / elapsed * 1000).formatted(.number.precision(.fractionLength(0)))) мс/с, кадр до \((worstApply * 1000).formatted(.number.precision(.fractionLength(1)))) мс",
            "задержка p50 \(percentile(0.5)) / p99 \(percentile(0.99)) мс",
            "этапы p50: сеть \(Self.median(&receivedAges)) · разбор \(Self.median(&decodedAges)) · кадр \(percentile(0.5)) · применено \(Self.median(&appliedAges)) · экран \(Self.median(&shownAges)) мс (кадр рисуется → виден \(Self.median(&drawnToShown)), показано \(perSecond(Double(drawnToShown.count)))/с)",
            "seq \(lastSeq.map { String($0) } ?? "—")",
        ]
        if gaps > 0 { parts.append("пропусков \(gaps)") }
        if conflatedMessages > 0 { parts.append("слитых \(conflatedMessages)") }
        if staleDrops > 0 { parts.append("сбросов отставания \(staleDrops)") }
        if let cost = snapshotCost {
            parts.append("снимок \(cost.rows.formatted()): хранилище \((cost.store * 1000).formatted(.number.precision(.fractionLength(0)))) мс, таблица \((cost.table * 1000).formatted(.number.precision(.fractionLength(0)))) мс")
        }
        if waitsForSnapshot { parts.append("ждём снимок") }
        if !backlog.isEmpty { parts.append("не успеваем: в очереди \(backlog.count.formatted())") }
        if !serverMessage.isEmpty { parts.append(serverMessage) }
        statusLabel.stringValue = parts.joined(separator: " · ")
        // For runs from the command line (stderr: not buffered).
        if didAutostart { FileHandle.standardError.write(Data("feed: \(statusLabel.stringValue)\n".utf8)) }
        resetSecond()
    }

    private func resetSecond() {
        (secondStart, frames, bytes, decoding, applying, worstApply, changedRows) = (.now, 0, 0, 0, 0, 0, 0)
        screenFrames = 0
        latencies.removeAll(keepingCapacity: true)
        receivedAges.removeAll(keepingCapacity: true)
        decodedAges.removeAll(keepingCapacity: true)
        appliedAges.removeAll(keepingCapacity: true)
        shownAges.removeAll(keepingCapacity: true)
        drawnToShown.removeAll(keepingCapacity: true)
    }

    /// The median of ages, one decimal ("—" without any).
    private static func median(_ values: inout [Double]) -> String {
        guard !values.isEmpty else { return "—" }
        values.sort()
        return values[values.count / 2].formatted(.number.precision(.fractionLength(1)))
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
