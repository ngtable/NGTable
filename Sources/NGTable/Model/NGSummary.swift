import Foundation

/// Aggregate function computed in the summary row.
public enum NGAggregate: Sendable, Hashable, CaseIterable {
    /// The total. Blank (not 0) when there are no values.
    case sum
    /// The arithmetic mean of the values.
    case average
    /// Number of rows that have a finite numeric value (NaN and infinity count
    /// as empty).
    case count
    /// The smallest value.
    case min
    /// The largest value.
    case max
}

/// Which values an aggregate takes into account. Empty and non-numeric values
/// are always left out.
///
/// Filters are compared by name: give custom filters distinct names.
public struct NGValueFilter: Sendable, Hashable {
    /// Identifies the filter; filters with the same name are the same.
    public let name: String
    private let predicate: @Sendable (Double) -> Bool

    /// A filter that includes the values `predicate` returns `true` for. It is
    /// called off the main thread for large tables, so it must be pure.
    public init(_ name: String, _ predicate: @escaping @Sendable (Double) -> Bool) {
        self.name = name
        self.predicate = predicate
    }

    /// Whether a value takes part in the aggregate.
    public func includes(_ value: Double) -> Bool {
        predicate(value)
    }

    /// Every value.
    public static let all = NGValueFilter("all") { _ in true }
    /// Values other than 0, e.g. the average ROI of campaigns that ran.
    public static let nonZero = NGValueFilter("nonZero") { $0 != 0 }
    /// Values greater than 0.
    public static let positive = NGValueFilter("positive") { $0 > 0 }
    /// Values of 0 or more.
    public static let nonNegative = NGValueFilter("nonNegative") { $0 >= 0 }

    public static func == (lhs: NGValueFilter, rhs: NGValueFilter) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

/// Aggregates of other columns in the current summary scope, passed to a
/// summary formula.
public struct NGSummaryValues: Sendable {
    private let calculators: [String: NGSummaryCalculator]
    /// Sum and count of every input, computed once per summary update.
    private let accumulators: [String: NGAccumulator]
    private let scope: NGSummaryScope
    private let selection: IndexSet

    init(calculators: [String: NGSummaryCalculator], scope: NGSummaryScope, selection: IndexSet) {
        self.init(calculators: calculators,
                  accumulators: calculators.mapValues { $0.accumulator(scope: scope, selection: selection, includesMinMax: false) },
                  scope: scope, selection: selection)
    }

    /// With accumulators computed by the caller (shared by several formulas).
    init(calculators: [String: NGSummaryCalculator], accumulators: [String: NGAccumulator], scope: NGSummaryScope, selection: IndexSet) {
        self.calculators = calculators
        self.accumulators = accumulators
        self.scope = scope
        self.selection = selection
    }

    /// The aggregate of a column's values in the current scope, or `nil` if the
    /// data source provided no numeric values for it there.
    public func value(_ aggregate: NGAggregate, of columnID: String) -> Double? {
        guard let accumulator = accumulators[columnID], accumulator.count > 0 else { return nil }
        // Min and max are computed when a formula asks for them: the shared
        // accumulators hold sums and counts only.
        if aggregate == .min || aggregate == .max {
            return calculators[columnID]?.value(for: aggregate, scope: scope, selection: selection)
        }
        return accumulator.value(for: aggregate)
    }

    /// The sum of a column's values in the scope, or `nil` without values.
    public func sum(_ columnID: String) -> Double? { value(.sum, of: columnID) }
    public func average(_ columnID: String) -> Double? { value(.average, of: columnID) }
    public func min(_ columnID: String) -> Double? { value(.min, of: columnID) }
    public func max(_ columnID: String) -> Double? { value(.max, of: columnID) }

    /// Number of numeric values; 0 when there are none.
    public func count(_ columnID: String) -> Double {
        Double(accumulators[columnID]?.count ?? 0)
    }
}

/// A summary computed from aggregates of other columns, e.g. the total ROI
/// `(sum of revenue − sum of spend) / sum of spend`, which, unlike the average
/// of the rows' ROI, weighs every row by its spend.
///
/// Inputs are column ids. Their values come from the data source like any
/// column's, whether the columns are shown, hidden or not in the table at all.
/// When the formula returns `nil` (e.g. the data source has no values for an
/// input), the optional fallback aggregate of the column's own values is shown.
///
/// Formulas are compared by name: give different formulas distinct names.
public struct NGSummaryFormula: Sendable, Hashable {
    /// Identifies the formula; formulas with the same name and inputs are the same.
    public let name: String
    /// Column ids whose aggregates the formula reads.
    public let inputs: [String]
    /// Shown (an aggregate of the column's own values) when the formula
    /// returns `nil` or a non-finite value.
    public let fallback: NGAggregate?
    /// Which of the column's own values the fallback aggregates.
    public let fallbackFilter: NGValueFilter
    private let compute: @Sendable (NGSummaryValues) -> Double?

