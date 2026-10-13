#if os(macOS)
import AppKit

// Rows and cells of the visible area: which rows and columns are in view,
// placing row backgrounds and cells (the Metal renderer's frame model),
// reading values, recycling
// cells that leave the view, and what a default cell shows for a value.

extension NGTableView {
    // MARK: Rows and cells

    /// Makes row backgrounds and cells exist exactly for the visible area.
    /// What a layout pass placed, to skip scroll steps that bring nothing new.
    struct VisibleRange: Equatable {
        var rows: Range<Int>
        var centerColumns: Range<Int>
        var offsetX: CGFloat
    }

    /// Makes the next layout pass place every visible row and cell again.
    func invalidateVisibleRange() {
        lastVisibleRange = nil
    }

    /// The number of a column id in `NGCellKey`s.
    func columnOrdinal(of columnID: String) -> Int {
        if let ordinal = columnOrdinals[columnID] { return ordinal }
        let ordinal = columnOrdinals.count
        columnOrdinals[columnID] = ordinal
        return ordinal
    }

    /// A column as a layout pass places it: resolved once per pass, not per
    /// cell (and passed by reference, not copied for every cell).
    final class PlacedColumn {
        let frame: NGColumnFrame
        let ordinal: Int
        let x: CGFloat
        let isHidden: Bool

        init(frame: NGColumnFrame, ordinal: Int, x: CGFloat, isHidden: Bool) {
            self.frame = frame
            self.ordinal = ordinal
            self.x = x
            self.isHidden = isHidden
        }
    }

