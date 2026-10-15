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

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        needsLayout = true
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
        // Not waiting for the single tap to fail: the first tap selects at
        // once, the second sends `doubleAction` (a double click on the Mac).
        let doubleTap = UITapGestureRecognizer(target: delegate, action: #selector(NGTouchScrollDelegate.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    /// Over the rows (under the header and the summary row), as large as the
    /// content: its offsets are the table's.
    func layOutTouchScrollView() {
        let metrics = layoutMetrics
        let frame = CGRect(x: 0, y: metrics.headerHeight, width: bounds.width, height: max(0, metrics.bodyHeight))
        if touchScrollView.frame != frame { touchScrollView.frame = frame }
        let size = CGSize(width: frame.width + metrics.maxOffset.x, height: frame.height + metrics.maxOffset.y)
        if touchScrollView.contentSize != size { touchScrollView.contentSize = size }
        touchScrollView.verticalScrollIndicatorInsets.bottom = metrics.bottomInset
        touchScrollView.horizontalScrollIndicatorInsets.bottom = metrics.bottomInset
        followInTouchScrollView()
    }

    /// Scrolled in code (or the content shrank): the scroll view goes there
    /// too, or the finger's next scroll would start from where it was.
    func followInTouchScrollView() {
        guard !isSyncingTouchScroll, !touchScrollView.isTracking, !touchScrollView.isDecelerating,
              touchScrollView.contentOffset != contentOffset else { return }
        isSyncingTouchScroll = true
        touchScrollView.contentOffset = contentOffset
        isSyncingTouchScroll = false
    }

    /// The scroll view moved: the table goes there, past the top or bottom
    /// as the rubber band.
    func touchScrollViewDidScroll() {
        guard !isSyncingTouchScroll else { return }
        let offset = touchScrollView.contentOffset
        let maxOffset = layoutMetrics.maxOffset
        let clamped = CGPoint(x: min(max(offset.x, 0), maxOffset.x), y: min(max(offset.y, 0), maxOffset.y))
        // The scroll view leads here (also in its own animations): it isn't moved back.
        isSyncingTouchScroll = true
        setContentOffset(clamped)
        isSyncingTouchScroll = false
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
        guard point.y < bounds.height - layoutMetrics.summaryHeight else { return }
        let row = row(at: point)
        clickedRow = row
        clickedColumn = column(at: point)
        if row >= 0 {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        send(action)
    }

    /// A second tap on the rows: `doubleAction`.
    func doubleTapped(at point: CGPoint) {
        guard !ignoresUserInput, point.y >= layoutMetrics.headerHeight,
              point.y < bounds.height - layoutMetrics.summaryHeight else { return }
        clickedRow = row(at: point)
        clickedColumn = column(at: point)
        send(doubleAction)
    }

    /// To `target`, or along the responder chain without one.
    private func send(_ action: Selector?) {
        guard let action else { return }
        if let target = target as? NSObjectProtocol {
            _ = target.perform(action, with: self)
        } else {
            UIApplication.shared.sendAction(action, to: nil, from: self, for: nil)
        }
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

    @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard let table else { return }
        table.doubleTapped(at: recognizer.location(in: table))
    }
}
#endif
