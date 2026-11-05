import Foundation

/// Presentation only, owned by this unlocked window and bounded by its history entries.
@MainActor public final class NavigationPresentation {
    struct Entry {
        var offset: CGPoint = .zero
        var collections: [String: Any] = [:]
    }
    private var entries: [UUID: Entry] = [:]
    private var allowedEntries: Set<UUID>?
    public init() {}
    var count: Int { entries.count }
    public var retainedEntryCount: Int { entries.count }
    public var retainedCollectionCount: Int { entries.values.reduce(0) { $0 + $1.collections.count } }
    public var capture: (() -> Void)?
    /// Stops the page restoring its saved position, so a scroll to a named card, such as App Privacy, is kept and becomes the entry's position.
    public var keepScroll: (() -> Void)?
    public func offset(_ id: UUID) -> CGPoint { entries[id]?.offset ?? .zero }
    public func save(_ offset: CGPoint, for id: UUID) {
        guard allowedEntries?.contains(id) != false else { return }
        entries[id, default: Entry()].offset = offset
    }
    public func collection<Value>(_ key: String, entry: UUID, as type: Value.Type) -> Value? { entries[entry]?.collections[key] as? Value }
    public func saveCollection<Value>(_ value: Value, key: String, entry: UUID) {
        guard allowedEntries?.contains(entry) != false else { return }
        if entries[entry]?.collections.count ?? 0 >= 512, entries[entry]?.collections[key] == nil { return }
        entries[entry, default: Entry()].collections[key] = value
    }
    public func retain(_ ids: Set<UUID>) { allowedEntries = ids; entries = entries.filter { ids.contains($0.key) } }

    /// The last result each screen read in this window, so returning to it shows that result at once while the screen reads again.
    /// Shared by every history entry, bounded by count and estimated bytes, and dropped with the window when the workspace locks.
    /// `readBudget` is the standard bound; `readCapacity` follows the Performance setting and evicts at once when it shrinks.
    public static let readLimit = 48
    public static let readBudget = CachePolicy.Limit(count: readLimit, bytes: 24 * 1_048_576)
    /// The estimate for a read until its encoded size is known, and for reads that cannot be encoded.
    static let unmeasuredCost = 16 * 1_024
    /// Decoded values take more memory than their JSON, as with decoded revisions.
    static let decodedFactor = 3
    public var readCapacity = NavigationPresentation.readBudget { didSet { trimReads() } }
    private struct Read { let value: Any, readAt: Date, generation: Int; var cost: Int }
    private var reads: [String: Read] = [:]
    private var readOrder: [String] = []
    private var readBytes = 0, generation = 0
    public var rememberedReadCount: Int { reads.count + saved.count }
    /// Estimated bytes this window keeps: decoded reads and saved reads not yet shown.
    public var retainedReadBytes: Int { readBytes + savedBytes }
    public func remember<Value>(_ value: Value, read key: String, at date: Date = Date()) { _ = keep(value, key: key, date: date, cost: Self.unmeasuredCost) }
    public func remembered<Value>(read key: String, as type: Value.Type) -> (value: Value, readAt: Date)? {
        guard let entry = reads[key], let value = entry.value as? Value else { return nil }
        touch(key); return (value, entry.readAt)
    }
    private func keep(_ value: Any, key: String, date: Date, cost: Int) -> Int {
        drop(saved: key); readBytes -= reads[key]?.cost ?? 0
        generation += 1
        reads[key] = Read(value: value, readAt: date, generation: generation, cost: cost); readBytes += cost
        touch(key); trimReads()
        return generation
    }
    private func touch(_ key: String) { readOrder.removeAll { $0 == key }; readOrder.append(key) }
    /// Saved reads not yet shown go first, oldest first; then the least recently used reads.
    private func trimReads() {
        while reads.count + saved.count > max(1, readCapacity.count) || retainedReadBytes > readCapacity.bytes,
              let oldest = saved.min(by: { $0.value.readAt < $1.value.readAt })?.key { drop(saved: oldest) }
        while !readOrder.isEmpty, reads.count > max(1, readCapacity.count) || readBytes > readCapacity.bytes {
            let key = readOrder.removeFirst(); readBytes -= reads.removeValue(forKey: key)?.cost ?? 0
        }
    }
    /// The encoded size of a kept read, once known; a read replaced or dropped since is left alone.
    private func measured(_ key: String, generation: Int, bytes: Int) {
        guard let entry = reads[key], entry.generation == generation else { return }
        readBytes += bytes * Self.decodedFactor - entry.cost; reads[key]?.cost = bytes * Self.decodedFactor
        trimReads()
    }

