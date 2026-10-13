#if os(macOS)
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import os

// NGTable in SwiftUI, like `Table`: rows (`Identifiable`), columns of values,
// a selection and a sort order bound to state. It wraps an `NGTableView`;
// each update tells it what changed by identity (rows inserted, removed,
// moved, and with `Equatable` rows only the changed ones read again), so a
// live array of 100,000 rows updates like the AppKit table does.
//
// Sorting: with a `sortOrder` binding the app sorts the rows, like SwiftUI's
// `Table` (header clicks change the comparators); without one the table
// sorts them itself (`sortsRows`), also as values change.

/// A table of rows and value columns, like SwiftUI's `Table`.
///
/// ```swift
/// NGDataTable(campaigns, selection: $selection) {
///     NGDataColumn("Name", value: \.name)
///     NGDataColumn("Spend", value: \.spend, format: .currency(code: "USD"), summary: .aggregate(.sum))
/// }
/// .rowContextMenu { ids in
///     Button("Archive") { archive(ids) }
/// } primaryAction: { ids in
///     open(ids)
/// }
/// ```
public struct NGDataTable<Row: Identifiable>: NSViewRepresentable {
    @usableFromInline
    enum Selection {
        case none
        case many(Binding<Set<Row.ID>>)
        case one(Binding<Row.ID?>)
    }

    @usableFromInline let rows: [Row]
    @usableFromInline let items: [NGDataColumnItem<Row>]
    @usableFromInline let selection: Selection
    @usableFromInline let sortOrder: Binding<[KeyPathComparator<Row>]>?
    /// What changed between two arrays of rows, compiled for `Row` in the
    /// app (made in an inlinable initializer): generic code over 100,000
    /// rows cost ~200 ns a row, specialized a few.
    @usableFromInline let diff: ([Row], [Row]) -> NGRowsDiff
    /// The rows as a binding, which edits write into (`NGDataTable($rows)`).
    @usableFromInline var rowsBinding: Binding<[Row]>?
    var menu: ((Set<Row.ID>) -> AnyView)?
    var primaryAction: ((Set<Row.ID>) -> Void)?
    var rowFilter: NGRowFilter?
    /// A filter by rows (see `rowFilter(searchText:columnIDs:id:isIncluded:)`).
    var rowPredicate: RowPredicate?
    var rowGrouping: NGRowGrouping?
    var configuration: ((NGTableView) -> Void)?
    /// SwiftUI's column customization (visibility), and the table's own
    /// (order, widths, visibility, pins).
    @usableFromInline var columnCustomization: Binding<TableColumnCustomization<Row>>?
    var fullColumnCustomization: Binding<NGColumnCustomization>?
    /// Rows with children (`init(_:children:…)`): each child's parent, and
    /// the rows shown open.
    @usableFromInline var parents: [Row.ID: Row.ID]?
    var expandedRows: Binding<Set<Row.ID>>?
    /// After the user's edit is written into a row (`onSubmit`).
    var submitAction: (() -> Void)?
    /// What deleting, moving and dropping onto rows does.
    var deleteAction: ((IndexSet) -> Void)?
    var moveAction: ((IndexSet, Int) -> Void)?
    var rowDrop: RowDrop?

    /// Values of a type dropped between rows: the types it takes, and what
    /// takes the dropped items (as item providers) and where they go.
    struct RowDrop {
        var types: [UTType]
        var accept: ([NSItemProvider], Int) -> Void
    }

    /// A table of rows, with a selection of several rows (or none) and a
    /// sort order the app sorts the rows by (or none: the table sorts them).
    @inlinable
    public init(_ rows: [Row], selection: Binding<Set<Row.ID>>? = nil,
                sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
                columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        self.init(rows: rows, items: columns(), columnCustomization: columnCustomization, selection: selection.map { .many($0) } ?? .none, sortOrder: sortOrder,
                  diff: { Self.diff($0, $1, equal: nil) })
    }

    /// A table of rows with a selection of one row at most.
    @inlinable
    public init(_ rows: [Row], selection: Binding<Row.ID?>, sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
                columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        self.init(rows: rows, items: columns(), columnCustomization: columnCustomization, selection: .one(selection), sortOrder: sortOrder,
                  diff: { Self.diff($0, $1, equal: nil) })
    }

    /// A table whose editable columns write into the rows (like SwiftUI's
    /// `Table($rows)`).
    @inlinable
    public init(_ rows: Binding<[Row]>, selection: Binding<Set<Row.ID>>? = nil,
                sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
                columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        self.init(rows: rows.wrappedValue, items: columns(), columnCustomization: columnCustomization, selection: selection.map { .many($0) } ?? .none,
                  sortOrder: sortOrder, diff: { Self.diff($0, $1, equal: nil) }, rowsBinding: rows)
    }

    /// A table whose editable columns write into the rows, with a selection
    /// of one row at most.
    @inlinable
    public init(_ rows: Binding<[Row]>, selection: Binding<Row.ID?>, sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
                columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        self.init(rows: rows.wrappedValue, items: columns(), columnCustomization: columnCustomization, selection: .one(selection), sortOrder: sortOrder,
                  diff: { Self.diff($0, $1, equal: nil) }, rowsBinding: rows)
    }

    /// A table of rows with children, like `Table(_:children:)`: each row's
    /// `children` (`nil` or empty for none) show under it as a tree, collapsed
    /// at first; see `expandedRows(_:)`. The table sorts siblings among
    /// themselves; with a `sortOrder` binding, sort each level yourself.
    @inlinable
    public init(_ roots: [Row], children: KeyPath<Row, [Row]?>, selection: Binding<Set<Row.ID>>? = nil,
                sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
                columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        let (rows, parents) = Self.flatten(roots, children: children)
        self.init(rows: rows, items: columns(), columnCustomization: columnCustomization, selection: selection.map { .many($0) } ?? .none,
                  sortOrder: sortOrder, diff: { Self.diff($0, $1, equal: nil) })
        self.parents = parents
    }

    /// A table of rows with children, with a selection of one row at most.
    @inlinable
    public init(_ roots: [Row], children: KeyPath<Row, [Row]?>, selection: Binding<Row.ID?>,
                sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
                columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        let (rows, parents) = Self.flatten(roots, children: children)
        self.init(rows: rows, items: columns(), columnCustomization: columnCustomization, selection: .one(selection),
                  sortOrder: sortOrder, diff: { Self.diff($0, $1, equal: nil) })
        self.parents = parents
    }

    /// Every row of a tree, depth first, and each child's parent.
    @inlinable
    static func flatten(_ roots: [Row], children: KeyPath<Row, [Row]?>) -> ([Row], [Row.ID: Row.ID]) {
        var rows: [Row] = []
        var parents: [Row.ID: Row.ID] = [:]
        var stack: [(row: Row, parent: Row.ID?)] = roots.reversed().map { ($0, nil) }
        while let (row, parent) = stack.popLast() {
            rows.append(row)
            if let parent { parents[row.id] = parent }
            for child in (row[keyPath: children] ?? []).reversed() { stack.append((child, row.id)) }
        }
        return (rows, parents)
    }

