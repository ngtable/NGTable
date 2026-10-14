import CoreGraphics
import CoreText
import Foundation
import os

// The table's text layout, usable from any thread. Core Text lays out what
// only a shaping engine does right (complex scripts, bidirectional text,
// combining marks, emoji sequences, ligatures, fallback fonts) and is asked
// once for each character's glyph and advance and each pair's kerning;
// lines of simple characters are then put together from those (`simpleLine`),
// truncated (`simpleTruncated`) and wrapped (NGSimpleWrap.swift) without it.
// What is learned is kept in stores that a lock guards only while they
// change: readers take a copy (a few retains) once per line, not per
// character. The caches of laid out text and the misses of a frame are the
// main actor's (`NGTextShaper`); the glyph bitmaps are the atlas's.

/// Text laid out: the glyphs (by font id, see `NGFontRegistry`) and their
/// pen positions.
struct NGShapedText: Sendable {
    struct Glyph: Sendable {
        let font: Int
        let glyph: CGGlyph
        /// From the start of the line, in points.
        let x: CGFloat
    }

    var glyphs: [Glyph] = []
    var width: CGFloat = 0
}

/// Fonts numbered for the keys of glyphs and laid out text (thread-safe).
final class NGFontRegistry: @unchecked Sendable {
    private struct State {
        var ids: [String: Int] = [:]
        var fonts: [CTFont] = []
        /// Fonts looked up last, by identity (kept, so their identity isn't reused).
        var recent: [(font: CTFont, id: Int)] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// A number for a font, to key glyphs by.
    func id(of font: CTFont) -> Int {
        // The table's few fonts are the same objects every time: found without
        // making their name. (Fallback fonts are new objects in every line.)
        if let id = state.withLockUnchecked({ state in state.recent.first { $0.font === font }?.id }) { return id }
        let identity = Self.identity(of: font)
        return state.withLockUnchecked { state in
            let id: Int
            if let known = state.ids[identity] {
                id = known
            } else {
                id = state.fonts.count
                state.ids[identity] = id
                state.fonts.append(font)
            }
            if state.recent.count == 16 { state.recent.removeFirst() }
            state.recent.append((font, id))
            return id
        }
    }

    func font(_ id: Int) -> CTFont {
        state.withLockUnchecked { $0.fonts[id] }
    }

    /// What tells fonts apart. Feature settings too: the monospaced digit
    /// system font has the system font's name and size. So do variations (a
    /// weight between styles) and a matrix (a skew).
    private static func identity(of font: CTFont) -> String {
        let features = (CTFontCopyFeatureSettings(font) as? [Any]).map { "\($0)" } ?? ""
        let variation = (CTFontCopyVariation(font) as? [AnyHashable: Any]).map { variation in
            variation.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        } ?? ""
        let matrix = CTFontGetMatrix(font)
        let skew = matrix.isIdentity ? "" : "\(matrix.a),\(matrix.b),\(matrix.c),\(matrix.d)"
        return "\(CTFontCopyPostScriptName(font) as String) \(CTFontGetSize(font)) \(features) \(variation) \(skew)"
    }
}

/// A character's glyph and advance as Core Text lays it out alone; glyph 0:
/// it isn't simple (a font draws it that isn't taken, or it takes more glyphs).
struct NGSimpleGlyph: Sendable {
    let glyph: CGGlyph
    let advance: CGFloat
    /// The id of the fallback font that draws it (CJK, kana, Hangul), or -1
    /// for the line's font.
    var font = -1
}

/// What lines of a font's simple characters are made of, as learned so far.
struct NGSimpleFontMetrics: Sendable {
    var glyphs: [UInt16: NGSimpleGlyph] = [:]
    /// By pair (`first << 16 | second`): how Core Text kerns it laid out as
    /// its two glyphs; NaN for a pair it lays out otherwise (a ligature, a
    /// contextual form).
    var kerning: [UInt32: CGFloat] = [:]
    /// The glyph of a colon by its neighbors (`previous << 16 | next`, 0 for
    /// none): the system font raises it between digits and capitals ("12:30",
    /// "LT:7") with the plain colon's advance and kerning. 0: Core Text lays
    /// that colon out otherwise.
    var colons: [UInt32: CGGlyph] = [:]

