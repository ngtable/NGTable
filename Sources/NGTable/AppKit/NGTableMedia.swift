#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Metal

// Media cells (`NGCellValue.media`): the picture at the cell's leading edge,
// cropped to its thumbnail size with rounded corners (a placeholder symbol
// while it loads, see NGMediaCache.swift), an optional badge in its corner,
// and the lines of text beside it, vertically centered. Pictures are
// textures of the frame (`metalTextures`), named by slot in their quads.

extension NGTableView {
    /// The slot of a texture in the frame being built.
    func textureSlot(_ texture: MTLTexture) -> Int {
        if let slot = metalTextures.firstIndex(where: { $0 === texture }) { return slot }
        metalTextures.append(texture)
        return metalTextures.count - 1
    }

    /// Where the picture of a visible media cell is, in the table's
    /// coordinates, e.g. for Quick Look to zoom from it. `nil` if the cell
    /// isn't in view or has no media value.
    public func frameOfMediaThumbnail(row: Int, columnID: String) -> CGRect? {
        guard let (media, cell) = visibleMedia(row: row, columnID: columnID) else { return nil }
        return mediaThumbnailFrame(of: media, inCell: cell)
    }

    #if os(macOS)
    /// The still picture of a visible media cell as it shows it (cropped to
    /// the thumbnail), or `nil` while it isn't loaded.
    public func mediaThumbnailImage(row: Int, columnID: String) -> NSImage? {
        guard let (media, _) = visibleMedia(row: row, columnID: columnID), let renderer = metalRenderer else { return nil }
        let scale = displayScale
        guard case .ready(let still) = NGMediaCache.shared.still(for: media, width: Int((media.thumbnailSize.width * scale).rounded()),
                                                                 height: Int((media.thumbnailSize.height * scale).rounded()),
                                                                 device: renderer.device),
              let image = still.image else { return nil }
        return NSImage(cgImage: image, size: media.thumbnailSize)
    }
    #endif

    /// The media value of a visible cell (a data source row) and its frame in the table.
    private func visibleMedia(row: Int, columnID: String) -> (NGMedia, CGRect)? {
        guard let displayRow = displayRow(forSourceRow: row),
              let cell = visibleCells[NGCellKey(row: displayRow, column: columnOrdinal(of: columnID))],
              case .media(let media) = cell.content, let frame = frameOfCell(row: row, columnID: columnID) else { return nil }
        return (media, frame)
    }

    /// Where a media cell's picture is in a cell frame (same coordinates),
    /// on whole device pixels.
    func mediaThumbnailFrame(of media: NGMedia, inCell cell: CGRect) -> CGRect {
        let scale = displayScale
        let size = media.thumbnailSize
        return CGRect(x: ((cell.minX + NGMetrics.mediaInset) * scale).rounded() / scale,
                      y: ((cell.midY - size.height / 2) * scale).rounded() / scale,
                      width: size.width, height: size.height)
    }

    func appendMedia(_ media: NGMedia, of cell: NGDrawnCell?, in frame: CGRect, clip: CGRect, highlighted: Bool, renderer: NGMetalRenderer,
                     scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        let thumbnail = mediaThumbnailFrame(of: media, inCell: frame)
        if thumbnail.intersects(clip) {
            appendThumbnail(of: media, of: cell, in: thumbnail, clip: clip, renderer: renderer, scale: scale, style: style, to: &quads)
        }
        appendMediaLines(media.lines, from: thumbnail.maxX + NGMetrics.mediaTextSpacing, in: frame, clip: clip,
                         highlighted: highlighted, renderer: renderer, scale: scale, style: style, to: &quads)
    }

    private func appendThumbnail(of media: NGMedia, of cell: NGDrawnCell?, in thumbnail: CGRect, clip: CGRect, renderer: NGMetalRenderer,
                                 scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let state = NGMediaCache.shared.still(for: media, width: Int((thumbnail.width * scale).rounded()),
                                              height: Int((thumbnail.height * scale).rounded()), device: renderer.device)
        if let player = mediaPlayer, player.cell === cell, player.media == media, let texture = player.texture {
            // The motion under the pointer, cropped to fill the thumbnail.
            quads.append(NGMetalRenderer.picture(thumbnail, slot: textureSlot(texture), radius: media.cornerRadius, scale: scale,
                                                 source: Self.fillingSource(width: texture.width, height: texture.height, in: thumbnail.size),
                                                 clip: clip))
        } else if case .ready(let still) = state {
            quads.append(NGMetalRenderer.picture(thumbnail, slot: textureSlot(still.texture), radius: media.cornerRadius,
                                                 scale: scale, clip: clip))
        } else {
            quads.append(NGMetalRenderer.roundedRectangle(thumbnail, radius: media.cornerRadius, corners: allCorners, scale: scale,
                                                          color: style.color(.quaternaryLabelColor), clip: clip))
            let isFailed = if case .failed = state { true } else { false }
            appendSymbol(isFailed ? "exclamationmark.triangle" : media.placeholder, pointSize: 18, weight: .regular,
                         centeredIn: thumbnail, color: style.color(.tertiaryLabelColor), clip: clip, renderer: renderer,
                         scale: scale, to: &quads)
        }
        if let badge = media.badge {
            let rect = CGRect(x: thumbnail.minX + 4, y: thumbnail.minY + 4, width: 18, height: 14)
            quads.append(NGMetalRenderer.roundedRectangle(rect, radius: 4, corners: allCorners, scale: scale,
                                                          color: NGMetalRenderer.premultiplied(NGColor.black.withAlphaComponent(0.55)),
                                                          clip: clip))
            appendSymbol(badge, pointSize: 10, weight: .semibold, centeredIn: rect, color: SIMD4(repeating: 1), clip: clip,
                         renderer: renderer, scale: scale, to: &quads)
        }
    }

