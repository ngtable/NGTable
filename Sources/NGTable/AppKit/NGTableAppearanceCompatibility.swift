#if os(macOS)
import AppKit

// NSTableView's appearance properties by their names, mapped onto the
// table's own: the header shown or hidden (`headerView = nil` in
// NSTableView), grid lines and their color, the background, the spacing
// between cells, the style (inset or full width), the row size, and cell
// frames for rows out of view.

extension NGTableView {
    // MARK: Header

    /// Whether the column header shows, like NSTableView's `headerView`
    /// being set (`headerView = nil` hides it there). Without it, rows start
    /// at the top; sorting and resizing by the header aren't available.
    public var showsHeader: Bool {
        get { !hidesHeader }
        set {
            guard newValue == hidesHeader else { return }
            hidesHeader = !newValue
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    // MARK: Grid

    /// The grid lines between cells, like NSTableView's `gridStyleMask`:
    /// vertical lines between columns, solid or dashed horizontal lines
    /// between rows.
    public var gridStyleMask: NSTableView.GridLineStyle {
        get {
            var mask: NSTableView.GridLineStyle = []
            if showsVerticalGridLines { mask.insert(.solidVerticalGridLineMask) }
            switch horizontalGridLines {
            case .solid: mask.insert(.solidHorizontalGridLineMask)
            case .dashed: mask.insert(.dashedHorizontalGridLineMask)
            case .none: break
            }
            return mask
        }
        set {
            showsVerticalGridLines = newValue.contains(.solidVerticalGridLineMask)
            horizontalGridLines = newValue.contains(.solidHorizontalGridLineMask) ? .solid
                : newValue.contains(.dashedHorizontalGridLineMask) ? .dashed : .none
            setNeedsMetalFrame()
        }
    }

    /// The color of the grid lines, like NSTableView's (`.gridColor` by default).
    public var gridColor: NSColor {
        get { gridLineColor }
        set {
            gridLineColor = newValue
            setNeedsMetalFrame()
        }
    }

    // MARK: Colors and spacing

    /// The color behind the rows, like NSTableView's (the table style's
    /// background, `controlBackgroundColor` by default).
    public var backgroundColor: NSColor {
        get { tableStyle.backgroundColor ?? .controlBackgroundColor }
        set { tableStyle.backgroundColor = newValue }
    }

    /// Room between cells, like NSTableView's `intercellSpacing`, added to
    /// the table's own: the width keeps the cells' content further from the
    /// column edges (half on each side), the height makes rows taller.
    /// `.zero` (the default) is the table's own spacing.
    public var intercellSpacing: NSSize {
        get { cellSpacing }
        set {
            let spacing = NSSize(width: max(0, newValue.width), height: max(0, newValue.height))
            guard spacing != cellSpacing else { return }
            let extraHeight = spacing.height - cellSpacing.height
            cellSpacing = spacing
            rowHeight = max(1, rowHeight + extraHeight)
            recycleAllCells()
            setNeedsMetalFrame()
        }
    }

    // MARK: Style and row size

    /// The table's style, like NSTableView's: `.inset`, `.sourceList` and
    /// `.automatic` draw rows inset with rounded corners (the default);
    /// `.fullWidth` and `.plain` across the whole width.
    public var style: NSTableView.Style {
        get { selectionHighlightStyle == .rounded ? .inset : .fullWidth }
        set { selectionHighlightStyle = (newValue == .fullWidth || newValue == .plain) ? .fullWidth : .rounded }
    }

    /// The row size, like NSTableView's `rowSizeStyle`, as the table's
    /// `density`: small is compact, medium (and default) regular, large
    /// spacious; custom is a `rowHeight` set by the app.
    public var rowSizeStyle: NSTableView.RowSizeStyle {
        get {
            switch density {
            case .compact: .small
            case .regular: .medium
            case .spacious: .large
            case nil: .custom
            }
        }
        set {
            switch newValue {
            case .small: density = .compact
            case .medium, .default: density = .regular
            case .large: density = .spacious
            case .custom: density = nil
            @unknown default: density = .regular
            }
        }
    }

    // MARK: Geometry

    /// The frame of a cell in the table's coordinates, like NSTableView's
    /// `frameOfCell(atColumn:row:)`: also for rows and columns scrolled out
    /// of view (`frameOfCell(row:columnID:)` gives only visible cells).
    /// `NSZeroRect` for a row or column that isn't shown.
    public func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let columnFrame = rect(ofColumn: column), rowFrame = rect(ofRow: row)
        guard !columnFrame.isEmpty, !rowFrame.isEmpty else { return .zero }
        return NSRect(x: columnFrame.minX, y: rowFrame.minY, width: columnFrame.width, height: rowFrame.height)
    }

    // MARK: Drawing

    /// Horizontal grid lines under the visible rows of a region.
    /// Lines after each column of a region (right to left before it), with
    /// the rows: under floating headers, the focus ring and the drop
    /// indicator, and moving with a column being dragged.
    func appendVerticalGridLines(in region: NGRegionView, origin: CGPoint, clip: CGRect, scale: CGFloat, style: MetalStyle,
                                 to quads: inout [NGMetalQuad]) {
        guard showsVerticalGridLines else { return }
        let color = style.color(gridLineColor)
        for column in geometry[region.pin].columns {
            let edge = isRightToLeft ? CGFloat(column.x) : CGFloat(column.maxX) - 1
            let x = origin.x + edge + slideOffset(forColumnID: column.column.id)
            guard x + 1 > clip.minX, x < clip.maxX else { continue }
            quads.append(NGMetalRenderer.rectangle(NSRect(x: x, y: clip.minY, width: 1, height: clip.height),
                                                   scale: scale, color: color, clip: clip))
        }
    }

    func appendHorizontalGridLines(_ rows: [(row: NGRowBackground, displayRow: Int)], origin: CGPoint, clip: CGRect,
                                   scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) {
        guard horizontalGridLines != .none else { return }
        let color = style.color(gridLineColor)
        let line = 1 / scale
        for (row, _) in rows {
            let frame = row.frame.offsetBy(dx: origin.x, dy: origin.y)
            let y = frame.maxY - line
            if horizontalGridLines == .solid {
                quads.append(NGMetalRenderer.rectangle(NSRect(x: clip.minX, y: y, width: clip.width, height: line),
                                                       scale: scale, color: color, clip: clip))
            } else {
                // Dashes scroll with the columns (from the canvas's origin, not the visible edge).
                var x = clip.minX - (clip.minX - origin.x).truncatingRemainder(dividingBy: 4)
                while x < clip.maxX {
                    quads.append(NGMetalRenderer.rectangle(NSRect(x: x, y: y, width: 2, height: line), scale: scale, color: color, clip: clip))
                    x += 4
                }
            }
        }
    }
}

extension NGTableView {
    /// Right to left (`.rightToLeft`), the table is mirrored: the first column
    /// at the right, leading frozen columns at the right edge and trailing ones
    /// at the left, the vertical scroller at the left, and each cell's content
    /// mirrored too (text reads as written). Follows the app's language.
    public override var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection {
        didSet {
            guard userInterfaceLayoutDirection != oldValue else { return }
            mirroredCenterSpan = 0
            updateGeometry()
            recycleAllCells()
            needsLayout = true
            layoutSubtreeIfNeeded()
            headerView.needsDisplay = true
            summaryBar.contentView.needsDisplay = true
            setNeedsMetalFrame()
        }
    }
}

/// Horizontal grid lines (see `NGTableView.gridStyleMask`).
enum NGHorizontalGridLines {
    case none, solid, dashed
}
#endif

#if os(macOS)
extension NGTableView {
    // MARK: Column autoresizing

