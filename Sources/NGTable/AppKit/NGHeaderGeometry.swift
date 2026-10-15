#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Header and summary drawing, shared by the header view and the summary bar.
/// Both span the table horizontally, so "viewport x" is their local x.
extension NGTableView {
    /// Where each region starts in viewport coordinates for the current scroll position.
    struct Viewport {
        var scrollX: CGFloat
        var width: CGFloat
        var leadingOrigin: CGFloat
        var trailingOrigin: CGFloat
        var centerClipMinX: CGFloat
        var centerClipMaxX: CGFloat

        func origin(of pin: NGColumnPin) -> CGFloat {
            switch pin {
            case .leading: leadingOrigin
            case .none: -scrollX
            case .trailing: trailingOrigin
            }
        }

        /// The horizontal range in which a region's content is visible.
        func clipRange(of pin: NGColumnPin, regionWidth: CGFloat) -> ClosedRange<CGFloat> {
            switch pin {
            case .leading: leadingOrigin...(leadingOrigin + regionWidth)
            case .none: centerClipMinX...max(centerClipMinX, centerClipMaxX)
            case .trailing: trailingOrigin...(trailingOrigin + regionWidth)
            }
        }
    }

    var viewport: Viewport {
        let metrics = layoutMetrics
        return Viewport(
            // The same device-pixel position as the scrolling canvas.
            scrollX: pixelAligned(metrics.leadingWidth + physicalOffsetX) - metrics.centerX,
            width: bounds.width,
            leadingOrigin: metrics.leadingX,
            trailingOrigin: metrics.trailingX,
            centerClipMinX: metrics.centerX,
            centerClipMaxX: metrics.centerX + metrics.centerWidth
        )
    }

    /// Regions in drawing order: frozen regions are drawn last, over the center.
    var drawingOrder: [NGColumnPin] { [.none, .leading, .trailing] }

    // MARK: Header

    /// The columns of a region that can appear in `visibleRect`, found by binary
    /// search: the header and summary redraw on every horizontal scroll step.
    /// While columns slide (after a reorder) they may be anywhere, so all are drawn.
    func drawableColumns(of region: NGRegionGeometry, originX: CGFloat, visibleRect: CGRect) -> ArraySlice<NGColumnFrame> {
        guard columnSlideOffsets.isEmpty else { return region.columns[...] }
        return region.columns(intersecting: Double(visibleRect.minX - originX), Double(visibleRect.maxX - originX))
    }

    /// The leaf column under a point of the header or summary, with its region.
    func column(atViewportPoint point: CGPoint) -> (frame: NGColumnFrame, pin: NGColumnPin)? {
        let viewport = viewport
        for pin in drawingOrder.reversed() {
            let region = geometry[pin]
            guard !region.isEmpty,
                  viewport.clipRange(of: pin, regionWidth: CGFloat(region.width)).contains(point.x) else { continue }
            return region.column(atX: Double(point.x - viewport.origin(of: pin))).map { ($0, pin) }
        }
        return nil
    }
}
#endif