    /// The lines one under another, the block centered vertically in the cell.
    private func appendMediaLines(_ lines: [NGMedia.Line], from x: CGFloat, in frame: CGRect, clip: CGRect, highlighted: Bool,
                                  renderer: NGMetalRenderer, scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        let width = frame.maxX - NGMetrics.mediaInset - x
        guard width > 0 else { return }
        var blocks: [(shaped: [NGShapedText], font: NGFont, color: SIMD4<Float>)] = []
        for line in lines where !line.text.isEmpty {
            let font: NGFont
            let color: SIMD4<Float>
            switch line.style {
            case .title:
                font = style.mediaTitleFont
                color = highlighted ? style.highlightedText : style.text
            case .secondary:
                font = style.mediaCaptionFont
                color = highlighted ? style.highlightedText : style.secondaryText
            case .colored(let named):
                font = style.mediaCaptionFont
                color = highlighted ? style.highlightedText : style.markColor(named)
            }
            blocks.append((renderer.shaper.shapeLines(line.text, font: font, width: width, maximumLines: line.maximumLines), font, color))
        }
        guard !blocks.isEmpty else { return }
        let lineHeight = { (font: NGFont) in ceil(font.ascender - font.descender + font.leading) }
        let height = blocks.reduce(0) { $0 + CGFloat($1.shaped.count) * lineHeight($1.font) }
            + NGMetrics.mediaLineSpacing * CGFloat(blocks.count - 1)
        var y = (frame.midY - height / 2).rounded()
        let textClip = clip.intersection(CGRect(x: x, y: frame.minY, width: width, height: frame.height))
        for block in blocks {
            for shaped in block.shaped {
                renderer.appendGlyphs(shaped, font: block.font, x: x, baseline: y + block.font.ascender, clip: textClip,
                                      scale: scale, color: block.color, to: &quads)
                y += lineHeight(block.font)
            }
            y += NGMetrics.mediaLineSpacing
        }
    }

    /// An SF Symbol drawn white into the atlas once, tinted, centered on whole pixels.
    func appendSymbol(_ name: String, pointSize: CGFloat, weight: NGFont.Weight, centeredIn rect: CGRect, color: SIMD4<Float>,
                      clip: CGRect, renderer: NGMetalRenderer, scale: CGFloat, to quads: inout [NGMetalQuad]) {
        guard let image = Self.symbolImage(name, pointSize: pointSize, weight: weight) else { return }
        let size = image.size
        guard let entry = renderer.atlas.icon("symbol:\(name):\(pointSize):\(weight.rawValue)", size: size, scale: scale, draw: { context in
            image.draw(into: context, in: CGRect(origin: .zero, size: size))
        }) else { return }
        renderer.appendIcon(entry, at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), clip: clip,
                            scale: scale, color: color, to: &quads)
    }

    private static func symbolImage(_ name: String, pointSize: CGFloat, weight: NGFont.Weight) -> NGSymbolImage? {
        NGSymbolImage.named(name, pointSize: pointSize, weight: weight)
    }

    /// The part of a texture that fills `size` keeping its proportions
    /// (centered), in 0...1.
    static func fillingSource(width: Int, height: Int, in size: CGSize) -> SIMD4<Float> {
        guard width > 0, height > 0, size.width > 0, size.height > 0 else { return SIMD4(0, 0, 1, 1) }
        let textureAspect = Float(width) / Float(height), aspect = Float(size.width / size.height)
        if textureAspect > aspect {
            let part = aspect / textureAspect
            return SIMD4((1 - part) / 2, 0, part, 1)
        }
        let part = textureAspect / aspect
        return SIMD4(0, (1 - part) / 2, 1, part)
    }

    /// A picture loaded somewhere in the app: a frame only for a table that
    /// shows media (or is between frames: cells are placed before drawing).
    @objc func mediaCacheDidChange(_ notification: Notification) {
        guard window != nil, needsMetalFrame || visibleCells.values.contains(where: { if case .media = $0.content { true } else { false } }) else { return }
        setNeedsMetalFrame()
    }

    // MARK: Motion under the pointer

    /// Plays the motion of the media cell under the pointer, and stops the previous one.
    func hoveredCellDidChange(from old: NGCellPosition?) {
        mediaPlayer?.stop()
        mediaPlayer = nil
        guard let hoveredCell, let renderer = metalRenderer, let displayRow = displayRow(forSourceRow: hoveredCell.row),
              let cell = visibleCells[NGCellKey(row: displayRow, column: columnOrdinal(of: hoveredCell.columnID))],
              case .media(let media) = cell.content, media.motion != nil else { return }
        let scale = displayScale
        let player = NGMediaPlayer(cell: cell, media: media) { [weak self] in self?.setNeedsMetalFrame() }
        player.start(in: self, device: renderer.device,
                     pixelSize: (Int((media.thumbnailSize.width * scale).rounded()), Int((media.thumbnailSize.height * scale).rounded())))
        mediaPlayer = player
    }
}
#endif
