#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Metal
import QuartzCore
import os

// The header's and the summary row's content drawn by Metal: titles, sort
// indicators, group titles, separators and summary values. Their backgrounds
// stay system views (the header material, Liquid Glass under the summary),
// so the content gets a transparent Metal layer of its own inside the header
// view and the summary's content view: the column drag snapshot and the
// scrollers stay above it. The views keep handling events, cursors, tool tips
// and accessibility; asking them to redraw marks their layer for the next
// frame, drawn with the rows before Core Animation commits.

/// The frames of one Metal layer the GPU hasn't finished. `nextDrawable()`
/// waits up to a second when the layer's drawables are all in use, on the
/// main thread; a layer asks for one only while one is free (one of its
/// drawables is on screen), and draws a frame it skipped when the GPU is done.
///
/// The count goes down on the GPU's completion thread, under a lock, not on
/// the main queue: code running in a main queue block (a main actor task)
/// that spins a nested run loop, e.g. a modal alert, would hold that back,
/// and the table would stop drawing. Waking the main run loop is enough: its
/// observer draws what waited, in nested loops too.
@MainActor
final class NGFramePacer {
    /// The layer's drawables (`maximumDrawableCount`).
    static let drawableCount = 3
    private let inFlight = OSAllocatedUnfairLock(initialState: 0)

    var framesInFlight: Int { inFlight.withLock { $0 } }

    /// Whether a drawable is free for a new frame.
    var canDraw: Bool { framesInFlight < Self.drawableCount - 1 }

