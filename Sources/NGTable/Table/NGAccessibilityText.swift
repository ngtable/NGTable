#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// What VoiceOver reads for cells, on both platforms (the Mac's elements are
// in NGTableAccessibility.swift, the iPad's in NGTableAccessibilityUIKit.swift).

extension NGTableView {
    /// Columns in display order: leading, scrolling, trailing.
    var accessibilityColumnOrder: [NGColumnFrame] {
        geometry.leading.columns + geometry.center.columns + geometry.trailing.columns
    }

    /// `nil` for rows or columns that no longer exist (a stale element).
    func accessibilityText(row: Int, column: NGTableColumn) -> String? {
        // In a batch that moved rows, display rows don't mean data source rows yet.
        guard rowUpdateBatch?.displayIsStale != true, row >= 0, row < numberOfRows,
              columnLayout.columnsByID[column.id] != nil else { return nil }
        if let node = groupNode(atDisplayRow: row) {
            return groupCellText(ofNode: node, column: column)
        }
        let source = sourceRow(row)
        guard source >= 0, source < numberOfSourceRows else { return nil }
        let value = dataSource?.tableView(self, valueFor: column, row: source) ?? .empty
        // A check mark is read as checked or not (an unchecked one shows nothing).
        if case .bool(let isOn) = value {
            return isOn ? String(localized: "checked", bundle: .module, comment: "VoiceOver: a check box cell that is on.")
                : String(localized: "not checked", bundle: .module, comment: "VoiceOver: a check box cell that is off.")
        }
        if case .rating(let rating, let maximum) = value {
            return String(localized: "\(rating) of \(maximum) stars", bundle: .module, comment: "VoiceOver: a rating in a cell, e.g. 3 of 5 stars.")
        }
        if case .progress(let progress, let total) = value, NGCellValue.fraction(progress, total) == nil {
            return String(localized: "in progress", bundle: .module, comment: "VoiceOver: an indeterminate progress bar in a cell.")
        }
        if case .sparkline(let sparkline) = value {
            return Self.accessibilityText(of: sparkline, format: column.format, locale: formattingLocale)
        }
        return column.format.string(for: value, locale: formattingLocale)
    }

    /// A sparkline read out: its last, lowest and highest values.
    static func accessibilityText(of sparkline: NGSparkline, format: NGValueFormat, locale: Locale) -> String {
        guard let last = sparkline.lastValue, let (low, high) = sparkline.extremes else {
            return String(localized: "trend: no values", bundle: .module, comment: "VoiceOver: a sparkline without values.")
        }
        let text = { (value: Double) in format.string(for: value, locale: locale) }
        return String(localized: "trend: last \(text(last)), lowest \(text(low)), highest \(text(high))", bundle: .module,
                      comment: "VoiceOver: a sparkline (a small chart in a cell): its last, lowest and highest values.")
    }

    /// Viewport x range of a column, clipped to where it is visible.
    func viewportRange(ofColumnID columnID: String) -> ClosedRange<CGFloat>? {
        let viewport = viewport
        for pin in drawingOrder {
            let region = geometry[pin]
            guard let frame = region.columns.first(where: { $0.column.id == columnID }) else { continue }
            let origin = viewport.origin(of: pin)
            let clip = viewport.clipRange(of: pin, regionWidth: CGFloat(region.width))
            let minX = max(origin + CGFloat(frame.x), clip.lowerBound)
            let maxX = min(origin + CGFloat(frame.maxX), clip.upperBound)
            return minX < maxX ? minX...maxX : nil
        }
        return nil
    }
}
#endif
