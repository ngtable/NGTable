#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Metal

// Text drawn on the GPU from a glyph atlas. The text is laid out by
// NGTextEngine.swift (Core Text for what only it does right); each glyph is rasterized
// once, the way Core Graphics draws text into a bitmap (no font smoothing,
// positions quantized to a quarter pixel), and placed by the GPU wherever it
// appears.

/// Glyph bitmaps packed into one texture, rasterized on first use.
@MainActor
final class NGGlyphAtlas {
    /// Where a glyph's bitmap is, and where its pen position is in it.
    /// Stored in 14 bytes (tables hold one per glyph and phase, up to the
    /// highest glyph used; with Ints they were 56).
    struct Entry {
        private let storedX: UInt16, storedY: UInt16, storedWidth: UInt16, storedHeight: UInt16
        private let storedOriginX: Int16, storedBaselineFromTop: Int16
        /// Color glyphs (emoji) keep their colors; others are coverage, tinted when drawn.
        let isColor: Bool

        /// In texture pixels; empty for glyphs that draw nothing (spaces).
        var x: Int { Int(storedX) }
        var y: Int { Int(storedY) }
        var width: Int { Int(storedWidth) }
        var height: Int { Int(storedHeight) }
        /// The pen position (with its subpixel phase) from the bitmap's left edge, in pixels.
        var originX: Int { Int(storedOriginX) }
        /// The baseline from the bitmap's top edge, in pixels.
        var baselineFromTop: Int { Int(storedBaselineFromTop) }

        /// `nil` if a value doesn't fit (positions are within the atlas, at most `maximumSize`).
        init?(x: Int, y: Int, width: Int, height: Int, originX: Int, baselineFromTop: Int, isColor: Bool) {
            guard let x = UInt16(exactly: x), let y = UInt16(exactly: y), let width = UInt16(exactly: width),
                  let height = UInt16(exactly: height), let originX = Int16(exactly: originX),
                  let baselineFromTop = Int16(exactly: baselineFromTop) else { return nil }
            storedX = x
            storedY = y
            storedWidth = width
            storedHeight = height
            storedOriginX = originX
            storedBaselineFromTop = baselineFromTop
            self.isColor = isColor
        }

        /// A glyph that draws nothing.
        static func empty(isColor: Bool) -> Entry {
            Entry(x: 0, y: 0, width: 0, height: 0, originX: 0, baselineFromTop: 0, isColor: isColor)!
        }
    }

    /// Subpixel positions of a glyph's pen, like Core Graphics' quantization.
    static let phases = 4

    /// The glyphs of one font at one baseline offset and scale, by glyph and
    /// phase: a frame looks up every glyph it draws, by index rather than by
    /// hashing. In pages of `pageGlyphs` glyphs, made when a glyph in them is
    /// used: fonts with tens of thousands of glyphs (CJK fallbacks) don't get
    /// an entry for every glyph below the highest one used.
    final class GlyphTable {
        static let pageGlyphs = 256
        fileprivate let font: Int
        /// The baseline's offset below a whole pixel, in 1/64 pixels: Core
        /// Graphics doesn't round baselines, and a line's is the same in every row.
        fileprivate let rise: Int
        fileprivate let scale: CGFloat
        fileprivate var pages: [[Entry?]?] = []
        /// Entries the pages have room for (for tests).
        var allocatedEntryCount: Int { pages.reduce(0) { $0 + ($1?.count ?? 0) } }
        /// The atlas's `resetCount` the entries are from.
        fileprivate var generation: Int

        fileprivate init(font: Int, rise: Int, scale: CGFloat, generation: Int) {
            self.font = font
            self.rise = rise
            self.scale = scale
            self.generation = generation
        }
    }

    private struct TableKey: Hashable {
        let font: Int
        let rise: Int
        let scale: CGFloat
    }

    /// Steps of the vertical offset (fine enough to match Core Graphics).
    static let rises = 64

