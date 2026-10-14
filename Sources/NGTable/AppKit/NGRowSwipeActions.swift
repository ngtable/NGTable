#if os(macOS)
import AppKit

// Swipe actions on rows, like NSTableView's `rowActionsForRow:edge:`: a
// two-finger swipe across a row slides it aside and shows the delegate's
// actions (`NGRowAction`, like `NSTableViewRowAction`) as buttons in the room it leaves; trailing
// actions to the left, leading ones to the right. Released past half the
// buttons, they stay open; a long swipe performs the first action if it is
// destructive, like Mail. A click elsewhere, scrolling or new data close
// them. A table that can scroll sideways scrolls first: a swipe opens actions
// only at the edge it would scroll past.

/// An action a swipe across a row shows, like `NSTableViewRowAction` (whose
/// handler AppKit keeps to itself): the same initializer, style and color.
@MainActor
public final class NGRowAction: NSObject {
    public typealias Style = NSTableViewRowAction.Style
    public let style: Style
    public var title: String
    /// Red for destructive actions, gray otherwise, like AppKit's.
    public var backgroundColor: NSColor
    /// Called with the action and the data source row.
    public let handler: (NGRowAction, Int) -> Void

    public init(style: Style, title: String, handler: @escaping (NGRowAction, Int) -> Void) {
        self.style = style
        self.title = title
        self.handler = handler
        backgroundColor = style == .destructive ? .systemRed : .systemGray
        super.init()
    }
}

/// A row's actions being swiped open, or open.
struct NGRowSwipe {
    let ref: NGRowRef
    let edge: NSTableView.RowActionEdge
    let actions: [NGRowAction]
    /// How far the row has slid: negative to the left (trailing actions).
    var offset: CGFloat
    var isTracking: Bool
}

extension NGTableView {
    /// Whether a row's actions show, like NSTableView's `rowActionsVisible`;
    /// set it to `false` to close them.
    public var rowActionsVisible: Bool {
        get { rowSwipe != nil }
        set { if !newValue { closeRowActions() } }
    }

    /// The display row whose content slides with a swipe, if any.
    var swipedDisplayRow: Int? {
        guard let swipe = rowSwipe else { return nil }
        let row = row(of: swipe.ref)
        return row >= 0 ? displayRow(forSourceRow: row) : nil
    }

    /// The x offset of a display row's content (its swipe).
    func swipeOffset(ofDisplayRow displayRow: Int) -> CGFloat {
        guard let swipe = rowSwipe, displayRow == swipedDisplayRow else { return 0 }
        return swipe.offset
    }

