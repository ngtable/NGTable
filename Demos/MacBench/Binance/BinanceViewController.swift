//
//  BinanceViewController.swift
//  NGTable Mac Bench
//
//  NGTable on Binance's public market data (spot), live: the tickers of every pair
//  with their best bid and ask as they change (a stream per pair, over a few connections of
//  1,024 streams), the trades of some pairs as they happen, or their order books (changes every
//  100 ms on a REST snapshot). Like the feed (FeedViewController), what came is applied once per
//  frame of the screen, in one batch, for `frameBudget` at most. The domain is a field
//  (`binance.com`, or `binance.us` where the first is closed): streams come from
//  `stream.<domain>:9443`, snapshots from `api.<domain>`. Times are in microseconds; the
//  latency is from Binance's event time, corrected by the offset of its clock (from
//  `/api/v3/time`), to the batch applied and to the frame on the screen.
//

import AppKit
import NGTable

final class BinanceViewController: NSViewController, NGTableViewDelegate {
    private static let frameBudget: Duration = .milliseconds(8)
    private static let defaultSymbols = "btcusdt ethusdt solusdt bnbusdt xrpusdt dogeusdt"

    private let store = BinanceStore()
    /// The table, of the engine chosen (NGTable unless compared with NSTableView or SwiftUI).
    private lazy var table: BenchTable = makeTable(.ngTable)
    private let enginePopUp = NSPopUpButton()
    private let mainThreadLoad = MainThreadLoad()
    private var stack: NSStackView?
    private let domainField = NSTextField(string: "binance.com")
    private let modePopUp = NSPopUpButton()
    private let symbolsField = NSTextField(string: BinanceViewController.defaultSymbols)
    private let connectButton = NSButton(title: "Подключить", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "Не подключено")

    private var connections: [BinanceConnection] = []
    private var streamCount = 0
    private var displayLink: CADisplayLink?
    private var didAutostart = false
    private var backlog: [(message: BinanceMessage, receivedAt: Double)] = []
    private var backlogStart = 0
    /// Binance's clock minus ours, µs (from `/api/v3/time`), and how far off it may be: half
    /// the round trip of the shortest of a few requests.
    private var clockOffset: Double = 0
    private var clockUncertainty: Double = .infinity
    private var books: [String: BinanceBookSync] = [:]
    private var fetchingBooks: Set<String> = []
    private var serverMessage = ""
    /// Bumped by every connect: answers of an earlier one are dropped.
    private var session = 0

    // Statistics of the current second.
    private var secondStart = ContinuousClock.now
    private var messages = 0, frames = 0, bytes = 0, screenFrames = 0
    private var decoding: Double = 0, applying: Double = 0, worstApply: Double = 0
    private var receivedAges: [Double] = [], appliedAges: [Double] = [], shownAges: [Double] = []
    private var batchEventTimes: [Int64] = []
    private var waitingToShow: [(appliedAt: CFTimeInterval, ages: [Double])] = []