    /// Reads that can be encoded are also written to the encrypted database, so the next launch shows them at once
    /// while each screen reads again. `persist` writes one with the session's view-read epoch; `preload` hands over what an earlier launch saved.
    public var persist: (@Sendable (String, Data, Date, Int) -> Void)?
    /// The session epoch reads are saved under; nil after Clear Cache until the session's new epoch is known.
    public private(set) var epoch: Int?
    /// Changes on Clear Cache, so a load that started before it does not fill the window again.
    public private(set) var clearCount = 0
    private var saved: [String: (data: Data, readAt: Date)] = [:]
    private var savedBytes = 0
    private func drop(saved key: String) { if let value = saved.removeValue(forKey: key) { savedBytes -= value.data.count } }
    /// Hands over saved reads loaded under `epoch`, unless the window was cleared after `clearCount` was read.
    public func preload(_ values: [String: (data: Data, readAt: Date)], epoch: Int, clearCount: Int) {
        guard clearCount == self.clearCount else { return }
        self.epoch = epoch
        for (key, value) in values where reads[key] == nil { drop(saved: key); saved[key] = value; savedBytes += value.data.count }
        trimReads()
    }
    public func remember<Value: Codable & Sendable>(_ value: Value, read key: String, at date: Date = Date()) {
        let generation = keep(value, key: key, date: date, cost: Self.unmeasuredCost), clears = clearCount, persist = persist
        // Encoding a large read never holds up the interface. A read from before Clear Cache is neither counted nor saved.
        Task.detached(priority: .utility) { [weak self] in
            guard let data = try? JSONEncoder().encode(value) else { return }
            let epoch = await self?.encoded(key, generation: generation, bytes: data.count, clears: clears)
            if let persist, let epoch { persist(key, data, date, epoch) }
        }
    }
    private func encoded(_ key: String, generation: Int, bytes: Int, clears: Int) -> Int? {
        guard clears == clearCount else { return nil }
        measured(key, generation: generation, bytes: bytes)
        return epoch
    }
    public func remembered<Value: Decodable>(read key: String, as type: Value.Type) -> (value: Value, readAt: Date)? {
        if let entry = reads[key], let value = entry.value as? Value { touch(key); return (value, entry.readAt) }
        guard let entry = saved[key], let value = try? JSONDecoder().decode(Value.self, from: entry.data) else { return nil }
        _ = keep(value, key: key, date: entry.readAt, cost: entry.data.count * Self.decodedFactor)
        return (value, entry.readAt)
    }

    /// Under memory pressure: drops every remembered and saved read; each screen reads again when it opens.
    public func releaseReads() {
        reads.removeAll(); readOrder.removeAll(); saved.removeAll(); readBytes = 0; savedBytes = 0
    }
    /// Clear Cache: drops every read and stops saving until `resume(epoch:)` gives the session's new epoch.
    public func clearReads() { releaseReads(); clearCount += 1; epoch = nil }
    public func resume(epoch: Int) { self.epoch = epoch }
}

extension WorkspaceSession {
    static let viewReadLimit = 8_000_000
    static let viewReadsNamespace = "view_reads", viewReadMetaNamespace = "view_read_meta"
    /// Saves one screen's last read in the encrypted database; an unchanged read is not written again, and nothing is saved
    /// for an `epoch` before the last Clear Cache. A small record beside it holds the read time and size, so cleanup and
    /// the next launch choose what to keep without reading every saved value.
    public func saveViewRead(key: String, data: Data, readAt: Date, epoch: Int) {
        guard epoch == viewReadEpoch, data.count <= Self.viewReadLimit, key.utf16.count <= 1_024, (try? requireSessionAccess()) != nil else { return }
        let digest = JSONText.string(key + "\u{0}" + data.base64EncodedString()).rawSHA256
        guard viewReadDigests[key] != digest else { return }
        let at = ReportTimestamps.isoUtcText(readAt)
        let value = JSONText.object([("readAt", .string(at)), ("value", .string(data.base64EncodedString()))])
        let meta = JSONText.object([("readAt", .string(at)), ("bytes", .number(Double(data.count)))])
        var added = false
        let saved = try? storeAccess { store in
            try store.transaction { current in
                added = try current(Self.viewReadMetaNamespace, key) == nil
                return [.put(namespace: Self.viewReadsNamespace, key: key, json: value.data), .put(namespace: Self.viewReadMetaNamespace, key: key, json: meta.data)]
            }
        }
        guard saved != nil else { return }
        viewReadDigests[key] = digest
        if added, let count = viewReadCount { viewReadCount = count + 1 }
        let due = viewReadCleanedAt.map { ContinuousClock.now - $0 > Self.viewReadCleanupInterval } ?? true
        if due || (viewReadCount ?? .max) > Self.viewReadKeep { _ = cleanViewReads() }
    }
    /// Saved screen reads older than this, or beyond the newest `viewReadKeep`, are deleted when a window loads them,
    /// when a save takes the count past the limit, and at least once per `viewReadCleanupInterval` while saving.
    static let viewReadAge: TimeInterval = 30 * 86_400
    static let viewReadKeep = 1_000
    static let viewReadCleanupInterval: Duration = .seconds(3_600)