    /// How columns take up a change of the table's width, like
    /// NSTableView's `columnAutoresizingStyle`: none (the default here,
    /// NSTableView's is uniform), all resizable columns equally, the last or
    /// first one first and then the next, or only the last or first column.
    /// Columns keep their minimum and maximum widths.
    public var columnAutoresizingStyle: NSTableView.ColumnAutoresizingStyle {
        get { autoresizingStyle }
        set { autoresizingStyle = newValue }
    }

    /// Makes the last column as wide as the room left, like NSTableView's
    /// `sizeLastColumnToFit()` (within its minimum and maximum width).
    public func sizeLastColumnToFit() {
        guard let last = columnLayout.allColumns.last(where: \.isResizable) else { return }
        distributeColumnWidth(freeColumnWidth, among: [last])
    }

    /// Makes the columns fill the table's width, the room shared equally
    /// among the resizable ones, like NSTableView's `sizeToFit()`.
    public func sizeToFit() {
        distributeColumnWidth(freeColumnWidth, among: columnLayout.allColumns.filter(\.isResizable))
    }

    /// The room left beside the columns in the table's width (negative when
    /// they are wider).
    private var freeColumnWidth: Double {
        let metrics = computeLayoutMetrics()
        let used = geometry.leading.width + geometry.center.width + geometry.trailing.width
        let available = Double(metrics.leadingWidth + metrics.centerWidth + metrics.trailingWidth)
        return available - used
    }

