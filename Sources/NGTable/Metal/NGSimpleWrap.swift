import CoreGraphics

// Wrapping simple text without Core Text. Core Text's typesetter finds line
// breaks at about 30 µs a line of a log message, and no faster on more
// threads: a million wrapped rows took half a minute to measure. Text of
// simple characters (`NGSimpleText.characters`) is wrapped here from the
// glyph advances and pair kerning learned from Core Text
// (`NGSimpleMetricsStore`), breaking where Unicode's line breaking rules
// (UAX #14) allow it for the classes of those characters: after spaces
// (which hang past the width), after hyphens, dashes and slashes (not before
// digits), between ideographs, kana and Hangul syllables but not before
// closing punctuation or after opening one; inside a word only when it is
// wider than a line. Drawing (`shapeLines`) and measuring rows use the same
// breaks, so a row is as high as its drawn lines; the tests check them
// against Core Text's.

enum NGSimpleWrap {
    enum Lines: Equatable {
        /// The lines, as ranges of UTF-16 units (the last one may hold the
        /// rest of the text, truncated when drawn).
        case lines([Range<Int>])
        /// Not simple text: Core Text wraps it.
        case notSimple
        /// A character or pair whose metrics aren't learned yet.
        case unknown
    }

    static func isWrappable(_ unit: UInt16) -> Bool {
        NGSimpleText.isSimple(unit)
    }

    /// Line breaking classes (UAX #14) of the simple characters.
    enum BreakClass: UInt8 {
        /// Letters and most symbols.
        case alphabetic
        case number
        case space
        /// No break on either side (no-break spaces, the non-breaking hyphen).
        case glue
        /// A break after it (hyphens, dashes, the ideographic space).
        case breakAfter
        case hyphen
        /// Em dash: a break on either side, not between two.
        case breakBoth
        /// Opening punctuation: no break after it.
        case open
        /// Closing punctuation: no break before it.
        case close
        case quotation
        /// "!" and "?": no break before them.
        case exclamation
        /// ",", ".", ":", ";": no break before them.
        case infixSeparator
        /// "/": no break before it, nor before digits after it.
        case symbol
        /// Currency signs, "+", "\\": kept with the number or word after them.
        case prefix
        /// "%", "°": kept with the number before them.
        case postfix
        /// Ideographs, kana, Hangul syllables: breaks between them.
        case ideographic
        /// Small kana, the prolonged sound mark, iteration marks: no break before them.
        case nonStarter
    }

    /// Every character's class, looked up (one load per character).
    private static let classes: [BreakClass] = (0...0xFFFF).map { classify(UInt16($0)) }

    static func breakClass(_ unit: UInt16) -> BreakClass { classes[Int(unit)] }

    private static func classify(_ unit: UInt16) -> BreakClass {
        switch unit {
        case 0x20: return .space
        case 0x30...0x39: return .number
        case 0xA0, 0x202F, 0x2011, 0x2007: return .glue
        case 0x2D: return .hyphen
        case 0x2010, 0x2012, 0x2013, 0x7C, 0x3000: return .breakAfter
        case 0x2014: return .breakBoth
        case 0x28, 0x5B, 0x7B, 0xA1, 0xBF, 0x201A, 0x201E: return .open
        case 0x29, 0x5D, 0x7D: return .close
        case 0x22, 0x27, 0xAB, 0xBB, 0x2018, 0x2019, 0x201B...0x201D, 0x201F, 0x2039, 0x203A: return .quotation
        case 0x21, 0x3F: return .exclamation
        case 0x2C, 0x2E, 0x3A, 0x3B: return .infixSeparator
        case 0x2F: return .symbol
        case 0x24, 0x2B, 0x5C, 0xA3, 0xA5, 0x20A0...0x20C0, 0x2116: return .prefix
        case 0x25, 0xA2, 0xB0, 0x2030, 0x2031: return .postfix
        // CJK punctuation.
        case 0x3001, 0x3002: return .close
        case 0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014, 0x3016, 0x3018, 0x301A: return .open
        case 0x3009, 0x300B, 0x300D, 0x300F, 0x3011, 0x3015, 0x3017, 0x3019, 0x301B: return .close
        case 0x3005, 0x301C, 0x303B, 0x309D, 0x309E, 0x30FB, 0x30FC, 0x30FD, 0x30FE: return .nonStarter
        // Small kana.
        case 0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3063, 0x3083, 0x3085, 0x3087, 0x308E, 0x3095, 0x3096,
             0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30C3, 0x30E3, 0x30E5, 0x30E7, 0x30EE, 0x30F5, 0x30F6: return .nonStarter
        // Full-width forms.
        case 0xFF08, 0xFF3B, 0xFF5B, 0xFF5F: return .open
        case 0xFF09, 0xFF0C, 0xFF0E, 0xFF3D, 0xFF5D, 0xFF60: return .close
        case 0xFF01, 0xFF1F: return .exclamation
        case 0xFF1A, 0xFF1B: return .nonStarter
        default:
            return NGSimpleText.isDrawnByFallback(unit) ? .ideographic : .alphabetic
        }
    }

