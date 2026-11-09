import Foundation

struct AIModelCatalog: Sendable {
    let connection: AIConnection
    let models: [AIClient.Model]
    let readAt: ContinuousClock.Instant
}

struct AIModelRead: Sendable {
    let id: UUID
    let task: Task<[AIClient.Model], Error>
    var waiters: Set<UUID>
}

extension WorkspaceSession {
    /// Reads model metadata using the exact saved connection. This never runs an inference or changes a default.
    public func availableAIModels(_ connection: AIConnection, refresh: Bool = false) async throws -> [AIClient.Model] {
        try Task.checkCancellation()
        try requireOwnWorkspace()
        guard !isSample, connection.provider != .apple else { throw AIFailure.configuration }
        guard try aiConnection(connection.provider) == connection else { throw AIFailure.changed }
        if !refresh, let cached = aiModelCatalogs[connection.provider], cached.connection == connection,
           cached.readAt.duration(to: .now) < .seconds(300) { return cached.models }
        let waiter = UUID()
        if var pending = aiModelReads[connection] {
            pending.waiters.insert(waiter); aiModelReads[connection] = pending
            return try await waitForAIModels(pending, connection: connection, waiter: waiter)
        }
        let id = UUID(), lease = try lifetime.admit(.ai)
        let task = Task { [self] in
            defer { lease.finish() }
            return try await SessionContext.$lease.withValue(lease) {
                try await readAIModels(connection)
            }
        }
        let pending = AIModelRead(id: id, task: task, waiters: [waiter]); aiModelReads[connection] = pending
        return try await waitForAIModels(pending, connection: connection, waiter: waiter)
    }

    private func readAIModels(_ connection: AIConnection) async throws -> [AIClient.Model] {
        let values: [AIClient.Model]
        if connection.provider == .chatgpt {
            guard let profile = try chatGPTProfiles().first(where: { $0.credentialID == connection.credentialId }) else { throw AIFailure.changed }
            values = try await chatGPTModels(profile)
        } else {
            let key = try aiCredential(connection)
            values = try await AIClient(provider: connection.provider, key: key, configuration: aiTestConfiguration?() ?? .ephemeral).models()
        }
        try Task.checkCancellation()
        guard try aiConnection(connection.provider) == connection else { throw AIFailure.changed }
        aiModelCatalogs[connection.provider] = .init(connection: connection, models: values, readAt: .now)
        return values
    }

    private func waitForAIModels(_ pending: AIModelRead, connection: AIConnection, waiter: UUID) async throws -> [AIClient.Model] {
        defer { finishAIModelRead(connection, id: pending.id, waiter: waiter) }
        return try await withTaskCancellationHandler(operation: {
            let values = try await pending.task.value
            try Task.checkCancellation(); return values
        }, onCancel: { Task { await self.finishAIModelRead(connection, id: pending.id, waiter: waiter) } })
    }

    private func finishAIModelRead(_ connection: AIConnection, id: UUID, waiter: UUID) {
        guard var pending = aiModelReads[connection], pending.id == id, pending.waiters.remove(waiter) != nil else { return }
        if pending.waiters.isEmpty { pending.task.cancel(); aiModelReads[connection] = nil }
        else { aiModelReads[connection] = pending }
    }
}
