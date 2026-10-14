#if os(macOS)
import AppKit
import Metal
import Testing
@testable import NGTable

/// The GPU renderer must draw text like Core Text draws it: each cell is
/// drawn both ways and the pixels compared.
@Suite("Metal renderer", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct NGMetalRendererTests {
    struct Difference: CustomStringConvertible {
        var pixels = 0
        var largest = 0
        var total = 0
        var description: String { "\(pixels) of \(total) pixels differ, by up to \(largest)/255" }
    }

    /// Pixels of a cell's text drawn by Core Text into a bitmap, laid out
    /// like the table's cells (padding, alignment, centered line, truncation).
    private func drawnByCoreText(_ text: String, font: NSFont, alignment: NSTextAlignment, size: CGSize, scale: CGFloat) -> [UInt8] {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = NGCellDrawing.makeBitmapContext(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        context.scaleBy(x: scale, y: scale)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let available = size.width - 2 * NGMetrics.cellPadding
        if CTLineGetTypographicBounds(line, nil, nil, nil) > available,
           let truncated = CTLineCreateTruncatedLine(line, available, .end,
                                                     CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))) {
            line = truncated
        }
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let x = alignment == .right ? NGMetrics.cellPadding + available - lineWidth : NGMetrics.cellPadding
        let top = ((size.height - NGCellTextMetrics.shared.textLineHeight) / 2).rounded()
        // Core Graphics is y-up, cells are top-down.
        context.textPosition = CGPoint(x: x, y: size.height - top - CTFontGetAscent(font))
        CTLineDraw(line, context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var pixels: [UInt8] = []
        for row in 0..<height {
            pixels.append(contentsOf: UnsafeBufferPointer(start: bytes + row * context.bytesPerRow, count: width * 4))
        }
        return pixels
    }

    /// Pixels of the same cell drawn by the Metal renderer.
    private func drawnOnGPU(_ text: String, font: NSFont, alignment: NSTextAlignment, size: CGSize, scale: CGFloat,
                            color: NSColor, renderer: NGMetalRenderer) -> [UInt8] {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: NGMetalRenderer.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = renderer.device.makeTexture(descriptor: descriptor)!
        // Built like the table's frames: again if the atlas started over meanwhile.
        let quads = renderer.quadsSurvivingAtlasResets {
            var quads: [NGMetalQuad] = []
            renderer.appendText(text, font: font, alignment: alignment, in: CGRect(origin: .zero, size: size), scale: scale,
                                color: NGMetalRenderer.premultiplied(color), to: &quads)
            return quads
        }
        let done = DispatchSemaphore(value: 0)
        let signal = NGUncheckedSendable(done)
        renderer.draw(quads, into: texture, clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) { signal.value.signal() }
        done.wait()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }

    private func compare(_ a: [UInt8], _ b: [UInt8]) -> Difference {
        var difference = Difference(total: a.count / 4)
        for pixel in 0..<(a.count / 4) {
            var largest = 0
            for channel in 0..<4 {
                largest = max(largest, abs(Int(a[pixel * 4 + channel]) - Int(b[pixel * 4 + channel])))
            }
            if largest > 0 { difference.pixels += 1 }
            difference.largest = max(difference.largest, largest)
        }
        return difference
    }

    /// Writes pixels over white, for looking at them (NGTABLE_METAL_DUMP=folder).
    static func writePNG(_ pixels: [UInt8], size: CGSize, scale: CGFloat, to path: String) {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        var data = pixels
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: NGCellDrawing.bitmapInfo)!
        let image = context.makeImage()!
        let white = CGContext(data: nil, width: width * 4, height: height * 4, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: NGCellDrawing.bitmapInfo)!
        white.setFillColor(CGColor(gray: 1, alpha: 1))
        white.fill(CGRect(x: 0, y: 0, width: width * 4, height: height * 4))
        white.interpolationQuality = .none
        white.draw(image, in: CGRect(x: 0, y: 0, width: width * 4, height: height * 4))
        let rep = NSBitmapImageRep(cgImage: white.makeImage()!)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static let samples: [(text: String, digits: Bool, alignment: NSTextAlignment)] = [
        ("Campaign DE Keto Wide #1042", false, .natural),
        ("Кампания «Суставы» — тест", false, .natural),
        ("Office ffi fl Ta To Wa", false, .natural),
        ("A very long campaign name that does not fit and is truncated", false, .natural),
        ("$12,345.67", true, .right),
        ("-0.42 %", true, .right),
        ("1 234 567", true, .right),
        ("Mixed 日本語 العربية", false, .natural),
    ]

    /// Color glyphs aren't tinted by the text's color but are faded with it
    /// (a fade multiplies quad colors).
    @Test func colorGlyphsFade() throws {
        let renderer = try #require(NGMetalRenderer())
        let quads = renderer.quadsSurvivingAtlasResets {
            var quads: [NGMetalQuad] = []
            renderer.appendText("😀a", font: NSFont.systemFont(ofSize: 13), alignment: .left,
                                in: CGRect(x: 0, y: 0, width: 100, height: 20), scale: 2,
                                color: SIMD4(0.2, 0.2, 0.2, 0.5), to: &quads)
            return quads
        }
        let emoji = try #require(quads.first { $0.kind.x == 2 })
        #expect(emoji.color == SIMD4(1, 1, 1, 1))
        #expect(quads.contains { $0.kind.x == 1 && $0.color == SIMD4(0.2, 0.2, 0.2, 0.5) })
    }

    @Test(arguments: [1.0, 2.0])
    func textMatchesCoreText(scale: Double) throws {
        let renderer = try #require(NGMetalRenderer())
        let size = CGSize(width: 220, height: 24)
        var report: [String] = []
        for sample in Self.samples {
            let font = sample.digits ? NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                : NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let reference = drawnByCoreText(sample.text, font: font, alignment: sample.alignment, size: size, scale: scale)
            let gpu = drawnOnGPU(sample.text, font: font, alignment: sample.alignment, size: size, scale: scale, color: .black, renderer: renderer)
            let difference = compare(reference, gpu)
            if let folder = ProcessInfo.processInfo.environment["NGTABLE_METAL_DUMP"] {
                let name = "\(folder)/\(Self.samples.firstIndex { $0.text == sample.text }!)-\(Int(scale))x"
                Self.writePNG(reference, size: size, scale: scale, to: name + "-coretext.png")
                Self.writePNG(gpu, size: size, scale: scale, to: name + "-metal.png")
            }
            report.append("\(sample.text): \(difference)")
            if scale >= 2 {
                // Retina: the same pixels (scripts drawn by fallback fonts may differ in a few).
                #expect(difference.pixels <= (sample.text.contains("日") ? 32 : 0), "\(sample.text) at \(scale)×: \(difference)")
            } else {
                // 1×: some glyphs a quarter pixel apart (Core Graphics quantizes lines differently).
                #expect(difference.pixels * 100 <= difference.total * 6, "\(sample.text) at \(scale)×: \(difference)")
            }
        }
        print("METAL \(scale)×\n" + report.joined(separator: "\n"))
    }

    /// A frame whose glyphs fill the atlas: it starts over in a new texture
    /// (frames on the GPU keep the old one), the frame is built again, and
    /// when one frame alone doesn't fit, the atlas grows. The text still
    /// matches Core Text's.
    @Test func textSurvivesAFullAtlas() throws {
        // 64 × 64 pixels hold far fewer glyphs than one line at 2×.
        let renderer = try #require(NGMetalRenderer(atlasSize: 64))
        let firstTexture = renderer.atlas.texture
        let size = CGSize(width: 220, height: 24)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let text = "Campaign DE Keto Wide #1042 Кампания"
        let reference = drawnByCoreText(text, font: font, alignment: .natural, size: size, scale: 2)
        let gpu = drawnOnGPU(text, font: font, alignment: .natural, size: size, scale: 2, color: .black, renderer: renderer)
        #expect(renderer.atlas.resetCount > 0)
        #expect(renderer.atlas.size > 64)
        #expect(renderer.atlas.texture !== firstTexture)
        let difference = compare(reference, gpu)
        #expect(difference.pixels == 0, "\(difference)")
    }

    /// A glyph too large for the atlas draws nothing, and isn't rasterized again on every frame.
    @Test func glyphsTooLargeForTheAtlasAreRemembered() throws {
        let renderer = try #require(NGMetalRenderer(atlasSize: 64))
        let font = NSFont.systemFont(ofSize: 200)
        let atlas = renderer.atlas
        let table = atlas.table(font: atlas.fontID(of: font), rise: 0, scale: 2)
        var glyph: CGGlyph = 0
        var character = UniChar(("W" as Character).utf16.first!)
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        let entry = try #require(atlas.entry(in: table, glyph: glyph, phase: 0))
        #expect(entry.width == 0)
        let rasterized = atlas.rasterizedCount
        _ = atlas.entry(in: table, glyph: glyph, phase: 0)
        #expect(atlas.rasterizedCount == rasterized)
        #expect(atlas.resetCount == 0)
    }

    /// Glyph tables are small: compact entries, in pages made only for the
    /// glyphs used (a CJK fallback font's high glyph numbers included).
    /// Fonts that differ only in a variation (a weight between styles) or a
    /// matrix (a skew) have their own glyphs.
    @Test func fontVariationsAndMatricesHaveTheirOwnGlyphs() throws {
        let renderer = try #require(NGMetalRenderer())
        let atlas = renderer.atlas
        let plain = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        var skew = CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: 0, ty: 0)
        let skewed = CTFontCreateWithName("Helvetica" as CFString, 13, &skew)
        #expect(atlas.fontID(of: plain) != atlas.fontID(of: skewed))
        let system = NSFont.systemFont(ofSize: 13)
        let weight = Int(bitPattern: UInt(0x7767_6874))   // 'wght'
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: [weight: 650]] as CFDictionary)
        let heavier = CTFontCreateCopyWithAttributes(system, 13, nil, descriptor)
        #expect(atlas.fontID(of: system) != atlas.fontID(of: heavier))
        #expect(atlas.fontID(of: CTFontCreateWithName("Helvetica" as CFString, 13, nil)) == atlas.fontID(of: plain))
    }

    @Test func glyphTablesStaySmallForHighGlyphNumbers() throws {
        #expect(MemoryLayout<NGGlyphAtlas.Entry?>.stride <= 16)
        let renderer = try #require(NGMetalRenderer())
        let atlas = renderer.atlas
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let table = atlas.table(font: atlas.fontID(of: font), rise: 0, scale: 2)
        var glyph: CGGlyph = 0
        var character = UniChar(("A" as Character).utf16.first!)
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        let low = try #require(atlas.entry(in: table, glyph: glyph, phase: 1))
        #expect(low.width > 0)
        // A glyph number far up: one more page, not entries for every glyph below it.
        _ = atlas.entry(in: table, glyph: 40_000, phase: 0)
        #expect(table.allocatedEntryCount == 2 * NGGlyphAtlas.GlyphTable.pageGlyphs * NGGlyphAtlas.phases)
        #expect(atlas.entry(in: table, glyph: glyph, phase: 1)?.x == low.x)
    }

    /// Objects a draw depends on are kept until the GPU is done, then released.
    @Test func drawsKeepTheirTexturesOwnersUntilDone() throws {
        let renderer = try #require(NGMetalRenderer())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: NGMetalRenderer.pixelFormat, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.renderTarget]
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        weak var released: NSObject?
        let done = DispatchSemaphore(value: 0)
        let signal = NGUncheckedSendable(done)
        do {
            let owner = NSObject()
            released = owner
            renderer.draw([NGMetalRenderer.rectangle(CGRect(x: 0, y: 0, width: 4, height: 4), scale: 1, color: SIMD4(1, 0, 0, 1))],
                          into: texture, clearColor: MTLClearColor(), keepingAlive: [owner]) { signal.value.signal() }
        }
        done.wait()
        // The completion handler (and what it held) goes right after it ran.
        for _ in 0..<100 where released != nil { usleep(1_000) }
        #expect(released == nil)
    }

    /// Formatted numbers are laid out without Core Text, and exactly like it.
    @Test func numbersAreLaidOutLikeCoreText() throws {
        let renderer = try #require(NGMetalRenderer())
        let shaper = renderer.shaper
        let fonts = [NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                     NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                     NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        let formats: [NGValueFormat] = [.currency(code: "USD"), .currency(code: "EUR"), .currency(code: "RUB"),
                                        .percent(fractionDigits: 1), .number(fractionDigits: 2), .number(fractionDigits: 0)]
        let locales = ["en_US", "de_DE", "ru_RU", "fr_FR"].map(Locale.init(identifier:))
        var texts: [String] = []
        for format in formats {
            for locale in locales {
                for value in [0, 0.5, -12.34, 1_237.5, 98_765_432.1, -0.042] {
                    texts.append(format.string(for: value, locale: locale))
                }
            }
        }
        var simple = 0
        for font in fonts {
            for text in texts {
                let before = shaper.simpleLineCount
                let shaped = shaper.shape(text, font: font, width: .greatestFiniteMagnitude)
                let reference = shaper.coreTextLine(text, font: font)
                if shaper.simpleLineCount > before { simple += 1 }
                #expect(shaped.glyphs.map(\.glyph) == reference.glyphs.map(\.glyph), "\(text)")
                #expect(zip(shaped.glyphs, reference.glyphs).allSatisfy { abs($0.x - $1.x) < 0.001 }, "\(text)")
                #expect(abs(shaped.width - reference.width) < 0.001, "\(text)")
            }
        }
        // Most numbers take the fast path in the digit fonts (pairs Core Text
        // kerns fall back to it).
        print("SIMPLE LINES: \(simple) of \(fonts.count * texts.count)")
        #expect(simple * 2 > texts.count)
    }

    /// Latin and Cyrillic text with common punctuation is laid out without
    /// Core Text, kerned and truncated with "…" exactly like it (random
    /// strings and words, several sizes and weights, many widths).
    @Test func textIsLaidOutAndTruncatedLikeCoreText() throws {
        let renderer = try #require(NGMetalRenderer())
        let shaper = renderer.shaper
        var fonts: [NSFont] = [NGCellDrawing.tagFont]
        for points in [11.0, 13.0, 15.0] {
            for weight in [NSFont.Weight.regular, .semibold] {
                fonts.append(.systemFont(ofSize: points, weight: weight))
                fonts.append(.monospacedDigitSystemFont(ofSize: points, weight: weight))
            }
        }
        let characters: [UInt16] = NGTextShaper.simpleCharacters.flatMap { Array($0) }
        let words = ["Campaign", "Summer", "Sale", "Кампания", "Летняя", "распродажа", "AVAST", "WAVY", "To", "Ty", "LT", "fi", "ffl",
                     "№", "—", "«", "»", "Tolkien", "Ёлка", "йод", " ", "  ", "Straße", "Ŧœur", "Żółć", "Şişli", "Ţară", "ÀÉÎÕÜ",
                     "Αθήνα", "ΆΈΉΊ", "Ґанок", "Їжак", "Қазақ", "‰", "€ 10", "£", "™", "→", "„Zitat“", "‹›", "•", "°C", "±½",
                     "12:03:04", "9:0", "0:", ":7", "a:b", "1: 2", "23:59:59.999", "::"]
        var generator = SplitMix64(seed: 2024)
        var texts = ["Campaign 12345 — Summer sale", "Кампания «Лето» № 5", "AVAST Tour LTd", "WAVE Ty Te ", "Ёлка и йод  ",
                     "2026-10-14 12:03:04 request retried", "Ratio 3:2:1, at 09:30"]
        for index in 0..<400 {
            if index % 2 == 0 {
                let units = (0..<(1 + Int(generator.next() % 24))).map { _ in characters[Int(generator.next() % UInt64(characters.count))] }
                texts.append(String(utf16CodeUnits: units, count: units.count))
            } else {
                texts.append((0..<(1 + Int(generator.next() % 5))).map { _ in words[Int(generator.next() % UInt64(words.count))] }.joined())
            }
        }
        func same(_ a: NGShapedText, _ b: NGShapedText) -> Bool {
            a.glyphs.map(\.glyph) == b.glyphs.map(\.glyph) && zip(a.glyphs, b.glyphs).allSatisfy { abs($0.x - $1.x) < 0.001 }
                && abs(a.width - b.width) < 0.001
        }
        // Random characters often include one the font lacks (then Core Text
        // lays the line out): only the words count for the fast path.
        let wordTexts = Set(texts.enumerated().filter { $0.offset < 5 || $0.offset % 2 == 0 }.map(\.element))
        var simple = 0, simpleWords = 0
        for font in fonts {
            for text in texts {
                let before = shaper.simpleLineCount
                let full = shaper.shape(text, font: font, width: .greatestFiniteMagnitude)
                guard shaper.simpleLineCount > before else { continue }
                simple += 1
                if wordTexts.contains(text) { simpleWords += 1 }
                #expect(same(full, shaper.coreTextLine(text, font: font)), "\(font.fontName) \(text.debugDescription)")
                for fraction in [0.1, 0.3, 0.6, 0.9, 0.99] {
                    let width = (full.width * fraction).rounded(.down)
                    #expect(same(shaper.shape(text, font: font, width: width), shaper.coreTextLine(text, font: font, width: width)),
                            "\(font.fontName) \(text.debugDescription) at \(width)")
                }
            }
        }
        // Widths a hair below each cut: Core Text lets the ellipsis end up
        // to 0.0002 past the width.
        let font = NSFont.systemFont(ofSize: 13)
        let ellipsis = shaper.coreTextLine("…", font: font).width
        for text in ["Campaign 12345 — Summer sale", "Кампания «Лето» № 5", "Αθήνα Straße Żółć"] {
            let full = shaper.coreTextLine(text, font: font)
            for cut in [2, 5, 9, 13] {
                for overshoot in [0.00005, 0.00015, 0.00019, 0.00021, 0.0003] {
                    let width = full.glyphs[cut].x + ellipsis - overshoot
                    #expect(shaper.simpleLine(text, font: font, width: width).map { same($0, shaper.coreTextLine(text, font: font, width: width)) } == true,
                            "\(text.debugDescription) cut at \(cut), \(overshoot) short")
                }
            }
        }
        // Most of them take the fast path (pairs Core Text lays out otherwise fall back to it).
        #expect(simpleWords * 10 > fonts.count * wordTexts.count * 8)
        #expect(simple > fonts.count * texts.count / 2)
    }
}
#endif