    /// The current texture. Starting over makes a new one: frames the GPU is
    /// still drawing keep reading the old one (their command buffers retain
    /// it), so no bitmap is overwritten under them.
    private(set) var texture: MTLTexture
    private let device: MTLDevice
    /// The texture's width and height; doubled (up to `maximumSize`) when one
    /// frame alone fills it (see `grow()`).
    private(set) var size: Int
    static let maximumSize = 4096
    private var tables: [TableKey: GlyphTable] = [:]
    /// Fonts by identity, numbered for the keys (CTFont isn't cheap to hash),
    /// shared with the text engine.
    let fonts: NGFontRegistry
    // Shelf packing: glyphs fill rows left to right; a row is as tall as its tallest glyph.
    private var cursorX = 0, cursorY = 0, shelfHeight = 0
    /// Glyphs rasterized so far (for tests and statistics).
    private(set) var rasterizedCount = 0
    /// The atlas filled up and started over (glyphs are rasterized again).
    private(set) var resetCount = 0

    init?(device: MTLDevice, size: Int = 2048, fonts: NGFontRegistry = NGFontRegistry()) {
        guard let texture = Self.makeTexture(device: device, size: size) else { return nil }
        self.fonts = fonts
        self.device = device
        self.texture = texture
        self.size = size
    }