    @usableFromInline
    init(rows: [Row], items: [NGDataColumnItem<Row>], columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
         selection: Selection, sortOrder: Binding<[KeyPathComparator<Row>]>?,
         diff: @escaping ([Row], [Row]) -> NGRowsDiff, rowsBinding: Binding<[Row]>? = nil) {
        self.rows = rows
        self.items = items
        self.columnCustomization = columnCustomization
        self.selection = selection
        self.sortOrder = sortOrder
        self.diff = diff
        self.rowsBinding = rowsBinding
    }

    /// What changed from `old` to `new` by identity: rows removed, inserted
    /// and moved (a feed's few, found walking both arrays at once without
    /// hashing; otherwise by each row's new place, the rows off the longest
    /// run kept in order being the moved ones), or, when very many rows
    /// moved, each old row's new place; and the kept rows whose values
    /// changed (all of them without `equal`).
    @inlinable
    static func diff(_ old: [Row], _ new: [Row], equal: ((Row, Row) -> Bool)?) -> NGRowsDiff {
        var changed = IndexSet(), removed = IndexSet(), inserted = IndexSet()
        var i = 0, j = 0
        var isSimple = true
        // A row up to this many places ahead in the other array: the rows
        // before it went or came (looked for in both arrays at once, nearest
        // first, so a block costs its length, and the walk at most two
        // passes over the rows). A row not found within it (a move far
        // away, a shuffle) ends the walk at once: then by new places.
        let window = 1_024
        while i < old.count, j < new.count {
            if old[i].id == new[j].id {
                if !(equal?(old[i], new[j]) ?? false) { changed.insert(j) }
                i += 1
                j += 1
                continue
            }
            var distance = 1, found = false
            while distance <= window, i + distance < old.count || j + distance < new.count {
                if i + distance < old.count, old[i + distance].id == new[j].id {
                    removed.insert(integersIn: i..<(i + distance))
                    i += distance
                    found = true
                    break
                }
                if j + distance < new.count, new[j + distance].id == old[i].id {
                    inserted.insert(integersIn: j..<(j + distance))
                    j += distance
                    found = true
                    break
                }
                distance += 1
            }
            if !found {
                isSimple = false
                break
            }
        }
        if isSimple {
            removed.insert(integersIn: i..<old.count)
            inserted.insert(integersIn: j..<new.count)
            // A record both removed and inserted moved: the other kept rows
            // are in order (the walk matched them so).
            var moves: [NGRowsDiff.Move] = []
            var movesAreFew = true
            if !removed.isEmpty, !inserted.isEmpty {
                var insertedByID = [Row.ID: Int](minimumCapacity: inserted.count)
                for index in inserted { insertedByID[new[index].id] = index }
                for index in removed {
                    if let to = insertedByID[old[index].id] { moves.append(NGRowsDiff.Move(old: index, new: to)) }
                }
                // Many: the walk took rows in between for moved (a swap far
                // apart); places give the fewest moves.
                movesAreFew = moves.count <= 16
            }
            if movesAreFew {
                var changedMoved: [Int] = []
                for move in moves {
                    removed.remove(move.old)
                    inserted.remove(move.new)
                    if !(equal?(old[move.old], new[move.new]) ?? false) { changedMoved.append(move.new) }
                }
                for index in changedMoved { changed.insert(index) }
                return NGRowsDiff(sameOrder: removed.isEmpty && inserted.isEmpty && moves.isEmpty, changed: changed,
                                  oldToNew: [], removed: removed, inserted: inserted, moves: moves)
            }
        }
        // Each old row's new place.
        var position = [Row.ID: Int](minimumCapacity: new.count)
        for (index, row) in new.enumerated() { position[row.id] = index }
        var oldToNew: [Int?] = []
        oldToNew.reserveCapacity(old.count)
        var changedRows: [Int] = []
        var isNew = [Bool](repeating: true, count: new.count)
        for row in old {
            let index = position[row.id]
            oldToNew.append(index)
            if let index {
                isNew[index] = false
                if !(equal?(row, new[index]) ?? false) { changedRows.append(index) }
            }
        }
        changedRows.sort()
        changed = IndexSet(changedRows)
        let moved = NGRowsDiff.movedRows(oldToNew)
        guard moved.count <= NGRowsDiff.moveLimit else {
            return NGRowsDiff(sameOrder: false, changed: changed, oldToNew: oldToNew, removed: [], inserted: [], moves: [])
        }
        removed = IndexSet()
        for (index, to) in oldToNew.enumerated() where to == nil { removed.insert(index) }
        // (In ascending order: each goes at the end of the set.)
        inserted = IndexSet()
        for (index, isNewRow) in isNew.enumerated() where isNewRow { inserted.insert(index) }
        let moves = moved.map { NGRowsDiff.Move(old: $0, new: oldToNew[$0]!) }
        return NGRowsDiff(sameOrder: removed.isEmpty && inserted.isEmpty && moves.isEmpty, changed: changed,
                          oldToNew: [], removed: removed, inserted: inserted, moves: moves)
    }

    // MARK: Modifiers

    /// The menu of a right-click (SwiftUI buttons, sections, submenus) for
    /// the rows it is for, and the action of a double click or Return, like
    /// `contextMenu(forSelectionType:menu:primaryAction:)` on a `Table`. (Its
    /// own name: SwiftUI's modifier wouldn't reach the AppKit table.) The
    /// menu needs macOS 14.4.
    public func rowContextMenu<Menu: View>(@ViewBuilder menu: @escaping (Set<Row.ID>) -> Menu,
                                           primaryAction: ((Set<Row.ID>) -> Void)? = nil) -> Self {
        var copy = self
        copy.menu = { AnyView(menu($0)) }
        copy.primaryAction = primaryAction
        return copy
    }

    /// Shows only the rows a filter lets through (e.g. a search field's
    /// text). Its `isIncluded` receives indexes of the rows the table shows
    /// now: with one, the filter applies to every row again on every update;
    /// prefer `rowFilter(searchText:columnIDs:id:isIncluded:)`, which tests
    /// rows and only the changed ones.
    public func rowFilter(_ filter: NGRowFilter?) -> Self {
        var copy = self
        copy.rowFilter = filter
        copy.rowPredicate = nil
        return copy
    }

    /// Shows only the rows that match a search (like `NGRowFilter`) and that
    /// `isIncluded` lets through. Like `task(id:)`, every row is tested again
    /// when `id` changes: give it what the condition depends on besides the
    /// row (a threshold, a toggle). Rows that change or arrive are tested as
    /// they do, by the current condition.
    ///
    /// ```swift
    /// .rowFilter(searchText: query, id: minimumSpend) { $0.spend >= minimumSpend }
    /// ```
    public func rowFilter(searchText: String = "", columnIDs: Set<String>? = nil, id: some Hashable = 0,
                          isIncluded: @escaping (Row) -> Bool) -> Self {
        var copy = self
        copy.rowFilter = nil
        copy.rowPredicate = RowPredicate(searchText: searchText, columnIDs: columnIDs, id: AnyHashable(id), isIncluded: isIncluded)
        return copy
    }

