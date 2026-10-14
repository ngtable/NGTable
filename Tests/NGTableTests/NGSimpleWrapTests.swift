#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Wrapping simple text without Core Text (NGSimpleWrap.swift): the breaks
/// Core Text makes for words and spaces, and the same lines for drawing,
/// measuring on the main actor and measuring on other threads.
@MainActor
@Suite("Simple wrapping")
struct NGSimpleWrapTests {
    static let words = ["request", "retried", "upstream", "timeout", "Ёлка", "сервер", "ответил", "медленно", "café", "Straße",
                        "a", "of", "the", "connection", "reset", "by", "peer", "42", "3.5", "(cache)", "miss,", "done."]

    func randomTexts(_ count: Int, seed: UInt64, extra: [String] = []) -> [String] {
        var generator = SplitMix(seed: seed)
        let pool = Self.words + extra
        return (0..<count).map { _ in
            (0..<(1 + Int(generator.next() % 24))).map { _ in pool[Int(generator.next() % UInt64(pool.count))] }.joined(separator: " ")
        }
    }

    func shaper() throws -> (NGTextShaper, CTFont) {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        return (try #require(table.metalRenderer?.shaper), table.metalStyle.textFont)
    }

    /// Words and spaces break where Core Text's typesetter breaks them.
    @Test func wordsBreakLikeCoreText() throws {
        let (shaper, font) = try shaper()
        let attributes = shaper.lineAttributes(of: font).value
        var differences: [String] = []
        for (index, text) in randomTexts(400, seed: 1).enumerated() {
            let width = CGFloat(40 + (index * 37) % 360) + 0.25 * CGFloat(index % 4)
            let simple = shaper.lineCount(of: text, font: font, width: width, maximumLines: .max)
            let coreText = NGTextShaper.lineCount(of: text, attributes: attributes, width: width, maximumLines: .max)
            if simple != coreText { differences.append("\(width): \(text) (\(simple) vs \(coreText))") }
        }
        #expect(differences.isEmpty, "\(differences.prefix(5))")
    }

    /// Drawing, measuring on the main actor and measuring on other threads
    /// count the same lines, whether the text is simple or not.
    @Test func drawingAndMeasuringAgree() async throws {
        let (shaper, font) = try shaper()
        let texts = randomTexts(300, seed: 2, extra: ["look-alike", "12:03:04", "a—b", "🌞", "東京", "x/y"])
        let lineHeight = NGLineHeights.height(of: font)
        for (index, text) in texts.enumerated() {
            let width = CGFloat(30 + (index * 53) % 300)
            let limit = index % 5 == 0 ? 3 : .max
            let drawn = shaper.shapeLines(text, font: font, width: width, maximumLines: limit).count
            #expect(shaper.lineCount(of: text, font: font, width: width, maximumLines: limit) == drawn, "\(text) at \(width)")
            let wrapped = NGWrappedText(text: text, font: font, width: width, lineLimit: limit, lineHeight: lineHeight)
            let engine = shaper.engine
            let measured = await Task.detached { NGTableView.height(of: [wrapped], rowHeight: 24, engine: engine) }.value
            #expect(measured == 24 + CGFloat(drawn - 1) * lineHeight, "\(text) at \(width)")
        }
    }

    /// Metrics not learned yet are told apart from text that isn't simple.
    @Test func unknownMetricsAndRules() throws {
        let units = Array("zebra quartz".utf16)
        #expect(NGSimpleWrap.lines(of: units, metrics: NGSimpleFontMetrics(), width: 100, maximumLines: .max) == .unknown)
        #expect(NGSimpleWrap.lines(of: Array("🌞 sun".utf16), metrics: NGSimpleFontMetrics(), width: 100, maximumLines: .max) == .notSimple)
        // A word wider than the line breaks inside it; spaces hang.
        var metrics = NGSimpleFontMetrics()
        for unit in Array("ab ".utf16) { metrics.glyphs[unit] = NGSimpleGlyph(glyph: 1, advance: 10) }
        for first in Array("ab ".utf16) { for second in Array("ab ".utf16) { metrics.kerning[UInt32(first) << 16 | UInt32(second)] = 0 } }
        #expect(NGSimpleWrap.lines(of: Array("aaaaa".utf16), metrics: metrics, width: 25, maximumLines: .max) == .lines([0..<2, 2..<4, 4..<5]))
        #expect(NGSimpleWrap.lines(of: Array("ab ab".utf16), metrics: metrics, width: 20, maximumLines: .max) == .lines([0..<3, 3..<5]))
        #expect(NGSimpleWrap.lines(of: Array("ab ab ab".utf16), metrics: metrics, width: 20, maximumLines: 2) == .lines([0..<3, 3..<8]))
    }

    /// The engine from many threads at once, learning as it goes: the same
    /// lines and counts as one thread laying the text out alone.
    @Test func manyThreadsLayOutLikeOne() async throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        let texts = randomTexts(600, seed: 9, extra: ["12:03:04", "look-alike", "🌞", "東京", "Ŧœur", "„Zitat“"])
        let reference = NGTextEngine()
        let expected = texts.enumerated().map { index, text in
            (reference.shape(text, font: font, width: CGFloat(60 + index % 200)).glyphs.map(\.glyph),
             reference.lineCount(of: text, font: font, width: CGFloat(40 + index % 300), maximumLines: index % 4 == 0 ? 2 : .max))
        }
        let engine = NGTextEngine()
        let results = NGUncheckedSendable(UnsafeMutableBufferPointer<([CGGlyph], Int)>.allocate(capacity: texts.count))
        defer { results.value.deallocate() }
        let input = NGUncheckedSendable((texts, font))
        await Task.detached {
            DispatchQueue.concurrentPerform(iterations: 16) { chunk in
                for index in stride(from: chunk, to: input.value.0.count, by: 16) {
                    let text = input.value.0[index]
                    let glyphs = engine.shape(text, font: input.value.1, width: CGFloat(60 + index % 200)).glyphs.map(\.glyph)
                    let lines = engine.lineCount(of: text, font: input.value.1, width: CGFloat(40 + index % 300),
                                                 maximumLines: index % 4 == 0 ? 2 : .max)
                    (results.value.baseAddress! + index).initialize(to: (glyphs, lines))
                }
            }
        }.value
        for index in texts.indices {
            #expect(results.value[index].0 == expected[index].0, "\(texts[index])")
            #expect(results.value[index].1 == expected[index].1, "\(texts[index])")
        }
    }
}
#endif