    /// - Parameters:
    ///   - name: Distinct for every different computation.
    ///   - inputs: Every column id `compute` reads; others read as `nil`.
    ///   - fallback: Aggregate of the column's own values shown when `compute`
    ///     returns `nil`.
    ///   - fallbackFilter: Which of the column's values the fallback includes.
    ///   - compute: The value from the inputs' aggregates in the current scope.
    ///     Must be pure; return `nil` when it can't be computed (e.g. dividing by 0).
    public init(
        _ name: String,
        using inputs: [String],
        otherwise fallback: NGAggregate? = nil,
        including fallbackFilter: NGValueFilter = .all,
        _ compute: @escaping @Sendable (NGSummaryValues) -> Double?
    ) {
        self.name = name
        self.inputs = inputs
        self.fallback = fallback
        self.fallbackFilter = fallbackFilter
        self.compute = compute
    }

    /// Runs the formula.
    public func value(with values: NGSummaryValues) -> Double? {
        compute(values)
    }

    public static func == (lhs: NGSummaryFormula, rhs: NGSummaryFormula) -> Bool {
        lhs.name == rhs.name && lhs.inputs == rhs.inputs && lhs.fallback == rhs.fallback && lhs.fallbackFilter == rhs.fallbackFilter
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(inputs)
    }
}

/// What a column shows in the summary row. The summary row holds values only,
/// no captions.
public enum NGColumnSummary: Sendable, Hashable {
    case none
    /// An aggregate of the column's own values, optionally only some of them
    /// (e.g. the average of non-zero values).
    case aggregate(NGAggregate, including: NGValueFilter = .all)
    /// A value computed from aggregates of other columns.
    case formula(NGSummaryFormula)

    /// Whether the column shows a summary value.
    public var hasValue: Bool {
        if case .none = self { return false }
        return true
    }
}

/// Which rows participate in the summary.
public enum NGSummaryScope: Sendable, Hashable, CaseIterable {
    case allRows
    case selectedRows
    /// Inverted logic: selected rows are subtracted from the total.
    case excludingSelectedRows
}

/// Running aggregate over a set of numeric values.
///
/// Sums are compensated (Neumaier), so totals of many values, and totals minus
/// the selected rows ("all except selected"), stay exact where plain floating
/// point addition would drift or leave a residue like -0.00.
public struct NGAccumulator: Sendable, Equatable {
    /// The compensated sum of the values (0 without values).
    public var sum: Double { total + compensation }
    /// Number of values added.
    public private(set) var count: Int = 0
    /// The smallest value, `nil` without values.
    public private(set) var min: Double?
    /// The largest value, `nil` without values.
    public private(set) var max: Double?

    private var total: Double = 0
    private var compensation: Double = 0
    /// Whether `min` and `max` cover every value: not after values were
    /// subtracted (they can't be), until they are computed again.
    private(set) var hasExactMinMax = true

    /// An empty accumulator.
    public init() {}

    /// Equal when the aggregates are, whatever the order values were added in.
    public static func == (lhs: NGAccumulator, rhs: NGAccumulator) -> Bool {
        lhs.sum == rhs.sum && lhs.count == rhs.count && lhs.min == rhs.min && lhs.max == rhs.max
    }

    /// Adds a value. Non-finite values (NaN, infinity) are ignored like empty
    /// values: a single one would make every summary unusable.
    public mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        let newTotal = total + value
        compensation += abs(total) >= abs(value) ? (total - newTotal) + value : (value - newTotal) + total
        total = newTotal
        count += 1
        min = Swift.min(min ?? value, value)
        max = Swift.max(max ?? value, value)
    }

    /// The aggregate of the values added, or `nil` when it has none.
    public func value(for aggregate: NGAggregate) -> Double? {
        switch aggregate {
        // No values is no sum (a blank summary), not a total of 0.
        case .sum: count > 0 ? sum : nil
        case .average: count > 0 ? sum / Double(count) : nil
        case .count: Double(count)
        case .min: min
        case .max: max
        }
    }