    /// A filter by rows, and what decides when it applies to every row again.
    struct RowPredicate {
        var searchText: String
        var columnIDs: Set<String>?
        var id: AnyHashable
        var isIncluded: (Row) -> Bool
    }

    /// Groups the rows by columns' values (see `NGRowGrouping`).
    public func rowGrouping(_ grouping: NGRowGrouping?) -> Self {
        var copy = self
        copy.rowGrouping = grouping
        return copy
    }

    /// After the user's edit of a cell is written into its row, like
    /// `onSubmit(of:_:)` on a `Table`'s text fields (not for Undo and Redo).
    public func onSubmit(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.submitAction = action
        return copy
    }

    /// Which rows with children are open, like `DisclosureTableRow`'s
    /// `isExpanded` for each of them: the user's opening and closing goes
    /// into the binding, and the binding's rows open (others close).
    public func expandedRows(_ expanded: Binding<Set<Row.ID>>) -> Self {
        var copy = self
        copy.expandedRows = expanded
        return copy
    }

    /// Deleting rows, like `onDelete(perform:)` on a `Table`'s `ForEach`:
    /// Delete, Backspace and Edit > Delete give the selected rows' offsets in
    /// the array (for `remove(atOffsets:)`).
    public func onDelete(perform action: ((IndexSet) -> Void)?) -> Self {
        var copy = self
        copy.deleteAction = action
        return copy
    }

    /// Moving rows by dragging them, like `onMove(perform:)`: the dragged
    /// rows' offsets and the offset they go before, as
    /// `move(fromOffsets:toOffset:)` takes them. While the table sorts the
    /// rows itself (a header click), clear its sort to let the order show.
    public func onMove(perform action: ((IndexSet, Int) -> Void)?) -> Self {
        var copy = self
        copy.moveAction = action
        return copy
    }

    /// Takes values dropped between rows, like `dropDestination(for:action:)`
    /// on a `Table`'s `ForEach`: the values decoded from what was dropped (the
    /// type's imported content types), and the offset they go before.
    @available(macOS 15.2, *)
    public func dropDestination<T: Transferable>(for payloadType: T.Type = T.self,
                                                 action: @escaping ([T], Int) -> Void) -> Self {
        dropDestination(for: payloadType, contentTypes: T.importedContentTypes(), action: action)
    }

    /// Takes values dropped between rows, given the content types they come
    /// as (before macOS 15.2, which tells a type's own).
    public func dropDestination<T: Transferable>(for payloadType: T.Type = T.self, contentTypes: [UTType],
                                                 action: @escaping ([T], Int) -> Void) -> Self {
        var copy = self
        copy.rowDrop = RowDrop(types: contentTypes) { providers, index in
            // Decoded in the background, then given in the order dropped.
            Task { @MainActor in
                var items: [T] = []
                for provider in providers {
                    if let item = await Self.load(T.self, from: provider) { items.append(item) }
                }
                if !items.isEmpty { action(items, index) }
            }
        }
        return copy
    }

    private static func load<T: Transferable>(_ type: T.Type, from provider: NSItemProvider) async -> T? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: type) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }

    /// Keeps the user's columns, their order, widths, visibility and pins,
    /// in a customization the app stores (e.g. in `@SceneStorage`), like a
    /// `TableColumnCustomization` (which only lets the table keep visibility;
    /// see `NGColumnCustomization`).
    public func columnCustomization(_ customization: Binding<NGColumnCustomization>) -> Self {
        var copy = self
        copy.fullColumnCustomization = customization
        return copy
    }

    /// Configures the `NGTableView` on every update: anything SwiftUI
    /// doesn't cover (summary scope, style, autosave name, key provider…).
    public func tableConfiguration(_ configure: @escaping (NGTableView) -> Void) -> Self {
        var copy = self
        copy.configuration = configure
        return copy
    }

    // MARK: NSViewRepresentable

    public func makeCoordinator() -> NGDataTableCoordinator<Row> {
        NGDataTableCoordinator()
    }

    public func makeNSView(context: Context) -> NGTableView {
        let table = NGTableView(frame: .zero)
        context.coordinator.environment = context.environment
        context.coordinator.update(table, from: self)
        return table
    }

    public func updateNSView(_ table: NGTableView, context: Context) {
        context.coordinator.environment = context.environment
        context.coordinator.update(table, from: self)
    }
}

extension NGDataTable where Row: Equatable {
    /// A table of `Equatable` rows with children: an update reads again
    /// only the rows that changed (a parent with a changed child too).
    @inlinable
    public init(_ roots: [Row], children: KeyPath<Row, [Row]?>, selection: Binding<Set<Row.ID>>? = nil,
                sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
                columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        let (rows, parents) = Self.flatten(roots, children: children)
        self.init(rows: rows, items: columns(), columnCustomization: columnCustomization, selection: selection.map { .many($0) } ?? .none,
                  sortOrder: sortOrder, diff: { Self.diff($0, $1, equal: { $0 == $1 }) })
        self.parents = parents
    }

    /// A table of `Equatable` rows with children, with a selection of one row at most.
    @inlinable
    public init(_ roots: [Row], children: KeyPath<Row, [Row]?>, selection: Binding<Row.ID?>,
                sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
                columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        let (rows, parents) = Self.flatten(roots, children: children)
        self.init(rows: rows, items: columns(), columnCustomization: columnCustomization, selection: .one(selection),
                  sortOrder: sortOrder, diff: { Self.diff($0, $1, equal: { $0 == $1 }) })
        self.parents = parents
    }

    /// A table of `Equatable` rows: an update reads again only the rows
    /// whose values changed.
    @inlinable
    public init(_ rows: [Row], selection: Binding<Set<Row.ID>>? = nil,
                sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
                columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        self.init(rows: rows, items: columns(), columnCustomization: columnCustomization, selection: selection.map { .many($0) } ?? .none, sortOrder: sortOrder,
                  diff: { Self.diff($0, $1, equal: { $0 == $1 }) })
    }

    /// A table of `Equatable` rows with a selection of one row at most.
    @inlinable
    public init(_ rows: [Row], selection: Binding<Row.ID?>, sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
                columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        self.init(rows: rows, items: columns(), columnCustomization: columnCustomization, selection: .one(selection), sortOrder: sortOrder,
                  diff: { Self.diff($0, $1, equal: { $0 == $1 }) })
    }

    /// A table of `Equatable` rows whose editable columns write into them.
    @inlinable
    public init(_ rows: Binding<[Row]>, selection: Binding<Set<Row.ID>>? = nil,
                sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
                columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        self.init(rows: rows.wrappedValue, items: columns(), columnCustomization: columnCustomization, selection: selection.map { .many($0) } ?? .none,
                  sortOrder: sortOrder, diff: { Self.diff($0, $1, equal: { $0 == $1 }) }, rowsBinding: rows)
    }

