#if os(macOS)
import Foundation
import SwiftUI

// Columns of `NGDataTable`, like SwiftUI's `TableColumn` with `value:`: a
// title and a key path (or a closure) to the value each row shows, plus
// what NGTable adds (format, summary, frozen edge, groups). Built with
// `NGDataColumnBuilder`, like `TableColumnBuilder`: lists, `if`, `for`.

/// A value a row can show in a cell (strings, numbers, dates, Booleans,
/// tags, marks, media, optionals of them, or an `NGCellValue`).
public protocol NGCellValueConvertible {
    var cellValue: NGCellValue { get }
}

extension NGCellValue: NGCellValueConvertible {
    public var cellValue: NGCellValue { self }
}
extension String: NGCellValueConvertible {
    public var cellValue: NGCellValue { .text(self) }
}
extension Int: NGCellValueConvertible {
    public var cellValue: NGCellValue { .number(Double(self)) }
}
extension Int32: NGCellValueConvertible {
    public var cellValue: NGCellValue { .number(Double(self)) }
}
extension Int64: NGCellValueConvertible {
    public var cellValue: NGCellValue { .number(Double(self)) }
}
extension UInt: NGCellValueConvertible {
    public var cellValue: NGCellValue { .number(Double(self)) }
}
extension Double: NGCellValueConvertible {
    public var cellValue: NGCellValue { .number(self) }
}
extension Float: NGCellValueConvertible {
    public var cellValue: NGCellValue { .number(Double(self)) }
}
extension Decimal: NGCellValueConvertible {
    public var cellValue: NGCellValue { .number(NSDecimalNumber(decimal: self).doubleValue) }
}
extension Bool: NGCellValueConvertible {
    public var cellValue: NGCellValue { .bool(self) }
}
extension Date: NGCellValueConvertible {
    public var cellValue: NGCellValue { .date(self) }
}
extension NGTag: NGCellValueConvertible {
    public var cellValue: NGCellValue { .tags([self]) }
}
extension Array: NGCellValueConvertible where Element == NGTag {
    public var cellValue: NGCellValue { .tags(self) }
}
extension NGMark: NGCellValueConvertible {
    public var cellValue: NGCellValue { .mark(self) }
}
extension NGMedia: NGCellValueConvertible {
    public var cellValue: NGCellValue { .media(self) }
}
extension NGCellButton: NGCellValueConvertible {
    public var cellValue: NGCellValue { .button(self) }
}
extension NGLink: NGCellValueConvertible {
    public var cellValue: NGCellValue { .link(self) }
}
extension NGSparkline: NGCellValueConvertible {
    public var cellValue: NGCellValue { .sparkline(self) }
}
extension Optional: NGCellValueConvertible where Wrapped: NGCellValueConvertible {
    public var cellValue: NGCellValue { self?.cellValue ?? .empty }
}

/// A value a cell's edit can be written back as (see `NGDataColumn.editable(_:choices:)`):
/// made from the value the table parsed, `nil` if it can't be one.
public protocol NGCellValueEditable: NGCellValueConvertible {
    init?(cellValue: NGCellValue)
}

