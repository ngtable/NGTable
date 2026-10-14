import Foundation

/// The table's own numbers for the data source's rows ("handles"): a row
/// keeps its handle while rows are inserted, removed and moved around it, so
/// everything the table keeps per row (summarized values, search words,
/// sort and group keys, filter results) is stored by handle and never moves,
/// and orders of rows (sorted, filtered, grouped) list handles that don't
/// need renumbering. The API stays in data source indexes: this maps both
/// ways.
///
/// Handles in index order are an `NGHandleSequence`: blocks of a few
/// hundred and a Fenwick tree of where they start, so an insert or a remove
/// shifts one block and updates the tree, not every row, and a handle's
/// index is a descent of the tree. Removed handles are reused only after
/// `releaseRemoved()` (the end of a batch), so a handle means one record for
/// a whole batch; to keep a record for longer (an open editor, Undo, a copy
/// in the background), keep an `NGRowRef`, which knows when its handle went
/// to another record.
struct NGRowHandles: Sendable {
    /// Handles in index order.
    private var sequence = NGHandleSequence()
    /// Handles to reuse, and handles removed since the last release.
    private var reusable: [Int32] = []
    private var removed: [Int32] = []
    /// How many times each handle was given to another record (missing:
    /// never), and how many times all of them were (`reset`): what an
    /// `NGRowRef` checks.
    private var generations: [UInt32] = []
    private(set) var epoch: UInt32 = 0

    /// Number of rows.
    var count: Int { sequence.count }
    /// Whether every handle still equals its row's index (after `reset`,
    /// until rows are inserted, removed or moved): lookups skip the blocks,
    /// so a feed of changing values pays nothing for handles.
    private(set) var isIdentity = true

    /// Handles there may be (used or not): the size of arrays by handle.
    var capacity: Int { sequence.capacity }

    /// Rows 0..<count with handles 0..<count.
    init(count: Int = 0) {
        reset(count: count)
    }

    /// All rows again, with handles equal to their indexes.
    mutating func reset(count rowCount: Int) {
        isIdentity = true
        reusable = []
        removed = []
        // Every handle may be another record now.
        epoch &+= 1
        generations = []
        sequence = NGHandleSequence.changingOrder(0..<rowCount, capacity: rowCount)
    }

    // MARK: Lookups

    /// The handle of the row at an index.
    func handle(at index: Int) -> Int32 {
        if isIdentity { return Int32(truncatingIfNeeded: index) }
        return sequence.handle(at: index)
    }

    /// Appends the handles of rows given in ascending order (below `count`).
    func appendHandles(atAscending rows: [Int32], to result: inout [Int32]) {
        if isIdentity {
            result.append(contentsOf: rows)
        } else {
            sequence.appendHandles(atAscending: rows, to: &result)
        }
    }

    /// The index of a handle's row, or -1 if no row has it (removed, or
    /// beyond the rows).
    func index(of handle: Int32) -> Int {
        guard handle >= 0, Int(handle) < sequence.capacity else { return -1 }
        if isIdentity { return Int(handle) }
        return sequence.index(of: handle)
    }

    /// A reference to the record at an index that stays valid while the
    /// record keeps its handle.
    func ref(at index: Int) -> NGRowRef {
        ref(of: handle(at: index))
    }

    /// A reference to a handle's current record.
    func ref(of handle: Int32) -> NGRowRef {
        let generation = Int(handle) < generations.count ? generations[Int(handle)] : 0
        return NGRowRef(handle: handle, stamp: UInt64(epoch) << 32 | UInt64(generation))
    }

    /// References to the records of handles (in their order), in one pass.
    func refs<Handles: Sequence<Int>>(ofHandles handles: Handles) -> [NGRowRef] {
        handles.map { ref(of: Int32(truncatingIfNeeded: $0)) }
    }

    /// References to the records at indexes (in their order), in one pass.
    func refs<Indexes: Sequence<Int>>(atIndexes indexes: Indexes) -> [NGRowRef] {
        indexes.map { ref(at: $0) }
    }

    /// The index of a reference's record, or -1 if it was removed (its
    /// handle may be another record's now, or every handle after `reset`).
    func index(of ref: NGRowRef) -> Int {
        guard ref == self.ref(of: ref.handle) else { return -1 }
        return index(of: ref.handle)
    }

    /// Whether a handle belongs to a row.
    func contains(_ handle: Int32) -> Bool {
        sequence.contains(handle)
    }

    /// By handle: 0 for a row's handle, `unused` for the others. One
    /// sequential pass, for loops over every row that skip removed ones
    /// (cheaper than `contains` per row, a random read).
    func states(unused: UInt8) -> [UInt8] {
        // Every handle in use (no rows removed since the last reload): all zeros, no pass.
        guard count < capacity else { return [UInt8](repeating: 0, count: capacity) }
        return sequence.states(absent: unused)
    }

    /// Every row's handle in index order (O(rows)).
    var handles: [Int32] { sequence.elements }

    /// The same as `Int`s (for orders of rows), in one pass.
    var integerHandles: [Int] { sequence.integerElements }

