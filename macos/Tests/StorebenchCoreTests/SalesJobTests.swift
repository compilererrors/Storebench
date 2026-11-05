import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct SalesJobTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001"
    func selection(_ count: Int = 1, end: String = "2026-02-03", source: ReportingSource = .api) throws -> SalesDownloadSelection {
        try SalesDownloadSelection(source: source, endDate: end, days: count)
    }
    func session(directory: URL? = nil) async throws -> (WorkspaceSession, Account, URL) {
        let fixture = try SalesSyncTests(), (session, root) = try fixture.session(directory: directory)
        try await fixture.connect(session, #"{"vendorNumber":"80000001"}"#)
        return (session, try #require(try await session.accounts().first), root)
    }
    func store(_ root: URL) throws -> EncryptedDocumentStore {
        try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
    }
    func seed(_ job: SalesDownloadJob, account: Account, store: EncryptedDocumentStore) throws {
        let key = try ReportJobs.identity(.sales, accountId: account.id, appId: appId)
        try store.transaction { _ in [.put(namespace: "jobs", key: key, json: job.json.data)] }
    }
    func wait(_ operation: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try await operation()) { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
    }
    func transport(_ host: String, account: Account, gate: AnalyticsJobDelayStubProtocol.Gate) throws -> AppStoreConnectClient {
        AnalyticsJobDelayStubProtocol.register(host, gate: gate, bytes: SalesSyncTests.report([
            ["APPLE", "SYNTHETIC", appId, "1F", "3", "0.99", "02/03/2026", "02/03/2026", "US", ""]]),
            headers: ["Content-Type": "application/a-gzip"], path: "/v1/salesReports")
        StubProtocol.handle(host) { request in
            #expect(request.url!.path.contains("inAppPurchasesV2") || request.url!.path.contains("subscriptionGroups"))
            return (200, [:], Data(#"{"data":[],"links":{}}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AnalyticsJobDelayStubProtocol.self, StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration)
    }

    @Test func savedSalesJobsMatchWebAndNeverDisplayLegacyDiagnostics() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/sales-jobs.json")))
        guard case .array(let rows)? = fixture["jobs"] else { throw ReportJobFailure.status }
        for row in rows {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: ReportJobFailure.status) { try SalesDownloadJob(json: input) } }
            else {
                let job = try SalesDownloadJob(json: input)
                #expect(job.json == row["expected"], "Synthetic Sales job: \(row["id"]?.text ?? "unknown")")
                #expect(job.error?.contains("Synthetic untrusted diagnostic") != true)
            }
        }
        #expect(try ReportJobs.name(.sales, accountId: "synthetic-account", appId: appId) == fixture["lockName"]?.text)
    }

    @Test func aBackgroundDownloadCoalescesAcrossSessionsAndCommitsItsReceiptWithReports() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AnalyticsJobDelayStubProtocol.Gate(), client = try transport("sales-job-complete.appstoreconnect.test", account: account, gate: gate)
        let before = try await session.salesFileRecords(account: account, appId: appId).map(\.json)
        let started = try await session.startSalesDownload(account: account, appId: appId, selection: selection(), client: client)
        try await wait { gate.pending == 1 }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let same = try await second.startSalesDownload(account: account, appId: appId, selection: selection())
        #expect(same.id == started.id && same.isActive && same.checked == 0)
        #expect(try await second.salesFileRecords(account: account, appId: appId).map(\.json) == before)
        gate.release()
        try await wait { try await second.salesDownloadJob(account: account, appId: appId)?.state == .complete }
        let completed = try #require(try await second.salesDownloadJob(account: account, appId: appId))
        #expect(completed.checked == 1 && completed.withApp == 1 && completed.result?.saved == true && completed.result?.changes?.added == 1)
        #expect(try await second.sales(accountId: account.id, appId: appId).contains { $0.beginDate == "2026-02-03" && $0.paidUnits == 3 })
        try await second.verifyBuckets(family: "sales", accountId: account.id, appId: appId)
    }

    @Test func anotherSessionCancelsOnlyTheExactDownloadAndRetryClearsTheOldRequest() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AnalyticsJobDelayStubProtocol.Gate(), client = try transport("sales-job-cancel.appstoreconnect.test", account: account, gate: gate)
        let before = try await session.salesFileRecords(account: account, appId: appId).map(\.json)
        let started = try await session.startSalesDownload(account: account, appId: appId, selection: selection(), client: client)
        try await wait { gate.pending == 1 }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault), reader = try store(root)
        let key = "sales:\(account.id):\(appId)"
        _ = try await second.cancelSalesDownload(account: account, appId: appId, id: UUID().uuidString.lowercased())
        #expect(try reader.document(namespace: "job_cancels", key: key) == nil)
        _ = try await second.cancelSalesDownload(account: account, appId: appId, id: started.id)
        try await wait { try await second.salesDownloadJob(account: account, appId: appId)?.state == .cancelled }
        gate.release()
        #expect(try await second.salesFileRecords(account: account, appId: appId).map(\.json) == before)
        let freshGate = AnalyticsJobDelayStubProtocol.Gate(); freshGate.release()
        let replacement = try await session.startSalesDownload(account: account, appId: appId, selection: selection(), client: transport("sales-job-retry.appstoreconnect.test", account: account, gate: freshGate))
        _ = try await second.cancelSalesDownload(account: account, appId: appId, id: started.id)
        let cancellation = try reader.document(namespace: "job_cancels", key: key)
        #expect(replacement.id != started.id && cancellation == nil)
        try await wait { try await second.salesDownloadJob(account: account, appId: appId)?.state == .complete }
        #expect(try await second.salesDownloadJob(account: account, appId: appId)?.id == replacement.id)
    }

    @Test func reporterSalesNeedsNoApiKeyAndIncompleteCatalogKeepsUnattributedDaysUnknown() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        try await SalesSyncTests().connect(session, #"{"vendorNumber":"80000001","reporter":{"accountNumber":"1234567","vendorNumber":"80000001","credentialId":"00000000-0000-4000-8000-000000000099","connectedAt":"2026-01-01T00:00:00.000Z"}}"#)
        let host = "sales-job-reporter.reporting.test"
        StubProtocol.handle(host) { request in
            let connectionLock = root.appendingPathComponent("state-v2/reporter_\(JSONText.string(account.id).rawSHA256.prefix(32)).mutex")
            let lock = try! FileMutex.tryLock(connectionLock); #expect(lock != nil); lock?.release()
            let body = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }; var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; result.append(bytes, count: n) }; return result
            } ?? Data()
            let form = URLComponents(string: "?" + String(data: body, encoding: .utf8)!)?.queryItems?.first { $0.name == "jsonRequest" }?.value ?? ""
            let fields = try! JSONSerialization.jsonObject(with: Data(form.utf8)) as! [String: String]
            #expect(fields["account"] == "1234567" && !request.url!.absoluteString.contains("synthetic-reporter-token"))
            let query = fields["queryInput"]!
            if query.hasSuffix("20260210]") { return (200, ["Content-Type": "application/a-gzip"], SalesSyncTests.report([
                ["APPLE", "SYNTHETIC", "1000000001", "1F", "4", "0.99", "02/10/2026", "02/10/2026", "DE", ""]])) }
            if query.hasSuffix("20260211]") { return (200, ["Content-Type": "text/xml"], Data("<Error><Code>213</Code><Message>There are no reports available.</Message></Error>".utf8)) }
            return (200, ["Content-Type": "application/a-gzip"], SalesSyncTests.report([
                ["APPLE", "OTHER", "1000000099", "1F", "2", "0.99", "02/12/2026", "02/12/2026", "US", ""]]))
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let base = try #require(try await session.reporterClient(accountId: account.id))
        let reporter = try ReporterClient(token: base.token, origin: URL(string: "https://\(host)")!, configuration: configuration, selection: base.selection)
        let result = try await session.downloadSales(account: account, appId: appId, days: ["2026-02-10", "2026-02-11", "2026-02-12"], reporter: reporter)
        #expect(result.noSalesDays == ["2026-02-11"] && result.noAppRowsDays == ["2026-02-12"] && result.changes.added == 2)
        let job = try #require(try await session.salesDownloadJob(account: account, appId: appId))
        #expect(job.state == .complete && job.checked == 3 && job.withApp == 1 && job.noSales == 1 && job.withoutApp == 1)
        #expect(AppSync.salesStatus(result).state == .partial)
        #expect(try await session.sales(accountId: account.id, appId: appId).allSatisfy { $0.beginDate != "2026-02-12" })
    }

    @Test func anEntireTemporaryOutageFailsAndKeepsSavedHistory() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await session.salesFileRecords(account: account, appId: appId).map(\.json), host = "sales-job-outage.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            if request.url!.path == "/v1/salesReports" { return (503, [:], Data()) }
            return (200, [:], Data(#"{"data":[],"links":{}}"#.utf8))
        }
        await #expect(throws: AppStoreConnectClient.Failure.status(503)) {
            try await session.downloadSales(account: account, appId: appId, days: ["2026-02-02", "2026-02-03"], client: SalesSyncTests().client(host, account: account))
        }
        let job = try #require(try await session.salesDownloadJob(account: account, appId: appId))
        #expect(job.state == .failed && job.result == nil && job.unavailable == 2 && job.code == "SB-REPORT-SERVICE")
        #expect(try await session.salesFileRecords(account: account, appId: appId).map(\.json) == before)
    }

    @Test func terminalReceiptRejectsForeignAndReleasedOwnersAndCannotChangeAfterCommit() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = try store(root), id = UUID().uuidString.lowercased(), selected = try selection()
        let owner = try #require(try ReportJobs.acquire(.sales, accountId: account.id, appId: appId, directory: reader.directory, id: id)); defer { owner.release() }
        var job = SalesDownloadJob(id: id, selection: selected, now: Date()); try ReportJobs.start(job, ownership: owner, store: reader)
        job.noSales = 1; job.complete(.init(changes: .init(added: 1), noSalesDays: selected.days), at: CustomerReview.isoString(Date()))
        let foreign = SalesDownloadJob(id: UUID().uuidString.lowercased(), selection: selected, now: Date())
        #expect(try SalesDownloadJob(json: foreign.json).id == foreign.id)
        try seed(foreign, account: account, store: reader)
        let before = try reader.documents(namespace: "sales_index"), saved = try await session.salesFileRecords(account: account, appId: appId).map(\.json)
        #expect(throws: ReportJobFailure.status) {
            try PartitionedReports.replaceAll(SalesRecord.self, family: "sales", legacyKey: "reports", accountId: account.id, appId: appId, store: reader,
                stateDirectory: reader.directory, onlyBuckets: ["2026-02"], bucketOf: { String($0.beginDate.prefix(7)) }, encode: { $0.json }, additionalWrites: {
                    try ReportJobs.terminalWrites(job, ownership: owner, current: { try reader.document(namespace: $0, key: $1) })
                }) { previous, _ in
                    (try SalesReports.merge(previous ?? [], [.noSalesDay(accountId: account.id, appId: appId, day: selected.endDate, importedAt: CustomerReview.isoString(Date()))]).records, nil)
                }
        }
        #expect(try reader.documents(namespace: "sales_index") == before)
        #expect(try await session.salesFileRecords(account: account, appId: appId).map(\.json) == saved)
        let running = SalesDownloadJob(id: id, selection: selected, now: Date()); try seed(running, account: account, store: reader)
        try reader.transaction { current in try ReportJobs.terminalWrites(job, ownership: owner, current: current) }
        let committed = try reader.document(namespace: "jobs", key: owner.key)
        var cancelled = job; cancelled.state = .cancelled; cancelled.result = nil
        #expect(throws: ReportJobFailure.status) { try reader.transaction { current in try ReportJobs.terminalWrites(cancelled, ownership: owner, current: current) } }
        #expect(try reader.document(namespace: "jobs", key: owner.key) == committed)
        owner.release()
        #expect(throws: ReportJobFailure.status) { try reader.transaction { current in try ReportJobs.terminalWrites(job, ownership: owner, current: current) } }
    }

    @Test func invalidOrUnfinishedSelectionsFailBeforeRequestingReports() throws {
        for days in [[], ["2026-02-01", "2026-02-01"], ["2026-02-01", "2026-02-03"], ["2026-02-30"], ["9999-12-31"]] {
            #expect(throws: ReportJobFailure.request) { try SalesDownloadSelection(source: .api, days: days, now: Date(timeIntervalSince1970: 1_770_000_000)) }
        }
    }
}

