#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Controls drawn in cells (links, buttons): the pointer over them (the link
// underlined, the pointing hand), a press tracked like a button's (released
// in the same cell, it acts; dragged out, nothing), Space on the focused
// cell, and VoiceOver's press. A plain click on a control doesn't select the
// row; Command- and Shift-clicks still do.

extension NGTableView {
    /// A link being pressed, darker (like a link in a web view).
    #if os(macOS)
    static let pressedLinkColor = NGColor(name: nil) { appearance in
        let base = NGColor.linkColor.usingColorSpace(.sRGB) ?? .linkColor
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? base.blended(withFraction: 0.3, of: .white) ?? base
            : base.blended(withFraction: 0.3, of: .black) ?? base
    }
    #else
    static let pressedLinkColor = UIColor { traits in
        let base = UIColor.link.resolvedColor(with: traits)
        var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        base.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let toward: CGFloat = traits.userInterfaceStyle == .dark ? 1 : 0
        return UIColor(red: red * 0.7 + toward * 0.3, green: green * 0.7 + toward * 0.3, blue: blue * 0.7 + toward * 0.3, alpha: alpha)
    }
    #endif

    /// A push button's border, its fill and its fill pressed, in both appearances.
    static let buttonBorderColor = NGColor.dynamic(light: NGColor(white: 0, alpha: 0.16), dark: NGColor(white: 1, alpha: 0.14))
    static let buttonFillColor = NGColor.dynamic(light: NGColor(white: 1, alpha: 1), dark: NGColor(white: 0.40, alpha: 1))
    static let pressedButtonFillColor = NGColor.dynamic(light: NGColor(white: 0.86, alpha: 1), dark: NGColor(white: 0.52, alpha: 1))

    /// Whether a cell's content is a control the table tracks.
    static func isControl(_ content: NGCellContent) -> Bool {
        switch content {
        case .link, .button: true
        case .rating(_, _, let isEditable, _): isEditable
        default: false
        }
    }

    /// Controls the pointer is the pointing hand over (links; buttons keep the arrow, like NSButton's).
    static func showsPointingHand(_ content: NGCellContent) -> Bool {
        if case .link = content { return true }
        return false
    }

    /// Whether a point of the window is on a cell's control: a link fills
    /// its cell, a button is its bezel (beside it, the click selects).
    func isOnControl(_ cell: NGDrawnCell, atWindowLocation location: CGPoint, row: Int, columnID: String) -> Bool {
        switch cell.content {
        case .link:
            return true
        case .rating(_, let maximum, let isEditable, let alignment):
            return isEditable && rating(atWindowLocation: location, maximum: maximum, alignment: alignment, row: row, columnID: columnID) != nil
        case .button(let button, let alignment):
            guard button.isEnabled, let frame = frameOfCell(row: row, columnID: columnID) else { return false }
            var bezel = buttonBezel(button, alignment: alignment, in: CGRect(origin: .zero, size: frame.size)).offsetBy(dx: frame.minX, dy: frame.minY)
            // Right to left, mirrored within the cell, like what it draws.
            if isRightToLeft { bezel.origin.x = frame.minX + frame.maxX - bezel.maxX }
            return bezel.contains(convert(location, from: nil))
        default:
            return false
        }
    }

    /// The rating a point of the window would set in a cell: the star under
    /// it (counted from the leading one), 0 just before the first one, `nil`
    /// away from the stars.
    func rating(atWindowLocation location: CGPoint, maximum: Int, alignment: NSTextAlignment, row: Int, columnID: String) -> Int? {
        guard maximum > 0, let frame = frameOfCell(row: row, columnID: columnID) else { return nil }
        let stars = Self.ratingStars(maximum: maximum, alignment: alignment, in: CGRect(origin: .zero, size: frame.size))
        guard let first = stars.first, let last = stars.last else { return nil }
        var x = convert(location, from: nil).x - frame.minX
        // Right to left the stars are mirrored in the cell: count from the right.
        if isRightToLeft { x = frame.width - x }
        if x < first.minX - NGMetrics.ratingClearWidth || x > last.maxX + NGMetrics.ratingStarSpacing { return nil }
        if x < first.minX { return 0 }
        return min(maximum, Int((x - first.minX) / (NGMetrics.ratingStarSize + NGMetrics.ratingStarSpacing)) + 1)
    }

