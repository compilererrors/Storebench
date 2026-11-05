import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReviewsJobTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001"
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/reviews-jobs.json"))) }
    func session(directory: URL? = nil) async throws -> (WorkspaceSession, Account, URL) { try await SalesJobTests().session(directory: directory) }
    func store(_ root: URL) throws -> EncryptedDocumentStore { try SalesJobTests().store(root) }
    func wait(_ operation: () async throws -> Bool) async throws { try await SalesJobTests().wait(operation) }
    func review(_ id: String = "synthetic-new-review", date: String = "2026-03-01T12:00:00.000Z") -> CustomerReview {
        .init(id: id, rating: 4, title: "Synthetic review", body: "Synthetic feedback.", createdDate: date, territory: "SWE")
    }
    func resource(_ review: CustomerReview) -> JSONText {
        .object([("type", .string("customerReviews")), ("id", .string(review.id)), ("attributes", .object([
            ("rating", .number(Double(review.rating))), ("title", .string(review.title)), ("body", .string(review.body)),
            ("createdDate", .string(review.createdDate)), ("territory", .string(review.territory)), ("reviewerNickname", .string("Omitted synthetic nickname"))]))])
    }
    func page(_ rows: [CustomerReview], next: String? = nil) -> Data {
        let links = JSONText.object(next.map { [("next", .string($0))] } ?? [])
        return JSONText.object([("data", .array(rows.map(resource))), ("links", links)]).data
    }
    func next(_ request: URLRequest, cursor: String) -> String {
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.queryItems = (url.queryItems ?? []).filter { $0.name != "cursor" } + [URLQueryItem(name: "cursor", value: cursor)]; return url.string!
    }
    func transport(_ host: String, account: Account, gate: AnalyticsJobDelayStubProtocol.Gate, rows: [CustomerReview], cursor: String? = nil) throws -> AppStoreConnectClient {
        AnalyticsJobDelayStubProtocol.register(host, gate: gate, bytes: page(rows), path: "/v1/apps/\(appId)/customerReviews", cursor: cursor)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AnalyticsJobDelayStubProtocol.self, StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: config)
    }
    func write(_ rows: [CustomerReview], account: Account, store: EncryptedDocumentStore, at: String = "2026-02-06T12:00:00.000Z") throws {
        let sorted = try CustomerReview.sorted(rows)
        try PartitionedReports.replaceAll(CustomerReview.self, family: "reviews", legacyKey: "reviews", accountId: account.id, appId: appId, store: store,
            stateDirectory: store.directory, bucketOf: { String($0.createdDate.prefix(7)) }, encode: { $0.json }) { _, _ in
                (sorted, .object([("checkedAt", .string(at)), ("limited", .bool(false)), ("fullCheckedAt", .string(at))]))
            }
    }
    func seed(_ job: ReviewsDownloadJob, account: Account, store: EncryptedDocumentStore) throws {
        let key = try ReportJobs.identity(.reviews, accountId: account.id, appId: appId)
        try store.transaction { _ in [.put(namespace: "jobs", key: key, json: job.json.data)] }
    }

    @Test func reviewJobsAndApiFieldsMatchWebWithExactScopeCountersAndFixedGuidance() throws {
        let vector = try fixture()
        guard case .array(let jobs)? = vector["jobs"], case .array(let fields)? = vector["fields"], case .array(let tied)? = vector["tied"] else { throw ReportJobFailure.status }
        for row in jobs {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: ReportJobFailure.status) { try ReviewsDownloadJob(json: input) } }
            else {
                let job = try ReviewsDownloadJob(json: input)
                #expect(job.json == row["expected"], "Synthetic review job: \(row["id"]?.text ?? "unknown")")
                #expect(job.error?.contains("Synthetic untrusted diagnostic") != true)
            }
        }
        for row in fields {
            let data = try #require(row["input"]), resource = try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: data.data)
            if row["rejected"] == .bool(true) { #expect(throws: (any Error).self) { try CustomerReview(apple: resource) } }
            else { #expect(try CustomerReview(apple: resource).json == row["expected"], "Synthetic review fields: \(row["id"]?.text ?? "unknown")") }
        }
        let records = try tied.map { try JSONDecoder().decode(CustomerReview.self, from: $0.data) }
        #expect(try JSONText.array(CustomerReview.sorted(records).map(\.json)) == vector["sorted"])
        #expect(try ReportJobs.name(.reviews, accountId: "synthetic-account", appId: appId) == vector["lockName"]?.text)
    }

    @Test func backgroundDownloadCoalescesBeforeKeychainAndCommitsItsReceiptWithHistory() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await session.reviews(accountId: account.id, appId: appId).map(\.json), gate = AnalyticsJobDelayStubProtocol.Gate()
        let started = try await session.startReviewsDownload(account: account, appId: appId, client: transport("reviews-job-complete.appstoreconnect.test", account: account, gate: gate, rows: [review()]))
        try await wait { gate.pending == 1 }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let same = try await second.startReviewsDownload(account: account, appId: appId)
        #expect(same.id == started.id && same.isActive && same.pages == 0)
        #expect(try await second.reviews(accountId: account.id, appId: appId).map(\.json) == before)
        gate.release(); try await wait { try await second.reviewsDownloadJob(account: account, appId: appId)?.state == .complete }
        let job = try #require(try await second.reviewsDownloadJob(account: account, appId: appId))
        #expect(job.pages == 1 && job.reviews == 1 && job.result?.added == 1 && job.result?.removed == 0)
        #expect(try await second.reviews(accountId: account.id, appId: appId).contains { $0.id == "synthetic-new-review" })
        try await second.verifyBuckets(family: "reviews", accountId: account.id, appId: appId)
        #expect(job.json.stringify().contains("nickname") == false)
    }

    @Test func anotherSessionCancelsAfterProgressAndAnOldStopCannotCancelItsReplacement() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "reviews-job-cancel.appstoreconnect.test", gate = AnalyticsJobDelayStubProtocol.Gate(), candidate = review()
        let client = try transport(host, account: account, gate: gate, rows: [review("synthetic-older-review", date: "2026-02-20T12:00:00.000Z")], cursor: "second")
        StubProtocol.handle(host) { request in (200, [:], page([candidate], next: next(request, cursor: "second"))) }
        let before = try await session.reviews(accountId: account.id, appId: appId).map(\.json)
        let started = try await session.startReviewsDownload(account: account, appId: appId, client: client)
        try await wait { gate.pending == 1 }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault), reader = try store(root), key = "reviews:\(account.id):\(appId)"
        #expect(try await second.reviewsDownloadJob(account: account, appId: appId)?.reviews == 1)
        _ = try await second.cancelReviewsDownload(account: account, appId: appId, id: UUID().uuidString.lowercased())
        #expect(try reader.document(namespace: "job_cancels", key: key) == nil)
        _ = try await second.cancelReviewsDownload(account: account, appId: appId, id: started.id)
        try await wait { try await second.reviewsDownloadJob(account: account, appId: appId)?.state == .cancelled }
        gate.release(); #expect(try await second.reviews(accountId: account.id, appId: appId).map(\.json) == before)
        let fresh = AnalyticsJobDelayStubProtocol.Gate(); fresh.release()
        let replacement = try await session.startReviewsDownload(account: account, appId: appId, client: transport("reviews-job-retry.appstoreconnect.test", account: account, gate: fresh, rows: [candidate]))
        _ = try await second.cancelReviewsDownload(account: account, appId: appId, id: started.id)
        #expect(replacement.id != started.id)
        #expect(try reader.document(namespace: "job_cancels", key: key) == nil)
        try await wait { try await second.reviewsDownloadJob(account: account, appId: appId)?.state == .complete }
    }

    @Test func aConcurrentSaveCannotBeOverwrittenByTheEarlierDownload() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AnalyticsJobDelayStubProtocol.Gate(), reader = try store(root), newer = review("synthetic-concurrent-review")
        _ = try await session.startReviewsDownload(account: account, appId: appId, client: transport("reviews-job-stale.appstoreconnect.test", account: account, gate: gate, rows: [review()]))
        try await wait { gate.pending == 1 }
        try write([newer], account: account, store: reader); gate.release()
        try await wait { try await session.reviewsDownloadJob(account: account, appId: appId)?.state == .failed }
        #expect(try await session.reviewsDownloadJob(account: account, appId: appId)?.code == "SB-REVIEWS-STALE")
        #expect(try await session.reviews(accountId: account.id, appId: appId).map(\.json) == [newer.json])
    }

    @Test func changedAppOrKeyAccessAfterAResponseCannotSaveAnyReview() async throws {
        for removed in [true, false] {
            let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
            let gate = AnalyticsJobDelayStubProtocol.Gate(), reader = try store(root), before = try await session.reviews(accountId: account.id, appId: appId).map(\.json)
            let host = removed ? "reviews-job-scope.appstoreconnect.test" : "reviews-job-key.appstoreconnect.test"
            _ = try await session.startReviewsDownload(account: account, appId: appId, client: transport(host, account: account, gate: gate, rows: [review()]))
            try await wait { gate.pending == 1 }
            let accounts = try #require(try reader.document(namespace: "accounts", key: "all"))
            let changed = Account(id: account.id, name: account.name, keyId: removed ? account.keyId : "SAMPLE0002", keyType: account.keyType, issuerId: account.issuerId, appIds: removed ? [] : account.appIds, appNames: account.appNames)
            try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] }; gate.release()
            try await wait { try reader.document(namespace: "jobs", key: "reviews:\(account.id):\(appId)").map { try ReviewsDownloadJob(json: JSONText.parse($0.payload)).state == .failed } ?? false }
            try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: accounts.payload)] }
            #expect(try await session.reviewsDownloadJob(account: account, appId: appId)?.code == "SB-REVIEWS-SCOPE")
            #expect(try await session.reviews(accountId: account.id, appId: appId).map(\.json) == before)
        }
    }

    @Test func savedUnchangedPagesStopEarlyAndTheWeeklyFullPassStillReadsOlderEdits() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = try store(root), known = review("synthetic-known-review", date: "2026-02-05T12:00:00.000Z"), older = review("synthetic-older-review", date: "2026-02-01T12:00:00.000Z")
        try write([known, older], account: account, store: reader)
        let host = "reviews-job-weekly.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            if request.url!.absoluteString.contains("cursor=") {
                return (200, [:], page([CustomerReview(id: older.id, rating: 2, title: older.title, body: "Synthetic older edit.", createdDate: older.createdDate, territory: older.territory)]))
            }
            return (200, [:], page([known], next: next(request, cursor: "older")))
        }
        let client = try SalesSyncTests().client(host, account: account)
        let early = try await session.downloadReviews(account: account, appId: appId, client: client, now: Date(timeIntervalSince1970: 1_770_465_600))
        #expect(early.unchanged == 1 && early.limited == false && StubProtocol.requests(host).count == 1)
        #expect(try await session.reviewsMeta(accountId: account.id, appId: appId)?["fullCheckedAt"]?.string == "2026-02-06T12:00:00.000Z")
        let full = try await session.downloadReviews(account: account, appId: appId, client: client, now: Date(timeIntervalSince1970: 1_772_400_000))
        #expect(full.updated == 1 && full.unchanged == 1 && !full.limited && StubProtocol.requests(host).count == 3)
        #expect(try await session.reviews(accountId: account.id, appId: appId).first { $0.id == older.id }?.body == "Synthetic older edit.")
    }

    @Test func duplicateOutOfOrderAndCyclicPagesFailWithoutSavingAPartialSnapshot() async throws {
        for kind in ["duplicate", "order", "cycle", "empty"] {
            let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
            let host = "reviews-job-\(kind).appstoreconnect.test", before = try await session.reviews(accountId: account.id, appId: appId).map(\.json)
            StubProtocol.handle(host) { request in
                let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
                if kind == "empty" { return (200, [:], page([], next: next(request, cursor: "one"))) }
                let row = kind == "duplicate" ? review() : review("synthetic-\(cursor ?? "first")", date: kind == "order" && cursor != nil ? "2026-03-02T12:00:00.000Z" : "2026-03-01T12:00:00.000Z")
                let following = cursor == nil ? "one" : cursor == "one" ? "two" : "one"
                return (200, [:], page([row], next: next(request, cursor: following)))
            }
            await #expect(throws: (any Error).self) { try await session.downloadReviews(account: account, appId: appId, client: SalesSyncTests().client(host, account: account)) }
            #expect(try await session.reviewsDownloadJob(account: account, appId: appId)?.code == "SB-REVIEWS-INTEGRITY")
            #expect(try await session.reviews(accountId: account.id, appId: appId).map(\.json) == before)
        }
    }

    @Test func aCompleteDownloadCanReadMoreThanOneThousandPagesWithoutDroppingSavedReviews() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "reviews-job-large.appstoreconnect.test", before = try await session.reviews(accountId: account.id, appId: appId).map(\.id)
        StubProtocol.handle(host) { request in
            let value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
            let index = value.flatMap(Int.init) ?? 0
            return (200, [:], page([review("synthetic-page-\(index)")], next: index < 1000 ? next(request, cursor: String(index + 1)) : nil))
        }
        let changes = try await session.downloadReviews(account: account, appId: appId, client: SalesSyncTests().client(host, account: account))
        #expect(changes.added == 1001 && changes.removed == 0 && StubProtocol.requests(host).count == 1001)
        let job = try #require(try await session.reviewsDownloadJob(account: account, appId: appId))
        #expect(job.state == .complete && job.pages == 1001 && job.reviews == 1001)
        let saved = try await session.reviews(accountId: account.id, appId: appId).map(\.id)
        #expect(Set(before).isSubset(of: Set(saved)) && saved.count == before.count + 1001)
    }
}

