import AppKit

// Frames a second the window gets (a display link's callbacks) and the share
// of the last second the main run loop didn't wait: with hundreds of entries
// a second the table looks busy, and these say whether it is.

final class FrameMeter: NSObject {
    private var frames: [CFTimeInterval] = []
    private var waits: [(start: CFTimeInterval, end: CFTimeInterval)] = []
    private var waitStart: CFTimeInterval?
    private var observer: CFRunLoopObserver?
    private var link: CADisplayLink?

    func start(on view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
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