    /// The handles of some rows, in index order (by ranges and blocks).
    func handles(of rows: IndexSet) -> [Int32] {
        sequence.handles(at: rows)
    }

    /// Every row's handle in order, with its index (see `NGHandleSequence.forEachHandle`).
    func forEachHandle(_ body: (_ row: Int, _ handle: Int32) -> Void) {
        if isIdentity {
            for row in 0..<count { body(row, Int32(truncatingIfNeeded: row)) }
        } else {
            sequence.forEachHandle(body)
        }
    }

    /// The handles of some rows, in order.
    func forEachHandle(of rows: IndexSet, _ body: (Int32) -> Void) {
        if isIdentity {
            for range in rows.rangeView {
                for row in max(0, range.lowerBound)..<min(count, range.upperBound) { body(Int32(truncatingIfNeeded: row)) }
            }
        } else {
            sequence.forEachHandle(at: rows, body)
        }
    }

    /// The indexes of some handles' rows (those that have one).
    func indexes(of handles: some Sequence<Int32>) -> IndexSet {
        var result = IndexSet()
        for handle in handles {
            let index = index(of: handle)
            if index >= 0 { result.insert(index) }
        }
        return result
    }

    // MARK: Changes

    /// A released handle, or a new one (then `capacity` grows by one).
    private mutating func newHandle() -> Int32 {
        if let reused = reusable.popLast() {
            // Another record: references to the old one no longer find it.
            let index = Int(reused)
            if index >= generations.count { generations.append(contentsOf: repeatElement(0, count: index + 1 - generations.count)) }
            generations[index] &+= 1
            return reused
        }
        let handle = Int32(sequence.capacity)
        sequence.reserve(capacity: sequence.capacity + 1)
        return handle
    }

    /// Inserts a row at an index and returns its handle: a released one, or
    /// a new one (then `capacity` grows by one).
    @discardableResult
    mutating func insert(at index: Int) -> Int32 {
        precondition(index >= 0 && index <= count, "NGRowHandles: insert at \(index) of \(count)")
        isIdentity = false
        let handle = newHandle()
        sequence.insert(handle, at: index)
        return handle
    }

    /// Removes the row at an index and returns its handle (reusable after
    /// `releaseRemoved()`).
    @discardableResult
    mutating func remove(at index: Int) -> Int32 {
        precondition(index >= 0 && index < count, "NGRowHandles: remove at \(index) of \(count)")
        isIdentity = false
        let handle = sequence.remove(at: index)
        removed.append(handle)
        return handle
    }

    /// Removes the row at an index and puts the last row in its place (an
    /// array's swap-remove; it keeps its handle). Returns the removed handle.
    @discardableResult
    mutating func removeReplacingWithLast(at index: Int) -> Int32 {
        precondition(index >= 0 && index < count, "NGRowHandles: remove at \(index) of \(count)")
        isIdentity = false
        let handle = sequence.replaceWithLast(at: index)
        removed.append(handle)
        return handle
    }

    /// Moves a row, like `array.insert(array.remove(at: from), at: to)`; it
    /// keeps its handle.
    mutating func move(from: Int, to: Int) {
        guard from != to else { return }
        isIdentity = false
        sequence.move(from: from, to: to)
    }

    /// The rows as `newOrder` lists them (handles in index order; handles
    /// not listed are removed, `-1` asks for a new row): one pass, for
    /// remappings. Returns the handles of the new rows in index order.
    mutating func replaceOrder(with newOrder: [Int32]) -> [Int32] {
        isIdentity = false
        var listed = [Bool](repeating: false, count: sequence.capacity)
        for handle in newOrder where handle >= 0 { listed[Int(handle)] = true }
        for handle in 0..<sequence.capacity where !listed[handle] && sequence.contains(Int32(handle)) {
            removed.append(Int32(handle))
        }
        var resolved = newOrder
        var added: [Int32] = []
        for index in resolved.indices where resolved[index] < 0 {
            let handle = newHandle()
            resolved[index] = handle
            added.append(handle)
        }
        sequence = NGHandleSequence.changingOrder(resolved.lazy.map { Int($0) }, capacity: sequence.capacity)
        return added
    }

    /// Handles removed since the last release become reusable, and are
    /// returned (their per-row data can be cleared).
    @discardableResult
    mutating func releaseRemoved() -> [Int32] {
        let released = removed
        reusable.append(contentsOf: removed)
        removed = []
        return released
    }

    /// Handles removed since the last release (not reused yet).
    var removedHandles: [Int32] { removed }
}

/// A record kept for longer than a batch: its row handle, and the handle's
/// generation (see `NGRowHandles.ref(at:)`). Its index is -1 once the record
/// is removed, even if a new record got the same handle.
struct NGRowRef: Hashable, Sendable {
    let handle: Int32
    let stamp: UInt64

    /// The reload it was taken in (see `NGRowHandles.epoch`).
    var epoch: UInt32 { UInt32(truncatingIfNeeded: stamp >> 32) }
}
