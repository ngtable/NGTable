import UIKit

// Frames the screen gets (a display link's callbacks) and the share of the
// time the main run loop didn't wait: live, over the last second, and over a
// measured span (a scroll test), with its worst second, its hitches (frames
// late by more than half a frame) and its longest frame.

@MainActor
final class FrameMeter: NSObject {
    private var frames: [CFTimeInterval] = []
    private var waits: [(start: CFTimeInterval, end: CFTimeInterval)] = []
    private var waitStart: CFTimeInterval?
    private var observer: CFRunLoopObserver?
    private var link: CADisplayLink?
    /// The frames of a measured span, and its waits.
    private var measuring: (start: CFTimeInterval, frames: [CFTimeInterval], waited: CFTimeInterval)?
    /// The screen's frame time (1/60 or 1/120 s).
    private(set) var frameDuration: CFTimeInterval = 1.0 / 60

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
                    if let from = self.measuring?.start { self.measuring?.waited += now - max(start, from) }
                    self.waitStart = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        frames.append(now)
        measuring?.frames.append(now)
        frameDuration = max(1.0 / 120, link.targetTimestamp - link.timestamp)
    }

    /// Over the last second: frames, and the main thread's busy share (0...1).
    func lastSecond() -> (frames: Int, busy: Double) {
        let now = CACurrentMediaTime(), from = now - 1
        frames.removeAll { $0 < from }
        waits.removeAll { $0.end < from }
        var waited = waits.reduce(0) { $0 + ($1.end - max($1.start, from)) }
        if let start = waitStart { waited += now - max(start, from) }
        return (frames.count, max(0, min(1, 1 - waited)))
    }

    func beginMeasuring() {
        measuring = (CACurrentMediaTime(), [], 0)
    }

    struct Result {
        var averageFPS: Double
        var worstSecondFPS: Int
        var hitches: Int
        var longestFrameMs: Double
        var busy: Double
    }

    func endMeasuring() -> Result? {
        guard let span = measuring.take(), let first = span.frames.first, let last = span.frames.last, span.frames.count > 1 else { return nil }
        let duration = CACurrentMediaTime() - span.start
        let gaps = zip(span.frames.dropFirst(), span.frames).map { $0 - $1 }
        var worst = Int.max
        var second = first
        while second + 1 <= last {
            let end = second + 1
            worst = min(worst, span.frames.lazy.filter { $0 >= second && $0 < end }.count)
            second = end
        }
        return Result(averageFPS: Double(span.frames.count - 1) / (last - first),
                      worstSecondFPS: worst == .max ? span.frames.count : worst,
                      hitches: gaps.filter { $0 > frameDuration * 1.5 }.count,
                      longestFrameMs: (gaps.max() ?? 0) * 1000,
                      busy: max(0, min(1, 1 - span.waited / duration)))
    }
}

extension Optional {
    /// The value, leaving `nil` behind.
    mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}