    private static func makeTexture(device: MTLDevice, size: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    /// A number for a font, to key glyphs by.
    func fontID(of font: CTFont) -> Int { fonts.id(of: font) }

    func font(_ id: Int) -> CTFont { fonts.font(id) }

    /// The glyphs of a font at a baseline offset below a whole pixel
    /// (0 ..< `rises`) and a scale.
    func table(font fontID: Int, rise: Int, scale: CGFloat) -> GlyphTable {
        let key = TableKey(font: fontID, rise: rise, scale: scale)
        if let table = tables[key] { return table }
        let table = GlyphTable(font: fontID, rise: rise, scale: scale, generation: resetCount)
        tables[key] = table
        return table
    }

    /// The bitmap of a glyph at a subpixel phase (0 ..< `phases`), rasterized
    /// and packed the first time.
    func entry(in table: GlyphTable, glyph: CGGlyph, phase: Int) -> Entry? {
        if table.generation != resetCount {
            // The atlas started over since: its bitmaps are gone.
            table.pages.removeAll()
            table.generation = resetCount
        }
        let page = Int(glyph) / GlyphTable.pageGlyphs
        let index = (Int(glyph) % GlyphTable.pageGlyphs) * Self.phases + phase
        if page < table.pages.count, let entries = table.pages[page], let entry = entries[index] { return entry }
        guard let entry = rasterize(font: fonts.font(table.font), glyph: glyph, phase: phase, rise: table.rise, scale: table.scale) else {
            return nil
        }
        // Rasterizing may have started the atlas over.
        if table.generation != resetCount {
            table.pages.removeAll()
            table.generation = resetCount
        }
        if page >= table.pages.count {
            table.pages.append(contentsOf: repeatElement(nil, count: page + 1 - table.pages.count))
        }
        if table.pages[page] == nil {
            table.pages[page] = [Entry?](repeating: nil, count: GlyphTable.pageGlyphs * Self.phases)
        }
        table.pages[page]![index] = entry
        return entry
    }

    private func rasterize(font: CTFont, glyph: CGGlyph, phase: Int, rise: Int, scale: CGFloat) -> Entry? {
        var glyph = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, &bounds, 1)
        let isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        let shift = CGFloat(phase) / CGFloat(Self.phases)
        // The baseline is `drop` pixels below the whole pixel the entry is placed from.
        let drop = CGFloat(rise) / CGFloat(Self.rises)
        guard !bounds.isEmpty else { return .empty(isColor: isColor) }
        // The glyph's pixels, with a pixel of room for antialiasing.
        let left = Int(floor(bounds.minX * scale + shift)) - 1
        let right = Int(ceil(bounds.maxX * scale + shift)) + 1
        let bottom = Int(floor(bounds.minY * scale - drop)) - 1
        let top = Int(ceil(bounds.maxY * scale - drop)) + 1
        let width = right - left, height = top - bottom
        // Too large for the atlas: drawn as nothing (and remembered as such,
        // instead of being tried again on every frame).
        guard width > 0, height > 0, width < size, height < size, Int16(exactly: -left) != nil, Int16(exactly: top) != nil else {
            return .empty(isColor: isColor)
        }
        guard let (x, y) = place(width: width, height: height),
              let context = NGCellDrawing.makeBitmapContext(width: width, height: height,
                                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        // White coverage (tinted on the GPU); color glyphs draw their own colors.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.scaleBy(x: scale, y: scale)
        var position = CGPoint(x: (shift - CGFloat(left)) / scale, y: (-CGFloat(bottom) - drop) / scale)
        CTFontDrawGlyphs(font, &glyph, &position, 1, context)
        guard let data = context.data else { return nil }
        // A bitmap context's first row is the top of the image, like the texture's.
        texture.replace(region: MTLRegionMake2D(x, y, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: context.bytesPerRow)
        rasterizedCount += 1
        return Entry(x: x, y: y, width: width, height: height, originX: -left, baselineFromTop: top, isColor: isColor) ?? .empty(isColor: isColor)
    }

    private var icons: [String: Entry] = [:]

    /// An icon (a symbol, a chevron) drawn by `draw` into `size` points, in
    /// white to be tinted, rasterized once per key and scale.
    func icon(_ key: String, size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> Entry? {
        let fullKey = "\(key)@\(scale)"
        if let entry = icons[fullKey] { return entry }
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0, width < self.size, height < self.size,
              let (x, y) = place(width: width, height: height),
              let context = NGCellDrawing.makeBitmapContext(width: width, height: height,
                                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        // Top-down points, like the cells.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(context)
        guard let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(x, y, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: context.bytesPerRow)
        guard let entry = Entry(x: x, y: y, width: width, height: height, originX: 0, baselineFromTop: 0, isColor: false) else { return nil }
        icons[fullKey] = entry
        return entry
    }

    /// A free spot for a bitmap; a full atlas starts over (glyphs are rasterized again as needed).
    private func place(width: Int, height: Int) -> (Int, Int)? {
        if cursorX + width > size {
            cursorX = 0
            cursorY += shelfHeight
            shelfHeight = 0
        }
        if cursorY + height > size {
            startOver(size: size)
        }
        defer {
            cursorX += width
            shelfHeight = max(shelfHeight, height)
        }
        return (cursorX, cursorY)
    }

    /// Empties the atlas into a new texture of `size`: every bitmap is
    /// rasterized again when next asked for. Quads made before refer to the
    /// old texture; frames being built are built again
    /// (`NGMetalRenderer.quadsSurvivingAtlasResets`).
    private func startOver(size newSize: Int) {
        // Without a new texture the old one is reused: the frame is built
        // again anyway, only frames the GPU is drawing could show a glyph late.
        if let texture = Self.makeTexture(device: device, size: newSize) {
            self.texture = texture
            size = newSize
        }
        icons.removeAll()
        cursorX = 0
        cursorY = 0
        shelfHeight = 0
        resetCount += 1
    }

    /// One frame's glyphs didn't fit: starts over twice as large (up to
    /// `maximumSize`), so the next attempt fits instead of starting over again.
    /// - Returns: Whether it grew.
    @discardableResult
    func grow() -> Bool {
        guard size < Self.maximumSize else { return false }
        startOver(size: min(size * 2, Self.maximumSize))
        return true
    }
}

/// Lays text out (see NGTextEngine.swift), truncated with "…" to a width,
/// and keeps recent results (the same values appear in many cells).
///
/// A frame full of new text (a fast flick) lays it out on all cores: the
/// frame is built collecting the text that isn't laid out yet
/// (`beginCollectingMisses()`), which is then laid out concurrently
/// (`layOutCollectedMisses()`), and the cells that missed it are added.
@MainActor
final class NGTextShaper {
    private struct Key: Hashable {
        let text: String
        let font: Int
        /// The width truncated to, in quarter points.
        let width: Int
    }

    private struct Request: Sendable {
        let text: String
        let style: NGTextStyle
        let width: CGFloat
    }

    /// The layout itself, thread-safe (shared with the atlas's font ids).
    let engine: NGTextEngine

    /// Text asked for during a collecting pass and not laid out yet.
    private var misses: [Key: Request]?
    /// Counts the misses, so callers can tell whether some text they asked for is missing.
    private(set) var missCount = 0

    private var cache: [Key: NGShapedText] = [:]
    private var order: [Key] = []
    private var orderStart = 0
    private let limit = 20_000

    init(engine: NGTextEngine) {
        self.engine = engine
    }

    /// Characters simple lines take (see `NGSimpleText`).
    nonisolated static var simpleCharacters: [ClosedRange<UInt16>] { NGSimpleText.characters }

    func shape(_ text: String, font: CTFont, width: CGFloat) -> NGShapedText {
        let fontID = fontID(of: font)
        // The whole line first, under one key for every width: text that fits
        // is the same in every column. Only text that doesn't is truncated.
        let fullKey = Key(text: text, font: fontID, width: Int.max)
        var full = cache[fullKey]
        var units: [UInt16]?
        if full == nil {
            let textUnits = Array(text.utf16)
            units = textUnits
            if let simple = engine.simpleLine(textUnits, font: font, fontID: fontID) {
                simpleLineCount += 1
                insert(simple, for: fullKey)
                full = simple
            }
        }
        if let full, width >= 100_000 || full.width <= width { return full }
        let key = Key(text: text, font: fontID, width: width < 100_000 ? Int((width * 4).rounded(.down)) : Int.max)
        if let full {
            if let truncated = cache[key] { return truncated }
            if let truncated = engine.simpleTruncated(full, of: units ?? Array(text.utf16), font: font, fontID: fontID, width: width) {
                insert(truncated, for: key)
                return truncated
            }
        }
        let request = Request(text: text, style: engine.style(of: font, id: fontID), width: width)
        if misses != nil {
            misses?[key] = request
            missCount += 1
            return NGShapedText()
        }
        return insert(Self.layOut(request), for: request, fontID: fontID)
    }

    // MARK: Wrapped lines

    private struct LinesKey: Hashable {
        let text: String
        let font: Int
        let width: Int
        let maximumLines: Int
    }

    private var wrapped: [LinesKey: [NGShapedText]] = [:]

    /// Text wrapped into at most `maximumLines` lines of `width`, the last one
    /// truncated with "…" if text remains (kept for the next frames).
    func shapeLines(_ text: String, font: CTFont, width: CGFloat, maximumLines: Int) -> [NGShapedText] {
        guard maximumLines > 1 else { return [shape(text, font: font, width: width)] }
        let fontID = fontID(of: font)
        let key = LinesKey(text: text, font: fontID, width: Int((width * 4).rounded(.down)), maximumLines: maximumLines)
        if let cached = wrapped[key] { return cached }
        // Simple text: wrapped like rows are measured (see NGSimpleWrap.swift).
        let units = Array(text.utf16)
        let lines: [NGShapedText]
        if case .lines(let ranges) = engine.simpleWrap(units, font: font, fontID: fontID, width: width, maximumLines: maximumLines) {
            lines = ranges.enumerated().map { index, range in
                var end = range.upperBound
                // Spaces at the end hang: not drawn, nor counted for the alignment.
                while end > range.lowerBound, units[end - 1] == 0x20 { end -= 1 }
                let line = String(utf16CodeUnits: Array(units[range.lowerBound..<end]), count: end - range.lowerBound)
                // The last line allowed truncated if text remains; the others
                // are drawn whole (a colon's glyph may differ by a hair).
                return shape(line, font: font, width: index == maximumLines - 1 ? width : .greatestFiniteMagnitude)
            }
        } else {
            lines = engine.coreTextLines(text, font: font, fontID: fontID, width: width, maximumLines: maximumLines)
        }
        if wrapped.count > 2_000 { wrapped.removeAll() }
        wrapped[key] = lines
        return lines
    }

    /// How many lines `shapeLines` wraps text onto, without laying out glyphs.
    func lineCount(of text: String, font: CTFont, width: CGFloat, maximumLines: Int) -> Int {
        engine.lineCount(of: text, font: font, width: width, maximumLines: maximumLines)
    }

    /// How many lines Core Text's typesetter wraps text onto (thread-safe).
    nonisolated static func lineCount(of text: String, attributes: CFDictionary, width: CGFloat, maximumLines: Int) -> Int {
        NGTextEngine.coreTextLineCount(of: text, attributes: attributes, width: width, maximumLines: maximumLines)
    }

    /// The attributes text of a font is laid out with.
    func lineAttributes(of font: CTFont) -> NGUncheckedSendable<CFDictionary> {
        NGUncheckedSendable(engine.style(of: font, id: fontID(of: font)).attributes)
    }

    // MARK: Simple lines

    /// Lines made without Core Text (for tests and statistics).
    private(set) var simpleLineCount = 0

    /// Core Text's layout of a line, truncated to `width` if it doesn't fit,
    /// bypassing the cache and the simple lines (for tests).
    func coreTextLine(_ text: String, font: CTFont, width: CGFloat = .greatestFiniteMagnitude) -> NGShapedText {
        let laidOut = NGTextEngine.layOut(text, style: NGTextStyle(font: font), width: width)
        return engine.shaped(laidOut.truncated ?? laidOut.full)
    }

    /// A simple line truncated to `width`, bypassing the cache (whose keys
    /// round widths to quarter points), or `nil` if it isn't simple (for tests).
    func simpleLine(_ text: String, font: CTFont, width: CGFloat) -> NGShapedText? {
        let fontID = fontID(of: font)
        let units = Array(text.utf16)
        guard let full = engine.simpleLine(units, font: font, fontID: fontID) else { return nil }
        return full.width <= width ? full : engine.simpleTruncated(full, of: units, font: font, fontID: fontID, width: width)
    }

    /// The fonts the shaper is asked for are the same few objects every time:
    /// their ids, found by identity without a lock (kept, so the identities
    /// aren't reused).
    private var fontIDsByObject: [ObjectIdentifier: (font: CTFont, id: Int)] = [:]

    private func fontID(of font: CTFont) -> Int {
        if let known = fontIDsByObject[ObjectIdentifier(font)] { return known.id }
        let id = engine.fonts.id(of: font)
        if fontIDsByObject.count > 64 { fontIDsByObject.removeAll() }
        fontIDsByObject[ObjectIdentifier(font)] = (font, id)
        return id
    }

    // MARK: A frame's misses

    /// Text asked for from now on comes back empty if it isn't laid out yet,
    /// and is noted for `layOutCollectedMisses()`.
    func beginCollectingMisses() {
        misses = [:]
    }

    /// Lays out the text noted since `beginCollectingMisses()`, on all cores
    /// when there is much of it, and stops collecting.
    /// - Returns: Whether there was any (the frame must be built again).
    func layOutCollectedMisses() -> Bool {
        guard let misses, !misses.isEmpty else {
            self.misses = nil
            return false
        }
        self.misses = nil
        let requests = Array(misses.values)
        var lines = [NGTextEngine.LaidOut](repeating: NGTextEngine.LaidOut(), count: requests.count)
        if requests.count < 8 {
            for (index, request) in requests.enumerated() {
                lines[index] = Self.layOut(request)
            }
        } else {
            let input = NGUncheckedSendable(requests)
            lines.withUnsafeMutableBufferPointer { buffer in
                let output = NGUncheckedSendable(buffer)
                let chunks = min(requests.count, ProcessInfo.processInfo.activeProcessorCount * 2)
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    for index in stride(from: chunk, to: input.value.count, by: chunks) {
                        output.value[index] = Self.layOut(input.value[index])
                    }
                }
            }
        }
        for (index, request) in requests.enumerated() {
            insert(lines[index], for: request, fontID: fontID(of: request.style.font))
        }
        return true
    }

    private nonisolated static func layOut(_ request: Request) -> NGTextEngine.LaidOut {
        NGTextEngine.layOut(request.text, style: request.style, width: request.width)
    }

    /// Caches a laid out line (and its truncated version) and returns the
    /// one for the request's width.
    @discardableResult
    private func insert(_ laidOut: NGTextEngine.LaidOut, for request: Request, fontID: Int) -> NGShapedText {
        let fullKey = Key(text: request.text, font: fontID, width: Int.max)
        let full = cache[fullKey] ?? engine.shaped(laidOut.full)
        insert(full, for: fullKey)
        guard let truncated = laidOut.truncated else { return full }
        let shapedTruncated = engine.shaped(truncated)
        insert(shapedTruncated, for: Key(text: request.text, font: fontID, width: Int((request.width * 4).rounded(.down))))
        return shapedTruncated
    }

    private func insert(_ shaped: NGShapedText, for key: Key) {
        guard cache.updateValue(shaped, forKey: key) == nil else { return }
        order.append(key)
        while cache.count > limit, orderStart < order.count {
            cache[order[orderStart]] = nil
            orderStart += 1
        }
        if orderStart > 4096, orderStart * 2 > order.count {
            order.removeFirst(orderStart)
            orderStart = 0
        }
    }
}
