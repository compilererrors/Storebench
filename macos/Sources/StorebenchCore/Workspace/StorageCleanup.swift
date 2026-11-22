import Foundation

/// What Storebench removes from this workspace by itself, and after how many days. Only two things are ever removed: reviews that
/// were prepared but never sent, and the images kept with older AI requests. Nothing sent to Apple, no saved listing, no draft
/// and no report is touched.
public struct StorageCleanup: Equatable, Sendable {
    public static let dayRange = 1...3_650
    public static let standardReviewDays = 30, standardImageDays = 90
    /// Reviews prepared but never approved are removed this many days after they expired; nil keeps them.
    public let unsentReviewDays: Int?
    /// The images of AI requests are removed from AI History after this many days; nil keeps them. Each request's text and answer stay.
    public let aiImageDays: Int?

    public init(unsentReviewDays: Int? = StorageCleanup.standardReviewDays, aiImageDays: Int? = StorageCleanup.standardImageDays) throws {
        guard unsentReviewDays.map(Self.dayRange.contains) ?? true, aiImageDays.map(Self.dayRange.contains) ?? true else { throw StorageCleanupFailure.invalid }
        self.unsentReviewDays = unsentReviewDays; self.aiImageDays = aiImageDays
    }
    public init(_ value: JSONText) throws {
        guard case .object = value, value["schemaVersion"] == .number(1) else { throw StorageCleanupFailure.invalid }
        func days(_ name: String) throws -> Int? {
            guard let saved = value[name], saved != .null else { return nil }
            guard case .number(let number) = saved, let whole = Int(exactly: number) else { throw StorageCleanupFailure.invalid }
            return whole
        }
        try self.init(unsentReviewDays: try days("unsentReviewDays"), aiImageDays: try days("aiImageDays"))
    }
    public var json: JSONText {
        .object([("schemaVersion", .number(1)), ("unsentReviewDays", unsentReviewDays.map { .number(Double($0)) } ?? .null), ("aiImageDays", aiImageDays.map { .number(Double($0)) } ?? .null)])
    }
    static func stored(_ document: EncryptedDocumentStore.Document?) throws -> Self {
        let value = try document.map { try JSONText.parse($0.payload) }
        if value == nil || value == .null { return try Self() }
        return try Self(value!)
    }
}

public enum StorageCleanupFailure: Error, Equatable { case invalid }

/// What one cleanup removed, and how much room it gave back.
public struct StorageCleanupResult: Equatable, Sendable {
    public let reviews: Int, requests: Int, compacted: Bool, at: Date
    public var summary: String {
        guard reviews > 0 || requests > 0 else { return "Nothing was old enough to remove." }
        let parts = [reviews == 0 ? nil : reviews == 1 ? "1 unsent review" : "\(reviews) unsent reviews",
                     requests == 0 ? nil : requests == 1 ? "the images of 1 AI request" : "the images of \(requests) AI requests"].compactMap { $0 }
        return "Removed " + parts.joined(separator: " and ") + "." + (compacted ? " The database file was made smaller." : "")
    }
}

extension WorkspaceSession {
    public func storageCleanup() throws -> StorageCleanup {
        try storeAccess { store in try StorageCleanup.stored(store.document(namespace: "storage_cleanup", key: "current")) }
    }

