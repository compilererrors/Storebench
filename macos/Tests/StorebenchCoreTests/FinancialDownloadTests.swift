import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct FinancialDownloadTests {
    init() throws { _ = try TestIsolation.require() }
    func download(_ session: WorkspaceSession, account: Account, host: String, retain: Bool = true) async throws -> FinancialDownload {
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "GET" && request.url!.path == "/v1/financeReports")
            return (200, ["Content-Type": "application/a-gzip"], FinanceSyncTests.january)
        }
        let client = try FinanceSyncTests().client(host, account)
        if !retain { return try await session.downloadFinancialBody(account: account, appId: "1000000001", region: "ZZ", periods: [FiscalPeriod(year: 2026, period: 4)], client: client,
            reporter: nil, source: .api, now: Date(), reviewId: UUID(), check: {}, progress: { _, _, _ in }) }
        return try await session.downloadFinancial(account: account, appId: "1000000001", region: "ZZ", periods: [FiscalPeriod(year: 2026, period: 4)], client: client)
    }
    func store(_ root: URL) throws -> EncryptedDocumentStore { try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true) }

    @Test func retainedCacheContractsAndFingerprintsMatchWebIncludingUnrelatedExpiry() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/financial-downloads.json")))
        guard case .array(let vectors)? = fixture["vectors"], let accountId = fixture["accountId"]?.text, let appId = fixture["appId"]?.text else { throw FinancialFileFailure.storage }
        for row in vectors {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: (any Error).self) { try FinancialDownloadRecord.cache(input.data, accountId: accountId, appId: appId, now: Date()) } }
            else {
                let records = try FinancialDownloadRecord.cache(input.data, accountId: accountId, appId: appId, now: Date())
                let first = try #require(records.first), expected = try #require(fixture["expected"]), fingerprint = try #require(row["fingerprint"]?.text)
                #expect(first.json == expected)
                #expect(first.value.sha256 == fingerprint)
            }
        }
    }

    @Test func freshReviewTimesUsePrimaryMillisecondsAndRejectTheNextMillisecond() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/financial-downloads.json")))
        guard case .array(let clocks)? = fixture["clocks"], case .array(let reports)? = fixture["expected"]?["value"]?["history"]?["reports"] else { throw FinancialFileFailure.storage }
        #expect(clocks.count == 3000)
        let accountId = "synthetic-account", appId = "1000000001"
        let smallReports = try reports.map { report -> JSONText in
            guard case .object(let fields) = report, let columns = report["source"]?["columns"], case .array(let rows)? = report["source"]?["rows"], !rows.isEmpty else { throw FinancialFileFailure.storage }
            let source = JSONText.object([("columns", columns), ("rows", .array(Array(rows.prefix(1))))])
            return .object(fields.map { ($0.0, $0.0 == "source" ? source : $0.1) })
        }
        func record(_ stamp: String) -> JSONText { .object([("id", .string("00000000-0000-4000-8000-000000000081")), ("value", .object([("schemaVersion", .number(1)), ("createdAt", .string(stamp)), ("selection", fixture["expected"]!["value"]!["selection"]!), ("history", .object([("schemaVersion", .number(1)), ("accountId", .string(accountId)), ("appId", .string(appId)), ("reports", .array(smallReports))]))]))]) }
        var foundationDifferences = 0
        for row in clocks {
            guard case .number(let milliseconds)? = row["nowMs"], let stamp = row["createdAt"]?.text, let extended = row["extended"]?.text, let future = row["future"]?.text else { throw FinancialFileFailure.storage }
            let now = Date(timeIntervalSince1970: milliseconds / 1000)
            if milliseconds == floor(milliseconds), let parsed = ISO8601DateFormatter.storebench.date(from: stamp) {
                let sameUnixTime = Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.nextDown)
                if sameUnixTime.timeIntervalSince1970 == now.timeIntervalSince1970 {
                    #expect(parsed > sameUnixTime)
                    _ = try FinancialDownloadRecord(json: record(stamp), accountId: accountId, appId: appId, now: sameUnixTime)
                    foundationDifferences += 1
                }
            }
            let ordinary = try FinancialDownloadRecord(json: record(stamp), accountId: accountId, appId: appId, now: now)
            let longer = try FinancialDownloadRecord(json: record(extended), accountId: accountId, appId: appId, now: now)
            #expect(ordinary.createdAt == stamp && longer.createdAt == extended && ordinary.expiresAt == longer.expiresAt)
            #expect(throws: FinanceFailure.expiredReview) { try FinancialDownloadRecord(json: record(future), accountId: accountId, appId: appId, now: now) }
        }
        #expect(foundationDifferences > 0)
        print("Synthetic Finance clocks checked: \(clocks.count); native submillisecond comparison differences: \(foundationDifferences).")
    }

    @Test func aNewSessionReopensAnExplicitReviewAndSavingClearsOnlyItsPointer() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let review = try await download(session, account: account, host: "finance-retained-session.appstoreconnect.test")
        try await session.retainPendingFinancialDownload(review)
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let reopened = try #require(try await second.pendingFinancialDownload(accountId: account.id, appId: review.appId))
        #expect(reopened.id == review.id && reopened.reports == review.reports && reopened.changes.map(\.action) == ["added"])
        #expect(try await second.financialReports(accountId: account.id, appId: review.appId).isEmpty)
        _ = try await second.saveFinancial(reopened)
        #expect(try await session.pendingFinancialDownload(accountId: account.id, appId: review.appId) == nil)
        #expect(try await session.financialReports(accountId: account.id, appId: review.appId) == review.reports)
    }

    @Test func savingOrDiscardingAnOlderReviewPreservesANewerPendingDownload() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let first = try await download(session, account: account, host: "finance-retained-older.appstoreconnect.test")
        try await session.retainPendingFinancialDownload(first)
        let opened = try #require(try await second.pendingFinancialDownload(accountId: account.id, appId: first.appId))
        let newer = try await download(session, account: account, host: "finance-retained-newer.appstoreconnect.test")
        try await session.retainPendingFinancialDownload(newer)
        _ = try await second.saveFinancial(opened)
        try await second.clearPendingFinancialDownload(opened)
        #expect(try await session.pendingFinancialDownload(accountId: account.id, appId: newer.appId)?.id == newer.id)
        await #expect(throws: FinanceFailure.stale) { try await second.saveFinancial(opened) }
    }

    @Test func changedRetainedSourceCannotSaveAndUnreadableStatusPreservesItsPointer() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let review = try await download(session, account: account, host: "finance-retained-source.appstoreconnect.test")
        try await session.retainPendingFinancialDownload(review)
        let opened = try #require(try await session.pendingFinancialDownload(accountId: account.id, appId: review.appId))
        let reader = try store(root), key = "\(account.id):\(review.appId)"
        let document = try #require(try reader.document(namespace: "financial_reviews", key: key))
        var cache = try JSONSerialization.jsonObject(with: document.payload) as! [[String: Any]]
        var value = cache[0]["value"] as! [String: Any], history = value["history"] as! [String: Any], reports = history["reports"] as! [[String: Any]], source = reports[0]["source"] as! [String: Any]
        var rows = source["rows"] as! [[String]]
        let quantity = try #require((source["columns"] as! [String]).firstIndex(of: "Quantity"))
        let positive = try #require(rows.firstIndex(where: { $0[quantity] == "3" })); rows[positive][quantity] = "03"; source["rows"] = rows
        reports[0]["source"] = source; history["reports"] = reports; value["history"] = history; cache[0]["value"] = value
        try reader.transaction { _ in [.put(namespace: "financial_reviews", key: key, json: try JSONSerialization.data(withJSONObject: cache))] }
        let pointer = try reader.document(namespace: "financial_pending", key: key)
        await #expect(throws: FinanceFailure.stale) { try await session.saveFinancial(opened) }
        #expect(try reader.document(namespace: "financial_pending", key: key) == pointer)
        #expect(try await session.financialReports(accountId: account.id, appId: review.appId).isEmpty)
        try reader.transaction { _ in [.put(namespace: "financial_reviews", key: key, json: Data("{}".utf8))] }
        await #expect(throws: FinancialFileFailure.storage) { try await session.pendingFinancialDownload(accountId: account.id, appId: review.appId) }
        #expect(try reader.document(namespace: "financial_pending", key: key) == pointer)
    }

    @Test func cacheBoundsEvictAnOldSourceWithoutDiscardingTheCurrentReview() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await download(session, account: account, host: "finance-retained-bound.appstoreconnect.test")
        try await session.retainPendingFinancialDownload(first)
        let opened = try #require(try await session.pendingFinancialDownload(accountId: account.id, appId: first.appId))
        var last = first
        for _ in 0..<3 { last = try await download(session, account: account, host: "finance-retained-bound.appstoreconnect.test"); try await session.retainPendingFinancialDownload(last) }
        let reader = try store(root), key = "\(account.id):\(first.appId)"
        let cache = try FinancialDownloadRecord.cache(reader.document(namespace: "financial_reviews", key: key)?.payload, accountId: account.id, appId: first.appId, now: Date())
        #expect(cache.count == 3 && !cache.contains(where: { $0.id == first.id.uuidString.lowercased() }))
        await #expect(throws: FinanceFailure.expiredReview) { try await session.saveFinancial(opened) }
        #expect(try await session.pendingFinancialDownload(accountId: account.id, appId: last.appId)?.id == last.id)
        #expect(try await session.financialReports(accountId: account.id, appId: last.appId).isEmpty)
    }

    @Test func overviewSyncKeepsWaitingFinanceWithoutAnotherKeychainReadOrDownload() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "finance-retained-overview.appstoreconnect.test", review = try await download(session, account: account, host: host)
        try await session.retainPendingFinancialDownload(review)
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let results = await second.syncApp(account: account, appId: review.appId)
        let finance = try #require(results.first(where: { $0.key == "finance" }))
        #expect(finance.state == .attention && finance.detail == "Downloaded. Open Financial Reports to review the fiscal dates and changes, then save the reports.")
        #expect(try await second.pendingFinancialDownload(accountId: account.id, appId: review.appId)?.id == review.id)
        #expect(try await second.financialReports(accountId: account.id, appId: review.appId).isEmpty)
        #expect(StubProtocol.requests(host).count == 1)
    }

    @Test func missingAndUnattributedFinancePeriodsStayPartialWithoutInventedRows() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let baseline = try await session.savedFinancialFiles(account: account, appId: "1000000001")
        for (noApp, unavailable) in [(["2026-04"], []), ([], ["2026-04"])] {
            let result = FinancialDownload(id: UUID(), accountId: account.id, appId: "1000000001", region: "ZZ", reports: [], noApp: noApp, unavailable: unavailable,
                changes: [], revision: baseline.revision, account: account, expiresAt: Date().addingTimeInterval(86_400))
            let status = AppSync.financialStatus(result)
            #expect(status.state == .partial && status.detail.contains("unknown"))
            #expect(try await session.financialReports(accountId: account.id, appId: "1000000001").isEmpty)
        }
    }

    @Test func retentionBoundsActualCacheBytesBeforeReplacingAPendingReview() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let review = try await download(session, account: account, host: "finance-retained-size.appstoreconnect.test")
        try await session.retainPendingFinancialDownload(review)
        let report = try #require(review.reports.first), quantity = try #require(report.source.columns.firstIndex(of: "Quantity"))
        let positive = try #require(report.source.rows.first(where: { $0[quantity] == "3" }))
        let source = ReportTable(columns: report.source.columns + ["Title"], rows: Array(repeating: positive + [String(repeating: "synthetic", count: 250)], count: 6000))
        let large = FinancialReport(beginDate: report.beginDate, endDate: report.endDate, region: report.region, basis: report.basis, importedAt: report.importedAt, source: source)
        let incoming = FinancialDownload(id: UUID(), accountId: account.id, appId: review.appId, region: review.region, reports: [large], noApp: [], unavailable: [], changes: [],
            revision: review.revision, account: account, expiresAt: review.expiresAt, selection: review.selection)
        await #expect(throws: FinanceFailure.size) { try await session.retainPendingFinancialDownload(incoming) }
        #expect(try await session.pendingFinancialDownload(accountId: account.id, appId: review.appId)?.id == review.id)
        #expect(try await session.financialReports(accountId: account.id, appId: review.appId).isEmpty)
    }
}

@Suite(.serialized) struct FinancialDownloadProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func waitingRetentionRechecksAccountAfterItsOwnedMutexProcessInterrupts() async throws {
        let root = try TestIsolation.require().appendingPathComponent("financial-review-lock-policy")
        let (session, account, _) = try await FinanceSyncTests().session(directory: root)
        let review = try await FinancialDownloadTests().download(session, account: account, host: "finance-retained-lock.appstoreconnect.test", retain: false)
        let reader = try FinancialDownloadTests().store(root), mutex = reader.directory.appendingPathComponent("financial_reviews_\(JSONText.string("\(account.id)\u{0}\(review.appId)").rawSHA256.prefix(32)).mutex")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path))
        #expect(try FileMutex.tryLock(mutex) == nil)
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        let operation = Task { try await session.retainPendingFinancialDownload(review) }
        try await Task.sleep(for: .milliseconds(100))
        let removed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(removed)]).data)] }
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        await #expect(throws: FinanceFailure.scope) { try await operation.value }
        #expect(try reader.documents(namespace: "financial_reviews").isEmpty && reader.documents(namespace: "financial_pending").isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }
}
