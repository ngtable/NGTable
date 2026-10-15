#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Column filters: per-column conditions (`NGColumnFilter`) that the user sets
// from the header, like a spreadsheet's. They are part of the table's filter:
// `computeRowMap` checks them with the search, `isIncluded` and hidden rows,
// targeted updates check only rows whose filtered columns changed, and they
// are saved with the layout (`autosaveName`). The values a filter offers
// come from the rows the other column filters let through.

extension NGTableView {
    /// The column filters with their columns, for checking rows (unknown
    /// column ids are ignored), as they apply now: date periods from today
    /// in `calendar`, ranks as ranges from the column's values.
    var resolvedColumnFilters: [(column: NGTableColumn, filter: NGColumnFilter)] {
        guard !columnFilters.isEmpty else { return [] }
        let columns = tableColumns
        let now = filterDateForTesting ?? Date()
        return columnFilters.compactMap { id, filter in
            columns.first { $0.id == id }.map { column in
                (column, filter.isRank ? rankRange(filter, column: column) : filter.resolved(calendar: calendar, now: now))
            }
        }.sorted { $0.column.id < $1.column.id }
    }

    /// A top or bottom filter as the range of the numbers it lets through:
    /// from (or up to) the `count`-th largest (smallest) value of all rows,
    /// read again when rows came, went or moved, or filtered values changed.
    private func rankRange(_ filter: NGColumnFilter, column: NGTableColumn) -> NGColumnFilter {
        if let kept = rankRanges[column.id], kept.filter == filter, kept.rowsMoved == summaryRowsMoved,
           kept.valuesVersion == columnFilterValuesVersion {
            return kept.range
        }
        var numbers: [Double] = []
        if let dataSource {
            numbers.reserveCapacity(numberOfSourceRows)
            for row in 0..<numberOfSourceRows {
                if let number = dataSource.tableView(self, valueFor: column, row: row).numericValue, number.isFinite { numbers.append(number) }
            }
        }
        let range: NGColumnFilter
        switch filter {
        case .top(let count): range = Self.rankRange(numbers, count: count, largest: true)
        case .bottom(let count): range = Self.rankRange(numbers, count: count, largest: false)
        default: range = filter
        }
        rankRanges[column.id] = (filter, range, summaryRowsMoved, columnFilterValuesVersion)
        return range
    }

    /// The range of the `count` largest (smallest) numbers, ties with the
    /// last included; nothing for no count, every number for more than there are.
    nonisolated static func rankRange(_ numbers: [Double], count: Int, largest: Bool) -> NGColumnFilter {
        guard count > 0, !numbers.isEmpty else { return .range(min: .infinity, max: -.infinity) }
        guard count < numbers.count else { return .range(min: -.infinity, max: .infinity) }
        // The k-th smallest, k counted from the end for the largest.
        var values = numbers
        let k = largest ? numbers.count - count : count - 1
        let threshold = nthSmallest(&values, k)
        return largest ? .range(min: threshold, max: nil) : .range(min: nil, max: threshold)
    }

    /// The `k`-th smallest value (from 0), by quickselect (linear on average).
    nonisolated static func nthSmallest(_ values: inout [Double], _ k: Int) -> Double {
        var low = 0, high = values.count - 1
        var generator = SystemRandomNumberGenerator()
        while low < high {
            values.swapAt(Int.random(in: low...high, using: &generator), high)
            let pivot = values[high]
            var store = low
            for index in low..<high where values[index] < pivot {
                values.swapAt(index, store)
                store += 1
            }
            values.swapAt(store, high)
            if store == k { return values[store] }
            if store < k { low = store + 1 } else { high = store - 1 }
        }
        return values[low]
    }

