#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Metal
import QuartzCore

// The table's rows and cells are drawn by the GPU. The layout pass keeps a
// frame model (NGCellModel.swift): what is where (visible rows and cells,
// their frames, colors, corners, markers, contents, highlight). Before Core
// Animation commits, a frame is built from it (one quad per rectangle and
// glyph) and drawn into one CAMetalLayer under the regions, presented with
// the transaction so the rows never lag the header or the scrollers.

extension NGTableView {
    /// Makes the Metal layer and the run loop observer that draws frames.
    func setUpMetalRenderer() {
        // One renderer (shaders, glyph atlas) for every table of the app.
        guard let renderer = NGMetalRenderer.shared else { return }
        metalRenderer = renderer
        // No `wantsLayer` of our own: it would flip the coordinates the views
        // draw in. In a window the table has a layer anyway; the Metal layer
        // joins it at the next layout.
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = NGMetalRenderer.pixelFormat
        layer.framebufferOnly = true
        layer.maximumDrawableCount = NGFramePacer.drawableCount
        layer.presentsWithTransaction = true
        // The renderer's colors are sRGB.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true
        // Below the regions (transparent) and everything over them.
        layer.zPosition = -1000
        metalLayer = layer
        headerSurface = NGMetalSurface(device: renderer.device)
        summarySurface = NGMetalSurface(device: renderer.device)
        installMetalObserver()
    }

    /// The Metal layer covers the table, at the screen's pixel density.
    /// - Returns: Whether its size or scale changed.
    @discardableResult
    func layoutMetalLayer() -> Bool {
        guard let metalLayer else { return false }
        if metalLayer.superlayer !== layer, let layer = layer as CALayer? { layer.addSublayer(metalLayer) }
        let scale = displayScale
        // Whole pixels, rounded up like the chrome's: a fractional size would
        // be cut. The layer is as large as its pixels (past the bounds by
        // less than one, which the table clips), so nothing is stretched.
        let drawableSize = CGSize(width: max(1, (bounds.width * scale).rounded(.up)), height: max(1, (bounds.height * scale).rounded(.up)))
        let size = CGSize(width: drawableSize.width / scale, height: drawableSize.height / scale)
        // Its top at the view's (the layer's y grows upward unless flipped).
        let y = (layer as CALayer?)?.isGeometryFlipped == true ? bounds.minY : bounds.maxY - size.height
        let frame = CGRect(origin: CGPoint(x: bounds.minX, y: y), size: size)
        // Every layout pass comes here: only a new size or scale needs a frame.
        guard metalLayer.frame != frame || metalLayer.contentsScale != scale || metalLayer.drawableSize != drawableSize else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = frame
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = drawableSize
        CATransaction.commit()
        setNeedsMetalFrame()
        return true
    }

    /// The next Core Animation commit shows a new frame.
    func setNeedsMetalFrame() {
        guard metalLayer != nil else { return }
        needsMetalFrame = true
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    // MARK: Run loop

    /// Draws before Core Animation commits (its observer has order 2,000,000),
    /// so the frame joins the same transaction as the layer changes.
    private func installMetalObserver() {
        guard metalObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                          true, 1_999_000) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.checkBatchAcrossRunLoopTurn()
                self?.drawMetalFrameIfNeeded()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        metalObserver = observer
    }

    // MARK: Frames

    /// Whether the window can't be seen: minimized, covered by other windows,
    /// a tab not selected, not ordered in, or the app hidden.
    var isWindowUnseen: Bool {
        guard let window, !drawsWhileUnseenForTesting else { return false }
        #if os(macOS)
        if window.isMiniaturized || NSApp.isHidden || !window.isVisible { return true }
        if let group = window.tabGroup, group.windows.count > 1, group.selectedWindow !== window { return true }
        return !window.occlusionState.contains(.visible)
        #else
        return !window.isVisible
        #endif
    }

    /// Number of frames drawn (for tests).
    static var metalFramesForTesting = 0

    func drawMetalFrameIfNeeded() {
        // A hidden table (a collapsed pane, a tab not shown) draws when it
        // shows again, so does one in a window that can't be seen.
        guard let renderer = metalRenderer, window != nil, !isHiddenOrHasHiddenAncestor, !isWindowUnseen else { return }
        drawRowsIfNeeded(renderer: renderer)
        drawChromeIfNeeded(renderer: renderer)
    }

