#if os(macOS)
import AppKit

// Rows as high as their wrapped text. When a shown column wraps text
// (`NGTableColumn.wrapsText`) and the delegate doesn't give heights
// (`NGTableViewRowHeights`), the table measures each row: the most lines
// its wrapped cells take, laid out as they are drawn (`appendWrappedText`).
// Heights are kept by row handle like a delegate's: they follow their
// records through sorts, filters and groups, and reloaded rows are measured
// again. Small tables are measured at once; in large ones the rows in view
// are, and the others in the background (their texts read in slices, their
// lines counted on all cores, see NGSimpleWrap.swift), counting as
// `rowHeight` until then; while rows above the top of the view grow, the
// scroll position keeps the top row where it is on screen. A wrapping
// column's new width, the font or `rowHeight` measures every row again.

extension NGTableView {
    /// Up to this many rows, all are measured at once (a scroller of the
    /// true height); more, as they come into view.
    static let measuredAtOnceLimit = 2_000

    /// Whether the table measures rows by their wrapped text.
    var measuresRowHeights: Bool { wrapsTextInSomeColumn && rowHeightProvider == nil }

    /// The shown columns that wrap text, with their widths.
    private var wrappingColumnFrames: [NGColumnFrame] {
        (geometry.leading.columns + geometry.center.columns + geometry.trailing.columns).filter { $0.column.wrapsText }
    }

    /// The texts of a row's wrapped cells, as they are drawn: in what width,
    /// how many lines at most, each line how high (see `appendWrappedText`).
    private func wrappedTexts(ofSourceRow row: Int, columns: [NGColumnFrame], shaper: NGTextShaper,
                              style: MetalStyle) -> [NGWrappedText] {
        guard let dataSource else { return [] }
        var texts: [NGWrappedText] = []
        for frame in columns {
            // The width the text is drawn in (see `appendContentLeftToRight`).
            let width = CGFloat(frame.width) - cellSpacing.width - 2 * NGMetrics.cellPadding
            guard width > 0 else { continue }
            let value = dataSource.tableView(self, valueFor: frame.column, row: row)
            guard case .text(let text, _, let monospacedDigits) = cellContent(for: value, in: frame.column), !text.isEmpty else { continue }
            let font = monospacedDigits ? style.digitFont : style.textFont
            texts.append(NGWrappedText(text: text, font: font, width: width, lineLimit: frame.column.lineLimit,
                                       lineHeight: NGLineHeights.height(of: font)))
        }
        return texts
    }

    /// The height a row's wrapped texts need: one line is `rowHeight`, each
    /// more a line of its font, as `shapeLines` draws them (thread-safe).
    nonisolated static func height(of texts: [NGWrappedText], rowHeight: CGFloat, engine: NGTextEngine) -> CGFloat {
        var metrics: [ObjectIdentifier: (font: CTFont, id: Int, metrics: NGSimpleFontMetrics)] = [:]
        return height(of: texts, rowHeight: rowHeight, engine: engine, metrics: &metrics)
    }

    /// The same with the fonts' ids and copies of their metrics the caller
    /// keeps, by font object (looking them up takes a lock all workers share).
    private nonisolated static func height(of texts: [NGWrappedText], rowHeight: CGFloat, engine: NGTextEngine,
                                           metrics: inout [ObjectIdentifier: (font: CTFont, id: Int, metrics: NGSimpleFontMetrics)]) -> CGFloat {
        var height = rowHeight
        for text in texts {
            let key = ObjectIdentifier(text.font)
            var entry = metrics[key] ?? {
                let id = engine.fonts.id(of: text.font)
                return (text.font, id, engine.metrics.metrics(of: id))
            }()
            let lines = engine.lineCount(of: text.text, font: text.font, fontID: entry.id, width: text.width, maximumLines: text.lineLimit,
                                         metrics: &entry.metrics)
            metrics[key] = entry
            height = max(height, rowHeight + CGFloat(lines - 1) * text.lineHeight)
        }
        return height
    }