    /// A table of `Equatable` rows whose editable columns write into them,
    /// with a selection of one row at most.
    @inlinable
    public init(_ rows: Binding<[Row]>, selection: Binding<Row.ID?>, sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
                columnCustomization: Binding<TableColumnCustomization<Row>>? = nil,
                @NGDataColumnBuilder<Row> columns: () -> [NGDataColumnItem<Row>]) {
        self.init(rows: rows.wrappedValue, items: columns(), columnCustomization: columnCustomization, selection: .one(selection), sortOrder: sortOrder,
                  diff: { Self.diff($0, $1, equal: { $0 == $1 }) }, rowsBinding: rows)
    }
}

/// What changed between two arrays of rows (see `NGDataTable.diff`).
/// Frozen so the inlinable initializers can set its properties when NGTable
/// is built with library evolution (the XCFramework).
@usableFromInline @frozen
struct NGRowsDiff {
    /// A kept row in another place: its old and new index.
    @usableFromInline @frozen
    struct Move {
        @usableFromInline let old: Int
        @usableFromInline let new: Int
        @inlinable init(old: Int, new: Int) {
            self.old = old
            self.new = new
        }
    }

    /// The same rows in the same order.
    @usableFromInline let sameOrder: Bool
    /// Kept rows whose values changed (new indexes).
    @usableFromInline let changed: IndexSet
    /// When very many rows moved: each old row's new index (else empty).
    @usableFromInline let oldToNew: [Int?]
    /// Otherwise: rows removed (old indexes), inserted (new indexes) and
    /// moved; the other kept rows stay in their order.
    @usableFromInline let removed: IndexSet
    @usableFromInline let inserted: IndexSet
    @usableFromInline let moves: [Move]

    /// Up to this many moved rows are moved one by one (two table moves
    /// each); beyond, the rows are mapped all at once.
    @usableFromInline static let moveLimit = 256

    @inlinable
    init(sameOrder: Bool, changed: IndexSet, oldToNew: [Int?], removed: IndexSet, inserted: IndexSet, moves: [Move]) {
        self.sameOrder = sameOrder
        self.changed = changed
        self.oldToNew = oldToNew
        self.removed = removed
        self.inserted = inserted
        self.moves = moves
    }

    /// The old indexes of the kept rows that moved: those off a longest run
    /// of kept rows whose new places increase (patience sorting, O(n log n)).
    @usableFromInline
    static func movedRows(_ oldToNew: [Int?]) -> [Int] {
        // Tails of the increasing runs by length, as positions in `oldToNew`,
        // and their new places (read without going through `oldToNew`).
        var tails: [Int] = [], tailPlaces: [Int] = []
        tails.reserveCapacity(oldToNew.count)
        tailPlaces.reserveCapacity(oldToNew.count)
        var previous = [Int](repeating: -1, count: oldToNew.count)
        for (index, to) in oldToNew.enumerated() {
            guard let to else { continue }
            // Rows still in order (nearly all, usually) extend the longest
            // run: no search.
            if let last = tailPlaces.last, last < to {
                previous[index] = tails[tails.count - 1]
                tails.append(index)
                tailPlaces.append(to)
                continue
            }
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if tailPlaces[middle] < to { low = middle + 1 } else { high = middle }
            }
            previous[index] = low > 0 ? tails[low - 1] : -1
            if low == tails.count {
                tails.append(index)
                tailPlaces.append(to)
            } else {
                tails[low] = index
                tailPlaces[low] = to
            }
        }
        var onRun = [Bool](repeating: false, count: oldToNew.count)
        var index = tails.last ?? -1
        while index >= 0 {
            onRun[index] = true
            index = previous[index]
        }
        var moved: [Int] = []
        for (index, to) in oldToNew.enumerated() where to != nil && !onRun[index] { moved.append(index) }
        return moved
    }
}

/// The data source and delegate of an `NGDataTable`'s table.
@MainActor
public final class NGDataTableCoordinator<Row: Identifiable>: NSObject, NGTableViewDataSource, NGTableViewDelegate {
    private(set) var rows: [Row] = []
    private var values: [String: (Row) -> NGCellValue] = [:]
    private var comparators: [String: (SortOrder) -> KeyPathComparator<Row>] = [:]
    private var keyPaths: [String: AnyKeyPath] = [:]
    private var writers: [String: (inout Row, NGCellValue) -> Bool] = [:]
    private var items: [NGColumnItem] = []
    private var view: NGDataTable<Row>?
    private weak var table: NGTableView?
    /// The table's selection or sort is being set from the bindings.
    private var isApplyingState = false
    /// The current filter by rows, and what it was applied for (see `RowPredicate`).
    private var rowPredicate: ((Row) -> Bool)?
    /// The index-based filter of the view applied last, and the number of
    /// rows its indexes mean.
    private var indexFilter: (isIncluded: @MainActor (Int) -> Bool, count: Int)?
    private var appliedPredicate: (searchText: String, columnIDs: Set<String>?, id: AnyHashable)?
    /// The selection as the table and the binding last agreed on (comparing
    /// them on every update read every selected row's identity).
    private var agreedSelection: Set<Row.ID>?
    /// Rows of the agreed selection that weren't there when it was applied.
    private var waitingSelectionIDs: Set<Row.ID> = []
    /// The sort binding's sort when the table restored another from
    /// `autosaveName`, until the binding has the restored one.
    private var staleBindingSort: [NSSortDescriptor]?
    /// The SwiftUI environment of the table, for the menu's content.
    var environment = EnvironmentValues()
    /// The table's selection changed while an update applied the view.
    private var selectionChangedWhileApplying = false
    /// Each child's parent (rows with children), and the rows the
    /// expansion binding opened last.
    private var parents: [Row.ID: Row.ID] = [:]
    private var appliedExpanded: Set<Row.ID>?
    /// The rows show as a tree (the view has children).
    private var showsTree = false
    /// Columns hidden until shown (`defaultVisibility(.hidden)`), and the
    /// customizations applied last (see `applyCustomization`).
    private var defaultHidden: Set<String> = []
    private var appliedFullCustomization: NGColumnCustomization?
    private var appliedCustomization: TableColumnCustomization<Row>?
    /// Rows that are `@Observable` objects: those whose values the table
    /// read and follows (by object, with their ids), the ids of those that
    /// changed since, and whether reading them again is on its way.
    private var observedRows: [ObjectIdentifier: Row.ID] = [:]
    private var changedObservedRows = Set<Row.ID>()
    private var readsObservedRows = false
    /// How many times changed observable rows were read again, and how many rows.
    private(set) var observedBatches = 0
    private(set) var observedRowsReloaded = 0
    /// The last column asked for, and its values (cells are asked column by column).
    private var lastColumnID: String?
    private var lastValue: ((Row) -> NGCellValue)?

