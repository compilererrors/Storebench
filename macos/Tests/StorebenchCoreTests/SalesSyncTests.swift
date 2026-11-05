import CryptoKit
import Foundation
import Testing
import zlib
@testable import StorebenchCore

/// Gzip for synthetic reports, the format Apple delivers Summary Sales Reports in.
func gzip(_ text: String) -> Data {
    var stream = z_stream(), input = Array(text.utf8), output = [UInt8](repeating: 0, count: input.count + 256)
    deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    let produced = input.withUnsafeMutableBufferPointer { inBuffer in output.withUnsafeMutableBufferPointer { outBuffer in
        stream.next_in = inBuffer.baseAddress; stream.avail_in = uInt(inBuffer.count)
        stream.next_out = outBuffer.baseAddress; stream.avail_out = uInt(outBuffer.count)
        deflate(&stream, Z_FINISH); return Int(stream.total_out)
    } }
    deflateEnd(&stream)
    return Data(output.prefix(produced))
}

@Suite(.serialized) struct SalesSyncTests {
    init() throws { _ = try TestIsolation.require() }
    static let columns = ["Provider", "SKU", "Apple Identifier", "Product Type Identifier", "Units", "Customer Price", "Begin Date", "End Date", "Country Code", "Parent Identifier"]
    static func report(_ rows: [[String]]) -> Data { gzip(([columns] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n") }

    func session(directory: URL? = nil) throws -> (WorkspaceSession, URL) {
        let root = try directory ?? TestIsolation.require().appendingPathComponent("storebench-sales-\(UUID().uuidString)")
        try TestIsolation.check(root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: try SyntheticFixtures.database(), to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = #"{\"schemaVersion\":1,\"phase\":\"ready\",\"envelope\":{\"version\":1,\"mode\":\"device\",\"key\":\"\#(key)\"}}"#
        let vault = try CredentialVault(json: Data(#"{"version":1,"entries":{"\#(CredentialVault.databaseEntry(root: root))":"\#(record)","reporter:00000000-0000-4000-8000-000000000099":"synthetic-reporter-token-0001"}}"#.utf8))
        return (try WorkspaceSession(workspace: Workspace(root: root), vault: vault), root)
    }

    static func connection(_ text: String, accountId: String) throws -> JSONText {
        guard case .object(let fields) = try JSONText.parse(Data(text.utf8)) else { throw ReporterSetupFailure.invalid }
        return .object([("schemaVersion", .number(1)), ("accountId", .string(accountId))] + fields)
    }

    func connect(_ session: WorkspaceSession, _ connection: String) async throws {
        let accountId = try #require(try await session.accounts().first).id
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "sales_connection", key: accountId, json: try Self.connection(connection, accountId: accountId).data)] } }
    }

    func client(_ host: String, account: Account) throws -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration)
    }

