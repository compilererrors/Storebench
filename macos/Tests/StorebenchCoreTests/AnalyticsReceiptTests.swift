import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AnalyticsReceiptTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001", now = Date(timeIntervalSince1970: 1_770_292_800)
    func bytes(_ count: Int = 3, app: String = "1000000001") -> Data {
        AnalyticsSyncTests.segment([["2026-02-03", "Synthetic App", app, "First-time Download", "1.0", "iPhone", "iOS 19", "App Store Search", "Store sheet", "No", "US", String(count)]])
    }
    func transport(_ api: String, storage: String, bytes: Data, segmentId: String = "synthetic-segment", unsafe: Bool = false) {
        let checksum = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        StubProtocol.handle(api) { request in
            #expect(request.httpMethod == "GET")
            let data: [[String: Any]]
            switch request.url!.path {
            case "/v1/apps/1000000001/analyticsReportRequests": data = [["type": "analyticsReportRequests", "id": "synthetic-ongoing", "attributes": ["accessType": "ONGOING"]]]
            case "/v1/analyticsReportRequests/synthetic-ongoing/reports": data = [["type": "analyticsReports", "id": "synthetic-downloads", "attributes": ["name": "App Downloads Standard"]]]
            case "/v1/analyticsReports/synthetic-downloads/instances": data = [["type": "analyticsReportInstances", "id": "synthetic-instance", "attributes": ["processingDate": "2026-02-04", "granularity": "DAILY"]]]
            case "/v1/analyticsReportInstances/synthetic-instance/segments": data = [["type": "analyticsReportSegments", "id": segmentId, "attributes": ["sizeInBytes": bytes.count, "checksum": checksum.uppercased(), "url": unsafe ? "https://synthetic-untrusted.example.test/report.gz" : "https://\(storage)/reports/synthetic.gz"]]]
            default: Issue.record("Unexpected synthetic Analytics receipt route"); return (404, [:], Data())
            }
            return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": data, "links": [:]]))
        }
        StubProtocol.handle(storage) { request in #expect(request.value(forHTTPHeaderField: "Authorization") == nil); return (200, [:], bytes) }
    }
    func run(_ session: WorkspaceSession, account: Account, api: String, incremental: Bool = true, days: Int = 1) async throws -> AnalyticsSyncResult {
        let selection = try AnalyticsDownloadSelection(kind: "downloads", level: "standard", granularity: "DAILY", endDate: "2026-02-04", days: days)
        let (_, task) = try await session.createAnalyticsDownload(account: account, appId: appId, selection: selection, client: SalesSyncTests().client(api, account: account), reuseRunning: false, now: now, incremental: incremental)
        return try await #require(task).value
    }
    @Test func unchangedManifestsReuseInstancesButRefreshAndChangedMetadataReadSegments() async throws {
        let helper = try AnalyticsSyncTests(), (session, root) = try helper.session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), api = "analytics-receipt-reuse.appstoreconnect.test", storage = "synthetic-receipt-reuse.s3.amazonaws.com"
        transport(api, storage: storage, bytes: bytes())
        #expect(try await run(session, account: account, api: api).changes.added == 1)
        let saved = try await session.savedAnalyticsFiles(account: account, appId: appId), receipts = try #require(await session.syncReceipts(accountId: account.id, appId: appId))
        #expect(receipts.entries.count == 1 && receipts.entries[0].outcome == .withApp)
        let again = try await run(session, account: account, api: api)
        #expect(again.reusedInstances == 1 && again.instances == 1 && again.changes.added == 0 && StubProtocol.requests(storage).count == 1)
        #expect(StubProtocol.requests(api).filter { $0.url!.path.hasSuffix("/segments") }.count == 2)
        #expect(try await session.savedAnalyticsFiles(account: account, appId: appId).partitions.map(\.json) == saved.partitions.map(\.json))
        _ = try await run(session, account: account, api: api, incremental: false)
        #expect(StubProtocol.requests(storage).count == 2)
        transport(api, storage: storage, bytes: bytes(7))
        #expect(try await run(session, account: account, api: api).reusedInstances == 0)
        #expect(StubProtocol.requests(storage).count == 1)
        let manifest = try #require(await session.syncReceipts(accountId: account.id, appId: appId)?.entries.first)
        #expect(manifest.remote != receipts.entries[0].remote)
        transport(api, storage: storage, bytes: bytes(7), segmentId: "synthetic-replacement-segment")
        #expect(try await run(session, account: account, api: api).reusedInstances == 0 && StubProtocol.requests(storage).count == 1)
        try await session.verifyBuckets(family: "analytics", accountId: account.id, appId: appId)
    }
    @Test func removedLocalPeriodsInvalidateReceiptsAndCachedUrlsStillRequireValidation() async throws {
        let helper = try AnalyticsSyncTests(), (session, root) = try helper.session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), api = "analytics-receipt-local.appstoreconnect.test", storage = "synthetic-receipt-local.s3.amazonaws.com"
        transport(api, storage: storage, bytes: bytes())
        _ = try await run(session, account: account, api: api)
        let saved = try await session.savedAnalyticsFiles(account: account, appId: appId), selected = try #require(saved.partitions.first { $0.processingDate == "2026-02-04" })
        try await session.removeAnalyticsFilePeriod(saved, key: selected.key)
        #expect(try await run(session, account: account, api: api).reusedInstances == 0 && StubProtocol.requests(storage).count == 2)
        let before = try await session.savedAnalyticsFiles(account: account, appId: appId).partitions.map(\.json), receipts = await session.syncReceipts(accountId: account.id, appId: appId)
        transport(api, storage: storage, bytes: bytes(), unsafe: true)
        await #expect(throws: AnalyticsFailure.integrity) { try await run(session, account: account, api: api) }
        #expect(StubProtocol.requests(storage).isEmpty)
        #expect(try await session.savedAnalyticsFiles(account: account, appId: appId).partitions.map(\.json) == before)
        #expect(await session.syncReceipts(accountId: account.id, appId: appId) == receipts)
    }
    @Test func cachedUnattributedInstancesAndMissingProcessingDatesStayUnknown() async throws {
        let helper = try AnalyticsSyncTests(), (session, root) = try helper.session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), api = "analytics-receipt-unknown.appstoreconnect.test", storage = "synthetic-receipt-unknown.s3.amazonaws.com"
        transport(api, storage: storage, bytes: bytes(app: "1000000099"))
        let first = try await run(session, account: account, api: api, days: 2)
        #expect(first.noAppInstances == 1 && first.reusedInstances == 0 && first.unavailableDays == ["2026-02-03"])
        #expect(await session.syncReceipts(accountId: account.id, appId: appId)?.entries.first?.outcome == .noApp)
        let again = try await run(session, account: account, api: api, days: 2)
        #expect(again.noAppInstances == 1 && again.reusedInstances == 0 && again.unavailableDays == first.unavailableDays)
        #expect(StubProtocol.requests(storage).count == 1)
        #expect(AppSync.analyticsItem(again, checkedAt: CustomerReview.isoString(now), days: 2).state == .partial)
        #expect(try await session.savedAnalyticsFiles(account: account, appId: appId).partitions.allSatisfy { $0.processingDate != "2026-02-04" })
    }
}
