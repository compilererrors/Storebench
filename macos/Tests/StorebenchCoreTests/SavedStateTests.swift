import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct SavedStateTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func aRepeatedReadIsDueOnlyWhenSomethingChangedIsWorkingOrIsOld() {
        var watch = SavedStateWatch()
        let start = ContinuousClock.now
        #expect(watch.due("synthetic-1", working: false, now: start))
        watch.read("synthetic-1", at: start)
        #expect(!watch.due("synthetic-1", working: false, now: start + .seconds(1)))
        #expect(watch.due("synthetic-2", working: false, now: start + .seconds(1)))
        #expect(watch.due("synthetic-1", working: true, now: start + .seconds(1)))
        #expect(watch.due(nil, working: false, now: start + .seconds(1)))
        #expect(watch.due("synthetic-1", working: false, now: start + SavedStateWatch.staleAfter))
        // A read whose token could not be taken is read again the next time.
        watch.read(nil, at: start)
        #expect(watch.due("synthetic-1", working: false, now: start + .seconds(1)))
    }

    @Test func aNamespaceStampFollowsItsOwnWritesAndEveryOtherConnection() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await session.storeAccess { try $0.namespaceStamp("revisions") }
        // A write elsewhere on this connection leaves the stamp of the saved revisions alone.
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "synthetic_notes", key: "one", json: Data("{}".utf8))] } }
        #expect(try await session.storeAccess { try $0.namespaceStamp("revisions") } == before)
        #expect(try await session.storeAccess { try $0.namespaceStamp("synthetic_notes") } != before)
        // A put replaces the payload and adds one to the revision without a second document; a delete starts it again at one.
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "synthetic_notes", key: "one", json: Data("[]".utf8))] } }
        #expect(try await session.storeAccess { try $0.revision(namespace: "synthetic_notes", key: "one") } == 2)
        #expect(try await session.storeAccess { try $0.document(namespace: "synthetic_notes", key: "one")?.payload } == Data("[]".utf8))
        #expect(try await session.storeAccess { try $0.documents(namespace: "synthetic_notes").count } == 1)
        try await session.storeAccess { store in try store.transaction { _ in [.delete(namespace: "synthetic_notes", key: "one"), .put(namespace: "synthetic_notes", key: "one", json: Data("{}".utf8))] } }
        #expect(try await session.storeAccess { try $0.revision(namespace: "synthetic_notes", key: "one") } == 1)
        #expect(try await session.storeAccess { try $0.revision(namespace: "synthetic_notes", key: "missing") } == nil)
        // Another connection's commit changes every namespace's stamp, since this connection cannot tell where it wrote.
        let other = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        try other.transaction { _ in [.put(namespace: "synthetic_notes", key: "two", json: Data("{}".utf8))] }
        #expect(try await session.storeAccess { try $0.namespaceStamp("revisions") } != before)
    }

    @Test func theSavedStateTokenIgnoresSavedScreenReadsAndFollowsSavedWork() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await session.savedStateToken()
        await session.saveViewRead(key: "synthetic-screen", data: Data("synthetic read".utf8), readAt: Date(), epoch: await session.viewReadEpoch)
        #expect(try await session.savedStateToken() == before)
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "synthetic_notes", key: "one", json: Data("{}".utf8))] } }
        #expect(try await session.savedStateToken() != before)
    }

    @Test func revisionListsStayTheSameUntilARevisionIsWrittenHereOrElsewhere() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001"
        let first = try await session.revisions(accountId: account.id, appId: app)
        #expect(!first.isEmpty)
        // Unrelated writes, and reads repeated while nothing changed, return the same revisions in the same order.
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "synthetic_notes", key: "one", json: Data("{}".utf8))] } }
        for _ in 0..<3 { #expect(try await session.revisions(accountId: account.id, appId: app).map(\.id) == first.map(\.id)) }
        #expect(try await session.archivedHistory(accountId: account.id, appId: app).map(\.id) == first.map(\.id))
        #expect(try await session.archivedHistory(accountId: account.id, appId: app).map(\.id) == first.map(\.id))
        // A revision removed by another connection is gone from the next read, and one removed here as well.
        let other = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let saved = try other.documents(namespace: "revisions", prefix: account.id + ":" + app + ":")
        let removed = try #require(saved.first)
        try other.transaction { _ in [.delete(namespace: "revisions", key: removed.key)] }
        #expect(try await session.revisions(accountId: account.id, appId: app).count == first.count - 1)
        #expect(try await session.archivedHistory(accountId: account.id, appId: app).count == first.count - 1)
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "revisions", key: removed.key, json: removed.payload)] } }
        #expect(try await session.revisions(accountId: account.id, appId: app).map(\.id) == first.map(\.id))
        // Memory given back under pressure is read again from the database.
        await session.trimCachedMemory()
        #expect(try await session.revisions(accountId: account.id, appId: app).map(\.id) == first.map(\.id))
    }

    @Test func theSharesOfOneWindowAndTheSessionFitTheMemoryBudget() {
        for megabytes in CachePolicy.memoryChoices {
            let budget = CachePolicy(level: .custom, customMemoryMB: megabytes).budget(), total = megabytes * 1_048_576
            let shares = [budget.appleReads, budget.decodedRevisions, budget.draftSources, budget.archivedRevisions, budget.pricingScreens, budget.thumbnails, budget.windowReads]
            #expect(shares.reduce(0) { $0 + $1.bytes } + total / 200 <= total)
            #expect(budget.savedReads.bytes <= budget.windowReads.bytes)
        }
    }

    @Test func aRateLimitWaitIsApplesOwnWithinALimitAndTheFallbackOtherwise() throws {
        let key = "SYNTHETICRATE1", url = try #require(URL(string: "https://rate-limit-wait.appstoreconnect.test"))
        func answer(_ status: Int, _ headers: [String: String]) throws -> HTTPURLResponse { try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)) }
        #expect(AppleRequestBudget.pause(keyId: key, fallback: .seconds(5)) == .seconds(5))
        AppleRequestBudget.record(try answer(429, ["Retry-After": "12"]), keyId: key)
        #expect(AppleRequestBudget.pause(keyId: key, fallback: .seconds(5)) == .seconds(12))
        #expect(!AppleRequestBudget.allowsReadingAhead(keyId: key))
        AppleRequestBudget.record(try answer(429, ["Retry-After": "600"]), keyId: key)
        #expect(AppleRequestBudget.pause(keyId: key, fallback: .seconds(5)) == nil)
        AppleRequestBudget.record(try answer(429, [:]), keyId: key)
        #expect(AppleRequestBudget.pause(keyId: key, fallback: .seconds(5)) == .seconds(5))
        // The next ordinary answer ends the wait and reports what is left of the hour.
        AppleRequestBudget.record(try answer(429, ["Retry-After": "30"]), keyId: key)
        AppleRequestBudget.record(try answer(200, ["X-Rate-Limit": "user-hour-lim:3600;user-hour-rem:3000;"]), keyId: key)
        #expect(AppleRequestBudget.pause(keyId: key, fallback: .seconds(5)) == .seconds(5))
        #expect(AppleRequestBudget.allowsReadingAhead(keyId: key))
    }

    private actor Held {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = 0
        func wait() async { entered += 1; await withCheckedContinuation { waiting.append($0) } }
        func release() { waiting.forEach { $0.resume() }; waiting = [] }
    }
    private actor Calls {
        private(set) var count = 0
        func next() -> Data { count += 1; return Data("synthetic response \(count)".utf8) }
    }
    @Test func aReadBeyondTheSharedLimitIsKeptForTheNextReader() async throws {
        let cache = AppStoreReadCache(lifetime: .seconds(3_600)), held = Held(), calls = Calls()
        let tasks = (0..<16).map { index in Task { try await cache.read("synthetic-held-\(index)") { await held.wait(); return Data() } } }
        let deadline = ContinuousClock.now + .seconds(10)
        while await held.entered < 16 {
            guard ContinuousClock.now < deadline else { Issue.record("The shared reads did not start."); break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let first = try await cache.read("synthetic-extra") { await calls.next() }
        let second = try await cache.read("synthetic-extra") { await calls.next() }
        #expect(first == second && first == Data("synthetic response 1".utf8))
        #expect(await calls.count == 1)
        // A Refresh that starts afterwards still reads again.
        let refreshed = try await AppStoreReadCache.refreshing { try await cache.read("synthetic-extra") { await calls.next() } }
        #expect(refreshed == Data("synthetic response 2".utf8))
        await held.release()
        for task in tasks { _ = try await task.value }
    }

    @Test func aReviewWithOneStepSaysStepAndNotSteps() throws {
        let one = try #require(PublishReview(Self.review(steps: 1))), two = try #require(PublishReview(Self.review(steps: 2)))
        #expect(PublishingReviewPresentation.activity(one) == "0 of 1 step complete")
        #expect(PublishingReviewPresentation.activity(two) == "0 of 2 steps complete")
        #expect(PublishingReviewPresentation.progress(one).hasPrefix("0 of 1 step done"))
        #expect(PublishingReviewPresentation.progress(two).hasPrefix("0 of 2 steps done"))
    }
    private static func review(steps count: Int) -> JSONText {
        let plan = PublishPlan(title: "Synthetic review", request: PublishRequest(accountId: "synthetic-account", appId: "1000000001", scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio"),
                               fingerprint: String(repeating: "a", count: 64),
                               steps: (1...count).map { PublishStep(key: "step-\($0)", group: nil, label: "Synthetic step \($0)", detail: "Synthetic", before: nil, after: nil, kind: .verify, method: nil, path: [.string("appStoreVersions")], body: nil, asset: nil, guardValue: nil, state: "pending", resultId: nil) },
                               notes: [], settled: [])
        return PublishReview(plan: plan, id: "00000000-0000-4000-8000-000000000001", now: Date(timeIntervalSince1970: 1_800_000_000)).json
    }
}
