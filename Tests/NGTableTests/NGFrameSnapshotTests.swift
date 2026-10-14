#if os(macOS)
import AppKit
import Metal
import Testing
@testable import NGTable

// Snapshot tests of whole Metal frames: the table drawn offscreen, compared
// with reference images in __Snapshots__ next to this file. What depends on
// the machine is fixed by the test (pixel density, emphasis, accent color),
// so the images don't change with the screen or System Settings.
//
// A missing reference is recorded and the test fails once; record all of them
// again after an intended change of the drawing:
//
//     NGTABLE_RECORD_SNAPSHOTS=1 swift test --filter NGFrameSnapshotTests
//
// On a mismatch the frame and a difference image are written to
// $TMPDIR/NGTableSnapshots (the failure message has the path). The fonts and
// SF Symbols are the system's: a new macOS version, or symbols the system
// updated by itself, may need new references (look at the difference images
// first: only the symbols or text should differ).

/// Reference images: comparing with them and recording them.
@MainActor
enum NGSnapshot {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__").appendingPathComponent("NGFrameSnapshotTests")
    static let failures = FileManager.default.temporaryDirectory.appendingPathComponent("NGTableSnapshots")
    static var isRecording: Bool { ProcessInfo.processInfo.environment["NGTABLE_RECORD_SNAPSHOTS"] != nil }

