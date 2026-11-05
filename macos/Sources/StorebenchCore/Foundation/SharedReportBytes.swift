import Foundation

/// A cancelled borrower releases its own wait. Only the initiating caller cancels that exact load.
private final class SharedByteEntry: @unchecked Sendable {
    let id = UUID(), created: Date, expires: Date, task: Task<Data, Error>
    private let lock = NSLock()
    private var result: Result<Data, Error>?
    private var waiters: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var cancelled: Set<UUID> = []
    var size: Int { lock.withLock { if case .success(let data)? = result { return data.count }; return 0 } }
    init(created: Date, expires: Date, task: Task<Data, Error>) { self.created = created; self.expires = expires; self.task = task }
    func complete(_ result: Result<Data, Error>) {
        let callbacks = lock.withLock { self.result = result; let callbacks = Array(waiters.values); waiters = [:]; cancelled = []; return callbacks }
        for callback in callbacks { callback.resume(with: result) }
    }
    func wait(owner: Bool) async throws -> Data {
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            let data = try await withCheckedThrowingContinuation { (callback: CheckedContinuation<Data, Error>) in
                let ready: Result<Data, Error>? = lock.withLock {
                    if cancelled.remove(id) != nil || Task.isCancelled { return .failure(CancellationError()) }
                    if let result { return result }
                    waiters[id] = callback; return nil
                }
                if let ready { callback.resume(with: ready) }
            }
            try Task.checkCancellation(); return data
        }, onCancel: {
            let callback = self.lock.withLock {
                let callback = self.waiters.removeValue(forKey: id)
                if callback == nil && self.result == nil { self.cancelled.insert(id) }
                return callback
            }
            callback?.resume(throwing: CancellationError())
            if owner { self.task.cancel() }
        })
    }
}

/// Brief process-local sharing of vendor files. Keys include account, source, vendor and report day.
public actor SharedReportBytes {
    static let shared = SharedReportBytes()
    private let capacity: Int, lifetime: TimeInterval, clock: @Sendable () -> Date
    private var entries: [String: SharedByteEntry] = [:], order: [String] = []
    public init(capacity: Int = 32_000_000, lifetime: TimeInterval = 600, clock: @escaping @Sendable () -> Date = Date.init) {
        self.capacity = max(0, capacity); self.lifetime = max(0, lifetime); self.clock = clock
    }
    private func remove(_ key: String, id: UUID? = nil) {
        if let id, entries[key]?.id != id { return }
        entries[key] = nil; order.removeAll { $0 == key }
    }
    private func evict(_ now: Date) {
        for key in order where entries[key].map({ $0.expires <= now || now < $0.created }) ?? true { remove(key) }
        var size = entries.values.reduce(0) { $0 + $1.size }
        for key in order where size > capacity { size -= entries[key]?.size ?? 0; remove(key) }
    }
    public func load(key: String, download: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try Task.checkCancellation(); evict(clock())
        if let entry = entries[key] {
            do { return try await entry.wait(owner: false) }
            catch { try Task.checkCancellation(); remove(key, id: entry.id) }
            // An initiating job's failure or cancellation is not this caller's answer.
        }
        try Task.checkCancellation()
        let now = clock(), task = Task { try await download() }, entry = SharedByteEntry(created: now, expires: now.addingTimeInterval(lifetime), task: task)
        entries[key] = entry; order.append(key)
        Task { let result = await task.result; self.completed(key: key, entry: entry, result: result) }
        return try await entry.wait(owner: true)
    }
    private func completed(key: String, entry: SharedByteEntry, result: Result<Data, Error>) {
        entry.complete(result)
        if case .failure = result { remove(key, id: entry.id) }
        evict(clock())
    }
    public func status() -> (entries: Int, bytes: Int) { (entries.count, entries.values.reduce(0) { $0 + $1.size }) }
}
