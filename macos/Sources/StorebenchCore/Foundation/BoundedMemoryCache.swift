import Foundation

/// Session memory only. Both entry count and estimated retained bytes are bounded.
/// Entries are linked from least to most recently used, so a read, an insert and an eviction each take constant time.
struct BoundedMemoryCache<Key: Hashable, Value> {
    private struct Entry { var value: Value, cost: Int; var previous: Key? = nil, next: Key? = nil }
    private var entries: [Key: Entry] = [:]
    private var oldest: Key?, newest: Key?
    private(set) var cost = 0
    var count: Int { entries.count }
    private(set) var capacity: Int, byteLimit: Int
    init(capacity: Int, byteLimit: Int) { self.capacity = max(0, capacity); self.byteLimit = max(0, byteLimit) }
    init(_ limit: CachePolicy.Limit) { self.init(capacity: limit.count, byteLimit: limit.bytes) }
    /// The value without marking it recently used, for reads that cannot change state, such as drawing a view.
    func peek(_ key: Key) -> Value? { entries[key]?.value }
    mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        if newest != key { unlink(key); link(key) }
        return entry.value
    }
    mutating func insert(_ value: Value, for key: Key, cost nextCost: Int) {
        remove(key)
        guard capacity > 0, nextCost >= 0, nextCost <= byteLimit else { return }
        while count >= capacity || cost > byteLimit - nextCost { guard let first = oldest else { break }; remove(first) }
        entries[key] = Entry(value: value, cost: nextCost); link(key); cost += nextCost
    }
    /// Replaces a kept value and its cost without changing how recently it was used. Does nothing when the key is not kept.
    mutating func update(_ value: Value, for key: Key, cost nextCost: Int) {
        guard let old = entries[key] else { return }
        guard nextCost >= 0, nextCost <= byteLimit else { remove(key); return }
        entries[key]?.value = value; entries[key]?.cost = nextCost; cost += nextCost - old.cost
        while cost > byteLimit { guard let first = oldest else { break }; remove(first) }
    }
    private mutating func unlink(_ key: Key) {
        guard let entry = entries[key] else { return }
        if let previous = entry.previous { entries[previous]?.next = entry.next } else { oldest = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous } else { newest = entry.previous }
    }
    private mutating func link(_ key: Key) {
        entries[key]?.previous = newest; entries[key]?.next = nil
        if let newest { entries[newest]?.next = key } else { oldest = key }
        newest = key
    }
    private mutating func remove(_ key: Key) {
        guard let old = entries[key] else { return }
        unlink(key); entries[key] = nil; cost -= old.cost
    }
    mutating func removeAll() { entries.removeAll(); oldest = nil; newest = nil; cost = 0 }
    mutating func removeAll(where drop: (Value) -> Bool) {
        var key = oldest
        while let current = key, let entry = entries[current] {
            key = entry.next
            if drop(entry.value) { remove(current) }
        }
    }
    /// A smaller limit evicts the least recently used entries at once.
    mutating func resize(_ limit: CachePolicy.Limit) {
        capacity = max(0, limit.count); byteLimit = max(0, limit.bytes)
        while count > capacity || cost > byteLimit { guard let first = oldest else { break }; remove(first) }
    }
}

/// Which cached values each list read returned, by the list's scope, and the stamp of the saved documents it was read under.
/// Only keys are kept, so the values stay owned and bounded by their own cache.
struct SavedListMemo {
    static let capacity = 128
    private var lists: [String: (stamp: String, keys: [String])] = [:]
    /// The cache keys of the list read for `scope`, in its order, when it was read under `stamp`.
    func keys(_ scope: String, stamp: String) -> [String]? {
        guard let list = lists[scope], list.stamp == stamp else { return nil }
        return list.keys
    }
    mutating func keep(_ keys: [String], for scope: String, stamp: String) {
        if lists.count >= Self.capacity, lists[scope] == nil { lists.removeAll() }
        lists[scope] = (stamp, keys)
    }
    mutating func removeAll() { lists.removeAll() }
}
