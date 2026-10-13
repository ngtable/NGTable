#if os(macOS)
import AppKit

/// The rows of a table at one moment, by identity: sections of item
/// identifiers, like `NSDiffableDataSourceSnapshot`, with the same methods.
/// Give it to `NGTableViewDiffableDataSource.apply(_:animatingDifferences:completion:)`.
///
/// Unlike AppKit's snapshot, it remembers which items `reloadItems(_:)` and
/// `reconfigureItems(_:)` marked, so only their cells and their share of the
/// summaries are read again. Item identifiers must be unique in a snapshot.
public struct NGDiffableDataSourceSnapshot<SectionIdentifierType: Hashable, ItemIdentifierType: Hashable> {
    fileprivate struct Section {
        var identifier: SectionIdentifierType
        var items: [ItemIdentifierType]
    }

    private var sections: [Section] = []
    /// The section of each item, to find it and keep items unique.
    private var sectionOfItem: [ItemIdentifierType: SectionIdentifierType] = [:]
    /// Items whose values changed (reloaded or reconfigured).
    private var reloadedItems: Set<ItemIdentifierType> = []
    private var reconfiguredItems: Set<ItemIdentifierType> = []
    private var reloadedSections: Set<SectionIdentifierType> = []

    public init() {}

    /// A snapshot with the sections and items of an AppKit snapshot, for
    /// code that builds those today. Reloads it marked aren't readable, so
    /// they don't carry over: mark them again on the result.
    public init(_ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>) {
        appendSections(snapshot.sectionIdentifiers)
        for section in snapshot.sectionIdentifiers {
            appendItems(snapshot.itemIdentifiers(inSection: section), toSection: section)
        }
    }

    // MARK: Reading

    public var numberOfItems: Int { sectionOfItem.count }
    public var numberOfSections: Int { sections.count }
    public var sectionIdentifiers: [SectionIdentifierType] { sections.map(\.identifier) }
    /// All items in order, section after section: the table's rows.
    public var itemIdentifiers: [ItemIdentifierType] { sections.flatMap(\.items) }

    public var reloadedItemIdentifiers: [ItemIdentifierType] { itemIdentifiers.filter(reloadedItems.contains) }
    public var reconfiguredItemIdentifiers: [ItemIdentifierType] { itemIdentifiers.filter(reconfiguredItems.contains) }
    public var reloadedSectionIdentifiers: [SectionIdentifierType] { sectionIdentifiers.filter(reloadedSections.contains) }

    public func numberOfItems(inSection identifier: SectionIdentifierType) -> Int {
        sectionIndex(identifier).map { sections[$0].items.count } ?? 0
    }

    public func itemIdentifiers(inSection identifier: SectionIdentifierType) -> [ItemIdentifierType] {
        sectionIndex(identifier).map { sections[$0].items } ?? []
    }

    public func sectionIdentifier(containingItem identifier: ItemIdentifierType) -> SectionIdentifierType? {
        sectionOfItem[identifier]
    }

    /// The item's index among all items (its row), or `nil`.
    public func indexOfItem(_ identifier: ItemIdentifierType) -> Int? {
        guard let section = sectionOfItem[identifier] else { return nil }
        var offset = 0
        for candidate in sections {
            if candidate.identifier == section {
                return candidate.items.firstIndex(of: identifier).map { offset + $0 }
            }
            offset += candidate.items.count
        }
        return nil
    }

    public func indexOfSection(_ identifier: SectionIdentifierType) -> Int? { sectionIndex(identifier) }

    // MARK: Items

    /// Appends items to a section, the last one by default.
    public mutating func appendItems(_ identifiers: [ItemIdentifierType], toSection sectionIdentifier: SectionIdentifierType? = nil) {
        guard let index = sectionIdentifier.map(sectionIndex) ?? (sections.isEmpty ? nil : sections.count - 1) else {
            assertionFailure("NGDiffableDataSourceSnapshot: no section to append items to")
            return
        }
        sections[index].items.append(contentsOf: adding(identifiers, to: sections[index].identifier))
    }