    /// Counts a frame being drawn; the returned handler is the draw's completion.
    func frameDidStart() -> @Sendable () -> Void {
        inFlight.withLock { $0 += 1 }
        let inFlight = inFlight
        return {
            inFlight.withLock { $0 -= 1 }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}

/// A transparent Metal layer filling a view, drawn when marked.
@MainActor
final class NGMetalSurface {
    let layer = CAMetalLayer()
    var needsFrame = true
    private let pacer = NGFramePacer()

    init(device: MTLDevice) {
        layer.device = device
        layer.pixelFormat = NGMetalRenderer.pixelFormat
        layer.framebufferOnly = true
        layer.maximumDrawableCount = NGFramePacer.drawableCount
        layer.presentsWithTransaction = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = false
    }

    /// Covers `view` at `scale`; a new size or scale needs a frame.
    func layout(in view: NGPlatformView, scale: CGFloat) {
        guard let host = view.layer as CALayer? else { return }
        if layer.superlayer !== host { host.addSublayer(layer) }
        let bounds = view.bounds
        let drawableSize = CGSize(width: max(1, (bounds.width * scale).rounded(.up)), height: max(1, (bounds.height * scale).rounded(.up)))
        guard layer.frame != bounds || layer.contentsScale != scale || layer.drawableSize != drawableSize else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        layer.contentsScale = scale
        layer.drawableSize = drawableSize
        CATransaction.commit()
        needsFrame = true
    }

    /// Draws `quads` (in the view's points) if marked; waits for a later
    /// turn while the GPU has no drawable free.
    func drawIfNeeded(_ renderer: NGMetalRenderer, quads: () -> [NGMetalQuad]) {
        guard needsFrame, layer.superlayer != nil, pacer.canDraw, let drawable = layer.nextDrawable() else { return }
        needsFrame = false
        renderer.draw(quads(), into: drawable.texture, clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
                      present: drawable, presentsWithTransaction: true, completion: pacer.frameDidStart())
        NGMetalSurface.framesForTesting += 1
    }

    /// Frames drawn by all surfaces (for tests).
    static var framesForTesting = 0
}

extension NGTableView {
    /// The header or the summary row needs drawing again (their views were
    /// asked to redraw).
    func setNeedsChromeFrame(_ view: NGPlatformView) {
        if view === headerView {
            headerSurface?.needsFrame = true
        } else {
            summarySurface?.needsFrame = true
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// The header's or the summary's view changed size.
    func layoutChromeSurface(of view: NGPlatformView) {
        let surface = view === headerView ? headerSurface : summarySurface
        surface?.layout(in: view, scale: displayScale)
    }

    func drawChromeIfNeeded(renderer: NGMetalRenderer) {
        withLayoutDirectionFixed { drawChromeWithFixedDirection(renderer: renderer) }
    }

    private func drawChromeWithFixedDirection(renderer: NGMetalRenderer) {
        let scale = displayScale
        if !headerView.isHidden {
            headerSurface?.drawIfNeeded(renderer) {
                renderer.quadsSurvivingAtlasResets { headerQuads(renderer: renderer, scale: scale) }
            }
        }
        if !summaryBar.isHidden {
            summarySurface?.drawIfNeeded(renderer) {
                renderer.quadsSurvivingAtlasResets { summaryQuads(renderer: renderer, scale: scale) }
            }
        }
    }

    // MARK: Header

    /// Titles and separators, in the header view's points.
    func headerQuads(renderer: NGMetalRenderer, scale: CGFloat) -> [NGMetalQuad] {
        var quads: [NGMetalQuad] = []
        let style = metalStyle
        let viewport = viewport
        let bounds = headerView.bounds
        let separator = style.color(.separatorColor)
        let hairline = hairline
        for pin in drawingOrder {
            let region = geometry[pin]
            guard !region.isEmpty else { continue }
            let range = viewport.clipRange(of: pin, regionWidth: CGFloat(region.width))
            let clip = CGRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: bounds.height)
            guard clip.width > 0 else { continue }
            // Clipping keeps scrolled center titles out of the frozen parts.
            appendHeaderRegion(region, originX: viewport.origin(of: pin), clip: clip, top: 0, height: bounds.height,
                               renderer: renderer, scale: scale, style: style, to: &quads)
            if pin != .none {
                // The frozen region's edge toward the scrolling columns.
                let edgeX = (pin == .leading) != isRightToLeft ? clip.maxX - hairline : clip.minX
                quads.append(NGMetalRenderer.rectangle(CGRect(x: edgeX, y: 0, width: hairline, height: bounds.height),
                                                       scale: scale, color: separator))
            }
        }
        quads.append(NGMetalRenderer.rectangle(CGRect(x: 0, y: bounds.maxY - hairline, width: bounds.width, height: hairline),
                                               scale: scale, color: separator))
        return quads
    }

    /// Group titles sit in the top band; every column title sits in the leaf
    /// row below it (also ungrouped ones), so all column titles share one
    /// baseline. `top` is where the header starts (the drag snapshot draws it
    /// lower when a column inside a group is lifted without the band).
    func appendHeaderRegion(_ region: NGRegionGeometry, originX: CGFloat, clip: CGRect, top: CGFloat, height: CGFloat,
                            renderer: NGMetalRenderer, scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        let band = columnLayout.hasGroups ? groupHeaderHeight : 0
        let separatorInset: CGFloat = 7
        let hairline = hairline
        let separator = style.color(.separatorColor)
        let text = style.color(.headerTextColor)

        // Group titles, kept visible while the group is partially scrolled out.
        for group in region.groups {
            // A group slides and hides together with its columns. When only
            // columns inside it move, its title stays in place.
            if case .item(let draggedID) = columnDrag?.unit, draggedID == group.groupID { continue }
            let memberOffsets = columnSlideOffsets.isEmpty ? [] : Set(region.columns.lazy
                .filter { self.columnLayout.groupIDByColumnID[$0.column.id] == group.groupID }
                .map { self.slideOffset(forColumnID: $0.column.id) })
            let groupOffset = memberOffsets.count == 1 ? memberOffsets.first ?? 0 : 0
            let rect = CGRect(x: originX + CGFloat(group.x) + groupOffset, y: top, width: CGFloat(group.width), height: band)
            let visible = rect.intersection(clip)
            if visible.width > 2 * NGMetrics.cellPadding {
                appendHeaderText(group.title, in: visible.insetBy(dx: NGMetrics.cellPadding, dy: 0), alignment: .center,
                                 font: style.groupHeaderFont, color: text, clip: clip, renderer: renderer, scale: scale, to: &quads)
            }
            // Underline spanning the group's columns.
            quads.append(NGMetalRenderer.rectangle(CGRect(x: rect.minX + NGMetrics.cellPadding, y: rect.maxY - hairline,
                                                          width: rect.width - 2 * NGMetrics.cellPadding, height: hairline),
                                                   scale: scale, color: separator, clip: clip))
        }

        // Column titles, all in the leaf row. A dragged column leaves an empty slot.
        for frame in drawableColumns(of: region, originX: originX, visibleRect: clip) where !isHiddenForDrag(frame.column.id) {
            let column = frame.column
            let x = originX + CGFloat(frame.x) + slideOffset(forColumnID: column.id)
            let rect = CGRect(x: x, y: top + band, width: CGFloat(frame.width), height: height - band)
            guard rect.intersects(clip) else { continue }
            if selectedColumnIDs.contains(column.id) {
                quads.append(NGMetalRenderer.rectangle(rect, scale: scale, color: columnSelectionTint(style), clip: rect.intersection(clip)))
            }

            // Right to left, mirrored within the title's rect (the filter and the
            // sort arrow at its left).
            appendMirrored(in: rect, clip: clip, renderer: renderer, scale: scale, to: &quads) { quads in
                var textRect = rect.insetBy(dx: NGMetrics.cellPadding, dy: 0)
                if showsFilterButton(for: column, width: frame.width) {
                    // Drawn left to right, then mirrored with the title.
                    let button = filterButtonRect(inTitleRect: rect, mirrored: false)
                    appendFilterButton(isActive: columnFilters[column.id] != nil, in: button, clip: clip, renderer: renderer,
                                       scale: scale, style: style, to: &quads)
                    textRect.size.width -= button.width + 2
                }
                if let sort = sortPosition(ofColumn: column) {
                    let indicatorWidth: CGFloat = 12
                    // Secondary sorts show dimmed, so the first one stands out.
                    appendSortIndicator(ascending: sort.ascending, isPrimary: sort.index == 0,
                                        in: CGRect(x: textRect.maxX - indicatorWidth, y: rect.minY, width: indicatorWidth, height: rect.height),
                                        clip: clip, renderer: renderer, scale: scale, style: style, to: &quads)
                    textRect.size.width -= indicatorWidth + 2
                }
                appendHeaderText(column.title, in: textRect,
                                 alignment: column.headerAlignment.textAlignment(isNumeric: false, layoutDirection: contentLayoutDirection),
                                 font: style.headerFont, color: text, clip: clip, renderer: renderer, scale: scale, to: &quads)
            }

            // A divider after every column title, except the last one in the
            // region: there the region edge line or the table edge follows.
            // Ungrouped columns own the full header height, so their divider
            // spans it; grouped ones stay in the leaf row below the group title.
            // (Region columns are listed left to right: the last one shown is the leftmost right to left.)
            let lastColumn = isRightToLeft ? region.columns.first : region.columns.last
            guard column.showsHeaderDivider, frame.column.id != lastColumn?.column.id else { continue }
            let dividerX = isRightToLeft ? rect.minX : rect.maxX - hairline
            let isGrouped = columnLayout.groupIDByColumnID[column.id] != nil
            let dividerTop = (isGrouped ? band : 0) + separatorInset
            quads.append(NGMetalRenderer.rectangle(CGRect(x: dividerX, y: top + dividerTop,
                                                          width: hairline, height: height - separatorInset - dividerTop),
                                                   scale: scale, color: separator, clip: clip))
        }
    }

    /// One line centered vertically in `rect`, aligned and truncated to its width.
    private func appendHeaderText(_ text: String, in rect: CGRect, alignment: NSTextAlignment, font: NGFont, color: SIMD4<Float>,
                                  clip: CGRect, renderer: NGMetalRenderer, scale: CGFloat, to quads: inout [NGMetalQuad]) {
        let lineTop = rect.midY - Self.lineHeight(of: font) / 2
        renderer.appendLine(text, font: font, alignment: alignment, in: rect, baseline: lineTop + font.ascender, scale: scale,
                            color: color, clip: clip, to: &quads)
    }

    private static var lineHeights: [NGFont: CGFloat] = [:]

    /// A font's single-line text height, as AppKit lays a line out (measured
    /// once per font).
    private static func lineHeight(of font: NGFont) -> CGFloat {
        if let height = lineHeights[font] { return height }
        let height = ceil(NSAttributedString(string: "Xg", attributes: [.font: font]).size().height)
        lineHeights[font] = height
        return height
    }

    private func appendSortIndicator(ascending: Bool, isPrimary: Bool, in rect: CGRect, clip: CGRect, renderer: NGMetalRenderer,
                                     scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        guard let image = Self.sortIndicatorImage(ascending: ascending) else { return }
        let size = image.size
        guard let entry = renderer.atlas.icon(ascending ? "sort.up" : "sort.down", size: size, scale: scale, draw: { context in
            image.draw(into: context, in: CGRect(origin: .zero, size: size))
        }) else { return }
        let color = style.color(isPrimary ? .secondaryLabelColor : .tertiaryLabelColor)
        renderer.appendIcon(entry, at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), clip: clip,
                            scale: scale, color: color, to: &quads)
    }

    /// The filter button: a funnel, in the accent color while the column has
    /// a filter (atlas icons take one color, so a filled symbol would lose
    /// its lines).
    private func appendFilterButton(isActive: Bool, in rect: CGRect, clip: CGRect, renderer: NGMetalRenderer,
                                    scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        let name = "line.3.horizontal.decrease.circle"
        guard let image = Self.symbolImage(name) else { return }
        let size = image.size
        guard let entry = renderer.atlas.icon(name, size: size, scale: scale, draw: { context in
            image.draw(into: context, in: CGRect(origin: .zero, size: size))
        }) else { return }
        let color = style.color(isActive ? .controlAccentColor : .tertiaryLabelColor)
        renderer.appendIcon(entry, at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), clip: clip,
                            scale: scale, color: color, to: &quads)
    }

    /// White symbols for the header, made once (tinted when drawn).
    private static func symbolImage(_ name: String) -> NGSymbolImage? {
        NGSymbolImage.named(name, pointSize: 11, weight: .regular)
    }

    /// White chevrons, made once (tinted when drawn).
    private static func sortIndicatorImage(ascending: Bool) -> NGSymbolImage? {
        NGSymbolImage.named(ascending ? "chevron.up" : "chevron.down", pointSize: 9, weight: .semibold)
    }

    // MARK: Summary

    /// The summary values, in the summary content view's points.
    func summaryQuads(renderer: NGMetalRenderer, scale: CGFloat) -> [NGMetalQuad] {
        var quads: [NGMetalQuad] = []
        let style = metalStyle
        let viewport = viewport
        let bounds = summaryBar.contentView.bounds
        for pin in drawingOrder {
            let region = geometry[pin]
            guard !region.isEmpty else { continue }
            let range = viewport.clipRange(of: pin, regionWidth: CGFloat(region.width))
            let clip = CGRect(x: range.lowerBound, y: bounds.minY, width: range.upperBound - range.lowerBound, height: bounds.height)
            guard clip.width > 0 else { continue }
            let originX = viewport.origin(of: pin)
            for frame in drawableColumns(of: region, originX: originX, visibleRect: clip) where !isHiddenForDrag(frame.column.id) {
                let x = originX + CGFloat(frame.x) + slideOffset(forColumnID: frame.column.id)
                let rect = CGRect(x: x, y: bounds.minY, width: CGFloat(frame.width), height: bounds.height)
                appendSummaryText(for: frame.column, in: rect, clip: clip, renderer: renderer, scale: scale, style: style, to: &quads)
            }
        }
        return quads
    }

    func appendSummaryText(for column: NGTableColumn, in columnRect: CGRect, clip: CGRect, renderer: NGMetalRenderer,
                           scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        guard let text = summaryTexts[column.id], columnRect.intersects(clip) else { return }
        // Values being recomputed dim; values that depend on the selection are
        // highlighted so the user notices the scope.
        let color: NGColor = isSummaryProgressVisible && showsSummaryProgress ? .tertiaryLabelColor
            : summaryScope == .allRows ? .labelColor : accentColorForTesting ?? .controlAccentColor
        appendHeaderText(text, in: columnRect.insetBy(dx: NGMetrics.cellPadding, dy: 0),
                         alignment: column.alignment.textAlignment(isNumeric: true, layoutDirection: layoutDirection),
                         font: style.boldDigitFont, color: style.color(color), clip: clip, renderer: renderer, scale: scale, to: &quads)
    }
}
#endif