    override func loadView() {
        for (control, action) in [(connectButton, #selector(connectToggled(_:))), (searchField, #selector(searchChanged(_:))),
                                  (modePopUp, #selector(modeChanged(_:)))] as [(NSControl, Selector)] {
            control.target = self
            control.action = action
        }
        modePopUp.addItems(withTitles: BinanceStore.Mode.allCases.map(\.title))
        enginePopUp.addItems(withTitles: BenchEngine.allCases.map(\.title))
        enginePopUp.target = self
        enginePopUp.action = #selector(engineChanged(_:))
        domainField.placeholderString = "binance.com"
        domainField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        symbolsField.placeholderString = "Пары через пробел"
        symbolsField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        symbolsField.isEnabled = false
        connectButton.bezelStyle = .rounded
        searchField.placeholderString = "Поиск"
        searchField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let domainLabel = NSTextField(labelWithString: "Домен:")
        let bar = NSStackView(views: [domainLabel, domainField, modePopUp, symbolsField, enginePopUp, connectButton, NSView(), searchField])
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
        // Launched with -BinanceAutostart tickers|trades|depth [-BinanceSymbols "btcusdt ethusdt"]
        // [-BinanceDomain binance.us]: connects once by itself, stats to stderr.
        guard !didAutostart, let name = UserDefaults.standard.string(forKey: "BinanceAutostart"),
              let mode = BinanceStore.Mode(rawValue: name) else { return }
        didAutostart = true
        modePopUp.selectItem(at: BinanceStore.Mode.allCases.firstIndex(of: mode) ?? 0)
        if let symbols = UserDefaults.standard.string(forKey: "BinanceSymbols") { symbolsField.stringValue = symbols }
        if let domain = UserDefaults.standard.string(forKey: "BinanceDomain") { domainField.stringValue = domain }
        // -BinanceEngine nsTable|swiftUI: the same streams in another table.
        if let name = UserDefaults.standard.string(forKey: "BinanceEngine"), let engine = BenchEngine(rawValue: name) {
            enginePopUp.selectItem(at: BenchEngine.allCases.firstIndex(of: engine) ?? 0)
            replaceTable(with: engine)
        }
        modeChanged(nil)
        connect()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        disconnect(reason: "Не подключено")
    }

    private var mode: BinanceStore.Mode { BinanceStore.Mode.allCases[max(0, modePopUp.indexOfSelectedItem)] }

    private var symbols: [String] {
        symbolsField.stringValue.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    }

    private var domain: String {
        let text = domainField.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "binance.com" : text
    }

    // MARK: Connecting

    @objc private func modeChanged(_ sender: Any?) {
        symbolsField.isEnabled = mode != .tickers
        if !connections.isEmpty { connect() }
    }

    @objc private func connectToggled(_ sender: Any?) {
        connections.isEmpty ? connect() : disconnect(reason: "Отключено")
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

    /// Another engine's table in the same place; connected, it connects again.
    private func replaceTable(with engine: BenchEngine) {
        guard engine != table.engine, let stack else { return }
        let wasConnected = !connections.isEmpty
        if wasConnected { disconnect(reason: "Смена таблицы") }
        let old = table.view
        table = makeTable(engine)
        stack.insertArrangedSubview(table.view, at: stack.arrangedSubviews.firstIndex(of: old) ?? stack.arrangedSubviews.count)
        old.removeFromSuperview()
        table.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        // Search: NGTable filters; the others show every row.
        searchField.isEnabled = engine == .ngTable
        if wasConnected { connect() }
    }

    private func streamURL(_ streams: [String]) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "stream.\(domain)"
        components.port = 9443
        components.path = "/stream"
        var query = [URLQueryItem(name: "timeUnit", value: "MICROSECOND")]
        if !streams.isEmpty { query.insert(URLQueryItem(name: "streams", value: streams.joined(separator: "/")), at: 0) }
        components.queryItems = query
        return components.url
    }

    private func restURL(_ path: String, _ query: [String: String] = [:]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.\(domain)"
        components.path = path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url
    }

    private func connect() {
        disconnect(reason: "")
        session += 1
        let session = session
        store.reset(mode: mode)
        table.show(columns: store.tableColumns(), sort: store.defaultSort)
        (books, fetchingBooks, serverMessage, streamCount) = ([:], [], "", 0)
        (clockOffset, clockUncertainty) = (0, .infinity)
        resetSecond()
        connectButton.title = "Отключить"
        statusLabel.stringValue = "Подключение к stream.\(domain)…"
        fetchClockOffset(session: session)
        switch mode {
        case .tickers:
            // Every pair's row from REST first, then the streams change them.
            fetch(restURL("/api/v3/ticker/24hr", ["type": "MINI"]), session: session) { [self] data in
                let tickers = try BinanceDecoder.miniTickers(data)
                table.beginUpdates()
                store.load(tickers, table: table)
                store.flushUpdates(table: table)
                table.endUpdates()
                open(["!ticker_1d@arr"])
                // Every pair's bid and ask as they are (streamed books tell changes).
                fetch(restURL("/api/v3/ticker/bookTicker"), session: session) { [self] data in
                    let books = try BinanceDecoder.bookTickers(data)
                    table.beginUpdates()
                    for book in books { store.apply(book, table: table) }
                    store.flushUpdates(table: table)
                    table.endUpdates()
                }
                let books = tickers.map { $0.symbol.lowercased() + "@bookTicker" }
                for start in stride(from: 0, to: books.count, by: BinanceConnection.streamLimit - 1) {
                    open([], subscribing: Array(books[start..<min(books.count, start + BinanceConnection.streamLimit - 1)]))
                }
            }
        case .trades:
            open(symbols.map { "\($0)@trade" })
        case .depth:
            for symbol in symbols { books[symbol.uppercased()] = BinanceBookSync() }
            open(symbols.map { "\($0)@depth@100ms" })
            for symbol in symbols { fetchBook(symbol.uppercased(), session: session) }
        }
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// A connection with these streams in its URL, and more subscribed to after.
    private func open(_ streams: [String], subscribing more: [String] = []) {
        guard let url = streamURL(streams) else { return }
        let connection = BinanceConnection(url: url)
        connections.append(connection)
        streamCount += streams.count + more.count
        connection.start()
        if !more.isEmpty { connection.subscribe(more) }
    }

    private func disconnect(reason: String) {
        for connection in connections { connection.close() }
        connections = []
        displayLink?.invalidate()
        displayLink = nil
        backlog = []
        backlogStart = 0
        connectButton.title = "Подключить"
        if !reason.isEmpty {
            statusLabel.stringValue = reason
            if didAutostart { FileHandle.standardError.write(Data("binance: \(reason)\n".utf8)) }
        }
    }

    /// A REST request; `body` runs on the main actor with the answer, unless another connect
    /// came since.
    private func fetch(_ url: URL?, session: Int, _ body: @escaping @MainActor (Data) throws -> Void) {
        guard let url else { return }
        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let self, self.session == session else { return }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    self.serverMessage = "\(url.path): HTTP \(http.statusCode) \(String(decoding: data.prefix(200), as: UTF8.self))"
                    return
                }
                try body(data)
            } catch {
                guard let self, self.session == session else { return }
                self.serverMessage = "\(url.path): \(error.localizedDescription)"
            }
        }
    }