    /// Whether each row (by handle) passes each column filter, brought up to
    /// date: every row for a new filter, otherwise only new rows and those
    /// whose filtered columns changed.
    @discardableResult
    func updateColumnFilterPasses(_ filters: [(column: NGTableColumn, filter: NGColumnFilter)],
                                  dataSource: NGTableViewDataSource) -> [(columnID: String, passes: [Bool])] {
        let capacity = rowHandles.capacity
        let toCheck = columnFilterRowsToCheck
        columnFilterRowsToCheck = []
        var kept: [String: (filter: NGColumnFilter, passes: [Bool])] = [:]
        var result: [(columnID: String, passes: [Bool])] = []
        for (column, filter) in filters {
            func passes(_ handle: Int) -> Bool {
                let row = row(ofHandle: handle)
                return row >= 0 && passesColumnFilters(row: row, [(column, filter)], dataSource: dataSource)
            }
            var passesByHandle: [Bool]
            if let cached = columnFilterPasses[column.id], cached.filter == filter, cached.passes.count <= capacity {
                passesByHandle = cached.passes
                let known = passesByHandle.count
                if known < capacity {
                    passesByHandle.append(contentsOf: repeatElement(false, count: capacity - known))
                    for handle in known..<capacity { passesByHandle[handle] = passes(handle) }
                }
                for handle in toCheck where handle < known { passesByHandle[handle] = passes(handle) }
            } else {
                // A filter that applies differently now (another day for a
                // period, other values for a rank): the rows it showed may
                // change without having changed.
                if columnFilterPasses[column.id] != nil { filterNeedsFullEvaluation = true }
                passesByHandle = [Bool](repeating: false, count: capacity)
                for handle in allRowHandles { passesByHandle[handle] = passes(handle) }
            }
            kept[column.id] = (filter, passesByHandle)
            result.append((column.id, passesByHandle))
        }
        columnFilterPasses = kept
        return result
    }

    /// Whether a data source row passes the column filters.
    func passesColumnFilters(row: Int, _ filters: [(column: NGTableColumn, filter: NGColumnFilter)],
                             dataSource: NGTableViewDataSource, skipping skippedID: String? = nil) -> Bool {
        for (column, filter) in filters where column.id != skippedID {
            let value = dataSource.tableView(self, valueFor: column, row: row)
            let text = filter.needsText ? Self.filterText(of: value, format: column.format, locale: locale) : ""
            if !filter.matches(value, text: text) { return false }
        }
        return true
    }

    /// A value as a column filter sees it: as displayed, "" when empty.
    static func filterText(of value: NGCellValue, format: NGValueFormat, locale: Locale? = nil) -> String {
        value == .empty ? "" : NGFormatIDs.string(for: value, format: format, locale: locale)
    }

    /// The values of a column a value filter can offer, as displayed, with
    /// how many rows have each: of the rows everything else lets through
    /// (the other column filters, the search, `isIncluded`, hidden rows),
    /// sorted like Finder sorts names. At most `limit` values (the most
    /// frequent ones when there are more).
    public func filterValues(forColumnID columnID: String, limit: Int = 1_000) -> [(value: String, count: Int)] {
        filterValueList(forColumnID: columnID, limit: limit).values
    }