    /// What tells `frameRendered` a frame's GPU time, if anything listens.
    private func gpuTimeHandler() -> (@Sendable (CFTimeInterval) -> Void)? {
        guard frameRendered != nil else { return nil }
        return { [weak self] seconds in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.frameRendered?(seconds) } }
        }
    }

    private func drawRowsIfNeeded(renderer: NGMetalRenderer) {
        guard needsMetalFrame, let metalLayer, bounds.width > 0, bounds.height > 0 else { return }
        // No drawable free (the GPU is behind): the frame waits for a later turn,
        // instead of `nextDrawable()` waiting on the main thread.
        guard metalPacer.canDraw, let drawable = metalLayer.nextDrawable() else { return }
        needsMetalFrame = false
        var quads = buildMetalQuads(renderer: renderer, scale: metalLayer.contentsScale)
        var base = SIMD4<Float>(1, 1, 1, 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            base = NGMetalRenderer.premultiplied(metalStyle.background.cgColor)
        }
        // A clear or translucent background shows what's behind the table.
        let isOpaque = base.w >= 0.999
        if metalLayer.isOpaque != isOpaque { metalLayer.isOpaque = isOpaque }
        if framePresented != nil {
            let drawnAt = CACurrentMediaTime()
            drawable.addPresentedHandler { [weak self] drawable in
                let presentedAt = drawable.presentedTime
                // (0: the frame was dropped, never shown.)
                guard presentedAt > 0 else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.framePresented?(drawnAt, presentedAt) } }
            }
        }
        renderer.draw(quads, textures: metalTextures, into: drawable.texture,
                      clearColor: MTLClearColor(red: Double(base.x), green: Double(base.y), blue: Double(base.z),
                                                alpha: isOpaque ? 1 : Double(base.w)),
                      present: drawable, presentsWithTransaction: true, keepingAlive: mediaPlayer?.textureOwner.map { [$0] } ?? [],
                      completion: metalPacer.frameDidStart(), gpuTime: gpuTimeHandler())
        quads.removeAll()
        Self.metalFramesForTesting += 1
    }

    /// The table as Metal draws it, offscreen, for checking it without a
    /// screenshot: the rows, and the header and the summary row over them on
    /// an opaque base (their materials are system views).
    func metalSnapshot() -> CGImage? {
        guard let renderer = metalRenderer, let metalLayer else { return nil }
        let scale = metalLayer.contentsScale
        let style = metalStyle
        var base = SIMD4<Float>(1, 1, 1, 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            base = NGMetalRenderer.premultiplied(metalStyle.background.cgColor)
        }
        // One frame of three parts: an atlas started over by a later part
        // invalidates the glyphs of the earlier ones too.
        let quads = renderer.quadsSurvivingAtlasResets {
            var quads = buildMetalQuads(renderer: renderer, scale: scale)
            let chrome: [(view: NGPlatformView, quads: [NGMetalQuad])] = [
                (headerView, headerQuads(renderer: renderer, scale: scale)),
                (summaryBar.contentView, summaryQuads(renderer: renderer, scale: scale)),
            ]
            for (view, viewQuads) in chrome where !view.isHiddenOrHasHiddenAncestor {
                let frame = view.convert(view.bounds, to: self)
                quads.append(NGMetalRenderer.rectangle(frame, scale: scale, color: style.color(.windowBackgroundColor)))
                let offset = SIMD2<Float>(Float(frame.minX * scale), Float(frame.minY * scale))
                quads += viewQuads.map { quad in
                    var quad = quad
                    quad.rect.x += offset.x
                    quad.rect.y += offset.y
                    // The clip is min x, min y, max x, max y.
                    quad.clip += SIMD4(offset.x, offset.y, offset.x, offset.y)
                    return quad
                }
            }
            return quads
        }
        return offscreenImage(of: quads, size: bounds.size, scale: scale,
                              clearColor: MTLClearColor(red: Double(base.x), green: Double(base.y), blue: Double(base.z), alpha: 1))
    }

    /// Default cells on a transparent background, for images such as the
    /// column drag snapshot. The frames are in the image's points.
    func metalImage(of cells: [(cell: NGDrawnCell, frame: CGRect)], size: CGSize, scale: CGFloat) -> CGImage? {
        guard let renderer = metalRenderer else { return nil }
        let style = metalStyle
        let bounds = CGRect(origin: .zero, size: size)
        let quads = renderer.quadsSurvivingAtlasResets {
            metalTextures.removeAll(keepingCapacity: true)
            var quads: [NGMetalQuad] = []
            for (cell, frame) in cells where !cell.isEmpty {
                let clip = frame.intersection(bounds)
                guard !clip.isEmpty else { continue }
                appendContent(of: cell, in: frame, clip: clip, renderer: renderer, scale: scale, style: style, to: &quads)
            }
            return quads
        }
        return offscreenImage(of: quads, size: size, scale: scale, clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
    }

    /// Draws quads into a texture of their own and waits for the GPU.
    func offscreenImage(of quads: [NGMetalQuad], size: CGSize, scale: CGFloat, clearColor: MTLClearColor) -> CGImage? {
        guard let renderer = metalRenderer else { return nil }
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: NGMetalRenderer.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { return nil }
        let done = DispatchSemaphore(value: 0)
        let signal = NGUncheckedSendable(done)
        renderer.draw(quads, textures: metalTextures, into: texture, clearColor: clearColor) { signal.value.signal() }
        done.wait()
        guard let context = NGCellDrawing.makeBitmapContext(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let data = context.data else { return nil }
        texture.getBytes(data, bytesPerRow: context.bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return context.makeImage()
    }

    /// The quads of the visible rows and cells, region by region (rows, then
    /// their cells), in the table's coordinates.
    func buildMetalQuads(renderer: NGMetalRenderer, scale: CGFloat) -> [NGMetalQuad] {
        withLayoutDirectionFixed {
            renderer.quadsSurvivingAtlasResets { buildMetalQuadsOnce(renderer: renderer, scale: scale) }
        }
    }

    private func buildMetalQuadsOnce(renderer: NGMetalRenderer, scale: CGFloat) -> [NGMetalQuad] {
        metalTextures.removeAll(keepingCapacity: true)
        drawsIndeterminateProgress = false
        defer { syncProgressAnimation() }
        formatVisibleNumbers()
        // Text that came into view is laid out together, on all cores; the
        // cells that waited for it are added after that.
        renderer.shaper.beginCollectingMisses()
        let style = metalStyle
        var waiting: [WaitingCell] = []
        let quads = buildQuads(renderer: renderer, scale: scale, style: style, waiting: &waiting)
        guard !waiting.isEmpty else {
            // Collecting always ends here: the header and summary, drawn
            // next, would otherwise only note their text, never draw it.
            if renderer.shaper.layOutCollectedMisses() { setNeedsMetalFrame() }
            return quads
        }
        guard renderer.shaper.layOutCollectedMisses() else {
            // Not laid out this time: drawn complete in the next frame.
            setNeedsMetalFrame()
            return quads
        }
        // Each waiting cell goes where it would have been drawn (under what
        // came after it: floating headers, the focus ring, the drop indicator),
        // in one pass.
        var result: [NGMetalQuad] = []
        result.reserveCapacity(quads.count + waiting.count * 8)
        var copied = 0
        for cell in waiting {
            result.append(contentsOf: quads[copied..<cell.position])
            copied = cell.position
            cell.draw(&result)
        }
        result.append(contentsOf: quads[copied...])
        return result
    }

    /// A cell whose text wasn't laid out when the frame was built: where its
    /// quads go, and how to draw it (with everything it had: a conditional
    /// format, a fade) once the text is.
    struct WaitingCell {
        let position: Int
        let draw: (inout [NGMetalQuad]) -> Void
    }

    /// Formats the numbers of cells that came into view, on all cores when
    /// there are many (a flick through a wide table).
    private func formatVisibleNumbers() {
        var cells: [NGDrawnCell] = []
        var numbers: [NGFormattedNumber] = []
        for cell in visibleCells.values where cell.displayedText == nil && !cell.isHidden {
            if case .number(let number, _) = cell.content {
                cells.append(cell)
                numbers.append(number)
            }
        }
        guard numbers.count >= 32 else { return }   // Fewer are formatted while drawn.
        let input = numbers
        // Styles made once on the main actor; every core formats with copies.
        var styles: [NGNumberStyle] = []
        styles.reserveCapacity(input.count)
        for number in input { styles.append(NGFormatIDs.numberStyle(id: number.formatID, format: number.format)) }
        let numberStyles = styles
        var texts = [String](repeating: "", count: input.count)
        texts.withUnsafeMutableBufferPointer { buffer in
            let output = NGUncheckedSendable(buffer)
            let chunks = min(input.count / 16, ProcessInfo.processInfo.activeProcessorCount * 2)
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                for index in stride(from: chunk, to: input.count, by: chunks) {
                    output.value[index] = numberStyles[index].string(for: input[index].value)
                }
            }
        }
        for (cell, text) in zip(cells, texts) {
            cell.displayedText = text
        }
    }

    /// - Parameter waiting: Cells with text that isn't laid out yet; they get
    ///   no quads until it is.
    private func buildQuads(renderer: NGMetalRenderer, scale: CGFloat, style: MetalStyle,
                            waiting: inout [WaitingCell]) -> [NGMetalQuad] {
        var quads: [NGMetalQuad] = []
        quads.reserveCapacity(visibleCells.count * 8)
        // Rows and cells by region, in one pass over each (not one per region).
        // With a row animation running, rows are drawn offset and faded by
        // display row, and gone rows' cells fade out (see NGRowAnimation.swift).
        let animating = rowAnimation != nil
        // Rows drawn away from their place: an animation, a drop's gap.
        let shifting = animating || dropGap != nil
        var rowsByRegion: [NGColumnPin: [(row: NGRowBackground, displayRow: Int)]] = [:]
        for (key, row) in visibleRowEntries where !row.isHidden {
            rowsByRegion[key.pin, default: []].append((row, key.row))
        }
        var cellsByRegion: [NGColumnPin: [(cell: NGDrawnCell, displayRow: Int, opacity: Float, ordinal: Int)]] = [:]
        for (key, cell) in visibleCells where !cell.isHidden && !cell.isEmpty {
            guard let pin = cell.regionPin else { continue }
            cellsByRegion[pin, default: []].append((cell, key.row, animating ? rowAnimationOpacity(ofDisplayRow: key.row) : 1, key.column))
        }
        if let disappearing = rowAnimation?.disappearing {
            let opacity = Float(1 - rowAnimationProgress)
            for cell in disappearing where !cell.isEmpty {
                guard let pin = cell.regionPin else { continue }
                cellsByRegion[pin, default: []].append((cell, -1, opacity, -1))
            }
        }
        let flashes = changeHighlightQuads(style: style)
        let conditionalFormats = resolvedConditionalFormats()
        // Floating group headers are drawn last, over the rows they cover.
        let floating = floatingGroupHeaders()
        let floatingRows = Set(floating.map(\.row))
        for region in regions where !region.isHidden {
            let origin = CGPoint(x: region.frame.minX + region.canvas.frame.minX, y: region.frame.minY + region.canvas.frame.minY)
            let clip = region.frame.intersection(bounds)
            guard !clip.isEmpty else { continue }
            let swiped = swipedDisplayRow
            for (row, displayRow) in rowsByRegion[region.pin] ?? [] where !floatingRows.contains(displayRow) {
                let start = quads.count
                let shift = shifting ? rowDrawShift(ofDisplayRow: displayRow) : .zero
                let slide = displayRow == swiped ? swipeOffset(ofDisplayRow: displayRow) : 0
                appendRow(row, origin: CGPoint(x: origin.x + slide + shift.x, y: origin.y + shift.y), clip: clip, scale: scale, style: style,
                          to: &quads)
                if animating { Self.fade(&quads, from: start, opacity: rowAnimationOpacity(ofDisplayRow: displayRow)) }
            }
            appendHorizontalGridLines(rowsByRegion[region.pin] ?? [], origin: origin, clip: clip, scale: scale, style: style, to: &quads)
            appendVerticalGridLines(in: region, origin: origin, clip: clip, scale: scale, style: style, to: &quads)
            // A range of cells, tinted under their content (navigation by cell).
            appendCellRangeTint(style: style, scale: scale, in: region, origin: origin, clip: clip, to: &quads)
            appendColumnSelectionTint(style: style, scale: scale, in: region, origin: origin, clip: clip, to: &quads)
            // Changed values' flashes, over the rows and under the cells' content.
            for flash in flashes[region.pin] ?? [] {
                let frame = flash.frame.offsetBy(dx: origin.x, dy: origin.y)
                quads.append(NGMetalRenderer.rectangle(frame, scale: scale, color: flash.color, clip: frame.intersection(clip)))
            }
            for (cell, displayRow, opacity, ordinal) in cellsByRegion[region.pin] ?? [] where !floatingRows.contains(displayRow) {
                // Gone rows' cells (-1) slide out the way the animation says.
                let shift = !shifting ? .zero : displayRow >= 0 ? rowDrawShift(ofDisplayRow: displayRow) : disappearingShift()
                let slide = displayRow == swiped ? swipeOffset(ofDisplayRow: displayRow) : 0
                let frame = cell.cellFrame.offsetBy(dx: origin.x + slide + shift.x, dy: origin.y + shift.y)
                let cellClip = frame.intersection(clip)
                guard !cellClip.isEmpty, opacity > 0 else { continue }
                let format = conditionalFormats.isEmpty ? nil : conditionalFormats[ordinal]
                let draw = { [self] (quads: inout [NGMetalQuad]) in
                    let start = quads.count
                    // A conditional format: bars or a background under the text, or the text's color.
                    var textColor: SIMD4<Float>?
                    if let format, case .number(let number, _) = cell.content {
                        // Bars grow from the leading edge: mirrored right to left.
                        appendMirrored(in: frame, clip: cellClip, renderer: renderer, scale: scale, to: &quads) { quads in
                            textColor = appendConditionalFormat(format, value: number.value, in: frame, clip: cellClip, scale: scale,
                                                                style: style, to: &quads)
                        }
                    }
                    appendContent(of: cell, in: frame, clip: cellClip, renderer: renderer, scale: scale, style: style,
                                  textColor: cell.isHighlighted ? nil : textColor, to: &quads)
                    if opacity < 1 { Self.fade(&quads, from: start, opacity: opacity) }
                }
                appendWaitingIfMissing(draw, renderer: renderer, to: &quads, waiting: &waiting)
            }
        }
        // Floating group headers over the rows, each on an opaque base, below the header.
        if !floating.isEmpty {
            // (On a clear background, the window's: rows mustn't show through.)
            let background = style.color(style.background)
            let base = background.w >= 0.999 ? background : style.color(.windowBackgroundColor)
            let rowsTop = layoutMetrics.headerHeight
            for region in regions where !region.isHidden {
                let origin = CGPoint(x: region.frame.minX + region.canvas.frame.minX, y: region.frame.minY + region.canvas.frame.minY)
                var clip = region.frame.intersection(bounds)
                clip = clip.intersection(CGRect(x: clip.minX, y: rowsTop, width: clip.width, height: max(0, clip.maxY - rowsTop)))
                guard !clip.isEmpty else { continue }
                for (displayRow, y) in floating {
                    let dy = y - rowGeometry.top(of: displayRow)
                    let band = CGRect(x: clip.minX, y: origin.y + y, width: clip.width, height: rowGeometry.height(of: displayRow))
                    quads.append(NGMetalRenderer.rectangle(band, scale: scale, color: SIMD4(base.x, base.y, base.z, 1), clip: clip))
                    for (row, rowIndex) in rowsByRegion[region.pin] ?? [] where rowIndex == displayRow {
                        appendRow(row, origin: CGPoint(x: origin.x, y: origin.y + dy), clip: clip, scale: scale, style: style, to: &quads)
                    }
                    for (cell, rowIndex, _, _) in cellsByRegion[region.pin] ?? [] where rowIndex == displayRow {
                        let frame = cell.cellFrame.offsetBy(dx: origin.x, dy: origin.y + dy)
                        let cellClip = frame.intersection(clip)
                        guard !cellClip.isEmpty else { continue }
                        appendWaitingIfMissing({ [self] quads in
                            appendContent(of: cell, in: frame, clip: cellClip, renderer: renderer, scale: scale, style: style, to: &quads)
                        }, renderer: renderer, to: &quads, waiting: &waiting)
                    }
                }
            }
        }
        // The focused cell's ring, over everything (navigation by cell).
        appendFocusRing(style: style, scale: scale, to: &quads)
        // Where a drop would go.
        appendDropIndicator(style: style, scale: scale, to: &quads)
        return quads
    }

    /// Draws a cell, or, if its text isn't laid out yet (a tag's capsule
    /// needs its title's width), notes where and how to draw it once it is.
    private func appendWaitingIfMissing(_ draw: @escaping (inout [NGMetalQuad]) -> Void, renderer: NGMetalRenderer,
                                        to quads: inout [NGMetalQuad], waiting: inout [WaitingCell]) {
        let start = quads.count, misses = renderer.shaper.missCount
        draw(&quads)
        guard renderer.shaper.missCount != misses else { return }
        quads.removeSubrange(start...)
        waiting.append(WaitingCell(position: start, draw: draw))
    }

    /// Quads from `start` on drawn at an opacity (colors are premultiplied).
    private static func fade(_ quads: inout [NGMetalQuad], from start: Int, opacity: Float) {
        guard opacity < 1 else { return }
        for index in start..<quads.count {
            quads[index].color *= opacity
        }
    }

    private func appendRow(_ row: NGRowBackground, origin: CGPoint, clip: CGRect, scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        let frame = row.frame.offsetBy(dx: origin.x, dy: origin.y)
        if let color = row.color {
            let fill = style.color(color)
            if fill.w > 0 {
                quads.append(NGMetalRenderer.roundedRectangle(frame, radius: row.cornerRadius, corners: row.maskedCorners,
                                                              scale: scale, color: fill, clip: clip))
            }
        }
        // The marker: the row's shape, clipped to its leading edge.
        if let marker = row.markerColor {
            let markerX = isRightToLeft ? frame.maxX - NGMetrics.markerWidth : frame.minX
            let edge = CGRect(x: markerX, y: frame.minY, width: NGMetrics.markerWidth, height: frame.height).intersection(clip)
            quads.append(NGMetalRenderer.roundedRectangle(frame, radius: row.cornerRadius, corners: row.maskedCorners,
                                                          scale: scale, color: style.color(marker), clip: edge))
        }
    }

    private func appendContent(of cell: NGDrawnCell, in frame: CGRect, clip: CGRect, renderer: NGMetalRenderer, scale: CGFloat,
                               style: MetalStyle, textColor colorOverride: SIMD4<Float>? = nil, to quads: inout [NGMetalQuad]) {
        // Right to left, mirrored within the cell.
        appendMirrored(in: frame, clip: clip, renderer: renderer, scale: scale, to: &quads) { quads in
            appendContentLeftToRight(of: cell, in: frame, clip: clip, renderer: renderer, scale: scale, style: style,
                                     textColor: colorOverride, to: &quads)
        }
    }

    /// Text wrapped onto at most `lineLimit` lines, one under another: the
    /// first where a one-line row puts its text (see `wrappedTextHeight`).
    private func appendWrappedText(_ text: String, font: NGFont, alignment: NSTextAlignment, lineLimit: Int, in frame: CGRect,
                                   clip: CGRect, renderer: NGMetalRenderer, scale: CGFloat, color: SIMD4<Float>,
                                   to quads: inout [NGMetalQuad]) {
        guard !text.isEmpty else { return }
        let available = max(0, frame.width - 2 * NGMetrics.cellPadding)
        let lines = renderer.shaper.shapeLines(text, font: font, width: available, maximumLines: lineLimit)
        let lineHeight = NGLineHeights.height(of: font)
        var top = frame.minY + ((min(frame.height, rowHeight) - lineHeight) / 2).rounded()
        let textClip = clip.intersection(frame)
        for line in lines {
            let x: CGFloat = switch alignment {
            case .right: NGMetrics.cellPadding + available - line.width
            case .center: NGMetrics.cellPadding + ((available - line.width) / 2)
            default: NGMetrics.cellPadding
            }
            renderer.appendGlyphs(line, font: font, x: frame.minX + x, baseline: top + CTFontGetAscent(font), clip: textClip,
                                  scale: scale, color: color, to: &quads)
            top += lineHeight
        }
    }

    private func appendContentLeftToRight(of cell: NGDrawnCell, in frame: CGRect, clip: CGRect, renderer: NGMetalRenderer,
                                          scale: CGFloat, style: MetalStyle, textColor colorOverride: SIMD4<Float>? = nil,
                                          to quads: inout [NGMetalQuad]) {
        let highlighted = cell.isHighlighted
        var frame = frame
        // Spacing between cells beyond the table's own (`intercellSpacing`).
        if cellSpacing.width > 0 {
            frame = frame.insetBy(dx: cellSpacing.width / 2, dy: 0)
        }
        if let outline = cell.outline {
            // A tree's outline column: indented by depth, with a triangle for rows with children.
            if outline.hasChildren {
                let size = CGSize(width: NGMetrics.disclosureWidth, height: NGMetrics.disclosureWidth)
                let x = frame.minX + NGMetrics.cellPadding + CGFloat(outline.level) * NGMetrics.groupIndent
                let y = frame.minY + ((frame.height - NGMetrics.disclosureWidth) / 2).rounded()
                // (Drawn left to right and mirrored with the cell: right to left a
                // collapsed row's chevron is drawn pointing left, so it ends up so.)
                let pointsLeft = isRightToLeft && !outline.isExpanded
                if let entry = renderer.atlas.icon(outline.isExpanded ? "chevron.down" : pointsLeft ? "chevron.left" : "chevron.right",
                                                   size: size, scale: scale, draw: { context in
                    if pointsLeft { context.translateBy(x: size.width, y: 0); context.scaleBy(x: -1, y: 1) }
                    NGCellDrawing.drawChevron(in: CGRect(origin: .zero, size: size), expanded: outline.isExpanded,
                                              color: CGColor(gray: 1, alpha: 1), context: context)
                }) {
                    renderer.appendIcon(entry, at: CGPoint(x: x, y: y), clip: clip, scale: scale,
                                        color: highlighted ? style.highlightedText : style.secondaryText, to: &quads)
                }
            }
            let inset = Self.outlineContentInset(outline)
            frame = CGRect(x: frame.minX + inset, y: frame.minY, width: max(0, frame.width - inset), height: frame.height)
        }
        if cell.showsChoiceChevron {
            // The pop-up's chevron at the trailing edge; the content keeps clear of it.
            let room = appendChoiceChevron(in: frame, clip: clip, highlighted: highlighted, renderer: renderer, scale: scale,
                                           style: style, to: &quads)
            frame.size.width = max(0, frame.width - room)
        }
        // Rows grown for wrapped text: other cells keep to the top, a
        // one-line row's height, level with the first line.
        if wrapsTextInSomeColumn, cell.lineLimit <= 1, frame.height > rowHeight {
            frame.size.height = rowHeight
        }
        let textColor = colorOverride ?? (highlighted ? style.highlightedText : style.text)
        // Text: the quads drawn last time when nothing they depend on changed.
        let font: NGFont? = switch cell.content {
        case .text(_, _, let monospacedDigits): monospacedDigits ? style.digitFont : style.textFont
        case .number: style.digitFont
        case .subtotal: style.boldDigitFont
        default: nil
        }
        var cacheKey: NGQuadKey?
        if let font, cell.outline == nil {
            let key = NGQuadKey(frame: frame, clip: clip, scale: scale, color: textColor, font: ObjectIdentifier(font),
                                atlas: ObjectIdentifier(renderer.atlas), atlasResets: renderer.atlas.resetCount)
            if let cache = cell.quadCache, cache.key == key {
                quads.append(contentsOf: cache.quads)
                return
            }
            cacheKey = key
        }
        let start = quads.count, misses = renderer.shaper.missCount
        defer {
            // Kept unless glyphs were missing (the cell is drawn again once they're in).
            if let cacheKey, renderer.shaper.missCount == misses, start <= quads.count {
                cell.quadCache = (cacheKey, Array(quads[start...]))
            }
        }
        switch cell.content {
        case .text(let text, let alignment, let monospacedDigits) where cell.lineLimit > 1:
            appendWrappedText(text, font: monospacedDigits ? style.digitFont : style.textFont, alignment: alignment,
                              lineLimit: cell.lineLimit, in: frame, clip: clip, renderer: renderer, scale: scale, color: textColor,
                              to: &quads)
        case .text(let text, let alignment, let monospacedDigits):
            renderer.appendText(text, font: monospacedDigits ? style.digitFont : style.textFont, alignment: alignment,
                                in: frame, scale: scale, color: textColor, clip: clip, laidOut: &cell.laidOutText, to: &quads)
        case .number(let number, let alignment):
            // Formatted once per value shown, not on every frame.
            let text = cell.displayedText ?? number.text
            cell.displayedText = text
            renderer.appendText(text, font: style.digitFont, alignment: alignment, in: frame, scale: scale, color: textColor,
                                clip: clip, laidOut: &cell.laidOutText, to: &quads)
        case .subtotal(let text, let alignment):
            renderer.appendText(text, font: style.boldDigitFont, alignment: alignment, in: frame, scale: scale, color: textColor,
                                clip: clip, laidOut: &cell.laidOutText, to: &quads)
        case .tags(let tags):
            appendTags(tags, in: frame, clip: clip, highlighted: highlighted, renderer: renderer, scale: scale, style: style, to: &quads)
        case .mark(let mark, let alignment):
            appendMark(mark, alignment: alignment, in: frame, clip: clip, highlighted: highlighted, renderer: renderer,
                       scale: scale, style: style, to: &quads)
        case .groupTitle(let title):
            appendGroupTitle(title, in: frame, clip: clip, renderer: renderer, scale: scale, style: style, to: &quads)
        case .media(let media):
            appendMedia(media, of: cell, in: frame, clip: clip, highlighted: highlighted, renderer: renderer, scale: scale,
                        style: style, to: &quads)
        case .sparkline(let sparkline):
            appendSparkline(sparkline, in: frame, clip: clip, highlighted: highlighted, scale: scale, style: style, to: &quads)
        case .rating(let value, let maximum, let isEditable, let alignment):
            // Under the pointer, an editable rating shows the value a click would set.
            let shown = isEditable && cell.isPointerOver ? (cell.previewRating ?? value) : value
            appendRating(shown, maximum: maximum, isPreview: shown != value, alignment: alignment, in: frame, clip: clip,
                         highlighted: highlighted, renderer: renderer, scale: scale, style: style, to: &quads)
        case .progress(let fraction, let text, let reserved):
            appendProgress(fraction: fraction, text: text, reserved: reserved, in: frame, clip: clip, highlighted: highlighted,
                           renderer: renderer, scale: scale, style: style, to: &quads)
        case .button(let button, let alignment):
            appendButton(button, alignment: alignment, pressed: cell.isPressed, in: frame, clip: clip, renderer: renderer,
                         scale: scale, style: style, to: &quads)
        case .link(let link, let alignment):
            // The link color (pressed: darker), underlined under the pointer.
            let color = highlighted ? style.highlightedText
                : style.color(cell.isPressed ? NGTableView.pressedLinkColor : .linkColor)
            renderer.appendText(link.title, font: style.textFont, alignment: alignment, in: frame, scale: scale, color: color,
                                clip: clip, laidOut: &cell.laidOutText, to: &quads)
            if cell.isPointerOver || cell.isPressed, let underline = Self.linkUnderline(in: frame, alignment: alignment,
                                                                                       text: cell.laidOutText, font: style.textFont, scale: scale) {
                quads.append(NGMetalRenderer.rectangle(underline, scale: scale, color: color, clip: clip))
            }
        }
    }

    /// The up-down chevron of a pop-up button at a cell's trailing edge; the width it takes.
    private func appendChoiceChevron(in frame: CGRect, clip: CGRect, highlighted: Bool, renderer: NGMetalRenderer, scale: CGFloat,
                                     style: MetalStyle, to quads: inout [NGMetalQuad]) -> CGFloat {
        guard let image = Self.choiceChevronImage else { return 0 }
        let size = image.size
        guard let entry = renderer.atlas.icon("choice-chevron", size: size, scale: scale, draw: { context in
            image.draw(into: context, in: CGRect(origin: .zero, size: size))
        }) else { return 0 }
        let x = frame.maxX - NGMetrics.cellPadding - size.width
        renderer.appendIcon(entry, at: CGPoint(x: x, y: (frame.midY - size.height / 2).rounded()), clip: clip.intersection(frame),
                            scale: scale, color: highlighted ? style.highlightedText : style.secondaryText, to: &quads)
        return size.width + NGMetrics.choiceChevronSpacing
    }

    /// `chevron.up.chevron.down`, small and semibold like a pop-up button's.
    static var choiceChevronImage: NGSymbolImage? {
        NGSymbolImage.named("chevron.up.chevron.down", pointSize: NGMetrics.choiceChevronPointSize, weight: .semibold)
    }

    /// Stars: `value` filled, the rest outlined; a preview (the value a click
    /// would set) fainter.
    private func appendRating(_ value: Int, maximum: Int, isPreview: Bool, alignment: NSTextAlignment, in frame: CGRect, clip: CGRect,
                              highlighted: Bool, renderer: NGMetalRenderer, scale: CGFloat, style: MetalStyle,
                              to quads: inout [NGMetalQuad]) {
        let clip = clip.intersection(frame)
        let stars = Self.ratingStars(maximum: maximum, alignment: alignment, in: frame)
        for (index, star) in stars.enumerated() {
            let filled = index < value
            let name = filled ? "star.fill" : "star"
            guard let image = NGCellDrawing.markImage(name),
                  let entry = renderer.atlas.icon("mark:\(name)", size: image.size, scale: scale, draw: { context in
                      image.draw(into: context, in: CGRect(origin: .zero, size: image.size))
                  }) else { continue }
            var color = highlighted ? (filled ? style.highlightedMark : style.highlightedMark * 0.45)
                : filled ? style.markColor(.orange) : style.color(.tertiaryLabelColor)
            if isPreview, filled { color *= 0.6 }
            renderer.appendIcon(entry, at: CGPoint(x: star.midX - image.size.width / 2, y: (star.midY - image.size.height / 2).rounded()),
                                clip: clip, scale: scale, color: color, to: &quads)
        }
    }

    /// Where a rating's stars go in a cell: one slot each, by the column's alignment.
    static func ratingStars(maximum: Int, alignment: NSTextAlignment, in frame: CGRect) -> [CGRect] {
        guard maximum > 0 else { return [] }
        let size = NGMetrics.ratingStarSize, spacing = NGMetrics.ratingStarSpacing
        let width = CGFloat(maximum) * size + CGFloat(maximum - 1) * spacing
        let available = max(0, frame.width - 2 * NGMetrics.cellPadding)
        let x = frame.minX + textOrigin(width: width, available: available, alignment: alignment)
        return (0..<maximum).map { index in
            CGRect(x: (x + CGFloat(index) * (size + spacing)).rounded(), y: frame.midY - size / 2, width: size, height: size)
        }
    }

    /// A progress bar like NSProgressIndicator's: a rounded track, the
    /// fraction filled in the accent color (indeterminate: a stripe moving
    /// along it), the text beside it, right-aligned in room for the widest.
    private func appendProgress(fraction: Double?, text: String?, reserved: String?, in frame: CGRect, clip: CGRect,
                                highlighted: Bool, renderer: NGMetalRenderer, scale: CGFloat, style: MetalStyle,
                                to quads: inout [NGMetalQuad]) {
        let font = style.digitFont
        let clip = clip.intersection(frame)
        var bar = frame.insetBy(dx: NGMetrics.cellPadding, dy: 0)
        if let reserved {
            let room = renderer.shaper.shape(reserved, font: font, width: .greatestFiniteMagnitude).width + NGMetrics.progressTextSpacing
            if let text {
                let shaped = renderer.shaper.shape(text, font: font, width: room)
                let baseline = frame.minY + ((frame.height - NGLineHeights.height(of: font)) / 2).rounded() + font.ascender
                renderer.appendGlyphs(shaped, font: font, x: bar.maxX - shaped.width, baseline: baseline, clip: clip, scale: scale,
                                      color: highlighted ? style.highlightedText : style.secondaryText, to: &quads)
            }
            bar.size.width = max(0, bar.width - room)
        }
        guard bar.width > 2 else { return }
        let thickness = NGMetrics.progressThickness
        bar = CGRect(x: bar.minX, y: (frame.midY - thickness / 2).rounded(), width: bar.width, height: thickness)
        let corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let track = highlighted ? style.highlightedText * 0.3 : style.color(.quaternaryLabelColor)
        let fill = highlighted ? style.highlightedText : style.color(accentColorForTesting ?? .controlAccentColor)
        quads.append(NGMetalRenderer.roundedRectangle(bar, radius: thickness / 2, corners: corners, scale: scale, color: track, clip: clip))
        if let fraction {
            guard fraction > 0 else { return }
            let filled = CGRect(x: bar.minX, y: bar.minY, width: max(thickness, bar.width * fraction), height: thickness)
            quads.append(NGMetalRenderer.roundedRectangle(filled, radius: thickness / 2, corners: corners, scale: scale, color: fill,
                                                          clip: clip))
        } else {
            // A third of the track sliding across it, then again (frames are asked for while one shows).
            drawsIndeterminateProgress = true
            let period = NGMetrics.indeterminateProgressPeriod
            let phase = (progressAnimationTimeForTesting ?? CACurrentMediaTime()).truncatingRemainder(dividingBy: period) / period
            let width = bar.width / 3
            let x = bar.minX - width + CGFloat(phase) * (bar.width + width)
            let stripe = CGRect(x: x, y: bar.minY, width: width, height: thickness)
            quads.append(NGMetalRenderer.roundedRectangle(stripe, radius: thickness / 2, corners: corners, scale: scale, color: fill,
                                                          clip: clip.intersection(bar)))
        }
    }

    /// Frames keep coming while an indeterminate progress bar shows (60 a second at most), and stop after.
    func syncProgressAnimation() {
        if drawsIndeterminateProgress, progressLink == nil, !isWindowUnseen {
            let link = displayLink(target: self, selector: #selector(stepProgressAnimation(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            progressLink = link
        } else if !drawsIndeterminateProgress || isWindowUnseen {
            stopProgressAnimation()
        }
    }

    @objc func stepProgressAnimation(_ link: CADisplayLink) {
        // Out of sight, frames wait: so does the stripe (the next frame starts it again).
        guard !isWindowUnseen else { return stopProgressAnimation() }
        setNeedsMetalFrame()
    }

    func stopProgressAnimation() {
        progressLink?.invalidate()
        progressLink = nil
    }

    /// A push button: its bezel (a border and a fill, darker pressed), an
    /// optional symbol and the title, centered in it.
    private func appendButton(_ button: NGCellButton, alignment: NSTextAlignment, pressed: Bool, in frame: CGRect, clip: CGRect,
                              renderer: NGMetalRenderer, scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        let font = style.textFont
        let symbol = button.symbolName.flatMap(NGCellDrawing.markImage)
        let layout = Self.buttonLayout(button, alignment: alignment, in: frame, symbolWidth: symbol?.size.width) { title, width in
            renderer.shaper.shape(title, font: font, width: width).width
        }
        let clip = clip.intersection(frame)
        let radius = NGMetrics.buttonCornerRadius
        let corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let pressed = pressed && button.isEnabled
        quads.append(NGMetalRenderer.roundedRectangle(layout.bezel, radius: radius, corners: corners, scale: scale,
                                                      color: style.color(NGTableView.buttonBorderColor), clip: clip))
        let inset = 1 / scale
        quads.append(NGMetalRenderer.roundedRectangle(layout.bezel.insetBy(dx: inset, dy: inset), radius: radius - inset, corners: corners,
                                                      scale: scale, color: style.color(pressed ? NGTableView.pressedButtonFillColor
                                                                                                : NGTableView.buttonFillColor), clip: clip))
        let textColor = style.color(!button.isEnabled ? .disabledControlTextColor : button.role == .destructive ? .systemRed : .controlTextColor)
        if let symbol, let name = button.symbolName,
           let entry = renderer.atlas.icon("mark:\(name)", size: symbol.size, scale: scale, draw: { context in
               symbol.draw(into: context, in: CGRect(origin: .zero, size: symbol.size))
           }) {
            renderer.appendIcon(entry, at: CGPoint(x: layout.symbolX, y: (layout.bezel.midY - symbol.size.height / 2).rounded()),
                                clip: clip, scale: scale, color: textColor, to: &quads)
        }
        let shaped = renderer.shaper.shape(button.title, font: font, width: layout.titleWidth)
        let baseline = (layout.bezel.midY - NGLineHeights.height(of: font) / 2).rounded() + font.ascender
        renderer.appendGlyphs(shaped, font: font, x: layout.titleX, baseline: baseline, clip: clip, scale: scale, color: textColor, to: &quads)
    }

    /// Where a cell's button and its parts go: the bezel as wide as the
    /// title (and symbol) needs, within the cell's padding, by the column's
    /// alignment. `measure` gives a title's width truncated to a width.
    static func buttonLayout(_ button: NGCellButton, alignment: NSTextAlignment, in frame: CGRect, symbolWidth: CGFloat?,
                             measure: (String, CGFloat) -> CGFloat)
        -> (bezel: CGRect, symbolX: CGFloat, titleX: CGFloat, titleWidth: CGFloat) {
        let padding = NGMetrics.buttonPadding
        let symbolRoom = symbolWidth.map { $0 + (button.title.isEmpty ? 0 : NGMetrics.buttonSymbolSpacing) } ?? 0
        let available = max(0, frame.width - 2 * NGMetrics.cellPadding)
        let titleWidth = min(measure(button.title, max(0, available - 2 * padding - symbolRoom)), max(0, available - 2 * padding - symbolRoom))
        let width = min(available, titleWidth + symbolRoom + 2 * padding)
        let height = min(NGMetrics.buttonHeight, max(0, frame.height - 4))
        let x = frame.minX + Self.textOrigin(width: width, available: available, alignment: alignment)
        let bezel = CGRect(x: x.rounded(), y: (frame.midY - height / 2).rounded(), width: width.rounded(), height: height)
        let contentX = bezel.minX + ((bezel.width - titleWidth - symbolRoom) / 2).rounded()
        return (bezel, contentX, contentX + symbolRoom, titleWidth)
    }

    /// Under a link's title as laid out (`nil` until it is).
    static func linkUnderline(in frame: CGRect, alignment: NSTextAlignment, text: NGLaidOutText?, font: NGFont,
                              scale: CGFloat) -> CGRect? {
        guard let text, text.shaped.width > 0 else { return nil }
        let x = Self.textOrigin(width: text.shaped.width, available: text.width, alignment: alignment)
        let top = ((frame.height - NGLineHeights.height(of: font)) / 2).rounded()
        let baseline = frame.minY + top + font.ascender
        let thickness = max(1 / scale, 1)
        return CGRect(x: frame.minX + x, y: (baseline + max(1, -font.descender * 0.45)) .rounded(.down) + (scale > 1 ? 0.5 : 0),
                      width: text.shaped.width, height: thickness)
    }

    /// Where a line of text of a width starts in a cell (`NGMetalRenderer.appendText` puts it so).
    static func textOrigin(width: CGFloat, available: CGFloat, alignment: NSTextAlignment) -> CGFloat {
        switch alignment {
        case .right: NGMetrics.cellPadding + available - width
        case .center: NGMetrics.cellPadding + ((available - width) / 2)
        default: NGMetrics.cellPadding
        }
    }

    /// A sparkline in the cell's padding: segments (and the areas under them),
    /// bars, and dots on the last, lowest and highest values.
    private func appendSparkline(_ sparkline: NGSparkline, in frame: CGRect, clip: CGRect, highlighted: Bool, scale: CGFloat,
                                 style: MetalStyle, to quads: inout [NGMetalQuad]) {
        let plot = Self.sparklinePlot(in: frame)
        guard plot.width > 1, plot.height > 1, !sparkline.values.isEmpty else { return }
        let clip = clip.intersection(frame)
        let base = highlighted ? style.highlightedMark
            : sparkline.color.map { style.markColor($0) } ?? style.color(accentColorForTesting ?? .controlAccentColor)
        let values = sparkline.values
        if sparkline.style == .winLoss {
            // Wins up from the middle, losses down, of one height.
            let width = plot.width / CGFloat(values.count), middle = plot.midY.rounded()
            let win = highlighted ? base : style.markColor(.green), loss = highlighted ? base : style.markColor(.red)
            for (index, value) in values.enumerated() where !value.isNaN && value != 0 {
                let x = plot.minX + CGFloat(index) * width
                let bar = CGRect(x: x, y: value > 0 ? plot.minY : middle + 1, width: max(1, width - (width > 3 ? 1 : 0)),
                                 height: middle - plot.minY - (value > 0 ? 1 : 0))
                quads.append(NGMetalRenderer.rectangle(bar, scale: scale, color: value > 0 ? win : loss, clip: clip))
            }
            return
        }
        guard let range = sparkline.drawnRange else { return }
        let span = range.upperBound - range.lowerBound
        func y(_ value: Double) -> CGFloat {
            plot.maxY - CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span) * plot.height
        }
        if sparkline.style == .bars {
            // Up from the bottom, or from zero when the range spans it.
            let width = plot.width / CGFloat(values.count)
            let zero = range.contains(0) ? y(0) : plot.maxY
            for (index, value) in values.enumerated() where !value.isNaN {
                let top = min(y(value), zero), bottom = max(y(value), zero)
                let bar = CGRect(x: plot.minX + CGFloat(index) * width, y: top, width: max(1, width - (width > 3 ? 1 : 0)),
                                 height: max(1 / scale, bottom - top))
                quads.append(NGMetalRenderer.rectangle(bar, scale: scale, color: base, clip: clip))
            }
        } else {
            let step = values.count > 1 ? plot.width / CGFloat(values.count - 1) : 0
            func point(_ index: Int) -> CGPoint {
                CGPoint(x: values.count > 1 ? plot.minX + CGFloat(index) * step : plot.midX, y: y(values[index]))
            }
            let lineWidth = NGMetrics.sparklineWidth
            if sparkline.style == .area {
                // Under the line, faint; down to the bottom.
                let fill = base * NGMetrics.sparklineAreaOpacity
                for index in values.indices.dropLast() where !values[index].isNaN && !values[index + 1].isNaN {
                    quads.append(NGMetalRenderer.area(from: point(index), to: point(index + 1), baseline: plot.maxY, scale: scale,
                                                      color: fill, clip: clip))
                }
            }
            for index in values.indices where !values[index].isNaN {
                let hasNext = index + 1 < values.count && !values[index + 1].isNaN
                let hasPrevious = index > 0 && !values[index - 1].isNaN
                if hasNext {
                    quads.append(NGMetalRenderer.segment(from: point(index), to: point(index + 1), width: lineWidth,
                                                         continues: hasPrevious, scale: scale, color: base, clip: clip))
                } else if !hasPrevious {
                    // A value alone between gaps: a dot.
                    quads.append(Self.sparklineDot(at: point(index), radius: lineWidth, scale: scale, color: base, clip: clip))
                }
            }
            if sparkline.showsMinMax, let (low, high) = sparkline.extremes, low < high,
               let lowIndex = values.firstIndex(of: low), let highIndex = values.firstIndex(of: high) {
                quads.append(Self.sparklineDot(at: point(lowIndex), radius: NGMetrics.sparklineDotRadius, scale: scale,
                                               color: highlighted ? base : style.markColor(.red), clip: clip))
                quads.append(Self.sparklineDot(at: point(highIndex), radius: NGMetrics.sparklineDotRadius, scale: scale,
                                               color: highlighted ? base : style.markColor(.green), clip: clip))
            }
            if sparkline.showsLastPoint, let last = values.lastIndex(where: { !$0.isNaN }) {
                quads.append(Self.sparklineDot(at: point(last), radius: NGMetrics.sparklineDotRadius, scale: scale, color: base, clip: clip))
            }
        }
    }

    /// Where a sparkline draws in a cell: inside its padding, a little below its top and above its bottom.
    static func sparklinePlot(in frame: CGRect) -> CGRect {
        frame.insetBy(dx: NGMetrics.cellPadding, dy: max(3, (frame.height * 0.2).rounded()))
    }

    private static func sparklineDot(at point: CGPoint, radius: CGFloat, scale: CGFloat, color: SIMD4<Float>,
                                     clip: CGRect) -> NGMetalQuad {
        NGMetalRenderer.roundedRectangle(CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2),
                                         radius: radius, corners: [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner,
                                                                   .layerMaxXMaxYCorner], scale: scale, color: color, clip: clip)
    }

    /// Capsules and their titles, `NGCellDrawing.fittingWidth(of:)` measures them the same way.
    private func appendTags(_ tags: [NGTag], in frame: CGRect, clip: CGRect, highlighted: Bool, renderer: NGMetalRenderer,
                            scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        let height = NGMetrics.tagHeight
        let y = frame.minY + ((frame.height - height) / 2).rounded()
        var x = NGMetrics.cellPadding
        let maxX = frame.width - NGMetrics.cellPadding
        for tag in tags where x < maxX {
            let space = maxX - x
            let shaped = renderer.shaper.shape(tag.title, font: style.tagFont, width: max(0, space - 2 * NGMetrics.tagPadding))
            guard !shaped.glyphs.isEmpty else { continue }
            let width = min(ceil(shaped.width) + 2 * NGMetrics.tagPadding, space)
            let capsule = CGRect(x: frame.minX + x, y: y, width: width, height: height)
            let colors = style.tagColors(tag.color)
            quads.append(NGMetalRenderer.roundedRectangle(capsule, radius: height / 2, corners: [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner], scale: scale,
                                                          color: highlighted ? style.highlightedTagFill : colors.fill, clip: clip))
            let baseline = capsule.minY + ((capsule.height - NGCellTextMetrics.shared.tagLineHeight) / 2) + CTFontGetAscent(style.tagFont)
            renderer.appendGlyphs(shaped, font: style.tagFont, x: capsule.minX + NGMetrics.tagPadding, baseline: baseline,
                                  clip: clip, scale: scale, color: highlighted ? style.highlightedText : colors.text, to: &quads)
            x += width + NGMetrics.tagSpacing
        }
    }

    /// An SF Symbol, drawn white into the atlas once and tinted with the mark's color.
    private func appendMark(_ mark: NGMark, alignment: NSTextAlignment, in frame: CGRect, clip: CGRect, highlighted: Bool,
                            renderer: NGMetalRenderer, scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        guard let image = NGCellDrawing.markImage(mark.symbolName) else { return }
        let size = image.size
        let rect = NGCellDrawing.markRect(size: size, alignment: alignment, in: CGRect(origin: .zero, size: frame.size))
        guard let entry = renderer.atlas.icon("mark:\(mark.symbolName)", size: size, scale: scale, draw: { context in
            image.draw(into: context, in: CGRect(origin: .zero, size: size))
        }) else { return }
        let color = highlighted ? style.highlightedMark : style.markColor(mark.color)
        renderer.appendIcon(entry, at: CGPoint(x: frame.minX + rect.minX, y: frame.minY + rect.minY), clip: clip, scale: scale,
                            color: color, to: &quads)
    }

    /// A group header's chevron, title and row count.
    private func appendGroupTitle(_ title: NGGroupTitle, in frame: CGRect, clip: CGRect, renderer: NGMetalRenderer,
                                  scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        let lineTop = ((frame.height - NGLineHeights.height(of: style.textFont)) / 2).rounded()
        let chevronX = NGMetrics.cellPadding + CGFloat(title.level) * NGMetrics.groupIndent
        let chevronY = ((frame.height - NGMetrics.disclosureWidth) / 2).rounded()
        let chevronSize = CGSize(width: NGMetrics.disclosureWidth, height: NGMetrics.disclosureWidth)
        let pointsLeft = isRightToLeft && !title.isExpanded
        if let entry = renderer.atlas.icon(title.isExpanded ? "chevron.down" : pointsLeft ? "chevron.left" : "chevron.right",
                                           size: chevronSize, scale: scale, draw: { context in
            if pointsLeft { context.translateBy(x: chevronSize.width, y: 0); context.scaleBy(x: -1, y: 1) }
            NGCellDrawing.drawChevron(in: CGRect(origin: .zero, size: chevronSize), expanded: title.isExpanded,
                                      color: CGColor(gray: 1, alpha: 1), context: context)
        }) {
            renderer.appendIcon(entry, at: CGPoint(x: frame.minX + chevronX, y: frame.minY + chevronY), clip: clip, scale: scale,
                                color: style.secondaryText, to: &quads)
        }
        let textX = chevronX + NGMetrics.disclosureWidth + NGMetrics.groupTitleSpacing
        let available = max(0, frame.width - NGMetrics.cellPadding - textX)
        let detail = title.detail.isEmpty ? nil : renderer.shaper.shape(title.detail, font: style.textFont, width: .greatestFiniteMagnitude)
        let detailRoom = detail.map { $0.width + NGMetrics.groupTitleSpacing } ?? 0
        let fullTitle = renderer.shaper.shape(title.title, font: style.boldTextFont, width: .greatestFiniteMagnitude)
        let showsDetail = detail != nil && fullTitle.width + detailRoom <= available
        let shapedTitle = showsDetail ? fullTitle : renderer.shaper.shape(title.title, font: style.boldTextFont, width: available)
        renderer.appendGlyphs(shapedTitle, font: style.boldTextFont, x: frame.minX + textX,
                              baseline: frame.minY + lineTop + CTFontGetAscent(style.boldTextFont), clip: clip, scale: scale,
                              color: style.text, to: &quads)
        if showsDetail, let detail {
            renderer.appendGlyphs(detail, font: style.textFont, x: frame.minX + textX + shapedTitle.width + NGMetrics.groupTitleSpacing,
                                  baseline: frame.minY + lineTop + CTFontGetAscent(style.textFont), clip: clip, scale: scale,
                                  color: style.secondaryText, to: &quads)
        }
    }
}

