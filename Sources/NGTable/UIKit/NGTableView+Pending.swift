#if os(iOS)
import UIKit

// What the iPad's table doesn't do yet: editing cells, menus, swipe actions,
// drag and drop, the header's pointer, the updating veil. The shared code
// calls these; here they do nothing, until the iPad gets each.

extension NGTableView {
    // Editing cells.
    func canEdit(row: Int, columnID: String) -> Bool { false }
    func endEditing(committing: Bool) {}
    func layoutCellEditor() {}
    func appendFocusRing(style: MetalStyle, scale: CGFloat, to quads: inout [NGMetalQuad]) {}

    // Keyboard and type select.
    func focusCell(displayRow: Int, columnID: String) {}
    func typeSelectMatch(from start: Int, to end: Int, for prefix: String) -> Int { -1 }

    // Menus.
    func rowsMenuDidClose() {}
    func showMenuOutline(forRow row: Int) {}
    func showChoiceMenu(row: Int, column: NGTableColumn) -> Bool { false }
    func showColumnFilter(for column: NGTableColumn, relativeTo rect: CGRect, of view: NGPlatformView) {}

    // Swipe actions.
    func closeRowActions() {}
    func layoutRowActionButtons() {}
    var swipedDisplayRow: Int? { nil }
    func swipeOffset(ofDisplayRow displayRow: Int) -> CGFloat { 0 }

    // Drag and drop.
    func dropGapOffset(ofDisplayRow row: Int, progress: CGFloat? = nil) -> CGFloat { 0 }
    func appendDropIndicator(style: MetalStyle, scale: CGFloat, to quads: inout [NGMetalQuad]) {}

    // The header's pointer (resizing and moving columns).
    var isHeaderInteracting: Bool { false }
    func cancelHeaderInteraction() {}
    func endColumnDragForResize() {}
    func updateHeaderPointerAreas() {}

    // The pointer over cells.
    func updateHoveredCellFromPointer() {}
    func syncControlUnderPointer() {}

    // Scroll bars: the iPad's scroll view shows its own.
    func layoutScrollers(_ metrics: LayoutMetrics) {}
    func updateScrollers() {}

    // Touches (NGTableView+UIKit.swift sets them up).
    func setUpTouch() {}

    // The updating veil (`updatingData`).
    func beginDataUpdate() {}
    func endDataUpdate() {}
    func layoutDataUpdateOverlay() {}
}

/// Pending kinds of the shared state: their parts come with the features.
final class NGCellEditor {}
final class NGRowSwipe {}
final class NGAccessibilityRow {}
final class NGAccessibilityColumnHeader {}
final class NGAccessibilityColumn {}
final class NGAccessibilitySummary {
    init(table: NGTableView) {}
}

/// The updating veil's place (it shows nothing yet on the iPad).
final class NGDataUpdateOverlay: UIView {
    var blocksInput = true
    var showsIndicator = false
    var text: String?
    var indicatorCenter: CGPoint = .zero
}
#endif