    public mutating func insertItems(_ identifiers: [ItemIdentifierType], beforeItem beforeIdentifier: ItemIdentifierType) {
        insert(identifiers, at: beforeIdentifier, after: false)
    }

    public mutating func insertItems(_ identifiers: [ItemIdentifierType], afterItem afterIdentifier: ItemIdentifierType) {
        insert(identifiers, at: afterIdentifier, after: true)
    }

    public mutating func deleteItems(_ identifiers: [ItemIdentifierType]) {
        let deleted = Set(identifiers)
        for index in sections.indices where sections[index].items.contains(where: deleted.contains) {
            sections[index].items.removeAll(where: deleted.contains)
        }
        for identifier in deleted {
            sectionOfItem[identifier] = nil
            reloadedItems.remove(identifier)
            reconfiguredItems.remove(identifier)
        }
    }

    /// Removes every item; the sections stay.
    public mutating func deleteAllItems() {
        for index in sections.indices { sections[index].items = [] }
        sectionOfItem = [:]
        reloadedItems = []
        reconfiguredItems = []
    }

    public mutating func moveItem(_ identifier: ItemIdentifierType, beforeItem toIdentifier: ItemIdentifierType) {
        move(identifier, to: toIdentifier, after: false)
    }

    public mutating func moveItem(_ identifier: ItemIdentifierType, afterItem toIdentifier: ItemIdentifierType) {
        move(identifier, to: toIdentifier, after: true)
    }

    /// Marks items whose values changed: their cells, search words and share
    /// of the summaries are read again.
    public mutating func reloadItems(_ identifiers: [ItemIdentifierType]) {
        reloadedItems.formUnion(identifiers.filter { sectionOfItem[$0] != nil })
    }

    /// The same as `reloadItems(_:)`: cells are values, so there is no
    /// view to keep.
    public mutating func reconfigureItems(_ identifiers: [ItemIdentifierType]) {
        reconfiguredItems.formUnion(identifiers.filter { sectionOfItem[$0] != nil })
    }

    // MARK: Sections

    public mutating func appendSections(_ identifiers: [SectionIdentifierType]) {
        sections.append(contentsOf: newSections(identifiers))
    }

    public mutating func insertSections(_ identifiers: [SectionIdentifierType], beforeSection toIdentifier: SectionIdentifierType) {
        guard let index = sectionIndex(toIdentifier) else { return missingSection(toIdentifier) }
        sections.insert(contentsOf: newSections(identifiers), at: index)
    }

    public mutating func insertSections(_ identifiers: [SectionIdentifierType], afterSection toIdentifier: SectionIdentifierType) {
        guard let index = sectionIndex(toIdentifier) else { return missingSection(toIdentifier) }
        sections.insert(contentsOf: newSections(identifiers), at: index + 1)
    }

    /// Removes sections with their items.
    public mutating func deleteSections(_ identifiers: [SectionIdentifierType]) {
        let deleted = Set(identifiers)
        deleteItems(sections.filter { deleted.contains($0.identifier) }.flatMap(\.items))
        sections.removeAll { deleted.contains($0.identifier) }
        reloadedSections.subtract(deleted)
    }

    public mutating func moveSection(_ identifier: SectionIdentifierType, beforeSection toIdentifier: SectionIdentifierType) {
        moveSection(identifier, to: toIdentifier, after: false)
    }

    public mutating func moveSection(_ identifier: SectionIdentifierType, afterSection toIdentifier: SectionIdentifierType) {
        moveSection(identifier, to: toIdentifier, after: true)
    }

    /// Marks every item of the sections as reloaded.
    public mutating func reloadSections(_ identifiers: [SectionIdentifierType]) {
        reloadedSections.formUnion(identifiers.filter { sectionIndex($0) != nil })
    }

    // MARK: For the data source

