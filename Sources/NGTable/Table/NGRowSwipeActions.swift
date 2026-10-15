#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Swipe actions on rows, like NSTableView's `rowActionsForRow:edge:`: a
// two-finger swipe across a row slides it aside and shows the delegate's
// actions (`NGRowAction`, like `NSTableViewRowAction`) as buttons in the room it leaves; trailing
// actions to the left, leading ones to the right. Released past half the
// buttons, they stay open; a long swipe performs the first action if it is
// destructive, like Mail. A click elsewhere, scrolling or new data close
// them. A table that can scroll sideways scrolls first: a swipe opens actions
// only at the edge it would scroll past. On the iPad a finger's swipe does
// the same (NGTableTouch.swift), and a tap on a button performs its action.

/// An action a swipe across a row shows, like `NSTableViewRowAction` (whose
/// handler AppKit keeps to itself): the same initializer, style and color.
@MainActor
public final class NGRowAction: NSObject {
    #if os(macOS)
    public typealias Style = NSTableViewRowAction.Style
    #else
    /// Like `NSTableViewRowAction.Style`.
    public enum Style: Int, Sendable {
        case regular, destructive
    }
    #endif
    public let style: Style
    public var title: String
    /// Red for destructive actions, gray otherwise, like AppKit's.
    public var backgroundColor: NGColor
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

    #if os(macOS)
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
            // Sliding left shows the trailing actions, right the leading ones,
            // where the table can't scroll further that way.
            guard beginRowSwipe(displayRow: row(atWindowLocation: location), revealsRight: dx < 0) else { return false }
            swipeTookGesture = true
        }
        guard var swipe = rowSwipe, swipe.isTracking, swipeTookGesture else { return false }
        if event.phase.contains(.changed) {
            moveRowSwipe(by: event.scrollingDeltaX)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            finishRowSwipe()
        }
        return true
    }
    #endif

    /// Starts a swipe on a display row toward a side (`revealsRight`: the
    /// row slides left), if the table can't scroll further that way and the
    /// delegate has actions there; whether it did.
    func beginRowSwipe(displayRow: Int, revealsRight: Bool) -> Bool {
        guard displayRow >= 0, displayRow < numberOfRows, !isGroupRow(displayRow), let delegate else { return false }
        // (Right to left, the trailing actions are at the left.)
        let edge: NSTableView.RowActionEdge = revealsRight != isRightToLeft ? .trailing : .leading
        let atEdge = edge == .trailing ? contentOffset.x >= layoutMetrics.maxOffset.x - 0.5 : contentOffset.x <= 0.5
        guard atEdge else { return false }
        let source = sourceRow(displayRow)
        let actions = delegate.tableView(self, rowActionsForRow: source, edge: edge)
        guard !actions.isEmpty else { return false }
        rowSwipe = NGRowSwipe(ref: rowRef(ofRow: source), edge: edge, actions: actions, offset: 0, isTracking: true)
        return true
    }

    /// The swiping row slides by `delta` (positive: to the right).
    func moveRowSwipe(by delta: CGFloat) {
        guard var swipe = rowSwipe, swipe.isTracking else { return }
        let limit = bounds.width
        swipe.offset = buttonsOnRight(swipe.edge) ? min(0, max(-limit, swipe.offset + delta))
            : max(0, min(limit, swipe.offset + delta))
        rowSwipe = swipe
        layoutRowActionButtons()
        setNeedsMetalFrame()
    }

    /// At the end of a swipe: open, closed, or the first action performed.
    func finishRowSwipe() {
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

    func perform(_ action: NGRowAction) {
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

    private static var buttonFont: NGFont {
        #if os(macOS)
        NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        #else
        UIFont.systemFont(ofSize: UIFont.labelFontSize, weight: .medium)
        #endif
    }

    private func buttonWidth(_ action: NGRowAction) -> CGFloat {
        let title = (action.title as NSString).size(withAttributes: [.font: Self.buttonFont])
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
        let rowFrame = convert(CGRect(x: 0, y: rowGeometry.top(of: displayRow), width: 1, height: rowHeight), from: centerRegion.canvas)
        let revealed = abs(swipe.offset)
        container.frame = CGRect(x: buttonsOnRight(swipe.edge) ? bounds.width - revealed : 0, y: rowFrame.minY,
                                 width: revealed, height: rowHeight)
        // The buttons share the room by their widths.
        let total = max(1, rowActionButtonsWidth(swipe.actions))
        var x: CGFloat = 0
        for (button, action) in zip(container.subviews, swipe.actions) {
            let width = revealed * buttonWidth(action) / total
            button.frame = CGRect(x: x, y: 0, width: width, height: rowHeight)
            x += width
        }
    }

    #if os(macOS)
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
    #else
    /// The buttons: labels on the actions' colors (the table's tap presses them).
    private func makeRowActionButtons(_ swipe: NGRowSwipe) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        for action in swipe.actions {
            let label = UILabel()
            label.text = action.title
            label.textColor = .white
            label.font = Self.buttonFont
            label.textAlignment = .center
            label.backgroundColor = action.backgroundColor
            container.addSubview(label)
        }
        insertSubview(container, belowSubview: headerBackground)
        rowActionButtons = container
        return container
    }

    /// A tap while actions are open: on a button it performs its action,
    /// elsewhere it closes them. Whether there were open actions.
    func tapRowActions(at point: CGPoint) -> Bool {
        guard let swipe = rowSwipe, !swipe.isTracking else { return false }
        if let container = rowActionButtons, container.frame.contains(point) {
            let x = point.x - container.frame.minX
            if let index = container.subviews.firstIndex(where: { $0.frame.minX <= x && x < $0.frame.maxX }), index < swipe.actions.count {
                perform(swipe.actions[index])
                return true
            }
        }
        closeRowActions()
        return true
    }
    #endif
}
#endif
