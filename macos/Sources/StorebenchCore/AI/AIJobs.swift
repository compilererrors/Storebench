import Foundation

actor AIWorkQueue {
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; return }
        guard waiting.count < 64 else { throw AIFailure.unavailable }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    func run(_ work: @Sendable () async throws -> JSONText) async throws -> JSONText {
        try await acquire(UUID())
        defer { if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().1.resume() } }
        try Task.checkCancellation(); return try await work()
    }
}

extension WorkspaceSession {
    /// Restored jobs keep their inputs and completed results. Only the exact process holding the job lock updates progress.
    public func aiJobs(accountId: String, appId: String, purpose: String? = nil) throws -> [AIJob] {
        try requireHistoryScope(accountId: accountId, appId: appId)
        return try storeAccess { store in
            try store.documents(namespace: "ai_jobs", prefix: accountId + ":" + appId + ":").map { try JSONDecoder().decode(AIJob.self, from: $0.payload) }
                .filter { purpose == nil || $0.request.purpose == purpose }.sorted { $0.createdAt > $1.createdAt }
        }
    }
    public func pauseAIJob(_ id: String) { aiTasks[id]?.cancel() }
    public func runAIJob(accountId: String, appId: String, provider: AIProvider, request: AIRequest, model: String? = nil) async throws -> JSONText {
        try requireHistoryScope(accountId: accountId, appId: appId); try request.validate()
        guard !isSample else { throw AIFailure.configuration }
        if let model { guard provider != .apple, AIConnection.validModel(model) else { throw AIFailure.configuration } }
        let connection: AIConnection
        if provider == .apple { connection = .init(provider: .apple, model: "system", credentialId: "local", revision: 0) }
        else { guard let value = try aiConnection(provider) else { throw AIFailure.configuration }; connection = value }
        let chosen = AIConnection(provider: provider, model: model ?? connection.model, credentialId: connection.credentialId, revision: connection.revision)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let signature = JSONText.object([("contract", .number(1)), ("request", try JSONText.parse(encoder.encode(request))),
            ("connection", try JSONText.parse(encoder.encode(chosen))), ("system", .string(provider == .apple ? ProcessInfo.processInfo.operatingSystemVersionString : ""))]).sha256
        let id = accountId + ":" + appId + ":" + signature
        if let active = aiTasks[id] { return try await active.value }
        let lease = try lifetime.admit(.ai)
        let task = Task { [self] in
            defer { lease.finish(); aiTasks[id] = nil }
            return try await SessionContext.$lease.withValue(lease) {
                try await executeAIJob(id: id, accountId: accountId, appId: appId, connection: connection, selected: chosen, request: request)
            }
        }
        aiTasks[id] = task
        return try await task.value
    }
    private func executeAIJob(id: String, accountId: String, appId: String, connection: AIConnection, selected: AIConnection, request: AIRequest) async throws -> JSONText {
        if connection.provider != .apple { guard try aiConnection(connection.provider) == connection else { throw AIFailure.changed } }
        let directory = try storeAccess { $0.directory }, name = "ai_job_" + JSONText.string(id).sha256
        guard let release = try JobLock.acquire(directory: directory, name: name, id: UUID().uuidString.lowercased()) else { throw AIFailure.unavailable }
        defer { release() }
        if let saved = try storeAccess({ try $0.document(namespace: "ai_jobs", key: id) }),
           let job = try? JSONDecoder().decode(AIJob.self, from: saved.payload), job.state == .complete, let result = job.result { return result }
        var job = AIJob(id: id, accountId: accountId, appId: appId, connection: selected, request: request, createdAt: Date(), state: .queued, result: nil, failure: nil)
        func save() throws { try storeAccess { try $0.transaction { _ in [.put(namespace: "ai_jobs", key: id, json: try JSONEncoder().encode(job))] } } }
        try save()
        do {
            let configuration = aiTestConfiguration
            let value = try await aiQueue.run { [self] in
                try await markAIJobRunning(id)
                if connection.provider == .apple { return try await AppleLocalAI.generate(request) }
                let key = try await (connection.provider == .chatgpt ? chatGPTAccess(connection) : aiCredential(connection))
                let result = try await AIClient(provider: connection.provider, key: key, configuration: configuration?() ?? .ephemeral).generate(request, model: selected.model)
                guard try await aiConnection(connection.provider) == connection else { throw AIFailure.changed }
                return result
            }
            try Task.checkCancellation()
            if request.purpose == "translation", case .array(let source) = try JSONText.parse(Data(request.input.utf8)) { try request.validateTranslations(value, count: source.count) }
            if request.purpose == "cards" { _ = try AICards.checked(value, count: request.images.count) }
            job.state = .complete; job.result = value; try save(); return value
        } catch {
            if connection.provider == .chatgpt, let failure = error as? AIFailure, [.subscriptionLimit, .signIn, .subscriptionPermission].contains(failure) { chatGPTBlocks[connection.credentialId] = failure }
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            job.state = cancelled ? .paused : .failed
            job.failure = cancelled ? .cancelled : error as? AIFailure ?? .unavailable
            try save(); throw error
        }
    }
    private func markAIJobRunning(_ id: String) throws {
        guard let saved = try storeAccess({ try $0.document(namespace: "ai_jobs", key: id) }) else { throw AIFailure.changed }
        var job = try JSONDecoder().decode(AIJob.self, from: saved.payload); job.state = .running
        try storeAccess { try $0.transaction { _ in [.put(namespace: "ai_jobs", key: id, json: try JSONEncoder().encode(job))] } }
    }
    public func translateWithAI(accountId: String, appId: String, provider: AIProvider, texts: [String], source: String, target: String, fields: [String]? = nil, model: String? = nil) async throws -> [String] {
        let request = try AIRequest.translation(texts, source: source, target: target, fields: fields)
        let result = try await runAIJob(accountId: accountId, appId: appId, provider: provider, request: request, model: model)
        return try AIRequest.translations(result, count: texts.count)
    }
}