    /// Sets an editable rating to the value at a point (with Undo); whether it did.
    @discardableResult
    func setRating(atWindowLocation location: CGPoint, row: Int, columnID: String) -> Bool {
        guard let cell = visibleCell(sourceRow: row, columnID: columnID), case .rating(_, let maximum, true, let alignment) = cell.content,
              let value = rating(atWindowLocation: location, maximum: maximum, alignment: alignment, row: row, columnID: columnID) else { return false }
        return setRating(value, row: row, columnID: columnID)
    }

    /// Sets an editable rating (with Undo); whether it did.
    @discardableResult
    func setRating(_ value: Int, row: Int, columnID: String) -> Bool {
        guard canEdit(row: row, columnID: columnID), let column = columnLayout.columnsByID[columnID],
              case .rating(let old, let maximum) = dataSource?.tableView(self, valueFor: column, row: row),
              (0...maximum).contains(value) else { return false }
        if value != old { setValue(.rating(value, maximum: maximum), row: row, column: column, undoValue: .rating(old, maximum: maximum)) }
        return true
    }

    /// A cell's button bezel in a frame (measured like it's drawn).
    func buttonBezel(_ button: NGCellButton, alignment: NSTextAlignment, in frame: CGRect) -> CGRect {
        let font = metalStyle.textFont
        let symbolWidth = button.symbolName.flatMap(NGCellDrawing.markImage)?.size.width
        return Self.buttonLayout(button, alignment: alignment, in: frame, symbolWidth: symbolWidth) { [metalRenderer] title, width in
            if let shaper = metalRenderer?.shaper { return shaper.shape(title, font: font, width: width).width }
            return min(width, NSAttributedString(string: title, attributes: [.font: font]).size().width)
        }.bezel
    }

    /// The visible cell of a data source row and column.
    func visibleCell(sourceRow row: Int, columnID: String) -> NGDrawnCell? {
        guard let displayRow = displayRow(forSourceRow: row) else { return nil }
        return visibleCells[NGCellKey(row: displayRow, column: columnOrdinal(of: columnID))]
    }

