import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AnalyticsSyncTests {
    init() throws { _ = try TestIsolation.require() }
    struct Part: Decodable { let items: [AnalyticsPartition] }

    func session() throws -> (WorkspaceSession, URL) {
        let root = (try TestIsolation.require()).appendingPathComponent("storebench-analytics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: try SyntheticFixtures.database(), to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = #"{\"schemaVersion\":1,\"phase\":\"ready\",\"envelope\":{\"version\":1,\"mode\":\"device\",\"key\":\"\#(key)\"}}"#
        let vault = try CredentialVault(json: Data(#"{"version":1,"entries":{"\#(CredentialVault.databaseEntry(root: root))":"\#(record)"}}"#.utf8))
        return (try WorkspaceSession(workspace: Workspace(root: root), vault: vault), root)
    }

    @Test func importAndViewsMatchSyntheticReferenceResults() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let parts = try await session.storeAccess { try $0.documents(namespace: "analytics_part", prefix: "\(account.id):1000000001:") }
        let views = try await session.storeAccess { try $0.documents(namespace: "analytics_view", prefix: "\(account.id):1000000001:") }
        #expect(!parts.isEmpty && parts.count == views.count)
        for part in parts {
            let text = try #require(String(data: part.payload, encoding: .utf8))
            let items = try JSONDecoder().decode(Part.self, from: part.payload).items
            // Re-importing each saved period's rows yields the same stored JSON, so fingerprints stay stable.
            for item in items {
                let meta = try AnalyticsMetadata(kind: item.kind, level: item.level, granularity: item.granularity, processingDate: item.processingDate)
                let again = try AnalyticsReports.importSegments([item.source], meta: meta, accountId: account.id, appId: "1000000001", importedAt: item.importedAt)
                #expect(again.count == 1 && again[0].source == item.source)
            }
            #expect(text.contains(#""items":"# + JSONText.array(items.map(\.json)).stringify() + "}"))
            let view = try #require(views.first { $0.key == part.key })
            let fingerprint = JSONText.array(items.map(\.json)).sha256
            #expect(String(data: view.payload, encoding: .utf8) == JSONText.object([("version", .number(1)), ("fingerprint", .string(fingerprint)), ("views", try AnalyticsReports.view(items))]).stringify())
        }
    }

    @Test func missingViewsAreSummarizedFromSavedRows() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let prepared = try await session.analytics(accountId: account.id, appId: "1000000001")
        try await session.storeAccess { store in
            for view in try store.documents(namespace: "analytics_view", prefix: "\(account.id):") { try store.delete(namespace: "analytics_view", key: view.key) }
        }
        let rebuilt = try await session.analytics(accountId: account.id, appId: "1000000001")
        #expect(rebuilt.map(\.key) == prepared.map(\.key) && rebuilt.map { $0.total("first") } == prepared.map { $0.total("first") })
    }

    @Test func tablesParseTabsAndCSVAndMatchExpectedSortOrder() throws {
        let tsv = try ReportTables.parse("\u{FEFF}b\ta\r\n2\t\"1\"\r\n\r\n")
        #expect(tsv == ReportTable(columns: ["b", "a"], rows: [["2", "\"1\""]]))
        let csv = try ReportTables.parse("Name,Note\r\n\"Quoted, \"\"name\"\"\",'=SUM(1)\n")
        #expect(csv == ReportTable(columns: ["Name", "Note"], rows: [["Quoted, \"name\"", "=SUM(1)"]]))
        #expect(throws: AnalyticsFailure.format) { try ReportTables.parse("a,b\n\"open,1\n") }
        let canonical = ReportTables.canonical(ReportTable(columns: ["Source Type", "App Name", "Pre-Order", "Page Type"], rows: [["b", "x", "No", "z"], ["a", "x", "No", "z"]]))
        #expect(canonical.columns == ["App Name", "Page Type", "Pre-Order", "Source Type"])
        #expect(canonical.rows == [["x", "z", "No", "a"], ["x", "z", "No", "b"]])
        #expect(AnalyticsReports.periodEnd("2024-02-01", granularity: "MONTHLY") == "2024-02-29" && AnalyticsReports.periodEnd("2026-03-02", granularity: "WEEKLY") == "2026-03-08")
    }

    static let columns = ["Date", "App Name", "App Apple Identifier", "Download Type", "App Version", "Device", "Platform Version", "Source Type", "Page Type", "Pre-Order", "Territory", "Counts"]
    static func segment(_ rows: [[String]]) -> Data { gzip(([columns] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n") }

    @Test func reportTransportBoundsActualBytesAndRejectsUntrustedDestinationsBeforeReading() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "synthetic-bounded.s3.amazonaws.com"
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FeedbackStreamStubProtocol.self]
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://analytics-bounded.appstoreconnect.test")!, configuration: configuration)
        let url = URL(string: "https://\(host)/reports/synthetic.gz")!
        await #expect(throws: AnalyticsFailure.integrity) { try await client.segment(url, size: 8, checksum: String(repeating: "0", count: 32)) }
        #expect(FeedbackStreamStubProtocol.lock.withLock { FeedbackStreamStubProtocol.sent[host, default: 0] } < 32)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]; config.httpAdditionalHeaders = ["Authorization": "synthetic-only", "Cookie": "synthetic-only"]
        let plain = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://analytics-bounded.appstoreconnect.test")!, configuration: config)
        let bytes = Data("Synthetic report bytes".utf8), checksum = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        StubProtocol.handle(host) { request in #expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil); return (200, [:], bytes) }
        #expect(try await plain.segment(url, size: bytes.count, checksum: checksum) == bytes)
        let count = StubProtocol.requests(host).count
        await #expect(throws: AnalyticsFailure.integrity) { try await plain.segment(URL(string: "https://example.invalid/reports/synthetic.gz")!, size: bytes.count, checksum: checksum) }
        await #expect(throws: AnalyticsFailure.integrity) { try await plain.segment(url, size: 0, checksum: checksum) }
        await #expect(throws: AnalyticsFailure.integrity) { try await plain.segment(url, size: bytes.count, checksum: "synthetic-invalid") }
        #expect(StubProtocol.requests(host).count == count)
    }

    @Test func explicitRequestDetailedWeeklyReportsAndFinalAccountScopeAreValidated() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), fixture = try AnalyticsFileTests()
        let incoming = try AnalyticsFileFormats.parse(fixture.input("weekly"), accountId: account.id, appId: "1000000001", now: fixture.now)
        let bytes = try AnalyticsFileFormats.source(incoming.partitions[0], format: .sourceGzip)
        let checksum = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let api = "analytics-selected.appstoreconnect.test", storage = "synthetic-selected.s3.amazonaws.com"
        func page(_ data: [[String: Any]]) -> (Int, [String: String], Data) { (200, [:], try! JSONSerialization.data(withJSONObject: ["data": data, "links": [:]])) }
        StubProtocol.handle(api) { request in
            #expect(request.httpMethod == "GET")
            switch request.url!.path {
            case "/v1/apps/1000000001/analyticsReportRequests": return page([
                ["type": "analyticsReportRequests", "id": "synthetic-ongoing", "attributes": ["accessType": "ONGOING"]],
                ["type": "analyticsReportRequests", "id": "synthetic-snapshot", "attributes": ["accessType": "ONE_TIME_SNAPSHOT"]]])
            case "/v1/analyticsReportRequests/synthetic-snapshot/reports": return page([["type": "analyticsReports", "id": "synthetic-detailed", "attributes": ["name": "App Downloads Detailed"]]])
            case "/v1/analyticsReports/synthetic-detailed/instances":
                #expect(request.url!.query?.contains("filter%5Bgranularity%5D=WEEKLY") == true)
                return page([["type": "analyticsReportInstances", "id": "synthetic-week", "attributes": ["processingDate": "2026-02-11", "granularity": "WEEKLY"]]])
            case "/v1/analyticsReportInstances/synthetic-week/segments": return page([["type": "analyticsReportSegments", "id": "synthetic-segment", "attributes": ["sizeInBytes": bytes.count, "checksum": checksum, "url": "https://\(storage)/reports/synthetic.gz"]]])
            default: Issue.record("Unexpected selected-report route"); return (404, [:], Data())
            }
        }
        StubProtocol.handle(storage) { request in #expect(request.value(forHTTPHeaderField: "Authorization") == nil); return (200, [:], bytes) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(api)")!, configuration: configuration)
        let result = try await session.downloadAnalytics(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-02-11"], client: client, level: "detailed", granularity: "WEEKLY", requestId: "synthetic-snapshot")
        #expect(result.changes.added == 1 && result.instances == 1)
        let saved = try await session.savedAnalyticsFiles(account: account, appId: "1000000001")
        #expect(saved.partitions.contains { $0.key == "downloads:detailed:WEEKLY:2026-02-02" })
        await #expect(throws: AnalyticsFailure.access) { try await session.downloadAnalytics(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-02-11"], client: client, level: "detailed", granularity: "WEEKLY", requestId: "synthetic-unknown") }
        let reader = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let original = try #require(try reader.document(namespace: "accounts", key: "all"))
        StubProtocol.handle(storage) { _ in
            let removed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
            try! reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(removed)]).data)] }
            return (200, [:], bytes)
        }
        await #expect(throws: AnalyticsFailure.scope) { try await session.downloadAnalytics(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-02-11"], client: client, level: "detailed", granularity: "WEEKLY", requestId: "synthetic-snapshot") }
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: original.payload)] }
        #expect(try await session.savedAnalyticsFiles(account: account, appId: "1000000001").partitions.map(\.json) == saved.partitions.map(\.json))
        try await session.verifyBuckets(family: "analytics", accountId: account.id, appId: "1000000001")
    }

    @Test func downloadsVerifiedSegmentsAndSavesPartitionsWithViews() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let first = Self.segment([
            ["2026-03-04", "Sample App", "1000000001", "First-time Download", "1.0", "iPhone", "iOS 19", "App Store Search", "Store sheet", "No", "SE", "7"],
            ["2026-03-04", "Other App", "1000000099", "First-time Download", "1.0", "iPhone", "iOS 19", "App Store Search", "Store sheet", "No", "SE", "70"],
        ])
        let second = Self.segment([["2026-03-04", "Sample App", "1000000001", "Redownload", "1.0", "iPad", "iPadOS 19", "Web referrer", "No page", "No", "US", "2"]])
        let md5 = { (data: Data) in Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let api = "analytics.appstoreconnect.test", storage = "synthetic-reports.s3.amazonaws.com"
        func page(_ data: [[String: Any]]) -> (Int, [String: String], Data) { (200, [:], try! JSONSerialization.data(withJSONObject: ["data": data, "links": [:]])) }
        StubProtocol.handle(api) { request in
            let path = request.url!.path
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            switch path {
            case "/v1/apps/1000000001/analyticsReportRequests": return page([["type": "analyticsReportRequests", "id": "req-snapshot", "attributes": ["accessType": "ONE_TIME_SNAPSHOT", "stoppedDueToInactivity": false]],
                                                                         ["type": "analyticsReportRequests", "id": "req-ongoing", "attributes": ["accessType": "ONGOING", "stoppedDueToInactivity": false]]])
            case "/v1/analyticsReportRequests/req-ongoing/reports": return page([["type": "analyticsReports", "id": "rep-1", "attributes": ["name": "App Downloads Standard", "category": "COMMERCE"]],
                                                                             ["type": "analyticsReports", "id": "rep-2", "attributes": ["name": "App Store Discovery and Engagement Standard"]]])
            case "/v1/analyticsReportRequests/req-snapshot/reports": return page([])
            case "/v1/analyticsReports/rep-1/instances":
                #expect(request.url!.query?.contains("filter%5Bgranularity%5D=DAILY") == true)
                return page([["type": "analyticsReportInstances", "id": "inst-5", "attributes": ["processingDate": "2026-03-05", "granularity": "DAILY"]],
                             ["type": "analyticsReportInstances", "id": "inst-1", "attributes": ["processingDate": "2026-01-01", "granularity": "DAILY"]]])
            case "/v1/analyticsReportInstances/inst-5/segments": return page([
                ["type": "analyticsReportSegments", "id": "seg-1", "attributes": ["sizeInBytes": first.count, "checksum": md5(first), "url": "https://\(storage)/reports/seg-1?X-Amz-Signature=synthetic"]],
                ["type": "analyticsReportSegments", "id": "seg-2", "attributes": ["sizeInBytes": second.count, "checksum": md5(second).uppercased(), "url": "https://\(storage)/reports/seg-2?X-Amz-Signature=synthetic"]]])
            default: Issue.record("Unexpected request \(path)"); return (404, [:], Data())
            }
        }
        StubProtocol.handle(storage) { request in
            // Report files never receive the App Store Connect token.
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, ["Content-Type": "application/octet-stream"], request.url!.path.hasSuffix("seg-1") ? first : second)
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(api)")!, configuration: configuration)
        let result = try await session.downloadAnalytics(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-03-05", "2026-03-06"], client: client)
        #expect(result.instances == 1 && result.changes.added == 1 && result.noAppInstances == 0)
        #expect(result.unavailableDays == ["2026-03-06"] && AppSync.analyticsStatus(result).state == .partial)
        #expect(StubProtocol.requests(storage).count == 2)

        let periods = try await session.analytics(accountId: account.id, appId: "1000000001")
        let saved = try #require(periods.first { $0.key == "downloads:standard:DAILY:2026-03-04" })
        #expect(saved.processingDate == "2026-03-05" && saved.total("first") == 7 && saved.total("redownload") == 2)
        #expect(saved.facts.contains { $0.territory == "SWE" && $0.source == "App Store Search" && $0.device == "iPhone" })
        // Earlier saved periods stay, and every bucket matches its index fingerprint.
        #expect(periods.count > 1)
        try await session.verifyBuckets(family: "analytics", accountId: account.id, appId: "1000000001")

        // A changed checksum is refused before anything is saved.
        StubProtocol.handle(storage) { _ in (200, [:], Data("tampered".utf8)) }
        await #expect(throws: AnalyticsFailure.integrity) { try await session.downloadAnalytics(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-03-05"], client: client) }
        // Processing dates outside the period are reported, never saved as zero activity.
        await #expect(throws: AnalyticsFailure.period) { try await session.downloadAnalytics(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-02-01"], client: client) }
    }
}