    /// `filterValues(forColumnID:limit:)`, and whether there were more values.
    func filterValueList(forColumnID columnID: String, limit: Int) -> (values: [(value: String, count: Int)], isTruncated: Bool) {
        guard let dataSource, let column = tableColumns.first(where: { $0.id == columnID }) else { return ([], false) }
        let others = updateColumnFilterPasses(resolvedColumnFilters, dataSource: dataSource).filter { $0.columnID != columnID }.map(\.passes)
        let filter = rowFilter ?? NGRowFilter()
        let words = filter.searchWords
        // The search as it shows rows now (while its index is read, every row).
        let index = words.isEmpty ? nil : searchIndex(for: filter, dataSource: dataSource)
        var counts: [String: Int] = [:]
        var seen: [NGCellValue: String] = [:]
        for row in 0..<numberOfSourceRows {
            let handle = handle(ofRow: row)
            if !hiddenRowHandles.isEmpty, hiddenRowHandles.contains(handle) { continue }
            if others.contains(where: { handle >= $0.count || !$0[handle] }) { continue }
            if let index, !NGRowFilter.matches(searchWords: words, rowWords: index.words(ofRow: handle)) { continue }
            if let isIncluded = filter.isIncluded, !isIncluded(row) { continue }
            let value = dataSource.tableView(self, valueFor: column, row: row)
            // Values repeat: each is formatted once.
            let text: String
            if let known = seen[value] {
                text = known
            } else {
                text = Self.filterText(of: value, format: column.format, locale: locale)
                if seen.count < 10_000 { seen[value] = text }
            }
            counts[text, default: 0] += 1
        }
        var values = counts.map { (value: $0.key, count: $0.value) }
        let isTruncated = values.count > limit
        if isTruncated {
            values = Array(values.sorted { $0.count > $1.count }.prefix(limit))
        }
        return (values.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }, isTruncated)
    }

    // MARK: Header

    static let filterButtonWidth: CGFloat = 16

    /// Whether a column's header shows the filter button: while the pointer
    /// is over the header of a filterable column wide enough for it, and
    /// always while the column has a filter (a quiet header otherwise).
    func showsFilterButton(for column: NGTableColumn, width: Double) -> Bool {
        guard allowsColumnFilters, column.isFilterable else { return false }
        return columnFilters[column.id] != nil || (hoveredHeaderColumnID == column.id && width >= 44)
    }

    /// The column whose header the pointer is over (`nil`: none).
    func updateHoveredHeaderColumn(at point: CGPoint?) {
        let id = point.flatMap { column(atViewportPoint: $0)?.frame.column.id }
        guard id != hoveredHeaderColumnID else { return }
        hoveredHeaderColumnID = id
        if allowsColumnFilters { setNeedsChromeFrame(headerView) }
    }

    /// Where the filter button is in a column's title area: at its trailing end.
    /// - Parameter mirrored: At the title's left (right to left by default).
    func filterButtonRect(inTitleRect rect: CGRect, mirrored: Bool? = nil) -> CGRect {
        CGRect(x: (mirrored ?? isRightToLeft) ? rect.minX + NGMetrics.cellPadding : rect.maxX - NGMetrics.cellPadding - Self.filterButtonWidth,
               y: rect.minY,
               width: Self.filterButtonWidth, height: rect.height)
    }

    /// Opens a column's filter in a popover under its header, as its filter
    /// button does: for a menu item, or the keyboard (Option-Down Arrow on a
    /// focused cell, like a spreadsheet). Scrolls the column into view
    /// first. Returns whether it opened: with `allowsColumnFilters`, for a
    /// filterable column that is shown.
    @discardableResult
    public func showFilter(forColumnID columnID: String) -> Bool {
        guard allowsColumnFilters, let index = tableColumns.firstIndex(where: { $0.id == columnID }),
              tableColumns[index].isFilterable, !hiddenColumnIDs.contains(columnID) else { return false }
        scrollColumnToVisible(index)
        layoutSubtreeIfNeeded()
        let viewport = viewport
        for pin in NGColumnPin.allCases {
            guard let frame = geometry[pin].columns.first(where: { $0.column.id == columnID }) else { continue }
            let band = columnLayout.hasGroups ? groupHeaderHeight : 0
            let title = CGRect(x: viewport.origin(of: pin) + CGFloat(frame.x) + slideOffset(forColumnID: columnID), y: band,
                               width: CGFloat(frame.width), height: headerView.bounds.height - band)
            showColumnFilter(for: frame.column, relativeTo: filterButtonRect(inTitleRect: title), of: headerView)
            return true
        }
        return false
    }

    #if os(macOS)
    /// Opens the filter of a column in a popover under its button.
    func showColumnFilter(for column: NGTableColumn, relativeTo rect: CGRect, of view: NGPlatformView) {
        columnFilterPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NGColumnFilterViewController(table: self, column: column)
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        columnFilterPopover = popover
    }
    #endif

    /// Sets or clears one column's filter as the user does from the header:
    /// saves the layout and tells the delegate.
    func setColumnFilter(_ filter: NGColumnFilter?, forColumnID columnID: String) {
        var filters = columnFilters
        filters[columnID] = filter
        guard filters != columnFilters else { return }
        columnFilters = filters
        delegate?.tableView(self, didChangeColumnFilters: columnFilters)
    }
}
#endif
