#if os(iOS)
import UIKit

// What the iPad's table doesn't do yet: dragging rows and dropping on them.
// The shared code calls these; here they do nothing. The header's pointer
// areas and scroll bars are AppKit's; the iPad's scroll view shows its own.

extension NGTableView {
    // Drag and drop.
    func dropGapOffset(ofDisplayRow row: Int, progress: CGFloat? = nil) -> CGFloat { 0 }
    func appendDropIndicator(style: MetalStyle, scale: CGFloat, to quads: inout [NGMetalQuad]) {}

    // The Mac's cursor areas and scroll bars.
    func updateHeaderPointerAreas() {}
    func layoutScrollers(_ metrics: LayoutMetrics) {}
    func updateScrollers() {}
}
#endif
