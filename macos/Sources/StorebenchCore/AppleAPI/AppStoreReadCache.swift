import Foundation

/// One bounded, short-lived response store per workspace session, shared by read-only screens.
/// Publishing clients never use this cache; local revisions and media keep their existing encrypted stores.
/// The size and lifetime follow the Performance setting; responses stay in memory only.
public actor AppStoreReadCache {
    private struct Entry { let bytes: Data, stored: ContinuousClock.Instant }
    private var entries: BoundedMemoryCache<String, Entry>
    private var pending: [String: Work] = [:]
    /// Requests a refresh replaced. Their readers still get their answer; it is never kept.
    private var superseded: [UUID: Work] = [:]
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

    /// While set, reads skip responses kept or requests started before this instant and replace them, so a screen's Refresh reads
    /// what it shows again without dropping what other screens read.
    @TaskLocal public static var refreshedSince: ContinuousClock.Instant?
    /// Runs `body` as a refresh that starts now.
    public static func refreshing<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        try await $refreshedSince.withValue(.now, operation: body, isolation: isolation)
    }

    /// How often a reader reads again when refreshes elsewhere keep replacing its read.
    static let rereads = 3

    /// A refresh elsewhere replaces reads in flight. Their readers read again instead of failing or showing the older answer.
    public func read(_ key: String, host: String? = nil, load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let starting = generation
            do { return try await read(key, host: host, starting: starting, load: load) } catch {
                guard starting != generation, !Task.isCancelled, attempt < Self.rereads else { throw error }
                attempt += 1
            }
        }
    }

    /// One request shared by every reader of the same key. Each reader waits on its own continuation, so a reader that leaves stops
    /// at once while the others keep waiting; the request itself stops only when no reader is left.
    private struct Work {
        let id: UUID, started: ContinuousClock.Instant
        var priority: AppleReadPriority
        var task: Task<Void, Never>?
        var readers: [UUID: CheckedContinuation<Data, Error>] = [:]
    }

    private func read(_ key: String, host: String?, starting: UInt64, load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let since = Self.refreshedSince
        if let entry = entries.value(for: key), ContinuousClock.now - entry.stored < lifetime, since.map({ entry.stored >= $0 }) ?? true { return entry.bytes }
        let priority = AppleReadPriority.current, workId: UUID
        if let existing = pending[key], let since, existing.started < since { superseded[existing.id] = existing; pending[key] = nil }
        if let existing = pending[key] {
            workId = existing.id
            // A more urgent reader moves the shared request up the queue instead of waiting behind background work.
            if priority > existing.priority { pending[key]?.priority = priority; Task { await AppleReadAdmission.shared(for: host).raise(key: key, to: priority) } }
        } else {
            // Beyond 16 shared reads a reader sends its own request; it still waits in the app's one request queue.
            if pending.count >= 16 {
                let bytes = try await load()
                guard starting == generation else { throw CancellationError() }
                try Task.checkCancellation(); return bytes
            }
            let id = UUID(); workId = id
            pending[key] = Work(id: id, started: .now, priority: priority)
            pending[key]?.task = Task {
                let result: Result<Data, Error>
                do { result = .success(try await AppleReadAdmission.$key.withValue(key) { try await load() }) } catch { result = .failure(error) }
                self.finish(key, id: id, result: result)
            }
        }
        let reader = UUID()
        let bytes = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                if pending[key]?.id == workId { pending[key]?.readers[reader] = continuation } else { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: { Task { await self.leave(key, id: workId, reader: reader) } }
        guard starting == generation else { throw CancellationError() }
        try Task.checkCancellation(); return bytes
    }

    private func finish(_ key: String, id: UUID, result: Result<Data, Error>) {
        if let work = superseded.removeValue(forKey: id) { for reader in work.readers.values { reader.resume(with: result) }; return }
        guard let work = pending[key], work.id == id else { return }
        pending[key] = nil
        if case .success(let bytes) = result { dropExpired(); entries.insert(.init(bytes: bytes, stored: .now), for: key, cost: bytes.count) }
        for reader in work.readers.values { reader.resume(with: result) }
    }

    private func leave(_ key: String, id: UUID, reader: UUID) {
        if var work = superseded[id], let continuation = work.readers.removeValue(forKey: reader) {
            continuation.resume(throwing: CancellationError())
            if work.readers.isEmpty { work.task?.cancel(); superseded[id] = nil } else { superseded[id] = work }
            return
        }
        guard var work = pending[key], work.id == id, let continuation = work.readers.removeValue(forKey: reader) else { return }
        continuation.resume(throwing: CancellationError())
        if work.readers.isEmpty { work.task?.cancel(); pending[key] = nil } else { pending[key] = work }
    }

    /// Readers currently waiting on a shared request, for tests.
    func readers(_ key: String) -> Int { pending[key]?.readers.count ?? 0 }

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
        let works = Array(pending.values) + Array(superseded.values); pending.removeAll(); superseded.removeAll()
        for work in works { work.task?.cancel(); for reader in work.readers.values { reader.resume(throwing: CancellationError()) } }
    }
}
