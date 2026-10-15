#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Highlighting changed values, like trading screens: when a targeted update
// changes the value of a visible cell in a column with a `changeHighlight`,
// the cell flashes and fades (green or red for numbers that went up or down
// with `.direction`). Only cells in view are compared, old content against
// the new value, so a feed of unchanged values reported anyway flashes
// nothing. A flash is kept by row handle and column, so it follows its
// record when the sort or other rows move it, and is drawn by the Metal
// renderer under the cell's content while a display link animates it.

/// A cell's flash: when it started and its color.
struct NGChangeFlash {
    enum Kind { case changed, up, down }
    let start: CFTimeInterval
    let kind: Kind
}

/// A flashing cell: its row's handle and its column's ordinal.
struct NGChangeKey: Hashable {
    let handle: Int
    let ordinal: Int
}

extension NGTableView {
    /// Compares the visible cells of changed rows (`dirty`, row handles) in
    /// highlighted columns with their new values, before the cells are read
    /// again, and starts their flashes. `sources`: after rows moved, the
    /// data source row of each display row the cells are still keyed by.
    func noteChangedValues(ofRows dirty: IndexSet, columns dirtyColumns: IndexSet, sources: [Int: Int]?) {
        // Out of a window nothing shows, and a display link wouldn't run
        // (it would keep the table alive): nothing flashes.
        // Not in a window no one sees: the flashes would be over unseen.
        guard let dataSource, !dirty.isEmpty, changeHighlightDuration > 0, window != nil, !isWindowUnseen else { return }
        let all = tableColumns
        var highlighted: [Int: (column: NGTableColumn, style: NGChangeHighlight)] = [:]
        for index in dirtyColumns where index >= 0 && index < all.count {
            if let style = all[index].changeHighlight {
                highlighted[columnOrdinal(of: all[index].id)] = (all[index], style)
            }
        }
        guard !highlighted.isEmpty else { return }
        let now = CACurrentMediaTime()
        for (key, cell) in visibleCells where !cell.isHidden {
            guard let (column, style) = highlighted[key.column] else { continue }
            let row = sources.map { $0[key.row] ?? -1 } ?? sourceRow(key.row)
            guard row >= 0 else { continue }
            let handle = handle(ofRow: row)
            guard dirty.contains(handle),
                  let kind = Self.change(from: cell.content, to: dataSource.tableView(self, valueFor: column, row: row),
                                         format: column.format, locale: formattingLocale) else { continue }
            changeHighlights[NGChangeKey(handle: handle, ordinal: key.column)] =
                NGChangeFlash(start: now, kind: style == .direction ? kind : .changed)
            changeHighlightOrdinals.insert(key.column)
        }
        if !changeHighlights.isEmpty { startChangeHighlightLink() }
    }

    /// How a cell's content changed to a new value: `nil` if it shows the
    /// same; up or down for numbers. Only text and numbers are compared.
    nonisolated static func change(from content: NGCellContent, to value: NGCellValue, format: NGValueFormat,
                                   locale: Locale = .current) -> NGChangeFlash.Kind? {
        switch content {
        case .number(let old, _):
            guard case .number(let new) = value else { return .changed }
            if new == old.value || (new.isNaN && old.value.isNaN) { return nil }
            return new > old.value ? .up : new < old.value ? .down : .changed
        case .text(let old, _, _):
            return format.string(for: value, locale: locale) == old ? nil : .changed
        default:
            return nil
        }
    }

    /// A reused handle is another record: its flashes go. Called for every
    /// inserted row (a feed inserts thousands a second), so by key, not by
    /// going through every flash.
    func forgetChangeHighlights(ofHandle handle: Int) {
        guard !changeHighlights.isEmpty else { return }
        for ordinal in changeHighlightOrdinals {
            changeHighlights.removeValue(forKey: NGChangeKey(handle: handle, ordinal: ordinal))
        }
    }

    /// The flashes to draw now, by region: the cell frame (in its region's
    /// canvas) and the premultiplied color.
    func changeHighlightQuads(style: MetalStyle) -> [NGColumnPin: [(frame: CGRect, color: SIMD4<Float>)]] {
        guard !changeHighlights.isEmpty else { return [:] }
        let now = CACurrentMediaTime()
        let duration = max(0.01, changeHighlightDuration)
        var result: [NGColumnPin: [(frame: CGRect, color: SIMD4<Float>)]] = [:]
        for (key, flash) in changeHighlights {
            let progress = (now - flash.start) / duration
            guard progress < 1 else { continue }
            let row = row(ofHandle: key.handle)
            guard row >= 0, let displayRow = displayRow(forSourceRow: row),
                  let cell = visibleCells[NGCellKey(row: displayRow, column: key.ordinal)], !cell.isHidden,
                  let pin = cell.regionPin else { continue }
            // Full for a moment, then fading out.
            let hold = 0.15
            let fade = progress < hold ? 1 : pow(1 - (progress - hold) / (1 - hold), 2)
            let base: NGColor = switch flash.kind {
            case .changed: .controlAccentColor
            case .up: .systemGreen
            case .down: .systemRed
            }
            let color = style.color(base) * Float(0.38 * fade)
            // A row sliding into place takes its flash along.
            result[pin, default: []].append((cell.cellFrame.offsetBy(dx: 0, dy: rowAnimationOffset(ofDisplayRow: displayRow)), color))
        }
        return result
    }

    private func startChangeHighlightLink() {
        guard changeHighlightLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(stepChangeHighlights(_:)))
        link.add(to: .main, forMode: .common)
        changeHighlightLink = link
    }

    @objc func stepChangeHighlights(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let duration = changeHighlightDuration
        changeHighlights = changeHighlights.filter { now - $0.value.start < duration }
        // The window went out of sight: they end now.
        if isWindowUnseen { changeHighlights = [:] }
        if changeHighlights.isEmpty {
            changeHighlightOrdinals = []
            changeHighlightLink?.invalidate()
            changeHighlightLink = nil
        }
        setNeedsMetalFrame()
    }

    /// Stops every flash (a reload: the records may be others).
    func clearChangeHighlights() {
        changeHighlights = [:]
        changeHighlightOrdinals = []
        changeHighlightLink?.invalidate()
        changeHighlightLink = nil
    }
}
#endif