    struct ViewReadSummary { let key: String, readAt: Date, bytes: Int }
    /// Deletes saved screen reads past the age and count limits, and halves left without their record, from the small
    /// records alone. A record changed after it was listed is kept. Returns what remains, newest first.
    func cleanViewReads() -> [ViewReadSummary] {
        guard let (keys, records) = try? storeAccess({ store in (Set(try store.keys(namespace: Self.viewReadsNamespace)), try store.documents(namespace: Self.viewReadMetaNamespace)) }) else { return [] }
        let oldest = Date().addingTimeInterval(-Self.viewReadAge)
        var stale: [(key: String, revision: Int?)] = [], valid: [(summary: ViewReadSummary, revision: Int)] = []
        for record in records {
            guard keys.contains(record.key), let value = try? JSONText.parse(record.payload), let at = value["readAt"]?.text.flatMap(ReportTimestamps.date),
                  case .number(let bytes)? = value["bytes"], bytes >= 0, bytes <= Double(Self.viewReadLimit) else { stale.append((record.key, record.revision)); continue }
            valid.append((ViewReadSummary(key: record.key, readAt: at, bytes: Int(bytes)), record.revision))
        }
        valid.sort { $0.summary.readAt > $1.summary.readAt }
        for (offset, item) in valid.enumerated() where offset >= Self.viewReadKeep || item.summary.readAt < oldest { stale.append((item.summary.key, item.revision)) }
        let recorded = Set(records.map(\.key))
        for key in keys where !recorded.contains(key) { stale.append((key, nil)) }
        var removed = Set<String>()
        if !stale.isEmpty {
            _ = try? storeAccess { store in
                try store.transaction { current in
                    removed = []
                    var writes: [EncryptedDocumentStore.Write] = []
                    for item in stale where try current(Self.viewReadMetaNamespace, item.key)?.revision == item.revision {
                        removed.insert(item.key)
                        writes.append(.delete(namespace: Self.viewReadsNamespace, key: item.key))
                        if item.revision != nil { writes.append(.delete(namespace: Self.viewReadMetaNamespace, key: item.key)) }
                    }
                    return writes
                }
            }
            for key in removed { viewReadDigests[key] = nil }
        }
        let kept = valid.map(\.summary).filter { !removed.contains($0.key) }
        viewReadCount = kept.count; viewReadCleanedAt = .now
        return kept
    }
    /// Screen reads saved by earlier launches, newest first, within the Performance setting's count and bytes, for the window to show
    /// while it reads again. Only the chosen values are read from the database.
    public func savedViewReads() -> [String: (data: Data, readAt: Date)] {
        guard (try? requireSessionAccess()) != nil else { return [:] }
        var bytes = 0, kept: [String: (data: Data, readAt: Date)] = [:]
        for summary in cleanViewReads() where kept.count < cacheBudget.savedReads.count && bytes + summary.bytes <= cacheBudget.savedReads.bytes {
            guard let document = try? storeAccess({ try $0.document(namespace: Self.viewReadsNamespace, key: summary.key) }),
                  let value = try? JSONText.parse(document.payload), let at = value["readAt"]?.text.flatMap(ReportTimestamps.date),
                  let data = value["value"]?.text.flatMap({ Data(base64Encoded: $0) }), data.count == summary.bytes else { continue }
            bytes += data.count; kept[summary.key] = (data, at)
        }
        return kept
    }
    /// Clear Cache: removes every saved screen read and starts a new epoch, so reads captured before it are not saved again.
    func clearViewReads() {
        viewReadEpoch += 1; viewReadDigests.removeAll(); viewReadCount = 0; viewReadCleanedAt = .now
        _ = try? storeAccess { store in
            try store.transaction { _ in
                try store.keys(namespace: Self.viewReadsNamespace).map { .delete(namespace: Self.viewReadsNamespace, key: $0) }
                    + store.keys(namespace: Self.viewReadMetaNamespace).map { .delete(namespace: Self.viewReadMetaNamespace, key: $0) }
            }
        }
    }
}