    /// Binance's clock against ours, from the middle of a request's round trip: the shortest
    /// round trip of `samples` requests, one after another, wins.
    private func fetchClockOffset(session: Int, samples: Int = 5) {
        guard samples > 0 else { return }
        let sent = Date().timeIntervalSince1970 * 1_000_000
        fetch(restURL("/api/v3/time"), session: session) { [self] data in
            let received = Date().timeIntervalSince1970 * 1_000_000
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let server = object["serverTime"] as? Double else { return }
            let uncertainty = (received - sent) / 2
            if uncertainty < clockUncertainty {
                clockOffset = server * 1000 - (sent + received) / 2
                clockUncertainty = uncertainty
            }
            fetchClockOffset(session: session, samples: samples - 1)
        }
    }

    /// A pair's order book snapshot: loaded, then the buffered changes after it.
    private func fetchBook(_ symbol: String, session: Int) {
        guard !fetchingBooks.contains(symbol) else { return }
        fetchingBooks.insert(symbol)
        fetch(restURL("/api/v3/depth", ["symbol": symbol, "limit": "5000"]), session: session) { [self] data in
            fetchingBooks.remove(symbol)
            let snapshot = try BinanceDecoder.snapshot(data)
            guard var sync = books[symbol] else { return }
            let outcome = sync.snapshot(lastUpdateID: snapshot.lastUpdateID)
            books[symbol] = sync
            switch outcome {
            case .fetchAgain:
                fetchBook(symbol, session: session)
            case .broken:
                fetchBook(symbol, session: session)
            case .apply(let changes):
                let now = Int64(Date().timeIntervalSince1970 * 1_000_000 + clockOffset)
                table.beginUpdates()
                store.removeLevels(of: symbol, table: table)
                store.apply(levels: snapshot.bids, isBid: true, symbol: symbol, time: now, table: table)
                store.apply(levels: snapshot.asks, isBid: false, symbol: symbol, time: now, table: table)
                for change in changes { apply(change) }
                store.flushUpdates(table: table)
                table.endUpdates()
            }
        }
    }

    private func apply(_ change: BinanceDepth) {
        store.apply(levels: change.bids, isBid: true, symbol: change.symbol, time: change.eventTime, table: table)
        store.apply(levels: change.asks, isBid: false, symbol: change.symbol, time: change.eventTime, table: table)
    }

    // MARK: A frame of the screen

    @objc private func frame(_ link: CADisplayLink) {
        guard !connections.isEmpty else { return }
        screenFrames += 1
        if backlogStart == backlog.count {
            backlog.removeAll(keepingCapacity: true)
            backlogStart = 0
            for connection in connections {
                let received = connection.take()
                frames += received.frames
                bytes += received.bytes
                decoding += received.decoding
                for (message, receivedAt) in zip(received.messages, received.receivedAt) {
                    backlog.append((message, receivedAt))
                    // (The event's time on our clock: Binance's minus the offset.)
                    if let eventTime = message.eventTime { receivedAges.append((receivedAt + clockOffset - Double(eventTime)) / 1000) }
                }
                // `.closed` comes without a frame.
                for message in received.messages.dropFirst(received.receivedAt.count) { backlog.append((message, 0)) }
            }
        }
        if backlogStart < backlog.count {
            let start = ContinuousClock.now
            apply(until: start + Self.frameBudget)
            let seconds = Self.seconds(start.duration(to: .now))
            applying += seconds
            worstApply = max(worstApply, seconds)
        }
        if secondStart.duration(to: .now) >= .seconds(1) { showSecond() }
    }

