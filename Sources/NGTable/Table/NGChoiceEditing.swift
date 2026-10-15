#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Editing by choosing instead of typing:
// - An editable column's Boolean cells show a check box. A click on it, Space
//   on the focused cell, Return or a double click toggle it.
// - A column with `editChoices` edits in a menu of those values under the
//   cell (the current one checked), opened like a text field would be.
// Both go through the data source's `tableView(_:setValue:for:row:)` and can
// be undone.

extension NGTableView {
    /// The check box of an editable Boolean cell, drawn as a mark.
    static func checkBoxMark(_ isOn: Bool) -> NGMark {
        NGMark(isOn ? NGCellDrawing.checkedBoxName : "square", color: isOn ? .blue : nil, label: isOn ? "✓" : "")
    }

    /// Whether a cell shows a check box: a Boolean in an editable column without choices.
    func isCheckBox(row: Int, column: NGTableColumn) -> Bool {
        guard column.isEditable, column.editChoices == nil, row >= 0, row < numberOfSourceRows, let dataSource,
              case .bool = dataSource.tableView(self, valueFor: column, row: row) else { return false }
        return true
    }

    /// Toggles a check box cell; returns whether it could.
    @discardableResult
    func toggleCheckBox(row: Int, columnID: String) -> Bool {
        guard canEdit(row: row, columnID: columnID), let dataSource,
              let column = tableColumns.first(where: { $0.id == columnID }),
              case .bool(let isOn) = dataSource.tableView(self, valueFor: column, row: row) else { return false }
        setValue(.bool(!isOn), row: row, column: column, undoValue: .bool(isOn))
        return true
    }

    /// Whether a click in the window hits a cell's check box (with a little slack around it).
    func checkBoxHit(atWindowLocation location: CGPoint, row: Int, columnID: String) -> Bool {
        guard let column = tableColumns.first(where: { $0.id == columnID }), isCheckBox(row: row, column: column),
              let frame = frameOfCell(row: row, columnID: columnID),
              let image = NGCellDrawing.markImage(Self.checkBoxMark(false).symbolName) else { return false }
        let alignment = column.alignment.textAlignment(isNumeric: false, layoutDirection: contentLayoutDirection)
        var box = NGCellDrawing.markRect(size: image.size, alignment: alignment, in: CGRect(origin: .zero, size: frame.size))
            .offsetBy(dx: frame.minX, dy: frame.minY).insetBy(dx: -4, dy: -4)
        // Right to left, mirrored within the cell, like what it draws.
        if isRightToLeft { box.origin.x = frame.minX + frame.maxX - box.maxX }
        return box.contains(convert(location, from: nil))
    }

    // MARK: Choices

    #if os(macOS)
    /// The menu of a cell's choices: their titles as displayed, the current
    /// one checked; choosing one sets it.
    func choiceMenu(row: Int, column: NGTableColumn) -> NSMenu? {
        guard let choices = column.editChoices, !choices.isEmpty, let dataSource else { return nil }
        let current = dataSource.tableView(self, valueFor: column, row: row)
        let menu = NSMenu()
        let ref = rowRef(ofRow: row)
        for (index, choice) in choices.enumerated() {
            let title = NGFormatIDs.string(for: choice, format: column.format, locale: locale)
            let item = NSMenuItem(title: title.isEmpty ? "—" : title, action: #selector(chooseEditChoice(_:)), keyEquivalent: "")
            item.target = self
            item.state = choice == current ? .on : .off
            item.representedObject = NGChoice(ref: ref, columnID: column.id, index: index)
            if case .tags(let tags) = choice, let color = tags.first?.color {
                item.image = Self.choiceDot(color)
            }
            menu.addItem(item)
        }
        return menu
    }
    #endif

    #if os(macOS)
    /// Opens the choices under the cell.
    func showChoiceMenu(row: Int, column: NGTableColumn) -> Bool {
        guard let menu = choiceMenu(row: row, column: column), let frame = frameOfCell(row: row, columnID: column.id) else { return false }
        focusedCell = NGCellPosition(row: row, columnID: column.id)
        menu.minimumWidth = frame.width
        // A live update that removes the record closes it (see `closeChoiceMenuIfGone`).
        openChoiceMenu = (menu, rowRef(ofRow: row))
        defer { openChoiceMenu = nil }
        if let showMenuForTesting = Self.choiceMenuShownForTesting {
            showMenuForTesting(menu)
            return true
        }
        menu.popUp(positioning: nil, at: CGPoint(x: frame.minX, y: frame.maxY), in: self)
        return true
    }
    #endif

    #if os(macOS)
    @objc func chooseEditChoice(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? NGChoice,
              let column = tableColumns.first(where: { $0.id == choice.columnID }),
              let choices = column.editChoices, choice.index < choices.count, let dataSource else { return }
        // The record may have moved while the menu was open: found by its reference.
        let row = row(of: choice.ref)
        guard row >= 0, canEdit(row: row, columnID: column.id) else { return }
        let old = dataSource.tableView(self, valueFor: column, row: row)
        guard old != choices[choice.index] else { return }
        setValue(choices[choice.index], row: row, column: column, undoValue: old)
    }
    #endif

    #if os(macOS)
    /// A tag's color as a dot in the menu.
    private static func choiceDot(_ color: NGNamedColor) -> NSImage {
        NSImage(size: CGSize(width: 10, height: 10), flipped: false) { rect in
            color.systemColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
    #endif
}

/// A menu item's choice: the record, the column and the value's index.
final class NGChoice: NSObject {
    let ref: NGRowRef
    let columnID: String
    let index: Int

    init(ref: NGRowRef, columnID: String, index: Int) {
        self.ref = ref
        self.columnID = columnID
        self.index = index
    }
}
#endif
