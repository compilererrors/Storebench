import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AnalyticsCatalogTests {
    init() throws { _ = try TestIsolation.require() }
    func list(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw AnalyticsFailure.integrity }; return values }
    func vector() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/analytics-catalog.json"))) }
    func client(_ host: String, account: Account) throws -> AppStoreConnectClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: config)
    }
    func rows(_ text: JSONText) throws -> [AppStoreConnectClient.Resource] { try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: text.data) }
    static func page(_ data: [[String: Any]]) -> (Int, [String: String], Data) { (200, [:], try! JSONSerialization.data(withJSONObject: ["data": data, "links": [:]])) }
    static func request(_ id: String = "synthetic-request", stopped: Bool = false, access: String = "ONGOING") -> [String: Any] {
        ["type": "analyticsReportRequests", "id": id, "attributes": ["accessType": access, "stoppedDueToInactivity": stopped]]
    }
    static func report(_ id: String = "synthetic-report", name: String = "App Downloads Standard") -> [String: Any] {
        ["type": "analyticsReports", "id": id, "attributes": ["name": name]]
    }
    static func instance(_ id: String = "synthetic-instance", date: String = "2026-02-11", granularity: String = "DAILY") -> [String: Any] {
        ["type": "analyticsReportInstances", "id": id, "attributes": ["processingDate": date, "granularity": granularity]]
    }

    @Test func catalogAndMetadataContractsMatchWebValidation() throws {
        let fixture = try vector()
        for item in try list(fixture["catalogs"]) {
            let input = try #require(item["input"])
            if item["rejected"] == .bool(true) { #expect(throws: AnalyticsFailure.integrity) { try AnalyticsCatalog(json: input) } }
            else { #expect(try AnalyticsCatalog(json: input).json == item["expected"]) }
        }
        for item in try list(fixture["requestRows"]) {
            let input = try rows(#require(item["input"]))
            if item["rejected"] == .bool(true) { #expect(throws: AnalyticsFailure.download) { try AnalyticsCatalog.requests(input) } }
            else { #expect(JSONText.array(try AnalyticsCatalog.requests(input).map(\.json)) == item["expected"]) }
        }
        for item in try list(fixture["instanceRows"]) {
            let row = try rows(.array([#require(item["input"])])), unit = try #require(item["input"]?["attributes"]?["granularity"]?.text)
            if item["rejected"] == .bool(true) { #expect(throws: AnalyticsFailure.download) { try AnalyticsCatalog.instances(row, granularity: unit) } }
            else {
                let instance = try #require(AnalyticsCatalog.instances(row, granularity: unit).first)
                #expect(instance.id == item["expected"]?["id"]?.text && instance.processingDate == item["expected"]?["processingDate"]?.text)
            }
        }
    }

    @Test func overviewStatusKeepsUnattributedAndMissingReportsPartial() throws {
        let fixture = try vector()
        for item in try list(fixture["analyticsStates"]) {
            guard case .number(let raw)? = item["noAppInstances"], let count = Int(exactly: raw) else { throw AnalyticsFailure.integrity }
            let result = AnalyticsSyncResult(instances: 3, noAppInstances: count)
            #expect(AppSync.analyticsStatus(result).state.rawValue == item["state"]?.text)
            var incomplete = result; incomplete.unavailableDays = ["2026-02-10"]
            #expect(AppSync.analyticsStatus(incomplete).state == .partial)
            #expect(AppSync.analyticsStatus(incomplete).detail.contains("1 requested processing days not available"))
        }
        for item in try list(fixture["salesStates"]) {
            let result = SalesSyncResult(unavailableDays: item["unavailable"] == .number(1) ? ["2026-02-10"] : [],
                noAppRowsDays: item["unattributed"] == .number(1) ? ["2026-02-11"] : [], noSalesDays: item["noSales"] == .number(1) ? ["2026-02-12"] : [])
            #expect(AppSync.salesStatus(result).state.rawValue == item["state"]?.text)
        }
    }

    @Test func discoveryRanksRequestsAndExplicitChoicesNeverFallBackOrDownloadFiles() async throws {
        let (session, root) = try AnalyticsSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "analytics-catalog-selection.appstoreconnect.test"
        let api = try client(host, account: account)
        let before = try await session.storeAccess { store in try store.documents(namespace: "jobs") + store.documents(namespace: "analytics_index") + store.documents(namespace: "analytics_part") }
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "GET")
            switch request.url!.path {
            case "/v1/apps/1000000001/analyticsReportRequests": return Self.page([Self.request("synthetic-stopped", stopped: true), Self.request("synthetic-snapshot", access: "ONE_TIME_SNAPSHOT"), Self.request("synthetic-ongoing")])
            case "/v1/analyticsReportRequests/synthetic-ongoing/reports": return Self.page([Self.report("synthetic-ongoing-report")])
            case "/v1/analyticsReports/synthetic-ongoing-report/instances": return Self.page([Self.instance(date: "2026-03-01")])
            case "/v1/analyticsReportRequests/synthetic-snapshot/reports": return Self.page([Self.report("synthetic-snapshot-report", name: "App Store Downloads")])
            case "/v1/analyticsReports/synthetic-snapshot-report/instances": return Self.page([Self.instance("synthetic-match"), Self.instance("synthetic-latest", date: "2026-02-12")])
            default: Issue.record("Unexpected catalog route"); return (404, [:], Data())
            }
        }
        let catalog = try await session.availableAnalyticsCatalog(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-02-11"], client: api)
        #expect(catalog.availability.matchingInstances == 1 && catalog.availability.requestId == "synthetic-snapshot" && catalog.availability.latestProcessingDate == "2026-02-12")
        #expect(catalog.requests.map(\.id) == ["synthetic-stopped", "synthetic-snapshot", "synthetic-ongoing"])
        #expect(StubProtocol.requests(host).map { $0.url!.path }.dropFirst().first == "/v1/analyticsReportRequests/synthetic-ongoing/reports")
        let selected = try await session.availableAnalyticsCatalog(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-02-11"], client: api, requestId: "synthetic-ongoing")
        #expect(selected.availability.failure == .period && selected.availability.requestId == "synthetic-ongoing" && selected.availability.latestProcessingDate == "2026-03-01")
        let count = StubProtocol.requests(host).count
        await #expect(throws: AnalyticsFailure.access) { try await session.availableAnalyticsCatalog(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-02-11"], client: api, requestId: "synthetic-foreign") }
        #expect(StubProtocol.requests(host).count == count + 1)
        let after = try await session.storeAccess { store in try store.documents(namespace: "jobs") + store.documents(namespace: "analytics_index") + store.documents(namespace: "analytics_part") }
        #expect(after == before)
        #expect(StubProtocol.requests(host).allSatisfy { !$0.url!.path.contains("segments") })
    }

    @Test func allAvailabilityGuidanceStatesKeepSavedHistory() async throws {
        let (session, root) = try AnalyticsSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        for failure in [AnalyticsFailure.setup, .inactive, .reportMissing, .noInstances, .period] {
            let host = "analytics-catalog-\(AnalyticsCatalog.code(failure)!.lowercased()).appstoreconnect.test", api = try client(host, account: account)
            StubProtocol.handle(host) { request in
                switch request.url!.path {
                case "/v1/apps/1000000001/analyticsReportRequests": return Self.page(failure == .setup ? [] : [Self.request(stopped: failure == .inactive)])
                case "/v1/analyticsReportRequests/synthetic-request/reports": return Self.page(failure == .reportMissing ? [] : [Self.report()])
                case "/v1/analyticsReports/synthetic-report/instances": return Self.page(failure == .period ? [Self.instance(date: "2026-02-01")] : [])
                default: Issue.record("Unexpected availability route"); return (404, [:], Data())
                }
            }
            let catalog = try await session.availableAnalyticsCatalog(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-02-11"], client: api)
            #expect(catalog.availability.failure == failure && catalog.availability.matchingInstances == 0)
            #expect(catalog.availability.needsSetup == (failure == .setup || failure == .inactive))
            #expect(catalog.availability.latestProcessingDate == (failure == .period ? "2026-02-01" : nil))
        }
    }

    @Test func malformedMetadataAndDuplicateAliasesFailClosed() async throws {
        let (session, root) = try AnalyticsSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        for scenario in ["request-duplicate", "report-aliases", "instance-duplicate", "processing-duplicate", "foreign-unit-invalid"] {
            let host = "analytics-catalog-\(scenario).appstoreconnect.test", api = try client(host, account: account)
            StubProtocol.handle(host) { request in
                switch request.url!.path {
                case "/v1/apps/1000000001/analyticsReportRequests": return Self.page(scenario == "request-duplicate" ? [Self.request(), Self.request()] : [Self.request()])
                case "/v1/analyticsReportRequests/synthetic-request/reports": return Self.page(scenario == "report-aliases" ? [Self.report(), Self.report("synthetic-alias", name: "App Store Downloads Standard")] : [Self.report()])
                case "/v1/analyticsReports/synthetic-report/instances":
                    return Self.page(scenario == "foreign-unit-invalid" ? [Self.instance(granularity: "WEEKLY"), Self.instance("synthetic-invalid", date: "2026-02-30", granularity: "MONTHLY")]
                        : [Self.instance(), Self.instance(scenario == "instance-duplicate" ? "synthetic-instance" : "synthetic-other")])
                default: Issue.record("Unexpected malformed catalog route"); return (404, [:], Data())
                }
            }
            await #expect(throws: scenario == "foreign-unit-invalid" ? AnalyticsFailure.download : .integrity) {
                try await session.availableAnalyticsCatalog(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-02-11"], client: api)
            }
        }
    }

    @Test func canceledAndInvalidSelectionsCannotStartAndLateAccountChangesStopDiscovery() async throws {
        let (session, root) = try AnalyticsSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "analytics-catalog-cancellation.appstoreconnect.test", api = try client(host, account: account)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.availableAnalyticsCatalog(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-02-11"], client: api)
        }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        for days in [[], ["2026-02-11", "2026-02-11"], ["2026-02-30"], ["9999-12-31"]] {
            await #expect(throws: AnalyticsFailure.access) { try await session.availableAnalyticsCatalog(account: account, appId: "1000000001", kind: "downloads", processingDays: days, client: api) }
        }
        #expect(StubProtocol.requests(host).isEmpty)
        let reader = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let original = try #require(try reader.document(namespace: "accounts", key: "all"))
        for stage in ["requests", "instances", "key"] {
            let scopedHost = "analytics-catalog-scope-\(stage).appstoreconnect.test", scopedAPI = try client(scopedHost, account: account)
            StubProtocol.handle(scopedHost) { request in
                let path = request.url!.path
                if (stage != "instances" && path.hasSuffix("analyticsReportRequests")) || (stage == "instances" && path.hasSuffix("instances")) {
                    let replacement = Account(id: account.id, name: account.name, keyId: stage == "key" ? "SAMPLE0002" : account.keyId,
                        keyType: account.keyType, issuerId: account.issuerId, appIds: stage == "key" ? account.appIds : [], appNames: nil)
                    try! reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(replacement)]).data)] }
                }
                if path.hasSuffix("analyticsReportRequests") { return Self.page([Self.request()]) }
                if path.hasSuffix("reports") { return Self.page([Self.report()]) }
                if path.hasSuffix("instances") { return Self.page([Self.instance()]) }
                Issue.record("Unexpected scope catalog route"); return (404, [:], Data())
            }
            do { _ = try await session.availableAnalyticsCatalog(account: account, appId: "1000000001", kind: "downloads", processingDays: ["2026-02-11"], client: scopedAPI); Issue.record("Changed account must reject availability") }
            catch { if stage == "key" { #expect(error as? AccountFailure == .stale) } else { #expect(error as? AnalyticsFailure == .scope) } }
            #expect(StubProtocol.requests(scopedHost).count == (stage == "instances" ? 3 : 1))
            try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: original.payload)] }
        }
    }

    @Test func canceledOverviewNeverStartsASourceOrClaimsACheckedTimestamp() async throws {
        let (session, root) = try AnalyticsSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return await session.syncApp(account: account, appId: "1000000001") }
        let items = await task.value
        #expect(items.count == 7 && items.allSatisfy { $0.state == .attention && $0.checkedAt == nil })
        #expect(try await session.storeAccess { try $0.document(namespace: "jobs", key: "import:\(account.id):1000000001") } == nil)
    }
}
