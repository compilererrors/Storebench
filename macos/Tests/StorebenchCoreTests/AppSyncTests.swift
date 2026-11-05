import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AppSyncTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001"
    func vector() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/sync-jobs.json"))) }
    func environment(directory: URL? = nil) async throws -> (WorkspaceSession, Account, URL) { try await SalesJobTests().session(directory: directory) }
    func seed(_ job: SyncJob, account: Account, store: EncryptedDocumentStore) throws {
        try store.transaction { _ in [.put(namespace: "jobs", key: "sync:\(account.id):\(appId)", json: job.json.data)] }
    }
    @Test func idleReportReadsAvoidMutexWritesAndActiveReadsRetainExactOwnershipRecovery() async throws {
        let (session, account, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SalesJobTests().store(root)
        let name = try ReportJobs.name(.sync, accountId: account.id, appId: appId)
        let mutex = store.directory.appendingPathComponent(name + ".lock.mutex")
        #expect(try await session.syncJob(account: account, appId: appId) == nil)
        #expect(!FileManager.default.fileExists(atPath: mutex.path))
        var complete = SyncJob(id: "00000000-0000-4000-8000-000000000406", accountId: account.id, appId: appId,
                               items: AppSync.pending().map { SyncItem(key: $0.key, state: .attention, detail: "Synthetic idle result") }, now: Date())
        complete.state = .complete
        try seed(complete, account: account, store: store)
        #expect(try await session.syncJob(account: account, appId: appId)?.id == complete.id)
        #expect(!FileManager.default.fileExists(atPath: mutex.path))
        let running = SyncJob(id: "00000000-0000-4000-8000-000000000407", accountId: account.id, appId: appId, items: AppSync.pending(), now: Date())
        let owner = try #require(try ReportJobs.acquire(.sync, accountId: account.id, appId: appId, directory: store.directory, id: running.id))
        defer { owner.release() }
        try ReportJobs.start(running, ownership: owner, store: store)
        let active = try #require(try await session.syncJob(account: account, appId: appId))
        #expect(active.id == running.id && active.isActive)
        owner.release()
        let interrupted = try #require(try await session.syncJob(account: account, appId: appId))
        #expect(interrupted.id == running.id && interrupted.state == .failed && interrupted.counts.attention == 7)
        #expect(FileManager.default.fileExists(atPath: mutex.path))
        try await session.signOut()
    }
    @Test func contractsCountsRetryAndReuseMatchPrimary() throws {
        let fixture = try vector()
        guard case .array(let jobs)? = fixture["jobs"], case .array(let reuse)? = fixture["reuse"] else { throw SyncFailure.status }
        for row in jobs {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: SyncFailure.status) { try SyncJob(json: input) } }
            else {
                let job: SyncJob
                do { job = try SyncJob(json: input) }
                catch { Issue.record("Could not read primary accepted synthetic vector: \(row["id"]?.text ?? "unknown")"); continue }
                #expect(job.json == row["expected"], "Synthetic sync job: \(row["id"]?.text ?? "unknown")")
                let counts = job.counts
                #expect(JSONText.object([("total", .number(Double(counts.total))), ("synced", .number(Double(counts.synced))), ("checked", .number(Double(counts.checked))), ("attention", .number(Double(counts.attention)))]) == row["counts"])
                #expect(job.needsRetry == (row["needsRetry"] == .bool(true)))
            }
        }
        for row in reuse {
            let item = try SyncItem(json: #require(row["item"])), mode = try #require(row["mode"]?.text.flatMap(SyncJob.Mode.init(rawValue:)))
            guard case .number(let milliseconds)? = row["now"] else { throw SyncFailure.status }
            #expect(SyncJob.reuse(item, mode: mode, now: Date(timeIntervalSince1970: milliseconds / 1000)) == (row["expected"] == .bool(true)))
        }
        #expect(try ReportJobs.name(.sync, accountId: "synthetic-account", appId: appId) == fixture["lockName"]?.text)
    }
    @Test func salesAndAnalyticsKeepEveryMissingDateUnknown() throws {
        let fixture = try vector(), checked = try #require(fixture["checkedAt"]?.text)
        guard case .array(let sales)? = fixture["sales"], case .array(let analytics)? = fixture["analytics"] else { throw SyncFailure.status }
        for row in sales {
            let result = try SalesDownloadJob.Result(json: #require(row["result"]))
            #expect(AppSync.salesItem(result, checkedAt: checked).json == row["expected"])
        }
        for row in analytics {
            let input = try #require(row["result"])
            guard case .number(let count)? = input["instances"] else { throw SyncFailure.status }
            var result = AnalyticsSyncResult(); result.instances = Int(count); result.changes.added = result.instances
            #expect(AppSync.analyticsItem(result, checkedAt: checked, days: 7).json == row["expected"])
        }
    }
    @Test func legacyTimestampsAreInterpretedAndStoredLiterally() throws {
        #expect(ReportTimestamps.date("2026-02-30") == ASO.iso("2026-03-02T00:00:00Z"))
        #expect(ReportTimestamps.date("2026-01-10T24:00:00Z") == ASO.iso("2026-01-11T00:00:00Z"))
        #expect(ReportTimestamps.date("2026-01-10T12:13:14+0200") == ASO.iso("2026-01-10T10:13:14Z"))
        #expect(ReportTimestamps.date("2026-01-10T12:13:14-02:30") == ASO.iso("2026-01-10T14:43:14Z"))
        #expect(ReportTimestamps.date("Sat, 10 Jan 2026 08:00:00 GMT") == ASO.iso("2026-01-10T08:00:00Z"))
        #expect(ReportTimestamps.date("2026-01-10T24:00:01Z") == nil)
    }
    @Test func statusTimestampKeepsTheLatestInstantAndLastEquivalentSpelling() async throws {
        let (session, account, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SalesJobTests().store(root)
        let timestamps = ["2026-01-09T23:00:00Z", "2026-01-10T10:00:00Z", "2026-01-10T12:00:00+0200", "2026-01-10T09:59:59Z",
                          "Sat, 10 Jan 2026 10:00:00 GMT", "2026-01-10T09:00:00-01:00", "2026-01-10T11:59:59+0200"]
        let items = zip(AppSync.sources, timestamps).map { source, date in SyncItem(key: source.0, state: .attention, detail: "Synthetic timestamp check", checkedAt: date) }
        var job = SyncJob(id: "00000000-0000-4000-8000-000000000405", accountId: account.id, appId: appId, items: items, now: try #require(ReportTimestamps.date("2026-01-10T09:30:00Z")))
        job.state = .complete
        try seed(job, account: account, store: store)
        for _ in 0..<20 {
            let result = try #require(try await session.syncStatus(account: account, appId: appId))
            #expect(result.updatedAt == timestamps[5])
            #expect(result.items.map(\.checkedAt) == timestamps.map(Optional.some))
        }
        #expect(try store.document(namespace: "jobs", key: "sync:\(account.id):\(appId)")?.payload == job.json.data)
        try await session.signOut()
    }
    @Test func malformedOrForeignAggregateCannotRecoverReplaceOrCancel() async throws {
        let (session, account, root) = try await environment(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SalesJobTests().store(root)
        let foreign = SyncJob(id: "00000000-0000-4000-8000-000000000082", accountId: "synthetic-other-account", appId: appId, items: AppSync.pending(), now: Date())
        try seed(foreign, account: account, store: store)
        let before = try #require(try store.document(namespace: "jobs", key: "sync:\(account.id):\(appId)"))
        await #expect(throws: (any Error).self) { try await session.syncStatus(account: account, appId: appId) }
        await #expect(throws: (any Error).self) { try await session.startSync(account: account, appId: appId) }
        await #expect(throws: (any Error).self) { try await session.cancelSync(account: account, appId: appId, id: foreign.id) }
        #expect(try store.document(namespace: "jobs", key: before.key)?.payload == before.payload)
        #expect(try store.document(namespace: "job_cancels", key: before.key) == nil)
    }
    @Test func recoveryKeepsCompletedSourcesAndNeverExpiresALiveOwner() async throws {
        let (session, account, root) = try await environment(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SalesJobTests().store(root), now = try #require(ASO.iso("2026-02-01T12:00:00Z"))
        let id = "00000000-0000-4000-8000-000000000083"
        var job = SyncJob(id: id, accountId: account.id, appId: appId, items: AppSync.pending(), now: now)
        job.items[1] = SyncItem(key: "pricing", state: .synced, detail: "Synthetic saved check.", checkedAt: job.updatedAt)
        let owner = try #require(try ReportJobs.acquire(.sync, accountId: account.id, appId: appId, directory: store.directory, id: id))
        try ReportJobs.start(job, ownership: owner, store: store)
        #expect(try await session.syncJob(account: account, appId: appId, now: now.addingTimeInterval(86_400 * 365))?.state == .running)
        owner.release()
        let recovered = try #require(try await session.syncJob(account: account, appId: appId))
        #expect(recovered.state == .failed && recovered.code == "SB-SYNC-INTERRUPTED")
        #expect(recovered.items[1].state == .synced)
        #expect(recovered.items.filter { $0.state == .attention }.count == 6)
        #expect(try await session.syncJob(account: account, appId: appId)?.json == recovered.json)
    }
    @Test func aggregateFollowsExistingJobAndCancelsOnlyItsBoundChild() async throws {
        let (session, account, root) = try await environment(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let gate = AnalyticsJobDelayStubProtocol.Gate(), host = "sync-owned-child.appstoreconnect.test"
        let client = try SalesJobTests().transport(host, account: account, gate: gate)
        StubProtocol.handle(host) { request in
            if request.url!.path.contains("inAppPurchasesV2") || request.url!.path.contains("subscriptionGroups") { return (200, [:], Data(#"{"data":[],"links":{}}"#.utf8)) }
            return (403, [:], Data(#"{"errors":[]}"#.utf8))
        }
        let (job, task) = try await session.createSync(account: account, appId: appId, client: client, mode: .refresh, reuseRunning: true, now: Date())
        let ownedTask = try #require(task)
        try await SalesJobTests().wait { gate.pending == 1 }
        let followed = try await second.startSync(account: account, appId: appId, mode: .refresh)
        #expect(followed.id == job.id && followed.isActive)
        let child = try #require(try await second.salesDownloadJob(account: account, appId: appId))
        let children = try await second.storeAccess { try SyncChildren(JSONText.parse(#require(try $0.document(namespace: "sync_children", key: "\(account.id):\(appId)")).payload), accountId: account.id, appId: appId) }
        #expect(children.id == job.id && children.entries.contains { $0.key == "sales" && $0.id == child.id })
        _ = try await second.cancelSync(account: account, appId: appId, id: job.id)
        await #expect(throws: (any Error).self) { try await ownedTask.value }
        #expect(try await second.syncJob(account: account, appId: appId)?.state == .cancelled)
        #expect(try await second.salesDownloadJob(account: account, appId: appId)?.state == .cancelled)
        gate.release()
        let (next, nextTask) = try await session.createSync(account: account, appId: appId, client: client, mode: .refresh, reuseRunning: true, now: Date())
        #expect(next.id != job.id)
        _ = try await second.cancelSync(account: account, appId: appId, id: job.id)
        #expect(try await second.syncJob(account: account, appId: appId)?.id == next.id)
        _ = try await nextTask?.value
    }
    @Test func setupReadsOnlyMetadataAndCannotEraseSavedSourceChecks() async throws {
        let (session, account, root) = try await environment(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "sync-readonly-setup.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "GET" && request.url!.path == "/v1/apps/1000000001/analyticsReportRequests")
            return (200, [:], Data(#"{"data":[],"links":{}}"#.utf8))
        }
        let client = try SalesSyncTests().client(host, account: account)
        let before = try await session.salesFileRecords(account: account, appId: appId).map(\.json)
        let status = try #require(try await session.refreshSyncSetup(account: account, appId: appId, client: client))
        #expect(status.statusOnly && status.counts.synced == 0)
        #expect(status.items.first { $0.key == "sales" }?.state == .ready)
        #expect(status.items.first { $0.key == "downloads" }?.code == "SB-ANALYTICS-SETUP")
        #expect(try await session.salesFileRecords(account: account, appId: appId).map(\.json) == before)
        let store = try SalesJobTests().store(root)
        var receipt = SyncJob(id: "00000000-0000-4000-8000-000000000084", accountId: account.id, appId: appId, items: AppSync.pending().map { SyncItem(key: $0.key, state: .attention, detail: "Synthetic check.") }, now: Date())
        receipt.state = .complete; receipt.items[2] = SyncItem(key: "sales", state: .partial, detail: "Synthetic missing day.", checkedAt: receipt.updatedAt)
        try seed(receipt, account: account, store: store)
        let next = try #require(try await session.refreshSyncSetup(account: account, appId: appId, client: client))
        #expect(next.items[2].state == .partial && next.counts.synced == 0)
    }
    @Test func malformedSavedPricesFailClosedWithoutReplacingThem() async throws {
        let (session, account, root) = try await environment(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SalesJobTests().store(root), key = "\(account.id):\(appId)"
        let invalid = JSONText.object([("checkedAt", .string("2026-01-01T00:00:00Z")), ("snapshot", .object([("baseTerritory", .string("USA")), ("baseCurrency", .string("USD")), ("fetchedAt", .string("2026-01-01T00:00:00Z")), ("rows", .array([.object([("source", .string("synthetic-invalid"))])]))]))])
        try store.transaction { _ in [.put(namespace: "apple_prices", key: key, json: invalid.data)] }
        await #expect(throws: (any Error).self) { try await session.syncStatus(account: account, appId: appId) }
        await #expect(throws: (any Error).self) { try await session.startSync(account: account, appId: appId) }
        #expect(try store.document(namespace: "apple_prices", key: key)?.payload == invalid.data)
    }
    @Test func parentCancellationRollsBackChildCreationAndItsIdentityTogether() async throws {
        let (session, account, root) = try await environment(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SalesJobTests().store(root), id = "00000000-0000-4000-8000-000000000085"
        let owner = try #require(try ReportJobs.acquire(.sync, accountId: account.id, appId: appId, directory: store.directory, id: id)); defer { owner.release() }
        var job = SyncJob(id: id, accountId: account.id, appId: appId, items: AppSync.pending(), now: Date())
        job.items[6] = SyncItem(key: "reviews", state: .running, detail: "Synthetic owned source.")
        let children = SyncChildren(id: id, accountId: account.id, appId: appId)
        try ReportJobs.start(job, ownership: owner, store: store, additionalWrites: [.put(namespace: "sync_children", key: "\(account.id):\(appId)", json: children.json.data)])
        #expect(try ReportJobs.cancel(SyncJob.self, family: .sync, accountId: account.id, appId: appId, id: id, store: store))
        let binding = SyncChildBinding(ownership: owner, accountId: account.id, appId: appId, key: "reviews")
        await #expect(throws: CancellationError.self) { try await session.createReviewsDownload(account: account, appId: appId, client: nil, reuseRunning: false, now: Date(), binding: binding) }
        #expect(try store.document(namespace: "jobs", key: "reviews:\(account.id):\(appId)") == nil)
        #expect(try store.document(namespace: "sync_children", key: "\(account.id):\(appId)")?.payload == children.json.data)
    }
    @Test func historicalDiagnosticsNeverSupplyDisplayText() throws {
        let item = try SyncItem(json: .object([("key", .string("reviews")), ("state", .string("failed")), ("detail", .string("Synthetic untrusted diagnostic"))]))
        #expect(!item.displayDetail.contains("Synthetic untrusted diagnostic"))
        #expect(item.json["detail"] == .string("Synthetic untrusted diagnostic"))
    }
    @Test func allAppsDeduplicatesConfiguredAppsAndKeepsEveryAccountScopeSeparate() async throws {
        let (session, account, root) = try await environment(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SalesJobTests().store(root)
        let first = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [appId, appId, "1000000002"], appNames: nil)
        let second = Account(id: "synthetic-second-account", name: "Synthetic second account", keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [appId], appNames: nil)
        try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(first), WorkspaceSession.json(second)]).data)] }
        let result = try await session.startAllSync(mode: .refresh)
        #expect(result.total == 3 && result.started == 3 && result.failed == 0)
        #expect(Set(result.jobs.map { "\($0.accountId):\($0.appId)" }) == Set(["\(account.id):\(appId)", "\(account.id):1000000002", "\(second.id):\(appId)"]))
        for entry in result.jobs {
            let selected = entry.accountId == first.id ? first : second
            try await SalesJobTests().wait { try await session.syncJob(account: selected, appId: entry.appId)?.isActive == false }
            let job = try #require(try await session.syncJob(account: selected, appId: entry.appId))
            #expect(job.id == entry.id && job.accountId == entry.accountId && job.appId == entry.appId)
            #expect(job.state == .complete && job.counts.checked == 7 && job.counts.synced == 0)
        }
    }
    @Test func downloadSlotsBoundActiveJobsAndCancelledWaitersCannotTakeANewerSlot() async throws {
        let slots = SyncSlots(limit: 2)
        try await slots.acquire(); try await slots.acquire()
        let cancelled = Task { try await slots.acquire() }
        try await SalesJobTests().wait { await slots.status().queued == 1 }
        cancelled.cancel(); await #expect(throws: CancellationError.self) { try await cancelled.value }
        let status = await slots.status(); #expect(status.active == 2 && status.queued == 0)
        let next = Task { try await slots.acquire() }
        try await SalesJobTests().wait { await slots.status().queued == 1 }
        await slots.release(); try await next.value
        #expect(await slots.status().active == 2)
        await slots.release(); await slots.release(); #expect(await slots.status().active == 0)
    }
}

@Suite(.serialized) struct SyncOwnedProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test(arguments: [true, false]) func completedReceiptsAndInterruptedOwnersSurviveOwnedProcessExit(committed: Bool) async throws {
        let root = try TestIsolation.require().appendingPathComponent(committed ? "sync-job-complete-policy" : "sync-job-interrupted-policy")
        let fixture = try AppSyncTests(), (session, account, _) = try await fixture.environment(directory: root), store = try SalesJobTests().store(root)
        let id = committed ? "00000000-0000-4000-8000-000000000121" : "00000000-0000-4000-8000-000000000122"
        var job = SyncJob(id: id, accountId: account.id, appId: fixture.appId, items: AppSync.pending(), now: Date(timeIntervalSince1970: 0))
        if committed { job.state = .complete; job.items = job.items.map { SyncItem(key: $0.key, state: .partial, detail: "Synthetic unavailable report.", checkedAt: job.updatedAt) } }
        try fixture.seed(job, account: account, store: store)
        let mutex = store.directory.appendingPathComponent(try ReportJobs.name(.sync, accountId: account.id, appId: fixture.appId) + ".lock.mutex")
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        #expect(try await session.syncJob(account: account, appId: fixture.appId)?.state == (committed ? .complete : .running))
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        try await SalesJobTests().wait { if let proof = try FileMutex.tryLock(mutex) { proof.release(); return true }; return false }
        let recovered = try #require(try await session.syncJob(account: account, appId: fixture.appId))
        #expect(recovered.id == id && recovered.state == (committed ? .complete : .failed))
        #expect(recovered.counts.synced == 0)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }
}