    /// The items whose values must be read again.
    var changedItems: Set<ItemIdentifierType> {
        var changed = reloadedItems.union(reconfiguredItems)
        for section in sections where reloadedSections.contains(section.identifier) {
            changed.formUnion(section.items)
        }
        return changed
    }

    /// The snapshot without its marks, as the data source keeps it.
    var withoutReloads: Self {
        var copy = self
        copy.reloadedItems = []
        copy.reconfiguredItems = []
        copy.reloadedSections = []
        return copy
    }

    // MARK: Helpers

    private func sectionIndex(_ identifier: SectionIdentifierType) -> Int? {
        sections.firstIndex { $0.identifier == identifier }
    }

    /// The identifiers not in the snapshot yet, now recorded in `section`.
    private mutating func adding(_ identifiers: [ItemIdentifierType], to section: SectionIdentifierType) -> [ItemIdentifierType] {
        var added: [ItemIdentifierType] = []
        added.reserveCapacity(identifiers.count)
        for identifier in identifiers {
            guard sectionOfItem[identifier] == nil else {
                assertionFailure("NGDiffableDataSourceSnapshot: the item \(identifier) is already in the snapshot")
                continue
            }
            sectionOfItem[identifier] = section
            added.append(identifier)
        }
        return added
    }

    private mutating func insert(_ identifiers: [ItemIdentifierType], at target: ItemIdentifierType, after: Bool) {
        guard let section = sectionOfItem[target], let index = sectionIndex(section),
              let position = sections[index].items.firstIndex(of: target) else {
            return assertionFailure("NGDiffableDataSourceSnapshot: the item \(target) is not in the snapshot")
        }
        sections[index].items.insert(contentsOf: adding(identifiers, to: section), at: after ? position + 1 : position)
    }

    private mutating func move(_ identifier: ItemIdentifierType, to target: ItemIdentifierType, after: Bool) {
        guard identifier != target, let source = sectionOfItem[identifier], let sourceIndex = sectionIndex(source),
              sectionOfItem[target] != nil else {
            if identifier != target { assertionFailure("NGDiffableDataSourceSnapshot: moving an item that is not in the snapshot") }
            return
        }
        sections[sourceIndex].items.removeAll { $0 == identifier }
        sectionOfItem[identifier] = nil
        let marks = (reloadedItems.contains(identifier), reconfiguredItems.contains(identifier))
        insert([identifier], at: target, after: after)
        if marks.0 { reloadedItems.insert(identifier) }
        if marks.1 { reconfiguredItems.insert(identifier) }
    }

    private func newSections(_ identifiers: [SectionIdentifierType]) -> [Section] {
        var seen = Set(sectionIdentifiers)
        return identifiers.compactMap { identifier in
            guard seen.insert(identifier).inserted else {
                assertionFailure("NGDiffableDataSourceSnapshot: the section \(identifier) is already in the snapshot")
                return nil
            }
            return Section(identifier: identifier, items: [])
        }
    }

    private mutating func moveSection(_ identifier: SectionIdentifierType, to target: SectionIdentifierType, after: Bool) {
        guard identifier != target, let from = sectionIndex(identifier), sectionIndex(target) != nil else { return }
        let section = sections.remove(at: from)
        guard let index = sectionIndex(target) else { return }
        sections.insert(section, at: after ? index + 1 : index)
    }

    private func missingSection(_ identifier: SectionIdentifierType) {
        assertionFailure("NGDiffableDataSourceSnapshot: the section \(identifier) is not in the snapshot")
    }
}

extension NGDiffableDataSourceSnapshot: Sendable where SectionIdentifierType: Sendable, ItemIdentifierType: Sendable {}
extension NGDiffableDataSourceSnapshot.Section: Sendable where SectionIdentifierType: Sendable, ItemIdentifierType: Sendable {}