    private func apply(until deadline: ContinuousClock.Instant) {
        table.beginUpdates()
        var first = true
        while backlogStart < backlog.count, first || ContinuousClock.now < deadline {
            first = false
            let (message, receivedAt) = backlog[backlogStart]
            backlogStart += 1
            messages += 1
            if let eventTime = message.eventTime { batchEventTimes.append(eventTime) }
            switch message {
            case .tickers(let tickers):
                for ticker in tickers { store.apply(ticker, table: table) }
            case .book(let book):
                store.apply(book, table: table)
            case .trade(let trade):
                store.apply(trade, receivedAt: receivedAt + clockOffset, table: table)
            case .depth(let change):
                guard var sync = books[change.symbol] else { continue }
                let outcome = sync.receive(change)
                books[change.symbol] = sync
                switch outcome {
                case .apply(let changes): for change in changes { apply(change) }
                case .broken, .fetchAgain: fetchBook(change.symbol, session: session)
                }
            case .reply:
                break
            case .error(let text):
                serverMessage = "Binance: \(text)"
            case .closed(let reason):
                serverMessage = "Соединение закрыто: \(reason)"
            }
        }
        store.flushUpdates(table: table)
        table.endUpdates()
        let applied = Date().timeIntervalSince1970 * 1_000_000 + clockOffset
        let ages = batchEventTimes.map { (applied - Double($0)) / 1000 }
        appliedAges += ages
        if waitingToShow.count < 64 { waitingToShow.append((CACurrentMediaTime(), ages)) }
        batchEventTimes.removeAll(keepingCapacity: true)
    }

    private func framePresented(drawnAt: CFTimeInterval, presentedAt: CFTimeInterval) {
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
        let perSecond = { (value: Double) in (value / elapsed).formatted(.number.precision(.fractionLength(0))) }
        var parts = [
            table.engine.title,
            "Строк: \(store.count.formatted())",
            "главный поток занят \((mainThreadLoad.takeBusyShare() * 100).formatted(.number.precision(.fractionLength(0))))%",
            "соединений \(connections.count), потоков \(streamCount.formatted())",
            "сообщений/с \(perSecond(Double(messages)))",
            "экран \(perSecond(Double(screenFrames))) Гц",
            "КБ/с \((Double(bytes) / elapsed / 1024).formatted(.number.precision(.fractionLength(0))))",
            "разбор \((decoding / elapsed * 100).formatted(.number.precision(.fractionLength(0))))% ядра",
            "таблица \((applying / elapsed * 1000).formatted(.number.precision(.fractionLength(0)))) мс/с, кадр до \((worstApply * 1000).formatted(.number.precision(.fractionLength(1)))) мс",
            "задержка p50: сеть \(Self.median(&receivedAges)) · применено \(Self.median(&appliedAges)) · экран \(Self.median(&shownAges)) мс",
            clockUncertainty.isFinite
                ? "часы биржи \((clockOffset / 1000).formatted(.number.precision(.fractionLength(0)))) ± \((clockUncertainty / 1000).formatted(.number.precision(.fractionLength(0)))) мс"
                : "часы биржи —",
        ]
        if mode == .depth {
            parts.append("книг в синхроне \(books.values.filter(\.isSynced).count) из \(books.count)")
        }
        if backlogStart < backlog.count { parts.append("не успеваем: в очереди \((backlog.count - backlogStart).formatted())") }
        if !serverMessage.isEmpty { parts.append(serverMessage) }
        statusLabel.stringValue = parts.joined(separator: " · ")
        if didAutostart { FileHandle.standardError.write(Data("binance: \(statusLabel.stringValue)\n".utf8)) }
        resetSecond()
    }

    private func resetSecond() {
        (secondStart, messages, frames, bytes, screenFrames) = (.now, 0, 0, 0, 0)
        (decoding, applying, worstApply) = (0, 0, 0)
        receivedAges.removeAll(keepingCapacity: true)
        appliedAges.removeAll(keepingCapacity: true)
        shownAges.removeAll(keepingCapacity: true)
    }

    private static func median(_ values: inout [Double]) -> String {
        guard !values.isEmpty else { return "—" }
        values.sort()
        return values[values.count / 2].formatted(.number.precision(.fractionLength(1)))
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
