import Foundation

/// An order of distinct row handles (see `NGRowHandles`) kept in blocks, so
/// inserting or removing one shifts one block, not the whole order; each
/// handle knows its block and its place in it. Blocks have stable ids
/// (splitting one doesn't renumber the others' handles). The table's rows in
/// data source order are one (`NGRowHandles`), and so are its sorted rows: a
/// row whose sort value changed is taken out and put back where it goes, by
/// binary search, instead of copying the whole order.
///
/// Where each block starts is a Fenwick tree over the blocks' lengths in
/// order: an insert or a remove updates it in O(log blocks), and a position
/// is found by descending it (a flat array of starts cost a pass over every
/// block after the change; reading it was no faster than the tree's
/// descent, one read a step).
struct NGHandleSequence: Sendable {
    /// Handles in a block before it is split in two. An insert or a remove
    /// shifts and renumbers half a block on average, and a split rebuilds
    /// the tree (every `maximumBlock / 2` inserts into a block).
    let maximumBlock: Int

    /// Handles in order, by block id; `order` lists the block ids in order.
    private var blocks: [[Int32]] = []
    private var order: [Int32] = []
    /// Each block's handle count, by id.
    private var lengths: [Int] = []
    /// Each block's place in `order`, by id (-1: free).
    private var positionOfBlock: [Int32] = []
    /// The Fenwick tree of the lengths in `order` (1-based: `tree[i]` sums
    /// the `i & -i` positions ending at `i - 1`).
    private var tree: [Int] = [0]
    /// Ids of blocks emptied and out of `order`, for the next split (a feed
    /// that inserts at one end and removes at the other would grow `blocks`
    /// forever).
    private var freeBlocks: [Int32] = []
    /// By handle: its block id and its place in the block (-1: not in it).
    private var blockOfHandle: [Int32] = []
    private var placeOfHandle: [Int32] = []

    /// Blocks kept, in use or free (for tests).
    var blockCountForTesting: Int { blocks.count }

    /// Number of handles in the sequence.
    private(set) var count = 0

    /// Handles there may be: the size of the lookups by handle.
    var capacity: Int { blockOfHandle.count }

    init(maximumBlock: Int = 512) {
        self.maximumBlock = maximumBlock
    }

    /// The handles in this order (distinct, below `capacity`).
    init(_ handles: some Collection<Int>, capacity: Int, maximumBlock: Int = 512) {
        self.maximumBlock = maximumBlock
        blockOfHandle = [Int32](repeating: -1, count: capacity)
        placeOfHandle = [Int32](repeating: -1, count: capacity)
        var block: [Int32] = []
        block.reserveCapacity(maximumBlock / 2)
        func close() {
            let id = Int32(blocks.count)
            order.append(id)
            for (place, handle) in block.enumerated() {
                blockOfHandle[Int(handle)] = id
                placeOfHandle[Int(handle)] = Int32(place)
            }
            count += block.count
            blocks.append(block)
            lengths.append(block.count)
            block = []
            block.reserveCapacity(maximumBlock / 2)
        }
        for handle in handles {
            block.append(Int32(truncatingIfNeeded: handle))
            if block.count == maximumBlock / 2 { close() }
        }
        if !block.isEmpty { close() }
        rebuildTree()
    }

    /// An order of rows that changes in many places at once (sorted rows, a
    /// feed's rows). Blocks of 512: measured against 256 and 1,024 (see
    /// NGHandleSequenceBenchmark); with the tree, their size no longer
    /// follows the rows'.
    static func changingOrder(_ handles: some Collection<Int>, capacity: Int) -> NGHandleSequence {
        NGHandleSequence(handles, capacity: capacity, maximumBlock: 512)
    }

    /// Room for handles below `capacity`.
    mutating func reserve(capacity newCapacity: Int) {
        guard newCapacity > blockOfHandle.count else { return }
        blockOfHandle.append(contentsOf: repeatElement(-1, count: newCapacity - blockOfHandle.count))
        placeOfHandle.append(contentsOf: repeatElement(-1, count: newCapacity - placeOfHandle.count))
    }