/// A data source that takes the rows as snapshots of identifiers and tells
/// the table what changed, like `NSTableViewDiffableDataSource`: build a
/// snapshot of the item identifiers (e.g. record ids), apply it, and the
/// table inserts, removes and moves rows to match, keeping the selection on
/// its records and updating summaries by the changed rows only.
///
/// Where AppKit's asks for a cell view per item, this one asks for a value
/// (`valueProvider`), which the table draws itself:
///
/// ```swift
/// dataSource = NGTableViewDiffableDataSource<Int, Campaign.ID>(tableView: table) { _, column, _, id in
///     campaigns[id]?.value(for: column.id) ?? .empty
/// }
/// var snapshot = NGDiffableDataSourceSnapshot<Int, Campaign.ID>()
/// snapshot.appendSections([0])
/// snapshot.appendItems(campaigns.ids)
/// dataSource.apply(snapshot)
/// ```
///
/// It makes itself the table's data source; keep it (the table holds its
/// data source weakly). Sections are one list of rows, unless
/// `sectionTitleProvider` shows them as groups with header rows.
@MainActor
public final class NGTableViewDiffableDataSource<SectionIdentifierType: Hashable, ItemIdentifierType: Hashable>: NSObject, NGTableViewDataSource {
    public typealias Snapshot = NGDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>
    /// The value of a cell: the table, the column, the row and its item.
    public typealias ValueProvider = (NGTableView, NGTableColumn, Int, ItemIdentifierType) -> NGCellValue

    private weak var tableView: NGTableView?
    private let valueProvider: ValueProvider
    private var currentSnapshot = Snapshot()
    /// The rows: the snapshot's items in order, and the row of each.
    private var items: [ItemIdentifierType] = []
    private var rowOfItem: [ItemIdentifierType: Int] = [:]

    /// The animation for inserted and removed rows, like AppKit's: rows
    /// applied with `animatingDifferences` slide and fade (one animation for
    /// every option); `[]` changes them at once.
    public var defaultRowAnimation: NSTableView.AnimationOptions = .effectFade

    /// Called when the table's `sortDescriptors` changed (see
    /// `NGTableViewDataSource.tableView(_:sortDescriptorsDidChange:)`): sort
    /// the items and apply a snapshot in the new order.
    public var sortDescriptorsDidChange: ((NGTableView, [NSSortDescriptor]) -> Void)?

    /// Shows the sections as groups of the table (see `NGRowGrouping`), with
    /// a header row titled by this (collapsible, with subtotals), like
    /// AppKit's section header views. Titles should be unique: sections that
    /// share one are one group. `nil` (the default) lists the rows of all
    /// sections as one list.
    public var sectionTitleProvider: ((SectionIdentifierType) -> String)? {
        didSet {
            guard let tableView, tableView.dataSource === self else { return }
            tableView.rowGrouping = sectionTitleProvider == nil ? nil : NGRowGrouping(columnID: Self.sectionColumnID)
            tableView.reloadData()
        }
    }

    /// The column the table groups by to show the sections (`sectionTitleProvider`).
    public static var sectionColumnID: String { "NGTable.section" }

    public init(tableView: NGTableView, valueProvider: @escaping ValueProvider) {
        self.tableView = tableView
        self.valueProvider = valueProvider
        super.init()
        tableView.dataSource = self
    }

    /// The rows as last applied, without reload marks.
    public func snapshot() -> Snapshot { currentSnapshot }

