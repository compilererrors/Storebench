import Foundation

/// The text actually submitted to the selected service, captured before dispatch.
public struct AIExecutionSnapshot: Codable, Sendable, Equatable {
    public let instructions: String, input: String, format: String
}

/// Lightweight history rows do not load the images or credentials in a request.
public struct AIHistoryEntry: Codable, Sendable, Identifiable {
    public let id: String, jobID: String, accountId: String, appId: String
    public let provider: AIProvider, model: String, purpose: String, title: String
    public let state: AIJob.State, createdAt: Date, startedAt: Date?, finishedAt: Date?
    public let imageCount: Int
    init(_ job: AIJob) {
        id = job.attemptID ?? job.id + ":legacy:" + JSONText.string(String(job.createdAt.timeIntervalSince1970)).sha256
        jobID = job.id; accountId = job.accountId; appId = job.appId
        provider = job.connection.provider; model = job.connection.model; purpose = job.request.purpose
        title = job.request.cardDraft?["name"]?.text ?? (purpose == "cards" ? "AI Cards" : "Translation")
        state = job.state; createdAt = job.createdAt; startedAt = job.startedAt; finishedAt = job.finishedAt; imageCount = job.request.images.count
    }
    public var stateTitle: String { state.title }
    static func writes(_ job: AIJob) throws -> [EncryptedDocumentStore.Write] {
        let entry = Self(job), encoder = JSONEncoder()
        return [.put(namespace: "ai_history", key: entry.id, json: try encoder.encode(job)),
                .put(namespace: "ai_history_index", key: entry.id, json: try encoder.encode(entry))]
    }
}

extension WorkspaceSession {
    /// Older requests appear immediately. Once indexed, refreshing reads only lightweight summaries.
    public func aiHistory(accountId: String, appId: String) throws -> [AIHistoryEntry] {
        try requireHistoryScope(accountId: accountId, appId: appId)
        let prefix = accountId + ":" + appId + ":"
        return try storeAccess { store in
            let rows = try store.documents(namespace: "ai_history_index", prefix: prefix).map { try JSONDecoder().decode(AIHistoryEntry.self, from: $0.payload) }
            let indexed = Set(rows.map(\.jobID))
            for key in try store.keys(namespace: "ai_jobs") where key.hasPrefix(prefix) && !indexed.contains(key) {
                try store.transaction { current in
                    guard let document = try current("ai_jobs", key) else { return [] }
                    let job = try JSONDecoder().decode(AIJob.self, from: document.payload), entry = AIHistoryEntry(job)
                    guard try current("ai_history_index", entry.id) == nil else { return [] }
                    return try AIHistoryEntry.writes(job)
                }
            }
            return try store.documents(namespace: "ai_history_index", prefix: prefix).map { try JSONDecoder().decode(AIHistoryEntry.self, from: $0.payload) }.sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
            }
        }
    }
    public func aiHistoryJob(accountId: String, appId: String, id: String) throws -> AIJob {
        try requireHistoryScope(accountId: accountId, appId: appId)
        guard id.hasPrefix(accountId + ":" + appId + ":") else { throw AIFailure.configuration }
        return try storeAccess { store in
            guard let document = try store.document(namespace: "ai_history", key: id) else { throw AIFailure.changed }
            let job = try JSONDecoder().decode(AIJob.self, from: document.payload)
            guard job.accountId == accountId, job.appId == appId else { throw AIFailure.configuration }
            return job
        }
    }
}