    // MARK: The tree

    /// The tree of the lengths of `order` again (O(blocks): when `order` changes).
    private mutating func rebuildTree() {
        let blockCount = order.count
        positionOfBlock = [Int32](repeating: -1, count: blocks.count)
        tree = [Int](repeating: 0, count: blockCount + 1)

        order.withUnsafeBufferPointer { order in
            lengths.withUnsafeBufferPointer { lengths in
                positionOfBlock.withUnsafeMutableBufferPointer { positions in
                    tree.withUnsafeMutableBufferPointer { tree in
                        for position in 0..<blockCount {
                            let id = Int(order[position])
                            positions[id] = Int32(truncatingIfNeeded: position)
                            tree[position &+ 1] = lengths[id]
                        }
                        // Each node adds itself to its parent: linear.
                        var node = 1
                        while node <= blockCount {
                            let parent = node &+ (node & -node)
                            if parent <= blockCount { tree[parent] &+= tree[node] }
                            node &+= 1
                        }
                    }
                }
            }
        }
    }

    /// Adds to the length at an order position.
    private mutating func addToTree(_ delta: Int, at position: Int) {
        tree.withUnsafeMutableBufferPointer { tree in
            var node = position &+ 1
            let end = tree.count
            while node < end {
                tree[node] &+= delta
                node &+= node & -node
            }
        }
    }

    /// The handles before an order position (the start of the block there).
    private func start(atPosition position: Int) -> Int {
        tree.withUnsafeBufferPointer { tree in
            var node = position, sum = 0
            while node > 0 {
                sum &+= tree[node]
                node &-= node & -node
            }
            return sum
        }
    }

    // MARK: Lookups

    /// The handle at a position.
    func handle(at index: Int) -> Int32 {
        let (position, place) = locate(index)
        return blocks[Int(order[position])][place]
    }

    /// Appends the handles at positions given in ascending order (below
    /// `count`): one walk over the blocks instead of a search of the tree
    /// for each position.
    func appendHandles(atAscending positions: [Int32], to result: inout [Int32]) {
        result.reserveCapacity(result.count &+ positions.count)
        var position = 0, start = 0
        var end = order.isEmpty ? 0 : lengths[Int(order[0])]
        for index in positions {
            let index = Int(index)
            while index >= end {
                position &+= 1
                start = end
                end &+= lengths[Int(order[position])]
            }
            result.append(blocks[Int(order[position])][index &- start])
        }
    }

    /// The position of a handle, or -1 if it isn't in the sequence.
    func index(of handle: Int32) -> Int {
        let handle = Int(handle)
        guard handle >= 0, handle < blockOfHandle.count else { return -1 }
        let id = blockOfHandle[handle]
        guard id >= 0 else { return -1 }
        return start(atPosition: Int(positionOfBlock[Int(id)])) &+ Int(placeOfHandle[handle])
    }

    /// Whether a handle is in the sequence.
    func contains(_ handle: Int32) -> Bool {
        handle >= 0 && Int(handle) < blockOfHandle.count && blockOfHandle[Int(handle)] >= 0
    }

    /// Every handle in order (O(count)).
    var elements: [Int32] {
        var result: [Int32] = []
        result.reserveCapacity(count)
        for id in order { result.append(contentsOf: blocks[Int(id)]) }
        return result
    }

    /// The same as `Int`s (for orders of rows), in one pass.
    var integerElements: [Int] {
        [Int](unsafeUninitializedCapacity: count) { buffer, initialized in
            var written = 0
            for id in order {
                blocks[Int(id)].withUnsafeBufferPointer { block in
                    for handle in block {
                        buffer[written] = Int(handle)
                        written += 1
                    }
                }
            }
            initialized = written
        }
    }

    /// Every handle in order with its position, without an array of them.
    func forEachHandle(_ body: (_ position: Int, _ handle: Int32) -> Void) {
        var position = 0
        for id in order {
            blocks[Int(id)].withUnsafeBufferPointer { block in
                for handle in block {
                    body(position, handle)
                    position += 1
                }
            }
        }
    }

