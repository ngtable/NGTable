import Foundation

/// Horizontal placement of a column or a column group.
///
/// Frozen: its cases are all there will be, so a `switch` over them needs
/// no `@unknown default`.
@frozen
public enum NGColumnPin: Sendable, Hashable, CaseIterable, Codable {
    /// Frozen at the leading edge of the table.
    case leading
    /// Scrolls horizontally with the table content.
    case none
    /// Frozen at the trailing edge of the table.
    case trailing
}

/// Content alignment of a column's cells, header and summary. Leading and
/// trailing follow the table's `userInterfaceLayoutDirection` (leading is
/// the left edge, or the right edge in a right-to-left interface), whatever
/// the language of the text.
public enum NGColumnAlignment: Sendable, Hashable {
    /// Numeric columns align to the trailing edge, everything else to the leading edge.
    case automatic
    case leading
    case center
    case trailing

    /// Resolves `.automatic` into a concrete alignment.
    public func resolved(isNumeric: Bool) -> NGColumnAlignment {
        guard self == .automatic else { return self }
        return isNumeric ? .trailing : .leading
    }
}

/// A leaf column that displays values.
public struct NGTableColumn: Identifiable, Sendable, Hashable {
    /// Unique identifier across the whole table (including columns inside groups).
    public var id: String
    /// The header title. Empty titles suit narrow columns such as marks; menus
    /// then use `menuTitle`.
    public var title: String
    /// Initial width in points. The user's resized width replaces it (see
    /// `NGTableView.setWidth(_:forColumnID:)` and `autosaveName`).
    public var width: Double
    public var minWidth: Double
    public var maxWidth: Double
    /// Alignment of the cells and the summary value. Leading by default; use
    /// `.automatic` to align numbers to the trailing edge.
    public var alignment: NGColumnAlignment
    /// Alignment of the column title. Leading by default, independent of the
    /// cells, like `NSTableView` headers.
    public var headerAlignment: NGColumnAlignment
    /// How values are displayed, e.g. as currency. Also used for the summary,
    /// copying, searching and VoiceOver.
    public var format: NGValueFormat
    /// What the summary row shows for the column.
    public var summary: NGColumnSummary
    /// The sort a click on the header asks for, like `NSTableColumn`'s: its
    /// key and direction (and selector or comparator, if your data source
    /// sorts with `NSSortDescriptor`s). `nil` makes the column unsortable. The
    /// table doesn't sort itself: it updates `NGTableView.sortDescriptors`
    /// and tells the data source (`tableView(_:sortDescriptorsDidChange:)`).
    public var sortDescriptorPrototype: NSSortDescriptor? {
        get { sortPrototype?.descriptor }
        set { sortPrototype = newValue.map(NGSortPrototype.init) }
    }

    /// Whether clicking the header sorts by the column: whether it has a
    /// `sortDescriptorPrototype`. Setting it to `true` gives a column without
    /// one an ascending sort by its id.
    public var isSortable: Bool {
        get { sortPrototype != nil }
        set {
            guard newValue != isSortable else { return }
            sortDescriptorPrototype = newValue ? NSSortDescriptor(key: id, ascending: true) : nil
        }
    }

    private var sortPrototype: NGSortPrototype?
    /// Whether the user can resize the column by dragging its header divider
    /// (double-clicking the divider fits the column to its content).
    public var isResizable: Bool
    /// Whether the user can hide the column from the header's context menu.
    public var isHideable: Bool
    /// Whether the user can move the column by dragging its header. Other columns
    /// can't move past a fixed column either, e.g. a mark column that stays first.
    public var isMovable: Bool
    /// Whether a divider follows the column's title in the header. Turn it off
    /// for narrow untitled columns, e.g. of marks, that belong to the next one.
    public var showsHeaderDivider: Bool
    /// Ignored for columns that belong to a group: the group's pin is used instead.
    public var pin: NGColumnPin
    /// Shown when the pointer rests on the column's header.
    public var toolTip: String?
    /// How cells show that a targeted update changed their value (a flash
    /// that fades; green or red for numbers going up or down), or `nil`.
    public var changeHighlight: NGChangeHighlight?
    /// How number cells look by their values: data bars, a color scale or
    /// colored text (see `NGConditionalFormat`), or `nil`.
    public var conditionalFormat: NGConditionalFormat?
    /// Whether the user can edit the column's cells in place (see
    /// `NGTableView.editCell(row:columnID:text:)`); the data source receives
    /// the values.
    public var isEditable: Bool
    /// The values an editable column's cells choose from, in a menu instead
    /// of a text field (e.g. statuses as tags), or `nil`. Editable Boolean
    /// cells show a check box without them.
    public var editChoices: [NGCellValue]?
    /// With `editChoices`, whether a single click on a cell opens the menu
    /// (like a pop-up button), not only a double click or Return. Every cell
    /// of an editable column with choices shows the pop-up's chevron.
    public var opensChoicesOnClick: Bool = false
    /// Whether the header offers a filter for the column, when the table
    /// allows column filters (`NGTableView.allowsColumnFilters`).
    public var isFilterable: Bool