    /// Makes the table show the snapshot's items. Items in both the old and
    /// the new snapshot keep their cells, selection and summarized values
    /// (unless marked reloaded); new ones are read, missing ones removed.
    /// The table is updated before `completion` is called and the method
    /// returns. With `animatingDifferences`, rows in view slide to their new
    /// places, new ones fade in and removed ones fade out.
    public func apply(_ snapshot: Snapshot, animatingDifferences: Bool = true, completion: (() -> Void)? = nil) {
        let newItems = snapshot.itemIdentifiers
        let changed = snapshot.changedItems
        guard let tableView, tableView.dataSource === self, !items.isEmpty else {
            return applySnapshotUsingReloadData(snapshot, completion: completion)
        }
        var newRows: [ItemIdentifierType: Int] = [:]
        newRows.reserveCapacity(newItems.count)
        for (row, item) in newItems.enumerated() { newRows[item] = row }
        var oldToNew: [Int?] = []
        oldToNew.reserveCapacity(items.count)
        var isIdentity = items.count == newItems.count
        // With sections as groups, items moved to another section change group.
        var otherSection: [ItemIdentifierType] = []
        for (row, item) in items.enumerated() {
            let new = newRows[item]
            oldToNew.append(new)
            if new != row { isIdentity = false }
            if sectionTitleProvider != nil, new != nil,
               currentSnapshot.sectionIdentifier(containingItem: item) != snapshot.sectionIdentifier(containingItem: item) {
                otherSection.append(item)
            }
        }
        store(snapshot, items: newItems, rows: newRows)
        tableView.beginUpdates()
        if animatingDifferences, !defaultRowAnimation.isEmpty {
            tableView.rowUpdateBatch?.animates = true
            if tableView.rowUpdateBatch?.animationOptions.isEmpty == true { tableView.rowUpdateBatch?.animationOptions = defaultRowAnimation }
        }
        if !isIdentity {
            tableView.remapRows(oldToNew, newCount: newItems.count)
        }
        if !changed.isEmpty || !otherSection.isEmpty {
            // New rows are read anyway; only kept ones need marking.
            let rows = IndexSet((changed + otherSection).compactMap { newRows[$0] }.sorted())
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        }
        tableView.endUpdates()
        completion?()
    }

    /// Makes the table show the snapshot by reading everything again, like
    /// `reloadData()`; the selection follows the items.
    public func applySnapshotUsingReloadData(_ snapshot: Snapshot, completion: (() -> Void)? = nil) {
        let newItems = snapshot.itemIdentifiers
        var newRows: [ItemIdentifierType: Int] = [:]
        newRows.reserveCapacity(newItems.count)
        for (row, item) in newItems.enumerated() { newRows[item] = row }
        store(snapshot, items: newItems, rows: newRows)
        if let tableView, tableView.dataSource === self {
            tableView.reloadData()
        }
        completion?()
    }

    /// The item of a row (a data source row), or `nil`.
    public func itemIdentifier(forRow row: Int) -> ItemIdentifierType? {
        row >= 0 && row < items.count ? items[row] : nil
    }

    /// The row (a data source row) of an item, or `nil` if it isn't shown.
    public func row(forItemIdentifier identifier: ItemIdentifierType) -> Int? {
        rowOfItem[identifier]
    }

    /// The section of a row's item, or `nil`.
    public func sectionIdentifier(forRow row: Int) -> SectionIdentifierType? {
        itemIdentifier(forRow: row).flatMap(currentSnapshot.sectionIdentifier(containingItem:))
    }

    private func store(_ snapshot: Snapshot, items newItems: [ItemIdentifierType], rows: [ItemIdentifierType: Int]) {
        currentSnapshot = snapshot.withoutReloads
        items = newItems
        rowOfItem = rows
    }

    // MARK: NGTableViewDataSource

    public func numberOfRows(in tableView: NGTableView) -> Int { items.count }

    public func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        guard row >= 0, row < items.count else { return .empty }
        if column.id == Self.sectionColumnID, let sectionTitleProvider {
            return currentSnapshot.sectionIdentifier(containingItem: items[row]).map { .text(sectionTitleProvider($0)) } ?? .empty
        }
        return valueProvider(tableView, column, row, items[row])
    }

    public func tableView(_ tableView: NGTableView, identifierForRow row: Int) -> AnyHashable? {
        itemIdentifier(forRow: row).map { AnyHashable($0) }
    }

    public func tableView(_ tableView: NGTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortDescriptorsDidChange?(tableView, oldDescriptors)
    }
}
#endif
