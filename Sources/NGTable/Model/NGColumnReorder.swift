import Foundation

/// Rules for moving columns by dragging their headers.
///
/// Moves never break a group apart and never move a column to another region:
/// - an ungrouped column or a whole group moves among the top-level items of its region;
/// - a column inside a group moves among the columns of that group.
public enum NGColumnReorder {
    /// What is being dragged.
    public enum Unit: Hashable, Sendable {
        /// A top-level item: an ungrouped column (column id) or a whole group (group id).
        case item(id: String)
        /// A column inside a group.
        case member(columnID: String, groupID: String)
    }

    /// Identifiers the unit can be reordered among, in display order. For
    /// `.item` these are column or group ids, for `.member` column ids.
    /// Hidden siblings are skipped.
    public static func siblings(of unit: Unit, in items: [NGColumnItem], hiddenIDs: Set<String> = []) -> [String] {
        switch unit {
        case .item(let id):
            guard let pin = items.first(where: { $0.id == id })?.pin else { return [] }
            return items.filter { $0.pin == pin && $0.isVisible(hiddenIDs: hiddenIDs) }.map(\.id)
        case .member(_, let groupID):
            return group(groupID, in: items)?.columns.map(\.id).filter { !hiddenIDs.contains($0) } ?? []
        }
    }

    /// The items after moving `unit` to `index` among its visible siblings
    /// (clamped). Hidden siblings keep their place relative to the visible
    /// sibling that follows them.
    public static func moving(_ unit: Unit, to index: Int, in items: [NGColumnItem], hiddenIDs: Set<String>) -> [NGColumnItem] {
        // Even without hidden ids, empty groups are not visible siblings, so the
        // index is always mapped onto the full list.
        let draggedID = switch unit {
        case .item(let id): id
        case .member(let columnID, _): columnID
        }
        let visibleOthers = siblings(of: unit, in: items, hiddenIDs: hiddenIDs).filter { $0 != draggedID }
        // Every sibling slot, including hidden columns and empty groups.
        var allOthers: [String]
        switch unit {
        case .item(let id):
            let pin = items.first { $0.id == id }?.pin
            allOthers = items.filter { $0.pin == pin }.map(\.id)
        case .member(_, let groupID):
            allOthers = group(groupID, in: items)?.columns.map(\.id) ?? []
        }
        allOthers.removeAll { $0 == draggedID }
        let index = min(max(index, 0), visibleOthers.count)
        let fullIndex: Int
        if index < visibleOthers.count {
            fullIndex = allOthers.firstIndex(of: visibleOthers[index]) ?? allOthers.count
        } else if let last = visibleOthers.last, let lastIndex = allOthers.firstIndex(of: last) {
            fullIndex = lastIndex + 1
        } else {
            fullIndex = allOthers.count
        }
        return moving(unit, to: fullIndex, in: items)
    }

    /// The items after moving `unit` to `index` among all its siblings (clamped).
    public static func moving(_ unit: Unit, to index: Int, in items: [NGColumnItem]) -> [NGColumnItem] {
        var items = items
        switch unit {
        case .item(let id):
            guard let pin = items.first(where: { $0.id == id })?.pin else { return items }
            // Reorder the region's top-level items in place, leaving other regions untouched.
            let slots = items.indices.filter { items[$0].pin == pin }
            var regionItems = slots.map { items[$0] }
            guard let from = regionItems.firstIndex(where: { $0.id == id }) else { return items }
            let moved = regionItems.remove(at: from)
            regionItems.insert(moved, at: min(max(index, 0), regionItems.count))
            for (slot, item) in zip(slots, regionItems) {
                items[slot] = item
            }

        case .member(let columnID, let groupID):
            guard let itemIndex = items.firstIndex(where: { $0.id == groupID }),
                  case .group(var group) = items[itemIndex],
                  let from = group.columns.firstIndex(where: { $0.id == columnID }) else { return items }
            let moved = group.columns.remove(at: from)
            group.columns.insert(moved, at: min(max(index, 0), group.columns.count))
            items[itemIndex] = .group(group)
        }
        return items
    }

    /// Where a dragged unit belongs among its siblings while being dragged.
    ///
    /// A sibling on the dragged unit's leading side is passed when the dragged
    /// span's leading edge crosses the sibling's midpoint; a sibling on its
    /// trailing side when the trailing edge does. Using edges instead of the
    /// center lets wide columns pass narrow neighbors even when the drag is
    /// clamped at a region edge, and gives natural hysteresis after a swap.
    ///
    /// - Parameters:
    ///   - currentIndex: The dragged unit's index among its siblings.
    ///   - others: The other siblings' horizontal ranges, in display order.
    ///   - draggedSpan: The dragged unit's current horizontal range.
    public static func targetIndex(currentIndex: Int, others: [ClosedRange<Double>], draggedSpan: ClosedRange<Double>) -> Int {
        var index = 0
        for (position, range) in others.enumerated() {
            let midpoint = (range.lowerBound + range.upperBound) / 2
            let isBeforeDragged = position < currentIndex
            let staysBefore = isBeforeDragged ? midpoint <= draggedSpan.lowerBound : midpoint < draggedSpan.upperBound
            if staysBefore {
                index += 1
            }
        }
        return index
    }

    private static func group(_ id: String, in items: [NGColumnItem]) -> NGColumnGroup? {
        for case .group(let group) in items where group.id == id {
            return group
        }
        return nil
    }
}

extension NGColumnItem {
    /// The column id or group id.
    public var id: String {
        switch self {
        case .column(let column): column.id
        case .group(let group): group.id
        }
    }

    /// Whether the item is shown: it is not hidden itself and, for a group,
    /// at least one of its columns is not hidden.
    public func isVisible(hiddenIDs: Set<String>) -> Bool {
        guard !hiddenIDs.contains(id) else { return false }
        return leafColumns.contains { !hiddenIDs.contains($0.id) }
    }
}