    public func setStorageCleanup(_ value: StorageCleanup) throws {
        try requireOwnWorkspace()
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("storage_cleanup.mutex")) {
                try store.transaction { current in
                    _ = try StorageCleanup.stored(current("storage_cleanup", "current"))
                    return [.put(namespace: "storage_cleanup", key: "current", json: value.json.data)]
                }
            }
        }
    }

    /// Removes what the cleanup settings allow. Saved reviews and requests are read and checked one at a time away from the session;
    /// each removal then happens only if that record is still exactly as it was read.
    public nonisolated func runStorageCleanup(now: Date = Date()) async throws -> StorageCleanupResult {
        try requireOwnWorkspace()
        let settings = try await storageCleanup()
        var reviews = 0, requests = 0
        if let days = settings.unsentReviewDays {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400), noted = Set(try await keysAwayFromSession(namespace: "change_journal_notes"))
            var stale: [(key: String, revision: Int)] = []
            for key in try await keysAwayFromSession(namespace: "publish_reviews") {
                try Task.checkCancellation()
                guard let document = try await documentAwayFromSession(namespace: "publish_reviews", key: key),
                      let review = (try? JSONText.parse(document.payload)).flatMap(PublishReview.init),
                      Self.unsentReviewIsStale(review, key: key, cutoff: cutoff, noted: noted) else { continue }
                stale.append((key, document.revision))
            }
            reviews = try await removeUnsentReviews(stale)
        }
        if let days = settings.aiImageDays {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            for key in try await keysAwayFromSession(namespace: "ai_history") {
                try Task.checkCancellation()
                guard let document = try await documentAwayFromSession(namespace: "ai_history", key: key),
                      let job = try? JSONDecoder().decode(AIJob.self, from: document.payload), let stripped = Self.withoutOldImages(job, cutoff: cutoff),
                      let payload = try? JSONEncoder().encode(stripped) else { continue }
                if try await replaceAIHistory(key: key, revision: document.revision, payload: payload) { requests += 1 }
            }
        }
        let compacted = reviews > 0 || requests > 0 ? await compactDatabaseIfWorthwhile() : false
        return StorageCleanupResult(reviews: reviews, requests: requests, compacted: compacted, at: now)
    }

    /// A review may go only when it was never approved, expired before `cutoff` and has no note in the Change Journal.
    static func unsentReviewIsStale(_ review: PublishReview, key: String, cutoff: Date, noted: Set<String>) -> Bool {
        guard review.state == "prepared", review.approvedAt == nil, review.sentAt == nil, review.completedAt == nil,
              !review.steps.contains(where: { $0.state != "pending" }),
              key == "\(review.request.accountId):\(review.request.appId):\(review.id)",
              let expired = ISO8601DateFormatter.storebench.date(from: review.expiresAt), expired < cutoff else { return false }
        return !noted.contains("\(review.request.accountId):\(review.request.appId):publish:\(review.id)")
    }

    /// The request with its images emptied, when it ended before `cutoff` and still has any; each image's recognized text stays.
    static func withoutOldImages(_ job: AIJob, cutoff: Date) -> AIJob? {
        guard [.complete, .failed, .paused].contains(job.state), (job.finishedAt ?? job.createdAt) < cutoff, job.request.images.contains(where: { !$0.data.isEmpty }) else { return nil }
        let request = AIRequest(purpose: job.request.purpose, instructions: job.request.instructions, input: job.request.input, schema: job.request.schema,
                                images: job.request.images.map { AIImage(data: Data(), mime: $0.mime, text: $0.text) }, translationFields: job.request.translationFields,
                                language: job.request.language, cardDraft: job.request.cardDraft, variationID: job.request.variationID)
        var stripped = AIJob(id: job.id, accountId: job.accountId, appId: job.appId, connection: job.connection, request: request, createdAt: job.createdAt,
                             state: job.state, result: job.result, failure: job.failure)
        stripped.attemptID = job.attemptID; stripped.execution = job.execution; stripped.startedAt = job.startedAt; stripped.finishedAt = job.finishedAt; stripped.failureDetail = job.failureDetail
        return stripped
    }

    private func removeUnsentReviews(_ stale: [(key: String, revision: Int)]) throws -> Int {
        guard !stale.isEmpty else { return 0 }
        var removed = 0
        try storeAccess { store in
            publishReviewSaves += 1
            try store.transaction { current in
                removed = 0
                var writes: [EncryptedDocumentStore.Write] = []
                for item in stale where try current("publish_reviews", item.key)?.revision == item.revision {
                    removed += 1; writes.append(.delete(namespace: "publish_reviews", key: item.key))
                }
                return writes
            }
        }
        return removed
    }

    private func replaceAIHistory(key: String, revision: Int, payload: Data) throws -> Bool {
        var replaced = false
        try storeAccess { store in
            try store.transaction { current in
                replaced = try current("ai_history", key)?.revision == revision
                return replaced ? [.put(namespace: "ai_history", key: key, json: payload)] : []
            }
        }
        return replaced
    }

    /// Gives unused room in the database file back to the disk after a cleanup, when at least a quarter of the file and 32 MB are unused.
    /// It is skipped whenever another read is using the database at that moment.
    private func compactDatabaseIfWorthwhile() -> Bool {
        (try? storeAccess { store in
            let room = try store.unusedRoom()
            guard room.unused >= 32 * 1_048_576, room.unused * 4 >= room.total else { return false }
            try Diagnostics.measure("Database compaction", slow: .seconds(2)) { try store.compact() }
            return true
        }) ?? false
    }

    /// The keys of one namespace, read on the second connection when it is open.
    nonisolated func keysAwayFromSession(namespace: String) async throws -> [String] {
        try requireSessionAccess()
        if reads.isOpen { return try reads.read { try $0.keys(namespace: namespace) } }
        return try await sessionKeys(namespace: namespace)
    }
    private func sessionKeys(namespace: String) throws -> [String] { try storeAccess { try $0.keys(namespace: namespace) } }
}
