import Foundation

/// One bounded, short-lived response store per workspace session, shared by read-only screens.
/// Publishing clients never use this cache; local revisions and media keep their existing encrypted stores.
/// The size and lifetime follow the Performance setting; responses stay in memory only.
public actor AppStoreReadCache {
    private struct Entry { let bytes: Data, stored: ContinuousClock.Instant }
    private var entries: BoundedMemoryCache<String, Entry>
    private var pending: [String: (id: UUID, task: Task<Data, Error>)] = [:]
    private var lifetime: Duration
    private var generation: UInt64 = 0
    public init(limit: CachePolicy.Limit = CachePolicy.standardBudget.appleReads, lifetime: Duration = CachePolicy.standardBudget.appleReadLifetime) {
        entries = BoundedMemoryCache(limit); self.lifetime = lifetime
    }
    /// A smaller budget or shorter lifetime applies to reads already kept.
    public func configure(limit: CachePolicy.Limit, lifetime: Duration) {
        self.lifetime = lifetime; entries.resize(limit); dropExpired()
    }
    /// Frees kept responses under memory pressure. Reads in flight continue for their screens.
    public func trim() { entries.removeAll() }
    /// Bytes of kept responses, for the Performance setting.
    public var retainedBytes: Int { entries.cost }
    private func dropExpired() { let now = ContinuousClock.now; entries.removeAll { now - $0.stored >= lifetime } }

    /// How often a reader reads again when refreshes elsewhere keep replacing its read.
    static let rereads = 3

    /// A refresh elsewhere replaces reads in flight. Their readers read again instead of failing or showing the older answer.
    func read(_ key: String, load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let starting = generation
            do { return try await read(key, starting: starting, load: load) } catch {
                guard starting != generation, !Task.isCancelled, attempt < Self.rereads else { throw error }
                attempt += 1
            }
        }
    }

    private func read(_ key: String, starting: UInt64, load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        if let entry = entries.value(for: key), ContinuousClock.now - entry.stored < lifetime { return entry.bytes }
        let work: (id: UUID, task: Task<Data, Error>)
        if let existing = pending[key] { work = existing }
        else {
            // Bound active requests as well as retained bytes. Excess readers use their own request.
            if pending.count >= 16 {
                let bytes = try await load()
                guard starting == generation else { throw CancellationError() }
                try Task.checkCancellation(); return bytes
            }
            work = (UUID(), Task { try await load() }); pending[key] = work
        }
        do {
            let bytes = try await work.task.value
            guard starting == generation else { throw CancellationError() }
            if pending[key]?.id == work.id {
                pending[key] = nil
                dropExpired()
                entries.insert(.init(bytes: bytes, stored: .now), for: key, cost: bytes.count)
            }
            try Task.checkCancellation(); return bytes
        } catch {
            if pending[key]?.id == work.id { pending[key] = nil }; throw error
        }
    }
    /// A refresh elsewhere cancels shared in-flight reads. A reader that was not itself cancelled reads again instead of reporting that as Apple's answer.
    public static func rereadingAfterInvalidation<T>(attempts: Int = 3, isolation: isolated (any Actor)? = #isolation, _ read: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do { return try await read() } catch {
                let invalidated = error is CancellationError || (error as? URLError)?.code == .cancelled
                guard invalidated, !Task.isCancelled, attempt < attempts else { throw error }
                attempt += 1
            }
        }
    }
    public func invalidate() {
        generation &+= 1
        entries.removeAll()
        for work in pending.values { work.task.cancel() }
        pending.removeAll()
    }
}