    func layoutVisibleContent(onlyIfVisibleRangeChanged: Bool = false) {
        // In a batch that moved rows (one can span an `await`), display rows
        // still mean the rows before its moves while the data source has the
        // new ones: rows are placed at its end, not read from the wrong records.
        guard rowUpdateBatch?.displayIsStale != true else { return }
        let metrics = layoutMetrics
        // A frame only if the pass changed something Metal draws.
        let changesAtStart = NGFrameModel.changes
        guard rowHeight > 0 else { return }

        // Include the rows scrolled underneath the translucent header.
        let firstRow = max(0, Int(floor((renderedOffsetY - metrics.headerHeight) / rowHeight)))
        // Rows past the data keep the stripe pattern, like NSTableView.
        let lastRow = Int(ceil((renderedOffsetY + metrics.bodyHeight) / rowHeight)) - 1
        let centerMinX = Double(metrics.leadingWidth + physicalOffsetX)
        let centerColumns = geometry.center.columns(intersecting: centerMinX, centerMinX + Double(metrics.centerWidth))

        let rows = firstRow..<max(firstRow, lastRow + 1)
        // Most scroll steps move the canvases only. (Horizontal offsets are part
        // of the key: rows at the trailing edge follow the visible width.)
        let visibleRange = VisibleRange(rows: rows, centerColumns: centerColumns.startIndex..<centerColumns.endIndex, offsetX: contentOffset.x)
        let isAnimating = !columnSlideOffsets.isEmpty || columnDrag != nil
        let previousRange = lastVisibleRange
        // Rows whose records changed, placed again whatever else happens.
        let placingAgain = rowsToPlaceAgain
        rowsToPlaceAgain = []
        func regionsAndColumns() -> ([NGRegionView], [(NGRegionView, [PlacedColumn])]) {
            (regions.filter { !$0.isHidden }, [
                (leadingRegion, placedColumns(geometry.leading.columns)),
                (centerRegion, placedColumns(centerColumns)),
                (trailingRegion, placedColumns(geometry.trailing.columns)),
            ])
        }
        if onlyIfVisibleRangeChanged, !isAnimating, visibleRange == previousRange {
            if !placingAgain.isEmpty {
                let (visibleRegions, columnsByRegion) = regionsAndColumns()
                for row in placingAgain where rows.contains(row) {
                    placeRow(row, regions: visibleRegions, columnsByRegion: columnsByRegion)
                }
                if NGFrameModel.changes != changesAtStart { setNeedsMetalFrame() }
            }
            return
        }
        lastVisibleRange = visibleRange
        let (visibleRegions, columnsByRegion) = regionsAndColumns()
        defer {
            if NGFrameModel.changes != changesAtStart { setNeedsMetalFrame() }
            // Rows may have changed under the pointer.
            updateHoveredCellFromPointer()
        }

        // Scrolling: only rows and columns that come and go change.
        if onlyIfVisibleRangeChanged, !isAnimating, let previousRange {
            let centerColumns = columnsByRegion[1].1
            let previousOrdinals = Set(lastCenterColumns.map(\.ordinal))
            let ordinals = Set(centerColumns.map(\.ordinal))
            let leavingColumns = lastCenterColumns.filter { !ordinals.contains($0.ordinal) }
            let enteringColumns = centerColumns.filter { !previousOrdinals.contains($0.ordinal) }
            let fixedColumns = columnsByRegion[0].1 + columnsByRegion[2].1
            for row in previousRange.rows where !rows.contains(row) {
                for region in visibleRegions {
                    if let layer = visibleRows.removeValue(forKey: NGRowKey(pin: region.pin, row: row)) {
                        layer.isHidden = true
                        rowPool.append(layer)
                    }
                }
                // A header's title may be keyed by a column scrolled away.
                if isGroupRow(row) {
                    recycleCells(ofRow: row)
                    continue
                }
                for column in fixedColumns + lastCenterColumns {
                    if let cell = visibleCells.removeValue(forKey: NGCellKey(row: row, column: column.ordinal)) {
                        recycle(cell)
                    }
                }
            }
            for row in previousRange.rows where rows.contains(row) && !isGroupRow(row) {
                for column in leavingColumns {
                    if let cell = visibleCells.removeValue(forKey: NGCellKey(row: row, column: column.ordinal)) {
                        recycle(cell)
                    }
                }
            }
            lastCenterColumns = centerColumns
            for row in rows {
                guard previousRange.rows.contains(row) else {
                    placeRow(row, regions: visibleRegions, columnsByRegion: columnsByRegion)
                    continue
                }
                // Rows at the trailing edge follow the visible width (their
                // colors stay: the delegate isn't asked again on every step).
                if previousRange.offsetX != visibleRange.offsetX {
                    for region in visibleRegions {
                        placeRowBackground(row: row, in: region, keepingColors: true)
                    }
                }
                guard row < numberOfRows else { continue }
                if let node = groupNode(atDisplayRow: row) {
                    if !enteringColumns.isEmpty || !leavingColumns.isEmpty {
                        placeGroupCells(row: row, node: node, columnsByRegion: columnsByRegion)
                    }
                    continue
                }
                for column in enteringColumns where !column.isHidden {
                    placeCell(row: row, column: column, in: centerRegion.canvas)
                }
            }
            // Rows that stayed in view but whose records changed.
            for row in placingAgain where rows.contains(row) && previousRange.rows.contains(row) {
                placeRow(row, regions: visibleRegions, columnsByRegion: columnsByRegion)
            }
            placeFloatingGroupHeaders(visibleRows: rows, regions: visibleRegions) {
                placeRow($0, regions: visibleRegions, columnsByRegion: columnsByRegion)
            }
            trimCellLayerPool()
            return
        }
        lastCenterColumns = columnsByRegion[1].1

        // Recycle what scrolled out first, so the views placed next can reuse
        // them instead of allocating new ones on big jumps.
        var neededRows = Set<NGRowKey>()
        var neededCells = Set<NGCellKey>()
        // Header rows place (and recycle) their own cells.
        var groupRows = Set<Int>()
        for row in rows {
            for region in visibleRegions {
                neededRows.insert(NGRowKey(pin: region.pin, row: row))
            }
            guard row < numberOfRows else { continue }
            if isGroupRow(row) {
                groupRows.insert(row)
                continue
            }
            for (_, columns) in columnsByRegion {
                for column in columns where !column.isHidden {
                    neededCells.insert(NGCellKey(row: row, column: column.ordinal))
                }
            }
        }
        let staleRows = visibleRows.keys.filter { !neededRows.contains($0) }
        for key in staleRows {
            if let layer = visibleRows.removeValue(forKey: key) {
                layer.isHidden = true
                rowPool.append(layer)
            }
        }
        let staleCells = visibleCells.keys.filter { !neededCells.contains($0) && !groupRows.contains($0.row) }
        for key in staleCells {
            if let cell = visibleCells.removeValue(forKey: key) {
                recycle(cell)
            }
        }

        for row in rows {
            placeRow(row, regions: visibleRegions, columnsByRegion: columnsByRegion)
        }
        floatingHeaderRows.subtract(rows)   // Recycled above unless still visible.
        placeFloatingGroupHeaders(visibleRows: rows, regions: visibleRegions) {
            placeRow($0, regions: visibleRegions, columnsByRegion: columnsByRegion)
        }
        trimCellLayerPool()
    }