    // MARK: Updating

    func update(_ table: NGTableView, from view: NGDataTable<Row>) {
        self.view = view
        self.table = table
        Self.warnIfReferenceRows()
        isApplyingState = true
        defer { isApplyingState = false }
        applyEnvironment(to: table)
        let columnsChanged = updateColumns(of: table, from: view)
        applyCustomization(to: table, from: view, columnsChanged: columnsChanged)
        // Changed rows are filtered by the new condition: the table asks it
        // through `indexFilter` (the old one indexes the rows it captured).
        rowPredicate = view.rowPredicate?.isIncluded
        indexFilter = view.rowFilter?.isIncluded.map { ($0, view.rows.count) }
        // Rows with children: the new parents are read as rows come; rows
        // that kept their values but moved to another parent are read again.
        let newParents = view.parents ?? [:]
        let reparented: Set<Row.ID> = parents == newParents ? []
            : Set(parents.keys).union(newParents.keys).filter { parents[$0] != newParents[$0] }
        parents = newParents
        updateRows(of: table, to: view.rows, diff: view.diff)
        updateTree(of: table, from: view, reparented: reparented)
        // The table sorts the rows itself unless the app does (a binding).
        table.sortsRows = view.sortOrder == nil
        if let sortOrder = view.sortOrder?.wrappedValue {
            let descriptors = sortOrder.compactMap { comparator -> NSSortDescriptor? in
                // The first column of the key path (two columns may show one property).
                guard let id = view.items.flatMap(\.leaves).first(where: { $0.keyPath == comparator.keyPath })?.column.id else { return nil }
                return NSSortDescriptor(key: id, ascending: comparator.order == .forward)
            }
            // A sort restored from `autosaveName` that the binding hasn't
            // heard of yet: the binding's older sort doesn't replace it
            // meanwhile; any other sort from the binding does.
            if descriptors == staleBindingSort {
                // Waiting for the binding.
            } else {
                staleBindingSort = nil
                if descriptors != table.sortDescriptors { table.sortDescriptors = descriptors }
            }
        }
        updateRowFilter(of: table, from: view)
        if table.rowGrouping != view.rowGrouping { table.rowGrouping = view.rowGrouping }
        // A binding of one row: one row at most (the configuration may say otherwise).
        if case .one = view.selection { table.allowsMultipleSelection = false }
        applySelection(to: table, from: view)
        table.rowDeletion = view.deleteAction
        updateDragTypes(of: table, from: view)
        table.target = self
        table.doubleAction = view.primaryAction == nil ? nil : #selector(primaryAction(_:))
        table.returnAction = view.primaryAction == nil ? nil : #selector(primaryAction(_:))
        let sortBefore = table.sortDescriptors
        view.configuration?(table)
        if selectionChangedWhileApplying {
            selectionChangedWhileApplying = false
            let ids = selectedIDs(of: table)
            agreedSelection = ids
            switch view.selection {
            case .none: break
            case .many(let binding):
                let current = binding.wrappedValue
                // The same rows: the binding's set is kept (shared storage
                // compares at once on the next update; another set of
                // 200,000 ids compares element by element).
                if current == ids { agreedSelection = current } else { Task { @MainActor in binding.wrappedValue = ids } }
            case .one(let binding): if binding.wrappedValue != ids.first { Task { @MainActor in binding.wrappedValue = ids.first } }
            }
        }
        // The configuration restored a saved sort (`autosaveName`): the
        // binding hears of it, instead of overwriting it with its own.
        if let binding = view.sortOrder, table.sortDescriptors != sortBefore {
            let restored = table.sortDescriptors.compactMap { descriptor in
                descriptor.key.flatMap { comparators[$0] }?(descriptor.ascending ? .forward : .reverse)
            }
            staleBindingSort = sortBefore
            Task { @MainActor in binding.wrappedValue = restored }
        }
    }

    /// What SwiftUI's environment says that a `Table`'s cells would follow:
    /// the locale values are formatted in, the layout direction, whether
    /// it's enabled.
    private func applyEnvironment(to table: NGTableView) {
        let locale = environment.locale
        if table.locale?.identifier != locale.identifier { table.locale = locale }
        let direction: NSUserInterfaceLayoutDirection = environment.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        if table.userInterfaceLayoutDirection != direction { table.userInterfaceLayoutDirection = direction }
        if table.isEnabled != environment.isEnabled { table.isEnabled = environment.isEnabled }
    }

    /// Shows rows with children as the table's tree, collapsed at first like
    /// a `Table`'s, and opens the rows of the expansion binding.
    private func updateTree(of table: NGTableView, from view: NGDataTable<Row>, reparented: Set<Row.ID>) {
        guard view.parents != nil else {
            // No longer a tree (the configuration may set one of its own).
            if showsTree {
                showsTree = false
                appliedExpanded = nil
                table.rowTree = nil
            }
            return
        }
        if !showsTree || table.rowTree == nil {
            showsTree = true
            table.rowTree = NGRowTree(startsCollapsed: true)
        }
        let rows = IndexSet(reparented.map { table.row(forIdentifier: AnyHashable($0)) }.filter { $0 >= 0 })
        if !rows.isEmpty { table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
        guard let binding = view.expandedRows else { return }
        let wanted = binding.wrappedValue
        guard wanted != appliedExpanded || !rows.isEmpty else { return }
        let before = appliedExpanded ?? []
        appliedExpanded = wanted
        for id in wanted.union(before) {
            let row = table.row(forIdentifier: AnyHashable(id))
            guard row >= 0 else { continue }
            if wanted.contains(id) { table.expandRow(row) } else { table.collapseRow(row) }
        }
    }

    /// The user opened or closed a row: the expansion binding hears of it.
    private func noteExpansion(_ notification: Notification, expanded: Bool) {
        guard !isApplyingState, let binding = view?.expandedRows,
              let id = notification.userInfo?["NGRowIdentifier"] as? Row.ID else { return }
        var rows = binding.wrappedValue
        if expanded { rows.insert(id) } else { rows.remove(id) }
        appliedExpanded = rows
        if rows != binding.wrappedValue { binding.wrappedValue = rows }
    }

    public func tableViewRowDidExpand(_ notification: Notification) { noteExpansion(notification, expanded: true) }
    public func tableViewRowDidCollapse(_ notification: Notification) { noteExpansion(notification, expanded: false) }

    public func tableView(_ tableView: NGTableView, parentIdentifierForRow row: Int) -> AnyHashable? {
        guard row >= 0, row < rows.count, let parent = parents[rows[row].id] else { return nil }
        return AnyHashable(parent)
    }

    /// The pasteboard type of rows dragged within the table to move them.
    static var rowMoveType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType("dev.ngtable.datatable-row") }