    /// Whether a line may break between a character of class `before` and
    /// one of class `after` (UAX #14, for the simple characters' classes);
    /// `beforeSpaces` is the class before the spaces `before` may be, and
    /// `beforeSpacesUnit` that character.
    static func breaks(before: BreakClass, after: BreakClass, beforeSpaces: BreakClass, beforeSpacesUnit: UInt16) -> Bool {
        // Most characters: inside a word, or a space.
        if after == .space || (before == .alphabetic && after == .alphabetic) { return false }
        switch after {
        case .space: return false                                                   // LB7
        case .close, .exclamation, .infixSeparator, .symbol: return false            // LB13
        default: break
        }
        if after == .glue, before != .space, before != .breakAfter, before != .hyphen { return false }   // LB12a
        if before == .glue { return false }                                          // LB12
        if beforeSpaces == .open { return false }                                    // LB14
        // (LB15, a quotation mark before opening punctuation: Core Text
        // follows Unicode 15's, which keeps only initial quotation marks there.)
        if beforeSpaces == .quotation, after == .open, [0xAB, 0x2018, 0x201B, 0x201C, 0x201F, 0x2039].contains(beforeSpacesUnit) {
            return false
        }
        if beforeSpaces == .close, after == .nonStarter { return false }             // LB16
        if beforeSpaces == .breakBoth, after == .breakBoth { return false }          // LB17
        if before == .space { return true }                                          // LB18
        if before == .quotation || after == .quotation { return false }              // LB19
        if after == .breakAfter || after == .hyphen || after == .nonStarter { return false }   // LB21
        switch (before, after) {
        case (.alphabetic, .alphabetic), (.alphabetic, .number), (.number, .alphabetic), (.number, .number): return false   // LB23, LB28
        case (.prefix, .alphabetic), (.postfix, .alphabetic), (.alphabetic, .prefix), (.alphabetic, .postfix): return false   // LB24
        case (.close, .postfix), (.close, .prefix), (.number, .postfix), (.number, .prefix),
             (.postfix, .open), (.prefix, .open), (.prefix, .number), (.postfix, .number),
             (.hyphen, .number), (.infixSeparator, .number), (.symbol, .number): return false   // LB25
        case (.prefix, .ideographic), (.ideographic, .postfix): return false         // LB27 (Hangul syllables)
        case (.infixSeparator, .alphabetic): return false                            // LB29
        case (.alphabetic, .open), (.number, .open), (.close, .alphabetic), (.close, .number): return false   // LB30
        default: return true                                                         // LB31
        }
    }

    /// The lines simple text wraps onto in `width`, at most `maximumLines`.
    static func lines(of units: [UInt16], metrics: NGSimpleFontMetrics, width: CGFloat, maximumLines: Int) -> Lines {
        guard !units.isEmpty else { return .lines([]) }
        guard units.allSatisfy(isWrappable) else { return .notSimple }
        var lines: [Range<Int>] = []
        var start = 0
        let count = units.count
        // The classes around the next break, carried along the text.
        var before = BreakClass.alphabetic, beforeSpaces = BreakClass.alphabetic
        var beforeSpacesUnit: UInt16 = 0
        while start < count, lines.count < maximumLines {
            var resolver = NGSimpleFontMetrics.Resolver()
            var x: CGFloat = 0
            // Where the line may end last.
            var lastBreak: Int?
            var end = count
            var index = start
            var previous: (unit: UInt16, glyph: NGSimpleGlyph)?
            while index < count {
                let unit = units[index]
                let glyph: NGSimpleGlyph
                switch resolver.next(unit, in: metrics) {
                case .glyph(let resolved): glyph = resolved
                case .notSimple: return .notSimple
                case .unknown: return .unknown
                }
                let advance = glyph.advance
                var kern: CGFloat = 0
                // (Characters of fallback fonts aren't kerned.)
                if let previous, previous.glyph.font < 0, glyph.font < 0 {
                    guard let known = metrics.kerning[UInt32(previous.unit) << 16 | UInt32(unit)] else { return .unknown }
                    if !known.isNaN { kern = known }
                }
                let after = breakClass(unit)
                if index > start, breaks(before: before, after: after, beforeSpaces: beforeSpaces, beforeSpacesUnit: beforeSpacesUnit) {
                    lastBreak = index
                }
                let right = x + kern + advance
                // Spaces hang past the width.
                if unit != 0x20, right > width, index > start {
                    end = lastBreak ?? index
                    break
                }
                before = after
                if after != .space {
                    beforeSpaces = after
                    beforeSpacesUnit = unit
                }
                x = right
                previous = (unit, glyph)
                index += 1
            }
            if index >= count { end = count }
            if lines.count == maximumLines - 1, end < count {
                // The last line takes the rest (truncated when drawn).
                lines.append(start..<count)
                break
            }
            lines.append(start..<end)
            start = end
            // The classes before the new line's first character.
            if start < count, start > 0 {
                before = breakClass(units[start - 1])
                var scan = start - 1
                while scan > 0, breakClass(units[scan]) == .space { scan -= 1 }
                beforeSpaces = breakClass(units[scan])
                beforeSpacesUnit = units[scan]
            }
        }
        return .lines(lines)
    }
}
