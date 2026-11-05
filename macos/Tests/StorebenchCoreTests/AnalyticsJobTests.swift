import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

/// An owned in-process report response held until the test releases it. Cancellation never reaches a network.
final class AnalyticsJobDelayStubProtocol: URLProtocol, @unchecked Sendable {
    final class Gate: @unchecked Sendable {
        let lock = NSLock()
        private var callbacks: [@Sendable () -> Void] = []
        private var released = false
        var pending: Int { lock.withLock { callbacks.count } }
        func add(_ callback: @escaping @Sendable () -> Void) {
            let ready = lock.withLock { if released { return true }; callbacks.append(callback); return false }
            if ready { callback() }
        }
        func release() {
            let ready = lock.withLock { released = true; let ready = callbacks; callbacks = []; return ready }
            for callback in ready { callback() }
        }
    }
    static let registryLock = NSLock()
    nonisolated(unsafe) static var responses: [String: (Gate, Data, [String: String], String?, String?)] = [:]
    static func register(_ host: String, gate: Gate, bytes: Data, headers: [String: String] = [:], path: String? = nil, cursor: String? = nil) { registryLock.withLock { responses[host] = (gate, bytes, headers, path, cursor) } }
    let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { registryLock.withLock {
        guard let response = responses[request.url?.host ?? ""] else { return false }
        let pathMatches = response.3 == nil || response.3 == request.url?.path
        let cursor = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "cursor" }?.value
        return pathMatches && (response.4 == nil || response.4 == cursor)
    } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let response = Self.registryLock.withLock({ Self.responses[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        response.0.add { [weak self] in
            guard let self else { return }
            guard self.stateLock.withLock({ !self.stopped }) else { return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: response.2)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: response.1); self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}

@Suite(.serialized) struct AnalyticsJobTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001"
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/analytics-jobs.json"))) }
    func list(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw ReportJobFailure.status }; return values }
    func session() throws -> (WorkspaceSession, URL) { try AnalyticsSyncTests().session() }
    func selected(_ kind: String = "downloads") throws -> AnalyticsDownloadSelection { try AnalyticsDownloadSelection(kind: kind, endDate: "2026-02-11", days: 1) }
    func transport(_ host: String, account: Account, storage: String, bytes: Data, gate: AnalyticsJobDelayStubProtocol.Gate? = nil, ready: URL? = nil) throws -> AppStoreConnectClient {
        if let gate { AnalyticsJobDelayStubProtocol.register(storage, gate: gate, bytes: bytes) }
        let digest = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        StubProtocol.handle(host) { request in
            switch request.url!.path {
            case "/v1/apps/1000000001/analyticsReportRequests": return AnalyticsCatalogTests.page([AnalyticsCatalogTests.request()])
            case "/v1/analyticsReportRequests/synthetic-request/reports": return AnalyticsCatalogTests.page([AnalyticsCatalogTests.report()])
            case "/v1/analyticsReports/synthetic-report/instances": return AnalyticsCatalogTests.page([AnalyticsCatalogTests.instance()])
            case "/v1/analyticsReportInstances/synthetic-instance/segments":
                return AnalyticsCatalogTests.page([["type": "analyticsReportSegments", "id": "synthetic-segment", "attributes": ["sizeInBytes": bytes.count, "checksum": digest, "url": "https://\(storage)/reports/synthetic.gz"]]])
            default: Issue.record("Unexpected owned Analytics job route"); return (404, [:], Data())
            }
        }
        if gate == nil {
            StubProtocol.handle(storage) { _ in if let ready { try! JobLock.exclusive(ready, "synthetic-segment-ready") }; return (200, [:], bytes) }
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AnalyticsJobDelayStubProtocol.self, StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: config)
    }
    func bytes(app: String = "1000000001") -> Data { AnalyticsSyncTests.segment([["2026-02-10", "Synthetic app", app, "First-time Download", "1.0", "iPhone", "17.0", "App Store Search", "App Page", "No", "US", "3"]]) }
    func wait(_ operation: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try await operation()) { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func durableContractsAndSanitizedGuidanceMatchWeb() throws {
        let fixture = try fixture()
        guard case .object(let messages)? = fixture["messages"] else { throw ReportJobFailure.status }
        #expect(messages.count == ReportingMessages.values.count)
        for (code, value) in messages { #expect(ReportingMessages.message(code) == value.text) }
        for row in try list(fixture["jobs"]) {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: (any Error).self) { try AnalyticsDownloadJob(json: input) } }
            else { let actual = try AnalyticsDownloadJob(json: input).json; #expect(actual == row["expected"], "Synthetic job case: \(row["id"]?.text ?? "unknown")") }
        }
        for row in try list(fixture["selections"]) {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: ReportJobFailure.request) { try AnalyticsDownloadSelection(json: input) } }
            else {
                let selection = try AnalyticsDownloadSelection(json: input)
                #expect(selection.json == row["expected"])
                #expect(JSONText.array(selection.processingDays.map(JSONText.string)) == row["processingDays"])
            }
        }
        #expect(try ReportJobs.name(.downloads, accountId: "synthetic-account", appId: appId) == fixture["lockName"]?.text)
        #expect(try ReportJobs.name(.engagement, accountId: "synthetic-account", appId: appId) == fixture["lockName"]?.text)
    }

