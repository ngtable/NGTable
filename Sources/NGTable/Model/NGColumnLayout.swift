import Foundation

/// A group header spanning a contiguous range of leaf columns inside a region.
public struct NGGroupSpan: Sendable, Hashable {
    public var groupID: String
    public var title: String
    public var columnRange: Range<Int>
}

/// Leaf columns and group spans of one horizontal region (leading, scrolling, trailing).
public struct NGColumnRegionLayout: Sendable, Hashable {
    public var pin: NGColumnPin
    public var columns: [NGTableColumn] = []
    public var groups: [NGGroupSpan] = []
}

/// Resolves a column definition into the three regions of the table.
///
/// Items keep their relative order inside each region. A group's pin applies to
/// all of its columns, so a group never spans two regions. Duplicate column
/// identifiers are dropped (only the first occurrence is kept).
///
/// Hidden columns and groups are left out entirely; a group whose columns are
/// all hidden disappears too.
public struct NGColumnLayout: Sendable {
    public private(set) var leading = NGColumnRegionLayout(pin: .leading)
    public private(set) var center = NGColumnRegionLayout(pin: .none)
    public private(set) var trailing = NGColumnRegionLayout(pin: .trailing)
    public private(set) var columnsByID: [String: NGTableColumn] = [:]
    public private(set) var groupsByID: [String: NGColumnGroup] = [:]
    public private(set) var groupIDByColumnID: [String: String] = [:]

    /// - Parameters:
    ///   - items: The column definition, in display order.
    ///   - hiddenIDs: Identifiers of hidden columns and groups.
    public init(items: [NGColumnItem] = [], hiddenIDs: Set<String> = []) {
        // Duplicates are dropped silently here (layouts are also built for menu
        // states); NGTableView reports them once when its columns are set.
        var seenIDs = Set<String>()
        func isNew(_ column: NGTableColumn) -> Bool {
            seenIDs.insert(column.id).inserted
        }

        for item in items {
            switch item {
            case .column(let column):
                guard isNew(column), !hiddenIDs.contains(column.id) else { continue }
                columnsByID[column.id] = column
                self[column.pin].columns.append(column)

            case .group(let group):
                var members: [NGTableColumn] = []
                for var column in group.columns {
                    guard isNew(column), !hiddenIDs.contains(group.id), !hiddenIDs.contains(column.id) else { continue }
                    column.pin = group.pin
                    columnsByID[column.id] = column
                    groupIDByColumnID[column.id] = group.id
                    members.append(column)
                }
                guard !members.isEmpty else { continue }
                let start = self[group.pin].columns.count
                self[group.pin].columns.append(contentsOf: members)
                self[group.pin].groups.append(
                    NGGroupSpan(groupID: group.id, title: group.title, columnRange: start..<(start + members.count))
                )
                groupsByID[group.id] = group
            }
        }
    }

    public subscript(pin: NGColumnPin) -> NGColumnRegionLayout {
        get {
            switch pin {
            case .leading: leading
            case .none: center
            case .trailing: trailing
            }
        }
        set {
            switch pin {
            case .leading: leading = newValue
            case .none: center = newValue
            case .trailing: trailing = newValue
            }
        }
    }

    /// All leaf columns in display order.
    public var allColumns: [NGTableColumn] {
        leading.columns + center.columns + trailing.columns
    }

    public var hasGroups: Bool {
        !groupsByID.isEmpty
    }

    /// Identifiers used more than once among columns and groups (they share the
    /// namespace of hidden ids and saved layouts).
    public static func duplicateIDs(in items: [NGColumnItem]) -> Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for id in items.map(\.id) + items.flatMap({ item -> [String] in
            if case .group(let group) = item { return group.columns.map(\.id) }
            return []
        }) where !seen.insert(id).inserted {
            duplicates.insert(id)
        }
        return duplicates
    }
}
