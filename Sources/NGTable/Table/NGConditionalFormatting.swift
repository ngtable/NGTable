#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Drawing conditional formats (`NGConditionalFormat`): data bars and color
// scales under a number cell's text, or its text in a rule's color. Automatic
// ranges come from the summary machinery: a format with one asks for the
// column's values like a summary does (read once, updated incrementally by
// targeted updates), and the range is the min and max of the rows shown.

extension NGTableView {
    /// A visible column's conditional format, with the range it scales over.
    struct ResolvedConditionalFormat {
        let format: NGConditionalFormat
        let range: ClosedRange<Double>?
    }

    /// The summary keys conditional formats need for their automatic ranges.
    var conditionalFormatSummaryKeys: Set<SummaryKey> {
        var keys = Set<SummaryKey>()
        for column in columnLayout.allColumns where column.conditionalFormat?.range == .automatic {
            keys.insert(SummaryKey(columnID: column.id, filter: .all))
        }
        return keys
    }

    /// The visible columns' formats by column ordinal, for drawing a frame.
    func resolvedConditionalFormats() -> [Int: ResolvedConditionalFormat] {
        var result: [Int: ResolvedConditionalFormat] = [:]
        bringSummaryRowsInStep(forSelection: false)
        keepExactMinMax(&summaryCalculators)
        for column in columnLayout.allColumns {
            guard let format = column.conditionalFormat else { continue }
            var range: ClosedRange<Double>?
            switch format.range {
            case .fixed(let low, let high)?:
                range = min(low, high)...max(low, high)
            case .automatic?:
                if let calculator = summaryCalculators[SummaryKey(columnID: column.id, filter: .all)],
                   let low = calculator.value(for: .min, scope: .allRows, selection: []),
                   let high = calculator.value(for: .max, scope: .allRows, selection: []) {
                    range = low...high
                }
            case nil:
                break
            }
            result[columnOrdinal(of: column.id)] = ResolvedConditionalFormat(format: format, range: range)
        }
        return result
    }

    /// Quads under a number cell's text for its format (bars, a scale's
    /// background); the text color for a `.textColor` format.
    func appendConditionalFormat(_ resolved: ResolvedConditionalFormat, value: Double, in frame: CGRect, clip: CGRect,
                                 scale: CGFloat, style: MetalStyle, to quads: inout [NGMetalQuad]) -> SIMD4<Float>? {
        guard value.isFinite else { return nil }
        switch resolved.format {
        case .dataBar(let positive, let negative, _):
            guard let range = resolved.range else { return nil }
            let low = min(range.lowerBound, 0), high = max(range.upperBound, 0)
            guard high > low else { return nil }
            let inset: CGFloat = 3
            let track = frame.insetBy(dx: inset, dy: inset + 1)
            func x(_ number: Double) -> CGFloat {
                track.minX + track.width * CGFloat((min(max(number, low), high) - low) / (high - low))
            }
            let zero = x(0), end = x(value)
            let bar = CGRect(x: min(zero, end), y: track.minY, width: abs(end - zero), height: track.height)
            guard bar.width > 0.5 else { return nil }
            let color = style.markColor(value < 0 ? negative : positive) * 0.32
            quads.append(NGMetalRenderer.roundedRectangle(bar, radius: 2, corners: [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                                                                   .layerMinXMaxYCorner, .layerMaxXMaxYCorner],
                                                          scale: scale, color: color, clip: clip))
            return nil
        case .colorScale(let lowColor, let highColor, _):
            guard let range = resolved.range else { return nil }
            let fraction = range.upperBound > range.lowerBound
                ? Float((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound))
                : 0.5
            let color = (style.markColor(lowColor) * (1 - fraction) + style.markColor(highColor) * fraction) * 0.3
            // A hairline apart, so neighboring rows stay rows.
            quads.append(NGMetalRenderer.rectangle(frame.insetBy(dx: 1, dy: 1), scale: scale, color: color, clip: clip))
            return nil
        case .textColor(let rules):
            return rules.first { $0.matches(value) }.map { style.markColor($0.color) }
        }
    }
}
#endif
