import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct FinancialJobTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001"
    func selection() throws -> FinancialDownloadSelection {
        try FinancialDownloadSelection(json: .object([("source", .string("api")), ("year", .number(2026)), ("period", .number(4)), ("periods", .number(1)), ("region", .string("ZZ"))]))
    }
    func wait(_ operation: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try await operation()) { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
    }
    func transport(_ host: String, account: Account, gate: AnalyticsJobDelayStubProtocol.Gate) throws -> AppStoreConnectClient {
        AnalyticsJobDelayStubProtocol.register(host, gate: gate, bytes: FinanceSyncTests.january, headers: ["Content-Type": "application/a-gzip"])
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AnalyticsJobDelayStubProtocol.self, StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration)
    }
    func seed(_ job: FinancialDownloadJob, account: Account, store: EncryptedDocumentStore) throws {
        let key = try ReportJobs.identity(.financial, accountId: account.id, appId: appId)
        try store.transaction { _ in [.put(namespace: "jobs", key: key, json: job.json.data)] }
    }
    func retain(_ job: FinancialDownloadJob, account: Account, session: WorkspaceSession) async throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/financial-downloads.json")))
        let expected = try #require(fixture["expected"]), record = try FinancialDownloadRecord(json: expected, accountId: account.id, appId: appId)
        let saved = try await session.savedFinancialFiles(account: account, appId: appId)
        let review = FinancialDownload(id: UUID(uuidString: job.id)!, accountId: account.id, appId: appId, region: "ZZ", reports: record.reports, noApp: [], unavailable: [],
            changes: [], revision: saved.revision, account: account, expiresAt: Date().addingTimeInterval(86_400), selection: job.selection)
        try await session.retainPendingFinancialDownload(review)
    }

    @Test func savedFinanceJobsMatchWebIncludingBoundedResultsAndFixedGuidance() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/financial-downloads.json")))
        guard case .array(let rows)? = fixture["jobs"] else { throw ReportJobFailure.status }
        for row in rows {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: ReportJobFailure.status) { try FinancialDownloadJob(json: input) } }
            else {
                let job = try FinancialDownloadJob(json: input)
                #expect(job.json == row["expected"], "Synthetic financial job: \(row["id"]?.text ?? "unknown")")
                #expect(job.error?.contains("Synthetic untrusted diagnostic") != true)
            }
        }
    }

    @Test func backgroundDownloadSurvivesNavigationAndCoalescesAcrossSessionsWithoutKeychain() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AnalyticsJobDelayStubProtocol.Gate(), client = try transport("financial-job-complete.appstoreconnect.test", account: account, gate: gate)
        let started = try await session.startFinancialDownload(account: account, appId: appId, selection: selection(), client: client)
        try await wait { gate.pending == 1 }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let running = try #require(try await second.financialDownloadJob(account: account, appId: appId))
        #expect(running.id == started.id && running.isActive && running.completed == 0 && running.bytes == 0)
        let same = try await second.startFinancialDownload(account: account, appId: appId, selection: selection())
        #expect(same.id == started.id && same.isActive)
        #expect(try await second.financialReports(accountId: account.id, appId: appId).isEmpty)
        gate.release()
        try await wait { try await second.financialDownloadJob(account: account, appId: appId)?.state == .complete }
        let completed = try #require(try await second.financialDownloadJob(account: account, appId: appId))
        #expect(completed.completed == completed.total && completed.bytes == FinanceSyncTests.january.count && completed.result?.reviewId == started.id)
        let review = try #require(try await second.pendingFinancialDownload(accountId: account.id, appId: appId))
        #expect(review.id.uuidString.lowercased() == started.id && review.retainedFingerprint != nil)
        #expect(try await second.financialReports(accountId: account.id, appId: appId).isEmpty)
        _ = try await second.saveFinancial(review)
        #expect(try await session.financialReports(accountId: account.id, appId: appId) == review.reports)
    }

    @Test func anotherSessionStopsOnlyTheExactJobAndANewStartClearsItsCancellation() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AnalyticsJobDelayStubProtocol.Gate(), client = try transport("financial-job-cancel.appstoreconnect.test", account: account, gate: gate)
        let started = try await session.startFinancialDownload(account: account, appId: appId, selection: selection(), client: client)
        try await wait { gate.pending == 1 }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault), reader = try FinancialDownloadTests().store(root)
        let key = "financial:\(account.id):\(appId)"
        _ = try await second.cancelFinancialDownload(account: account, appId: appId, id: UUID().uuidString.lowercased())
        #expect(try reader.document(namespace: "job_cancels", key: key) == nil)
        _ = try await second.cancelFinancialDownload(account: account, appId: appId, id: started.id)
        try await wait { try await second.financialDownloadJob(account: account, appId: appId)?.state == .cancelled }
        gate.release()
        #expect(try await second.pendingFinancialDownload(accountId: account.id, appId: appId) == nil)
        #expect(try await second.financialReports(accountId: account.id, appId: appId).isEmpty)
        let freshGate = AnalyticsJobDelayStubProtocol.Gate(); freshGate.release()
        let replacement = try await session.startFinancialDownload(account: account, appId: appId, selection: selection(), client: transport("financial-job-retry.appstoreconnect.test", account: account, gate: freshGate))
        #expect(replacement.id != started.id)
        _ = try await second.cancelFinancialDownload(account: account, appId: appId, id: started.id)
        #expect(try reader.document(namespace: "job_cancels", key: key) == nil)
        try await wait { try await second.financialDownloadJob(account: account, appId: appId)?.state == .complete }
        #expect(try await second.financialDownloadJob(account: account, appId: appId)?.id == replacement.id)
    }

    @Test func changedAppAccessDuringDownloadCannotRetainOrSaveReports() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AnalyticsJobDelayStubProtocol.Gate(), client = try transport("financial-job-scope.appstoreconnect.test", account: account, gate: gate)
        _ = try await session.startFinancialDownload(account: account, appId: appId, selection: selection(), client: client)
        try await wait { gate.pending == 1 }
        let reader = try FinancialDownloadTests().store(root), accounts = try #require(try reader.document(namespace: "accounts", key: "all"))
        let removed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(removed)]).data)] }
        gate.release()
        try await wait { try reader.document(namespace: "jobs", key: "financial:\(account.id):\(appId)").map { try FinancialDownloadJob(json: JSONText.parse($0.payload)).state == .failed } ?? false }
        #expect(try reader.documents(namespace: "financial_reviews").isEmpty && reader.documents(namespace: "financial_pending").isEmpty)
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: accounts.payload)] }
        #expect(try await session.financialDownloadJob(account: account, appId: appId)?.code == "SB-FINANCE-SCOPE")
        #expect(try await session.financialReports(accountId: account.id, appId: appId).isEmpty)
    }

    @Test func anInterruptedRetainedReviewIsRecoveredBeforeKeychainAndWithoutAnotherDownload() async throws {
        for foreground in [false, true] {
            let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let reader = try FinancialDownloadTests().store(root)
            var job = FinancialDownloadJob(id: UUID().uuidString.lowercased(), selection: try selection(), now: Date(timeIntervalSince1970: 1))
            job.phase = .preparing; job.completed = job.total
            try await retain(job, account: account, session: session); try seed(job, account: account, store: reader)
            let before = try reader.document(namespace: "financial_reviews", key: "\(account.id):\(appId)")
            if foreground {
                let host = "financial-job-recovery.appstoreconnect.test", client = try FinanceSyncTests().client(host, account)
                StubProtocol.handle(host) { _ in Issue.record("Recovery must not download an already retained review"); return (404, [:], Data()) }
                let recovered = try await session.downloadFinancial(account: account, appId: appId, region: "ZZ", periods: [FiscalPeriod(year: 2026, period: 4)], client: client)
                #expect(recovered.id.uuidString.lowercased() == job.id)
                #expect(StubProtocol.requests(host).isEmpty)
            } else {
                let recovered = try await session.startFinancialDownload(account: account, appId: appId, selection: selection())
                #expect(recovered.id == job.id && recovered.state == .complete && recovered.result?.reviewId == job.id)
            }
            #expect(try reader.document(namespace: "financial_reviews", key: "\(account.id):\(appId)") == before)
            #expect(try await session.financialReports(accountId: account.id, appId: appId).isEmpty)
        }
    }

    @Test func completedMissingAndUnattributedJobsKeepPeriodsUnknownWithoutAReviewOrHistory() async throws {
        for missing in [true, false] {
            let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let host = missing ? "financial-job-unavailable.appstoreconnect.test" : "financial-job-unattributed.appstoreconnect.test"
            StubProtocol.handle(host) { request in
                #expect(request.httpMethod == "GET" && request.url!.path == "/v1/financeReports")
                return missing ? (404, [:], Data()) : (200, ["Content-Type": "application/a-gzip"], FinanceSyncTests.report([
                    ["12/29/2025", "01/31/2026", "1", "0.70", "0.70", "USD", "S", "1000000099", "1F", "US", "0.99", "USD"]]))
            }
            let result = try await session.downloadFinancial(account: account, appId: appId, region: "ZZ", periods: [FiscalPeriod(year: 2026, period: 4)], client: FinanceSyncTests().client(host, account))
            let job = try #require(try await session.financialDownloadJob(account: account, appId: appId))
            #expect(job.state == .complete && job.completed == job.total && job.result?.reports == 0 && job.result?.reviewId == nil)
            #expect(job.result?.unavailable == (missing ? ["2026-04"] : []) && job.result?.noApp == (missing ? [] : ["2026-04"]))
            #expect(AppSync.financialStatus(result).state == .partial)
            #expect(try await session.pendingFinancialDownload(accountId: account.id, appId: appId) == nil)
            #expect(try await session.financialReports(accountId: account.id, appId: appId).isEmpty)
        }
    }

    @Test func reporterFinanceNeedsNoApiKeyAndUsesOnlyItsCapturedAccountAndVendor() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(reporter: true); defer { try? FileManager.default.removeItem(at: root) }
        let host = "financial-job-reporter.reporting.test"
        StubProtocol.handle(host) { request in
            let lock = try! FileMutex.tryLock(root.appendingPathComponent("state-v2/reporter_" + JSONText.string(account.id).rawSHA256.prefix(32) + ".mutex"))
            #expect(lock != nil); lock?.release()
            #expect(request.url!.path == "/reportservice/finance/v1")
            let data = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }; return data
            } ?? Data()
            let form = URLComponents(string: "?" + String(data: data, encoding: .utf8)!)?.queryItems?.first { $0.name == "jsonRequest" }?.value ?? ""
            let command = (try! JSONSerialization.jsonObject(with: Data(form.utf8)) as! [String: String])["queryInput"]!
            if command.contains("Finance.getVendorsAndRegions") {
                return (200, ["Content-Type": "text/xml"], Data("<VendorsAndRegions><Vendor><Number>80000001</Number><Region><Code>US</Code><Reports><Report>Financial</Report></Reports></Region></Vendor></VendorsAndRegions>".utf8))
            }
            #expect(command.hasSuffix("Finance.getReport, 80000001,ZZ,Financial,2026,4]"))
            return (200, ["Content-Type": "application/a-gzip"], FinanceSyncTests.january)
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let base = try #require(try await session.reporterClient(accountId: account.id))
        let reporter = try ReporterClient(token: base.token, origin: URL(string: "https://\(host)")!, configuration: configuration, selection: base.selection)
        let selected = try FinancialDownloadSelection(source: .reporter, periods: [FiscalPeriod(year: 2026, period: 4)], region: "ZZ")
        _ = try await session.startFinancialDownload(account: account, appId: appId, selection: selected, reporter: reporter)
        try await wait { try await session.financialDownloadJob(account: account, appId: appId)?.state == .complete }
        #expect(StubProtocol.requests(host).count == 2)
        #expect(try await session.pendingFinancialDownload(accountId: account.id, appId: appId)?.selection?.source == .reporter)
        #expect(try await session.financialReports(accountId: account.id, appId: appId).isEmpty)
    }

    @Test func uncommittedAndUnreadableInterruptionsCannotInventACompletedReview() async throws {
        for malformed in [false, true] {
            let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let reader = try FinancialDownloadTests().store(root)
            var job = FinancialDownloadJob(id: UUID().uuidString.lowercased(), selection: try selection(), now: Date(timeIntervalSince1970: 1))
            job.phase = .preparing; job.completed = job.total
            if malformed {
                try await retain(job, account: account, session: session)
                try reader.transaction { _ in [.put(namespace: "financial_reviews", key: "\(account.id):\(appId)", json: Data("{}".utf8))] }
            }
            try seed(job, account: account, store: reader)
            let before = try reader.document(namespace: "jobs", key: "financial:\(account.id):\(appId)")
            if malformed {
                await #expect(throws: FinancialFileFailure.storage) { try await session.financialDownloadJob(account: account, appId: appId) }
                #expect(try reader.document(namespace: "jobs", key: "financial:\(account.id):\(appId)") == before)
            } else {
                let recovered = try #require(try await session.financialDownloadJob(account: account, appId: appId))
                #expect(recovered.state == .failed && recovered.result == nil && recovered.code == "SB-REPORT-JOB")
            }
            #expect(try await session.financialReports(accountId: account.id, appId: appId).isEmpty)
        }
    }
}