    private func placedColumns<Frames: Collection<NGColumnFrame>>(_ frames: Frames) -> [PlacedColumn] {
        frames.map { frame in
            PlacedColumn(frame: frame, ordinal: columnOrdinal(of: frame.column.id),
                         x: CGFloat(frame.x) + slideOffset(forColumnID: frame.column.id),
                         isHidden: isHiddenForDrag(frame.column.id))
        }
    }

    private func placeRow(_ row: Int, regions: [NGRegionView], columnsByRegion: [(NGRegionView, [PlacedColumn])]) {
        rowPlacements += 1
        for region in regions {
            placeRowBackground(row: row, in: region)
        }
        guard row < numberOfRows else { return }
        if let node = groupNode(atDisplayRow: row) {
            placeGroupCells(row: row, node: node, columnsByRegion: columnsByRegion)
            return
        }
        for (region, columns) in columnsByRegion {
            for column in columns where !column.isHidden {
                placeCell(row: row, column: column, in: region.canvas)
            }
        }
    }

    /// Shows content in a header row's cell (made from the pool if needed).
    func placeGroupCell(_ key: NGCellKey, content: NGCellContent, frame: NSRect, in canvas: NGCanvasView) {
        let layer: NGDrawnCell
        if let existing = visibleCells[key] {
            layer = existing
        } else {
            if let other = visibleCells.removeValue(forKey: key) { recycle(other) }
            layer = cellLayerPool.popLast() ?? NGDrawnCell()
            layer.unresolvedSource = nil
        }
        layer.regionPin = canvas.region?.pin
        layer.isHighlighted = false
        layer.outline = nil
        layer.content = content
        layer.cellFrame = frame
        layer.isHidden = false
        visibleCells[key] = layer
    }

    /// Spares for the next pass only: stale cells are recycled before new
    /// ones are placed, so a big jump reuses them without a large pool.
    private func trimCellLayerPool() {
        if cellLayerPool.count > Self.cellLayerPoolLimit {
            cellLayerPool.removeLast(cellLayerPool.count - Self.cellLayerPoolLimit)
        }
    }

    private static let cellLayerPoolLimit = 128
    /// The frame of the cell at a point of a region's canvas, if it has a
    /// tool tip (see `cellToolTip(at:in:)`).
    func cellToolTipFrame(at point: NSPoint, in region: NGRegionView) -> NSRect? {
        guard !ignoresUserInput, let (cell, _) = cellUnderPoint(point, in: region),
              cellToolTip(at: point, in: region) != nil else { return nil }
        return cell.cellFrame
    }