    /// After values were subtracted, min and max as they were before (still
    /// right when the removed values were within them, or the values added
    /// since reach past them).
    fileprivate mutating func keepMinMax(min: Double, max: Double) {
        guard count > 0 else { return }
        self.min = min
        self.max = max
        hasExactMinMax = true
    }

    /// Adds another accumulator's values (sum, count; min and max as they
    /// are known).
    func adding(_ other: NGAccumulator) -> NGAccumulator {
        guard other.count > 0 else { return self }
        guard count > 0 else { return other }
        var result = self
        let newTotal = total + other.total
        result.compensation += abs(total) >= abs(other.total) ? (total - newTotal) + other.total : (other.total - newTotal) + total
        result.compensation += other.compensation
        result.total = newTotal
        result.count += other.count
        result.min = Swift.min(min ?? .infinity, other.min ?? .infinity)
        result.max = Swift.max(max ?? -.infinity, other.max ?? -.infinity)
        result.hasExactMinMax = hasExactMinMax && other.hasExactMinMax
        return result
    }

    /// Removes `other` (a subset of the added values, at most about half of
    /// them) for sum/count/average. Min and max cannot be derived this way and
    /// are cleared.
    func subtractingAdditive(_ other: NGAccumulator) -> NGAccumulator {
        var result = NGAccumulator()
        result.count = count - other.count
        guard result.count > 0 else { return result }
        result.hasExactMinMax = false
        result.total = total - other.total
        result.compensation = compensation - other.compensation
        // A residue of rounding is not a value (e.g. 0.1 + 0.2 minus 0.2 + 0.1
        // shown as -0.00). The totals are compensated: their difference is
        // exact, and what rounding leaves is at the level of the compensations,
        // so a remainder under the large values' last place stays (0.15 of
        // 1e15 + 0.15).
        let residue = Swift.max(abs(compensation), abs(other.compensation), abs(result.compensation)).ulp * 4
        if abs(result.sum) <= residue {
            result.total = 0
            result.compensation = 0
        }
        return result
    }
}

/// Computes summary values for a single column.
///
/// Totals over all rows are computed once; selection-dependent values walk the
/// selection (or, when most rows are selected, the unselected rest) range by
/// range, so updating the summary on every selection change stays cheap for
/// large tables.
///
/// Values are stored compactly (`NaN` for rows without a value) and can be
/// shared with other calculators: a row map (displayed row → stored row) and a
/// value filter are applied when reading, not by copying the values.
public struct NGSummaryCalculator: Sendable {
    private let source: [Double]
    private let rowMap: [Int]?
    private let filter: NGValueFilter
    /// Number of rows the calculator covers.
    public let count: Int
    /// Aggregates of all rows.
    public let total: NGAccumulator
    /// Whether `rowMap` is from before rows moved: the total and `count`
    /// are right, but row queries need `withRowMap(_:)` first (rows that
    /// move on every batch of a feed were all copied for it, only to sum);
    /// until then they read the old rows (in the middle of a batch).
    let rowMapIsStale: Bool

    /// - Parameters:
    ///   - values: Values by row, `nil` for rows without a value.
    ///   - filter: Values it excludes are treated as empty.
    public init(values: [Double?], including filter: NGValueFilter = .all) {
        self.init(source: values.map { $0 ?? .nan }, rowMap: nil, including: filter)
    }

    /// - Parameters:
    ///   - source: Values by stored row, `NaN` for rows without a value.
    ///   - rowMap: The stored row of each row, or `nil` when they are the same.
    ///   - filter: Values it excludes are treated as empty.
    public init(source: [Double], rowMap: [Int]?, including filter: NGValueFilter = .all) {
        self.source = source
        self.rowMap = rowMap
        self.filter = filter
        count = rowMap?.count ?? source.count
        total = Self.accumulate(rows: 0..<(rowMap?.count ?? source.count), source: source, rowMap: rowMap, filter: filter)
        rowMapIsStale = false
    }

    private init(source: [Double], rowMap: [Int]?, filter: NGValueFilter, total: NGAccumulator, count: Int,
                 rowMapIsStale: Bool = false) {
        self.source = source
        self.rowMap = rowMap
        self.filter = filter
        self.count = count
        self.total = total
        self.rowMapIsStale = rowMapIsStale
    }

    /// The same calculator over its rows as they are now (`count` of them).
    func withRowMap(_ newRowMap: [Int]) -> NGSummaryCalculator {
        precondition(newRowMap.count == count, "NGSummaryCalculator: a row map of \(newRowMap.count) rows for \(count)")
        return NGSummaryCalculator(source: source, rowMap: newRowMap, filter: filter, total: total, count: count)
    }