@Suite(.serialized) struct FinancialJobProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test(arguments: [true, false]) func ownedFinancialProcessKeepsProgressUntilItInterruptsAndRecoversItsExactRetainedReview(retained: Bool) async throws {
        let fixture = try FinancialJobTests(), root = try TestIsolation.require().appendingPathComponent(retained ? "financial-job-retained-policy" : "financial-job-interrupted-policy")
        let id = retained ? "00000000-0000-4000-8000-000000000091" : "00000000-0000-4000-8000-000000000092"
        let (session, account, _) = try await FinanceSyncTests().session(directory: root), reader = try FinancialDownloadTests().store(root)
        var job = FinancialDownloadJob(id: id, selection: try fixture.selection(), now: Date(timeIntervalSince1970: 1))
        if retained { job.phase = .preparing; job.completed = job.total; try await fixture.retain(job, account: account, session: session) }
        try fixture.seed(job, account: account, store: reader)
        let name = try ReportJobs.name(.financial, accountId: account.id, appId: fixture.appId), mutex = reader.directory.appendingPathComponent("\(name).lock.mutex")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path))
        #expect(try FileMutex.tryLock(mutex) == nil)
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        #expect(try await session.financialDownloadJob(account: account, appId: fixture.appId)?.isActive == true)
        let coalesced = try await session.startFinancialDownload(account: account, appId: fixture.appId, selection: fixture.selection())
        #expect(coalesced.id == id && coalesced.isActive)
        #expect(try ReportJobs.acquire(.financial, accountId: account.id, appId: fixture.appId, directory: reader.directory, id: UUID().uuidString.lowercased()) == nil)
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        try await fixture.wait { if let proof = try FileMutex.tryLock(mutex) { proof.release(); return true }; return false }
        let recovered = try #require(try await session.financialDownloadJob(account: account, appId: fixture.appId))
        #expect(recovered.id == id && recovered.state == (retained ? .complete : .failed))
        #expect(recovered.result?.reviewId == (retained ? id : nil))
        #expect(try await session.financialReports(accountId: account.id, appId: fixture.appId).isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }
}