/// Fonts and colors of one frame, resolved for the table's appearance once.
@MainActor
final class MetalStyle {
    let textFont: NGFont
    let digitFont: NGFont
    let tagFont = NGCellDrawing.tagFont
    let boldTextFont: NGFont
    let boldDigitFont: NGFont
    let headerFont: NGFont
    let mediaTitleFont: NGFont
    let mediaCaptionFont = NGFont.preferredFont(forTextStyle: .caption1)
    let groupHeaderFont: NGFont
    /// The background behind the rows.
    let background: NGColor
    private let tableStyle: NGTableStyle

    let text: SIMD4<Float>
    let secondaryText: SIMD4<Float>
    let highlightedText: SIMD4<Float>
    let highlightedTagFill: SIMD4<Float>
    let highlightedMark: SIMD4<Float>
    private let palette: NGCellPalette
    private let appearance: NGAppearance
    /// Row colors are a few objects (stripes, selection, tints): resolved once
    /// each. The colors are kept, so their identifiers can't be reused by others.
    private var colors: [ObjectIdentifier: (color: NGColor, value: SIMD4<Float>)] = [:]
    private var tags: [NGNamedColor: (text: SIMD4<Float>, fill: SIMD4<Float>)] = [:]
    private var marks: [NGNamedColor?: SIMD4<Float>] = [:]