extension String: NGCellValueEditable {
    public init?(cellValue: NGCellValue) {
        switch cellValue {
        case .text(let text): self = text
        case .empty: self = ""
        default: return nil
        }
    }
}
// Whole numbers take whole numbers only: 2.7 isn't written as 3 (the edit
// is refused), and values out of the type's range neither.
extension Int: NGCellValueEditable {
    public init?(cellValue: NGCellValue) {
        guard case .number(let number) = cellValue, let value = Int(exactly: number) else { return nil }
        self = value
    }
}
extension Int32: NGCellValueEditable {
    public init?(cellValue: NGCellValue) {
        guard case .number(let number) = cellValue, let value = Int32(exactly: number) else { return nil }
        self = value
    }
}
extension Int64: NGCellValueEditable {
    public init?(cellValue: NGCellValue) {
        guard case .number(let number) = cellValue, let value = Int64(exactly: number) else { return nil }
        self = value
    }
}
extension UInt: NGCellValueEditable {
    public init?(cellValue: NGCellValue) {
        guard case .number(let number) = cellValue, let value = UInt(exactly: number) else { return nil }
        self = value
    }
}
extension Float: NGCellValueEditable {
    public init?(cellValue: NGCellValue) {
        guard case .number(let number) = cellValue, number.isNaN || abs(number) <= Double(Float.greatestFiniteMagnitude) else { return nil }
        self = Float(number)
    }
}
extension Double: NGCellValueEditable {
    public init?(cellValue: NGCellValue) {
        guard case .number(let number) = cellValue else { return nil }
        self = number
    }
}
extension Decimal: NGCellValueEditable {
    public init?(cellValue: NGCellValue) {
        guard case .number(let number) = cellValue else { return nil }
        self = Decimal(number)
    }
}
extension Bool: NGCellValueEditable {
    public init?(cellValue: NGCellValue) {
        guard case .bool(let flag) = cellValue else { return nil }
        self = flag
    }
}
extension Date: NGCellValueEditable {
    public init?(cellValue: NGCellValue) {
        guard case .date(let date) = cellValue else { return nil }
        self = date
    }
}
extension NGTag: NGCellValueEditable {
    public init?(cellValue: NGCellValue) {
        guard case .tags(let tags) = cellValue, let tag = tags.first else { return nil }
        self = tag
    }
}
extension Array: NGCellValueEditable where Element == NGTag {
    public init?(cellValue: NGCellValue) {
        switch cellValue {
        case .tags(let tags): self = tags
        case .empty: self = []
        default: return nil
        }
    }
}
extension Optional: NGCellValueEditable where Wrapped: NGCellValueEditable {
    public init?(cellValue: NGCellValue) {
        if cellValue == .empty {
            self = .none
        } else if let value = Wrapped(cellValue: cellValue) {
            self = .some(value)
        } else {
            return nil
        }
    }
}

/// A column of `NGDataTable`: a title and the value of each row, like
/// SwiftUI's `TableColumn(_:value:)`.
///
/// ```swift
/// NGDataColumn("Name", value: \.name)
/// NGDataColumn("Spend", value: \.spend, format: .currency(code: "USD"), summary: .aggregate(.sum))
///     .width(min: 80, ideal: 110)
/// ```
public struct NGDataColumn<Row> {
    /// The table column (id, title, width, format, summary…).
    public var column: NGTableColumn
    let value: (Row) -> NGCellValue
    /// The key path, for `sortOrder` bindings' comparators.
    let keyPath: AnyKeyPath?
    let comparator: ((SortOrder) -> KeyPathComparator<Row>)?
    /// Writes an edited value into a row (a writable key path of an
    /// editable type), or `nil`; whether the value fit.
    let write: ((inout Row, NGCellValue) -> Bool)?
    /// Hidden until the user or a customization shows it (`defaultVisibility(.hidden)`).
    var isHiddenByDefault = false

    /// The writing of a key path, when it is writable and its type editable.
    static func writer<Value>(_ keyPath: KeyPath<Row, Value>) -> ((inout Row, NGCellValue) -> Bool)? {
        guard let writable = keyPath as? WritableKeyPath<Row, Value>,
              let editable = Value.self as? any NGCellValueEditable.Type else { return nil }
        return { row, value in
            guard let new = editable.init(cellValue: value) as? Value else { return false }
            row[keyPath: writable] = new
            return true
        }
    }

    /// A column of a key path's values. `id` (the key path by default) is
    /// what saved layouts and sorting refer to: keep it stable.
    public init<Value: NGCellValueConvertible>(_ title: String, id: String? = nil, value: KeyPath<Row, Value>,
                                               format: NGValueFormat = .automatic, alignment: NGColumnAlignment = .automatic,
                                               summary: NGColumnSummary = .none, pin: NGColumnPin = .none) {
        column = NGTableColumn(id ?? Self.identifier(of: value, title: title), title: title, alignment: alignment, format: format,
                               summary: summary, pin: pin)
        self.value = { $0[keyPath: value].cellValue }
        keyPath = value
        comparator = nil
        write = Self.writer(value)
    }