    /// Pixels of an image as premultiplied BGRA in sRGB, row by row from the top.
    static func pixels(of image: CGImage) -> [UInt8] {
        let context = NGCellDrawing.makeBitmapContext(width: image.width, height: image.height,
                                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var pixels: [UInt8] = []
        pixels.reserveCapacity(image.width * image.height * 4)
        for row in 0..<image.height {
            pixels.append(contentsOf: UnsafeBufferPointer(start: bytes + row * context.bytesPerRow, count: image.width * 4))
        }
        return pixels
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    /// Compares `image` with the reference `name`. Channels may differ by 2
    /// (rounding in the GPU's blending); a few pixels by more.
    static func expectMatches(_ image: CGImage, named name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let reference = folder.appendingPathComponent(name + ".png")
        if isRecording {
            try writePNG(image, to: reference)
            Issue.record("Recorded the snapshot \(name); run the tests again.", sourceLocation: sourceLocation)
            return
        }
        // A missing reference fails without touching the source tree: a normal
        // run must not record (and then pass on) whatever it drew.
        guard FileManager.default.fileExists(atPath: reference.path) else {
            let frame = failures.appendingPathComponent(name + ".png")
            try writePNG(image, to: frame)
            Issue.record("No reference for \(name) (frame at \(frame.path)); record with NGTABLE_RECORD_SNAPSHOTS=1.",
                         sourceLocation: sourceLocation)
            return
        }
        let expected = try #require(NSImage(contentsOf: reference)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        guard expected.width == image.width, expected.height == image.height else {
            try writePNG(image, to: failures.appendingPathComponent(name + ".png"))
            Issue.record("\(name): \(image.width)×\(image.height) instead of \(expected.width)×\(expected.height)",
                         sourceLocation: sourceLocation)
            return
        }
        let (a, b) = (pixels(of: expected), pixels(of: image))
        // Usually identical: compared at memory speed (the loop below is slow in debug builds).
        let identical = a.withUnsafeBytes { a in b.withUnsafeBytes { b in memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0 } }
        guard !identical else { return }
        var differing = 0
        var difference = [UInt8](repeating: 0, count: a.count)
        for pixel in 0..<(a.count / 4) {
            var largest = 0
            for channel in 0..<4 {
                largest = max(largest, abs(Int(a[pixel * 4 + channel]) - Int(b[pixel * 4 + channel])))
            }
            if largest > 2 {
                differing += 1
                // Red where they differ (BGRA).
                difference[pixel * 4 + 2] = 255
                difference[pixel * 4 + 3] = 255
            }
        }
        // At most one pixel in 2,000.
        guard differing * 2_000 > a.count / 4 else { return }
        try writePNG(image, to: failures.appendingPathComponent(name + ".png"))
        let context = CGContext(data: &difference, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: NGCellDrawing.bitmapInfo)!
        try writePNG(context.makeImage()!, to: failures.appendingPathComponent(name + "-difference.png"))
        Issue.record("\(name): \(differing) of \(a.count / 4) pixels differ; see \(failures.path)", sourceLocation: sourceLocation)
    }
}

@Suite("Frame snapshots", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct NGFrameSnapshotTests {
    @MainActor
    class Data: NGTableViewDataSource, NGTableViewDelegate {
        static let lossTint = NSColor.systemRed.withAlphaComponent(0.14)
        static let names = ["DE Keto Wide", "Кампания «Суставы»", "Office ffi fl", "FR Detox — Push", "Summer sale 🌞"]
        static let statuses = [NGTag("Active", color: .green), NGTag("Paused", color: .orange), NGTag("Finished", color: .gray)]

        func numberOfRows(in tableView: NGTableView) -> Int { 30 }

        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            switch column.id {
            case "mark": row % 4 == 0 ? .mark(NGMark("star.fill", color: .yellow, label: "Favorite")) : .empty
            case "name": .text("\(Self.names[row % Self.names.count]) #\(row)")
            case "spend": .number(Double(row * 1_237 % 9_000) + 0.5)
            case "ctr": .number(Double(row * 37 % 100) / 1_000)
            case "status": .tags([Self.statuses[row % 3]])
            case "channels": .tags(row % 2 == 0 ? [NGTag("Google"), NGTag("Meta", color: .blue)] : [NGTag("TikTok", color: .pink)])
            default: .empty
            }
        }

        func tableView(_ tableView: NGTableView, markerColorForRow row: Int) -> NSColor? {
            row % 5 == 1 ? .systemOrange : nil
        }

        func tableView(_ tableView: NGTableView, backgroundColorForRow row: Int) -> NSColor? {
            row == 9 ? Self.lossTint : nil
        }
    }

    /// The accent of emphasized selections (System Settings ▸ Appearance).
    enum Accent: String, Sendable, CaseIterable {
        case blue, pink, graphite

        var color: NSColor {
            switch self {
            case .blue: .systemBlue
            case .pink: .systemPink
            case .graphite: .systemGray
            }
        }
    }

    struct Variant: Sendable, CustomTestStringConvertible {
        var dark: Bool
        var scale: CGFloat
        /// `nil`: the selection of a window that isn't key (unemphasized).
        var accent: Accent?

        var name: String { "\(dark ? "dark" : "light")-\(Int(scale))x-\(accent?.rawValue ?? "unemphasized")" }
        var testDescription: String { name }

        static let all: [Variant] = [false, true].flatMap { dark in
            [1, 2].flatMap { scale in
                ([nil] + Accent.allCases.map(Optional.some)).map { Variant(dark: dark, scale: CGFloat(scale), accent: $0) }
            }
        }
    }

    private func makeTable(_ variant: Variant, data: Data, wrapsNames: Bool = false) -> (NGTableView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 620, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        let table = NGTableView(frame: frame)
        table.scaleForTesting = variant.scale
        table.emphasisForTesting = variant.accent != nil
        table.accentColorForTesting = variant.accent?.color
        table.columns = [
            .column(NGTableColumn("mark", title: "", width: 28, alignment: .center, pin: .leading)),
            .column(wrapsNames ? NGTableColumn("name", title: "Campaign", width: 190, pin: .leading).wrappingText()
                               : NGTableColumn("name", title: "Campaign", width: 190, pin: .leading)),
            .column(NGTableColumn("spend", title: "Spend", width: 110, alignment: .automatic,
                                  format: .currency(code: "USD"), summary: .aggregate(.sum))),
            .column(NGTableColumn("ctr", title: "CTR", width: 70, alignment: .automatic,
                                  format: .percent(fractionDigits: 1), summary: .aggregate(.average))),
            .column(NGTableColumn("status", title: "Status", width: 90)),
            .column(NGTableColumn("channels", title: "Channels", width: 140)),
        ]
        window.contentView = table
        table.dataSource = data
        table.delegate = data
        table.layoutSubtreeIfNeeded()
        return (table, window)
    }

    /// The same rows, some of them taller (`NGTableViewRowHeights`).
    final class HeightData: Data, NGTableViewRowHeights {
        func tableView(_ tableView: NGTableView, heightOfRow row: Int) -> CGFloat {
            row % 4 == 1 ? 48 : row == 6 ? 36 : tableView.rowHeight
        }
    }

    /// Rows of their own heights: backgrounds, stripes, a tinted tall row, a
    /// selection over tall and short rows, cells centered in their rows.
    @Test(arguments: Variant.all.filter { ["light-2x-blue", "dark-1x-unemphasized"].contains($0.name) })
    func heights(_ variant: Variant) throws {
        let data = HeightData()
        let (table, window) = makeTable(variant, data: data)
        defer { withExtendedLifetime((window, data)) {} }
        #expect(table.rowGeometry.hasRowHeights)
        table.selectRowIndexes([4, 5, 6, 9], byExtendingSelection: false)
        table.layoutSubtreeIfNeeded()
        let image = try #require(table.metalSnapshot())
        try NGSnapshot.expectMatches(image, named: "heights-" + variant.name)
    }

    /// Some names longer than their column.
    final class LongNameData: Data {
        override func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            guard column.id == "name", row % 3 == 1 else { return super.tableView(tableView, valueFor: column, row: row) }
            return .text(row == 4 ? "Кампания «Суставы» — весна, широкая аудитория, ретаргетинг и look-alike #\(row)"
                                  : "DE Keto Wide, broad audience, two creatives #\(row)")
        }
    }