    /// The same calculator reading other storage of the same values: `[]`
    /// lets the caller change its values without copying them (the arrays
    /// are shared), the values give them back. Totals stay.
    func withSource(_ newSource: [Double]) -> NGSummaryCalculator {
        NGSummaryCalculator(source: newSource, rowMap: rowMap, filter: filter, total: total, count: count,
                            rowMapIsStale: rowMapIsStale)
    }

    /// The same totals over other storage of the same rows' values, e.g. a
    /// group's rows after rows around them moved (min and max are computed
    /// again from these rows when asked for).
    func withSource(_ newSource: [Double], rowMap newRowMap: [Int]) -> NGSummaryCalculator {
        NGSummaryCalculator(source: newSource, rowMap: newRowMap, filter: filter, total: total, count: newRowMap.count)
    }

    /// The calculator after some of its rows changed values, without walking
    /// every row: the total takes away the old values (of changed and removed
    /// rows) and adds the new ones (of changed and inserted rows). With a row
    /// map, its rows must stay the same (only their values changed). Min and
    /// max are computed again when asked for.
    func updating(source newSource: [Double], removing removed: [Double], adding added: [Double]) -> NGSummaryCalculator {
        updating(source: newSource, rowMap: rowMap, removing: removed, adding: added)
    }

    /// The same with other rows (a filter shows other rows now): `removed`
    /// and `added` hold the values of the rows that left and came too.
    func updating(source newSource: [Double], rowMap newRowMap: [Int]?, removing removed: [Double], adding added: [Double]) -> NGSummaryCalculator {
        updating(source: newSource, rowMap: newRowMap, count: newRowMap?.count ?? newSource.count, rowMapIsStale: false,
                 removing: removed, adding: added)
    }

    /// The same for `count` rows that moved, without their order yet: the
    /// row map stays the old one, stale, until `withRowMap(_:)`.
    func updating(source newSource: [Double], movedRowsCount count: Int, removing removed: [Double], adding added: [Double]) -> NGSummaryCalculator {
        updating(source: newSource, rowMap: rowMap, count: count, rowMapIsStale: true, removing: removed, adding: added)
    }

    private func updating(source newSource: [Double], rowMap newRowMap: [Int]?, count newCount: Int, rowMapIsStale: Bool,
                          removing removed: [Double], adding added: [Double]) -> NGSummaryCalculator {
        let includesAll = filter == .all
        let filter = filter
        // Plain loops over buffers, like `accumulate`: every update runs this.
        func add(_ values: [Double], to accumulator: inout NGAccumulator) {
            values.withUnsafeBufferPointer { buffer in
                var index = 0
                while index < buffer.count {
                    let value = buffer[index]
                    if value.isFinite, includesAll || filter.includes(value) { accumulator.add(value) }
                    index += 1
                }
            }
        }
        var minus = NGAccumulator()
        add(removed, to: &minus)
        var total = minus.count > 0 ? self.total.subtractingAdditive(minus) : self.total
        // Min and max stay exact unless an extreme was removed and nothing
        // added reaches it (a feed raising the largest value keeps the max):
        // then they're computed again once, when asked for (`withExactMinMax`).
        if minus.count > 0, self.total.hasExactMinMax, let oldMin = self.total.min, let oldMax = self.total.max,
           let removedMin = minus.min, let removedMax = minus.max {
            var plus = NGAccumulator()
            add(added, to: &plus)
            let keepsMax = removedMax < oldMax || (plus.max.map { $0 >= oldMax } ?? false)
            let keepsMin = removedMin > oldMin || (plus.min.map { $0 <= oldMin } ?? false)
            if keepsMax, keepsMin { total.keepMinMax(min: oldMin, max: oldMax) }
        }
        add(added, to: &total)
        return NGSummaryCalculator(source: newSource, rowMap: newRowMap, filter: filter, total: total,
                                   count: newCount, rowMapIsStale: rowMapIsStale)
    }

    /// Whether min and max of all rows are known without walking them.
    var hasExactMinMax: Bool { total.hasExactMinMax }

    /// The same calculator with min and max of all rows computed again (one
    /// walk), to keep instead of walking on every query.
    func withExactMinMax() -> NGSummaryCalculator {
        guard !total.hasExactMinMax else { return self }
        return NGSummaryCalculator(source: source, rowMap: rowMap, filter: filter,
                                   total: Self.accumulate(rows: 0..<count, source: source, rowMap: rowMap, filter: filter),
                                   count: count)
    }