    /// The tool tip of the cell at a point of a region's canvas: the
    /// delegate's, or a mark's label, a media cell's text, or the whole text
    /// of a cell too narrow for it (like NSTableView's expansion tool tips).
    func cellToolTip(at point: NSPoint, in region: NGRegionView) -> String? {
        guard let (cell, column) = cellUnderPoint(point, in: region) else { return nil }
        let row = Int(floor(point.y / rowHeight))
        let source = sourceRow(row)
        if source >= 0, let text = delegate?.tableView(self, toolTipForRow: source, column: column) {
            return text.isEmpty ? nil : text
        }
        switch cell.content {
        case .mark(let mark, _):
            return mark.label
        case .media(let media):
            return media.toolTip ?? media.lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        case .tags(let tags):
            let shaper = metalRenderer?.shaper
            return NGCellDrawing.fittingWidth(of: tags, shaper: shaper) > cell.cellFrame.width + 0.5
                ? tags.map(\.title).joined(separator: ", ") : nil
        default:
            guard let (text, font) = displayedText(of: cell), let shaper = metalRenderer?.shaper else { return nil }
            let available = max(0, cell.cellFrame.width - 2 * NGMetrics.cellPadding)
            return shaper.shape(text, font: font, width: .greatestFiniteMagnitude).width > available + 0.5 ? text : nil
        }
    }

    /// The visible cell at a point of a region's canvas, and its column.
    private func cellUnderPoint(_ point: NSPoint, in region: NGRegionView) -> (NGDrawnCell, NGTableColumn)? {
        // Canvas coordinates are the geometry's (scrolling columns start after the leading region).
        guard rowHeight > 0, let columnFrame = geometry[region.pin].column(atX: Double(point.x)) else { return nil }
        let row = Int(floor(point.y / rowHeight))
        guard let cell = visibleCells[NGCellKey(row: row, column: columnOrdinal(of: columnFrame.column.id))], !cell.isHidden
        else { return nil }
        return (cell, columnFrame.column)
    }

    /// The text a text-like cell shows and its font, as the renderer draws it.
    private func displayedText(of cell: NGDrawnCell) -> (String, NSFont)? {
        let style = metalStyle
        switch cell.content {
        case .text(let text, _, let monospacedDigits): return text.isEmpty ? nil : (text, monospacedDigits ? style.digitFont : style.textFont)
        case .number(let number, _): return (cell.displayedText ?? number.text, style.digitFont)
        case .subtotal(let text, _): return text.isEmpty ? nil : (text, style.boldDigitFont)
        default: return nil
        }
    }

