import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct SalesReceiptTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001", now = Date(timeIntervalSince1970: 1_770_206_400)
    func bytes(_ units: Int = 3, app: String = "1000000001") -> Data {
        SalesSyncTests.report([["APPLE", "SYNTHETIC", app, "1F", String(units), "0.99", "02/03/2026", "02/03/2026", "US", ""]])
    }
    func transport(_ host: String, catalog: Bool = true, status: Int = 200, bytes: Data) {
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "GET")
            if request.url!.path == "/v1/salesReports" { return (status, ["Content-Type": "application/a-gzip"], bytes) }
            #expect(request.url!.path.contains("inAppPurchasesV2") || request.url!.path.contains("subscriptionGroups"))
            return (catalog ? 200 : 404, [:], Data(#"{"data":[],"links":{}}"#.utf8))
        }
    }
    func files(_ host: String) -> Int { StubProtocol.requests(host).filter { $0.url?.path == "/v1/salesReports" }.count }
    func run(_ session: WorkspaceSession, account: Account, host: String, incremental: Bool = true, cache: SharedReportBytes = SharedReportBytes(), now: Date? = nil, app: String? = nil) async throws -> SalesSyncResult {
        let selection = try SalesDownloadSelection(source: .api, endDate: "2026-02-03", days: 1)
        let (_, task) = try await session.createSalesDownload(account: account, appId: app ?? appId, selection: selection, client: SalesSyncTests().client(host, account: account), reporter: nil,
                                                            reuseRunning: false, now: now ?? self.now, incremental: incremental, sharedBytes: cache)
        return try await #require(task).value
    }
    @Test func freshDaysReuseExactSavedContentWhileRefreshAndLocalChangesReadAgain() async throws {
        let helper = try SalesJobTests(), (session, account, root) = try await helper.session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "sales-receipt-reuse.appstoreconnect.test", cache = SharedReportBytes()
        transport(host, bytes: bytes())
        #expect(try await run(session, account: account, host: host, cache: cache).changes.added == 1)
        let first = try await session.salesFileRecords(account: account, appId: appId).map(\.json), receipts = try #require(await session.syncReceipts(accountId: account.id, appId: appId))
        #expect(receipts.entries.count == 1 && receipts.entries[0].outcome == .withApp && receipts.entries[0].remote == SyncReceipt.bytesFingerprint(bytes()))
        let again = try await run(session, account: account, host: host, cache: cache)
        #expect(again.changes.unchanged == 1 && again.changes.added == 0 && files(host) == 1)
        #expect(try await session.salesFileRecords(account: account, appId: appId).map(\.json) == first)
        #expect(StubProtocol.requests(host).filter { $0.url!.path.contains("inAppPurchasesV2") }.count == 2)
        _ = try await run(session, account: account, host: host, incremental: false, cache: cache)
        #expect(files(host) == 2)
        try await session.removeSalesFilePeriod(account: account, appId: appId, beginDate: "2026-02-03", endDate: "2026-02-03")
        _ = try await run(session, account: account, host: host)
        #expect(files(host) == 3)
        let changed = bytes(7)
        _ = try await session.importSalesFile(account: account, appId: appId, data: changed, client: SalesSyncTests().client(host, account: account), now: now.addingTimeInterval(1))
        transport(host, bytes: bytes())
        _ = try await run(session, account: account, host: host)
        #expect(files(host) == 1)
        #expect(try await session.sales(accountId: account.id, appId: appId).first { $0.beginDate == "2026-02-03" }?.paidUnits == 3)
        try await session.verifyBuckets(family: "sales", accountId: account.id, appId: appId)
    }
    @Test func unavailableAnswersExpireAndTemporaryFailuresNeverBecomeReceipts() async throws {
        let helper = try SalesJobTests(), (session, account, root) = try await helper.session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "sales-receipt-missing.appstoreconnect.test"
        transport(host, status: 503, bytes: Data())
        await #expect(throws: AppStoreConnectClient.Failure.status(503)) { try await run(session, account: account, host: host) }
        #expect(await session.syncReceipts(accountId: account.id, appId: appId) == nil)
        transport(host, status: 404, bytes: Data())
        await #expect(throws: SalesFailure.unavailable) { try await run(session, account: account, host: host) }
        #expect(await session.syncReceipts(accountId: account.id, appId: appId)?.entries.first?.outcome == .unavailable)
        let count = files(host)
        await #expect(throws: SalesFailure.unavailable) { try await run(session, account: account, host: host, now: now.addingTimeInterval(10)) }
        #expect(files(host) == count)
        await #expect(throws: SalesFailure.unavailable) { try await run(session, account: account, host: host, now: now.addingTimeInterval(901)) }
        #expect(files(host) == count + 1)
        #expect(try await session.salesFileRecords(account: account, appId: appId).allSatisfy { $0.beginDate != "2026-02-03" })
    }
    @Test func unattributedRowsRemainUnknownAndNoSalesCannotReplaceSavedSales() async throws {
        let helper = try SalesJobTests(), (session, account, root) = try await helper.session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "sales-receipt-unknown.appstoreconnect.test"
        transport(host, catalog: false, bytes: bytes(app: "1000000099"))
        let unknown = try await run(session, account: account, host: host)
        #expect(unknown.noAppRowsDays == ["2026-02-03"] && unknown.noSalesDays.isEmpty)
        #expect(await session.syncReceipts(accountId: account.id, appId: appId)?.entries.first?.outcome == .noApp)
        _ = try await run(session, account: account, host: host)
        #expect(files(host) == 1)
        transport(host, bytes: bytes(app: "1000000099"))
        #expect(try await run(session, account: account, host: host).noSalesDays == ["2026-02-03"])
        #expect(try await session.salesFileRecords(account: account, appId: appId).first { $0.beginDate == "2026-02-03" }?.noSales == true)
        transport(host, bytes: bytes())
        _ = try await run(session, account: account, host: host, incremental: false)
        transport(host, bytes: bytes(app: "1000000099"))
        _ = try await run(session, account: account, host: host)
        #expect(try await session.sales(accountId: account.id, appId: appId).first { $0.beginDate == "2026-02-03" }?.paidUnits == 3)
        let rows = try await session.salesFileRecords(account: account, appId: appId), stored = rows.first { $0.beginDate == "2026-02-03" }
        #expect(await session.syncReceipts(accountId: account.id, appId: appId)?.entries.filter { $0.outcome == .noSales }.allSatisfy { $0.local != stored?.json.sha256 } == true)
    }
    @Test func twoAppsShareVendorBytesButSaveOnlyTheirOwnRows() async throws {
        let helper = try SalesJobTests(), (session, original, root) = try await helper.session(); defer { try? FileManager.default.removeItem(at: root) }
        let otherApp = "1000000003", account = Account(id: original.id, name: original.name, keyId: original.keyId, keyType: original.keyType, issuerId: original.issuerId, appIds: [appId, otherApp], appNames: nil)
        let store = try helper.store(root)
        try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(account)]).data)] }
        let host = "sales-receipt-shared.appstoreconnect.test", cache = SharedReportBytes()
        transport(host, bytes: SalesSyncTests.report([
            ["APPLE", "SYNTHETIC", appId, "1F", "3", "0.99", "02/03/2026", "02/03/2026", "US", ""],
            ["APPLE", "SYNTHETIC-OTHER", otherApp, "1F", "9", "0.99", "02/03/2026", "02/03/2026", "SE", ""]]))
        async let first = run(session, account: account, host: host, cache: cache)
        async let second = run(session, account: account, host: host, cache: cache, app: otherApp)
        _ = try await (first, second)
        #expect(files(host) == 1)
        #expect(try await session.sales(accountId: account.id, appId: appId).first { $0.beginDate == "2026-02-03" }?.paidUnits == 3)
        #expect(try await session.sales(accountId: account.id, appId: otherApp).first { $0.beginDate == "2026-02-03" }?.paidUnits == 9)
        #expect(await session.syncReceipts(accountId: account.id, appId: appId)?.entries.first?.local != session.syncReceipts(accountId: account.id, appId: otherApp)?.entries.first?.local)
        let another = Account(id: "synthetic-other-account", name: "Synthetic other account", keyId: original.keyId, keyType: original.keyType, issuerId: original.issuerId, appIds: [appId], appNames: nil)
        try store.transaction { _ in [
            .put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(account), WorkspaceSession.json(another)]).data),
            .put(namespace: "sales_connection", key: another.id, json: try SalesSyncTests.connection(#"{"vendorNumber":"80000001"}"#, accountId: another.id).data)] }
        _ = try await run(session, account: another, host: host, cache: cache)
        #expect(files(host) == 2)
        #expect(try await session.salesFileRecords(account: another, appId: appId).allSatisfy { $0.accountId == another.id })
    }
    @Test func freshReporterReceiptsDoNotRequireACredentialUntilAnActualDownload() async throws {
        let helper = try SalesJobTests(), (session, account, root) = try await helper.session(); defer { try? FileManager.default.removeItem(at: root) }
        try await SalesSyncTests().connect(session, #"{"vendorNumber":"80000001","reporter":{"accountNumber":"1234567","vendorNumber":"80000001","credentialId":"00000000-0000-4000-8000-000000000099","connectedAt":"2026-01-01T00:00:00.000Z"}}"#)
        let host = "sales-receipt-reporter.reporting.test", report = bytes()
        StubProtocol.handle(host) { _ in (200, ["Content-Type": "application/a-gzip"], report) }
        let original = try #require(try await session.reporterClient(accountId: account.id)), configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let reporter = try ReporterClient(token: original.token, origin: URL(string: "https://\(host)")!, configuration: configuration, selection: original.selection)
        let selection = try SalesDownloadSelection(source: .reporter, endDate: "2026-02-03", days: 1)
        let (_, first) = try await session.createSalesDownload(account: account, appId: appId, selection: selection, client: nil, reporter: reporter,
            reuseRunning: false, now: now, incremental: true, sharedBytes: SharedReportBytes())
        _ = try await #require(first).value
        let vault = await session.vault
        let noToken = try CredentialVault(json: JSONText.object([("version", .number(1)), ("entries", .object(vault.entries.filter { !$0.key.hasPrefix("reporter:") }.map { ($0.key, .string($0.value)) }))]).data)
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: noToken)
        let (_, reused) = try await reopened.createSalesDownload(account: account, appId: appId, selection: selection, client: nil, reporter: nil,
            reuseRunning: false, now: now, incremental: true, sharedBytes: SharedReportBytes())
        #expect(try await #require(reused).value.changes.unchanged == 1 && StubProtocol.requests(host).count == 1)
        let (_, forced) = try await reopened.createSalesDownload(account: account, appId: appId, selection: selection, client: nil, reporter: nil,
            reuseRunning: false, now: now, incremental: false, sharedBytes: SharedReportBytes())
        await #expect(throws: SalesFailure.noConnection) { try await #require(forced).value }
    }
    @Test func aConcurrentEditOfAReusedDayPreventsTheWholeBatchFromOverwritingHistory() async throws {
        let helper = try SalesJobTests(), (session, account, root) = try await helper.session(); defer { try? FileManager.default.removeItem(at: root) }
        let initialHost = "sales-receipt-edit.appstoreconnect.test", batchHost = "sales-receipt-batch.appstoreconnect.test", batchTime = now.addingTimeInterval(86_400)
        transport(initialHost, bytes: bytes())
        _ = try await run(session, account: account, host: initialHost, now: batchTime)
        let gate = AnalyticsJobDelayStubProtocol.Gate()
        AnalyticsJobDelayStubProtocol.register(batchHost, gate: gate, bytes: SalesSyncTests.report([
            ["APPLE", "SYNTHETIC", appId, "1F", "8", "0.99", "02/04/2026", "02/04/2026", "US", ""]]), headers: ["Content-Type": "application/a-gzip"], path: "/v1/salesReports")
        StubProtocol.handle(batchHost) { _ in (200, [:], Data(#"{"data":[],"links":{}}"#.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AnalyticsJobDelayStubProtocol.self, StubProtocol.self]
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(batchHost)")!, configuration: configuration)
        let selection = try SalesDownloadSelection(source: .api, endDate: "2026-02-04", days: 2)
        let (_, task) = try await session.createSalesDownload(account: account, appId: appId, selection: selection, client: client, reporter: nil,
            reuseRunning: false, now: batchTime.addingTimeInterval(10), incremental: true, sharedBytes: SharedReportBytes())
        try await helper.wait { gate.pending == 1 }
        _ = try await session.importSalesFile(account: account, appId: appId, data: bytes(7), client: SalesSyncTests().client(initialHost, account: account), now: batchTime.addingTimeInterval(20))
        let saved = try await session.salesFileRecords(account: account, appId: appId).map(\.json), receipts = await session.syncReceipts(accountId: account.id, appId: appId)
        gate.release()
        await #expect(throws: PartitionedReports.Failure.stale) { try await #require(task).value }
        #expect(try await session.salesFileRecords(account: account, appId: appId).map(\.json) == saved)
        #expect(await session.syncReceipts(accountId: account.id, appId: appId) == receipts)
        #expect(try await session.salesDownloadJob(account: account, appId: appId)?.state == .failed)
    }
}
