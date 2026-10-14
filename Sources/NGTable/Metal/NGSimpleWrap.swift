import CoreGraphics

// Wrapping simple text without Core Text. Core Text's typesetter finds line
// breaks at about 30 µs a line of a log message, and no faster on more
// threads: a million wrapped rows took half a minute to measure. Text of
// simple characters (`NGSimpleText.characters`, and the colon: its
// glyph between digits differs by a hair, which only moves a break by that
// hair) is wrapped here from the glyph advances and pair kerning learned
// from Core Text (`NGSimpleMetricsStore`): breaks after spaces (which hang past the width)
// and after hyphens and dashes before a letter, and inside a word only when
// it is wider than a line. Drawing (`shapeLines`) and measuring rows use the
// same breaks, so a row is as high as its drawn lines whatever Core Text
// would have chosen; for plain words and spaces the breaks are Core Text's.

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
        unit == 0x3A || NGSimpleText.isSimple(unit)
    }

    private static func breaksAfter(_ unit: UInt16) -> Bool {
        unit == 0x2D || unit == 0x2010 || unit == 0x2013 || unit == 0x2014
    }

    private static func isLetter(_ unit: UInt16) -> Bool {
        unit != 0x20 && !(0x30...0x39).contains(unit) && !breaksAfter(unit)
    }

    /// The lines simple text wraps onto in `width`, at most `maximumLines`.
    static func lines(of units: [UInt16], metrics: NGSimpleFontMetrics, width: CGFloat, maximumLines: Int) -> Lines {
        guard !units.isEmpty else { return .lines([]) }
        for unit in units {
            guard isWrappable(unit) else { return .notSimple }
            // A character another font draws.
            if metrics.glyphs[unit]?.glyph == 0 { return .notSimple }
        }
        var lines: [Range<Int>] = []
        var start = 0
        let count = units.count
        while start < count, lines.count < maximumLines {
            var x: CGFloat = 0
            // Where the line may end: after spaces, or after a hyphen.
            var lastBreak: Int?
            var end = count
            var index = start
            var previous: UInt16?
            while index < count {
                let unit = units[index]
                guard let advance = metrics.glyphs[unit]?.advance else { return .unknown }
                var kern: CGFloat = 0
                if let previous {
                    guard let known = metrics.kerning[UInt32(previous) << 16 | UInt32(unit)] else { return .unknown }
                    if !known.isNaN { kern = known }
                }
                let right = x + kern + advance
                if unit == 0x20 {
                    // Spaces hang past the width.
                    x = right
                    previous = unit
                    index += 1
                    lastBreak = index
                    continue
                }
                if right > width, index > start {
                    end = lastBreak ?? index
                    break
                }
                x = right
                previous = unit
                index += 1
                if breaksAfter(unit), index < count, isLetter(units[index]) { lastBreak = index }
            }
            if index >= count { end = count }
            if lines.count == maximumLines - 1, end < count {
                // The last line takes the rest (truncated when drawn).
                lines.append(start..<count)
                break
            }
            lines.append(start..<end)
            start = end
        }
        return .lines(lines)
    }
}