    static func colonKey(_ previous: UInt16?, _ next: UInt16?) -> UInt32 {
        UInt32(previous ?? 0) << 16 | UInt32(next ?? 0)
    }

    /// Characters in the fallback font of the characters before them (by
    /// `fontID << 16 | unit`; glyph 0: that font has none).
    var inFallback: [UInt64: NGSimpleGlyph] = [:]

    static func fallbackKey(_ fontID: Int, _ unit: UInt16) -> UInt64 { UInt64(fontID) << 16 | UInt64(unit) }

    enum Resolution {
        case glyphs([NGSimpleGlyph])
        case notSimple
        /// A character, or a character in a fallback font, not learned yet.
        case unknown(fallback: (font: Int, unit: UInt16)?)
    }

    /// Each character's glyph as Core Text draws it in the line, one after
    /// another (no array of them): characters the line's font lacks take
    /// the fallback font of the characters before them while it has them
    /// (Core Text picks one font for as many of them in a row as it can),
    /// otherwise their own. Lines with Hangul and other CJK characters
    /// aren't simple: Core Text draws ideographs near Hangul with a Korean
    /// font, looking ahead too.
    struct Resolver {
        enum Step {
            case glyph(NGSimpleGlyph)
            case notSimple
            /// A character, or a character in a fallback font, not learned yet.
            case unknown(fallback: (font: Int, unit: UInt16)?)
        }

        // (The metrics come with each character: a copy of them here would
        // retain their tables for every line, from every thread at once.)
        private var current = -1
        private var hasHangul = false, hasOtherCJK = false

        mutating func next(_ unit: UInt16, in metrics: NGSimpleFontMetrics) -> Step {
            guard let glyph = metrics.glyphs[unit] else { return .unknown(fallback: nil) }
            guard glyph.glyph != 0 else { return .notSimple }
            guard glyph.font >= 0 else {
                current = -1
                return .glyph(glyph)
            }
            if (0xAC00...0xD7A3).contains(unit) { hasHangul = true } else { hasOtherCJK = true }
            if hasHangul, hasOtherCJK { return .notSimple }
            if current >= 0, current != glyph.font {
                guard let other = metrics.inFallback[NGSimpleFontMetrics.fallbackKey(current, unit)] else {
                    return .unknown(fallback: (current, unit))
                }
                if other.glyph != 0 { return .glyph(other) }
            }
            current = glyph.font
            return .glyph(glyph)
        }
    }

    /// Whether the line resolves; the first fallback glyph to learn if not.
    func resolves(_ units: [UInt16]) -> Resolver.Step {
        var resolver = Resolver()
        for unit in units {
            let step = resolver.next(unit, in: self)
            guard case .glyph = step else { return step }
        }
        return .glyph(NGSimpleGlyph(glyph: 1, advance: 0))
    }

    /// How a pair is kerned (`nil`: not learned; NaN: laid out otherwise).
    /// Characters of fallback fonts aren't kerned: Core Text kerns neither
    /// across fonts nor CJK text.
    func kerning(_ first: UInt16, _ second: UInt16) -> CGFloat? {
        if (glyphs[first]?.font ?? -1) >= 0 || (glyphs[second]?.font ?? -1) >= 0 { return 0 }
        return kerning[UInt32(first) << 16 | UInt32(second)]
    }
}

/// Simple characters: scripts laid out a character at a time.
enum NGSimpleText {
    /// Characters simple lines take: one glyph each, kerned by pairs,
    /// without combining marks, which Core Text positions on the letter
    /// before. The colon too: between digits the system font raises it (a
    /// contextual form, learned once per font). CJK, kana and Hangul
    /// syllables are drawn by the fallback font Core Text picks for each
    /// (learned once), not kerned. Other characters the font has no glyph
    /// for still go to Core Text.
    static let characters: [ClosedRange<UInt16>] = fallbackCharacters + [
        0x0020...0x007E,                    // ASCII.
        0x00A0...0x00AC, 0x00AE...0x024F,   // Latin-1 (no soft hyphen), Latin Extended-A and -B.
        0x0386...0x0386, 0x0388...0x03CE,   // Greek.
        0x0400...0x0482, 0x048A...0x052F,   // Cyrillic without its combining marks.
        0x2010...0x2027, 0x2030...0x2043,   // Punctuation (up to the fraction slash).
        0x202F...0x202F, 0x20A0...0x20C0,   // Narrow no-break space, currencies.
        0x2116...0x2116, 0x2122...0x2122, 0x2190...0x2193, 0x2212...0x2212,   // №, ™, arrows, minus.
    ]

