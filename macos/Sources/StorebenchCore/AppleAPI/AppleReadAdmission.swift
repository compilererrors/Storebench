import Foundation

/// How soon a read from Apple is needed. Screens set it for the work they start; reads without one count as visible.
public enum AppleReadPriority: Int, Sendable, Comparable, CaseIterable {
    /// Filling in data nobody looks at yet, such as preparing other apps.
    case background
    /// Data for the step the user is likely to open next.
    case next
    /// What the open screen shows or the user just asked for.
    case visible

    @TaskLocal public static var current: AppleReadPriority = .visible
    public static func < (left: Self, right: Self) -> Bool { left.rawValue < right.rawValue }
}

/// One queue for every read request sent to Apple in this app. Visible reads go first, then next-step reads, then background
/// reads. Only so many requests run at once, and slots stay free for visible reads, so heavy background work never holds every
/// connection. Next-step and background reads that would wait beyond their limit are dropped instead of piling up.
/// A slot covers one request: retries and Retry-After waits happen outside it.
public actor AppleReadAdmission {
    public struct Limits: Sendable, Equatable {
        /// Requests running at once, in all.
        public var active = 6
        /// Next-step and background requests running at once, leaving the rest for visible reads.
        public var nextActive = 5
        /// Background requests running at once.
        public var backgroundActive = 3
        /// Requests that may wait per priority before new ones of that priority are dropped. Visible reads always wait.
        public var nextWaiting = 48, backgroundWaiting = 24
        public init() {}
    }
    public enum Failure: Error, Equatable {
        /// A next-step or background read was dropped because too many of its kind were already waiting.
        case full
    }
    public struct Snapshot: Sendable, Equatable {
        public let active: [AppleReadPriority: Int], waiting: [AppleReadPriority: Int], dropped: Int
    }

    /// The queue for requests to one host. The app reads from one App Store Connect host, so all its reads share one queue.
    public static func shared(for host: String?) -> AppleReadAdmission {
        let key = host?.lowercased() ?? ""
        return lock.withLock {
            if let queue = queues[key] { return queue }
            if queues.count >= 64 { queues.removeAll() }
            let queue = AppleReadAdmission(); queues[key] = queue; return queue
        }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [String: AppleReadAdmission] = [:]
    /// The shared read a request belongs to, so a reader that joins it can raise its priority.
    @TaskLocal public static var key: String?

    private struct Waiter { let id: UUID, key: String?, order: Int; var priority: AppleReadPriority; let continuation: CheckedContinuation<AppleReadPriority, Error> }
    private let limits: Limits
    private var waiting: [Waiter] = []
    private var active: [AppleReadPriority: Int] = [:]
    private var raised: [String: AppleReadPriority] = [:]
    private var order = 0, dropped = 0

    public init(limits: Limits = Limits()) { self.limits = limits }

    public var snapshot: Snapshot {
        Snapshot(active: active.filter { $0.value > 0 }, waiting: Dictionary(grouping: waiting, by: \.priority).mapValues(\.count), dropped: dropped)
    }

    /// Runs one request when a slot is free for its priority.
    public func run<T: Sendable>(_ priority: AppleReadPriority = AppleReadPriority.current, key: String? = AppleReadAdmission.key,
                                 _ body: @Sendable () async throws -> T) async throws -> T {
        let slot = try await acquire(priority, key: key)
        do { let value = try await body(); release(slot, key: key); return value } catch { release(slot, key: key); throw error }
    }

    /// A more urgent reader joined the shared read for `key`: a request of it that waits, or has not reached the queue yet, moves up.
    public func raise(key: String, to priority: AppleReadPriority) {
        if raised.count >= 256, raised[key] == nil { raised.removeAll() }
        raised[key] = max(raised[key] ?? priority, priority)
        for index in waiting.indices where waiting[index].key == key && waiting[index].priority < priority { waiting[index].priority = priority }
        pump()
    }

    private func acquire(_ requested: AppleReadPriority, key: String?) async throws -> AppleReadPriority {
        try Task.checkCancellation()
        let priority = max(requested, key.flatMap { raised[$0] } ?? requested)
        if !waiting.contains(where: { $0.priority >= priority }), startable(priority) { active[priority, default: 0] += 1; return priority }
        let limit = priority == .next ? limits.nextWaiting : priority == .background ? limits.backgroundWaiting : Int.max
        guard waiting.count(where: { $0.priority == priority }) < limit else { dropped += 1; throw Failure.full }
        let id = UUID()
        order += 1; let position = order
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append(Waiter(id: id, key: key, order: position, priority: priority, continuation: continuation))
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func startable(_ priority: AppleReadPriority) -> Bool {
        let total = active.values.reduce(0, +), ahead = (active[.next] ?? 0) + (active[.background] ?? 0)
        switch priority {
        case .visible: return total < limits.active
        case .next: return total < limits.active && ahead < limits.nextActive
        case .background: return total < limits.active && ahead < limits.nextActive && (active[.background] ?? 0) < limits.backgroundActive
        }
    }

    private func release(_ slot: AppleReadPriority, key: String?) {
        active[slot, default: 1] -= 1
        if let key { raised[key] = nil }
        pump()
    }

    /// Starts waiting requests, most urgent and then oldest first, while slots allow.
    private func pump() {
        while let index = waiting.indices.filter({ startable(waiting[$0].priority) })
                .max(by: { (waiting[$0].priority, -waiting[$0].order) < (waiting[$1].priority, -waiting[$1].order) }) {
            let waiter = waiting.remove(at: index)
            active[waiter.priority, default: 0] += 1
            waiter.continuation.resume(returning: waiter.priority)
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
