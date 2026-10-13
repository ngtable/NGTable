#if os(macOS)
import AppKit
import QuartzCore

/// A running elastic animation of the vertical overscroll.
enum ElasticAnimation {
    /// Returning to the edge after the finger lifts past it (no overshoot).
    case springBack(from: CGFloat, start: CFTimeInterval)
    /// A short overshoot when momentum scrolling hits an edge.
    case bounce(velocity: CGFloat, start: CFTimeInterval)
}

/// Elastic ("rubber band") vertical scrolling, like system scroll views:
/// - pulling past an edge with the finger meets increasing resistance;
/// - releasing past an edge springs back, and the following momentum is ignored;
/// - momentum that hits an edge overshoots briefly and bounces back;
/// - grabbing during an animation stops it, and the pull continues from there.
extension NGTableView {
    /// Critically damped spring stiffness: higher returns faster.
    private static let springOmega: CGFloat = 12
    /// Resistance of the rubber band, as in UIKit/AppKit.
    private static let rubberBandCoefficient: CGFloat = 0.55
    private static let maximumBounceVelocity: CGFloat = 2500

    /// Displayed overscroll for a raw pull distance: grows ever more slowly.
    private func rubberBand(_ raw: CGFloat) -> CGFloat {
        let dimension = max(1, layoutMetrics.bodyHeight)
        let resisted = (1 - 1 / (abs(raw) * Self.rubberBandCoefficient / dimension + 1)) * dimension
        return raw < 0 ? -resisted : resisted
    }

    /// The raw pull distance that produces a displayed overscroll.
    private func inverseRubberBand(_ displayed: CGFloat) -> CGFloat {
        let dimension = max(1, layoutMetrics.bodyHeight)
        let value = min(abs(displayed), dimension - 1)
        let raw = dimension * value / (Self.rubberBandCoefficient * (dimension - value))
        return displayed < 0 ? -raw : raw
    }

    func handleElasticPhases(of event: NSEvent) {
        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            // Grabbing during an animation stops it; the pull continues from there.
            stopElasticAnimation()
            rawVerticalOverscroll = inverseRubberBand(verticalOverscroll)
            ignoresMomentum = false
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            rawVerticalOverscroll = 0
            if verticalOverscroll != 0 {
                ignoresMomentum = true
                startElasticAnimation(.springBack(from: verticalOverscroll, start: CACurrentMediaTime()))
            } else if event.phase.contains(.cancelled) {
                ignoresMomentum = false
            }
        }
    }

    func scrollVerticallyWithElasticity(by deltaY: CGFloat, event: NSEvent) {
        let interval = max(1.0 / 120, event.timestamp - lastScrollEventTimestamp)
        lastScrollEventTimestamp = event.timestamp
        let maxY = layoutMetrics.maxOffset.y

        if !event.momentumPhase.isEmpty {
            guard !ignoresMomentum, elasticAnimation == nil else { return }
            let proposed = contentOffset.y - deltaY
            guard proposed < 0 || proposed > maxY else {
                setContentOffset(CGPoint(x: contentOffset.x, y: proposed))
                return
            }
            // Momentum hits the edge: stop there and overshoot briefly.
            setContentOffset(CGPoint(x: contentOffset.x, y: proposed))
            let velocity = max(-Self.maximumBounceVelocity, min(Self.maximumBounceVelocity, -deltaY / CGFloat(interval)))
            ignoresMomentum = true
            startElasticAnimation(.bounce(velocity: velocity, start: CACurrentMediaTime()))
            return
        }

        // The finger is on the trackpad.
        if rawVerticalOverscroll != 0 {
            let raw = rawVerticalOverscroll - deltaY
            if (rawVerticalOverscroll < 0) != (raw < 0) || raw == 0 {
                // Pulled back across the edge: the rest scrolls the content.
                rawVerticalOverscroll = 0
                setVerticalOverscroll(0)
                setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y + raw))
            } else {
                rawVerticalOverscroll = raw
                setVerticalOverscroll(rubberBand(raw))
            }
            return
        }
        let proposed = contentOffset.y - deltaY
        let clamped = min(max(proposed, 0), maxY)
        setContentOffset(CGPoint(x: contentOffset.x, y: clamped))
        if proposed != clamped {
            rawVerticalOverscroll = proposed - clamped
            setVerticalOverscroll(rubberBand(rawVerticalOverscroll))
        }
    }

    func setVerticalOverscroll(_ value: CGFloat) {
        guard value != verticalOverscroll else { return }
        verticalOverscroll = value
        applyScrollPosition()
    }

    // MARK: Animation

    private func startElasticAnimation(_ animation: ElasticAnimation) {
        elasticAnimation = animation
        if elasticLink == nil {
            let link = displayLink(target: self, selector: #selector(stepElasticAnimation(_:)))
            link.add(to: .main, forMode: .common)
            elasticLink = link
        }
    }

    func stopElasticAnimation() {
        elasticAnimation = nil
        elasticLink?.invalidate()
        elasticLink = nil
    }

    @objc func stepElasticAnimation(_ link: CADisplayLink) {
        guard let animation = elasticAnimation else {
            stopElasticAnimation()
            return
        }
        let omega = Self.springOmega
        let value: CGFloat
        let elapsed: CGFloat
        switch animation {
        case .springBack(let from, let start):
            elapsed = CGFloat(CACurrentMediaTime() - start)
            value = from * (1 + omega * elapsed) * exp(-omega * elapsed)
        case .bounce(let velocity, let start):
            elapsed = CGFloat(CACurrentMediaTime() - start)
            value = velocity * elapsed * exp(-omega * elapsed)
        }
        if elapsed > 0.1, abs(value) < 0.5 {
            stopElasticAnimation()
            setVerticalOverscroll(0)
        } else {
            setVerticalOverscroll(value)
        }
    }
}
#endif