    /// Characters drawn by a fallback font, one glyph each: CJK punctuation,
    /// kana, the unified ideographs, Hangul syllables, full-width forms. Not
    /// the rare kana (ゔ, ゕ, ヷ…) and ideographs (extension A, compatibility),
    /// which other fallback fonts draw, switched to by rules of Core Text's own.
    static let fallbackCharacters: [ClosedRange<UInt16>] = [
        0x3000...0x303F, 0x3041...0x3093, 0x309D...0x309E,   // CJK punctuation, hiragana.
        0x30A1...0x30F6, 0x30FB...0x30FE,                    // Katakana.
        0x4E00...0x9FFF,                                     // Ideographs.
        0xAC00...0xD7A3,                                     // Hangul syllables.
        0xFF01...0xFF60, 0xFFE0...0xFFE6,                    // Full-width forms.
    ]

    private static let fallbackTable: [Bool] = {
        var table = [Bool](repeating: false, count: 0x10000)
        for range in fallbackCharacters { for unit in range { table[Int(unit)] = true } }
        return table
    }()

    static func isDrawnByFallback(_ unit: UInt16) -> Bool { fallbackTable[Int(unit)] }

    /// `characters` as a lookup table (one load per character).
    private static let table: [Bool] = {
        var table = [Bool](repeating: false, count: 0x10000)
        for range in characters { for unit in range { table[Int(unit)] = true } }
        return table
    }()

    static func isSimple(_ unit: UInt16) -> Bool {
        Int(unit) < table.count && table[Int(unit)]
    }

    /// The neighbors of the character at `index`, as a colon's key.
    static func colonKey(_ units: [UInt16], at index: Int) -> UInt32 {
        NGSimpleFontMetrics.colonKey(index > 0 ? units[index - 1] : nil, index + 1 < units.count ? units[index + 1] : nil)
    }

    /// Spaces Core Text drops before an ellipsis.
    static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0xA0 || unit == 0x202F
    }
}

