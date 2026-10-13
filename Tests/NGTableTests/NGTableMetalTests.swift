#if os(macOS)
import AppKit
import Metal
import Testing
@testable import NGTable

/// The table's rows and cells drawn by the Metal renderer: frames, when they
/// are drawn, and what they cost.
@Suite("Table with the Metal renderer", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct NGTableMetalTests {
    @MainActor
    final class Data: NGTableViewDataSource {
        var names: [Int: String] = [:]
        func numberOfRows(in tableView: NGTableView) -> Int { 40 }
        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            switch column.id {
            case "name": .text(names[row] ?? ["DE Keto Wide #\(row)", "Кампания «Суставы» \(row)", "Office ffi fl"][row % 3])
            case "spend": .number(Double(row) * 123.45)
            case "status": .tags([NGTag(row % 2 == 0 ? "Active" : "Paused", color: row % 2 == 0 ? .green : .orange)])
            case "mark": row % 4 == 0 ? .mark(NGMark("star.fill", color: .yellow, label: "Star")) : .empty
            default: .empty
            }
        }
    }

    private func makeTable(data: Data) -> (NGTableView, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        // The window isn't on screen: the frames are drawn anyway.
        table.drawsWhileUnseenForTesting = true
        table.columns = [
            .column(NGTableColumn("mark", title: "", width: 28, pin: .leading)),
            .column(NGTableColumn("name", title: "Name", width: 220, pin: .leading)),
            .column(NGTableColumn("spend", title: "Spend", width: 120, format: .currency(code: "USD"), summary: .aggregate(.sum))),
            .column(NGTableColumn("status", title: "Status", width: 140)),
        ]
        window.contentView = table
        table.dataSource = data
        table.selectRowIndexes([2, 3, 7], byExtendingSelection: false)
        table.layoutSubtreeIfNeeded()
        return (table, window)
    }

    /// A frame whose text isn't laid out yet (tags never seen) is the same
    /// as the next one: the cells that waited for their text keep their
    /// place under floating headers and the focus ring.
    /// Header titles outside the shaper's fast path (Arabic, Chinese, emoji)
    /// over rows that need no shaping: a rows frame with nothing to wait for
    /// still ends collecting misses, so the header and summary draw their text.
    @Test func chromeTextAfterARowsFrameWithNothingNew() throws {
        @MainActor final class Plain: NGTableViewDataSource {
            func numberOfRows(in tableView: NGTableView) -> Int { 50 }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .text("Row \(row)") }
        }
        let data = Plain()
        let frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        let titles = ["مرحبا بالعالم \(UUID().uuidString.prefix(4))", "你好世界 \(UUID().uuidString.prefix(4))", "Spend 💰 \(UUID().uuidString.prefix(4))"]
        table.columns = titles.enumerated().map { .column(NGTableColumn("c\($0.offset)", title: $0.element, width: 180)) }
        window.contentView = table
        table.dataSource = data
        table.layoutSubtreeIfNeeded()
        let renderer = try #require(table.metalRenderer)
        func headerGlyphs() -> Int {
            table.headerQuads(renderer: renderer, scale: 2).filter { $0.kind.x == 1 || $0.kind.x == 2 }.count
        }
        for _ in 0..<2 {
            _ = table.buildMetalQuads(renderer: renderer, scale: 2)
            _ = headerGlyphs()   // The first time the titles are laid out, the next time drawn.
        }
        _ = table.buildMetalQuads(renderer: renderer, scale: 2)
        let glyphs = headerGlyphs()
        #expect(glyphs > 30, "\(glyphs) glyphs in the header")
        withExtendedLifetime((window, data)) {}
    }

    @Test func aFirstFrameIsTheSameAsTheNext() throws {
        @MainActor final class Fresh: NGTableViewDataSource {
            // Text that needs shaping (Arabic), never seen before.
            var tags: [String] = []
            var groups: [String] = []
            init() { renew() }
            func renew() {
                tags = (0..<6).map { _ in "وسم " + UUID().uuidString.prefix(6) }
                groups = (0..<8).map { _ in "حملة " + UUID().uuidString.prefix(6) }
            }
            func numberOfRows(in tableView: NGTableView) -> Int { 300 }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
                column.id == "group" ? .text(groups[row / 40]) : .tags([NGTag(tags[row % tags.count], color: .blue)])
            }
        }
        let data = Fresh()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let table = NGTableView(frame: frame)
        table.columns = [.column(NGTableColumn("group", title: "Group", width: 100)),
                         .column(NGTableColumn("tag", title: "Tag", width: 200))]
        window.contentView = table
        table.dataSource = data
        table.rowGrouping = NGRowGrouping(columnID: "group")
        table.layoutSubtreeIfNeeded()
        // Scrolled into a group (its header floats over tag cells), a focused tag cell.
        table.setContentOffset(CGPoint(x: 0, y: table.rowHeight * 10.5))
        table.layoutSubtreeIfNeeded()
        // New text, not drawn yet: the next frame is the first with it.
        data.renew()
        table.reloadData()
        table.setContentOffset(CGPoint(x: 0, y: table.rowHeight * 10.5))
        table.layoutSubtreeIfNeeded()
        let missesBefore = table.metalRenderer!.shaper.missCount
        let first = try #require(table.metalSnapshot())
        #expect(table.metalRenderer!.shaper.missCount > missesBefore)   // It did wait for text.
        let second = try #require(table.metalSnapshot())
        let a = try #require(first.dataProvider?.data as Foundation.Data?), b = try #require(second.dataProvider?.data as Foundation.Data?)
        #expect(a == b)
        withExtendedLifetime((window, data)) {}
    }

    /// A clear background shows what's behind the table.
    /// The rows' layer is as large as its pixels: drawn one to one, the part
    /// past the bounds (less than a pixel) going below them, where the
    /// table clips it.
    @Test func theRowsLayerIsNotStretched() throws {
        let data = Data()
        let (table, window) = makeTable(data: data)
        defer { withExtendedLifetime((window, data)) {} }
        table.setFrameSize(NSSize(width: 640.3, height: 400.3))
        table.layoutSubtreeIfNeeded()
        let layer = try #require(table.metalLayer)
        #expect(layer.frame.width * layer.contentsScale == layer.drawableSize.width)
        #expect(layer.frame.height * layer.contentsScale == layer.drawableSize.height)
        // Its top and left edges are the table's: the part past is below and right.
        let flipped = table.layer?.isGeometryFlipped == true
        #expect(flipped ? layer.frame.minY == 0 : abs(layer.frame.maxY - table.bounds.height) < 0.001)
        #expect(layer.frame.minX == 0)
    }

    /// A batch that changes visible cells only doesn't draw the header and
    /// summary again, nor rebuild the header's cursor areas.
    @Test func batchesOfCellsLeaveTheChrome() throws {
        let data = Data()
        let (table, window) = makeTable(data: data)
        defer { withExtendedLifetime((window, data)) {} }
        table.drawMetalFrameIfNeeded()
        let header = try #require(table.headerSurface), summary = try #require(table.summarySurface)
        header.needsFrame = false
        summary.needsFrame = false
        let pointerAreas = table.headerPointerAreasGeneration
        data.names[2] = "Renamed"
        table.reloadData(forRowIndexes: [2], columnIndexes: [1])
        #expect(!header.needsFrame && !summary.needsFrame)
        #expect(table.headerPointerAreasGeneration == pointerAreas)
        // A new width does.
        table.setWidth(260, forColumnID: "name")
        table.layoutSubtreeIfNeeded()
        #expect(header.needsFrame)
    }

    @Test func aClearBackgroundIsNotOpaque() throws {
        let data = Data()
        let (table, window) = makeTable(data: data)
        defer { withExtendedLifetime((window, data)) {} }
        table.backgroundColor = .clear
        table.setNeedsMetalFrame()
        table.drawMetalFrameIfNeeded()
        #expect(table.metalLayer?.isOpaque == false)
        table.backgroundColor = .white
        table.setNeedsMetalFrame()
        table.drawMetalFrameIfNeeded()
        #expect(table.metalLayer?.isOpaque == true)
        // Translucent: what's behind shows through too.
        table.backgroundColor = NSColor.white.withAlphaComponent(0.5)
        table.setNeedsMetalFrame()
        table.drawMetalFrameIfNeeded()
        #expect(table.metalLayer?.isOpaque == false)
        // Translucent grid lines keep their alpha (premultiplied).
        table.gridColor = NSColor.systemRed.withAlphaComponent(0.25)
        table.showsVerticalGridLines = true
        let renderer = try #require(table.metalRenderer)
        let lines = table.buildMetalQuads(renderer: renderer, scale: 2).filter { abs($0.color.w - 0.25) < 0.01 }
        #expect(lines.count >= table.tableColumns.count)
    }

    /// Vertical grid lines are quads of the frame (under floating headers and
    /// the focus ring), one per column, not views over it.
    @Test func verticalGridLinesAreDrawnWithTheRows() throws {
        let data = Data()
        let (table, window) = makeTable(data: data)
        defer { withExtendedLifetime((window, data)) {} }
        let renderer = try #require(table.metalRenderer)
        let without = table.buildMetalQuads(renderer: renderer, scale: 2).count
        table.showsVerticalGridLines = true
        let with = table.buildMetalQuads(renderer: renderer, scale: 2).count
        #expect(with - without == table.tableColumns.count)
        #expect(!table.centerRegion.canvas.subviews.contains { $0 is NGColorView })
    }

    @Test func aFrameIsDrawn() throws {
        let data = Data()
        let (table, window) = makeTable(data: data)
        defer { withExtendedLifetime((window, data)) {} }
        let renderer = try #require(table.metalRenderer)
        let quads = table.buildMetalQuads(renderer: renderer, scale: 2)
        #expect(quads.count > 200)
        let before = NGTableView.metalFramesForTesting
        table.setNeedsMetalFrame()
        table.drawMetalFrameIfNeeded()
        #expect(NGTableView.metalFramesForTesting == before + 1)
    }

    /// A frame drawn tells how long the GPU took, on the main thread.
    @Test func aFrameTellsItsGPUTime() async throws {
        let data = Data()
        let (table, window) = makeTable(data: data)
        defer { withExtendedLifetime((window, data)) {} }
        var times: [CFTimeInterval] = []
        table.frameRendered = { times.append($0) }
        table.setNeedsMetalFrame()
        table.drawMetalFrameIfNeeded()
        let deadline = Date().addingTimeInterval(5)
        while times.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let time = try #require(times.first)
        #expect(time > 0 && time < 1)
    }

    /// Every scroll step draws a frame where the rows now are, also steps that
    /// bring no new row into view (the canvases only move): custom cell views
    /// move with the canvases, and the rows drawn by Metal must too.
    @Test func smallScrollStepsDrawAFrame() throws {
        let data = Data()
        let (table, window) = makeTable(data: data)
        defer { withExtendedLifetime((window, data)) {} }
        let renderer = try #require(table.metalRenderer)
        table.drawMetalFrameIfNeeded()
        let before = table.buildMetalQuads(renderer: renderer, scale: 2)
        table.needsMetalFrame = false
        table.scroll(to: CGPoint(x: 0, y: 3))
        #expect(table.needsMetalFrame)
        let after = table.buildMetalQuads(renderer: renderer, scale: 2)
        // The same rows, 3 points (6 pixels) higher.
        #expect(before.count == after.count)
        #expect(after.first.map { $0.rect.y } == before.first.map { $0.rect.y - 6 })
    }

    /// Updates of rows out of view draw no frame; of visible rows, one.
    @Test func framesOnlyWhenSomethingVisibleChanged() {
        @MainActor final class Values: NGTableViewDataSource {
            var values = (0..<500).map(Double.init)
            func numberOfRows(in tableView: NGTableView) -> Int { values.count }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue { .number(values[row]) }
        }
        let data = Values()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = [.column(NGTableColumn("v", title: "V", width: 120, format: .number(fractionDigits: 0)))]
        window.contentView = table
        table.dataSource = data
        table.layoutSubtreeIfNeeded()
        table.needsMetalFrame = false
        // Row 400 is far below the visible rows.
        data.values[400] += 1
        table.reloadData(forRowIndexes: [400], columnIndexes: [0])
        #expect(!table.needsMetalFrame)
        data.values[1] += 1
        table.reloadData(forRowIndexes: [1], columnIndexes: [0])
        #expect(table.needsMetalFrame)
        withExtendedLifetime((window, data)) {}
    }

    /// How long a frame of a wide table takes to build (printed; for debug builds too).
    @Test func frameCost() throws {
        @MainActor final class Wide: NGTableViewDataSource {
            func numberOfRows(in tableView: NGTableView) -> Int { 2_000 }
            func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
                column.id == "c0" ? .text("Campaign DE Keto Wide #\(row)") : .number(Double(row * 31 + column.id.count))
            }
        }
        let data = Wide()
        let frame = NSRect(x: 0, y: 0, width: 1800, height: 1000)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let table = NGTableView(frame: frame)
        table.columns = (0..<30).map { .column(NGTableColumn("c\($0)", title: "C\($0)", width: $0 == 0 ? 220 : 90,
                                                             format: .number(fractionDigits: 2))) }
        window.contentView = table
        table.dataSource = data
        table.layoutSubtreeIfNeeded()
        let renderer = try #require(table.metalRenderer)
        _ = table.buildMetalQuads(renderer: renderer, scale: 2)   // Warm the caches.
        let start = CACurrentMediaTime()
        var quads = 0
        for step in 0..<20 {
            table.scroll(to: CGPoint(x: 0, y: CGFloat(step) * 3))
            quads = table.buildMetalQuads(renderer: renderer, scale: 2).count
        }
        print("METAL FRAME: \(String(format: "%.2f", (CACurrentMediaTime() - start) / 20 * 1000)) ms per frame, \(quads) quads")
        withExtendedLifetime((window, data)) {}
    }

    /// Group headers (chevrons, titles, counts, subtotals) build their quads too.
    @Test func groupHeadersDraw() throws {
        let data = Data()
        let (table, window) = makeTable(data: data)
        defer { withExtendedLifetime((window, data)) {} }
        table.rowGrouping = NGRowGrouping(columnID: "status")
        table.layoutSubtreeIfNeeded()
        let renderer = try #require(table.metalRenderer)
        let quads = table.buildMetalQuads(renderer: renderer, scale: 2)
        #expect(quads.count > 200)
        table.collapseGroup(nil, collapseChildren: true)
        #expect(table.buildMetalQuads(renderer: renderer, scale: 2).count > 10)
    }

    /// The column drag snapshot covers its whole frame at the screen's scale,
    /// with the cells (drawn by Metal offscreen) where the rows are.
    @Test func columnDragImageFillsItsFrame() throws {
        let data = Data()
        let (table, window) = makeTable(data: data)
        defer { withExtendedLifetime((window, data)) {} }
        let rect = NSRect(x: 28, y: 0, width: 220, height: table.bounds.height)
        let image = try #require(table.makeColumnDragImage(of: rect, unit: .item(id: "name"), columnIDs: ["name"], pin: .leading))
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        #expect(image.size == rect.size)
        // Opaque everywhere (it was drawn at half size into a corner, the rest transparent).
        for (x, y) in [(1, 1), (bitmap.pixelsWide - 2, 1), (1, bitmap.pixelsHigh - 2), (bitmap.pixelsWide - 2, bitmap.pixelsHigh - 2)] {
            #expect(bitmap.colorAt(x: x, y: y)?.alphaComponent == 1, "pixel \(x), \(y)")
        }
        // Text in the first rows: dark pixels in the top quarter below the header.
        let top = Int(table.layoutMetrics.headerHeight * 2) + 4
        var dark = 0
        for y in top..<(bitmap.pixelsHigh / 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) where (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.4 {
                dark += 1
            }
        }
        #expect(dark > 50)
    }

    /// A new size draws its frame in the layout pass itself: window zoom
    /// animations resize without returning to the run loop, where frames are
    /// otherwise drawn, and the old frame was shown stretched.
    @Test func resizingDrawsInTheLayoutPass() {
        let data = Data()
        let (table, window) = makeTable(data: data)
        defer { withExtendedLifetime((window, data)) {} }
        table.drawMetalFrameIfNeeded()
        let before = NGTableView.metalFramesForTesting
        window.setContentSize(NSSize(width: 900, height: 600))
        table.layoutSubtreeIfNeeded()
        #expect(NGTableView.metalFramesForTesting == before + 1)
        #expect(table.metalLayer?.drawableSize == CGSize(width: 900 * table.metalLayer!.contentsScale, height: 600 * table.metalLayer!.contentsScale))
        // Layout without a new size waits for the run loop as before.
        table.needsLayout = true
        table.layoutSubtreeIfNeeded()
        #expect(NGTableView.metalFramesForTesting == before + 1)
    }

    /// The header and the summary row are Metal layers inside their views:
    /// asking a view to redraw draws its layer in the next frame, and only it.
    @Test func headerAndSummaryDrawWhenAsked() throws {
        let data = Data()
        let (table, window) = makeTable(data: data)
        defer { withExtendedLifetime((window, data)) {} }
        let header = try #require(table.headerSurface), summary = try #require(table.summarySurface)
        #expect(header.layer.superlayer != nil && header.layer.superlayer === table.headerView.layer)
        #expect(summary.layer.superlayer != nil && summary.layer.superlayer === table.summaryBar.contentView.layer)
        #expect(header.layer.drawableSize.width == table.headerView.bounds.width * header.layer.contentsScale)
        table.drawMetalFrameIfNeeded()
        #expect(!header.needsFrame && !summary.needsFrame)

        let frames = NGMetalSurface.framesForTesting, rowFrames = NGTableView.metalFramesForTesting
        table.headerView.needsDisplay = true
        #expect(header.needsFrame && !summary.needsFrame)
        table.drawMetalFrameIfNeeded()
        #expect(NGMetalSurface.framesForTesting == frames + 1)
        #expect(NGTableView.metalFramesForTesting == rowFrames)

        // A new summary scope changes the values' color.
        table.summaryScope = .selectedRows
        #expect(summary.needsFrame)
        table.drawMetalFrameIfNeeded()
        #expect(NGMetalSurface.framesForTesting == frames + 2)
        #expect(!table.headerQuads(renderer: table.metalRenderer!, scale: 2).isEmpty)
        #expect(!table.summaryQuads(renderer: table.metalRenderer!, scale: 2).isEmpty)
    }

    /// A layer asks for a drawable only while one is free (one is on screen),
    /// and may draw again once the GPU finished a frame.
    @Test func framesWaitForAFreeDrawable() async {
        let pacer = NGFramePacer()
        #expect(pacer.canDraw)
        let first = pacer.frameDidStart()
        #expect(pacer.canDraw)
        let second = pacer.frameDidStart()
        #expect(!pacer.canDraw)
        // The GPU's completions count down on its own thread.
        await Task.detached { first(); second() }.value
        #expect(pacer.framesInFlight == 0)
        #expect(pacer.canDraw)
    }

    /// A hidden table draws no frames; it draws the one it missed when shown.
    @Test func hiddenTablesDrawWhenShown() {
        let data = Data()
        let (table, window) = makeTable(data: data)
        table.drawMetalFrameIfNeeded()
        table.isHidden = true
        table.setNeedsMetalFrame()
        let frames = NGTableView.metalFramesForTesting
        table.drawMetalFrameIfNeeded()
        #expect(NGTableView.metalFramesForTesting == frames)
        table.isHidden = false
        table.drawMetalFrameIfNeeded()
        #expect(NGTableView.metalFramesForTesting == frames + 1)
        // A window not on screen (ordered out, or its app hidden) draws nothing.
        table.drawsWhileUnseenForTesting = false
        table.setNeedsMetalFrame()
        table.drawMetalFrameIfNeeded()
        #expect(NGTableView.metalFramesForTesting == frames + 1)
        withExtendedLifetime((data, window)) {}
    }
}
#endif
