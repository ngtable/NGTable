#if os(macOS)
import AppKit

// Animated row changes, like NSTableView's `withAnimation:`: when a batch
// that asked for animation (or moved rows by the table's own sort, with
// `animatesSortMoves`) finishes, rows in view that moved slide from where
// they were, new rows fade in, and rows gone (removed, or hidden by the
// filter) fade out where they were. Layout puts everything at its final
// place at once (clicks, selection and hit testing use it); only drawing
// interpolates: the renderer offsets the cells and backgrounds of moved
// display rows, fades in new ones, and draws the gone rows' cells, kept
// aside, until the animation ends. A new batch, a reload or scrolling
// doesn't wait: the next batch finishes the running animation first.

/// A running row animation (see NGRowAnimation.swift).
struct NGRowAnimation {
    let start: CFTimeInterval
    /// Display row → how far above (negative: below) its final place it
    /// started, in points.
    var offsets: [Int: CGFloat]
    /// Display rows of new records: they fade in.
    var appearing: Set<Int>
    /// Cells of records gone from view, at their old frames: they fade out.
    var disappearing: [NGDrawnCell]
    /// How rows come and go.
    var effect: Effect = .fade

    /// How rows come and go, from NSTableView's animation options (the
    /// other rows slide to their places with every one).
    enum Effect: Equatable {
        /// Fading in and out (`.effectFade`, and `animatesSortMoves`).
        case fade
        /// At once, in the gap the others open (`.effectGap`).
        case gap
        /// Sliding in and out that way, a row's height up or down or the
        /// table's width sideways, fading too (`.slideUp`, `.slideDown`,
        /// `.slideLeft`, `.slideRight`).
        case slide(dx: CGFloat, dy: CGFloat)

        init(_ options: NSTableView.AnimationOptions) {
            // The slides are values of one field (`.slideLeft` has
            // `.slideUp`'s bit), not flags.
            switch options.rawValue & 0xF0 {
            case NSTableView.AnimationOptions.slideUp.rawValue: self = .slide(dx: 0, dy: -1)
            case NSTableView.AnimationOptions.slideDown.rawValue: self = .slide(dx: 0, dy: 1)
            case NSTableView.AnimationOptions.slideLeft.rawValue: self = .slide(dx: -1, dy: 0)
            case NSTableView.AnimationOptions.slideRight.rawValue: self = .slide(dx: 1, dy: 0)
            default: self = options.contains(.effectGap) && !options.contains(.effectFade) ? .gap : .fade
            }
        }
    }
}

extension NGTableView {
    static let rowAnimationDuration: CFTimeInterval = 0.25

    /// The animation's progress now, eased (0 at the start, 1 at the end).
    var rowAnimationProgress: CGFloat {
        guard let rowAnimation else { return 1 }
        let linear = min(1, max(0, (CACurrentMediaTime() - rowAnimation.start) / Self.rowAnimationDuration))
        return CGFloat(1 - pow(1 - linear, 3))   // Ease out.
    }

    /// How far above its final place a display row is drawn now.
    func rowAnimationOffset(ofDisplayRow row: Int) -> CGFloat {
        guard let offset = rowAnimation?.offsets[row] else { return 0 }
        return offset * (1 - rowAnimationProgress)
    }

    /// Where a display row is drawn now (or at `progress`) from its place:
    /// moved rows from where they were, new ones from where they slide in.
    func rowAnimationShift(ofDisplayRow row: Int, progress: CGFloat? = nil) -> CGPoint {
        guard let rowAnimation else { return .zero }
        let rest = 1 - (progress ?? rowAnimationProgress)
        if rowAnimation.appearing.contains(row), case .slide(let dx, let dy) = rowAnimation.effect {
            // Moving that way: it starts on the other side.
            return CGPoint(x: -dx * bounds.width * rest, y: -dy * rowGeometry.height(of: row) * rest)
        }
        return CGPoint(x: 0, y: (rowAnimation.offsets[row] ?? 0) * rest)
    }

    /// How far gone rows' cells have moved now (or at `progress`) as they slide out.
    func disappearingShift(progress: CGFloat? = nil) -> CGPoint {
        guard let rowAnimation, case .slide(let dx, let dy) = rowAnimation.effect else { return .zero }
        let done = progress ?? rowAnimationProgress
        return CGPoint(x: dx * bounds.width * done, y: dy * rowHeight * done)
    }

    /// Where a display row is drawn now from its place: its animation, and
    /// a drop's gap below it.
    func rowDrawShift(ofDisplayRow row: Int) -> CGPoint {
        let shift = rowAnimationShift(ofDisplayRow: row)
        return CGPoint(x: shift.x, y: shift.y + dropGapOffset(ofDisplayRow: row))
    }

    /// How opaque a display row is drawn now (or at `progress`): new rows
    /// fade in (in a gap, at once).
    func rowAnimationOpacity(ofDisplayRow row: Int, progress: CGFloat? = nil) -> Float {
        guard let rowAnimation, rowAnimation.appearing.contains(row), rowAnimation.effect != .gap else { return 1 }
        return Float(progress ?? rowAnimationProgress)
    }

    /// Starts animating a batch's moves: `moves` maps each old display row in
    /// view to its new one, `appearing` are the new records' display rows,
    /// `disappearing` the cells of rows gone from view.
    func startRowAnimation(moves: [Int: Int], appearing: Set<Int>, disappearing: [NGDrawnCell], effect: NGRowAnimation.Effect = .fade) {
        finishRowAnimation()
        var offsets: [Int: CGFloat] = [:]
        let rowLayout = rowGeometry
        for (old, new) in moves where old != new {
            offsets[new] = rowLayout.offset(from: old, to: new)
        }
        // Out of a window a display link doesn't run (and would keep the
        // table alive): everything is at its place at once.
        // With Reduce Motion, rows change at once.
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !offsets.isEmpty || !appearing.isEmpty || !disappearing.isEmpty else {
            disappearing.forEach(recycle)
            return
        }
        rowAnimation = NGRowAnimation(start: CACurrentMediaTime(), offsets: offsets, appearing: appearing,
                                      disappearing: disappearing, effect: effect)
        if rowAnimationLink == nil {
            let link = displayLink(target: self, selector: #selector(stepRowAnimation(_:)))
            link.add(to: .main, forMode: .common)
            rowAnimationLink = link
        }
        setNeedsMetalFrame()
    }

    @objc func stepRowAnimation(_ link: CADisplayLink) {
        if rowAnimationProgress >= 1 {
            finishRowAnimation()
        }
        setNeedsMetalFrame()
    }

    /// Ends the running animation at once: everything at its final place.
    func finishRowAnimation() {
        rowAnimationLink?.invalidate()
        rowAnimationLink = nil
        guard let animation = rowAnimation.take() else { return }
        animation.disappearing.forEach(recycle)
        setNeedsMetalFrame()
    }
}
#endif