    private struct Key: Hashable {
        let appearance: NGAppearance.Name
        let style: NGTableStyle
    }

    /// Styles by appearance and table style, made once (fonts, resolved colors).
    private static var styles: [Key: MetalStyle] = [:]

    static func resolved(for appearance: NGAppearance, style tableStyle: NGTableStyle = NGTableStyle()) -> MetalStyle {
        let key = Key(appearance: appearance.name, style: tableStyle)
        if let style = styles[key] { return style }
        // Apps keep a few styles; stay small if they make new ones.
        if styles.count > 32 { styles.removeAll() }
        let style = MetalStyle(appearance: appearance, style: tableStyle)
        styles[key] = style
        return style
    }

    /// System colors changed (accent, contrast): resolve them again.
    static func removeAll() {
        styles.removeAll()
    }

    private init(appearance: NGAppearance, style tableStyle: NGTableStyle) {
        self.appearance = appearance
        self.tableStyle = tableStyle
        let size = tableStyle.cellFontSize, titleSize = tableStyle.titleFontSize
        textFont = .systemFont(ofSize: size)
        digitFont = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        boldTextFont = .systemFont(ofSize: size, weight: .semibold)
        boldDigitFont = .monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        mediaTitleFont = .systemFont(ofSize: size, weight: .medium)
        headerFont = .systemFont(ofSize: titleSize)
        groupHeaderFont = .systemFont(ofSize: titleSize, weight: .semibold)
        background = tableStyle.backgroundColor ?? .controlBackgroundColor
        palette = NGCellPalette.resolved(for: appearance)
        var resolvedText = NGMetalRenderer.premultiplied(palette.text)
        var resolvedSecondary = NGMetalRenderer.premultiplied(palette.secondaryText)
        appearance.performAsCurrentDrawingAppearance {
            if let color = tableStyle.textColor { resolvedText = NGMetalRenderer.premultiplied(color.cgColor) }
            if let color = tableStyle.secondaryTextColor { resolvedSecondary = NGMetalRenderer.premultiplied(color.cgColor) }
        }
        text = resolvedText
        secondaryText = resolvedSecondary
        highlightedText = NGMetalRenderer.premultiplied(palette.highlightedText)
        highlightedTagFill = NGMetalRenderer.premultiplied(palette.highlightedTagFill)
        var mark = SIMD4<Float>(1, 1, 1, 1)
        appearance.performAsCurrentDrawingAppearance {
            mark = NGMetalRenderer.premultiplied(NGColor.alternateSelectedControlTextColor.cgColor)
        }
        highlightedMark = mark
    }

