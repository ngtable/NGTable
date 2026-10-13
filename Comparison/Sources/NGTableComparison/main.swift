import AppKit

// The window: a bar with the table shown, its frames a second and how busy
// the main thread is, over the table. The feed ticks 60 times a second on the
// main thread for every table alike.
//
//   swift run -c release --package-path Comparison NGTableComparison
//       [--seconds 7] [--quit] [--rows 20000] [--changes 45000] [--unsorted]
//
// Each table shows for --seconds, NGTable, NSTableView, SwiftUI Table, then
// again (with --quit the app ends after the third). The rows are sorted by
// amount (NGTable sorts them itself; for the others the app sorts, as they
// leave sorting to it); --unsorted shows them in their order. It prints its
// window's frame (screen points, top-left origin), for recording it.

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}

/// Frames the main thread gets to (a display link's callbacks a second), and
/// the share of time its run loop didn't wait.
final class Meter: NSObject {
    private var frames: [CFTimeInterval] = []
    private var observer: CFRunLoopObserver?
    private var waitStart: CFTimeInterval?
    private var waits: [(start: CFTimeInterval, end: CFTimeInterval)] = []
    private var link: CADisplayLink?

    func start(on view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue,
                                                      true, Int.max) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .beforeWaiting {
                    self.waitStart = now
                } else if let start = self.waitStart {
                    self.waits.append((start, now))
                    self.waitStart = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    @objc private func frame(_ link: CADisplayLink) { frames.append(CACurrentMediaTime()) }

    /// Over the last second: frames, and the main thread's busy share (0...1).
    func lastSecond() -> (frames: Int, busy: Double) {
        let now = CACurrentMediaTime(), from = now - 1
        frames.removeAll { $0 < from }
        waits.removeAll { $0.end < from }
        var waited = waits.reduce(0) { $0 + ($1.end - max($1.start, from)) }
        if let start = waitStart { waited += now - max(start, from) }
        return (frames.count, max(0, min(1, 1 - waited)))
    }
}

final class Bar: NSView {
    let engine = NSTextField(labelWithString: "")
    let order = NSTextField(labelWithString: "")
    let frames = NSTextField(labelWithString: "")
    let busy = NSTextField(labelWithString: "")
    let load = NSTextField(labelWithString: "")

    init(load text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        engine.font = .systemFont(ofSize: 28, weight: .bold)
        order.font = .systemFont(ofSize: 13)
        order.textColor = .secondaryLabelColor
        for label in [frames, busy] {
            label.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            label.alignment = .right
        }
        load.stringValue = text
        load.font = .systemFont(ofSize: 13)
        load.textColor = .secondaryLabelColor
        load.alignment = .right
        let left = NSStackView(views: [engine, order])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2
        let numbers = NSStackView(views: [frames, busy])
        numbers.spacing = 28
        let right = NSStackView(views: [numbers, load])
        right.orientation = .vertical
        right.alignment = .trailing
        right.spacing = 2
        for view in [left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ title: String, of titles: [String]) {
        engine.stringValue = title
        order.stringValue = titles.map { $0 == title ? "● \($0)" : "○ \($0)" }.joined(separator: "    ")
    }

    func update(frames count: Int, busy share: Double) {
        frames.stringValue = "\(count) frames/s"
        busy.stringValue = "main thread \(Int((share * 100).rounded()))% busy"
        let color: NSColor = count >= 100 ? .systemGreen : count >= 40 ? .systemOrange : .systemRed
        frames.textColor = color
        busy.textColor = share < 0.75 ? .systemGreen : share < 0.9 ? .systemOrange : .systemRed
    }
}

final class Controller: NSObject, NSApplicationDelegate {
    let feed = Feed(count: Int(argument("--rows") ?? "") ?? 20_000, changesPerSecond: Int(argument("--changes") ?? "") ?? 45_000,
                    isSorted: !arguments.contains("--unsorted"))
    let seconds = Double(argument("--seconds") ?? "") ?? 7
    let quits = arguments.contains("--quit")
    let makers: [(String, @MainActor (Feed) -> Engine)] = [("NGTable", { NGEngine(feed: $0) }), ("NSTableView", { NSEngine(feed: $0) }),
                                                          ("SwiftUI Table", { SwiftUIEngine(feed: $0) })]
    var window: NSWindow!
    var bar: Bar!
    let container = NSView()
    let meter = Meter()
    var engine: Engine?
    var shown = 0
    var reports = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "NGTable vs NSTableView vs SwiftUI Table"
        bar = Bar(load: "\(feed.count.formatted()) trades\(feed.isSorted ? " sorted by amount" : "") · \((feed.changesPerTick * 60).formatted()) changes a second")
        let content = NSView()
        for view in [bar!, container] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 72),
            container.topAnchor.constraint(equalTo: bar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.center()
        // Above other apps' windows: a covered window isn't drawn (NGTable
        // stops drawing then), and the numbers are of a table in view.
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        meter.start(on: content)
        show(0)

        let tick = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.feed.tick()
                self.engine?.feedChanged()
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        let numbers = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let (frames, busy) = self.meter.lastSecond()
                self.bar.update(frames: frames, busy: busy)
                self.reports += 1
                if self.reports % 4 == 0, let title = self.engine?.title {
                    print("STATS \(title): \(frames) frames/s, \(Int(busy * 100))% busy")
                    fflush(stdout)
                }
            }
        }
        RunLoop.main.add(numbers, forMode: .common)
        scheduleNext()

        let frame = window.frame
        let screen = window.screen?.frame ?? .zero
        print("WINDOW \(Int(frame.minX)),\(Int(screen.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
        fflush(stdout)
    }

    func show(_ index: Int) {
        engine?.view.removeFromSuperview()
        let (title, make) = makers[index % makers.count]
        bar.show(title, of: makers.map(\.0))
        let engine = make(feed)
        engine.view.frame = container.bounds
        engine.view.autoresizingMask = [.width, .height]
        container.addSubview(engine.view)
        self.engine = engine
    }

    func scheduleNext() {
        // A wall-clock timer: it fires late when the main thread is stuck, as everything does.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.shown += 1
            if self.quits && self.shown == self.makers.count { NSApp.terminate(nil); return }
            self.show(self.shown)
            self.scheduleNext()
        }
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