    private func placeRowBackground(row: Int, in region: NGRegionView, keepingColors: Bool = false) {
        let key = NGRowKey(pin: region.pin, row: row)
        let existing = visibleRows[key]
        let view = existing ?? rowPool.popLast() ?? NGRowBackground()
        visibleRows[key] = view
        let keepsColors = keepingColors && existing != nil

        var frame = NSRect(
            x: region.pin == .none ? layoutMetrics.leadingWidth : 0,
            y: CGFloat(row) * rowHeight,
            width: region.pin == .none ? centerCanvasWidth - layoutMetrics.leadingWidth : region.canvas.frame.width,
            height: rowHeight
        )
        var corners: CACornerMask = []
        let isOuterLeading = region.pin == .leading || (region.pin == .none && geometry.leading.isEmpty)
        if selectionHighlightStyle == .rounded {
            // Like inset macOS lists: stripes and selections are inset from the
            // table's outer edges and rounded there; consecutive selected rows
            // merge into one block.
            let inset = NGMetrics.selectionInset
            let isOuterTrailing = region.pin == .trailing || (region.pin == .none && geometry.trailing.isEmpty)
            // The outer edges by side (mirrored right to left).
            let isOuterLeft = isRightToLeft ? isOuterTrailing : isOuterLeading
            let isOuterRight = isRightToLeft ? isOuterLeading : isOuterTrailing
            if isOuterLeft {
                if region.pin == .none, isRightToLeft {
                    // The trailing end is the visible left edge of the wider canvas.
                    let visibleLeft = layoutMetrics.leadingWidth + physicalOffsetX
                    frame.size.width = frame.maxX - visibleLeft
                    frame.origin.x = visibleLeft
                }
                frame.origin.x += inset
                frame.size.width -= inset
            }
            if isOuterRight {
                // The center canvas may be wider than the viewport; inset at the visible edge.
                if region.pin == .none, !isRightToLeft {
                    frame.size.width = layoutMetrics.leadingWidth + layoutMetrics.centerWidth + contentOffset.x - frame.minX
                }
                frame.size.width -= inset
            }
            let isSelected = isSelected(row)
            if isSelected, self.isSelected(row - 1) {
                // Like Finder: adjacent selected rows stay one block, split by a
                // hairline gap that shows the table background.
                frame.origin.y += hairline
                frame.size.height -= hairline
            }
            let roundsTop = !isSelected || !self.isSelected(row - 1)
            let roundsBottom = !isSelected || !self.isSelected(row + 1)
            // The views are flipped, so MinY corners are at the top on screen.
            if isOuterLeft, roundsTop { corners.insert(.layerMinXMinYCorner) }
            if isOuterLeft, roundsBottom { corners.insert(.layerMinXMaxYCorner) }
            if isOuterRight, roundsTop { corners.insert(.layerMaxXMinYCorner) }
            if isOuterRight, roundsBottom { corners.insert(.layerMaxXMaxYCorner) }
        }
        // The marker sits at the table's leading edge, so only in the outermost region.
        if !keepsColors {
            let marker = isOuterLeading && row < numberOfRows && !isGroupRow(row) ? delegate?.tableView(self, markerColorForRow: sourceRow(row)) : nil
            view.setColors(rowColor(row), marker: marker)
        }
        view.setShape(cornerRadius: corners.isEmpty ? 0 : NGMetrics.selectionCornerRadius, corners: corners)
        view.frame = frame
        view.isHidden = false
    }

    /// Marker colors of the visible rows in the outermost leading region (for tests).
    func rowBackgroundMarkerColors() -> [Int: NSColor] {
        var colors: [Int: NSColor] = [:]
        for (key, layer) in visibleRows {
            if let color = layer.markerColor { colors[key.row] = color }
        }
        return colors
    }

    private func isSelected(_ row: Int) -> Bool {
        isDisplayRowSelected(row)
    }

    private func placeCell(row: Int, column: PlacedColumn, in canvas: NGCanvasView) {
        let key = NGCellKey(row: row, column: column.ordinal)
        let cell = visibleCells[key] ?? makeCell(for: column.frame.column, ordinal: column.ordinal, row: row, readsValue: false)
        let cellFrame = NSRect(x: column.x, y: CGFloat(row) * rowHeight, width: CGFloat(column.frame.width), height: rowHeight)
        cell.regionPin = canvas.region?.pin
        cell.cellFrame = cellFrame
        cell.showsChoiceChevron = Self.showsChoiceChevron(column.frame.column)
        if cell.unresolvedSource == nil, isShowingRowTree {
            // Kept: its row may have got or lost children since.
            cell.outline = outline(forDisplayRow: row, column: column.frame.column)
        }
        resolveContent(of: cell)
        cell.isHidden = false
        visibleCells[key] = cell
    }

    /// The outline cells of a tree that stay after an update: rows whose
    /// children came or went weren't read again themselves.
    func refreshTreeOutlines() {
        guard isShowingRowTree, let id = outlineColumnID, let column = columnLayout.columnsByID[id] else { return }
        let ordinal = columnOrdinal(of: id)
        for (key, cell) in visibleCells where key.column == ordinal && cell.unresolvedSource == nil {
            cell.outline = outline(forDisplayRow: key.row, column: column)
        }
    }

    /// Whether a column's cells show the pop-up chevron: editable, with choices.
    static func showsChoiceChevron(_ column: NGTableColumn) -> Bool {
        column.isEditable && !(column.editChoices?.isEmpty ?? true)
    }

