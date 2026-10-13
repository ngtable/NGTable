import Foundation

/// Rows by identity, for `NGTableView.row(forIdentifier:)`: identities to row
/// handles (see `NGRowHandles`), so a lookup stays two steps however rows
/// were inserted, removed or moved since. Built from all rows on the first
/// lookup; removed rows leave it at once, inserted rows are read on the next
/// lookup (within a batch the data source may not be there yet).
struct NGIdentityIndex {
    private var handleOfIdentity: [AnyHashable: Int32] = [:]
    /// By handle: its identity, if it has one in the index.
    private var identityOfHandle: [AnyHashable?] = []
    /// Inserted rows whose identities are still to be read.
    private(set) var pending: [Int32] = []
    /// The handles of each identity that more than one row has: when the
    /// one in `handleOfIdentity` goes, another takes its place at once.
    private var copies: [AnyHashable: Set<Int32>] = [:]

    /// The handle with an identity, or `nil`.
    func handle(of identity: AnyHashable) -> Int32? {
        handleOfIdentity[identity]
    }

    /// A handle's identity, if it has one in the index.
    func identity(of handle: Int32) -> AnyHashable? {
        Int(handle) < identityOfHandle.count ? identityOfHandle[Int(handle)] : nil
    }

    /// Adds a row's identity (with duplicates, the last one read wins).
    mutating func set(_ identity: AnyHashable, for handle: Int32) {
        let index = Int(handle)
        if index >= identityOfHandle.count {
            identityOfHandle.append(contentsOf: repeatElement(nil, count: index + 1 - identityOfHandle.count))
        }
        if identityOfHandle[index] != nil { remove(handle) }
        identityOfHandle[index] = identity
        // One lookup: the row before with it, if any.
        if let other = handleOfIdentity.updateValue(handle, forKey: identity), other != handle {
            copies[identity, default: [other]].insert(handle)
        }
    }

    /// A removed row: its identity goes (its handle may be reused).
    mutating func remove(_ handle: Int32) {
        let index = Int(handle)
        guard index < identityOfHandle.count, let identity = identityOfHandle[index] else { return }
        identityOfHandle[index] = nil
        if var others = copies[identity] {
            // Others have it still: one of them is found from now on.
            others.remove(handle)
            if handleOfIdentity[identity] == handle { handleOfIdentity[identity] = others.max() }
            copies[identity] = others.count > 1 ? others : nil
        } else if handleOfIdentity[identity] == handle {
            handleOfIdentity[identity] = nil
        }
    }

    /// An inserted row, read on the next lookup.
    mutating func noteInserted(_ handle: Int32) {
        remove(handle)
        pending.append(handle)
    }

    /// The inserted rows to read, taken.
    mutating func takePending() -> [Int32] {
        defer { pending = [] }
        return pending
    }

    mutating func reserve(_ count: Int) {
        handleOfIdentity.reserveCapacity(count)
        identityOfHandle.reserveCapacity(count)
    }
}