/// The simple-text metrics of every font, learned from Core Text (thread-safe).
final class NGSimpleMetricsStore: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(uncheckedState: [Int: NGSimpleFontMetrics]())
    /// The ids of fallback fonts.
    private let fonts: NGFontRegistry

    init(fonts: NGFontRegistry) {
        self.fonts = fonts
    }

    /// What has been learned of a font.
    func metrics(of fontID: Int) -> NGSimpleFontMetrics {
        state.withLockUnchecked { $0[fontID] ?? NGSimpleFontMetrics() }
    }

    /// The metrics of a font after learning the characters of `units` and
    /// (with `pairs`) each pair of neighbors it doesn't know yet. Stops at a
    /// character the font has no glyph for: such text isn't simple.
    func learning(_ units: some Collection<UInt16>, pairs: Bool = true, font: CTFont, fontID: Int) -> NGSimpleFontMetrics {
        let known = metrics(of: fontID)
        var glyphs: [UInt16: NGSimpleGlyph] = [:]
        var kerning: [UInt32: CGFloat] = [:]
        var previous: (unit: UInt16, glyph: NGSimpleGlyph)?
        for unit in units {
            let glyph: NGSimpleGlyph
            if let found = known.glyphs[unit] ?? glyphs[unit] {
                glyph = found
            } else {
                glyph = self.glyph(of: unit, font: font)
                glyphs[unit] = glyph
            }
            guard glyph.glyph != 0 else { break }
            if pairs, let previous, previous.glyph.font < 0, glyph.font < 0 {
                let pair = UInt32(previous.unit) << 16 | UInt32(unit)
                if known.kerning[pair] == nil, kerning[pair] == nil {
                    kerning[pair] = Self.kerning(previous.unit, unit, first: previous.glyph, second: glyph, font: font)
                }
            }
            previous = (unit, glyph)
        }
        // Colons by their neighbors.
        var colons: [UInt32: CGGlyph] = [:]
        let array = Array(units)
        for index in array.indices where array[index] == 0x3A {
            let key = NGSimpleText.colonKey(array, at: index)
            guard known.colons[key] == nil, colons[key] == nil else { continue }
            colons[key] = Self.colon(after: index > 0 ? array[index - 1] : nil, before: index + 1 < array.count ? array[index + 1] : nil, font: font)
        }
        // Characters in the fallback fonts of the characters before them.
        var inFallback: [UInt64: NGSimpleGlyph] = [:]
        var resolving = known
        resolving.glyphs.merge(glyphs) { old, _ in old }
        while case .unknown(let fallback?) = resolving.resolves(array) {
            let glyph = self.glyph(of: fallback.unit, in: fallback.font)
            let key = NGSimpleFontMetrics.fallbackKey(fallback.font, fallback.unit)
            inFallback[key] = glyph
            resolving.inFallback[key] = glyph
        }
        guard !glyphs.isEmpty || !kerning.isEmpty || !colons.isEmpty || !inFallback.isEmpty else { return known }
        return state.withLockUnchecked { all in
            var metrics = all[fontID] ?? NGSimpleFontMetrics()
            metrics.glyphs.merge(glyphs) { old, _ in old }
            metrics.kerning.merge(kerning) { old, _ in old }
            metrics.colons.merge(colons) { old, _ in old }
            metrics.inFallback.merge(inFallback) { old, _ in old }
            all[fontID] = metrics
            return metrics
        }
    }

    /// A character's glyph and advance as Core Text lays it out alone (with
    /// the font's features, e.g. tabular digits, which the character map
    /// doesn't apply).
    private func glyph(of unit: UInt16, font: CTFont) -> NGSimpleGlyph {
        let found = Self.glyph(of: unit, font: font)
        guard found.glyph != 0, let fallback = found.fallback else { return NGSimpleGlyph(glyph: found.glyph, advance: found.advance) }
        // Another font draws it: taken for the characters fallback fonts draw alike.
        guard NGSimpleText.isDrawnByFallback(unit) else { return NGSimpleGlyph(glyph: 0, advance: found.advance) }
        return NGSimpleGlyph(glyph: found.glyph, advance: found.advance, font: fonts.id(of: fallback))
    }

    /// A character's glyph and advance in a fallback font (glyph 0: it has none).
    private func glyph(of unit: UInt16, in fontID: Int) -> NGSimpleGlyph {
        let font = fonts.font(fontID)
        var character = unit
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else { return NGSimpleGlyph(glyph: 0, advance: 0) }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return NGSimpleGlyph(glyph: glyph, advance: advance.width, font: fontID)
    }

    /// One glyph, of this font or of the fallback font Core Text picks
    /// (glyph 0: more glyphs or runs).
    private static func glyph(of unit: UInt16, font: CTFont) -> (glyph: CGGlyph, advance: CGFloat, fallback: CTFont?) {
        let text = String(utf16CodeUnits: [unit], count: 1)
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary))
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard runs.count == 1, CTRunGetGlyphCount(runs[0]) == 1,
              let runFont = (CTRunGetAttributes(runs[0]) as NSDictionary)[kCTFontAttributeName] else { return (0, advance, nil) }
        var glyph: CGGlyph = 0
        CTRunGetGlyphs(runs[0], CFRange(location: 0, length: 1), &glyph)
        let fallback = CFEqual(runFont as CFTypeRef, font) ? nil : (runFont as! CTFont)
        return (glyph, advance, fallback)
    }

    /// The glyph Core Text draws a colon with between two characters (or at
    /// an end), if it keeps the plain colon's advance and kerning and the
    /// neighbors' glyphs (0: it doesn't).
    private static func colon(after previous: UInt16?, before next: UInt16?, font: CTFont) -> CGGlyph {
        func own(_ unit: UInt16) -> NGSimpleGlyph {
            let found = glyph(of: unit, font: font)
            return NGSimpleGlyph(glyph: found.fallback == nil ? found.glyph : 0, advance: found.advance)
        }
        let plain = own(0x3A)
        let neighbors = [previous, next].map { $0.map(own) }
        guard plain.glyph != 0, neighbors.allSatisfy({ $0 == nil || $0!.glyph != 0 }) else { return 0 }
        let units = [previous, 0x3A, next].compactMap { $0 }
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, String(utf16CodeUnits: units, count: units.count) as CFString,
                                                                             [kCTFontAttributeName: font] as CFDictionary))
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        guard runs.count == 1, CTRunGetGlyphCount(runs[0]) == units.count else { return 0 }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        var positions = [CGPoint](repeating: .zero, count: units.count)
        CTRunGetGlyphs(runs[0], CFRange(location: 0, length: units.count), &glyphs)
        CTRunGetPositions(runs[0], CFRange(location: 0, length: units.count), &positions)
        let colon = previous == nil ? 0 : 1
        var x: CGFloat = 0
        if let previous, let before = neighbors[0] {
            let kern = kerning(previous, 0x3A, first: before, second: plain, font: font)
            guard glyphs[0] == before.glyph, !kern.isNaN else { return 0 }
            x = before.advance + kern
        }
        guard abs(positions[colon].x - x) < 0.0001 else { return 0 }
        if let next, let after = neighbors[1] {
            let kern = kerning(0x3A, next, first: plain, second: after, font: font)
            guard glyphs[colon + 1] == after.glyph, !kern.isNaN, abs(positions[colon + 1].x - (x + plain.advance + kern)) < 0.0001 else { return 0 }
        }
        return glyphs[colon]
    }

    /// How Core Text kerns a pair laid out as its two glyphs (NaN: it lays
    /// the pair out otherwise).
    private static func kerning(_ first: UInt16, _ second: UInt16, first a: NGSimpleGlyph, second b: NGSimpleGlyph, font: CTFont) -> CGFloat {
        let text = String(utf16CodeUnits: [first, second], count: 2)
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary))
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        guard runs.count == 1, CTRunGetGlyphCount(runs[0]) == 2 else { return .nan }
        var glyphs = [CGGlyph](repeating: 0, count: 2)
        var positions = [CGPoint](repeating: .zero, count: 2)
        CTRunGetGlyphs(runs[0], CFRange(location: 0, length: 2), &glyphs)
        CTRunGetPositions(runs[0], CFRange(location: 0, length: 2), &positions)
        let kern = positions[1].x - a.advance
        guard glyphs == [a.glyph, b.glyph], positions[0].x == 0,
              abs(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - (a.advance + b.advance + kern)) < 0.0001 else { return .nan }
        return kern
    }
}