    func visibleCell(row: Int, columnID: String) -> NGDrawnCell? {
        visibleCells[NGCellKey(row: row, column: columnOrdinal(of: columnID))]
    }

    /// A cell for the value of a column and display row.
    /// - Parameter readsValue: `false` leaves reading the value to the
    ///   layout pass that places the cell.
    func makeCell(for column: NGTableColumn, ordinal: Int? = nil, row: Int, readsValue: Bool = true) -> NGDrawnCell {
        let layer = cellLayerPool.popLast() ?? NGDrawnCell()
        layer.unresolvedSource = (column, ordinal ?? columnOrdinal(of: column.id), row)
        layer.isHighlighted = isHighlighted(row: row)
        if readsValue {
            resolveContent(of: layer)
        }
        return layer
    }

    /// Reads the value of a cell made without it.
    func resolveContent(of layer: NGDrawnCell) {
        guard let (column, ordinal, row) = layer.unresolvedSource else { return }
        layer.unresolvedSource = nil
        layer.content = cellContent(for: value(of: column, row: row), in: column, ordinal: ordinal)
        layer.outline = outline(forDisplayRow: row, column: column)
    }

    private func value(of column: NGTableColumn, row: Int) -> NGCellValue {
        guard row < numberOfRows else { return .empty }
        let source = sourceRow(row)
        return source >= 0 ? dataSource?.tableView(self, valueFor: column, row: source) ?? .empty : .empty
    }

    /// What a default cell shows for a value. Numbers stay numbers: they are
    /// formatted when drawn (see `NGCellContent.number`).
    /// - Parameter ordinal: The column's number, which finds its format id
    ///   without hashing the format.
    func cellContent(for value: NGCellValue, in column: NGTableColumn, ordinal: Int? = nil) -> NGCellContent {
        switch value {
        case .media(let media):
            return .media(media)
        case .sparkline(let sparkline):
            return .sparkline(sparkline)
        case .link(let link):
            return .link(link, alignment: column.alignment.textAlignment(isNumeric: false, layoutDirection: contentLayoutDirection))
        case .button(let button):
            return .button(button, alignment: column.alignment.textAlignment(isNumeric: false, layoutDirection: contentLayoutDirection))
        case .rating(let value, let maximum):
            return .rating(value, maximum: maximum, isEditable: column.isEditable,
                           alignment: column.alignment.textAlignment(isNumeric: false, layoutDirection: contentLayoutDirection))
        case .progress(let value, let total):
            // Written beside the bar only with a format on the column.
            let fraction = NGCellValue.fraction(value, total)
            if case .automatic = column.format { return .progress(fraction: fraction, text: nil, reserved: nil) }
            return .progress(fraction: fraction, text: fraction.map { column.format.string(for: $0, locale: formattingLocale) },
                             reserved: column.format.string(for: Double(1), locale: formattingLocale))
        case .mark(let mark):
            return .mark(mark, alignment: column.alignment.textAlignment(isNumeric: false, layoutDirection: contentLayoutDirection))
        case .tags(let tags):
            return .tags(tags)
        case .bool(let flag) where column.isEditable && column.editChoices == nil:
            return .mark(Self.checkBoxMark(flag),
                         alignment: column.alignment.textAlignment(isNumeric: false, layoutDirection: contentLayoutDirection))
        case .number(let number):
            let formatID = ordinal.map { self.formatID(ofColumn: column, ordinal: $0) } ?? NGFormatIDs.id(of: column.format, locale: locale)
            return .number(NGFormattedNumber(value: number, format: column.format, formatID: formatID),
                           alignment: column.alignment.textAlignment(isNumeric: true, layoutDirection: contentLayoutDirection))
        default:
            let isNumeric = column.isNumeric
            return .text(column.format.string(for: value, locale: formattingLocale), alignment: column.alignment.textAlignment(isNumeric: isNumeric, layoutDirection: contentLayoutDirection),
                         monospacedDigits: isNumeric)
        }
    }