    /// A column that wraps text: rows as high as their names, the other
    /// cells of a tall row at its top, a selection over tall rows.
    @Test(arguments: Variant.all.filter { ["light-2x-blue", "dark-1x-unemphasized"].contains($0.name) })
    func wrappedText(_ variant: Variant) throws {
        let data = LongNameData()
        let (table, window) = makeTable(variant, data: data, wrapsNames: true)
        defer { withExtendedLifetime((window, data)) {} }
        #expect(table.rowGeometry.height(of: 4) > table.rowGeometry.height(of: 1))
        #expect(table.rowGeometry.height(of: 1) > table.rowHeight)
        table.selectRowIndexes([3, 4], byExtendingSelection: false)
        table.layoutSubtreeIfNeeded()
        let image = try #require(table.metalSnapshot())
        try NGSnapshot.expectMatches(image, named: "wrapped-" + variant.name)
    }

    @Test(arguments: Variant.all)
    func rows(_ variant: Variant) throws {
        let data = Data()
        let (table, window) = makeTable(variant, data: data)
        defer { withExtendedLifetime((window, data)) {} }
        // Consecutive selected rows merge into one block; row 9 is tinted.
        table.selectRowIndexes([2, 3, 7, 9], byExtendingSelection: false)
        table.layoutSubtreeIfNeeded()
        let image = try #require(table.metalSnapshot())
        #expect(image.width == Int(620 * variant.scale))
        try NGSnapshot.expectMatches(image, named: "rows-" + variant.name)
    }

    /// The cell kinds drawn as shapes: sparklines of every style (with
    /// gaps, a flat series, a value alone, dots), in selected rows too.
    @MainActor
    final class KindsData: NGTableViewDataSource {
        func numberOfRows(in tableView: NGTableView) -> Int { 8 }