/// What lines of one font are made with, made once: attributed strings
/// from a ready dictionary skip AppKit's attribute uniquing, a lock all
/// threads would wait for.
final class NGTextStyle: @unchecked Sendable {
    let font: CTFont
    let attributes: CFDictionary
    let ellipsis: CTLine

    init(font: CTFont) {
        self.font = font
        attributes = [kCTFontAttributeName: font] as CFDictionary
        ellipsis = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "…" as CFString, attributes))
    }
}

/// Lays text out from any thread (see the top of this file). One per
/// renderer, shared by its shaper and its atlas.
final class NGTextEngine: Sendable {
    let fonts: NGFontRegistry
    let metrics: NGSimpleMetricsStore
    private let styles = OSAllocatedUnfairLock(uncheckedState: [Int: NGTextStyle]())

    init(fonts: NGFontRegistry = NGFontRegistry()) {
        self.fonts = fonts
        metrics = NGSimpleMetricsStore(fonts: fonts)
    }

    func style(of font: CTFont, id: Int) -> NGTextStyle {
        if let style = styles.withLockUnchecked({ $0[id] }) { return style }
        let style = NGTextStyle(font: font)
        return styles.withLockUnchecked { styles in
            if let made = styles[id] { return made }
            styles[id] = style
            return style
        }
    }

    // MARK: Simple lines