    /// Takes a trackpad swipe across a row for its actions; whether the
    /// event was the swipe's (the table doesn't scroll with it).
    func handleRowSwipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, delegate != nil, !ignoresUserInput else { return false }
        // The momentum after a swipe is the swipe's.
        if !event.momentumPhase.isEmpty { return rowSwipe != nil && swipeTookGesture }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            swipeTookGesture = false
            swipeCandidate = event.locationInWindow
            if let swipe = rowSwipe, !swipe.isTracking {
                // A new swipe on the open row moves it; elsewhere it closes it.
                if row(atWindowLocation: event.locationInWindow) == swipedDisplayRow {
                    rowSwipe?.isTracking = true
                    swipeTookGesture = true
                    swipeCandidate = nil
                } else {
                    closeRowActions()
                }
            }
            return swipeTookGesture
        }
        if let location = swipeCandidate, event.phase.contains(.changed), rowSwipe == nil {
            let (dx, dy) = (event.scrollingDeltaX, event.scrollingDeltaY)
            guard dx != 0 || dy != 0 else { return false }
            swipeCandidate = nil
            guard abs(dx) > abs(dy) * 1.5 else { return false }
            let displayRow = row(atWindowLocation: location)
            guard displayRow >= 0, displayRow < numberOfRows, !isGroupRow(displayRow) else { return false }
            // Sliding left shows the trailing actions, right the leading ones,
            // where the table can't scroll further that way.
            // (Right to left, the trailing actions are at the left.)
            let revealsRight = dx < 0
            let edge: NSTableView.RowActionEdge = revealsRight != isRightToLeft ? .trailing : .leading
            let atEdge = edge == .trailing ? contentOffset.x >= layoutMetrics.maxOffset.x - 0.5 : contentOffset.x <= 0.5
            guard atEdge, let delegate else { return false }
            let source = sourceRow(displayRow)
            let actions = delegate.tableView(self, rowActionsForRow: source, edge: edge)
            guard !actions.isEmpty else { return false }
            rowSwipe = NGRowSwipe(ref: rowRef(ofRow: source), edge: edge, actions: actions, offset: 0, isTracking: true)
            swipeTookGesture = true
        }
        guard var swipe = rowSwipe, swipe.isTracking, swipeTookGesture else { return false }
        if event.phase.contains(.changed) {
            let limit = bounds.width
            swipe.offset = buttonsOnRight(swipe.edge) ? min(0, max(-limit, swipe.offset + event.scrollingDeltaX))
                : max(0, min(limit, swipe.offset + event.scrollingDeltaX))
            rowSwipe = swipe
            layoutRowActionButtons()
            setNeedsMetalFrame()
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            finishRowSwipe()
        }
        return true
    }

    /// At the end of a swipe: open, closed, or the first action performed.
    private func finishRowSwipe() {
        guard var swipe = rowSwipe else { return }
        let buttons = rowActionButtonsWidth(swipe.actions)
        let distance = abs(swipe.offset)
        if distance > bounds.width * 0.6, let first = swipe.actions.first, first.style == .destructive {
            perform(first)
            return
        }
        guard distance > buttons / 2 else {
            closeRowActions()
            return
        }
        swipe.offset = buttonsOnRight(swipe.edge) ? -buttons : buttons
        swipe.isTracking = false
        rowSwipe = swipe
        layoutRowActionButtons()
        setNeedsMetalFrame()
    }

    /// Whether an edge's buttons are at the right: trailing ones left to
    /// right, leading ones right to left.
    func buttonsOnRight(_ edge: NSTableView.RowActionEdge) -> Bool {
        (edge == .trailing) != isRightToLeft
    }

    /// Closes the open actions.
    func closeRowActions() {
        guard rowSwipe != nil else { return }
        rowSwipe = nil
        swipeTookGesture = false
        rowActionButtons?.removeFromSuperview()
        rowActionButtons = nil
        setNeedsMetalFrame()
    }

    private func perform(_ action: NGRowAction) {
        guard let swipe = rowSwipe else { return }
        let row = row(of: swipe.ref)
        let isShown = swipedDisplayRow != nil
        closeRowActions()
        // Not on a record the user doesn't see (removed, filtered out, collapsed).
        guard row >= 0, isShown else { return }
        action.handler(action, row)
    }

    // MARK: Buttons

    private static let minimumButtonWidth: CGFloat = 64

    private func buttonWidth(_ action: NGRowAction) -> CGFloat {
        let title = (action.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        return max(Self.minimumButtonWidth, ceil(title.width) + 24)
    }

    private func rowActionButtonsWidth(_ actions: [NGRowAction]) -> CGFloat {
        actions.reduce(0) { $0 + buttonWidth($1) }
    }

    /// Puts the buttons in the room the row left.
    func layoutRowActionButtons() {
        guard let swipe = rowSwipe, let displayRow = swipedDisplayRow else {
            closeRowActions()
            return
        }
        let container = rowActionButtons ?? makeRowActionButtons(swipe)
        let rowHeight = rowGeometry.height(of: displayRow)
        let rowFrame = convert(NSRect(x: 0, y: rowGeometry.top(of: displayRow), width: 1, height: rowHeight), from: centerRegion.canvas)
        let revealed = abs(swipe.offset)
        container.frame = NSRect(x: buttonsOnRight(swipe.edge) ? bounds.width - revealed : 0, y: rowFrame.minY,
                                 width: revealed, height: rowHeight)
        // The buttons share the room by their widths.
        let total = max(1, rowActionButtonsWidth(swipe.actions))
        var x: CGFloat = 0
        for (button, action) in zip(container.subviews, swipe.actions) {
            let width = revealed * buttonWidth(action) / total
            button.frame = NSRect(x: x, y: 0, width: width, height: rowHeight)
            x += width
        }
    }

    private func makeRowActionButtons(_ swipe: NGRowSwipe) -> NSView {
        let container = NGFlippedView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        for (index, action) in swipe.actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(rowActionButtonClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = action.backgroundColor.cgColor
            button.contentTintColor = .white
            button.attributedTitle = NSAttributedString(string: action.title, attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            ])
            container.addSubview(button)
        }
        addSubview(container, positioned: .below, relativeTo: headerBackground)
        rowActionButtons = container
        return container
    }

    @objc private func rowActionButtonClicked(_ sender: NSButton) {
        guard let swipe = rowSwipe, sender.tag < swipe.actions.count else { return }
        perform(swipe.actions[sender.tag])
    }
}
#endif