    /// The heights of many rows' wrapped texts, on all cores (each worker
    /// with its own copies of the metrics).
    nonisolated static func heights(of rows: [[NGWrappedText]], rowHeight: CGFloat, engine: NGTextEngine) -> [CGFloat] {
        var heights = [CGFloat](repeating: rowHeight, count: rows.count)
        let input = NGUncheckedSendable(rows)
        heights.withUnsafeMutableBufferPointer { buffer in
            let output = NGUncheckedSendable(buffer)
            let chunks = min(rows.count, ProcessInfo.processInfo.activeProcessorCount * 2)
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                var metrics: [ObjectIdentifier: (font: CTFont, id: Int, metrics: NGSimpleFontMetrics)] = [:]
                for index in stride(from: chunk, to: input.value.count, by: chunks) {
                    output.value[index] = height(of: input.value[index], rowHeight: rowHeight, engine: engine, metrics: &metrics)
                }
            }
        }
        return heights
    }

    private func measuredHeight(ofSourceRow row: Int, columns: [NGColumnFrame], shaper: NGTextShaper, style: MetalStyle) -> CGFloat {
        Self.height(of: wrappedTexts(ofSourceRow: row, columns: columns, shaper: shaper, style: style), rowHeight: rowHeight,
                    engine: shaper.engine)
    }

    /// What measured heights depend on: the wrapping columns' widths and line
    /// limits, the fonts, the spacing and `rowHeight`.
    private func measuredRowsKey(_ columns: [NGColumnFrame], style: MetalStyle) -> [Double] {
        var key: [Double] = [Double(rowHeight), Double(cellSpacing.width), Double(style.textFont.pointSize), Double(style.digitFont.pointSize)]
        for frame in columns {
            key.append(frame.width)
            key.append(Double(frame.column.maximumNumberOfLines))
        }
        return key
    }

    /// Gets the measured heights ready: forgets them all if what they
    /// depend on changed, makes room for new rows.
    /// - Returns: The columns, shaper and style to measure with (`nil`: no
    ///   measuring now), and whether heights were forgotten.
    private func prepareMeasuring() -> (columns: [NGColumnFrame], shaper: NGTextShaper, style: MetalStyle, forgot: Bool)? {
        guard measuresRowHeights, rowUpdateDepth == 0, rowUpdateBatch?.displayIsStale != true,
              let shaper = metalRenderer?.shaper else { return nil }
        let columns = wrappingColumnFrames
        let style = metalStyle
        var forgot = false
        let key = measuredRowsKey(columns, style: style)
        if key != lastMeasuredRowsKey {
            lastMeasuredRowsKey = key
            forgetAllRowHeights()
            forgot = true
        }
        if rowHeightsByHandle.count < rowHandles.capacity {
            rowHeightsByHandle.append(contentsOf: repeatElement(.nan, count: rowHandles.capacity - rowHeightsByHandle.count))
        }
        return (columns, shaper, style, forgot)
    }

    /// Measures the display rows not measured yet.
    /// - Returns: Whether one is higher than its estimate (`rowHeight`).
    private func measure(_ displayRows: Range<Int>, columns: [NGColumnFrame], shaper: NGTextShaper, style: MetalStyle) -> Bool {
        var measured = false
        for displayRow in displayRows.clamped(to: 0..<numberOfRows) {
            let row = sourceRow(displayRow)
            guard row >= 0 else { continue }
            let handle = handle(ofRow: row)
            guard handle >= 0, handle < rowHeightsByHandle.count, rowHeightsByHandle[handle].isNaN else { continue }
            let height = measuredHeight(ofSourceRow: row, columns: columns, shaper: shaper, style: style)
            rowHeightsByHandle[handle] = height
            // A row of one line was counted as one already.
            if height != rowHeight { measured = true }
        }
        if measured { rowGeometryCache = nil }
        return measured
    }

    /// Measures the rows in view (all of them in a small table) not measured
    /// yet, keeping the top row in place on screen while rows above it grow.
    /// Returns whether a height changed (the content height may have).
    @discardableResult
    func measureRowsInView() -> Bool {
        guard let (columns, shaper, style, forgot) = prepareMeasuring() else { return false }
        if numberOfSourceRows <= Self.measuredAtOnceLimit {
            return measure(0..<numberOfRows, columns: columns, shaper: shaper, style: style) || forgot
        }
        // Rows measured taller leave room for fewer: a few rounds until all
        // the rows in view are measured.
        let headerHeight = layoutMetrics.headerHeight
        let changed = keepingTopRowInPlace {
            var changed = forgot
            for _ in 0..<4 {
                let rows = rowGeometry
                let first = max(0, Int(floor(rows.position(atY: renderedOffsetY - headerHeight))))
                let last = min(numberOfRows, Int(ceil(rows.position(atY: renderedOffsetY + bounds.height))))
                guard first < last, measure(first..<last, columns: columns, shaper: shaper, style: style) else { break }
                changed = true
            }
            return changed
        }
        startMeasuringInBackground()
        return changed
    }

    /// Changes heights so that the row at the top of the view (below the
    /// header) stays where it is on screen.
    /// - Returns: What `change` returns: whether heights changed.
    private func keepingTopRowInPlace(_ change: () -> Bool) -> Bool {
        let before = rowGeometry
        let anchor = max(0, Int(floor(before.position(atY: contentOffset.y))))
        let into = contentOffset.y - before.top(of: anchor)
        guard change() else { return false }
        if contentOffset.y > 0 {
            contentOffset.y = max(0, rowGeometry.top(of: anchor) + into)
        }
        return true
    }

    /// Before scrolling to a row of a large table: measures it and the rows
    /// that would share the view with it, at its top or bottom, so it is
    /// scrolled to by their true heights.
    func measureRows(around displayRow: Int) {
        guard numberOfSourceRows > Self.measuredAtOnceLimit, let (columns, shaper, style, _) = prepareMeasuring() else { return }
        // Each row is at least `rowHeight`: a view's worth of them either side.
        let reach = Int(ceil(bounds.height / rowHeight)) + 1
        if measure(displayRow - reach..<displayRow + reach + 1, columns: columns, shaper: shaper, style: style) {
            layoutMetrics = computeLayoutMetrics()
            needsLayout = true
        }
    }
}