    /// A line of simple characters put together from their advances and
    /// kerning, or `nil` if it isn't simple (Core Text lays it out).
    func simpleLine(_ units: [UInt16], font: CTFont, fontID: Int) -> NGShapedText? {
        guard !units.isEmpty, units.count <= 256, units.allSatisfy(NGSimpleText.isSimple) else { return nil }
        let known = metrics.metrics(of: fontID)
        if let line = Self.simpleLine(units, fontID: fontID, metrics: known) { return line }
        // Characters or pairs not learned yet (or a line that isn't simple).
        return Self.simpleLine(units, fontID: fontID, metrics: metrics.learning(units, font: font, fontID: fontID))
    }

    private static func simpleLine(_ units: [UInt16], fontID: Int, metrics: NGSimpleFontMetrics) -> NGShapedText? {
        var resolver = NGSimpleFontMetrics.Resolver()
        var shaped = NGShapedText()
        shaped.glyphs.reserveCapacity(units.count)
        var x: CGFloat = 0
        var previous: UInt16?
        for (index, unit) in units.enumerated() {
            guard case .glyph(let glyph) = resolver.next(unit, in: metrics) else { return nil }
            if let previous {
                guard let kerning = metrics.kerning(previous, unit), !kerning.isNaN else { return nil }
                x += kerning
            }
            var drawn = glyph.glyph
            if unit == 0x3A {
                guard let colon = metrics.colons[NGSimpleText.colonKey(units, at: index)], colon != 0 else { return nil }
                drawn = colon
            }
            shaped.glyphs.append(.init(font: glyph.font >= 0 ? glyph.font : fontID, glyph: drawn, x: x))
            x += glyph.advance
            previous = unit
        }
        shaped.width = x
        return shaped
    }

    /// A simple line truncated with "…" to `width` like Core Text truncates
    /// its end: the most characters for which the ellipsis, put where the
    /// next character starts in the whole line (kerned to it, not to the
    /// ellipsis), fits; spaces before the ellipsis go. `nil` if the result
    /// can't be told without Core Text.
    func simpleTruncated(_ full: NGShapedText, of units: [UInt16], font: CTFont, fontID: Int, width: CGFloat) -> NGShapedText? {
        guard full.glyphs.count == units.count, units.allSatisfy(NGSimpleText.isSimple) else { return nil }
        var known = metrics.metrics(of: fontID)
        if known.glyphs[0x2026] == nil { known = metrics.learning([0x2026], pairs: false, font: font, fontID: fontID) }
        guard let ellipsis = known.glyphs[0x2026], ellipsis.glyph != 0 else { return nil }
        // Narrower than the ellipsis: nothing, whatever would fit.
        guard width >= ellipsis.advance else { return NGShapedText() }
        // Spaces at the end hang: they don't count for what fits, and a line
        // that fits without them loses them instead of being truncated.
        var trailing = units.count
        while trailing > 0, NGSimpleText.isSpace(units[trailing - 1]) { trailing -= 1 }
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
        while kept > 0, NGSimpleText.isSpace(units[kept - 1]) { kept -= 1 }
        let x = full.glyphs[kept].x
        var shaped = NGShapedText()
        shaped.glyphs = Array(full.glyphs.prefix(kept))
        // (Core Text keeps the whole line's glyphs: a colon raised between
        // digits stays raised before the ellipsis.)
        shaped.glyphs.append(.init(font: fontID, glyph: ellipsis.glyph, x: x))
        shaped.width = x + ellipsis.advance
        return shaped
    }

    // MARK: Core Text

    /// A line as Core Text laid it out, before its fonts get ids.
    struct Line {
        var width: CGFloat = 0
        var runs: [(font: CTFont, glyphs: [CGGlyph], x: [CGFloat])] = []
    }

    /// The whole line, and the truncated one if it doesn't fit its width.
    struct LaidOut {
        var full = Line()
        var truncated: Line?
    }