    /// The table takes moved rows and the drop's types.
    private func updateDragTypes(of table: NGTableView, from view: NGDataTable<Row>) {
        var types: [NSPasteboard.PasteboardType] = view.moveAction == nil ? [] : [Self.rowMoveType]
        types += (view.rowDrop?.types ?? []).map { NSPasteboard.PasteboardType($0.identifier) }
        guard Set(types) != Set(table.registeredDraggedTypes) else { return }
        table.unregisterDraggedTypes()
        if !types.isEmpty { table.registerForDraggedTypes(types) }
    }

    /// A drag of this table's rows to move them.
    private func isRowMove(_ info: any NSDraggingInfo, in tableView: NGTableView) -> Bool {
        (info.draggingSource as? NGTableView) === tableView && info.draggingPasteboard.types?.contains(Self.rowMoveType) == true
    }

    /// The dropped items in the drop's types, as item providers (read now:
    /// the pasteboard is only readable during the drop).
    private func droppedProviders(_ info: any NSDraggingInfo, types: [UTType]) -> [NSItemProvider] {
        (info.draggingPasteboard.pasteboardItems ?? []).compactMap { item in
            for type in item.types {
                guard let contentType = UTType(type.rawValue), types.contains(where: { contentType.conforms(to: $0) }),
                      let data = item.data(forType: type) else { continue }
                let provider = NSItemProvider()
                provider.registerDataRepresentation(for: contentType, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
                return provider
            }
            return nil
        }
    }

    /// Whether no two old rows go to the same new place.
    private static func placesAreDistinct(_ oldToNew: [Int?], count: Int) -> Bool {
        var taken = [Bool](repeating: false, count: count)
        for case let new? in oldToNew {
            guard new >= 0, new < count, !taken[new] else { return false }
            taken[new] = true
        }
        return true
    }

    /// Whether rows are `@Observable` objects (their changes are followed).
    private static var rowsAreObservable: Bool { Row.self is any Observable.Type && Row.self is AnyObject.Type }

    /// Starts following an observable row's values (all the columns'), the
    /// first time the table reads them: a change marks it, and the changed
    /// rows are read again together, then followed again.
    private func observe(_ row: Row) {
        guard Self.rowsAreObservable else { return }
        let key = ObjectIdentifier(row as AnyObject)
        guard observedRows[key] == nil else { return }
        observedRows[key] = row.id
        let readers = Array(values.values)
        withObservationTracking {
            for read in readers { _ = read(row) }
        } onChange: { [weak self] in
            // Before the change is made, on the thread that makes it.
            Task { @MainActor in self?.observedRowChanged(key) }
        }
    }

    private func observedRowChanged(_ key: ObjectIdentifier) {
        guard let id = observedRows.removeValue(forKey: key) else { return }
        changedObservedRows.insert(id)
        guard !readsObservedRows else { return }
        readsObservedRows = true
        // After the other changes made at the same time.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.readChangedObservedRows() }
        }
    }