    func color(_ color: NGColor) -> SIMD4<Float> {
        if let resolved = colors[ObjectIdentifier(color)] { return resolved.value }
        var resolved = SIMD4<Float>.zero
        appearance.performAsCurrentDrawingAppearance {
            resolved = NGMetalRenderer.premultiplied(color.cgColor)
        }
        // Apps should give the same color objects every time; if they don't, stay small.
        if colors.count > 512 { colors.removeAll() }
        colors[ObjectIdentifier(color)] = (color, resolved)
        return resolved
    }

    func tagColors(_ name: NGNamedColor) -> (text: SIMD4<Float>, fill: SIMD4<Float>) {
        if let resolved = tags[name] { return resolved }
        let pair = palette.tags[name]
        let resolved = (pair.map { NGMetalRenderer.premultiplied($0.text) } ?? text, pair.map { NGMetalRenderer.premultiplied($0.fill) } ?? .zero)
        tags[name] = resolved
        return resolved
    }

    func markColor(_ name: NGNamedColor?) -> SIMD4<Float> {
        if let resolved = marks[name] { return resolved }
        var resolved = SIMD4<Float>.zero
        appearance.performAsCurrentDrawingAppearance {
            resolved = NGMetalRenderer.premultiplied((name?.systemColor ?? .secondaryLabelColor).cgColor)
        }
        marks[name] = resolved
        return resolved
    }
}
#endif