    /// Core Text's layout of a line, truncated if it doesn't fit.
    static func layOut(_ text: String, style: NGTextStyle, width: CGFloat) -> LaidOut {
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, style.attributes))
        var laidOut = LaidOut(full: runs(of: line, font: style.font))
        if laidOut.full.width > width {
            // A line too narrow even for "…" is empty.
            laidOut.truncated = CTLineCreateTruncatedLine(line, Double(width), .end, style.ellipsis)
                .map { runs(of: $0, font: style.font) } ?? Line()
        }
        return laidOut
    }

    static func runs(of line: CTLine, font: CTFont) -> Line {
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

    /// Glyph runs with font ids.
    func shaped(_ line: Line) -> NGShapedText {
        var shaped = NGShapedText(width: line.width)
        shaped.glyphs.reserveCapacity(line.runs.reduce(0) { $0 + $1.glyphs.count })
        for run in line.runs {
            let fontID = fonts.id(of: run.font)
            for index in run.glyphs.indices {
                shaped.glyphs.append(.init(font: fontID, glyph: run.glyphs[index], x: run.x[index]))
            }
        }
        return shaped
    }

    // MARK: Lines (without the shaper's caches)

    /// Text on one line, truncated with "…" to `width`.
    func shape(_ text: String, font: CTFont, width: CGFloat) -> NGShapedText {
        let fontID = fonts.id(of: font)
        let units = Array(text.utf16)
        if let full = simpleLine(units, font: font, fontID: fontID) {
            if width >= 100_000 || full.width <= width { return full }
            if let truncated = simpleTruncated(full, of: units, font: font, fontID: fontID, width: width) { return truncated }
        }
        let laidOut = Self.layOut(text, style: style(of: font, id: fontID), width: width)
        return shaped(laidOut.truncated ?? laidOut.full)
    }

    /// Wraps simple text, learning the advances and kerning it needs first:
    /// `.notSimple` for text Core Text wraps.
    func simpleWrap(_ units: [UInt16], font: CTFont, fontID: Int, width: CGFloat, maximumLines: Int) -> NGSimpleWrap.Lines {
        guard units.allSatisfy(NGSimpleWrap.isWrappable) else { return .notSimple }
        let lines = NGSimpleWrap.lines(of: units, metrics: metrics.metrics(of: fontID), width: width, maximumLines: maximumLines)
        guard lines == .unknown else { return lines }
        return NGSimpleWrap.lines(of: units, metrics: metrics.learning(units, font: font, fontID: fontID), width: width, maximumLines: maximumLines)
    }

    /// How many lines text wraps onto (as `NGTextShaper.shapeLines` draws it).
    func lineCount(of text: String, font: CTFont, width: CGFloat, maximumLines: Int) -> Int {
        let fontID = fonts.id(of: font)
        var known = metrics.metrics(of: fontID)
        return lineCount(of: text, font: font, fontID: fontID, width: width, maximumLines: maximumLines, metrics: &known)
    }

    /// The same with a copy of the font's metrics the caller keeps (taking
    /// one per text from many threads costs more than counting): updated
    /// when the text needs metrics not learned yet.
    func lineCount(of text: String, font: CTFont, fontID: Int, width: CGFloat, maximumLines: Int, metrics known: inout NGSimpleFontMetrics) -> Int {
        guard maximumLines > 1, !text.isEmpty else { return 1 }
        let units = Array(text.utf16)
        var lines = NGSimpleWrap.lines(of: units, metrics: known, width: width, maximumLines: maximumLines)
        if lines == .unknown {
            known = metrics.learning(units, font: font, fontID: fontID)
            lines = NGSimpleWrap.lines(of: units, metrics: known, width: width, maximumLines: maximumLines)
        }
        if case .lines(let ranges) = lines { return max(1, ranges.count) }
        return Self.coreTextLineCount(of: text, attributes: style(of: font, id: fontID).attributes, width: width, maximumLines: maximumLines)
    }

    /// How many lines Core Text's typesetter wraps text onto.
    static func coreTextLineCount(of text: String, attributes: CFDictionary, width: CGFloat, maximumLines: Int) -> Int {
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

    /// Text wrapped by Core Text's typesetter into at most `maximumLines`
    /// lines of `width`, the last one truncated with "…" if text remains.
    func coreTextLines(_ text: String, font: CTFont, fontID: Int, width: CGFloat, maximumLines: Int) -> [NGShapedText] {
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
        return lines
    }
}
