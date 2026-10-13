import Foundation

/// The user's column customizations: order, widths, hidden columns and the
/// sort. It can be saved and later applied to the same column definition, even
/// after columns were added or removed in a newer version of the app.
public struct NGColumnLayoutState: Codable, Sendable, Hashable {
    /// Top-level item ids (ungrouped columns and groups) in display order.
    public var order: [String]
    /// Column ids of each group in display order, by group id.
    public var groupOrders: [String: [String]]
    /// Column widths set by the user, by column id.
    public var widths: [String: Double]
    /// Hidden column and group ids (see `NGTableView.hiddenColumnIDs`).
    public var hiddenIDs: Set<String>
    /// The sort (see `NGTableView.sortDescriptors`), or `nil` when none was
    /// saved: applying the state then keeps the table's current sort.
    public var sort: [Sort]?
    /// The column filters (see `NGTableView.columnFilters`), or `nil` when
    /// none were saved: applying the state then keeps the current ones.
    public var filters: [String: NGColumnFilter]?
    /// The regions the user moved top-level items to (column or group ids),
    /// or `nil` when none were saved: the definition's then. Only the user's
    /// changes: pins the app changes in a new version still apply to the
    /// other items. (Saved as "userPins": states from before, which saved
    /// every item's pin, keep the definition's.)
    public var pins: [String: NGColumnPin]?
    /// Every item's pin, as states saved them before user pins were kept
    /// apart: those that differ from the definition are the user's.
    var legacyPins: [String: NGColumnPin]?
    /// The grouping columns the user chose (empty: not grouped), or `nil`
    /// when not saved: applying the state then keeps the current grouping.
    public var grouping: [String]?

    /// One sort descriptor as it is saved: its key, direction and the name of
    /// its selector, like `NSTableView` saves them. Comparators can't be saved.
    public struct Sort: Codable, Sendable, Hashable {
        public var key: String
        public var ascending: Bool
        /// The selector's name, e.g. `localizedStandardCompare:`; `nil` for `compare:`.
        public var selector: String?

        public init(key: String, ascending: Bool, selector: String? = nil) {
            self.key = key
            self.ascending = ascending
            self.selector = selector
        }

        /// A descriptor's key, direction and selector (`nil` without a key).
        public init?(_ descriptor: NSSortDescriptor) {
            guard let key = descriptor.key else { return nil }
            self.key = key
            ascending = descriptor.ascending
            let name = descriptor.selector.map(NSStringFromSelector)
            selector = name == "compare:" ? nil : name
        }

        /// The sort descriptor it was saved from.
        public var descriptor: NSSortDescriptor {
            NSSortDescriptor(key: key, ascending: ascending, selector: selector.map(NSSelectorFromString))
        }
    }

    /// The columns alone: no sort, filters or grouping (applying it keeps theirs).
    var withoutSortFiltersAndGrouping: NGColumnLayoutState {
        var state = self
        state.sort = nil
        state.filters = nil
        state.grouping = nil
        return state
    }

    /// A state from its parts; empty parts leave the defaults.
    public init(order: [String] = [], groupOrders: [String: [String]] = [:], widths: [String: Double] = [:],
                hiddenIDs: Set<String> = [], sort: [Sort]? = nil) {
        self.order = order
        self.groupOrders = groupOrders
        self.widths = widths
        self.hiddenIDs = hiddenIDs
        self.sort = sort
    }

    private enum CodingKeys: String, CodingKey {
        case order, groupOrders, widths, hiddenIDs, sort, filters, grouping
        case pins = "userPins"
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case pins
    }

    /// Missing keys decode as empty (no saved sort), so states saved by other
    /// versions still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        groupOrders = try container.decodeIfPresent([String: [String]].self, forKey: .groupOrders) ?? [:]
        widths = try container.decodeIfPresent([String: Double].self, forKey: .widths) ?? [:]
        hiddenIDs = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenIDs) ?? []
        sort = try container.decodeIfPresent([Sort].self, forKey: .sort)
        filters = try container.decodeIfPresent([String: NGColumnFilter].self, forKey: .filters)
        pins = try container.decodeIfPresent([String: NGColumnPin].self, forKey: .pins)
        if pins == nil {
            legacyPins = try decoder.container(keyedBy: LegacyCodingKeys.self).decodeIfPresent([String: NGColumnPin].self, forKey: .pins)
        }
        grouping = try container.decodeIfPresent([String].self, forKey: .grouping)
    }

    /// Captures the state of a column definition and its sort.
    public init(items: [NGColumnItem], widths: [String: Double], hiddenIDs: Set<String>,
                sortDescriptors: [NSSortDescriptor]? = nil) {
        order = items.map(\.id)
        var groupOrders: [String: [String]] = [:]
        for case .group(let group) in items {
            groupOrders[group.id] = group.columns.map(\.id)
        }
        self.groupOrders = groupOrders
        self.widths = widths
        self.hiddenIDs = hiddenIDs
        sort = sortDescriptors?.compactMap(Sort.init)
    }

    /// The saved sort as sort descriptors, or `nil` when none was saved.
    public var sortDescriptors: [NSSortDescriptor]? {
        sort?.map(\.descriptor)
    }

    /// Reorders `items` like the saved order. Items the state doesn't know keep
    /// their position; saved ids that no longer exist are ignored.
    public func applyingOrder(to items: [NGColumnItem]) -> [NGColumnItem] {
        Self.reordered(items, by: order, id: \.id).map { item in
            switch item {
            case .column(var column):
                if let pin = pins?[column.id] { column.pin = pin }
                return .column(column)
            case .group(var group):
                if let columnOrder = groupOrders[group.id] { group.columns = Self.reordered(group.columns, by: columnOrder, id: \.id) }
                if let pin = pins?[group.id] { group.pin = pin }
                return .group(group)
            }
        }
    }

    /// Hidden ids, widths and sorts limited to the columns and groups of
    /// `items` (sorts by the keys of their sortable columns).
    public func restricted(to items: [NGColumnItem]) -> NGColumnLayoutState {
        var ids = Set(items.map(\.id))
        ids.formUnion(items.flatMap(\.leafColumns).map(\.id))
        let sortKeys = Set(items.flatMap(\.leafColumns).compactMap { $0.sortDescriptorPrototype?.key })
        var state = self
        state.hiddenIDs = hiddenIDs.intersection(ids)
        state.widths = widths.filter { ids.contains($0.key) }
        state.sort = sort?.filter { sortKeys.contains($0.key) }
        return state
    }

    /// Known elements fill the slots of known elements in saved order; unknown
    /// elements stay where they are.
    private static func reordered<Element>(_ elements: [Element], by order: [String], id: (Element) -> String) -> [Element] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let slots = elements.indices.filter { rank[id(elements[$0])] != nil }
        let known = slots.map { elements[$0] }.sorted { rank[id($0), default: 0] < rank[id($1), default: 0] }
        var result = elements
        for (slot, element) in zip(slots, known) {
            result[slot] = element
        }
        return result
    }
}