    @Test func onlyExactOwnerCanUpdateAndTerminalStatusCannotBeRewritten() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let id = UUID().uuidString.lowercased(), owner = try #require(try ReportJobs.acquire(.downloads, accountId: account.id, appId: appId, directory: store.directory, id: id)); defer { owner.release() }
        var job = AnalyticsDownloadJob(id: id, selection: try selected(), now: Date())
        try ReportJobs.start(job, ownership: owner, store: store)
        #expect(try ReportJobs.read(AnalyticsDownloadJob.self, family: .downloads, accountId: account.id, appId: appId, store: store)?.state == .running)
        let foreign = AnalyticsDownloadJob(id: UUID().uuidString.lowercased(), selection: try selected(), now: Date())
        try store.transaction { _ in [.put(namespace: "jobs", key: owner.key, json: foreign.json.data)] }
        let before = try store.document(namespace: "jobs", key: owner.key)
        #expect(throws: ReportJobFailure.status) { try ReportJobs.update(job, ownership: owner, store: store) }
        #expect(try store.document(namespace: "jobs", key: owner.key) == before)
        try store.transaction { _ in [.put(namespace: "jobs", key: owner.key, json: job.json.data)] }
        job.state = .complete; job.result = AnalyticsSyncResult()
        try ReportJobs.update(job, ownership: owner, store: store)
        let complete = try store.document(namespace: "jobs", key: owner.key)
        try ReportJobs.update(job, ownership: owner, store: store)
        #expect(try store.document(namespace: "jobs", key: owner.key) == complete)
        job.phase = .saving
        #expect(throws: ReportJobFailure.status) { try ReportJobs.update(job, ownership: owner, store: store) }
        #expect(try ReportJobs.cancel(AnalyticsDownloadJob.self, family: .downloads, accountId: account.id, appId: appId, id: id, store: store) == false)
    }

    @Test func backgroundProgressAndCompletionSurviveANewSession() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), gate = AnalyticsJobDelayStubProtocol.Gate(), host = "analytics-job-complete.appstoreconnect.test", storage = "synthetic-job-complete.s3.amazonaws.com"
        let client = try transport(host, account: account, storage: storage, bytes: bytes(), gate: gate)
        let started = try await session.startAnalyticsDownload(account: account, appId: appId, selection: selected(), client: client)
        try await wait { gate.pending == 1 }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let current = try #require(try await second.analyticsDownloadJob(account: account, appId: appId))
        #expect(current.id == started.id && current.state == .running && current.phase == .downloading && current.total == 1 && current.completed == 0)
        gate.release()
        try await wait { try await second.analyticsDownloadJob(account: account, appId: appId)?.state == .complete }
        let complete = try #require(try await second.analyticsDownloadJob(account: account, appId: appId))
        #expect(complete.id == started.id && complete.completed == 1 && complete.segments == 1 && complete.bytes == bytes().count && complete.result?.changes.added == 1)
        try await second.verifyBuckets(family: "analytics", accountId: account.id, appId: appId)
        let name = try ReportJobs.name(.downloads, accountId: account.id, appId: appId)
        try await wait { !FileManager.default.fileExists(atPath: root.appendingPathComponent("state-v2/\(name).lock").path) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("state-v2/\(name).lock").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("state-v2/\(name).lock.mutex").path))
    }

    @Test func concurrentKindsFollowOneOwnerAndStaleCancelCannotStopAnotherJob() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), gate = AnalyticsJobDelayStubProtocol.Gate(), host = "analytics-job-concurrent.appstoreconnect.test", storage = "synthetic-job-concurrent.s3.amazonaws.com"
        let client = try transport(host, account: account, storage: storage, bytes: bytes(), gate: gate)
        let first = try await session.startAnalyticsDownload(account: account, appId: appId, selection: selected(), client: client)
        try await wait { gate.pending == 1 }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let count = StubProtocol.requests(host).count
        let following = try await second.startAnalyticsDownload(account: account, appId: appId, selection: selected("engagement"), client: client)
        #expect(following.id == first.id && following.selection.kind == "downloads" && StubProtocol.requests(host).count == count)
        _ = try await second.cancelAnalyticsDownload(account: account, appId: appId, id: UUID().uuidString.lowercased())
        #expect(try await second.storeAccess { try $0.documents(namespace: "job_cancels") }.isEmpty)
        let cancelled = try await second.cancelAnalyticsDownload(account: account, appId: appId, id: first.id)
        #expect(cancelled?.id == first.id)
        try await wait { try await second.analyticsDownloadJob(account: account, appId: appId)?.state == .cancelled }
        gate.release()
        StubProtocol.handle(storage) { _ in (200, [:], bytes()) }
        let freshGate = AnalyticsJobDelayStubProtocol.Gate(); freshGate.release()
        let newClient = try transport("analytics-job-concurrent-retry.appstoreconnect.test", account: account, storage: "synthetic-job-retry.s3.amazonaws.com", bytes: bytes(), gate: freshGate)
        let fresh = try await second.startAnalyticsDownload(account: account, appId: appId, selection: selected(), client: newClient)
        #expect(fresh.id != first.id)
        try await wait { try await second.analyticsDownloadJob(account: account, appId: appId)?.state == .complete }
        _ = try await second.cancelAnalyticsDownload(account: account, appId: appId, id: first.id)
        #expect(try await second.analyticsDownloadJob(account: account, appId: appId)?.state == .complete)
        #expect(try await second.storeAccess { try $0.documents(namespace: "job_cancels") }.isEmpty)
    }

    @Test func releasedOwnersRecoverAndLiveLegacyOwnersNeverExpireByTime() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let id = UUID().uuidString.lowercased(), owner = try #require(try ReportJobs.acquire(.downloads, accountId: account.id, appId: appId, directory: store.directory, id: id))
        let job = AnalyticsDownloadJob(id: id, selection: try selected(), now: Date(timeIntervalSince1970: 1))
        try ReportJobs.start(job, ownership: owner, store: store)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: owner.lock.path)
        #expect(try await session.analyticsDownloadJob(account: account, appId: appId)?.state == .running)
        owner.release()
        let recovered = try #require(try await session.analyticsDownloadJob(account: account, appId: appId))
        #expect(recovered.id == id && recovered.state == .failed && recovered.code == "SB-REPORT-JOB")
        let legacyId = UUID().uuidString.lowercased(), legacy = AnalyticsDownloadJob(id: legacyId, selection: try selected(), now: Date(timeIntervalSince1970: 1))
        try store.transaction { _ in [.put(namespace: "jobs", key: owner.key, json: legacy.json.data)] }
        try JobLock.exclusive(owner.lock, JSONText.object([("id", .string(legacyId)), ("pid", .number(Double(getpid())))]).stringify())
        #expect(try await session.analyticsDownloadJob(account: account, appId: appId)?.state == .running)
        #expect(try ReportJobs.acquire(.engagement, accountId: account.id, appId: appId, directory: store.directory, id: UUID().uuidString.lowercased()) == nil)
        try FileManager.default.removeItem(at: owner.lock)
        #expect(try await session.analyticsDownloadJob(account: account, appId: appId)?.state == .failed)
    }

    @Test func legacyCompletedJobsMigrateAndEachKindKeepsItsOwnReceipt() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), vector = try fixture(), saved = try AnalyticsDownloadJob(json: #require(vector["benchmark"]))
        let legacyStatus = AppSync.analyticsStatus(try #require(saved.result), processingDays: saved.selection.days)
        #expect(legacyStatus.state == .partial && legacyStatus.detail.contains("5 requested processing days"))
        #expect(saved.result?.unavailableDays.isEmpty == true)
        try await session.storeAccess { try $0.transaction { _ in [.put(namespace: "jobs", key: "analytics:\(account.id):\(appId)", json: saved.json.data)] } }
        #expect(try await session.analyticsDownloadJob(account: account, appId: appId)?.id == saved.id)
        let legacy = try await session.storeAccess { try $0.document(namespace: "jobs", key: "analytics:\(account.id):\(appId)") }
        let split = try await session.storeAccess { try $0.document(namespace: "jobs", key: "analytics_downloads:\(account.id):\(appId)") }
        #expect(legacy == nil && split != nil)
        var engagement = AnalyticsDownloadJob(id: UUID().uuidString.lowercased(), selection: try selected("engagement"), now: Date())
        engagement.fail(AnalyticsFailure.reportMissing, at: CustomerReview.isoString(Date()))
        try await session.storeAccess { try $0.transaction { _ in [.put(namespace: "jobs", key: "analytics_engagement:\(account.id):\(appId)", json: engagement.json.data)] } }
        #expect(try await session.analyticsDownloadJob(account: account, appId: appId, kind: "downloads")?.id == saved.id)
        #expect(try await session.analyticsDownloadJob(account: account, appId: appId, kind: "engagement")?.id == engagement.id)
    }

    @Test func importedHistoryChangesDuringNetworkReadStopTheFinalSave() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), gate = AnalyticsJobDelayStubProtocol.Gate()
        let client = try transport("analytics-job-stale.appstoreconnect.test", account: account, storage: "synthetic-job-stale.s3.amazonaws.com", bytes: bytes(), gate: gate)
        _ = try await session.startAnalyticsDownload(account: account, appId: appId, selection: selected(), client: client)
        try await wait { gate.pending == 1 }
        let reader = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let metadata = try AnalyticsMetadata(kind: "downloads", level: "standard", granularity: "DAILY", processingDate: "2026-02-11")
        let files = AnalyticsFileInput(files: [try ReportFiles.unpack(bytes(), limit: 10_000_000)], metadata: metadata, complete: true)
        let review = try await session.previewAnalyticsFiles(account: account, appId: appId, input: files)
        _ = try await session.saveAnalyticsFiles(review, input: files)
        let imported = try reader.documents(namespace: "analytics_index") + reader.documents(namespace: "analytics_part")
        gate.release()
        try await wait { try await session.analyticsDownloadJob(account: account, appId: appId)?.state == .failed }
        #expect(try await session.analyticsDownloadJob(account: account, appId: appId)?.code == "SB-ANALYTICS-STALE")
        #expect(try reader.documents(namespace: "analytics_index") + reader.documents(namespace: "analytics_part") == imported)
    }

    @Test func partialProcessingPeriodsAndForeignRowsRemainUnknownAfterRestoration() async throws {
        for foreign in [false, true] {
            let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first)
            let before = try await session.storeAccess { try $0.documents(namespace: "analytics_index") + $0.documents(namespace: "analytics_part") }
            let client = try transport("analytics-job-partial-\(foreign).appstoreconnect.test", account: account,
                                       storage: "synthetic-job-partial-\(foreign).s3.amazonaws.com", bytes: bytes(app: foreign ? "1000000002" : appId))
            let selection = try AnalyticsDownloadSelection(kind: "downloads", endDate: "2026-02-11", days: 2)
            let started = try await session.startAnalyticsDownload(account: account, appId: appId, selection: selection, client: client)
            let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
            try await wait { try await second.analyticsDownloadJob(account: account, appId: appId)?.state == .complete }
            let saved = try #require(try await second.analyticsDownloadJob(account: account, appId: appId))
            #expect(saved.id == started.id && saved.result?.instances == 1 && saved.result?.unavailableDays == ["2026-02-10"])
            #expect(saved.result?.noAppInstances == (foreign ? 1 : 0))
            let records = try await second.storeAccess { try $0.documents(namespace: "analytics_index") + $0.documents(namespace: "analytics_part") }
            if foreign { #expect(records == before) } else { #expect(saved.result?.changes.added == 1) }
            #expect(saved.json["result"]?["unavailableProcessingDates"] == .array([.string("2026-02-10")]))
        }
    }
    @Test func terminalReceiptAfterABusyProbeRemainsReadableOnlyForTheObservedJob() async throws {
        for foreign in [false, true] {
            let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first)
            try await session.storeAccess { store in
                let id = UUID().uuidString.lowercased(), selection = try AnalyticsDownloadSelection(kind: "downloads", endDate: "2026-02-11", days: 2)
                let owner = try #require(try ReportJobs.acquire(.downloads, accountId: account.id, appId: appId, directory: store.directory, id: id)); defer { owner.release() }
                let running = AnalyticsDownloadJob(id: id, selection: selection, now: Date())
                try ReportJobs.start(running, ownership: owner, store: store)
                #expect(try FileMutex.tryLock(owner.lock.appendingPathExtension("mutex")) == nil)
                let observed = try #require(try ReportJobs.parsed(AnalyticsDownloadJob.self, store.document(namespace: "jobs", key: owner.key), family: .downloads))
                var terminal = running, result = AnalyticsSyncResult(instances: 1, noAppInstances: foreign ? 1 : 0, unavailableDays: ["2026-02-10"])
                result.changes.added = foreign ? 0 : 1
                terminal.state = .complete; terminal.total = 1; terminal.completed = 1; terminal.result = result
                try ReportJobs.update(terminal, ownership: owner, store: store)
                owner.release()
                let ownerId = try JobLock.owner(JobLock.privateFile(owner.lock))?.id
                #expect(ownerId == nil)
                let completed = try ReportJobs.activeObservation(observed, ownerId: ownerId) {
                    try ReportJobs.parsed(AnalyticsDownloadJob.self, store.document(namespace: "jobs", key: owner.key), family: .downloads)
                }
                #expect(completed.state == .complete && completed.id == id && completed.result?.unavailableDays == ["2026-02-10"] && completed.result?.noAppInstances == (foreign ? 1 : 0))
                #expect(throws: ReportJobFailure.status) { try ReportJobs.activeObservation(observed, ownerId: nil, latest: { observed }) }
                #expect(throws: ReportJobFailure.status) { try ReportJobs.activeObservation(observed, ownerId: nil, latest: { nil }) }
                let newer = AnalyticsDownloadJob(id: UUID().uuidString.lowercased(), selection: selection, now: Date())
                #expect(throws: ReportJobFailure.status) { try ReportJobs.activeObservation(observed, ownerId: newer.id, latest: { newer }) }
                #expect(try store.document(namespace: "jobs", key: owner.key)?.payload == terminal.json.data)
            }
        }
    }
}