    @Test func teamKeyDownloadsDailyReportsWithoutTurningGapsIntoZero() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        try await connect(session, #"{"vendorNumber":"80000001"}"#)
        let host = "sales.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            let url = request.url!.absoluteString
            if url.contains("inAppPurchasesV2") { return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": [["type": "inAppPurchases", "id": "6000000001"]], "links": [:]])) }
            if url.contains("subscriptionGroups") { return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": [], "links": [:]])) }
            #expect(request.url!.path == "/v1/salesReports" && url.contains("filter%5BvendorNumber%5D=80000001"))
            if url.contains("2026-02-03") { return (200, ["Content-Type": "application/a-gzip"], Self.report([
                ["APPLE", "SYNTHETIC", "1000000001", "1F", "3", "0.99", "02/03/2026", "02/03/2026", "US", ""],
                ["APPLE", "SYN-IAP", "6000000001", "IA1", "2", "1.99", "02/03/2026", "02/03/2026", "SE", "SYNTHETIC"],
                ["APPLE", "OTHER", "1000000099", "1F", "9", "0.99", "02/03/2026", "02/03/2026", "US", ""],
            ])) }
            // Another app sold, ours had no rows, and the whole catalog is verified: a checked day without sales.
            if url.contains("2026-02-04") { return (200, ["Content-Type": "application/a-gzip"], Self.report([["APPLE", "OTHER", "1000000099", "1F", "1", "0.99", "02/04/2026", "02/04/2026", "GB", ""]])) }
            return (404, [:], Data())
        }
        let result = try await session.downloadSales(account: account, appId: "1000000001", days: ["2026-02-03", "2026-02-04", "2026-02-05"], client: client(host, account: account))
        #expect(result.unavailableDays == ["2026-02-05"] && result.noSalesDays == ["2026-02-04"] && result.noAppRowsDays.isEmpty)
        #expect(result.changes.added == 2)

        let saved = try await session.sales(accountId: account.id, appId: "1000000001")
        let day = try #require(saved.first { $0.beginDate == "2026-02-03" })
        #expect(day.unitsByTerritory == ["USA": 3] && day.paidUnits == 3)
        #expect(saved.contains { $0.beginDate == "2026-02-04" && $0.noSales == true })
        #expect(!saved.contains { $0.beginDate == "2026-02-05" })
        // Earlier saved months are untouched and every bucket still matches its index fingerprint.
        #expect(saved.contains { $0.beginDate == "2026-01-30" })
        try await session.verifyBuckets(family: "sales", accountId: account.id, appId: "1000000001")

        let again = try await session.downloadSales(account: account, appId: "1000000001", days: ["2026-02-03"], client: client(host, account: account))
        #expect(again.changes.added == 0 && again.changes.updated == 0)
    }

    @Test func noSalesNeverReplacesSavedSales() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        try await connect(session, #"{"vendorNumber":"80000001"}"#)
        let host = "nosales.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            let url = request.url!.absoluteString
            if url.contains("inAppPurchasesV2") || url.contains("subscriptionGroups") { return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": [], "links": [:]])) }
            return (200, ["Content-Type": "application/a-gzip"], Self.report([["APPLE", "OTHER", "1000000099", "1F", "1", "0.99", "01/31/2026", "01/31/2026", "GB", ""]]))
        }
        _ = try await session.downloadSales(account: account, appId: "1000000001", days: ["2026-01-31"], client: client(host, account: account))
        let saved = try await session.sales(accountId: account.id, appId: "1000000001")
        #expect(saved.first { $0.beginDate == "2026-01-31" }?.noSales != true)
    }

    @Test func reporterAnswersMapToReportsNoSalesAndUnavailableDays() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        try await connect(session, #"{"vendorNumber":"80000001","reporter":{"accountNumber":"1234567","vendorNumber":"80000001","credentialId":"00000000-0000-4000-8000-000000000099","connectedAt":"2026-01-01T00:00:00.000Z"}}"#)
        let api = "reporter-api.appstoreconnect.test", reporterHost = "reporter.reporting.test"
        StubProtocol.handle(api) { _ in (200, [:], try! JSONSerialization.data(withJSONObject: ["data": [], "links": [:]])) }
        StubProtocol.handle(reporterHost) { request in
            let body = String(data: request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            } ?? Data(), encoding: .utf8) ?? ""
            let form = URLComponents(string: "?" + body)?.queryItems?.first { $0.name == "jsonRequest" }?.value ?? ""
            let json = try! JSONSerialization.jsonObject(with: Data(form.utf8)) as! [String: String]
            #expect(json["accesstoken"] == "synthetic-reporter-token-0001" && json["account"] == "1234567" && json["mode"] == "Robot.XML" && json["version"] == "2.2")
            let query = json["queryInput"]!
            if query.hasSuffix("20260210]") { return (200, ["Content-Type": "application/a-gzip"], Self.report([["APPLE", "SYNTHETIC", "1000000001", "1F", "4", "0.99", "02/10/2026", "02/10/2026", "DE", ""]])) }
            if query.hasSuffix("20260211]") { return (200, ["Content-Type": "text/xml"], Data("<Error><Code>213</Code><Message>There are no reports available.</Message></Error>".utf8)) }
            return (200, ["Content-Type": "text/xml"], Data("<Error><Code>210</Code><Message>Report not available yet.</Message></Error>".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let base = try #require(try await session.reporterClient(accountId: account.id))
        let reporter = try ReporterClient(token: base.token, origin: URL(string: "https://\(reporterHost)")!, configuration: configuration, selection: base.selection)
        let result = try await session.downloadSales(account: account, appId: "1000000001", days: ["2026-02-10", "2026-02-11", "2026-02-12"], client: client(api, account: account), reporter: reporter)
        #expect(result.noSalesDays == ["2026-02-11"] && result.unavailableDays == ["2026-02-12"])
        let saved = try await session.sales(accountId: account.id, appId: "1000000001")
        #expect(saved.contains { $0.beginDate == "2026-02-10" } && saved.contains { $0.beginDate == "2026-02-11" && $0.noSales == true })
        // The Reporter token stays in the request body, never in the URL.
        #expect(StubProtocol.requests(reporterHost).allSatisfy { !($0.url!.absoluteString.contains("synthetic-reporter-token")) })
    }

    @Test func accountChangesAfterDownloadCannotSaveReportsOrExplicitNoSales() async throws {
        for operation in ["remove-app", "replace-key", "no-sales"] {
            let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), host = "sales-late-\(operation).example.test"
            try await connect(session, #"{"vendorNumber":"80000001"}"#)
            let reader = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
            let before = try reader.documents(namespace: "sales_index") + reader.documents(namespace: "sales_part")
            StubProtocol.handle(host) { request in
                if request.url?.path != "/v1/salesReports" { return (200, [:], Data(#"{"data":[],"links":{}}"#.utf8)) }
                let changed = Account(id: account.id, name: account.name, keyId: operation == "replace-key" ? "SAMPLE0002" : account.keyId, keyType: account.keyType,
                                      issuerId: account.issuerId, appIds: operation == "replace-key" ? account.appIds : [], appNames: nil)
                try! reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] }
                return (200, [:], Self.report([["APPLE", "SYNTHETIC", operation == "no-sales" ? "1000000099" : "1000000001", "1F", "3", ".99", "02/10/2026", "02/10/2026", "US", ""]]))
            }
            if operation == "replace-key" {
                await #expect(throws: AccountFailure.stale) { try await session.downloadSales(account: account, appId: "1000000001", days: ["2026-02-10"], client: client(host, account: account)) }
            } else {
                await #expect(throws: SalesFileFailure.scope) { try await session.downloadSales(account: account, appId: "1000000001", days: ["2026-02-10"], client: client(host, account: account)) }
            }
            #expect(try reader.documents(namespace: "sales_index") + reader.documents(namespace: "sales_part") == before)
        }
    }

    @Test func cancellationBeforeCatalogAndScopeChangesDuringCatalogCannotStartReportDownloads() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "sales-catalog-scope.example.test"
        try await connect(session, #"{"vendorNumber":"80000001"}"#)
        let reader = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let before = try reader.documents(namespace: "sales_index") + reader.documents(namespace: "sales_part"), client = try client(host, account: account)
        StubProtocol.handle(host) { _ in (200, [:], Data(#"{"data":[],"links":{}}"#.utf8)) }
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await session.downloadSales(account: account, appId: "1000000001", days: ["2026-02-10"], client: client) }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(StubProtocol.requests(host).isEmpty)
        StubProtocol.handle(host) { _ in
            let changed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
            try! reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] }
            return (200, [:], Data(#"{"data":[],"links":{}}"#.utf8))
        }
        await #expect(throws: SalesFileFailure.scope) { try await session.downloadSales(account: account, appId: "1000000001", days: ["2026-02-10"], client: client) }
        #expect(!StubProtocol.requests(host).contains { $0.url?.path == "/v1/salesReports" })
        #expect(try reader.documents(namespace: "sales_index") + reader.documents(namespace: "sales_part") == before)
    }
}

@Suite(.serialized) struct SalesSyncProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func waitingScopeChangePreservesHistoryAndPermanentMutex() async throws { try await run("scope") }
    @Test func waitingCancellationPreservesHistoryAndPermanentMutex() async throws { try await run("cancel") }
    func run(_ operation: String) async throws {
        let root = try TestIsolation.require().appendingPathComponent("sales-sync-\(operation)-lock-policy"), fixtures = try SalesSyncTests()
        let (session, _) = try fixtures.session(directory: root), account = try #require(try await session.accounts().first), appId = "1000000001"
        try await fixtures.connect(session, #"{"vendorNumber":"80000001"}"#)
        let mutex = root.appendingPathComponent("state-v2/sales-\(JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(32)).mutex")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path))
        #expect(try FileMutex.tryLock(mutex) == nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        let reader = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let before = try reader.documents(namespace: "sales_index") + reader.documents(namespace: "sales_part"), accountDocument = try #require(try reader.document(namespace: "accounts", key: "all"))
        let host = "sales-sync-\(operation)-process.example.test", ready = root.appendingPathComponent("report-ready")
        StubProtocol.handle(host) { request in
            if request.url?.path != "/v1/salesReports" { return (200, [:], Data(#"{"data":[],"links":{}}"#.utf8)) }
            try! JobLock.exclusive(ready, "synthetic-report-ready")
            return (200, [:], SalesSyncTests.report([["APPLE", "SYNTHETIC", appId, "1F", "3", ".99", "02/10/2026", "02/10/2026", "US", ""]]))
        }
        let client = try fixtures.client(host, account: account), pending = Task { try await session.downloadSales(account: account, appId: appId, days: ["2026-02-10"], client: client) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try reader.documents(namespace: "sales_index") + reader.documents(namespace: "sales_part") == before)
        if operation == "cancel" { pending.cancel() }
        else {
            let changed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
            try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] }
        }
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        if operation == "cancel" { await #expect(throws: CancellationError.self) { try await pending.value } }
        else { await #expect(throws: SalesFileFailure.scope) { try await pending.value } }
        #expect(try reader.documents(namespace: "sales_index") + reader.documents(namespace: "sales_part") == before)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: accountDocument.payload)] }
        // A fresh request can save after the interrupted owned process; the old request never commits.
        StubProtocol.handle(host) { request in
            request.url?.path == "/v1/salesReports" ? (200, [:], SalesSyncTests.report([["APPLE", "SYNTHETIC", appId, "1F", "3", ".99", "02/10/2026", "02/10/2026", "US", ""]])) : (200, [:], Data(#"{"data":[],"links":{}}"#.utf8))
        }
        let fresh = try await session.downloadSales(account: account, appId: appId, days: ["2026-02-10"], client: client)
        #expect(fresh.changes.added == 1)
        try await session.verifyBuckets(family: "sales", accountId: account.id, appId: appId)
    }
}

@Suite struct SyncFreshnessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func catchUpMatchesSyntheticReferenceResults() {
        // No saved days: the chosen reach. A gap after the earliest saved day: reach back to it. Otherwise the weekly minimum.
        #expect(SyncFreshness.catchUpDays(saved: [], end: "2026-03-31", first: 30) == 30)
        let saved = SyncFreshness.savedSalesDays([("2026-03-01", "2026-03-20"), ("2026-03-22", "2026-03-31")], end: "2026-03-31")
        #expect(SyncFreshness.catchUpDays(saved: saved, end: "2026-03-31", first: 30, maximum: 30) == 11)
        let full = SyncFreshness.savedSalesDays([("2026-03-01", "2026-03-31")], end: "2026-03-31")
        #expect(SyncFreshness.catchUpDays(saved: full, end: "2026-03-31", first: 30, maximum: 30) == 7)
        #expect(SalesReports.days(ending: "2026-03-02", count: 3) == ["2026-02-28", "2026-03-01", "2026-03-02"])
    }
}