    /// - Parameters:
    ///   - id: Unique across all columns and groups of the table; also the key
    ///     the data source answers values for, and the key of saved layouts.
    ///   - title: The header title.
    ///   - width: Initial width in points.
    ///   - minWidth: The narrowest the user can make the column.
    ///   - maxWidth: The widest the user can make the column.
    ///   - alignment: Alignment of the cells and the summary value.
    ///   - headerAlignment: Alignment of the title.
    ///   - format: How values are displayed.
    ///   - summary: What the summary row shows.
    ///   - isSortable: Whether header clicks request sorting by the column:
    ///     ascending by its id. Set `sortDescriptorPrototype` for another key,
    ///     direction or selector.
    ///   - isResizable: Whether the user can resize the column.
    ///   - isHideable: Whether the user can hide the column.
    ///   - isMovable: Whether the user can move the column.
    ///   - showsHeaderDivider: Whether a divider follows the title.
    ///   - pin: The region of the column (ignored inside groups).
    ///   - toolTip: Shown over the header.
    ///   - changeHighlight: How changed values flash (see `NGChangeHighlight`).
    ///   - isFilterable: Whether the header offers a filter for the column.
    ///   - conditionalFormat: How number cells look by their values.
    ///   - isEditable: Whether the user can edit the cells in place.
    ///   - editChoices: The values edited cells choose from, in a menu.
    public init(
        _ id: String,
        title: String,
        width: Double = 100,
        minWidth: Double = 40,
        maxWidth: Double = 1000,
        alignment: NGColumnAlignment = .leading,
        headerAlignment: NGColumnAlignment = .leading,
        format: NGValueFormat = .automatic,
        summary: NGColumnSummary = .none,
        isSortable: Bool = true,
        isResizable: Bool = true,
        isHideable: Bool = true,
        isMovable: Bool = true,
        showsHeaderDivider: Bool = true,
        pin: NGColumnPin = .none,
        toolTip: String? = nil,
        changeHighlight: NGChangeHighlight? = nil,
        isFilterable: Bool = true,
        conditionalFormat: NGConditionalFormat? = nil,
        isEditable: Bool = false,
        editChoices: [NGCellValue]? = nil
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.alignment = alignment
        self.headerAlignment = headerAlignment
        self.format = format
        self.summary = summary
        self.sortPrototype = isSortable ? NGSortPrototype(NSSortDescriptor(key: id, ascending: true)) : nil
        self.isResizable = isResizable
        self.isHideable = isHideable
        self.isMovable = isMovable
        self.showsHeaderDivider = showsHeaderDivider
        self.pin = pin
        self.toolTip = toolTip
        self.changeHighlight = changeHighlight
        self.isFilterable = isFilterable
        self.conditionalFormat = conditionalFormat
        self.isEditable = isEditable
        self.editChoices = editChoices
    }

    /// The name in menus: the title, or for untitled columns (e.g. a narrow
    /// tag column) the tool tip, or the id.
    public var menuTitle: String {
        if !title.isEmpty { return title }
        if let toolTip, !toolTip.isEmpty { return toolTip }
        return id
    }

    /// Whether the column is expected to hold numbers (used for automatic
    /// alignment and the kind of column filter): a number format, or a
    /// summary of numbers (a count is of rows, whatever they hold).
    public var isNumeric: Bool {
        if format.isNumeric { return true }
        if case .aggregate(.count, _) = summary { return false }
        return summary.hasValue
    }
}

/// A super-column that spans several leaf columns, e.g. "Income" over "Store 1", "Store 2".
public struct NGColumnGroup: Identifiable, Sendable, Hashable {
    /// Unique across all columns and groups of the table.
    public var id: String
    /// Shown in the group header band above the columns.
    public var title: String
    /// The group's columns, in display order.
    public var columns: [NGTableColumn]
    /// Applies to every column in the group.
    public var pin: NGColumnPin

    public init(_ id: String, title: String, pin: NGColumnPin = .none, columns: [NGTableColumn]) {
        self.id = id
        self.title = title
        self.pin = pin
        self.columns = columns
    }
}

/// A top-level entry of the table's column definition.
///
/// Frozen: its cases are all there will be, so a `switch` over them needs
/// no `@unknown default`.
@frozen
public enum NGColumnItem: Sendable, Hashable {
    case column(NGTableColumn)
    case group(NGColumnGroup)

    /// The region the item is shown in.
    public var pin: NGColumnPin {
        switch self {
        case .column(let column): column.pin
        case .group(let group): group.pin
        }
    }

    /// The item in another region.
    func withPin(_ pin: NGColumnPin) -> NGColumnItem {
        switch self {
        case .column(var column):
            column.pin = pin
            return .column(column)
        case .group(var group):
            group.pin = pin
            return .group(group)
        }
    }

    /// The column itself, or the group's columns.
    public var leafColumns: [NGTableColumn] {
        switch self {
        case .column(let column): [column]
        case .group(let group): group.columns
        }
    }
}

/// Keeps a column's sort descriptor prototype in its `Sendable` value.
/// `NSSortDescriptor` is immutable, and the table only stores and hands it
/// back: it never evaluates it, on any thread.
private struct NGSortPrototype: @unchecked Sendable, Hashable {
    let descriptor: NSSortDescriptor

    init(_ descriptor: NSSortDescriptor) {
        self.descriptor = descriptor
    }
}

/// How a column shows that a targeted update changed a cell's value.
public enum NGChangeHighlight: Sendable, Hashable {
    /// A flash of the accent color that fades.
    case flash
    /// Numbers that went up flash green, those that went down red (like a
    /// trading screen); other values flash the accent color.
    case direction
}
