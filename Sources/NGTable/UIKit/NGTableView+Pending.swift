#if os(iOS)
import UIKit

// What the iPad's table doesn't do yet: dragging rows and dropping on them.
// The shared code calls these; here they do nothing. The header's pointer
// areas and scroll bars are AppKit's; the iPad's scroll view shows its own.

extension NGTableView {
    // The Mac's cursor areas and scroll bars.
    func updateHeaderPointerAreas() {}
    func layoutScrollers(_ metrics: LayoutMetrics) {}
    func updateScrollers() {}
}
#endif
