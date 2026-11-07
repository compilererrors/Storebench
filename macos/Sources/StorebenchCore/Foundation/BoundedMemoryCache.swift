import Foundation

/// Session memory only. Both entry count and estimated retained bytes are bounded.
struct BoundedMemoryCache<Key: Hashable, Value> {
    private struct Entry { let value: Value, cost: Int }
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private(set) var cost = 0
    var count: Int { entries.count }
    private(set) var capacity: Int, byteLimit: Int
    init(capacity: Int, byteLimit: Int) { self.capacity = max(0, capacity); self.byteLimit = max(0, byteLimit) }
    init(_ limit: CachePolicy.Limit) { self.init(capacity: limit.count, byteLimit: limit.bytes) }
    /// The value without marking it recently used, for reads that cannot change state, such as drawing a view.
    func peek(_ key: Key) -> Value? { entries[key]?.value }
    mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key); return entry.value
    }
    mutating func insert(_ value: Value, for key: Key, cost nextCost: Int) {
        remove(key)
        guard capacity > 0, nextCost >= 0, nextCost <= byteLimit else { return }
        while count >= capacity || cost > byteLimit - nextCost { guard let first = order.first else { break }; remove(first) }
        entries[key] = Entry(value: value, cost: nextCost); order.append(key); cost += nextCost
    }
    private mutating func remove(_ key: Key) { if let old = entries.removeValue(forKey: key) { cost -= old.cost }; order.removeAll { $0 == key } }
    mutating func removeAll() { entries.removeAll(); order.removeAll(); cost = 0 }
    mutating func removeAll(where drop: (Value) -> Bool) { for key in order where entries[key].map({ drop($0.value) }) == true { remove(key) } }
    /// A smaller limit evicts the least recently used entries at once.
    mutating func resize(_ limit: CachePolicy.Limit) {
        capacity = max(0, limit.count); byteLimit = max(0, limit.bytes)
        while count > capacity || cost > byteLimit { guard let first = order.first else { break }; remove(first) }
    }
}