@Suite(.serialized) struct AnalyticsJobProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func ownedKernelJobMutexPreservesProgressUntilItsProcessInterrupts() async throws {
        let root = try TestIsolation.require().appendingPathComponent("analytics-job-lock-policy"), fixture = try AnalyticsJobTests()
        let (session, _) = try SalesSyncTests().session(directory: root), account = try #require(try await session.accounts().first), appId = fixture.appId
        let reader = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let name = try ReportJobs.name(.downloads, accountId: account.id, appId: appId), mutex = reader.directory.appendingPathComponent("\(name).lock.mutex")
        let busy = try FileMutex.tryLock(mutex)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path) && busy == nil)
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        let id = UUID().uuidString.lowercased(), job = AnalyticsDownloadJob(id: id, selection: try fixture.selected(), now: Date(timeIntervalSince1970: 1))
        try reader.transaction { _ in [.put(namespace: "jobs", key: "analytics_downloads:\(account.id):\(appId)", json: job.json.data)] }
        try JobLock.exclusive(reader.directory.appendingPathComponent("\(name).lock"), JSONText.object([("id", .string(id)), ("pid", .number(Double(getpid()))), ("protocol", .number(2))]).stringify())
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        #expect(try await session.analyticsDownloadJob(account: account, appId: appId)?.state == .running)
        #expect(try ReportJobs.acquire(.engagement, accountId: account.id, appId: appId, directory: reader.directory, id: UUID().uuidString.lowercased()) == nil)
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        try await fixture.wait { if let probe = try FileMutex.tryLock(mutex) { probe.release(); return true }; return false }
        let recovered = try #require(try await session.analyticsDownloadJob(account: account, appId: appId))
        #expect(recovered.id == id && recovered.state == .failed && recovered.code == "SB-REPORT-JOB")
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }

    @Test func exactCancellationFromAnotherSessionStopsASaveWaitingOnTheReportMutex() async throws {
        let root = try TestIsolation.require().appendingPathComponent("analytics-job-cancel-save-lock-policy"), fixture = try AnalyticsJobTests()
        let (session, _) = try SalesSyncTests().session(directory: root), account = try #require(try await session.accounts().first), appId = fixture.appId
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let reader = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let before = try reader.documents(namespace: "analytics_index") + reader.documents(namespace: "analytics_part")
        let mutex = reader.directory.appendingPathComponent("analytics-\(JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(32)).mutex")
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        let ready = root.appendingPathComponent("report-ready")
        let client = try fixture.transport("analytics-job-save-wait.appstoreconnect.test", account: account, storage: "synthetic-job-save-wait.s3.amazonaws.com", bytes: fixture.bytes(), ready: ready)
        let started = try await session.startAnalyticsDownload(account: account, appId: appId, selection: fixture.selected(), client: client)
        try await fixture.wait { FileManager.default.fileExists(atPath: ready.path) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try reader.documents(namespace: "analytics_index") + reader.documents(namespace: "analytics_part") == before)
        _ = try await second.cancelAnalyticsDownload(account: account, appId: appId, id: started.id)
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        try await fixture.wait { try await second.analyticsDownloadJob(account: account, appId: appId)?.state == .cancelled }
        #expect(try reader.documents(namespace: "analytics_index") + reader.documents(namespace: "analytics_part") == before)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }
}