    /// A column of a key path's comparable values: also sortable by a
    /// `sortOrder` binding of `KeyPathComparator`s, like SwiftUI's.
    public init<Value: NGCellValueConvertible & Comparable>(_ title: String, id: String? = nil,
                                                            value: any KeyPath<Row, Value> & Sendable,
                                                            format: NGValueFormat = .automatic,
                                                            alignment: NGColumnAlignment = .automatic,
                                                            summary: NGColumnSummary = .none, pin: NGColumnPin = .none) {
        column = NGTableColumn(id ?? Self.identifier(of: value, title: title), title: title, alignment: alignment, format: format,
                               summary: summary, pin: pin)
        self.value = { $0[keyPath: value].cellValue }
        keyPath = value
        comparator = { KeyPathComparator(value, order: $0) }
        write = Self.writer(value)
    }

    /// A column of values computed from the row.
    public init(_ title: String, id: String, format: NGValueFormat = .automatic, alignment: NGColumnAlignment = .automatic,
                summary: NGColumnSummary = .none, pin: NGColumnPin = .none, value: @escaping (Row) -> NGCellValue) {
        column = NGTableColumn(id, title: title, alignment: alignment, format: format, summary: summary, pin: pin)
        self.value = value
        keyPath = nil
        comparator = nil
        write = nil
    }

    /// A stable id from a key path, such as `\Campaign.name`. A key path
    /// to a computed property can describe itself by its address in a
    /// release build (`\Campaign.<computed 0x…>`), which changes from one
    /// launch to the next, and saved layouts and formulas would lose the
    /// column: then the title is the id (pass `id:` for one that stays when
    /// the title is localized).
    static func identifier(of keyPath: AnyKeyPath, title: String) -> String {
        let described = String(describing: keyPath)
        return described.contains("<") ? "title:" + title : described
    }

    // MARK: Modifiers

    /// A fixed width, like `TableColumn.width(_:)`.
    public func width(_ width: CGFloat) -> Self {
        var copy = self
        copy.column.width = Double(width)
        copy.column.minWidth = Double(width)
        copy.column.maxWidth = Double(width)
        copy.column.isResizable = false
        return copy
    }

    /// A flexible width, like `TableColumn.width(min:ideal:max:)`.
    public func width(min: CGFloat? = nil, ideal: CGFloat? = nil, max: CGFloat? = nil) -> Self {
        var copy = self
        if let min { copy.column.minWidth = Double(min) }
        if let max { copy.column.maxWidth = Double(max) }
        if let ideal { copy.column.width = Double(ideal) }
        copy.column.width = Swift.min(Swift.max(copy.column.width, copy.column.minWidth), copy.column.maxWidth)
        return copy
    }

    /// Lets the user edit the column's cells, like the AppKit table's
    /// editable columns: text and numbers in place, Booleans with a check
    /// box, values from a menu of `choices`. The value is written into the
    /// row of the table's `Binding` of rows (`NGDataTable($rows) { … }`),
    /// with Undo. Needs a writable key path of an `NGCellValueEditable` type
    /// (strings, numbers, `Decimal`, Booleans, dates, tags, optionals);
    /// otherwise, or without the binding, the column doesn't edit.
    public func editable(_ isEditable: Bool = true, choices: [NGCellValue]? = nil) -> Self {
        var copy = self
        copy.column.isEditable = isEditable && write != nil
        copy.column.editChoices = choices
        return copy
    }

    /// The column's id for saved customizations, like
    /// `TableColumn.customizationID(_:)`: it replaces the column's id (the
    /// key path by default), which saved layouts, sorting and summary
    /// formulas refer to. Keep it stable across versions.
    public func customizationID(_ id: String) -> Self {
        var copy = self
        copy.column.id = id
        return copy
    }

