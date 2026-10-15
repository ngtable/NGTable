#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// What the table's views on both platforms use: named colors as the
// system's, column alignments as text alignments, keys of visible cells.

extension NGNamedColor {
    var systemColor: NGColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .mint: .systemMint
        case .teal: .systemTeal
        case .cyan: .systemCyan
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .brown: .systemBrown
        case .gray: .systemGray
        }
    }
}

extension NGColumnAlignment {
    /// Leading and trailing follow the interface's direction, not the text's:
    /// a Latin title in a right-to-left interface is still at the leading
    /// (right) edge.
    func textAlignment(isNumeric: Bool, layoutDirection: NGLayoutDirection) -> NSTextAlignment {
        let isRightToLeft = layoutDirection == .rightToLeft
        return switch resolved(isNumeric: isNumeric) {
        case .center: .center
        case .trailing: isRightToLeft ? .left : .right
        case .leading, .automatic: isRightToLeft ? .right : .left
        }
    }
}

/// Identifies a visible cell. Columns are numbered (see
/// `NGTableView.columnOrdinal(of:)`): hashing ids for every cell of every
/// layout pass is measurable in wide tables.
struct NGCellKey: Hashable {
    let row: Int
    let column: Int
}

/// Identifies a visible row background.
struct NGRowKey: Hashable {
    let pin: NGColumnPin
    let row: Int
}
#endif