    #if os(macOS)
    /// The control under the pointer shows it (and the cursor is the
    /// pointing hand). After the pointer moved, the rows scrolled or changed.
    func syncControlUnderPointer() {
        var cell: NGDrawnCell?
        if let hoveredCell, cellPress == nil || cellPress?.columnID == hoveredCell.columnID,
           let visible = visibleCell(sourceRow: hoveredCell.row, columnID: hoveredCell.columnID), Self.isControl(visible.content) {
            cell = visible
            // An editable rating previews the value a click there would set.
            if case .rating(_, let maximum, _, let alignment) = visible.content, let location = pointerWindowLocation {
                visible.previewRating = rating(atWindowLocation: location, maximum: maximum, alignment: alignment,
                                               row: hoveredCell.row, columnID: hoveredCell.columnID)
            }
        }
        if pointerOverCell !== cell {
            pointerOverCell?.isPointerOver = false
            pointerOverCell = cell
        }
        cell?.isPointerOver = true
        let hand = cell.map { Self.showsPointingHand($0.content) } ?? false
        if hand != showsPointingHand {
            showsPointingHand = hand
            (hand ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }
    #endif

    #if os(macOS)
    /// A plain press on a control: tracked until the mouse is released
    /// (`true`: the table took the press).
    func beginControlPress(_ event: NSEvent, displayRow: Int, columnID: String?) -> Bool {
        guard let columnID, displayRow >= 0, displayRow < numberOfRows, !isGroupRow(displayRow),
              event.modifierFlags.isDisjoint(with: [.command, .shift, .control]) else { return false }
        let row = sourceRow(displayRow)
        guard row >= 0, let cell = visibleCell(sourceRow: row, columnID: columnID),
              isOnControl(cell, atWindowLocation: event.locationInWindow, row: row, columnID: columnID) else { return false }
        cellPress = (rowRef(ofRow: row), columnID)
        cell.isPressed = true
        clickedRow = -1
        clickedColumn = -1
        return true
    }
    #endif

    #if os(macOS)
    /// The pressed control looks pressed while the mouse is over it.
    func dragControlPress(_ event: NSEvent) -> Bool {
        guard let press = cellPress else { return false }
        let row = self.row(of: press.ref)
        visibleCell(sourceRow: row, columnID: press.columnID)?.isPressed = isControl(at: event, row: row, columnID: press.columnID)
        return true
    }
    #endif

    #if os(macOS)
    /// Released over the pressed control: it acts.
    func endControlPress(_ event: NSEvent) -> Bool {
        guard let press = cellPress.take() else { return false }
        let row = self.row(of: press.ref)
        visibleCell(sourceRow: row, columnID: press.columnID)?.isPressed = false
        if row >= 0, isControl(at: event, row: row, columnID: press.columnID) {
            // A rating takes the star the mouse was released on.
            if !setRating(atWindowLocation: event.locationInWindow, row: row, columnID: press.columnID) {
                activateControl(row: row, columnID: press.columnID)
            }
        }
        syncControlUnderPointer()
        return true
    }
    #endif

    #if os(macOS)
    private func isControl(at event: NSEvent, row: Int, columnID: String) -> Bool {
        guard row >= 0, let displayRow = displayRow(forSourceRow: row),
              self.row(atWindowLocation: event.locationInWindow) == displayRow,
              self.columnID(atWindowLocation: event.locationInWindow) == columnID,
              let cell = visibleCell(sourceRow: row, columnID: columnID) else { return false }
        return isOnControl(cell, atWindowLocation: event.locationInWindow, row: row, columnID: columnID)
    }
    #endif

    /// What a control does: a link calls the delegate (by default it opens
    /// its URL). `false` if the cell has no control.
    @discardableResult
    func activateControl(row: Int, columnID: String) -> Bool {
        guard !ignoresUserInput, row >= 0, row < numberOfSourceRows, let column = columnLayout.columnsByID[columnID],
              let value = dataSource?.tableView(self, valueFor: column, row: row) else { return false }
        switch value {
        case .link(let link):
            if let delegate {
                delegate.tableView(self, didClickLink: link, in: column, row: row)
            } else {
                Self.open(link)
            }
            return true
        case .button(let button):
            guard button.isEnabled else { return false }
            delegate?.tableView(self, didPressButton: button, in: column, row: row)
            return true
        default:
            return false
        }
    }

    /// Opens a link's URL (with the workspace, or the testing hook).
    static func open(_ link: NGLink) {
        guard let url = link.url else { return }
        if let openURLForTesting {
            openURLForTesting(url)
        } else {
            NGSystem.open(url)
        }
    }

    /// Whether a data source row's cell in a column is a control (for VoiceOver and the keyboard).
    func isControlCell(row: Int, columnID: String) -> Bool {
        guard row >= 0, row < numberOfSourceRows, let column = columnLayout.columnsByID[columnID],
              let value = dataSource?.tableView(self, valueFor: column, row: row) else { return false }
        switch value {
        case .link: return true
        case .button(let button): return button.isEnabled
        default: return false
        }
    }

    #if os(macOS)
    /// What VoiceOver calls a control cell (a link or a button), `nil` for other cells.
    func controlRoleDescription(row: Int, columnID: String) -> String? {
        guard row >= 0, row < numberOfSourceRows, let column = columnLayout.columnsByID[columnID],
              let value = dataSource?.tableView(self, valueFor: column, row: row) else { return nil }
        switch value {
        case .link: return NSAccessibility.Role.link.description(with: nil)
        case .button: return NSAccessibility.Role.button.description(with: nil)
        default: return nil
        }
    }
    #endif
}
#endif
