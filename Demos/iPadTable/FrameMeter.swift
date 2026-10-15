import UIKit

// Frames a second the screen gets (a display link's callbacks) and the share
// of the last second the main run loop didn't wait: with values changing many
// times a second the table looks busy, and these say whether it is. A
// ProMotion iPad reaches 120 frames a second while something moves; standing
// still, the system may lower the rate.

@MainActor
final class FrameMeter: NSObject {
    private var frames: [CFTimeInterval] = []
    private var waits: [(start: CFTimeInterval, end: CFTimeInterval)] = []
    private var waitStart: CFTimeInterval?
    private var observer: CFRunLoopObserver?
    private var link: CADisplayLink?

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue,
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
        self.observer = observer
    }

    func stop() {
        link?.invalidate()
        link = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
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

/// The meter's numbers in a small pill, updated twice a second.
final class FrameMeterLabel: UILabel {
    private let meter = FrameMeter()
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        textColor = .white
        backgroundColor = UIColor.black.withAlphaComponent(0.65)
        textAlignment = .center
        layer.cornerRadius = 8
        layer.masksToBounds = true
        isUserInteractionEnabled = false
        text = "— fps"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 20, height: size.height + 8)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, timer == nil {
            meter.start()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        } else if window == nil {
            timer?.invalidate()
            timer = nil
            meter.stop()
        }
    }

    private func update() {
        let (frames, busy) = meter.lastSecond()
        text = "\(frames) fps · main \(Int((busy * 100).rounded()))%"
    }
}
