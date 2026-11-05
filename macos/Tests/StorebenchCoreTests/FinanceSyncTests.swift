import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct FinanceSyncTests {
    init() throws { _ = try TestIsolation.require() }
    static let columns = ["Start Date", "End Date", "Quantity", "Partner Share", "Extended Partner Share", "Partner Share Currency", "Sale or Return", "Apple Identifier", "Product Type Identifier", "Country of Sale", "Customer Price", "Customer Currency"]
    static func report(_ rows: [[String]]) -> Data { gzip(([columns] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n") }
    static let january = report([
        ["12/29/2025", "01/31/2026", "3", "0.70", "2.10", "USD", "S", "1000000001", "1F", "US", "0.99", "USD"],
        ["12/29/2025", "01/31/2026", "-1", "6.50", "-6.50", "SEK", "R", "1000000001", "1F", "SE", "9.00", "SEK"],
        ["12/29/2025", "01/31/2026", "9", "0.70", "6.30", "USD", "S", "1000000099", "1F", "US", "0.99", "USD"],
    ])

    func session(reporter: Bool = false, directory: URL? = nil) async throws -> (WorkspaceSession, Account, URL) {
        let root = try directory ?? TestIsolation.require().appendingPathComponent("storebench-finance-\(UUID().uuidString)")
        try TestIsolation.check(root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: try SyntheticFixtures.database(), to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = #"{\"schemaVersion\":1,\"phase\":\"ready\",\"envelope\":{\"version\":1,\"mode\":\"device\",\"key\":\"\#(key)\"}}"#
        let vault = try CredentialVault(json: Data(#"{"version":1,"entries":{"\#(CredentialVault.databaseEntry(root: root))":"\#(record)","reporter:00000000-0000-4000-8000-000000000099":"synthetic-reporter-token-0001"}}"#.utf8))
        let session = try WorkspaceSession(workspace: Workspace(root: root), vault: vault)
        let account = try #require(try await session.accounts().first)
        let connection = reporter ? #"{"vendorNumber":"80000001","reporter":{"accountNumber":"1234567","vendorNumber":"80000001","credentialId":"00000000-0000-4000-8000-000000000099","connectedAt":"2026-01-01T00:00:00.000Z"}}"# : #"{"vendorNumber":"80000001"}"#
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "sales_connection", key: account.id, json: try SalesSyncTests.connection(connection, accountId: account.id).data)] } }
        return (session, account, root)
    }

    func client(_ host: String, _ account: Account) throws -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration)
    }

    @Test func downloadIsReviewedBeforeItIsSaved() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "finance.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            let url = request.url!.absoluteString
            #expect(request.url!.path == "/v1/financeReports" && url.contains("filter%5BvendorNumber%5D=80000001") && url.contains("filter%5BreportType%5D=FINANCIAL") && url.contains("filter%5BregionCode%5D=ZZ"))
            if url.contains("filter%5BreportDate%5D=2026-04") { return (200, ["Content-Type": "application/a-gzip"], Self.january) }
            // Another app only: checked without this app's rows. A 404 is not available yet, never zero proceeds.
            if url.contains("filter%5BreportDate%5D=2026-03") { return (200, ["Content-Type": "application/a-gzip"], Self.report([["11/30/2025", "12/28/2025", "1", "0.70", "0.70", "USD", "S", "1000000099", "1F", "US", "0.99", "USD"]])) }
            return (404, [:], Data())
        }
        let periods = FinancialReports.periods(ending: FiscalPeriod(year: 2026, period: 5), count: 3)
        #expect(periods.map(\.key) == ["2026-03", "2026-04", "2026-05"])
        let download = try await session.downloadFinancial(account: account, appId: "1000000001", region: "ZZ", periods: periods, client: client(host, account), now: Date(timeIntervalSince1970: 1_775_000_000))
        #expect(download.noApp == ["2026-03"] && download.unavailable == ["2026-05"] && download.reports.count == 1)
        #expect(download.changes.map(\.action) == ["added"] && download.changes[0].label == "2025-12-29 – 2026-01-31 · All countries · summary")
        #expect(download.changes[0].after == "3 sale units · 1 returned units\n-6.50 SEK · 2.10 USD")
        #expect(try await session.financialReports(accountId: account.id, appId: "1000000001").isEmpty)

        let saved = try await session.saveFinancial(download)
        #expect(saved.map(\.action) == ["added"])
        let reports = try await session.financialReports(accountId: account.id, appId: "1000000001")
        #expect(reports.count == 1 && reports[0].basis == "consolidated" && reports[0].source.rows.count == 2)
        let facts = FinancialReports.facts(reports[0])
        #expect(facts.first { $0.territory == "USA" }?.paid == 3 && facts.first { $0.territory == "SWE" }?.returned == 1)
        try await session.verifyBuckets(family: "financial", accountId: account.id, appId: "1000000001")

        let again = try await session.downloadFinancial(account: account, appId: "1000000001", region: "ZZ", periods: periods, client: client(host, account), now: Date(timeIntervalSince1970: 1_775_000_000))
        #expect(again.changes.map(\.action) == ["unchanged"])
        _ = try await session.saveFinancial(again)
        await #expect(throws: FinanceFailure.stale) { try await session.saveFinancial(download) }
    }

    @Test func parserRefusesAmountsThatDoNotAddUp() throws {
        let table = { (amount: String) in ReportTable(columns: Self.columns, rows: [["12/29/2025", "01/31/2026", "3", "0.70", amount, "USD", "S", "1000000001", "1F", "US", "0.99", "USD"]]) }
        #expect(try FinancialReports.fromTable(table("2.11"), scope: "ZZ", appId: "1000000001", importedAt: "2026-02-01T00:00:00.000Z").source.rows.count == 1)
        #expect(throws: FinanceFailure.format) { try FinancialReports.fromTable(table("2.50"), scope: "ZZ", appId: "1000000001", importedAt: "2026-02-01T00:00:00.000Z") }
        #expect(throws: FinanceFailure.format) { try FinancialReports.fromTable(table("-2.10"), scope: "ZZ", appId: "1000000001", importedAt: "2026-02-01T00:00:00.000Z") }
        let iap = ReportTable(columns: Self.columns, rows: [["12/29/2025", "01/31/2026", "1", "0.70", "0.70", "USD", "S", "1000000001", "IA1", "US", "0.99", "USD"]])
        #expect(throws: FinanceFailure.scope) { try FinancialReports.fromTable(iap, scope: "ZZ", appId: "1000000001", importedAt: "2026-02-01T00:00:00.000Z") }
        #expect(FinancialReports.latestClosedPeriod(now: Date(timeIntervalSince1970: 1_775_000_000)) == FiscalPeriod(year: 2026, period: 5))
    }

    @Test func reporterChecksFinancialAccessFirst() async throws {
        let (session, account, root) = try await session(reporter: true); defer { try? FileManager.default.removeItem(at: root) }
        let reporterHost = "finance.reporting.test"
        StubProtocol.handle(reporterHost) { request in
            let lock = try! FileMutex.tryLock(root.appendingPathComponent("state-v2/reporter_" + JSONText.string(account.id).rawSHA256.prefix(32) + ".mutex"))
            #expect(lock != nil); lock?.release()
            #expect(request.url!.path == "/reportservice/finance/v1")
            let body = String(data: request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            } ?? Data(), encoding: .utf8) ?? ""
            let form = URLComponents(string: "?" + body)?.queryItems?.first { $0.name == "jsonRequest" }?.value ?? ""
            let query = (try! JSONSerialization.jsonObject(with: Data(form.utf8)) as! [String: String])["queryInput"]!
            if query.contains("Finance.getVendorsAndRegions") {
                return (200, ["Content-Type": "text/xml"], Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><VendorsAndRegions><Vendor><Number>80000001</Number><Region><Code>US</Code><Reports><Report>Financial</Report></Reports></Region></Vendor></VendorsAndRegions>".utf8))
            }
            #expect(query.hasSuffix("Finance.getReport, 80000001,ZZ,Financial,2026,4]"))
            return (200, ["Content-Type": "application/a-gzip"], Self.january)
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let base = try #require(try await session.reporterClient(accountId: account.id))
        let reporter = try ReporterClient(token: base.token, origin: URL(string: "https://\(reporterHost)")!, configuration: configuration, selection: base.selection)
        let download = try await session.downloadFinancial(account: account, appId: "1000000001", region: "ZZ", periods: [FiscalPeriod(year: 2026, period: 4)], client: client("unused.appstoreconnect.test", account), reporter: reporter, now: Date(timeIntervalSince1970: 1_775_000_000))
        #expect(download.reports.count == 1)
        await #expect(throws: FinanceFailure.access) { try await session.downloadFinancial(account: account, appId: "1000000001", region: "SE", periods: [FiscalPeriod(year: 2026, period: 4)], client: client("unused.appstoreconnect.test", account), reporter: reporter) }
    }

    @Test func expiredDownloadReviewsCannotSaveOrReappearAsPendingSyncReviews() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "finance-review-expiry.appstoreconnect.test"
        StubProtocol.handle(host) { request in #expect(request.httpMethod == "GET" && request.url!.path == "/v1/financeReports"); return (200, ["Content-Type": "application/a-gzip"], Self.january) }
        let review = try await session.downloadFinancial(account: account, appId: "1000000001", region: "ZZ", periods: [FiscalPeriod(year: 2026, period: 4)], client: client(host, account))
        let expired = FinancialDownload(id: review.id, accountId: review.accountId, appId: review.appId, region: review.region, reports: review.reports, noApp: review.noApp, unavailable: review.unavailable, changes: review.changes, revision: review.revision, account: review.account, expiresAt: .distantPast)
        await #expect(throws: FinanceFailure.expiredReview) { try await session.saveFinancial(expired) }
        try await session.installSyntheticFinancialReview(expired)
        #expect(try await session.pendingFinancialDownload(accountId: account.id, appId: review.appId) == nil)
        #expect(try await session.financialReports(accountId: account.id, appId: review.appId).isEmpty)
    }

    @Test func everyGzipMemberIsDecodedAndACorruptLaterMemberCannotProduceAPartialReview() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let firstRow = ["12/29/2025", "01/31/2026", "3", ".70", "2.10", "USD", "S", account.appIds[0], "1F", "US", ".99", "USD"]
        let secondRow = ["12/29/2025", "01/31/2026", "2", ".70", "1.40", "USD", "S", account.appIds[0], "1F", "GB", ".99", "USD"]
        let first = try ReportFiles.gzip(Data(([Self.columns, firstRow].map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n").utf8))
        let second = try ReportFiles.gzip(Data((secondRow.joined(separator: "\t") + "\n").utf8))
        var broken = second; broken[broken.count - 8] ^= 1
        let valid = first + second, invalid = first + broken
        let host = "finance-gzip-members.appstoreconnect.test", brokenHost = "finance-gzip-integrity.appstoreconnect.test"
        StubProtocol.handle(host) { request in #expect(request.httpMethod == "GET" && request.url!.path == "/v1/financeReports"); return (200, ["Content-Type": "application/a-gzip"], valid) }
        StubProtocol.handle(brokenHost) { request in #expect(request.httpMethod == "GET" && request.url!.path == "/v1/financeReports"); return (200, ["Content-Type": "application/a-gzip"], invalid) }
        let review = try await session.downloadFinancial(account: account, appId: "1000000001", region: "ZZ", periods: [FiscalPeriod(year: 2026, period: 4)], client: client(host, account))
        #expect(review.reports[0].source.rows.count == 2 && review.changes[0].after.contains("5 sale units"))
        await #expect(throws: FinanceFailure.format) { try await session.downloadFinancial(account: account, appId: "1000000001", region: "ZZ", periods: [FiscalPeriod(year: 2026, period: 4)], client: client(brokenHost, account)) }
        #expect(try await session.financialReports(accountId: account.id, appId: "1000000001").isEmpty)
    }

    @Test func dismissingAnOlderSyncReviewKeepsTheNewerDownloadAndRejectsChangedAccountScope() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "finance-review-identity.appstoreconnect.test"
        StubProtocol.handle(host) { request in #expect(request.httpMethod == "GET" && request.url!.path == "/v1/financeReports"); return (200, ["Content-Type": "application/a-gzip"], Self.january) }
        let first = try await session.downloadFinancial(account: account, appId: "1000000001", region: "ZZ", periods: [FiscalPeriod(year: 2026, period: 4)], client: client(host, account))
        let newer = try await session.downloadFinancial(account: account, appId: "1000000001", region: "ZZ", periods: [FiscalPeriod(year: 2026, period: 4)], client: client(host, account))
        #expect(first.id != newer.id)
        try await session.installSyntheticFinancialReview(newer)
        try await session.clearPendingFinancialDownload(first)
        #expect(try await session.pendingFinancialDownload(accountId: account.id, appId: newer.appId)?.id == newer.id)
        try await session.clearPendingFinancialDownload(newer)
        #expect(try await session.pendingFinancialDownload(accountId: account.id, appId: newer.appId) == nil)
        try await session.installSyntheticFinancialReview(newer)
        try await session.storeAccess { store in
            let removed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
            try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(removed)]).data)] }
        }
        #expect(try await session.pendingFinancialDownload(accountId: account.id, appId: newer.appId) == nil)
        await #expect(throws: FinanceFailure.scope) { try await session.saveFinancial(newer) }
        #expect(try await session.financialReports(accountId: account.id, appId: newer.appId).isEmpty)
    }
}

extension WorkspaceSession {
    func installSyntheticFinancialReview(_ review: FinancialDownload) throws {
        _ = try TestIsolation.require()
        guard review.accountId == "synthetic-account", review.appId == "1000000001" else { throw TestIsolation.Failure.unguarded }
        if review.expiresAt > Date() { try retainPendingFinancialDownload(review); return }
        let selection = try FinancialDownloadSelection(source: .api, periods: [FiscalPeriod(year: 2026, period: 4)], region: review.region)
        let id = review.id.uuidString.lowercased(), key = "\(review.accountId):\(review.appId)"
        let value = JSONText.object([("schemaVersion", .number(1)), ("createdAt", .string(CustomerReview.isoString(Date().addingTimeInterval(-2 * 86_400)))),
            ("selection", selection.json), ("history", FinancialFileFormats.history(accountId: review.accountId, appId: review.appId, reports: review.reports))])
        try storeAccess { store in try store.transaction { _ in [
            .put(namespace: "financial_reviews", key: key, json: JSONText.array([.object([("id", .string(id)), ("value", value)])]).data),
            .put(namespace: "financial_pending", key: key, json: JSONText.object([("id", .string(id)), ("noApp", .array([])), ("unavailable", .array([]))]).data)] } }
    }
}
