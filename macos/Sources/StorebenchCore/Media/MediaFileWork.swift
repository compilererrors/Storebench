import Foundation

/// Bounds disk and encryption work without occupying the session actor while files are processed.
actor MediaFileWork {
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let limit: Int
    init(limit: Int = 2) { precondition(limit > 0); self.limit = limit }

    func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        if running == limit { await withCheckedContinuation { waiting.append($0) } }
        else { running += 1 }
        defer {
            if waiting.isEmpty { running -= 1 }
            else { waiting.removeFirst().resume() }
        }
        try Task.checkCancellation()
        let worker = Task.detached { try Task.checkCancellation(); return try work() }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
