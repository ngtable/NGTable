import Foundation

/// Sorting rows by the table's `NSSortDescriptor`s when the data source works
/// with cell values rather than key-value coded objects.
///
/// With objects that are key-value coding compliant, sort with the
/// descriptors themselves (`NSArray.sortedArray(using:)`), like for an
/// `NSTableView`. With plain Swift values, this gives the row order:
///
/// ```swift
/// func tableView(_ tableView: NGTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
///     let previous = order
///     order = NGSorting.order(ofRows: campaigns.count, by: tableView.sortDescriptors) { key, row in
///         Self.value(key, of: campaigns[row])
///     }
///     // The same rows in another order: nothing is read again.
///     tableView.reorderRows(from: previous, to: order)
/// }
/// ```
public enum NGSorting {
    /// The rows `0..<count` in the order of `descriptors`: the first decides,
    /// rows it finds equal go by the next one, and so on; rows equal by all of
    /// them keep their order. No descriptors keep the rows as they are.
    ///
    /// Each descriptor's `key`, `ascending` and selector are used, not a
    /// comparator: values compare like `NGCellValue.sortsBefore(_:)`, text
    /// by `localizedCompare:`, `localizedCaseInsensitiveCompare:` or
    /// `caseInsensitiveCompare:` when that's the selector, otherwise (also
    /// for the default, `compare:`) by `localizedStandardCompare:`, as the
    /// table sorts.
    ///
    /// - Parameters:
    ///   - count: The number of rows, `0..<count`.
    ///   - descriptors: The sort keys, most significant first.
    ///   - value: The value a row sorts by for a descriptor's key, usually the
    ///     cell value of the column with that key, or another value where the
    ///     display differs from the order (e.g. a number for an id shown as
    ///     text). It is asked once per row and key.
    /// - Returns: The rows in sorted order (a stable sort), sorted like the
    ///   table sorts them itself: numbers by radix, text on all cores.
    public static func order(ofRows count: Int, by descriptors: [NSSortDescriptor],
                             value: (_ key: String, _ row: Int) -> NGCellValue) -> [Int] {
        let rows = Array(0..<max(count, 0))
        let sorts = descriptors.compactMap { descriptor in
            descriptor.key.map { (key: $0, ascending: descriptor.ascending, comparison: NGTextComparison(descriptor)) }
        }
        guard !sorts.isEmpty, !rows.isEmpty else { return rows }
        let keys = NGSortKeys(keys: sorts.map(\.key), ascending: sorts.map(\.ascending), comparisons: sorts.map(\.comparison),
                              values: sorts.map { sort in rows.map { value(sort.key, $0) } })
        // Ties in row order: the rows' handles are their indexes.
        return NGTableView.sortedRows(rows, keys: keys, order: NGRowHandles(count: rows.count), keyProvider: nil)
    }

    /// For `NGTableView.reorderRows(fromOldIndexes:)`: the row each row of
    /// `new` had in `previous`, two orders of the same rows (each an array of
    /// the rows' indexes in the app's data, like `order(ofRows:by:value:)`
    /// gives).
    public static func oldIndexes(from previous: [Int], to new: [Int]) -> [Int] {
        precondition(previous.count == new.count, "NGSorting: two orders of different rows")
        var position = [Int](repeating: -1, count: (previous.max() ?? -1) + 1)
        for (row, index) in previous.enumerated() {
            position[index] = row
        }
        return new.map { $0 < position.count ? position[$0] : -1 }
    }

    /// The sort descriptors after a click on a sortable column's header, like
    /// `NSTableView`: the column becomes the first descriptor (others stay as
    /// secondary ones), and clicking the first column again reverses it. A
    /// click after the user reversed it (`reversedByUser`) removes it,
    /// leaving the rest: back to the original order when there is no other
    /// sort. (A sort the app set, in either direction, is reversed.)
    static func descriptors(afterClicking prototype: NSSortDescriptor, current: [NSSortDescriptor],
                            reversedByUser: Bool = false) -> [NSSortDescriptor] {
        guard let first = current.first, first.key == prototype.key else {
            return [prototype] + current.filter { $0.key != prototype.key }
        }
        return reversedByUser ? Array(current.dropFirst())
            : [first.reversedSortDescriptor as? NSSortDescriptor ?? prototype] + current.dropFirst()
    }
}