    private func formatID(ofColumn column: NGTableColumn, ordinal: Int) -> Int {
        if ordinal < columnFormatIDs.count, let id = columnFormatIDs[ordinal] { return id }
        let id = NGFormatIDs.id(of: column.format, locale: locale)
        if ordinal >= columnFormatIDs.count {
            columnFormatIDs.append(contentsOf: repeatElement(nil, count: ordinal + 1 - columnFormatIDs.count))
        }
        columnFormatIDs[ordinal] = id
        return id
    }

    /// Numbers are formatted in the user's locale: format them again.
    @objc func currentLocaleDidChange(_ notification: Notification) {
        NGFormatIDs.localeDidChange()
        NGTextCollation.localeDidChange()
        columnFilterPasses = [:]
        for layer in visibleCells.values {
            layer.displayedText = nil
        }
        for layer in cellLayerPool {
            layer.displayedText = nil
        }
        setNeedsMetalFrame()
        needsLayout = true
        // Summary texts are formatted in the locale too.
        updateSummary()
        // Inside a batch its rows aren't laid out until it ends: then.
        if rowUpdateBatch != nil {
            localeChangedDuringBatch = true
        } else {
            readLocaleDependentKeysAgain()
        }
    }

    /// Search words, group keys and column filters' values are formatted text
    /// too: read again; the table's sort of text follows the new language's rules.
    func readLocaleDependentKeysAgain() {
        if sortsRows, !sortDescriptors.isEmpty {
            sortOrderNeedsRebuild = true
            applyTableSort()
        }
        guard searchIndex != nil || searchBuild != nil || groupKeys != nil || !columnFilters.isEmpty else { return }
        searchIndex = nil
        cancelSearchBuild()
        groupKeys = nil
        filterNeedsFullEvaluation = true
        applyRowFilter()
    }

    /// Spare cells are kept, hidden, for the next cells to show.
    func recycle(_ cell: NGDrawnCell) {
        // A cell gone from view (outside a layout pass too).
        setNeedsMetalFrame()
        cell.isHidden = true
        cell.unresolvedSource = nil
        cell.outline = nil
        cell.isPointerOver = false
        cell.isPressed = false
        cell.previewRating = nil
        cellLayerPool.append(cell)
    }

    func recycleAllCells() {
        for cell in visibleCells.values {
            recycle(cell)
        }
        visibleCells.removeAll()
        lastVisibleRange = nil
    }

    /// After rows moved (targeted updates): visible cells move with their
    /// records to their new display rows, keeping what they show. Cells of
    /// rows that are gone or hidden, or whose values changed, are recycled.
    /// - Parameter newRow: The new display row of an old one's cells, or `nil`.
    /// - Parameter keeping: Old display rows whose cells, gone, are returned
    ///   instead of recycled (they fade out in a row animation).
    @discardableResult
    func moveVisibleCells(keeping: Set<Int> = [], to newRow: (Int) -> Int?) -> [NGDrawnCell] {
        setNeedsMetalFrame()
        var moved: [NGCellKey: NGDrawnCell] = [:]
        var kept: [NGDrawnCell] = []
        moved.reserveCapacity(visibleCells.count)
        for (key, cell) in visibleCells {
            guard let row = newRow(key.row), row >= 0, row < numberOfRows else {
                if keeping.contains(key.row) {
                    kept.append(cell)
                } else {
                    recycle(cell)
                }
                continue
            }
            let newKey = NGCellKey(row: row, column: key.column)
            guard moved[newKey] == nil else {
                recycle(cell)
                continue
            }
            // The highlight follows the selection at the new row.
            cell.isHighlighted = isHighlighted(row: row)
            moved[newKey] = cell
        }
        visibleCells = moved
        lastVisibleRange = nil
        return kept
    }

    /// Vertical grid lines are drawn with the rows (see `appendVerticalGridLines`).
    func layoutGridLines(height: CGFloat) {
        setNeedsMetalFrame()
    }
}
#endif
