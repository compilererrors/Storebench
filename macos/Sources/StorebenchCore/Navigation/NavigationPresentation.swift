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
    private struct ReadWatch { var version = UUID(); var readers = 0 }
    private var readWatches: [String: ReadWatch] = [:]
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
    /// When the remembered or saved read for `key` was taken, without decoding it.
    public func readAt(_ key: String) -> Date? { reads[key]?.readAt ?? saved[key]?.readAt }
    private func keep(_ value: Any, key: String, date: Date, cost: Int) -> Int {
        if readWatches[key] != nil { readWatches[key]?.version = UUID() }
        drop(saved: key); readBytes -= reads[key]?.cost ?? 0
        generation += 1
        reads[key] = Read(value: value, readAt: date, generation: generation, cost: cost); readBytes += cost
        touch(key); trimReads()
        return generation
    }
    private func touch(_ key: String) { readOrder.removeAll { $0 == key }; readOrder.append(key) }
    /// Saved reads not yet shown go first, oldest first; then the least recently used reads.
    private func trimReads(keepingSaved protected: String? = nil) {
        while reads.count + saved.count > max(1, readCapacity.count) || retainedReadBytes > readCapacity.bytes,
              let oldest = saved.lazy.filter({ $0.key != protected }).min(by: { $0.value.readAt < $1.value.readAt })?.key { drop(saved: oldest) }
        while !readOrder.isEmpty, reads.count + saved.count > max(1, readCapacity.count) || retainedReadBytes > readCapacity.bytes {
            let key = readOrder.removeFirst(); readBytes -= reads.removeValue(forKey: key)?.cost ?? 0
        }
        if let protected, reads.count + saved.count > max(1, readCapacity.count) || retainedReadBytes > readCapacity.bytes { drop(saved: protected) }
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
    /// Reloads one SQL result after memory eviction. The epoch prevents Clear Cache from restoring an earlier result.
    public var restore: (@Sendable (String, Int) async -> (data: Data, readAt: Date)?)?
    /// The session epoch reads are saved under; nil after Clear Cache until the session's new epoch is known.
    public private(set) var epoch: Int?
    /// Changes on Clear Cache, so a load that started before it does not fill the window again.
    public private(set) var clearCount = 0
    private var saved: [String: (data: Data, readAt: Date)] = [:]
    private var savedBytes = 0
    private var restoring: [String: (id: UUID, task: Task<(data: Data, readAt: Date)?, Never>)] = [:]
    private var hydrationGeneration = 0
    private func drop(saved key: String) { if let value = saved.removeValue(forKey: key) { savedBytes -= value.data.count } }
    /// Hands over saved reads loaded under `epoch`, unless the window was cleared after `clearCount` was read.
    public func preload(_ values: [String: (data: Data, readAt: Date)], epoch: Int, clearCount: Int) {
        guard clearCount == self.clearCount else { return }
        self.epoch = epoch
        for (key, value) in values where reads[key] == nil && (saved[key].map { $0.readAt < value.readAt } ?? true) {
            drop(saved: key); saved[key] = value; savedBytes += value.data.count
        }
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
    /// The epoch to save an encoded read under, or nil when Clear Cache ran or a newer read of the same key replaced it,
    /// so an older read that finishes encoding last never replaces the newer one on disk.
    private func encoded(_ key: String, generation: Int, bytes: Int, clears: Int) -> Int? {
        guard clears == clearCount, reads[key]?.generation == generation else { return nil }
        measured(key, generation: generation, bytes: bytes)
        return epoch
    }
    public func remembered<Value: Decodable>(read key: String, as type: Value.Type) -> (value: Value, readAt: Date)? {
        if let entry = reads[key], let value = entry.value as? Value { touch(key); return (value, entry.readAt) }
        guard let entry = saved[key], let value = try? JSONDecoder().decode(Value.self, from: entry.data) else { return nil }
        _ = keep(value, key: key, date: entry.readAt, cost: entry.data.count * Self.decodedFactor)
        return (value, entry.readAt)
    }

    /// As `remembered(read:as:)`, but a read saved by an earlier launch is decoded away from the main thread, for large reads.
    public func rememberedDecoded<Value: Decodable & Sendable>(read key: String, as type: Value.Type) async -> (value: Value, readAt: Date)? {
        guard !Task.isCancelled else { return nil }
        if let entry = reads[key], let value = entry.value as? Value { touch(key); return (value, entry.readAt) }
        readWatches[key, default: ReadWatch()].readers += 1
        let version = readWatches[key]?.version, hydration = hydrationGeneration, clears = clearCount
        defer {
            readWatches[key]?.readers -= 1
            if readWatches[key]?.readers == 0 { readWatches[key] = nil }
        }
        if saved[key] == nil, let restore, let epoch {
            let work: (id: UUID, task: Task<(data: Data, readAt: Date)?, Never>)
            if let existing = restoring[key] { work = existing }
            else {
                guard restoring.count < 16 else { return nil }
                let id = UUID()
                work = (id, Task { [weak self] in
                    let result = await restore(key, epoch)
                    if self?.restoring[key]?.id == id { self?.restoring[key] = nil }
                    return result
                })
                restoring[key] = work
            }
            let entry = await LocalReadWaiter.value(of: work.task)
            guard !Task.isCancelled, hydration == hydrationGeneration, clears == clearCount, epoch == self.epoch else { return nil }
            if let current = reads[key], let value = current.value as? Value { touch(key); return (value, current.readAt) }
            // A newer result may have arrived and then been evicted while SQL was reading. Never resurrect the earlier value.
            guard readWatches[key]?.version == version else { return nil }
            if let entry, entry.data.count <= readCapacity.bytes, saved[key].map({ $0.readAt < entry.readAt }) ?? true {
                drop(saved: key); saved[key] = entry; savedBytes += entry.data.count
                trimReads(keepingSaved: key)
            }
        }
        guard let entry = saved[key] else { return nil }
        let data = entry.data
        let decoding = Task.detached(priority: .userInitiated) { try? JSONDecoder().decode(Value.self, from: data) }
        let value = await withTaskCancellationHandler { await LocalReadWaiter.value(of: decoding) } onCancel: { decoding.cancel() }
        guard !Task.isCancelled, hydration == hydrationGeneration, clears == clearCount else { return nil }
        if let current = reads[key], let value = current.value as? Value { touch(key); return (value, current.readAt) }
        guard readWatches[key]?.version == version, saved[key]?.data == data else { return nil }
        guard let value else { drop(saved: key); return nil }
        _ = keep(value, key: key, date: entry.readAt, cost: data.count * Self.decodedFactor)
        return (value, entry.readAt)
    }

    /// Under memory pressure: drops every remembered and saved read; each screen reads again when it opens.
    public func releaseReads() {
        hydrationGeneration += 1
        for work in restoring.values { work.task.cancel() }; restoring.removeAll()
        reads.removeAll(); readOrder.removeAll(); saved.removeAll(); readBytes = 0; savedBytes = 0
    }
    /// Clear Cache: drops every read and stops saving until `resume(epoch:)` gives the session's new epoch.
    public func clearReads() { releaseReads(); clearCount += 1; epoch = nil }
    public func resume(epoch: Int) { self.epoch = epoch }
}

/// A caller can leave a shared SQL read or a detached decode immediately without cancelling work another caller needs.
private final class LocalReadWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var completed = false
    private var result: Value?
    private func receive(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        if completed { let result = result; lock.unlock(); continuation.resume(returning: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    private func finish(_ value: Value?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true; result = value
        let continuation = continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(returning: value)
    }
    static func value(of task: Task<Value?, Never>) async -> Value? {
        let waiter = LocalReadWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.receive(continuation)
                Task { waiter.finish(await task.value) }
            }
        } onCancel: { waiter.finish(nil) }
    }
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
        var added = false, newer = true
        let saved = try? storeAccess { store in
            try store.withoutChangeStamp { try store.transaction { current in
                let existing = try current(Self.viewReadMetaNamespace, key)
                added = existing == nil
                // A read from another window that was taken later stays; this older one is not written over it.
                if let existing, let at = (try? JSONText.parse(existing.payload))?["readAt"]?.text.flatMap(ReportTimestamps.date), at > readAt { newer = false; return [] }
                return [.put(namespace: Self.viewReadsNamespace, key: key, json: value.data), .put(namespace: Self.viewReadMetaNamespace, key: key, json: meta.data)]
            } }
        }
        guard saved != nil, newer else { return }
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
                try store.withoutChangeStamp { try store.transaction { current in
                    removed = []
                    var writes: [EncryptedDocumentStore.Write] = []
                    for item in stale where try current(Self.viewReadMetaNamespace, item.key)?.revision == item.revision {
                        removed.insert(item.key)
                        writes.append(.delete(namespace: Self.viewReadsNamespace, key: item.key))
                        if item.revision != nil { writes.append(.delete(namespace: Self.viewReadMetaNamespace, key: item.key)) }
                    }
                    return writes
                } }
            }
            for key in removed { viewReadDigests[key] = nil }
        }
        let kept = valid.map(\.summary).filter { !removed.contains($0.key) }
        viewReadCount = kept.count; viewReadCleanedAt = .now
        return kept
    }
    /// Screen reads saved by earlier launches, newest first, within the Performance setting's count and bytes, for the window to show
    /// while it reads again. Only the chosen values are read from the database.
    /// With `containing`, only reads whose key names it, such as the open app's ID, are read; the rest can follow separately.
    public func savedViewReads(containing part: String? = nil) -> [String: (data: Data, readAt: Date)] {
        guard (try? requireSessionAccess()) != nil else { return [:] }
        var bytes = 0, kept: [String: (data: Data, readAt: Date)] = [:]
        for summary in cleanViewReads() where (part.map { summary.key.contains($0) } ?? true) && kept.count < cacheBudget.savedReads.count && bytes + summary.bytes <= cacheBudget.savedReads.bytes {
            guard let document = try? storeAccess({ try $0.document(namespace: Self.viewReadsNamespace, key: summary.key) }),
                  let value = try? JSONText.parse(document.payload), let at = value["readAt"]?.text.flatMap(ReportTimestamps.date),
                  let data = value["value"]?.text.flatMap({ Data(base64Encoded: $0) }), data.count == summary.bytes else { continue }
            bytes += data.count; kept[summary.key] = (data, at)
        }
        return kept
    }
    /// Reads exactly one saved screen result from encrypted SQL after a window evicts it. Metadata is checked before loading
    /// the value; no full cache scan or cleanup blocks the requested screen.
    public func savedViewRead(key: String, epoch: Int) -> (data: Data, readAt: Date)? {
        guard epoch == viewReadEpoch, !Task.isCancelled, key.utf16.count <= 1_024, (try? requireSessionAccess()) != nil else { return nil }
        return try? storeAccess { store in
            guard let record = try store.document(namespace: Self.viewReadMetaNamespace, key: key),
                  let meta = try? JSONText.parse(record.payload), let at = meta["readAt"]?.text.flatMap(ReportTimestamps.date),
                  at >= Date().addingTimeInterval(-Self.viewReadAge), case .number(let bytes)? = meta["bytes"],
                  bytes >= 0, bytes <= Double(Self.viewReadLimit), bytes.rounded() == bytes,
                  let document = try store.document(namespace: Self.viewReadsNamespace, key: key),
                  let value = try? JSONText.parse(document.payload), value["readAt"] == meta["readAt"],
                  let data = value["value"]?.text.flatMap({ Data(base64Encoded: $0) }), data.count == Int(bytes) else { return nil }
            return (data, at)
        }
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

/// The line under a list shown from an earlier read, so the age of what is on screen is always visible.
public enum ReadAge {
    /// "Last read 5 minutes ago · Reading again…", or empty before anything was read.
    public static func text(readAt: Date?, now: Date = Date(), reading: Bool) -> String {
        guard let readAt else { return reading ? "Reading App Store Connect…" : "" }
        let seconds = max(0, now.timeIntervalSince(readAt))
        let age: String
        switch seconds {
        case ..<60: age = "just now"
        case ..<3_600: let minutes = Int(seconds / 60); age = minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        case ..<86_400: let hours = Int(seconds / 3_600); age = hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        default: let days = Int(seconds / 86_400); age = days == 1 ? "1 day ago" : "\(days) days ago"
        }
        return "Last read " + age + (reading ? " · Reading again…" : "")
    }
}
