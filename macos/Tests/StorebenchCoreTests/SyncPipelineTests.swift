import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

extension AppSyncTests {

    func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(try await condition()) {
            guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func client(account: Account, appId: String, gate: AnalyticsJobDelayStubProtocol.Gate,
                source: String = "material") throws -> AppStoreConnectClient {
        _ = try TestIsolation.require()
        let host = "sync-pipeline-\(UUID().uuidString.lowercased()).appstoreconnect.test"
        let app = JSONText.object([("data", .object([("type", .string("apps")), ("id", .string(appId)),
            ("attributes", .object([("name", .string("Synthetic app")), ("bundleId", .string("example.synthetic.pipeline")),
                                    ("sku", .string("SYNTHETIC")), ("primaryLocale", .string("en-US"))]))]))])
        let empty = Data(#"{"data":[],"links":{}}"#.utf8)
        let path: String, bytes: Data, headers: [String: String]
        switch source {
        case "sales":
            path = "/v1/salesReports"; headers = ["Content-Type": "application/a-gzip"]
            bytes = SalesSyncTests.report([["APPLE", "SYNTHETIC", appId, "1F", "3", "0.99", "02/03/2026", "02/03/2026", "US", ""]])
        case "finance": path = "/v1/financeReports"; bytes = FinanceSyncTests.january; headers = ["Content-Type": "application/a-gzip"]
        case "downloads", "engagement": path = "/v1/apps/\(appId)/analyticsReportRequests"; bytes = empty; headers = [:]
        case "reviews": path = "/v1/apps/\(appId)/customerReviews"; bytes = empty; headers = [:]
        default: path = "/v1/apps/\(appId)"; bytes = app.data; headers = [:]
        }
        AnalyticsJobDelayStubProtocol.register(host, gate: gate, bytes: bytes, headers: headers, path: path)
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "GET")
            let path = request.url!.path
            if path == "/v1/apps/\(appId)" { return (200, [:], app.data) }
            if path.hasSuffix("appInfos") || path.hasSuffix("appStoreVersions") || path.hasSuffix("customerReviews") ||
                path.hasSuffix("inAppPurchasesV2") || path.hasSuffix("subscriptionGroups") || path.hasSuffix("analyticsReportRequests") {
                return (200, [:], empty)
            }
            return (403, [:], Data(#"{"errors":[]}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsJobDelayStubProtocol.self, StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation),
                                    origin: URL(string: "https://\(host)")!, configuration: configuration)
    }
    func children(_ session: WorkspaceSession, account: Account) async throws -> SyncChildren {
        try await session.storeAccess {
            try SyncChildren(JSONText.parse(#require(try $0.document(namespace: "sync_children", key: "\(account.id):\(appId)")).payload),
                             accountId: account.id, appId: appId)
        }
    }

    @Test(arguments: ["a,all,b,all,a", "all,a,b,all", "a,b,all,a", "all,all,b,a", "race,all,a,b"])
    func mixedAppAndAllStartsReuseExactJobs(order: String) async throws {
        let (session, original, root) = try await SalesJobTests().session()
        let gates = [AnalyticsJobDelayStubProtocol.Gate(), AnalyticsJobDelayStubProtocol.Gate()]
        defer { gates.forEach { $0.release() }; try? FileManager.default.removeItem(at: root) }
        let account = Account(id: original.id, name: original.name, keyId: original.keyId, keyType: original.keyType,
                              issuerId: original.issuerId, appIds: [appId, "1000000002"], appNames: nil)
        let store = try SalesJobTests().store(root)
        try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(account)]).data)] }
        let clients = try Dictionary(uniqueKeysWithValues: account.appIds.enumerated().map { index, app in
            ("\(account.id):\(app)", try client(account: account, appId: app, gate: gates[index]))
        })
        var ids: [String: String] = [:]
        for action in order.split(separator: ",") {
            if action == "race" {
                async let all = session.startAllSync(mode: .refresh, now: Date(), clients: clients)
                async let first = session.startSync(account: account, appId: appId, client: clients["\(account.id):\(appId)"])
                async let second = session.startSync(account: account, appId: "1000000002", client: clients["\(account.id):1000000002"])
                let (batch, a, b) = try await (all, first, second)
                #expect(batch.total == 2 && batch.started == 2 && batch.failed == 0)
                #expect(batch.jobs.first { $0.appId == appId }?.id == a.id)
                #expect(batch.jobs.first { $0.appId == "1000000002" }?.id == b.id)
                ids[appId] = a.id; ids["1000000002"] = b.id
            } else if action == "all" {
                let batch = try await session.startAllSync(mode: .refresh, now: Date(), clients: clients)
                #expect(batch.total == 2 && batch.started == 2 && batch.failed == 0)
                for entry in batch.jobs { if let id = ids[entry.appId] { #expect(id == entry.id) }; ids[entry.appId] = entry.id }
            } else {
                let app = action == "a" ? appId : "1000000002"
                let job = try await session.startSync(account: account, appId: app, mode: action == "a" ? .all : .retry,
                                                      client: clients["\(account.id):\(app)"])
                if let id = ids[app] { #expect(id == job.id) }; ids[app] = job.id
            }
        }
        try await wait { gates.allSatisfy { $0.pending == 1 } }
        #expect(Set(ids.values).count == 2)
        for _ in 0..<10 {
            let activity = try await session.syncActivitySummary()
            #expect(activity.activeApps == 2 && activity.totalApps == 2)
            #expect(activity.sources.total == 14 && activity.sources.synced < 14 && activity.sources.running > 0)
        }
        #expect(gates.allSatisfy { $0.pending == 1 })
        gates.forEach { $0.release() }
        for app in account.appIds {
            try await wait { try await session.syncJob(account: account, appId: app)?.isActive == false }
            let job = try #require(try await session.syncJob(account: account, appId: app))
            #expect(job.id == ids[app] && job.state == .complete && job.counts.checked == 7)
            #expect(job.items.first { $0.key == "material" }?.state == .synced)
        }
        let finished = try await session.syncActivitySummary()
        #expect(finished.activeApps == 0 && finished.totalApps == 2)
        let cards = try await session.connectedApps()
        #expect(finished.sources.synced == cards.compactMap(\.sync).reduce(0) { $0 + $1.counts.synced })
        #expect(finished.sources.attention == cards.compactMap(\.sync).reduce(0) { $0 + $1.counts.attention })
        try await session.signOut()
    }

    @Test(arguments: ["material", "sales", "downloads", "engagement", "finance", "reviews"], ["cancel", "continue", "refresh"])
    func separateSourceKeepsOwnershipWhileAggregateWaits(source: String, scenario: String) async throws {
        let cancel = scenario == "cancel", mode: SyncJob.Mode = scenario == "refresh" ? .refresh : .all
        let (session, account, root) = try await SalesJobTests().session()
        let aggregateSession = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let gate = AnalyticsJobDelayStubProtocol.Gate()
        defer { gate.release(); try? FileManager.default.removeItem(at: root) }
        let client = try client(account: account, appId: appId, gate: gate, source: source)
        let now = Date(timeIntervalSince1970: 1_770_206_400)
        let foreignId: String, foreignTask: Task<Void, Error>
        switch source {
        case "material":
            let (job, task) = try await session.createImport(account: account, appId: appId, client: client, reuseRunning: false, now: Date.init)
            foreignId = job.id; let owned = try #require(task); foreignTask = Task { _ = try await owned.value }
        case "sales":
            let selection = try SalesJobTests().selection()
            let (job, task) = try await session.createSalesDownload(account: account, appId: appId, selection: selection, client: client,
                                                                 reporter: nil, reuseRunning: false, now: now)
            foreignId = job.id; let owned = try #require(task); foreignTask = Task { _ = try await owned.value }
        case "downloads", "engagement":
            let selection = try AnalyticsDownloadSelection(kind: source, endDate: "2026-02-03", days: 1, today: "2026-02-04")
            let (job, task) = try await session.createAnalyticsDownload(account: account, appId: appId, selection: selection, client: client,
                                                                     reuseRunning: false, now: now)
            foreignId = job.id; let owned = try #require(task); foreignTask = Task { _ = try await owned.value }
        case "finance":
            let (job, task) = try await session.createFinancialDownload(account: account, appId: appId, selection: FinancialJobTests().selection(),
                                                                     client: client, reporter: nil, reuseRunning: false, now: now)
            foreignId = job.id; let owned = try #require(task); foreignTask = Task { _ = try await owned.value }
        default:
            let (job, task) = try await session.createReviewsDownload(account: account, appId: appId, client: client, reuseRunning: false, now: now)
            foreignId = job.id; let owned = try #require(task); foreignTask = Task { _ = try await owned.value }
        }
        try await wait { gate.pending == 1 }
        let before = try await session.syncPresentation(account: account, appId: appId)
        #expect(before.status?.isActive == true && before.activeJobId == nil)
        let row = try #require(try await session.connectedApps().first)
        #expect(row.canSync && !row.aggregateActive)
        let (parent, task) = try await aggregateSession.createSync(account: account, appId: appId, client: client, mode: mode, reuseRunning: true, now: now)
        let owned = try #require(task), waitingKey = source == "engagement" ? "downloads" : source
        try await wait {
            try await session.syncJob(account: account, appId: appId)?.items.first { $0.key == waitingKey }?.detail == AppSync.waitingForSource
        }
        #expect(try await session.syncPresentation(account: account, appId: appId).status?.items.first { $0.key == waitingKey }?.displayDetail == AppSync.waitingForSource)
        let binding = try await children(session, account: account)
        #expect(binding.id == parent.id && !binding.entries.contains { $0.id == foreignId })
        #expect(try await session.syncSourceIsActive(source, account: account, appId: appId))
        #expect(try await session.syncPresentation(account: account, appId: appId).activeJobId == parent.id)
        if cancel {
            _ = try await session.cancelSync(account: account, appId: appId, id: parent.id)
            await #expect(throws: CancellationError.self) { try await owned.value }
            #expect(try await session.syncSourceIsActive(source, account: account, appId: appId))
            #expect(try await session.syncJob(account: account, appId: appId)?.state == .cancelled)
        }
        gate.release()
        do { try await foreignTask.value } catch {
            #expect(source == "downloads" || source == "engagement")
        }
        if !cancel {
            let finished = try await owned.value
            #expect(finished.state == .complete && finished.counts.checked == 7)
            #expect(!finished.items.contains { $0.code == "SB-SYNC-BUSY" })
            if source == "material" || source == "reviews" {
                #expect(finished.items.first { $0.key == source }?.state == .synced)
                let entries = try await children(session, account: account).entries
                #expect(entries.contains { $0.key == source } == (mode == .refresh))
                #expect(!entries.contains { $0.id == foreignId })
            }
        }
        try await aggregateSession.signOut(); try await session.signOut()
    }

    @Test(arguments: [true, false]) func waitingForASeparateReportLeavesBothDownloadSlotsAvailable(cancelAfterReport: Bool) async throws {
        let (session, original, root) = try await SalesJobTests().session()
        let apps = [appId, "1000000002", "1000000003"], gates = (0..<3).map { _ in AnalyticsJobDelayStubProtocol.Gate() }
        defer { gates.forEach { $0.release() }; try? FileManager.default.removeItem(at: root) }
        let account = Account(id: original.id, name: original.name, keyId: original.keyId, keyType: original.keyType,
                              issuerId: original.issuerId, appIds: apps, appNames: nil)
        let store = try SalesJobTests().store(root)
        try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(account)]).data)] }
        let salesClient = try client(account: account, appId: appId, gate: gates[0], source: "sales")
        let now = Date(timeIntervalSince1970: 1_770_206_400)
        let (_, foreign) = try await session.createSalesDownload(account: account, appId: appId, selection: SalesJobTests().selection(),
                                                               client: salesClient, reporter: nil, reuseRunning: false, now: now)
        let foreignTask = try #require(foreign)
        try await wait { gates[0].pending == 1 }
        let (parent, owned) = try await session.createSync(account: account, appId: appId, client: salesClient, mode: .all, reuseRunning: true, now: now)
        let parentTask = try #require(owned)
        try await wait { try await session.syncJob(account: account, appId: appId)?.items.first { $0.key == "sales" }?.detail == AppSync.waitingForSource }
        var tasks: [Task<SyncJob, Error>] = []
        for index in 1...2 {
            let client = try client(account: account, appId: apps[index], gate: gates[index])
            let (_, task) = try await session.createSync(account: account, appId: apps[index], client: client, mode: .all, reuseRunning: true, now: now)
            tasks.append(try #require(task))
        }
        try await wait { gates[1].pending == 1 && gates[2].pending == 1 }
        #expect(try await session.syncJob(account: account, appId: appId)?.isActive == true)
        if cancelAfterReport {
            gates[0].release(); _ = try await foreignTask.value
            try await wait { try await session.syncJob(account: account, appId: appId)?.items.first { $0.key == "sales" }?.detail == AppSync.waitingForSlot }
        }
        _ = try await session.cancelSync(account: account, appId: appId, id: parent.id)
        await #expect(throws: CancellationError.self) { try await parentTask.value }
        #expect(try await session.salesDownloadJob(account: account, appId: appId)?.isActive == !cancelAfterReport)
        gates.forEach { $0.release() }
        _ = try await foreignTask.value
        for task in tasks { #expect(try await task.value.state == .complete) }
        try await session.signOut()
    }

    @Test func cancelledQueuedAppDoesNotConsumeTheNextAppsSlot() async throws {
        let (session, original, root) = try await SalesJobTests().session()
        let apps = [appId, "1000000002", "1000000003", "1000000004"]
        let gates = apps.map { _ in AnalyticsJobDelayStubProtocol.Gate() }
        defer { gates.forEach { $0.release() }; try? FileManager.default.removeItem(at: root) }
        let account = Account(id: original.id, name: original.name, keyId: original.keyId, keyType: original.keyType,
                              issuerId: original.issuerId, appIds: apps, appNames: nil)
        let store = try SalesJobTests().store(root)
        try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(account)]).data)] }
        var jobs: [SyncJob] = [], tasks: [Task<SyncJob, Error>] = []
        for (index, app) in apps.enumerated() {
            let client = try client(account: account, appId: app, gate: gates[index])
            let (job, task) = try await session.createSync(account: account, appId: app, client: client, mode: .refresh, reuseRunning: true, now: Date())
            jobs.append(job); tasks.append(try #require(task))
            if index < 2 { try await wait { gates[index].pending == 1 } }
        }
        #expect(gates[2].pending == 0 && gates[3].pending == 0)
        _ = try await session.cancelSync(account: account, appId: apps[2], id: jobs[2].id)
        await #expect(throws: CancellationError.self) { try await tasks[2].value }
        gates[0].release(); _ = try await tasks[0].value
        try await wait { gates[3].pending == 1 }
        #expect(gates[2].pending == 0 && gates[1].pending == 1)
        gates[1].release(); gates[3].release()
        _ = try await tasks[1].value; _ = try await tasks[3].value
        #expect(try await session.syncJob(account: account, appId: apps[2])?.state == .cancelled)
        try await session.signOut()
    }
}
