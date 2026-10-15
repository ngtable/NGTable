import SwiftUI
import UIKit

// The bench: pick an engine, how many rows and how many values change a
// second; the pill shows frames a second and the main thread's load live.
// Scroll Test scrolls the table down and up for eight seconds, as fast as a
// flick, while the values keep changing, and shows the frames it got: the
// average, the worst second, the hitches (frames late by more than half a
// frame) and the longest frame. Measure on a device, in a Release build:
// the simulator draws with the Mac's GPU.
//
// Launch arguments pick the options and run the test by themselves, its
// result printed: `-engine 0…4 -rows 0…2 -rate 0…3 -autoTest YES`.
//
// With a hardware keyboard attached (the simulator has the Mac's, unless
// I/O > Keyboard > Connect Hardware Keyboard is off) iPadOS's focus system
// searches the views for a default focus while UITableView and
// UICollectionView scroll: compare with and without one.

@main
struct NGTableIPadBenchApp: App {
    var body: some Scene {
        WindowGroup {
            BenchScreen().ignoresSafeArea()
        }
    }
}

struct BenchScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: BenchViewController())
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

@MainActor
final class BenchViewController: UIViewController {
    private let data = BenchData()
    private var engine: BenchEngine?
    private let meter = FrameMeter()
    private let engines = UISegmentedControl(items: BenchEngineKind.allCases.map(\.title))
    private static let rowCounts = [10_000, 100_000, 1_000_000]
    private let rows = UISegmentedControl(items: ["10K rows", "100K rows", "1M rows"])
    private static let rates = [0, 100, 1_000, 10_000]
    private let rate = UISegmentedControl(items: ["Still", "100/s", "1K/s", "10K/s"])
    private let live = UILabel()
    private let result = UILabel()
    private var tickLink: CADisplayLink?
    private var pendingChanges = 0.0
    private var scrollTest: (start: CFTimeInterval, link: CADisplayLink)?
    private var liveTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Table Bench"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Scroll Test", style: .done, target: self, action: #selector(startScrollTest))
        let defaults = UserDefaults.standard
        engines.selectedSegmentIndex = min(defaults.integer(forKey: "engine"), engines.numberOfSegments - 1)
        rows.selectedSegmentIndex = defaults.object(forKey: "rows") == nil ? 1 : min(defaults.integer(forKey: "rows"), rows.numberOfSegments - 1)
        rate.selectedSegmentIndex = defaults.object(forKey: "rate") == nil ? 2 : min(defaults.integer(forKey: "rate"), rate.numberOfSegments - 1)
        engines.addTarget(self, action: #selector(engineChanged), for: .valueChanged)
        rows.addTarget(self, action: #selector(rowsChanged), for: .valueChanged)
        live.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        result.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        result.textColor = .secondaryLabel
        result.numberOfLines = 2
        result.text = "Scroll Test: scrolls for 8 s with the values changing, then shows the frames."
        // The engines on a line of their own (their names fit in portrait).
        let amounts = UIStackView(arrangedSubviews: [rows, rate])
        amounts.axis = .horizontal
        amounts.spacing = 12
        let options = UIStackView(arrangedSubviews: [engines, amounts])
        options.axis = .vertical
        options.alignment = .leading
        options.spacing = 8
        let status = UIStackView(arrangedSubviews: [live, result])
        status.axis = .horizontal
        status.spacing = 16
        live.setContentHuggingPriority(.required, for: .horizontal)
        for view in [options, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
        }
        NSLayoutConstraint.activate([
            options.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            options.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            options.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: options.leadingAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
        data.make(count: Self.rowCounts[rows.selectedSegmentIndex])
        showEngine()
        meter.start()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLive() }
        }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        tickLink = link
        if defaults.bool(forKey: "autoTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startScrollTest() }
        }
    }

    /// The engine's view under the options.
    private func showEngine() {
        if let old = engine?.controller {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        let kind = BenchEngineKind(rawValue: engines.selectedSegmentIndex) ?? .ngTable
        let engine = kind.make(data: data)
        self.engine = engine
        addChild(engine.controller)
        let child = engine.controller.view!
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: result.bottomAnchor, constant: 8),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        engine.controller.didMove(toParent: self)
    }

    @objc private func engineChanged() {
        stopScrollTest()
        showEngine()
    }

    @objc private func rowsChanged() {
        stopScrollTest()
        data.make(count: Self.rowCounts[rows.selectedSegmentIndex])
        engine?.reload()
    }

    /// Every frame: the values that changed since the last one.
    @objc private func tick(_ link: CADisplayLink) {
        let perSecond = Double(Self.rates[rate.selectedSegmentIndex])
        pendingChanges += perSecond * max(0, min(0.1, link.targetTimestamp - link.timestamp))
        let count = Int(pendingChanges)
        guard count > 0 else { return }
        pendingChanges -= Double(count)
        engine?.rowsChanged(data.tick(changing: count))
    }

    private func updateLive() {
        let (frames, busy) = meter.lastSecond()
        live.text = "\(frames) fps · main \(Int((busy * 100).rounded()))%"
    }

    // MARK: Scroll test

    private static let scrollTestDuration: CFTimeInterval = 8
    private static let scrollSpeed: CGFloat = 3_000

    @objc private func startScrollTest() {
        guard scrollTest == nil, let scroll = engine?.scrollView else { return }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: false)
        result.text = "Scrolling…"
        let link = CADisplayLink(target: self, selector: #selector(stepScrollTest(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        scrollTest = (CACurrentMediaTime(), link)
        meter.beginMeasuring()
    }

    /// Down at a flick's speed for half the time, then back up.
    @objc private func stepScrollTest(_ link: CADisplayLink) {
        guard let test = scrollTest, let scroll = engine?.scrollView else { return stopScrollTest() }
        let elapsed = CACurrentMediaTime() - test.start
        guard elapsed < Self.scrollTestDuration else { return finishScrollTest() }
        let half = Self.scrollTestDuration / 2
        let distance = Self.scrollSpeed * CGFloat(elapsed < half ? elapsed : Self.scrollTestDuration - elapsed)
        let top = -scroll.adjustedContentInset.top
        let bottom = max(top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        scroll.contentOffset = CGPoint(x: scroll.contentOffset.x, y: min(bottom, top + distance))
    }

    private func finishScrollTest() {
        let engineTitle = engine?.title ?? ""
        stopScrollTest()
        guard let measured = meter.endMeasuring() else { return }
        result.text = String(format: "%@, %@, %@: %.0f fps on average, %d in the worst second, %d hitches, longest frame %.0f ms, main %.0f%%",
                             engineTitle, rows.titleForSegment(at: rows.selectedSegmentIndex) ?? "",
                             rate.titleForSegment(at: rate.selectedSegmentIndex) ?? "", measured.averageFPS, measured.worstSecondFPS,
                             measured.hitches, measured.longestFrameMs, measured.busy * 100)
        print("BENCH \(result.text ?? "")")
    }

    private func stopScrollTest() {
        scrollTest?.link.invalidate()
        scrollTest = nil
    }
}