    /// The table's width changed (in `layout()`): columns take up the
    /// difference by `columnAutoresizingStyle`.
    func autoresizeColumns(toWidth width: CGFloat) {
        defer { lastAutoresizedWidth = width }
        guard autoresizingStyle != .noColumnAutoresizing, let previous = lastAutoresizedWidth, previous != width,
              !columnLayout.allColumns.isEmpty else { return }
        let resizable = columnLayout.allColumns.filter(\.isResizable)
        // What rounding to pixels left over from the last steps comes along:
        // a slow live resize in 1-point steps moves the columns too.
        let delta = Double(width - previous) + autoresizeCarry
        autoresizeCarry = 0
        switch autoresizingStyle {
        case .uniformColumnAutoresizingStyle: distributeColumnWidth(delta, among: resizable, carrying: true)
        case .sequentialColumnAutoresizingStyle: distributeColumnWidth(delta, among: resizable.reversed(), sequentially: true, carrying: true)
        case .reverseSequentialColumnAutoresizingStyle: distributeColumnWidth(delta, among: resizable, sequentially: true, carrying: true)
        case .lastColumnOnlyAutoresizingStyle: distributeColumnWidth(delta, among: resizable.last.map { [$0] } ?? [], carrying: true)
        case .firstColumnOnlyAutoresizingStyle: distributeColumnWidth(delta, among: resizable.first.map { [$0] } ?? [], carrying: true)
        default: break
        }
    }

    /// Adds `delta` points to columns' widths: shared equally (what a column
    /// can't take for its limits goes to the others), or one after another.
    /// Widths are whole pixels; with `carrying`, what rounding left out is
    /// kept for the next call (`autoresizeCarry`).
    private func distributeColumnWidth(_ delta: Double, among columns: [NGTableColumn], sequentially: Bool = false,
                                       carrying: Bool = false) {
        guard carrying ? delta != 0 : abs(delta) >= 0.5, !columns.isEmpty else { return }
        var widths = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, width(ofColumnID: $0.id) ?? $0.width) })
        let old = widths
        var remaining = delta
        if sequentially {
            for column in columns where abs(remaining) >= 0.5 {
                let current = widths[column.id] ?? column.width
                let target = min(max(current + remaining, column.minWidth), column.maxWidth)
                remaining -= target - current
                widths[column.id] = target
            }
        } else {
            // Shared equally; columns at a limit leave the rest to the others.
            var open = columns
            while abs(remaining) >= 0.5, !open.isEmpty {
                let share = remaining / Double(open.count)
                var stillOpen: [NGTableColumn] = []
                for column in open {
                    let current = widths[column.id] ?? column.width
                    let target = min(max(current + share, column.minWidth), column.maxWidth)
                    remaining -= target - current
                    widths[column.id] = target
                    if target == current + share { stillOpen.append(column) }
                }
                if stillOpen.count == open.count { break }
                open = stillOpen
            }
        }
        // Columns whose width changes by a pixel or more (and only they tell).
        var changed: [(NGTableColumn, Double)] = []
        var applied = 0.0
        for column in columns {
            let oldWidth = old[column.id] ?? column.width
            let newWidth = Double(pixelAligned(CGFloat(widths[column.id] ?? column.width)))
            guard newWidth != oldWidth else { continue }
            columnWidths[column.id] = newWidth
            applied += newWidth - oldWidth
            changed.append((column, oldWidth))
        }
        // (What limits left over isn't carried; what was too small to share is.)
        if carrying { autoresizeCarry = (delta - remaining) - applied + (abs(remaining) < 0.5 ? remaining : 0) }
        guard !changed.isEmpty else { return }
        updateGeometry()
        needsLayout = true
        for (column, oldWidth) in changed {
            let notification = Notification(name: Self.columnDidResizeNotification, object: self,
                                            userInfo: ["NSTableColumn": column, "NSOldWidth": NSNumber(value: oldWidth)])
            delegate?.tableViewColumnDidResize(notification)
            NotificationCenter.default.post(notification)
        }
        scheduleLayoutAutosave()
    }
}
#endif