    /// The handles at some positions, in order, without an array of them.
    func forEachHandle(at positions: IndexSet, _ body: (Int32) -> Void) {
        for range in positions.rangeView {
            let lower = max(0, range.lowerBound), upper = min(count, range.upperBound)
            guard lower < upper else { continue }
            var (position, place) = locate(lower)
            var index = lower
            while index < upper {
                let take = blocks[Int(order[position])].withUnsafeBufferPointer { block in
                    let take = min(block.count - place, upper - index)
                    for offset in place..<(place + take) { body(block[offset]) }
                    return take
                }
                index += take
                position += 1
                place = 0
            }
        }
    }

    /// The handles at some positions, in order (by ranges and blocks).
    func handles(at positions: IndexSet) -> [Int32] {
        var result: [Int32] = []
        result.reserveCapacity(positions.count)
        for range in positions.rangeView {
            let lower = max(0, range.lowerBound), upper = min(count, range.upperBound)
            guard lower < upper else { continue }
            var (position, place) = locate(lower)
            var index = lower
            while index < upper {
                let block = blocks[Int(order[position])]
                let take = min(block.count - place, upper - index)
                result.append(contentsOf: block[place..<(place + take)])
                index += take
                position += 1
                place = 0
            }
        }
        return result
    }

    /// By handle: 0 for one in the sequence, `absent` for the others. One
    /// sequential pass (cheaper than `contains` per handle, a random read).
    func states(absent: UInt8) -> [UInt8] {
        blockOfHandle.map { $0 >= 0 ? 0 : absent }
    }

    /// The first position whose handle satisfies `predicate`, which is false
    /// for a prefix of the sequence and true after it (`count` if none):
    /// a binary search over the blocks, then within one.
    func partitioningIndex(where predicate: (Int32) -> Bool) -> Int {
        // The first block whose last handle satisfies it.
        var low = 0, high = order.count
        while low < high {
            let middle = (low + high) / 2
            let block = blocks[Int(order[middle])]
            if let last = block.last, !predicate(last) { low = middle + 1 } else { high = middle }
        }
        guard low < order.count else { return count }
        let id = Int(order[low])
        return blocks[id].withUnsafeBufferPointer { block in
            var first = 0, end = block.count
            while first < end {
                let middle = (first + end) / 2
                if predicate(block[middle]) { end = middle } else { first = middle + 1 }
            }
            return first
        } + start(atPosition: low)
    }

    /// The order position and place of a position (the last block's end for `count`).
    private func locate(_ index: Int) -> (position: Int, place: Int) {
        if index >= count {
            let last = order.count - 1
            return (last, lengths[Int(order[last])])
        }
        // Down the tree: the most positions whose handles are all before the index.
        return tree.withUnsafeBufferPointer { tree in
            let blockCount = tree.count &- 1
            var position = 0, remaining = index
            var step = 1
            while step &* 2 <= blockCount { step &*= 2 }
            while step > 0 {
                let next = position &+ step
                if next <= blockCount, tree[next] <= remaining {
                    position = next
                    remaining &-= tree[next]
                }
                step >>= 1
            }
            return (position, remaining)
        }
    }

    // MARK: Changes

    /// Inserts a handle (below `capacity`, not in the sequence) at a position.
    mutating func insert(_ handle: Int32, at index: Int) {
        precondition(index >= 0 && index <= count, "NGHandleSequence: insert at \(index) of \(count)")
        if order.isEmpty {
            let id = freeBlocks.popLast().map(Int.init) ?? blocks.count
            if id == blocks.count {
                blocks.append([])
                lengths.append(0)
            }
            order.append(Int32(id))
            rebuildTree()
        }
        // At the end of a block rather than the start of the next one.
        let position: Int, place: Int
        if index == count {
            position = order.count - 1
            place = blocks[Int(order[position])].count
        } else {
            (position, place) = locate(index)
        }
        let id = Int(order[position])
        blocks[id].insert(handle, at: place)
        lengths[id] &+= 1
        blockOfHandle[Int(handle)] = Int32(id)
        renumberPlaces(inBlock: id, from: place)
        count &+= 1
        addToTree(1, at: position)
        if blocks[id].count > maximumBlock { split(at: position) }
    }