// MARK: Measuring in the background

/// A wrapped cell's text to measure (thread-safe: its font is an immutable
/// Core Foundation object).
struct NGWrappedText: @unchecked Sendable {
    let text: String
    let font: CTFont
    let width: CGFloat
    let lineLimit: Int
    let lineHeight: CGFloat
}

extension NGTableView {
    /// Rows of a large table read for measuring at once, at most.
    private static let measuringSliceRows = 4_096

    /// Whether the rows of a large table are being measured in the background.
    var isMeasuringRows: Bool { measuringTask != nil }

    /// In a large table, measures the rows not in view in the background, so
    /// the content (and the scroller) gets the rows' true height: their texts
    /// are read on the main actor in slices of a few milliseconds, their lines
    /// counted on all cores, and their heights put in while the top row keeps
    /// its place. Rows reloaded or inserted meanwhile are measured in turn.
    private func startMeasuringInBackground() {
        guard measuringTask == nil, rowsLeftToMeasure, numberOfSourceRows > Self.measuredAtOnceLimit else { return }
        measuringTask = Task { [weak self] in
            var foundInPass = false
            while true {
                await Task.yield()
                guard !Task.isCancelled, let table = self else { return }
                guard table.measuresRowHeights, table.numberOfSourceRows > Self.measuredAtOnceLimit else {
                    table.measuringTask = nil
                    return
                }
                // Between batches, with the rows' texts as drawn.
                guard let (columns, shaper, style, _) = table.prepareMeasuring() else {
                    try? await Task.sleep(for: .milliseconds(5))
                    continue
                }
                let generation = table.measuringGeneration
                let (handles, texts, wrapped) = table.readRowsToMeasure(columns: columns, shaper: shaper, style: style)
                if !handles.isEmpty { foundInPass = true }
                if wrapped {
                    // A pass over every row that found none to measure: done.
                    if !foundInPass {
                        table.rowsLeftToMeasure = false
                        table.measuringTask = nil
                        return
                    }
                    foundInPass = false
                }
                guard !handles.isEmpty else { continue }
                table.measuringForgotten = []
                table.measuringSliceWasReadForTesting?()
                let rowHeight = table.rowHeight
                let engine = shaper.engine
                let heights = await Task.detached(priority: .utility) {
                    NGTableView.heights(of: texts, rowHeight: rowHeight, engine: engine)
                }.value
                guard !Task.isCancelled, let table = self else { return }
                table.putMeasuredHeights(heights, of: handles, generation: generation)
            }
        }
    }

    /// Reads the texts of rows not measured yet, from `measuringNext` on,
    /// for a few milliseconds.
    /// - Returns: The rows (handles), their texts, and whether the pass
    ///   reached the last handle (it starts over at the first).
    private func readRowsToMeasure(columns: [NGColumnFrame], shaper: NGTextShaper, style: MetalStyle)
        -> (handles: [Int], texts: [[NGWrappedText]], wrapped: Bool) {
        let capacity = min(rowHandles.capacity, rowHeightsByHandle.count)
        let deadline = ContinuousClock.now.advanced(by: NGTableView.backgroundSlice)
        var handles: [Int] = [], texts: [[NGWrappedText]] = []
        var handle = min(measuringNext, capacity)
        while handle < capacity, handles.count < Self.measuringSliceRows {
            if rowHeightsByHandle[handle].isNaN {
                let row = row(ofHandle: handle)
                if row >= 0 {
                    handles.append(handle)
                    texts.append(wrappedTexts(ofSourceRow: row, columns: columns, shaper: shaper, style: style))
                    if handles.count.isMultiple(of: 64), ContinuousClock.now >= deadline { handle += 1; break }
                }
            }
            handle += 1
        }
        let wrapped = handle >= capacity
        measuringNext = wrapped ? 0 : handle
        return (handles, texts, wrapped)
    }

    /// Puts in heights measured in the background (but not of rows reloaded
    /// or reused since they were read), keeping the top row in place.
    private func putMeasuredHeights(_ heights: [CGFloat], of handles: [Int], generation: Int) {
        let forgotten = measuringForgotten
        measuringForgotten = []
        // (Getting ready forgets every height if the widths changed.)
        _ = prepareMeasuring()
        guard measuringGeneration == generation else { return }
        let changed = keepingTopRowInPlace {
            var changed = false
            for (index, handle) in handles.enumerated() where handle < rowHeightsByHandle.count
                && rowHeightsByHandle[handle].isNaN && !forgotten.contains(handle) {
                let height = heights[index]
                rowHeightsByHandle[handle] = height
                if height != rowHeight { changed = true }
            }
            if changed { rowGeometryCache = nil }
            return changed
        }
        guard changed else { return }
        layoutMetrics = computeLayoutMetrics()
        needsLayout = true
    }
}
#endif
