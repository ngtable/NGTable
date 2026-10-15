#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The row a context menu is for, when it isn't selected: outlined, the
// selection left as it is (like Finder and Mail), until the menu closes.

extension NGTableView {
    func rowsMenuDidClose() {
        menuOutline?.removeFromSuperview()
        menuOutline = nil
        menuOutlineRow = nil
        menuOutlineRef = nil
    }

    /// The row a menu is for, outlined without changing the selection. It
    /// follows its record when the table scrolls or a live sort moves it.
    func showMenuOutline(forRow row: Int) {
        if menuOutlineRow != row || menuOutlineRef == nil {
            let source = sourceRow(row)
            menuOutlineRef = source >= 0 ? rowRef(ofRow: source) : nil
        }
        menuOutlineRow = row
        menuOutline?.isHidden = false
        let outline = menuOutline ?? NGColorView()
        outline.borderColor = .controlAccentColor
        let metrics = layoutMetrics
        let inset = selectionHighlightStyle == .rounded ? NGMetrics.selectionInset : 0
        outline.cornerRadius = selectionHighlightStyle == .rounded ? NGMetrics.selectionCornerRadius : 0
        outline.roundedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let y = pixelAligned(metrics.headerHeight - renderedOffsetY) + rowGeometry.top(of: row)
        // The columns' span, whichever side the frozen regions are on.
        let left = min(metrics.leadingX, metrics.trailingX, metrics.centerX)
        let right = max(metrics.leadingX + metrics.leadingWidth, metrics.trailingX + metrics.trailingWidth,
                        metrics.centerX + metrics.centerWidth)
        outline.frame = CGRect(x: left + inset, y: y, width: max(0, right - left - 2 * inset), height: rowGeometry.height(of: row))
        // Above the rows, below the header and scrollers.
        if outline.superview !== self {
            addSubview(outline, positioned: .below, relativeTo: headerBackground)
        }
        menuOutline = outline
    }
}
#endif