@Suite(.serialized) struct ReviewsJobProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test(arguments: [true, false]) func aSaveWaitingForItsOwnedReportMutexRechecksScopeAndExactCancellation(cancel: Bool) async throws {
        let fixture = try ReviewsJobTests(), root = try TestIsolation.require().appendingPathComponent(cancel ? "reviews-save-cancel-policy" : "reviews-save-scope-policy")
        let (session, account, _) = try await fixture.session(directory: root), reader = try fixture.store(root)
        let before = try await session.reviews(accountId: account.id, appId: fixture.appId).map(\.json)
        let original = try #require(try reader.document(namespace: "accounts", key: "all")), ready = root.appendingPathComponent("response-ready")
        let host = cancel ? "reviews-save-cancel.appstoreconnect.test" : "reviews-save-scope.appstoreconnect.test"
        StubProtocol.handle(host) { _ in
            try! JobLock.exclusive(ready, "ready"); return (200, [:], fixture.page([fixture.review()]))
        }
        let client = try SalesSyncTests().client(host, account: account)
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let operation = Task { try await session.downloadReviews(account: account, appId: fixture.appId, client: client) }
        try await fixture.wait {
            guard FileManager.default.fileExists(atPath: ready.path), let saved = try reader.document(namespace: "jobs", key: "reviews:\(account.id):\(fixture.appId)") else { return false }
            return try ReviewsDownloadJob(json: JSONText.parse(saved.payload)).phase == .saving
        }
        let name = "reviews-" + JSONText.string("\(account.id)\u{0}\(fixture.appId)").rawSHA256.prefix(32), mutex = reader.directory.appendingPathComponent("\(name).mutex")
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        #expect(try FileMutex.tryLock(mutex) == nil)
        if cancel {
            let running = try #require(try await second.reviewsDownloadJob(account: account, appId: fixture.appId))
            _ = try await second.cancelReviewsDownload(account: account, appId: fixture.appId, id: running.id)
        } else {
            let removed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
            try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(removed)]).data)] }
        }
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        await #expect(throws: (any Error).self) { try await operation.value }
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: original.payload)] }
        let job = try #require(try await session.reviewsDownloadJob(account: account, appId: fixture.appId))
        #expect(job.state == (cancel ? .cancelled : .failed))
        #expect(job.code == (cancel ? nil : "SB-REVIEWS-SCOPE"))
        #expect(try await session.reviews(accountId: account.id, appId: fixture.appId).map(\.json) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }
    @Test(arguments: [true, false]) func aLiveOwnerNeverExpiresAndInterruptionKeepsTheExactCommittedReceipt(committed: Bool) async throws {
        let fixture = try ReviewsJobTests(), root = try TestIsolation.require().appendingPathComponent(committed ? "reviews-job-complete-policy" : "reviews-job-interrupted-policy")
        let id = committed ? "00000000-0000-4000-8000-000000000111" : "00000000-0000-4000-8000-000000000112"
        let (session, account, _) = try await fixture.session(directory: root), reader = try fixture.store(root)
        var job = ReviewsDownloadJob(id: id, now: Date(timeIntervalSince1970: 1)); try fixture.seed(job, account: account, store: reader)
        let mutex = reader.directory.appendingPathComponent(try ReportJobs.name(.reviews, accountId: account.id, appId: fixture.appId) + ".lock.mutex")
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        let same = try await session.startReviewsDownload(account: account, appId: fixture.appId)
        #expect(same.id == id && same.isActive)
        #expect(try FileMutex.tryLock(mutex) == nil)
        if committed {
            let row = fixture.review("synthetic-policy-review"); job.pages = 1; job.reviews = 1; job.complete(.init(added: 1), at: CustomerReview.isoString(Date()))
            try PartitionedReports.replaceAll(CustomerReview.self, family: "reviews", legacyKey: "reviews", accountId: account.id, appId: fixture.appId, store: reader,
                stateDirectory: reader.directory, bucketOf: { String($0.createdDate.prefix(7)) }, encode: { $0.json }, additionalWrites: {
                    [.put(namespace: "jobs", key: "reviews:\(account.id):\(fixture.appId)", json: job.json.data)]
                }) { previous, _ in
                    (try CustomerReview.sorted((previous ?? []) + [row]), .object([("checkedAt", .string(CustomerReview.isoString(Date()))), ("limited", .bool(false))]))
                }
        }
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        try await fixture.wait { if let proof = try FileMutex.tryLock(mutex) { proof.release(); return true }; return false }
        let recovered = try #require(try await session.reviewsDownloadJob(account: account, appId: fixture.appId))
        #expect(recovered.id == id && recovered.state == (committed ? .complete : .failed))
        #expect(try await session.reviews(accountId: account.id, appId: fixture.appId).contains { $0.id == "synthetic-policy-review" } == committed)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }
}
