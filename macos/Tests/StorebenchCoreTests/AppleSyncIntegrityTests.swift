import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AppleSyncIntegrityTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"

    @Test func resourceIdentifiersMustMatchTheWholeValue() {
        #expect(ProductPricing.opaque("synthetic-resource_1"))
        for value in ["synthetic\n", "synthetic\r", "synthetic\r\n", "synthetic\u{2028}", "synthetic/other"] {
            #expect(!ProductPricing.opaque(value))
        }
    }

    func resource(_ type: String, _ id: String, parent: (String, String, String)? = nil) -> [String: Any] {
        var value: [String: Any] = ["type": type, "id": id]
        if let parent { value["relationships"] = [parent.0: ["data": ["type": parent.1, "id": parent.2]]] }
        return value
    }

    @Test func invalidProductCatalogsCannotEstablishADayWithoutSales() async throws {
        for scenario in 0..<7 {
            let (session, root) = try SalesSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), host = "catalog-integrity-\(scenario).appstoreconnect.test"
            try await SalesSyncTests().connect(session, #"{"vendorNumber":"80000001"}"#)
            StubProtocol.handle(host) { request in
                let rows: [[String: Any]]
                switch request.url!.path {
                case "/v1/apps/1000000001/inAppPurchasesV2":
                    switch scenario {
                    case 0: rows = [resource("apps", "6000000001")]
                    case 1: rows = [resource("inAppPurchases", "6000000001", parent: ("app", "apps", "1000000099"))]
                    case 2: rows = [resource("inAppPurchases", "6000000001"), resource("inAppPurchases", "6000000001")]
                    default: rows = []
                    }
                case "/v1/apps/1000000001/subscriptionGroups":
                    rows = scenario == 3 ? [resource("apps", "group-synthetic")] : scenario >= 4 ? [resource("subscriptionGroups", "group-synthetic")] : []
                case "/v1/subscriptionGroups/group-synthetic/subscriptions":
                    if scenario == 4 { rows = [resource("inAppPurchases", "7000000001")] }
                    else if scenario == 5 { rows = [resource("subscriptions", "7000000001", parent: ("group", "subscriptionGroups", "group-foreign"))] }
                    else { rows = [resource("subscriptions", "7000000001", parent: ("group", "subscriptionGroups", "group-synthetic"))] }
                case "/v1/salesReports":
                    return (200, ["Content-Type": "application/a-gzip"], SalesSyncTests.report([["APPLE", "OTHER", "1000000099", "1F", "1", "0.99", "02/10/2026", "02/10/2026", "US", ""]]))
                default: Issue.record("Unexpected synthetic catalog route"); return (404, [:], Data())
                }
                return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": rows, "links": [:]]))
            }
            let client = try SalesSyncTests().client(host, account: account)
            let result = try await session.downloadSales(account: account, appId: app, days: ["2026-02-10"], client: client)
            let saved = try await session.sales(accountId: account.id, appId: app).first { $0.beginDate == "2026-02-10" }
            if scenario == 6 {
                #expect(result.noSalesDays == ["2026-02-10"] && saved?.noSales == true)
            } else {
                #expect(result.noSalesDays.isEmpty && result.noAppRowsDays == ["2026-02-10"])
                #expect(saved == nil)
            }
        }
    }

    @Test func financeStopsWhenTheReportingChoiceChangesDuringAResponse() async throws {
        for reporter in [false, true] {
            let (session, account, root) = try await FinanceSyncTests().session(reporter: reporter)
            defer { try? FileManager.default.removeItem(at: root) }
            let host = "finance-choice-\(reporter).reporting.test"
            let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
            StubProtocol.handle(host) { request in
                #expect(request.httpMethod == (reporter ? "POST" : "GET"))
                #expect(request.url!.path == (reporter ? "/reportservice/finance/v1" : "/v1/financeReports"))
                try! FileMutex.withLock(root.appendingPathComponent("state-v2/reporter_" + JSONText.string(account.id).rawSHA256.prefix(32) + ".mutex")) {
                    try store.transaction { _ in [.put(namespace: "sales_connection", key: account.id, json: try SalesSyncTests.connection(#"{"vendorNumber":"90000001"}"#, accountId: account.id).data)] }
                }
                if reporter {
                    return (200, ["Content-Type": "text/xml"], Data("<VendorsAndRegions><Vendor><Number>80000001</Number><Region><Code>US</Code><Reports><Report>Financial</Report></Reports></Region></Vendor></VendorsAndRegions>".utf8))
                }
                return (200, ["Content-Type": "application/a-gzip"], FinanceSyncTests.january)
            }
            let client = try FinanceSyncTests().client(host, account), captured = try await session.reporterClient(accountId: account.id)
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
            let transport = try captured.map { try ReporterClient(token: $0.token, origin: URL(string: "https://\(host)")!, configuration: configuration, selection: $0.selection) }
            await #expect(throws: FinanceFailure.access) {
                try await session.downloadFinancial(account: account, appId: app, region: "ZZ", periods: [.init(year: 2026, period: 4)], client: client, reporter: transport)
            }
            #expect(StubProtocol.requests(host).count == 1)
            #expect(try await session.pendingFinancialDownload(accountId: account.id, appId: app) == nil)
            #expect(try await session.financialReports(accountId: account.id, appId: app).isEmpty)
            #expect(try await session.financialDownloadJob(account: account, appId: app)?.state == .failed)
        }
    }

    @Test func unverifiedWriteRepliesFailAndCannotReplayAnApprovedReview() async throws {
        let good = resource("appStoreVersions", "version-1")
        let replies = [Data(), Data("Synthetic unreadable reply".utf8),
                      try JSONSerialization.data(withJSONObject: ["data": NSNull()]),
                      try JSONSerialization.data(withJSONObject: ["data": []]),
                      try JSONSerialization.data(withJSONObject: ["data": [good]]),
                      try JSONSerialization.data(withJSONObject: ["data": resource("apps", "version-1")]),
                      try JSONSerialization.data(withJSONObject: ["data": resource("appStoreVersions", "version-foreign")]),
                      Data(repeating: 7, count: 4_000_001)]
        for (index, reply) in replies.enumerated() {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "write-reply-\(index).appstoreconnect.test"
            StubProtocol.handle(host) { request in
                let response = apple.handle(request)
                return request.httpMethod == "GET" ? response : (200, ["Content-Type": "application/json"], reply)
            }
            let client = try PublishingTests().client(account, host: host)
            let review = try await session.preparePublishing(account: account, request: .init(accountId: account.id, appId: app, scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio"), client: client)
            #expect(apple.writes.isEmpty)
            let result = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
            #expect(result.state == "failed" && result.steps.count == 1 && result.steps[0].state == "failed")
            #expect(result.steps[0].resultId == nil && apple.writes.count == 1)
            await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
            #expect(apple.writes.count == 1)
        }
    }

    @Test func reporterCancelsOversizedRepliesWhileTheyAreStillArriving() async throws {
        for finance in [false, true] {
            let host = "reporter-stream-\(finance).reporting.test", configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FeedbackStreamStubProtocol.self]
            let reporter = try ReporterClient(token: "synthetic-reporting-token", origin: URL(string: "https://\(host)")!, configuration: configuration)
            await #expect(throws: ReporterClient.Failure.size) {
                if finance { _ = try await reporter.financialReport(account: "1000", vendor: "200000", region: "ZZ", year: 2026, period: 4) }
                else { _ = try await reporter.dailySales(account: "1000", vendor: "200000", day: "2026-02-10") }
            }
            #expect(FeedbackStreamStubProtocol.lock.withLock { FeedbackStreamStubProtocol.sent[host, default: 0] } < 32)
        }
    }

    @Test func importsRejectResourcesLinkedToAnotherAppOrVersion() async throws {
        let targets = [("/v1/apps/1000000001/appInfos", "appInfos", "app", "apps"),
                       ("/v1/apps/1000000001/appStoreVersions", "appStoreVersions", "app", "apps"),
                       ("/v1/appStoreVersions/version-1/appStoreVersionLocalizations", "appStoreVersionLocalizations", "appStoreVersion", "appStoreVersions")]
        for (index, target) in targets.enumerated() {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "import-parent-\(index).appstoreconnect.test"
            let before = try await session.revisions(accountId: account.id, appId: app).map(\.id)
            StubProtocol.handle(host) { request in
                if request.url!.path == target.0 {
                    return apple.page([resource(target.1, "synthetic-foreign", parent: (target.2, target.3, "foreign-parent"))])
                }
                return apple.handle(request)
            }
            let client = try PublishingTests().client(account, host: host)
            await #expect(throws: ImportFailure.download) { try await session.importApp(account: account, appId: app, client: client) }
            #expect(try await session.revisions(accountId: account.id, appId: app).map(\.id) == before)
            #expect(try await session.importJob(account: account, appId: app)?.state == .failed)
            #expect(apple.writes.isEmpty)
        }
    }

    @Test func unreadableAppleIDWriteRepliesCannotCompleteOrReplayAReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticAppleID()
        let webHost = "integrity.appleid.test", apiHost = "privacy-integrity.appstoreconnect.test"
        StubProtocol.handle(webHost) { request in
            let response = apple.handle(request)
            return request.url!.path.hasPrefix("/iris/v1/") && request.httpMethod != "GET" ? (200, [:], Data("Synthetic unreadable write reply".utf8)) : response
        }
        StubProtocol.handle(apiHost) { apple.handle($0) }
        let web = AppleWebSession(appleId: "tester@example.com", teams: [.init(id: "12345", name: "Synthetic Team")],
                                  cookies: [.init(name: "myacinfo", value: "synthetic", domain: webHost, path: "/", expires: nil, secure: true)],
                                  origins: AppleIDOrigins(identity: URL(string: "https://idmsa.appleid.test")!, connect: URL(string: "https://\(webHost)")!), signedInAt: "2026-11-01T00:00:00.000Z")
        try await session.routeAppleWeb(web) { AppleIDTests.configuration() }
        var request = PublishRequest(accountId: account.id, appId: app, scope: .appPrivacy)
        request.appPrivacy = AppPrivacyAnswers(collects: false, items: [])
        let client = try PublishingTests().client(account, host: apiHost)
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(!review.steps.isEmpty && apple.writes.isEmpty)
        let result = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(result.state == "failed" && apple.writes.count == 1)
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(apple.writes.count == 1)
    }
}