    /// Whether the column shows until the user or a column customization
    /// says otherwise, like `TableColumn.defaultVisibility(_:)`: `.hidden`
    /// hides it at first.
    public func defaultVisibility(_ visibility: Visibility) -> Self {
        var copy = self
        copy.isHiddenByDefault = visibility == .hidden
        return copy
    }

    /// What the user can't do with the column, like
    /// `TableColumn.disabledCustomizationBehavior(_:)`: move it (`.reorder`),
    /// resize it (`.resize`) or hide it (`.visibility`); `.all` for none.
    /// Code can still change it.
    public func disabledCustomizationBehavior(_ behavior: TableColumnCustomizationBehavior) -> Self {
        var copy = self
        if behavior.contains(.reorder) { copy.column.isMovable = false }
        if behavior.contains(.resize) { copy.column.isResizable = false }
        if behavior.contains(.visibility) { copy.column.isHideable = false }
        return copy
    }

    /// Changes anything else of the table column (tool tip, filter, editing…).
    public func configured(_ change: (inout NGTableColumn) -> Void) -> Self {
        var copy = self
        change(&copy.column)
        return copy
    }
}

/// Columns under a common header, like `NGColumnGroup`.
public struct NGDataColumnGroup<Row> {
    let group: NGColumnGroup
    let columns: [NGDataColumn<Row>]

    /// - Parameters:
    ///   - title: The group's header title.
    ///   - id: Stays the same across languages and titles (saved layouts
    ///     refer to it); `"group:" + title` by default, which changes with a
    ///     localized title.
    ///   - pin: The region the group's columns are frozen in, if any.
    ///   - columns: The group's columns.
    public init(_ title: String, id: String? = nil, pin: NGColumnPin = .none,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        let leaves = columns().flatMap(\.leaves)
        self.columns = leaves
        group = NGColumnGroup(id ?? "group:" + title, title: title, pin: pin, columns: leaves.map(\.column))
    }
}

/// A column or a group of them, as `NGDataColumnBuilder` builds them.
///
/// Frozen: its cases are all there will be, so a `switch` over them needs
/// no `@unknown default`.
@frozen
public enum NGDataColumnItem<Row> {
    case column(NGDataColumn<Row>)
    case group(NGDataColumnGroup<Row>)

    var leaves: [NGDataColumn<Row>] {
        switch self {
        case .column(let column): [column]
        case .group(let group): group.columns
        }
    }

    var item: NGColumnItem {
        switch self {
        case .column(let column): .column(column.column)
        case .group(let group): .group(group.group)
        }
    }
}

/// Builds the columns of an `NGDataTable`, like SwiftUI's `TableColumnBuilder`.
@resultBuilder
public enum NGDataColumnBuilder<Row> {
    public static func buildExpression(_ column: NGDataColumn<Row>) -> [NGDataColumnItem<Row>] { [.column(column)] }
    public static func buildExpression(_ group: NGDataColumnGroup<Row>) -> [NGDataColumnItem<Row>] { [.group(group)] }
    public static func buildExpression(_ items: [NGDataColumnItem<Row>]) -> [NGDataColumnItem<Row>] { items }
    public static func buildBlock(_ parts: [NGDataColumnItem<Row>]...) -> [NGDataColumnItem<Row>] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [NGDataColumnItem<Row>]?) -> [NGDataColumnItem<Row>] { part ?? [] }
    public static func buildEither(first part: [NGDataColumnItem<Row>]) -> [NGDataColumnItem<Row>] { part }
    public static func buildEither(second part: [NGDataColumnItem<Row>]) -> [NGDataColumnItem<Row>] { part }
    public static func buildArray(_ parts: [[NGDataColumnItem<Row>]]) -> [NGDataColumnItem<Row>] { parts.flatMap { $0 } }
    public static func buildLimitedAvailability(_ part: [NGDataColumnItem<Row>]) -> [NGDataColumnItem<Row>] { part }
}
#endif