        static func series(_ row: Int) -> [Double] {
            switch row {
            case 3: return [5, 5, 5, 5, 5, 5]                      // Flat.
            case 4: return [3, .nan, 7, 2, .nan, .nan, 9, 4]       // Gaps, 9 alone after them... and 4.
            case 5: return [.nan, .nan, 6, .nan, .nan]             // A value alone.
            default:
                return (0..<24).map { (index: Int) -> Double in
                    let wave: Double = sin(Double(index + row * 3) / 3) * 10
                    return wave + Double(index) / 2 - 3
                }
            }
        }

        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            let values = Self.series(row)
            return switch column.id {
            case "name": .text("Row \(row)")
            case "line": .sparkline(NGSparkline(values, showsLastPoint: true, showsMinMax: row % 2 == 0))
            case "area": .sparkline(NGSparkline(values, color: .teal, style: .area))
            case "bars": .sparkline(NGSparkline(values, style: .bars))
            case "winLoss": .sparkline(NGSparkline(values.map { $0.isNaN ? $0 : ($0 > 1 ? 1 : $0 < -1 ? -1 : 0) }, style: .winLoss))
            case "link": .link(NGLink("site\(row).example"))
            case "progress": .progress(row == 5 ? nil : Double(row) / 6)
            case "percent": .progress(Double(row * 17), total: 102)
            case "rating": .rating(row % 6)
            case "choice": row % 2 == 0 ? .tags([NGTag("Active", color: .green)]) : .text("Paused")
            case "button": .button(row == 4 ? NGCellButton("Stop", isEnabled: false)
                                   : row == 5 ? NGCellButton("Delete", role: .destructive)
                                   : row == 6 ? NGCellButton("Share", symbolName: "square.and.arrow.up")
                                   : NGCellButton("Open"))
            default: .empty
            }
        }
    }

    @Test(arguments: Variant.all.filter { $0.accent == nil || $0.accent == .blue })
    func cellKinds(_ variant: Variant) throws {
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 220)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        let table = NGTableView(frame: frame)
        table.scaleForTesting = variant.scale
        table.emphasisForTesting = variant.accent != nil
        table.accentColorForTesting = variant.accent?.color
        table.columns = [
            .column(NGTableColumn("name", title: "Name", width: 70)),
            .column(NGTableColumn("line", title: "Line", width: 130)),
            .column(NGTableColumn("area", title: "Area", width: 130)),
            .column(NGTableColumn("bars", title: "Bars", width: 120)),
            .column(NGTableColumn("winLoss", title: "Win/loss", width: 100)),
            .column(NGTableColumn("link", title: "Link", width: 120)),
            .column(NGTableColumn("button", title: "Button", width: 100, alignment: .center)),
            .column(NGTableColumn("progress", title: "Progress", width: 90)),
            .column(NGTableColumn("percent", title: "Done", width: 110, format: .percent(fractionDigits: 0))),
            .column(NGTableColumn("rating", title: "Rating", width: 110, isEditable: true)),
            .column(NGTableColumn("choice", title: "Choice", width: 110, isEditable: true,
                                  editChoices: [.tags([NGTag("Active", color: .green)]), .text("Paused")])),
        ]
        let data = KindsData()
        // The indeterminate stripe at a fixed moment.
        table.progressAnimationTimeForTesting = 0.5
        window.contentView = table
        table.dataSource = data
        defer { withExtendedLifetime((window, data)) {} }
        table.selectRowIndexes([1, 2], byExtendingSelection: false)
        table.layoutSubtreeIfNeeded()
        // Links: under the pointer (row 0, underlined), pressed (row 3), in a selected row (2).
        let linkFrame = try #require(table.frameOfCell(row: 0, columnID: "link"))
        table.pointerLocationForTesting = table.convert(NSPoint(x: linkFrame.midX, y: linkFrame.midY), to: nil)
        table.updateHoveredCellFromPointer()
        table.visibleCell(sourceRow: 3, columnID: "link")?.isPressed = true
        table.visibleCell(sourceRow: 2, columnID: "link")?.isPointerOver = true
        table.visibleCell(sourceRow: 3, columnID: "button")?.isPressed = true
        // A rating under the pointer previews 4 (it holds 0).
        table.visibleCell(sourceRow: 6, columnID: "rating")?.isPointerOver = true
        table.visibleCell(sourceRow: 6, columnID: "rating")?.previewRating = 4
        let image = try #require(table.metalSnapshot())
        try NGSnapshot.expectMatches(image, named: "kinds-" + variant.name)
    }

    /// Group headers: chevrons, titles, counts and subtotals, one collapsed.
    @Test(arguments: Variant.all.filter { $0.accent == nil })
    func groups(_ variant: Variant) throws {
        let data = Data()
        let (table, window) = makeTable(variant, data: data)
        defer { withExtendedLifetime((window, data)) {} }
        table.rowGrouping = NGRowGrouping(columnID: "status")
        if let paused = table.topLevelGroups.first(where: { $0.value == "Paused" }) {
            table.collapseGroup(paused)
        }
        table.layoutSubtreeIfNeeded()
        let image = try #require(table.metalSnapshot())
        try NGSnapshot.expectMatches(image, named: "groups-" + variant.name)
    }

    /// Scrolled sideways and down: frozen columns stay, the others are clipped
    /// at the frozen region's edge.
    @Test func scrolled() throws {
        let variant = Variant(dark: false, scale: 2, accent: .blue)
        let data = Data()
        let (table, window) = makeTable(variant, data: data)
        defer { withExtendedLifetime((window, data)) {} }
        table.scroll(to: CGPoint(x: 75, y: 100))
        table.layoutSubtreeIfNeeded()
        let image = try #require(table.metalSnapshot())
        try NGSnapshot.expectMatches(image, named: "scrolled-" + variant.name)
    }

    // MARK: Media cells

    /// A picture with a gradient, a frame and a diagonal, to see how it is
    /// cropped and scaled; written as a PNG once per test run.
    static func testPicture(named name: String, width: Int, height: Int, hue: CGFloat) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGTableTests-\(name).png")
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1).cgColor,
                      NSColor(hue: hue + 0.3, saturation: 0.8, brightness: 0.5, alpha: 1).cgColor] as CFArray
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(CGFloat(min(width, height)) / 20)
        context.stroke(CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: CGFloat(width) / 10, dy: CGFloat(height) / 10))
        context.move(to: .zero)
        context.addLine(to: CGPoint(x: width, y: height))
        context.strokePath()
        try NGSnapshot.writePNG(try #require(context.makeImage()), to: url)
        return url
    }

    @MainActor
    final class MediaData: NGTableViewDataSource {
        var media: [NGMedia] = []
        func numberOfRows(in tableView: NGTableView) -> Int { media.count }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            column.id == "creative" ? .media(media[row]) : .number(Double(row + 1) * 12.5)
        }
    }

    /// Waits until the table's pictures have loaded (or failed).
    static func waitForPictures(_ table: NGTableView) async throws {
        for _ in 0..<200 {
            _ = table.metalSnapshot()
            let loading = table.visibleCells.values.contains { cell in
                guard case .media(let media) = cell.content else { return false }
                let thumbnail = table.mediaThumbnailFrame(of: media, inCell: cell.cellFrame)
                if case .loading = NGMediaCache.shared.still(for: media, width: Int(thumbnail.width * table.displayScale),
                                                             height: Int(thumbnail.height * table.displayScale),
                                                             device: table.metalRenderer!.device) { return true }
                return false
            }
            if !loading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The pictures didn't load")
    }

    @Test(arguments: [false, true])
    func media(dark: Bool) async throws {
        let landscape = try Self.testPicture(named: "landscape", width: 640, height: 240, hue: 0.55)
        let portrait = try Self.testPicture(named: "portrait", width: 200, height: 400, hue: 0.05)
        let data = MediaData()
        data.media = [
            NGMedia(image: landscape, badge: "video.fill", lines: [
                .init("A long creative title that wraps to a second line and then gets truncated at its end", style: .title, maximumLines: 2),
                .init("example.com · Description"),
                .init("💬 Needs a new picture", style: .colored(.orange)),
            ]),
            NGMedia(image: portrait, lines: [.init("Portrait picture", style: .title), .init("Cropped to fill")]),
            NGMedia(image: URL(fileURLWithPath: "/nonexistent/picture.png"), lines: [.init("Missing picture", style: .title)]),
        ]
        let frame = NSRect(x: 0, y: 0, width: 460, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let table = NGTableView(frame: frame)
        table.scaleForTesting = 2
        table.emphasisForTesting = true
        table.accentColorForTesting = .systemBlue
        table.rowHeight = 80
        table.columns = [
            .column(NGTableColumn("creative", title: "Creative", width: 340)),
            .column(NGTableColumn("spend", title: "Spend", width: 100, alignment: .automatic, format: .currency(code: "USD"))),
        ]
        window.contentView = table
        table.dataSource = data
        table.selectRowIndexes([1], byExtendingSelection: false)
        table.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime((window, data)) {} }
        try await Self.waitForPictures(table)
        let image = try #require(table.metalSnapshot())
        try NGSnapshot.expectMatches(image, named: "media-\(dark ? "dark" : "light")-2x")
    }
}
#endif
