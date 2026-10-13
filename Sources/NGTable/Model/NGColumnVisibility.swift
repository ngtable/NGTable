import Foundation

/// Rules for showing and hiding columns and groups, as offered by the header's
/// context menu.
///
/// Hidden identifiers can name ungrouped columns, groups and columns inside
/// groups. Hiding a group keeps the hidden state of its columns, so showing the
/// group again restores it as it was.
public enum NGColumnVisibility {
    /// Checkmark state of a menu entry.
    ///
    /// Frozen: its cases are all there will be, so a `switch` over them needs
    /// no `@unknown default`.
    @frozen
    public enum State: Sendable, Hashable {
        case visible
        /// A group with some of its columns hidden.
        case partiallyVisible
        case hidden
    }

    public static func state(of id: String, in items: [NGColumnItem], hiddenIDs: Set<String>) -> State {
        for item in items {
            switch item {
            case .column(let column) where column.id == id:
                return hiddenIDs.contains(id) ? .hidden : .visible
            case .group(let group) where group.id == id:
                guard item.isVisible(hiddenIDs: hiddenIDs) else { return .hidden }
                return group.columns.contains { hiddenIDs.contains($0.id) } ? .partiallyVisible : .visible
            case .group(let group) where group.columns.contains(where: { $0.id == id }):
                return hiddenIDs.contains(group.id) || hiddenIDs.contains(id) ? .hidden : .visible
            default:
                continue
            }
        }
        return .hidden
    }

    /// The hidden identifiers after the user toggles a column or group entry.
    ///
    /// - A visible (or partially visible) group is hidden as a whole; showing it
    ///   again restores its columns as they were, or shows all of them if they
    ///   were all hidden.
    /// - Showing a column of a hidden group shows the group with just that column.
    public static func toggling(_ id: String, in items: [NGColumnItem], hiddenIDs: Set<String>) -> Set<String> {
        var hidden = hiddenIDs
        let isShowing = state(of: id, in: items, hiddenIDs: hiddenIDs) == .hidden
        for item in items {
            switch item {
            case .column(let column) where column.id == id:
                if isShowing { hidden.remove(id) } else { hidden.insert(id) }
                return hidden
            case .group(let group) where group.id == id:
                if isShowing {
                    hidden.remove(id)
                    let memberIDs = group.columns.map(\.id)
                    if memberIDs.allSatisfy(hidden.contains) {
                        hidden.subtract(memberIDs)
                    }
                } else {
                    hidden.insert(id)
                }
                return hidden
            case .group(let group) where group.columns.contains(where: { $0.id == id }):
                if isShowing {
                    if hidden.remove(group.id) != nil {
                        hidden.formUnion(group.columns.map(\.id))
                    }
                    hidden.remove(id)
                } else {
                    hidden.insert(id)
                }
                return hidden
            default:
                continue
            }
        }
        return hidden
    }

    /// Whether the entry can be toggled: showing is always possible; hiding
    /// needs hideable columns and must leave at least one column visible.
    public static func canToggle(_ id: String, in items: [NGColumnItem], hiddenIDs: Set<String>) -> Bool {
        guard state(of: id, in: items, hiddenIDs: hiddenIDs) != .hidden else { return true }
        let newHidden = toggling(id, in: items, hiddenIDs: hiddenIDs)
        let remaining = Set(NGColumnLayout(items: items, hiddenIDs: newHidden).allColumns.map(\.id))
        guard !remaining.isEmpty else { return false }
        // Every column that would disappear must be hideable.
        return NGColumnLayout(items: items, hiddenIDs: hiddenIDs).allColumns
            .allSatisfy { remaining.contains($0.id) || $0.isHideable }
    }
}
