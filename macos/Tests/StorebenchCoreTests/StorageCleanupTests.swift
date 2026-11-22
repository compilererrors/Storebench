import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct StorageCleanupTests {
    init() throws { _ = try TestIsolation.require() }
    static let app = "1000000001", day: TimeInterval = 86_400

    struct Fixture { let session: WorkspaceSession, root: URL, account: Account, review: PublishReview }
    /// A workspace with one review that was prepared and never sent.
    func fixture() async throws -> Fixture {
        let (session, root) = try DraftTests().session(), account = try #require(try await session.accounts().first)
        let host = "storage-cleanup-\(UUID().uuidString.lowercased()).appstoreconnect.test", apple = SyntheticApple()
        StubProtocol.handle(host) { apple.handle($0) }
        let review = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: Self.app, scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio"),
                                                         client: try PublishingTests().client(account, host: host))
        return Fixture(session: session, root: root, account: account, review: review)
    }
    func reviews(_ f: Fixture) async throws -> [PublishReview] { try await f.session.publishHistory(accountId: f.account.id, appId: Self.app) }

    @Test func theSettingsKeepTheirDefaultsAndRefuseDaysOutOfRange() throws {
        let standard = try StorageCleanup()
        #expect(standard.unsentReviewDays == 30 && standard.aiImageDays == 90)
        #expect(try StorageCleanup(standard.json) == standard)
        let off = try StorageCleanup(unsentReviewDays: nil, aiImageDays: 3_650)
        #expect(try StorageCleanup(off.json) == off && off.unsentReviewDays == nil)
        #expect(throws: StorageCleanupFailure.invalid) { try StorageCleanup(unsentReviewDays: 0) }
        #expect(throws: StorageCleanupFailure.invalid) { try StorageCleanup(aiImageDays: 3_651) }
        #expect(throws: StorageCleanupFailure.invalid) { try StorageCleanup(.object([("schemaVersion", .number(1)), ("unsentReviewDays", .number(1.5))])) }
        #expect(throws: StorageCleanupFailure.invalid) { try StorageCleanup(.object([("schemaVersion", .number(2))])) }
    }

    @Test func anUnsentReviewIsRemovedOnlyAfterItsDaysAndOnlyWhenCleanupIsOn() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(try await f.session.storageCleanup() == StorageCleanup())
        #expect(try await reviews(f).map(\.id) == [f.review.id])
        // Not old enough: the review expired minutes after it was prepared, and 30 days have not passed.
        let early = try await f.session.runStorageCleanup(now: Date().addingTimeInterval(29 * Self.day))
        #expect(early.reviews == 0 && early.requests == 0 && !early.compacted && early.summary == "Nothing was old enough to remove.")
        #expect(try await reviews(f).count == 1)
        // Turned off: nothing is removed however old it is.
        try await f.session.setStorageCleanup(try StorageCleanup(unsentReviewDays: nil, aiImageDays: nil))
        #expect(try await f.session.runStorageCleanup(now: Date().addingTimeInterval(400 * Self.day)).reviews == 0)
        #expect(try await reviews(f).count == 1)
        // A shorter number of days applies at the next cleanup.
        try await f.session.setStorageCleanup(try StorageCleanup(unsentReviewDays: 7, aiImageDays: nil))
        let removed = try await f.session.runStorageCleanup(now: Date().addingTimeInterval(8 * Self.day))
        #expect(removed.reviews == 1 && removed.summary == "Removed 1 unsent review.")
        #expect(try await reviews(f).isEmpty)
        #expect(try await f.session.runStorageCleanup(now: Date().addingTimeInterval(9 * Self.day)).reviews == 0)
    }

    @Test func aReviewThatWasApprovedOrHasANoteIsNeverRemoved() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let later = Date().addingTimeInterval(400 * Self.day)
        // A note in Change Journal keeps the review it belongs to.
        try await f.session.storeAccess { store in
            try store.transaction { _ in [.put(namespace: "change_journal_notes", key: "\(f.account.id):\(Self.app):publish:\(f.review.id)", json: Data("{}".utf8))] }
        }
        #expect(try await f.session.runStorageCleanup(now: later).reviews == 0)
        try await f.session.storeAccess { store in try store.delete(namespace: "change_journal_notes", key: "\(f.account.id):\(Self.app):publish:\(f.review.id)") }
        // A review that was approved, is being sent, stopped or finished is history and stays.
        var revision = 1
        for state in ["running", "failed", "conflict", "complete"] {
            var changed = f.review; changed.state = state
            revision = try await f.session.savePublishReview(changed, expected: revision)
            #expect(try await f.session.runStorageCleanup(now: later).reviews == 0, "A \(state) review was removed")
        }
        var approved = f.review; approved.approvedAt = f.review.createdAt
        revision = try await f.session.savePublishReview(approved, expected: revision)
        #expect(try await f.session.runStorageCleanup(now: later).reviews == 0)
        #expect(try await reviews(f).map(\.id) == [f.review.id])
        // The untouched review, as first prepared, is the only kind that goes.
        _ = try await f.session.savePublishReview(f.review, expected: revision)
        #expect(try await f.session.runStorageCleanup(now: later).reviews == 1)
    }

    @Test func aRecordChangedAfterItWasReadIsLeftAlone() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let key = "\(f.account.id):\(Self.app):\(f.review.id)", cutoff = Date().addingTimeInterval(400 * Self.day)
        #expect(WorkspaceSession.unsentReviewIsStale(f.review, key: key, cutoff: cutoff, noted: []))
        #expect(!WorkspaceSession.unsentReviewIsStale(f.review, key: key, cutoff: Date(), noted: []))
        #expect(!WorkspaceSession.unsentReviewIsStale(f.review, key: key, cutoff: cutoff, noted: ["\(f.account.id):\(Self.app):publish:\(f.review.id)"]))
        #expect(!WorkspaceSession.unsentReviewIsStale(f.review, key: "synthetic-other:\(Self.app):\(f.review.id)", cutoff: cutoff, noted: []))
        var started = f.review; started.steps[0].state = "done"
        #expect(!WorkspaceSession.unsentReviewIsStale(started, key: key, cutoff: cutoff, noted: []))
    }

    @Test func olderAIRequestsLoseTheirImagesAndKeepTheirTextAndAnswer() async throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let request = AIRequest(purpose: "cards", instructions: "Synthetic instructions", input: "{}", schema: .object([]),
                                images: [AIImage(data: Data(repeating: 7, count: 2_000), text: "Synthetic headline"), AIImage(data: Data(repeating: 9, count: 1_000), mime: "image/png")])
        var job = AIJob(id: "synthetic-account:\(Self.app):job", accountId: "synthetic-account", appId: Self.app, connection: AIConnection(provider: .openai, model: "synthetic-model", credentialId: "synthetic", revision: 1),
                        request: request, createdAt: created, state: .complete, result: .object([("cards", .array([]))]), failure: nil)
        job.attemptID = "synthetic-account:\(Self.app):attempt"; job.finishedAt = created.addingTimeInterval(60)
        #expect(WorkspaceSession.withoutOldImages(job, cutoff: created) == nil, "A request that ended after the cutoff keeps its images")
        let stripped = try #require(WorkspaceSession.withoutOldImages(job, cutoff: created.addingTimeInterval(120)))
        #expect(stripped.request.images.map(\.data) == [Data(), Data()] && stripped.request.images.map(\.text) == ["Synthetic headline", ""] && stripped.request.images.map(\.mime) == ["image/jpeg", "image/png"])
        #expect(stripped.request.instructions == request.instructions && stripped.result == job.result && stripped.attemptID == job.attemptID && stripped.finishedAt == job.finishedAt && stripped.id == job.id)
        #expect(WorkspaceSession.withoutOldImages(stripped, cutoff: created.addingTimeInterval(120)) == nil, "A request without images is not written again")
        var running = job; running.state = .running
        #expect(WorkspaceSession.withoutOldImages(running, cutoff: .distantFuture) == nil, "A request still running keeps its images")
        // The saved request is rewritten in AI History, and only there.
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let key = try #require(job.attemptID), payload = try JSONEncoder().encode(job)
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "ai_history", key: key, json: payload), .put(namespace: "ai_jobs", key: job.id, json: payload)] } }
        let result = try await session.runStorageCleanup(now: created.addingTimeInterval(200 * Self.day))
        #expect(result.requests == 1 && result.summary == "Removed the images of 1 AI request.")
        let history = try #require(try await session.storeAccess { try $0.document(namespace: "ai_history", key: key) }), saved = try JSONDecoder().decode(AIJob.self, from: history.payload)
        #expect(saved.request.images.allSatisfy { $0.data.isEmpty } && saved.request.images.count == 2 && history.payload.count < payload.count)
        #expect(try await session.storeAccess { try $0.document(namespace: "ai_jobs", key: job.id) }?.payload == payload)
        #expect(try await session.runStorageCleanup(now: created.addingTimeInterval(201 * Self.day)).requests == 0)
    }
}
