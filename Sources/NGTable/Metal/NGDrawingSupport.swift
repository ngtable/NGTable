#if canImport(AppKit)
import AppKit
typealias NGPlatformFont = NSFont
#else
import UIKit
typealias NGPlatformFont = UIFont
#endif

// What the renderer and the table's views share on every platform: sizes,
// line heights, bitmap contexts like the atlas's, and a wrapper for values
// handed to other threads.

enum NGMetrics {
    /// Horizontal padding between a column edge and its content (cells, header, summary).
    static let cellPadding: CGFloat = 6
    /// A sparkline's line, its dots and how strongly its area is filled.
    static let sparklineWidth: CGFloat = 1.5
    static let sparklineDotRadius: CGFloat = 2
    static let sparklineAreaOpacity: Float = 0.22
    /// A cell's push button: its height, corner radius, the title's padding
    /// and the gap after its symbol.
    static let buttonHeight: CGFloat = 20
    static let buttonCornerRadius: CGFloat = 5
    static let buttonPadding: CGFloat = 9
    static let buttonSymbolSpacing: CGFloat = 4
    /// A progress bar's thickness, the gap before its text and how long the
    /// indeterminate stripe takes across it (seconds).
    static let progressThickness: CGFloat = 6
    static let progressTextSpacing: CGFloat = 6
    static let indeterminateProgressPeriod: Double = 1.4
    /// The pop-up chevron of cells with choices: its point size and the gap before it.
    static let choiceChevronPointSize: CGFloat = 9
    static let choiceChevronSpacing: CGFloat = 4
    /// A rating's star slots and the gap between them.
    static let ratingStarSize: CGFloat = 14
    static let ratingStarSpacing: CGFloat = 2
    /// Clicked this close before the first star, a rating is cleared (0).
    static let ratingClearWidth: CGFloat = 8
    /// The width a column of sparklines fits to.
    static let sparklineFittingWidth: CGFloat = 100
    /// A media cell's picture from the cell's leading edge, and its text from the picture.
    static let mediaInset: CGFloat = 4
    static let mediaTextSpacing: CGFloat = 10
    /// Between a media cell's lines of text.
    static let mediaLineSpacing: CGFloat = 2
    /// Distance of rounded rows (stripes and selections) from the table's
    /// leading and trailing edges.
    static let selectionInset: CGFloat = 8
    static let selectionCornerRadius: CGFloat = 6
    /// Margin before the first and after the last column with rounded rows, so
    /// content keeps clear of the rounded row edges like in inset macOS lists.
    static let contentEdgeInset: CGFloat = 10
    /// Row markers: the leading edge of the row background painted this wide,
    /// clipped by the row's rounded corners.
    static let markerWidth: CGFloat = 2
    /// Marks: an SF Symbol.
    static let markPointSize: CGFloat = 12
    /// Tags: capsules with a small label.
    static let tagHeight: CGFloat = 16
    static let tagPadding: CGFloat = 6
    static let tagSpacing: CGFloat = 4
    /// Group headers: each level is indented this much more than the one
    /// around it, and the disclosure chevron takes this much room.
    static let groupIndent: CGFloat = 16
    static let disclosureWidth: CGFloat = 10
    /// Between the chevron and the title, and the title and the row count.
    static let groupTitleSpacing: CGFloat = 6
}

/// Single-line heights of fonts, as AppKit lays a line out (measured once
/// per font: no formula of the font's metrics gives AppKit's).
@MainActor
enum NGLineHeights {
    private static var heights: [NGPlatformFont: CGFloat] = [:]
    /// The font asked last: a frame asks for the same few fonts cell after
    /// cell, and hashing a font costs more than comparing pointers.
    private static var last: (font: NGPlatformFont, height: CGFloat)?

    static func height(of font: NGPlatformFont) -> CGFloat {
        if let last, last.font === font { return last.height }
        let height = heights[font] ?? ceil(NSAttributedString(string: "Xg", attributes: [.font: font]).size().height)
        heights[font] = height
        last = (font, height)
        return height
    }
}

/// Drawing the table's cells: bitmap contexts here, the rest with the views.
@MainActor
enum NGCellDrawing {
    nonisolated static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// A bitmap context for glyphs and icons, transparent like the atlas (so
    /// without font smoothing).
    nonisolated static func makeBitmapContext(width: Int, height: Int, colorSpace: CGColorSpace) -> CGContext? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: colorSpace, bitmapInfo: bitmapInfo)
        context?.setAllowsFontSmoothing(false)
        return context
    }
}

/// A value handed to other threads by code that guarantees exclusive access.
struct NGUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
