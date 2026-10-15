#if os(iOS)
import UIKit

// The table on the iPad: UIKit's layout pass runs the table's; a scroll view
// over the rows gives the finger momentum, the rubber band at the top and
// bottom and the scroll indicators (it holds no content: its offset is the
// table's); a tap selects a row, or sorts by a column's title in the header.

extension NGTableView {
    public override func layoutSubviews() {
        super.layoutSubviews()
        layOutTable()
        layOutTouchScrollView()
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.displayScale != traitCollection.displayScale { backingPropertiesDidChange() }
        if previous?.hasDifferentColorAppearance(comparedTo: traitCollection) ?? true { appearanceDidChange() }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        needsLayout = true
        setNeedsMetalFrame()
        setNeedsChromeFrame(headerView)
        setNeedsChromeFrame(summaryBar.contentView)
    }

    /// The scroll view over the rows, and the taps.
    func setUpTouch() {
        let delegate = NGTouchScrollDelegate(table: self)
        touchScrollDelegate = delegate
        touchScrollView.delegate = delegate
        touchScrollView.backgroundColor = .clear
        touchScrollView.contentInsetAdjustmentBehavior = .never
        touchScrollView.alwaysBounceVertical = true
        touchScrollView.showsHorizontalScrollIndicator = true
        if #available(iOS 17.4, *) { touchScrollView.bouncesHorizontally = false }
        addSubview(touchScrollView)
        let tap = UITapGestureRecognizer(target: delegate, action: #selector(NGTouchScrollDelegate.tapped(_:)))
        addGestureRecognizer(tap)
    }

    /// Over the rows (under the header and the summary row), as large as the
    /// content: its offsets are the table's.
    func layOutTouchScrollView() {
        let metrics = layoutMetrics
        let frame = CGRect(x: 0, y: metrics.headerHeight, width: bounds.width, height: max(0, metrics.bodyHeight))
        if touchScrollView.frame != frame { touchScrollView.frame = frame }
        let size = CGSize(width: frame.width + metrics.maxOffset.x, height: frame.height + metrics.maxOffset.y)
        if touchScrollView.contentSize != size { touchScrollView.contentSize = size }
        touchScrollView.verticalScrollIndicatorInsets.bottom = metrics.summaryHeight
        touchScrollView.horizontalScrollIndicatorInsets.bottom = metrics.summaryHeight
        // Scrolled in code (or the content shrank): the scroll view follows.
        if !touchScrollView.isTracking, !touchScrollView.isDecelerating, touchScrollView.contentOffset != contentOffset {
            isSyncingTouchScroll = true
            touchScrollView.contentOffset = contentOffset
            isSyncingTouchScroll = false
        }
    }

    /// The scroll view moved: the table goes there, past the top or bottom
    /// as the rubber band.
    func touchScrollViewDidScroll() {
        guard !isSyncingTouchScroll else { return }
        let offset = touchScrollView.contentOffset
        let maxOffset = layoutMetrics.maxOffset
        let clamped = CGPoint(x: min(max(offset.x, 0), maxOffset.x), y: min(max(offset.y, 0), maxOffset.y))
        setContentOffset(clamped)
        setVerticalOverscroll(offset.y - clamped.y)
    }

    /// A tap: on a title it sorts by its column, on a row it selects it (and
    /// sends `action`).
    func tapped(at point: CGPoint) {
        guard !ignoresUserInput else { return }
        if point.y < layoutMetrics.headerHeight {
            if let (frame, _) = column(atViewportPoint: point), frame.column.isSortable { sortByClicking(frame.column) }
            return
        }
        let row = row(at: point)
        clickedRow = row
        clickedColumn = column(at: point)
        if row >= 0 {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        if let action { UIApplication.shared.sendAction(action, to: target, from: self, for: nil) }
    }
}

/// The scroll view's and the tap's delegate (an object: UIKit holds it).
final class NGTouchScrollDelegate: NSObject, UIScrollViewDelegate {
    weak var table: NGTableView?

    init(table: NGTableView) {
        self.table = table
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        table?.touchScrollViewDidScroll()
    }

    @objc func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let table else { return }
        table.tapped(at: recognizer.location(in: table))
    }
}
#endif
