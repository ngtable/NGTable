#if os(iOS)
import UIKit

// What the iPad's table doesn't do yet: editing cells, menus, swipe actions,
// drag and drop, the header's pointer, the updating veil. The shared code
// calls these; here they do nothing, until the iPad gets each.

extension NGTableView {
    // Keyboard and type select.

    // Menus.
    func showChoiceMenu(row: Int, column: NGTableColumn) -> Bool { false }
    func showColumnFilter(for column: NGTableColumn, relativeTo rect: CGRect, of view: NGPlatformView) {}

    // Drag and drop.
    func dropGapOffset(ofDisplayRow row: Int, progress: CGFloat? = nil) -> CGFloat { 0 }
    func appendDropIndicator(style: MetalStyle, scale: CGFloat, to quads: inout [NGMetalQuad]) {}

    // The header's pointer (resizing and moving columns).
    func updateHeaderPointerAreas() {}

    // The pointer over cells.

    // Scroll bars: the iPad's scroll view shows its own.
    func layoutScrollers(_ metrics: LayoutMetrics) {}
    func updateScrollers() {}

    // The updating veil (`updatingData`).
    func beginDataUpdate() {}
    func endDataUpdate() {}
    func layoutDataUpdateOverlay() {}
}

/// The updating veil's place (it shows nothing yet on the iPad).
final class NGDataUpdateOverlay: UIView {
    var blocksInput = true
    var showsIndicator = false
    var text: String?
    var indicatorCenter: CGPoint = .zero
}
#endif