@Suite(.serialized) struct SalesJobProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test(arguments: [true, false]) func anOwnedProcessCannotExpireAndItsCommittedReceiptSurvivesInterruption(committed: Bool) async throws {
        let fixture = try SalesJobTests(), root = try TestIsolation.require().appendingPathComponent(committed ? "sales-job-complete-policy" : "sales-job-interrupted-policy")
        let id = committed ? "00000000-0000-4000-8000-000000000101" : "00000000-0000-4000-8000-000000000102"
        let (session, account, _) = try await fixture.session(directory: root), reader = try fixture.store(root)
        var job = SalesDownloadJob(id: id, selection: try fixture.selection(), now: Date(timeIntervalSince1970: 1))
        let name = try ReportJobs.name(.sales, accountId: account.id, appId: fixture.appId), mutex = reader.directory.appendingPathComponent("\(name).lock.mutex")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path))
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        try fixture.seed(job, account: account, store: reader)
        let same = try await session.startSalesDownload(account: account, appId: fixture.appId, selection: fixture.selection())
        let proof = try FileMutex.tryLock(mutex)
        #expect(same.id == id && same.isActive && proof == nil)
        if committed {
            let selected = job.selection
            job.noSales = 1; job.complete(.init(changes: .init(added: 1), noSalesDays: selected.days), at: CustomerReview.isoString(Date()))
            try PartitionedReports.replaceAll(SalesRecord.self, family: "sales", legacyKey: "reports", accountId: account.id, appId: fixture.appId, store: reader,
                stateDirectory: reader.directory, onlyBuckets: ["2026-02"], bucketOf: { String($0.beginDate.prefix(7)) }, encode: { $0.json }, additionalWrites: {
                    [.put(namespace: "jobs", key: "sales:\(account.id):\(fixture.appId)", json: job.json.data)]
                }) { previous, _ in
                    (try SalesReports.merge(previous ?? [], [.noSalesDay(accountId: account.id, appId: fixture.appId, day: selected.endDate, importedAt: CustomerReview.isoString(Date()))]).records, nil)
                }
        }
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        try await fixture.wait { if let proof = try FileMutex.tryLock(mutex) { proof.release(); return true }; return false }
        let recovered = try #require(try await session.salesDownloadJob(account: account, appId: fixture.appId))
        #expect(recovered.id == id && recovered.state == (committed ? .complete : .failed))
        #expect(recovered.result?.saved == (committed ? true : nil))
        #expect(try await session.sales(accountId: account.id, appId: fixture.appId).contains { $0.beginDate == "2026-02-03" } == committed)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }
}
