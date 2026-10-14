#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Metal

// Text drawn on the GPU from a glyph atlas. Core Text still lays the text out
// (kerning, ligatures, fallback fonts, truncation); each glyph is rasterized
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
    /// Fonts by identity, numbered for the keys (CTFont isn't cheap to hash).
    private var fontIDs: [String: Int] = [:]
    private var fonts: [CTFont] = []
    // Shelf packing: glyphs fill rows left to right; a row is as tall as its tallest glyph.
    private var cursorX = 0, cursorY = 0, shelfHeight = 0
    /// Glyphs rasterized so far (for tests and statistics).
    private(set) var rasterizedCount = 0
    /// The atlas filled up and started over (glyphs are rasterized again).
    private(set) var resetCount = 0

    init?(device: MTLDevice, size: Int = 2048) {
        guard let texture = Self.makeTexture(device: device, size: size) else { return nil }
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
    func fontID(of font: CTFont) -> Int {
        // The table's few fonts are the same objects every time: found without
        // making their name. (Fallback fonts are new objects in every line.)
        if let recent = recentFonts.first(where: { $0.font === font }) { return recent.id }
        // Feature settings too: the monospaced digit system font has the
        // system font's name and size. So do variations (a weight between
        // styles) and a matrix (a skew).
        let features = (CTFontCopyFeatureSettings(font) as? [Any]).map { "\($0)" } ?? ""
        let variation = (CTFontCopyVariation(font) as? [AnyHashable: Any]).map { variation in
            variation.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        } ?? ""
        let matrix = CTFontGetMatrix(font)
        let skew = matrix.isIdentity ? "" : "\(matrix.a),\(matrix.b),\(matrix.c),\(matrix.d)"
        let identity = "\(CTFontCopyPostScriptName(font) as String) \(CTFontGetSize(font)) \(features) \(variation) \(skew)"
        let id: Int
        if let known = fontIDs[identity] {
            id = known
        } else {
            id = fonts.count
            fontIDs[identity] = id
            fonts.append(font)
        }
        if recentFonts.count == 16 { recentFonts.removeFirst() }
        recentFonts.append((font, id))
        return id
    }

    /// Fonts looked up last, by identity (kept, so their identity isn't reused).
    private var recentFonts: [(font: CTFont, id: Int)] = []

    func font(_ id: Int) -> CTFont { fonts[id] }

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
        guard let entry = rasterize(font: fonts[table.font], glyph: glyph, phase: phase, rise: table.rise, scale: table.scale) else {
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

/// Text laid out by Core Text: the glyphs and their pen positions.
struct NGShapedText {
    struct Glyph {
        let font: Int
        let glyph: CGGlyph
        /// From the start of the line, in points.
        let x: CGFloat
    }

    var glyphs: [Glyph] = []
    var width: CGFloat = 0
}

/// Lays text out with Core Text, truncated with "…" to a width, and keeps
/// recent results (the same values appear in many cells).
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

    private struct Request {
        let text: String
        let style: Style
        let width: CGFloat
    }

    /// What lines of one font are made with, made once: attributed strings
    /// from a ready dictionary skip AppKit's attribute uniquing, a lock all
    /// threads would wait for.
    private final class Style: @unchecked Sendable {
        let font: CTFont
        let attributes: CFDictionary
        let ellipsis: CTLine

        init(font: CTFont) {
            self.font = font
            attributes = [kCTFontAttributeName: font] as CFDictionary
            ellipsis = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "…" as CFString, attributes))
        }
    }

    private var styles: [Int: Style] = [:]

    private func style(of font: CTFont, id: Int) -> Style {
        if let style = styles[id] { return style }
        let style = Style(font: font)
        styles[id] = style
        return style
    }

    /// A line as Core Text laid it out, before its fonts get atlas ids.
    private struct Line {
        var width: CGFloat = 0
        var runs: [(font: CTFont, glyphs: [CGGlyph], x: [CGFloat])] = []
    }

    /// The whole line, and the truncated one if it doesn't fit its width.
    private struct LaidOut {
        var full = Line()
        var truncated: Line?
    }

    /// Text asked for during a collecting pass and not laid out yet.
    private var misses: [Key: Request]?
    /// Counts the misses, so callers can tell whether some text they asked for is missing.
    private(set) var missCount = 0

    private let atlas: NGGlyphAtlas
    private var cache: [Key: NGShapedText] = [:]
    private var order: [Key] = []
    private var orderStart = 0
    private let limit = 20_000

    init(atlas: NGGlyphAtlas) {
        self.atlas = atlas
    }

    func shape(_ text: String, font: CTFont, width: CGFloat) -> NGShapedText {
        let fontID = fontID(of: font)
        // The whole line first, under one key for every width: text that fits
        // is the same in every column. Only text that doesn't is truncated.
        let fullKey = Key(text: text, font: fontID, width: Int.max)
        var full = cache[fullKey]
        if full == nil, let simple = simpleLine(text, font: font, fontID: fontID) {
            insert(simple, for: fullKey)
            full = simple
        }
        if let full, width >= 100_000 || full.width <= width { return full }
        let key = Key(text: text, font: fontID, width: width < 100_000 ? Int((width * 4).rounded(.down)) : Int.max)
        if let full {
            if let truncated = cache[key] { return truncated }
            if let truncated = simpleTruncated(full, of: text, font: font, fontID: fontID, width: width) {
                insert(truncated, for: key)
                return truncated
            }
        }
        let request = Request(text: text, style: style(of: font, id: fontID), width: width)
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
        if case .lines(let ranges) = simpleWrap(units, font: font, fontID: fontID, width: width, maximumLines: maximumLines) {
            let lines = ranges.enumerated().map { index, range in
                var end = range.upperBound
                // Spaces at the end hang: not drawn, nor counted for the alignment.
                while end > range.lowerBound, units[end - 1] == 0x20 { end -= 1 }
                let line = String(utf16CodeUnits: Array(units[range.lowerBound..<end]), count: end - range.lowerBound)
                // The last line truncated if text remains; the others are
                // drawn whole (a colon's glyph may differ by a hair).
                let truncates = index == ranges.count - 1 && range.upperBound == units.count && index == maximumLines - 1
                return shape(line, font: font, width: truncates ? width : .greatestFiniteMagnitude)
            }
            if wrapped.count > 2_000 { wrapped.removeAll() }
            wrapped[key] = lines
            return lines
        }
        let style = style(of: font, id: fontID)
        let attributed = CFAttributedStringCreate(nil, text as CFString, style.attributes)!
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = CFAttributedStringGetLength(attributed)
        var lines: [NGShapedText] = []
        var start = 0
        while start < length, lines.count < maximumLines {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            if lines.count == maximumLines - 1, start + count < length {
                // The last line takes the rest, truncated.
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
                let line = CTLineCreateTruncatedLine(rest, Double(width), .end, style.ellipsis) ?? rest
                lines.append(shaped(Self.runs(of: line, font: font)))
                break
            }
            lines.append(shaped(Self.runs(of: CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)), font: font)))
            start += count
        }
        if wrapped.count > 2_000 { wrapped.removeAll() }
        wrapped[key] = lines
        return lines
    }

    /// Wraps simple text, learning the advances and kerning it needs first:
    /// `.notSimple` for text Core Text wraps.
    private func simpleWrap(_ units: [UInt16], font: CTFont, fontID: Int, width: CGFloat, maximumLines: Int) -> NGSimpleWrap.Lines {
        guard units.allSatisfy(NGSimpleWrap.isWrappable) else { return .notSimple }
        let simple = simpleFont(fontID)
        var previous: UInt16?
        for unit in units {
            guard glyph(of: unit, in: simple, font: font) != nil else { return .notSimple }
            if let previous { _ = kerning(previous, unit, in: simple, font: font) }
            previous = unit
        }
        return NGSimpleWrap.lines(of: units, metrics: simple.wrap, width: width, maximumLines: maximumLines)
    }

    /// What wrapping a font's simple text needs, as learned so far (for other threads).
    func wrapMetrics(of font: CTFont) -> NGWrapMetrics {
        simpleFont(fontID(of: font)).wrap
    }

    /// How many lines `shapeLines` wraps text onto, without laying out glyphs.
    func lineCount(of text: String, font: CTFont, width: CGFloat, maximumLines: Int) -> Int {
        guard maximumLines > 1, !text.isEmpty else { return 1 }
        let fontID = fontID(of: font)
        if case .lines(let ranges) = simpleWrap(Array(text.utf16), font: font, fontID: fontID, width: width, maximumLines: maximumLines) {
            return max(1, ranges.count)
        }
        return Self.lineCount(of: text, attributes: style(of: font, id: fontID).attributes, width: width, maximumLines: maximumLines)
    }

    /// The attributes `shapeLines` lays text of a font out with, for
    /// `lineCount(of:attributes:width:maximumLines:)` on other threads.
    func lineAttributes(of font: CTFont) -> NGUncheckedSendable<CFDictionary> {
        NGUncheckedSendable(style(of: font, id: fontID(of: font)).attributes)
    }

    /// How many lines Core Text's typesetter wraps text onto, as
    /// `shapeLines` does text that isn't simple (thread-safe).
    nonisolated static func lineCount(of text: String, attributes: CFDictionary, width: CGFloat, maximumLines: Int) -> Int {
        guard maximumLines > 1, !text.isEmpty else { return 1 }
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)!
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = CFAttributedStringGetLength(attributed)
        var lines = 0
        var start = 0
        while start < length, lines < maximumLines {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            lines += 1
            start += count
        }
        return max(1, lines)
    }

    // MARK: Simple lines

    /// Characters of simple lines: formatted numbers, and Latin and Cyrillic
    /// text with common punctuation. Lines of only these, in fonts that lay
    /// each pair out as its two glyphs (kerned or not), are their glyphs'
    /// advances and kerning added up: made without Core Text, whose line
    /// layout barely gets faster on more threads (about 8 µs a line).
    /// Characters Core Text may change by their context (the colon between
    /// digits, ligature-prone or combining marks) aren't simple.
    nonisolated static func isSimple(_ unit: UInt16) -> Bool {
        Int(unit) < simpleTable.count && simpleTable[Int(unit)]
    }

    /// `simpleCharacters` as a lookup table (one load per character).
    private nonisolated static let simpleTable: [Bool] = {
        var table = [Bool](repeating: false, count: Int(simpleCharacters.map(\.upperBound).max() ?? 0) + 1)
        for range in simpleCharacters { for unit in range { table[Int(unit)] = true } }
        return table
    }()

    /// Characters simple lines take: scripts laid out a character at a time
    /// (one glyph each, kerned by pairs), without combining marks, which
    /// Core Text positions on the letter before. The colon is left out: the
    /// system font raises it between digits (a contextual form, beyond a
    /// pair). Characters the font has no glyph for still go to Core Text.
    nonisolated static let simpleCharacters: [ClosedRange<UInt16>] = [
        0x0020...0x0039, 0x003B...0x007E,   // ASCII without the colon.
        0x00A0...0x00AC, 0x00AE...0x024F,   // Latin-1 (no soft hyphen), Latin Extended-A and -B.
        0x0386...0x0386, 0x0388...0x03CE,   // Greek.
        0x0400...0x0482, 0x048A...0x052F,   // Cyrillic without its combining marks.
        0x2010...0x2027, 0x2030...0x2043,   // Punctuation (up to the fraction slash).
        0x202F...0x202F, 0x20A0...0x20C0,   // Narrow no-break space, currencies.
        0x2116...0x2116, 0x2122...0x2122, 0x2190...0x2193, 0x2212...0x2212,   // №, ™, arrows, minus.
    ]

    /// What simple lines of a font are made of: each character's glyph and
    /// advance, and how Core Text lays out each pair: as just the two glyphs,
    /// kerned by some amount (no ligatures or contextual forms), checked once
    /// per pair; NaN for pairs it lays out otherwise.
    private final class SimpleFont {
        var glyphs: [UInt16: (glyph: CGGlyph, advance: CGFloat)] = [:]
        var kerning: [UInt32: CGFloat] = [:]
        /// The advances and kerning learned, for wrapping (see NGSimpleWrap.swift).
        var wrap = NGWrapMetrics()
    }

    private var simpleFonts: [Int: SimpleFont] = [:]
    /// Lines made without Core Text (for tests and statistics).
    private(set) var simpleLineCount = 0

    /// Core Text's layout of a line, truncated to `width` if it doesn't fit,
    /// bypassing the cache and the simple lines (for tests).
    func coreTextLine(_ text: String, font: CTFont, width: CGFloat = .greatestFiniteMagnitude) -> NGShapedText {
        let laidOut = Self.layOut(Request(text: text, style: Style(font: font), width: width))
        return shaped(laidOut.truncated ?? laidOut.full)
    }

    /// A simple line truncated to `width`, bypassing the cache (whose keys
    /// round widths to quarter points), or `nil` if it isn't simple (for tests).
    func simpleLine(_ text: String, font: CTFont, width: CGFloat) -> NGShapedText? {
        let fontID = fontID(of: font)
        guard let full = simpleLine(text, font: font, fontID: fontID) else { return nil }
        return full.width <= width ? full : simpleTruncated(full, of: text, font: font, fontID: fontID, width: width)
    }

    private func simpleFont(_ fontID: Int) -> SimpleFont {
        if let simple = simpleFonts[fontID] { return simple }
        let simple = SimpleFont()
        simpleFonts[fontID] = simple
        return simple
    }

    private func simpleLine(_ text: String, font: CTFont, fontID: Int) -> NGShapedText? {
        let units = text.utf16
        guard !units.isEmpty, units.count <= 256 else { return nil }
        for unit in units where !Self.isSimple(unit) { return nil }
        let simple = simpleFont(fontID)
        var shaped = NGShapedText()
        shaped.glyphs.reserveCapacity(units.count)
        var x: CGFloat = 0
        var previous: UInt16?
        for unit in units {
            guard let glyph = glyph(of: unit, in: simple, font: font) else { return nil }
            if let previous {
                let kerning = kerning(previous, unit, in: simple, font: font)
                guard !kerning.isNaN else { return nil }
                x += kerning
            }
            shaped.glyphs.append(.init(font: fontID, glyph: glyph.glyph, x: x))
            x += glyph.advance
            previous = unit
        }
        shaped.width = x
        simpleLineCount += 1
        return shaped
    }

    /// A simple line truncated with "…" to `width` like Core Text truncates
    /// its end: the most characters for which the ellipsis, put where the
    /// next character starts in the whole line (kerned to it, not to the
    /// ellipsis), fits; spaces before the ellipsis go. `nil` if the result
    /// can't be told without Core Text.
    private func simpleTruncated(_ full: NGShapedText, of text: String, font: CTFont, fontID: Int, width: CGFloat) -> NGShapedText? {
        let simple = simpleFont(fontID)
        let units = Array(text.utf16)
        guard let ellipsis = glyph(of: 0x2026, in: simple, font: font), full.glyphs.count == units.count else { return nil }
        for unit in units where !Self.isSimple(unit) { return nil }
        // Narrower than the ellipsis: nothing, whatever would fit.
        guard width >= ellipsis.advance else { return NGShapedText() }
        // Spaces at the end hang: they don't count for what fits, and a line
        // that fits without them loses them instead of being truncated.
        var trailing = units.count
        while trailing > 0, Self.isSpace(units[trailing - 1]) { trailing -= 1 }
        let hanging = trailing < units.count ? full.width - full.glyphs[trailing].x : 0
        if trailing > 0, trailing < units.count, full.glyphs[trailing].x <= width {
            var shaped = NGShapedText()
            shaped.glyphs = Array(full.glyphs.prefix(trailing))
            shaped.width = full.glyphs[trailing].x
            return shaped
        }
        // Core Text lets the ellipsis end up to 0.0002 past the width (measured on a
        // fine grid of widths around each cut).
        let available = width + hanging + 0.0002
        // Keeping `kept` characters puts the ellipsis where character `kept` starts.
        var kept = units.count - 1
        while kept > 0, full.glyphs[kept].x + ellipsis.advance > available { kept -= 1 }
        guard full.glyphs[kept].x + ellipsis.advance <= available else { return NGShapedText() }
        while kept > 0, Self.isSpace(units[kept - 1]) { kept -= 1 }
        let x = full.glyphs[kept].x
        var shaped = NGShapedText()
        shaped.glyphs = Array(full.glyphs.prefix(kept))
        shaped.glyphs.append(.init(font: fontID, glyph: ellipsis.glyph, x: x))
        shaped.width = x + ellipsis.advance
        return shaped
    }

    /// Spaces Core Text drops before an ellipsis.
    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0xA0 || unit == 0x202F
    }

    /// A character's glyph and advance as Core Text lays it out alone (with
    /// the font's features, e.g. tabular digits, which the character map
    /// doesn't apply).
    private func glyph(of unit: UInt16, in simple: SimpleFont, font: CTFont) -> (glyph: CGGlyph, advance: CGFloat)? {
        if let known = simple.glyphs[unit] { return known.glyph == 0 ? nil : known }
        let text = String(utf16CodeUnits: [unit], count: 1)
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary))
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        var glyph: CGGlyph = 0
        // One glyph of this font, or the character needs a fallback font or more glyphs.
        if runs.count == 1, CTRunGetGlyphCount(runs[0]) == 1,
           let runFont = (CTRunGetAttributes(runs[0]) as NSDictionary)[kCTFontAttributeName], CFEqual(runFont as CFTypeRef, font) {
            CTRunGetGlyphs(runs[0], CFRange(location: 0, length: 1), &glyph)
        }
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        simple.glyphs[unit] = (glyph, advance)
        if glyph == 0 { simple.wrap.missing.insert(unit) } else { simple.wrap.advances[unit] = advance }
        return glyph == 0 ? nil : (glyph, advance)
    }

    /// How Core Text kerns a pair laid out as its two glyphs (NaN: it lays
    /// the pair out otherwise), checked once per pair.
    private func kerning(_ first: UInt16, _ second: UInt16, in simple: SimpleFont, font: CTFont) -> CGFloat {
        let pair = UInt32(first) << 16 | UInt32(second)
        if let known = simple.kerning[pair] { return known }
        var kerning = CGFloat.nan
        if let a = glyph(of: first, in: simple, font: font), let b = glyph(of: second, in: simple, font: font) {
            let text = String(utf16CodeUnits: [first, second], count: 2)
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary))
            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            if runs.count == 1, CTRunGetGlyphCount(runs[0]) == 2 {
                var glyphs = [CGGlyph](repeating: 0, count: 2)
                var positions = [CGPoint](repeating: .zero, count: 2)
                CTRunGetGlyphs(runs[0], CFRange(location: 0, length: 2), &glyphs)
                CTRunGetPositions(runs[0], CFRange(location: 0, length: 2), &positions)
                let kern = positions[1].x - a.advance
                if glyphs == [a.glyph, b.glyph], positions[0].x == 0,
                   abs(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - (a.advance + b.advance + kern)) < 0.0001 {
                    kerning = kern
                }
            }
        }
        simple.kerning[pair] = kerning
        simple.wrap.kerning[pair] = kerning
        return kerning
    }

    /// The fonts the shaper is asked for are the same few objects every time:
    /// their ids, found by identity (kept, so the identities aren't reused).
    private var fontIDsByObject: [ObjectIdentifier: (font: CTFont, id: Int)] = [:]

    private func fontID(of font: CTFont) -> Int {
        if let known = fontIDsByObject[ObjectIdentifier(font)] { return known.id }
        let id = atlas.fontID(of: font)
        if fontIDsByObject.count > 64 { fontIDsByObject.removeAll() }
        fontIDsByObject[ObjectIdentifier(font)] = (font, id)
        return id
    }

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
        var lines = [LaidOut](repeating: LaidOut(), count: requests.count)
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

    /// Caches a laid out line (and its truncated version) and returns the
    /// one for the request's width.
    @discardableResult
    private func insert(_ laidOut: LaidOut, for request: Request, fontID: Int) -> NGShapedText {
        let fullKey = Key(text: request.text, font: fontID, width: Int.max)
        let full = cache[fullKey] ?? shaped(laidOut.full)
        insert(full, for: fullKey)
        guard let truncated = laidOut.truncated else { return full }
        let shapedTruncated = shaped(truncated)
        insert(shapedTruncated, for: Key(text: request.text, font: fontID, width: Int((request.width * 4).rounded(.down))))
        return shapedTruncated
    }

    /// Glyph runs with atlas font ids.
    private func shaped(_ line: Line) -> NGShapedText {
        var shaped = NGShapedText(width: line.width)
        shaped.glyphs.reserveCapacity(line.runs.reduce(0) { $0 + $1.glyphs.count })
        for run in line.runs {
            let fontID = atlas.fontID(of: run.font)
            for index in run.glyphs.indices {
                shaped.glyphs.append(.init(font: fontID, glyph: run.glyphs[index], x: run.x[index]))
            }
        }
        return shaped
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

    /// Core Text's layout of a line, truncated if it doesn't fit (thread-safe:
    /// called on worker threads).
    private nonisolated static func layOut(_ request: Request) -> LaidOut {
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, request.text as CFString, request.style.attributes))
        var laidOut = LaidOut(full: runs(of: line, font: request.style.font))
        if laidOut.full.width > request.width {
            // A line too narrow even for "…" is empty.
            laidOut.truncated = CTLineCreateTruncatedLine(line, Double(request.width), .end, request.style.ellipsis)
                .map { runs(of: $0, font: request.style.font) } ?? Line()
        }
        return laidOut
    }

    private nonisolated static func runs(of line: CTLine, font: CTFont) -> Line {
        var shaped = Line(width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            // Core Text picks fallback fonts for characters the font lacks.
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont? ?? font
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            shaped.runs.append((runFont, glyphs, positions.map(\.x)))
        }
        return shaped
    }
}