    private func readChangedObservedRows() {
        readsObservedRows = false
        let ids = changedObservedRows
        changedObservedRows = []
        guard let table, !ids.isEmpty else { return }
        let changed = IndexSet(ids.map { table.row(forIdentifier: AnyHashable($0)) }.filter { $0 >= 0 })
        guard !changed.isEmpty else { return }
        observedBatches += 1
        observedRowsReloaded += changed.count
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    /// Rows that are objects change without a new array, so the table can't
    /// see what changed unless they're `@Observable`: told once.
    private static func warnIfReferenceRows() {
        guard Row.self is AnyObject.Type, !rowsAreObservable, !NGDataTableWarnings.warnedAboutReferenceRows else { return }
        NGDataTableWarnings.warnedAboutReferenceRows = true
        NGDataTableWarnings.log.warning("""
            NGDataTable rows of \(String(describing: Row.self), privacy: .public) are objects that aren't @Observable: \
            changes inside them don't reach the summaries, sort or search. Use structs, or make them @Observable.
            """)
    }

    /// Filters compare by their search; a condition closure can't be compared:
    /// one by rows applies again when its `id` changes, one by indexes on
    /// every update (its indexes are of the rows it captured).
    private func updateRowFilter(of table: NGTableView, from view: NGDataTable<Row>) {
        if let predicate = view.rowPredicate {
            let key = (searchText: predicate.searchText, columnIDs: predicate.columnIDs, id: predicate.id)
            if let applied = appliedPredicate, applied.searchText == key.searchText, applied.columnIDs == key.columnIDs,
               applied.id == key.id, table.rowFilter != nil {
                return
            }
            appliedPredicate = key
            table.rowFilter = NGRowFilter(searchText: key.searchText, columnIDs: key.columnIDs) { [weak self] row in
                guard let self, row >= 0, row < rows.count, let isIncluded = rowPredicate else { return true }
                return isIncluded(rows[row])
            }
            return
        }
        appliedPredicate = nil
        let old = table.rowFilter, new = view.rowFilter
        if let new, new.isIncluded != nil {
            // Every row again (the condition may have changed), through the
            // view's current closure, never past the rows it captured.
            table.rowFilter = NGRowFilter(searchText: new.searchText, columnIDs: new.columnIDs) { [weak self] row in
                guard let self, let (isIncluded, count) = indexFilter, row >= 0, row < count else { return true }
                return isIncluded(row)
            }
        } else if old?.searchText != new?.searchText || old?.columnIDs != new?.columnIDs || old?.isIncluded != nil {
            table.rowFilter = new
        }
    }

    /// Returns whether the columns changed.
    @discardableResult
    private func updateColumns(of table: NGTableView, from view: NGDataTable<Row>) -> Bool {
        let leaves = view.items.flatMap(\.leaves)
        defaultHidden = Set(leaves.filter(\.isHiddenByDefault).map(\.column.id))
        values = Dictionary(leaves.map { ($0.column.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        comparators = Dictionary(leaves.compactMap { column in column.comparator.map { (column.column.id, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        keyPaths = Dictionary(leaves.compactMap { column in column.keyPath.map { (column.column.id, $0) } },
                              uniquingKeysWith: { first, _ in first })
        writers = Dictionary(leaves.compactMap { column in column.write.map { (column.column.id, $0) } },
                             uniquingKeysWith: { first, _ in first })
        lastColumnID = nil
        // With a sort order binding, only columns with comparators sort;
        // without a binding of rows, nothing edits (there's nowhere to write).
        var newItems = view.items.map(\.item)
        // A column without a way to write the row back doesn't edit (it
        // would register an Undo of nothing).
        let writable = Set(writers.keys)
        newItems = newItems.map { item in
            switch item {
            case .column(var column):
                if !writable.contains(column.id) { column.isEditable = false }
                return .column(column)
            case .group(var group):
                group.columns = group.columns.map { var column = $0; if !writable.contains(column.id) { column.isEditable = false }; return column }
                return .group(group)
            }
        }
        if view.rowsBinding == nil {
            newItems = newItems.map { item in
                switch item {
                case .column(var column):
                    column.isEditable = false
                    return .column(column)
                case .group(var group):
                    group.columns = group.columns.map { var column = $0; column.isEditable = false; return column }
                    return .group(group)
                }
            }
        }
        if view.sortOrder != nil {
            newItems = newItems.map { item in
                switch item {
                case .column(var column):
                    if comparators[column.id] == nil { column.isSortable = false }
                    return .column(column)
                case .group(var group):
                    group.columns = group.columns.map { column in
                        var column = column
                        if comparators[column.id] == nil { column.isSortable = false }
                        return column
                    }
                    return .group(group)
                }
            }
        }
        guard newItems != items else { return false }
        // The user's order, widths, pins and hidden columns stay through a
        // new definition (a title changed); the first one is as given, with
        // the columns hidden by default.
        let isFirst = items.isEmpty
        let layout = table.columnLayoutState
        items = newItems
        table.columns = newItems
        if isFirst {
            if !defaultHidden.isEmpty { table.hiddenColumnIDs = defaultHidden }
        } else {
            table.columnLayoutState = layout
        }
        return true
    }

    /// The column customizations the app keeps: applied when they or the
    /// columns change (the user's changes are written into them, see
    /// `captureCustomization`). Visibility the SwiftUI one sets goes over the
    /// table's own customization.
    private func applyCustomization(to table: NGTableView, from view: NGDataTable<Row>, columnsChanged: Bool) {
        let full = view.fullColumnCustomization?.wrappedValue
        let visibility = view.columnCustomization?.wrappedValue
        guard full != nil || visibility != nil else { return }
        guard columnsChanged || full != appliedFullCustomization || visibility != appliedCustomization else { return }
        appliedFullCustomization = full
        appliedCustomization = visibility
        var hidden = full?.hiddenIDs(defaultHidden: defaultHidden) ?? defaultHidden
        if let visibility {
            for id in table.tableColumns.map(\.id) {
                switch visibility[visibility: id] {
                case .hidden: hidden.insert(id)
                case .visible: hidden.remove(id)
                default: break
                }
            }
        }
        if let full {
            var state = full.layoutState(defaultHidden: defaultHidden)
            state.hiddenIDs = hidden
            if state != table.columnLayoutState.withoutSortFiltersAndGrouping { table.columnLayoutState = state }
        } else if table.hiddenColumnIDs != hidden {
            table.hiddenColumnIDs = hidden
        }
    }

    /// The user changed the columns: the customizations hear of it.
    private func captureCustomization(from table: NGTableView) {
        guard !isApplyingState, let view else { return }
        let state = table.columnLayoutState
        if let binding = view.fullColumnCustomization {
            let customization = NGColumnCustomization(state, defaultHidden: defaultHidden, keeping: binding.wrappedValue)
            appliedFullCustomization = customization
            if binding.wrappedValue != customization { binding.wrappedValue = customization }
        }
        if let binding = view.columnCustomization {
            var customization = binding.wrappedValue
            for id in table.tableColumns.map(\.id) {
                let isHidden = state.hiddenIDs.contains(id)
                let wanted = customization[visibility: id]
                let shownAs = wanted == .automatic ? defaultHidden.contains(id) : wanted == .hidden
                if shownAs != isHidden { customization[visibility: id] = isHidden ? .hidden : .visible }
            }
            appliedCustomization = customization
            if binding.wrappedValue != customization { binding.wrappedValue = customization }
        }
    }

    /// Tells the table what changed by identity: the first time a reload,
    /// then inserts, removes and moves, and the rows whose values changed
    /// (all kept rows unless rows are `Equatable`).
    private func updateRows(of table: NGTableView, to newRows: [Row], diff: ([Row], [Row]) -> NGRowsDiff) {
        let first = table.dataSource !== self
        let oldRows = rows
        // The same array (SwiftUI updated something else): nothing changed.
        if !first, Self.sharesStorage(oldRows, newRows) { return }
        rows = newRows
        // Objects no longer among the rows aren't followed.
        if Self.rowsAreObservable, !observedRows.isEmpty {
            let current = Set(newRows.lazy.map { ObjectIdentifier($0 as AnyObject) })
            observedRows = observedRows.filter { current.contains($0.key) }
        }
        if first {
            table.delegate = self
            table.dataSource = self
            return
        }
        let changes = diff(oldRows, newRows)
        guard !changes.sameOrder || !changes.changed.isEmpty else { return }
        // Rows sharing an identity can make the changes not add up: read
        // everything again instead (the table would assert).
        guard !changes.oldToNew.isEmpty || oldRows.count - changes.removed.count + changes.inserted.count == newRows.count else {
            table.reloadData()
            return
        }
        // (By places, two old rows sharing an identity get the same new place.)
        if !changes.oldToNew.isEmpty, !Self.placesAreDistinct(changes.oldToNew, count: newRows.count) {
            table.reloadData()
            return
        }
        table.beginUpdates()
        if !changes.oldToNew.isEmpty {
            table.remapRows(changes.oldToNew, newCount: newRows.count)
        } else {
            // Like an AppKit feed: removes by old indexes, moves, then inserts by new ones.
            if !changes.removed.isEmpty { table.removeRows(at: changes.removed) }
            if !changes.moves.isEmpty {
                Self.applyMoves(changes.moves, removed: changes.removed, inserted: changes.inserted,
                                keptCount: oldRows.count - changes.removed.count, to: table)
            }
            if !changes.inserted.isEmpty { table.insertRows(at: changes.inserted) }
        }
        if !changes.changed.isEmpty {
            table.reloadData(forRowIndexes: changes.changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        table.endUpdates()
    }

    /// Moves the kept rows that moved into place (the others are in order),
    /// after the removes and before the inserts: each to the end, then from
    /// there to its place among the kept rows, in the order of their places,
    /// so every place before it is already right.
    static func applyMoves(_ moves: [NGRowsDiff.Move], removed: IndexSet, inserted: IndexSet, keptCount: Int,
                           to table: NGTableView) {
        let byOld = moves.sorted { $0.old < $1.old }
        for (count, move) in byOld.enumerated() {
            let position = move.old - removed.count(in: 0..<move.old) - count
            table.moveRow(at: position, to: keptCount - 1)
        }
        var tail = byOld.map(\.new)
        for move in moves.sorted(by: { $0.new < $1.new }) {
            guard let index = tail.firstIndex(of: move.new) else { continue }
            let place = move.new - inserted.count(in: 0..<move.new)
            table.moveRow(at: keptCount - tail.count + index, to: place)
            tail.remove(at: index)
        }
    }

    /// Whether two arrays are the same storage (unchanged since the last update).
    private static func sharesStorage(_ lhs: [Row], _ rhs: [Row]) -> Bool {
        lhs.count == rhs.count && lhs.withUnsafeBufferPointer { a in rhs.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress } }
    }

    private func applySelection(to table: NGTableView, from view: NGDataTable<Row>) {
        let wanted: Set<Row.ID>
        switch view.selection {
        case .none: return
        case .many(let binding): wanted = binding.wrappedValue
        case .one(let binding): wanted = binding.wrappedValue.map { [$0] } ?? []
        }
        // The same selection as last time: only rows it waits for may have come.
        if wanted == agreedSelection {
            guard !waitingSelectionIDs.isEmpty,
                  waitingSelectionIDs.contains(where: { table.row(forIdentifier: AnyHashable($0)) >= 0 }) else { return }
        }
        agreedSelection = wanted
        // The table's index of identities (kept through inserts and removes).
        var found = IndexSet()
        var waiting: Set<Row.ID> = []
        for id in wanted {
            let row = table.row(forIdentifier: AnyHashable(id))
            if row >= 0 { found.insert(row) } else { waiting.insert(id) }
        }
        // Rows not there yet (still loading) are selected when they come.
        waitingSelectionIDs = waiting
        guard found != table.selectedRowIndexes else { return }
        table.selectRowIndexes(found, byExtendingSelection: false)
    }

    private func selectedIDs(of table: NGTableView) -> Set<Row.ID> {
        Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
    }

    // MARK: NGTableViewDataSource

    public func numberOfRows(in tableView: NGTableView) -> Int { rows.count }

    public func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        guard row >= 0, row < rows.count, let value = value(of: column.id) else { return .empty }
        observe(rows[row])
        return value(rows[row])
    }

    public func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? {
        row >= 0 && row < rows.count ? AnyHashable(rows[row].id) : nil
    }

    public func tableView(_ tableView: NGTableView, numbersFor column: NGTableColumn, rows range: Range<Int>,
                          into numbers: UnsafeMutableBufferPointer<Double>) -> Bool {
        guard let value = value(of: column.id), range.upperBound <= rows.count else { return false }
        for (offset, row) in range.enumerated() {
            observe(rows[row])
            numbers[offset] = value(rows[row]).numericValue ?? .nan
        }
        return true
    }

    /// An edit (or its Undo): written into the row of the binding.
    public func tableView(_ tableView: NGTableView, setValue value: NGCellValue, for column: NGTableColumn, row: Int) {
        guard let binding = view?.rowsBinding, let write = writers[column.id], row >= 0, row < rows.count else { return }
        var all = binding.wrappedValue
        let id = rows[row].id
        // The binding's array is the table's (the last update); by identity in case it isn't.
        guard let index = row < all.count && all[row].id == id ? row : all.firstIndex(where: { $0.id == id }) else { return }
        var edited = all[index]
        guard write(&edited, value) else { return }
        all[index] = edited
        rows[row] = edited
        binding.wrappedValue = all
        if let undo = tableView.undoManager, undo.isUndoing || undo.isRedoing { return }
        view?.submitAction?()
    }

    public func tableView(_ tableView: NGTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingState, let binding = view?.sortOrder else { return }
        // Header clicks: the comparators of the sorted columns, for the app to
        // sort by; a column the app already sorts by keeps its comparator
        // (lexical, say), in the new direction.
        let current = binding.wrappedValue
        binding.wrappedValue = tableView.sortDescriptors.compactMap { descriptor in
            guard let id = descriptor.key else { return nil }
            let order: SortOrder = descriptor.ascending ? .forward : .reverse
            if let keyPath = keyPaths[id], var kept = current.first(where: { $0.keyPath == keyPath }) {
                kept.order = order
                return kept
            }
            return comparators[id]?(order)
        }
    }

    // MARK: Moving and dropping rows

    public func tableView(_ tableView: NGTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard view?.moveAction != nil else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowMoveType)
        return item
    }

    public func tableView(_ tableView: NGTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                          proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let view else { return [] }
        let operation: NSDragOperation
        if isRowMove(info, in: tableView) {
            guard view.moveAction != nil else { return [] }
            operation = .move
        } else if let drop = view.rowDrop, !droppedProviders(info, types: drop.types).isEmpty {
            operation = .copy
        } else {
            return []
        }
        // Between rows, like a ForEach's offsets.
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return operation
    }

    public func tableView(_ tableView: NGTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                          dropOperation: NSTableView.DropOperation) -> Bool {
        guard let view else { return false }
        if isRowMove(info, in: tableView) {
            let rows = tableView.draggedRowIndexes
            guard let move = view.moveAction, !rows.isEmpty else { return false }
            move(rows, row)
            return true
        }
        guard let drop = view.rowDrop else { return false }
        let providers = droppedProviders(info, types: drop.types)
        guard !providers.isEmpty else { return false }
        drop.accept(providers, row)
        return true
    }

    private func value(of columnID: String) -> ((Row) -> NGCellValue)? {
        if columnID == lastColumnID { return lastValue }
        lastColumnID = columnID
        lastValue = values[columnID]
        return lastValue
    }

    // MARK: NGTableViewDelegate

    public func tableView(_ tableView: NGTableView, didChangeHiddenColumns hiddenColumnIDs: Set<String>) {
        captureCustomization(from: tableView)
    }

    public func tableView(_ tableView: NGTableView, didReorderColumns columns: [NGColumnItem]) {
        captureCustomization(from: tableView)
    }

    public func tableView(_ tableView: NGTableView, didResizeColumn column: NGTableColumn, width: Double) {
        captureCustomization(from: tableView)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        // During an update (rows that went left the selection): the binding
        // hears of it once the update is done.
        if isApplyingState {
            selectionChangedWhileApplying = true
            return
        }
        guard let view, let table else { return }
        let ids = selectedIDs(of: table)
        agreedSelection = ids
        switch view.selection {
        case .none: break
        case .many(let binding):
            let current = binding.wrappedValue
            if current == ids { agreedSelection = current } else { binding.wrappedValue = ids }
        case .one(let binding): if binding.wrappedValue != ids.first { binding.wrappedValue = ids.first }
        }
    }

    public func tableView(_ tableView: NGTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: NGTableColumn?) -> NSMenu? {
        guard let menu = view?.menu else { return nil }
        let ids = Set(rows.compactMap { $0 < self.rows.count ? self.rows[$0].id : nil })
        guard #available(macOS 14.4, *) else { return nil }
        // With the table's environment (its `@Environment` values, e.g. a model).
        return NSHostingMenu(rootView: menu(ids).environment(\.self, environment))
    }

    @objc private func primaryAction(_ sender: Any?) {
        guard let table, let action = view?.primaryAction else { return }
        // A double click below the rows is for no row (like a SwiftUI `Table`).
        let clicked = table.clickedRow
        guard clicked >= 0 || table.isSendingReturnAction else { return }
        // The clicked row, with the selection when it is one of them.
        let rows = clicked >= 0 && !table.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : table.selectedRowIndexes
        let ids = Set(rows.compactMap { $0 < self.rows.count ? self.rows[$0].id : nil })
        if !ids.isEmpty { action(ids) }
    }
}
/// Warnings told once per run.
@MainActor
enum NGDataTableWarnings {
    static var warnedAboutReferenceRows = false
    static let log = Logger(subsystem: "NGTable", category: "SwiftUI")
}
#endif