    /// Removes the handle at a position and returns it.
    @discardableResult
    mutating func remove(at index: Int) -> Int32 {
        precondition(index >= 0 && index < count, "NGHandleSequence: remove at \(index) of \(count)")
        let (position, place) = locate(index)
        return remove(position: position, place: place)
    }

    /// Removes the handle at a place of the block at an order position.
    @discardableResult
    private mutating func remove(position: Int, place: Int) -> Int32 {
        let id = Int(order[position])
        let handle = blocks[id].remove(at: place)
        lengths[id] &-= 1
        blockOfHandle[Int(handle)] = -1
        placeOfHandle[Int(handle)] = -1
        renumberPlaces(inBlock: id, from: place)
        count &-= 1
        if blocks[id].isEmpty, order.count > 1 {
            order.remove(at: position)
            freeBlocks.append(Int32(id))
            rebuildTree()
        } else {
            addToTree(-1, at: position)
        }
        return handle
    }

    /// Removes the handle at a position and puts the last handle in its
    /// place (an array's swap-remove): nothing shifts, one block's count
    /// changes. Returns the removed handle.
    @discardableResult
    mutating func replaceWithLast(at index: Int) -> Int32 {
        precondition(index >= 0 && index < count, "NGHandleSequence: remove at \(index) of \(count)")
        guard index < count &- 1 else { return remove(at: index) }
        let (position, place) = locate(index)
        let id = Int(order[position])
        let removed = blocks[id][place]
        let lastPosition = order.count &- 1
        let lastID = Int(order[lastPosition])
        let moved = blocks[lastID].removeLast()
        lengths[lastID] &-= 1
        blocks[id][place] = moved
        blockOfHandle[Int(moved)] = Int32(id)
        placeOfHandle[Int(moved)] = Int32(truncatingIfNeeded: place)
        blockOfHandle[Int(removed)] = -1
        placeOfHandle[Int(removed)] = -1
        count &-= 1
        if blocks[lastID].isEmpty, order.count > 1 {
            order.removeLast()
            freeBlocks.append(Int32(lastID))
            rebuildTree()
        } else {
            addToTree(-1, at: lastPosition)
        }
        return removed
    }

    /// Removes a handle if it is in the sequence; whether it was.
    @discardableResult
    mutating func remove(_ handle: Int32) -> Bool {
        guard contains(handle) else { return false }
        // Its block, place and the block's position are known: no search.
        let id = Int(blockOfHandle[Int(handle)])
        remove(position: Int(positionOfBlock[id]), place: Int(placeOfHandle[Int(handle)]))
        return true
    }

    /// Moves a handle, like `array.insert(array.remove(at: from), at: to)`.
    mutating func move(from: Int, to: Int) {
        guard from != to else { return }
        insert(remove(at: from), at: to)
    }

    private mutating func renumberPlaces(inBlock id: Int, from place: Int) {
        let block = blocks[id]
        guard place < block.count else { return }
        placeOfHandle.withUnsafeMutableBufferPointer { places in
            block.withUnsafeBufferPointer { block in
                var index = place
                while index < block.count {
                    places[Int(block[index])] = Int32(truncatingIfNeeded: index)
                    index &+= 1
                }
            }
        }
    }

    /// Splits the block at an order position in two halves.
    private mutating func split(at position: Int) {
        let id = Int(order[position])
        let half = blocks[id].count / 2
        let tail = Array(blocks[id][half...])
        blocks[id].removeSubrange(half...)
        lengths[id] = half
        let newID: Int32
        if let free = freeBlocks.popLast() {
            newID = free
            blocks[Int(free)] = tail
            lengths[Int(free)] = tail.count
        } else {
            newID = Int32(blocks.count)
            blocks.append(tail)
            lengths.append(tail.count)
        }
        order.insert(newID, at: position + 1)
        for (place, handle) in tail.enumerated() {
            blockOfHandle[Int(handle)] = newID
            placeOfHandle[Int(handle)] = Int32(place)
        }
        rebuildTree()
    }
}