    /// The value of a row, if it has one the filter includes.
    public func value(atRow row: Int) -> Double? {
        guard row >= 0, row < count else { return nil }
        if let rowMap, row >= rowMap.count { return nil }
        let index = rowMap.map { $0[row] } ?? row
        guard index >= 0, index < source.count else { return nil }
        let value = source[index]
        guard value.isFinite, filter == .all || filter.includes(value) else { return nil }
        return value
    }

    /// Adds the values of `rows` (row indexes, mapped by `rowMap`). Plain
    /// loops over buffers: this walks every row, often, also in debug builds.
    private static func accumulate(rows: Range<Int>, source: [Double], rowMap: [Int]?, filter: NGValueFilter,
                                   into result: inout NGAccumulator) {
        let includesAll = filter == .all
        source.withUnsafeBufferPointer { values in
            func add(_ index: Int) {
                guard index >= 0, index < values.count else { return }
                let value = values[index]
                if value.isFinite, includesAll || filter.includes(value) { result.add(value) }
            }
            var row = rows.lowerBound
            if let rowMap {
                rowMap.withUnsafeBufferPointer { map in
                    // (A stale map may have fewer rows than the calculator.)
                    let upper = min(rows.upperBound, map.count)
                    while row < upper {
                        add(map[row])
                        row += 1
                    }
                }
            } else {
                while row < rows.upperBound {
                    add(row)
                    row += 1
                }
            }
        }
    }

    private static func accumulate(rows: Range<Int>, source: [Double], rowMap: [Int]?, filter: NGValueFilter) -> NGAccumulator {
        var result = NGAccumulator()
        accumulate(rows: rows, source: source, rowMap: rowMap, filter: filter, into: &result)
        return result
    }

    /// An aggregate of the rows in a scope; `selection` holds row indexes.
    public func value(for aggregate: NGAggregate, scope: NGSummaryScope, selection: IndexSet) -> Double? {
        accumulator(scope: scope, selection: selection, includesMinMax: aggregate == .min || aggregate == .max)
            .value(for: aggregate)
    }

    /// Sum, count and (optionally) min/max of the values in a scope. Sums of a
    /// large part of the rows are taken as the total minus the smaller rest;
    /// min and max can't be derived that way, so they are computed directly
    /// only when asked for.
    public func accumulator(scope: NGSummaryScope, selection: IndexSet, includesMinMax: Bool = true) -> NGAccumulator {
        let selected = min(selection.count, count)
        switch scope {
        case .allRows:
            // After an update in place, min and max are computed again.
            if includesMinMax, !total.hasExactMinMax {
                        return Self.accumulate(rows: 0..<count, source: source, rowMap: rowMap, filter: filter)
            }
            return total
        case .selectedRows:
            if !includesMinMax, selected * 2 > count {
                return total.subtractingAdditive(accumulate(excluding: selection))
            }
            return accumulate(selection)
        case .excludingSelectedRows:
            // Nothing selected: all rows (min and max computed again after an update in place).
            guard !selection.isEmpty else { return accumulator(scope: .allRows, selection: [], includesMinMax: includesMinMax) }
            if !includesMinMax, selected * 2 < count {
                return total.subtractingAdditive(accumulate(selection))
            }
            return accumulate(excluding: selection)
        }
    }

    /// Sum and count of some rows (row indexes), range by range.
    func accumulator(ofRows rows: IndexSet) -> NGAccumulator {
        accumulate(rows)
    }

    /// The rows of `rows`, range by range.
    private func accumulate(_ rows: IndexSet) -> NGAccumulator {
        var result = NGAccumulator()
        for range in rows.rangeView {
            let lower = max(range.lowerBound, 0), upper = min(range.upperBound, count)
            guard lower < upper else { continue }
            Self.accumulate(rows: lower..<upper, source: source, rowMap: rowMap, filter: filter, into: &result)
        }
        return result
    }

    /// All rows except those in `rows`, walking the gaps between their ranges.
    private func accumulate(excluding rows: IndexSet) -> NGAccumulator {
        var result = NGAccumulator()
        var start = 0
        for range in rows.rangeView where range.lowerBound < count {
            if start < range.lowerBound {
                Self.accumulate(rows: start..<range.lowerBound, source: source, rowMap: rowMap, filter: filter, into: &result)
            }
            start = max(start, range.upperBound)
        }
        if start < count {
            Self.accumulate(rows: start..<count, source: source, rowMap: rowMap, filter: filter, into: &result)
        }
        return result
    }
}
