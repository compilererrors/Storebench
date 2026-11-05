import Foundation
import Testing
@testable import StorebenchCore

/// In-process Apple answers; neither reads nor writes reach an external service.
private final class NoSalesApple: @unchecked Sendable {
    let lock = NSLock()
    var prices = ["USA": "10", "SWE": "100", "GBR": "10"]
    var amounts = ["0", "1", "2", "3", "4", "5", "7.5", "9", "10", "25", "50", "70", "75", "80", "100"]
    var pointStatus = 200
    var onPoints: (() throws -> Void)?
    let currencies = ["USA": "USD", "SWE": "SEK", "GBR": "GBP"]
    func page(_ data: Any, included: [Any] = []) -> (Int, [String: String], Data) { (200, [:], try! JSONSerialization.data(withJSONObject: ["data": data, "included": included, "links": [:]])) }
    func answer(_ request: URLRequest) -> (Int, [String: String], Data) {
        #expect(request.httpMethod == "GET")
        switch request.url!.path {
        case "/v1/apps/1000000001/appPriceSchedule": return page(["type": "appPriceSchedules", "id": "synthetic-schedule"])
        case "/v1/appPriceSchedules/synthetic-schedule/baseTerritory": return page(["type": "territories", "id": "USA", "attributes": ["currency": "USD"]])
        case "/v1/appPriceSchedules/synthetic-schedule/automaticPrices": return page([])
        case "/v1/appPriceSchedules/synthetic-schedule/manualPrices":
            let current = lock.withLock { prices }
            let data = current.keys.sorted().map { code in ["type": "appPrices", "id": "price-\(code)", "attributes": [:], "relationships": ["territory": ["data": ["type": "territories", "id": code]], "appPricePoint": ["data": ["type": "appPricePoints", "id": "current-\(code)"]]]] as [String: Any] }
            let included = current.keys.sorted().flatMap { code -> [[String: Any]] in [["type": "territories", "id": code, "attributes": ["currency": currencies[code]!]], ["type": "appPricePoints", "id": "current-\(code)", "attributes": ["customerPrice": current[code]!, "proceeds": "0"]]] }
            return page(data, included: included)
        case "/v1/territories": return page(currencies.keys.sorted().map { ["type": "territories", "id": $0, "attributes": ["currency": currencies[$0]!]] })
        case "/v1/apps/1000000001/appPricePoints":
            let (hook, values, status) = lock.withLock { let hook = onPoints; onPoints = nil; return (hook, amounts, pointStatus) }
            do { try hook?() } catch { Issue.record("Synthetic concurrent write failed: \(error)") }
            if status != 200 { return (status, [:], Data()) }
            let codes = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "filter[territory]" }?.value?.components(separatedBy: ",") ?? []
            return page(codes.flatMap { code in values.map { amount in ["type": "appPricePoints", "id": "\(code)-\(amount)", "attributes": ["customerPrice": amount], "relationships": ["territory": ["data": ["type": "territories", "id": code]]]] as [String: Any] } })
        default: Issue.record("Unexpected synthetic pricing route"); return (404, [:], Data())
        }
    }
}

private final class NoSalesClock: @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    var lockedChecks: [Bool] = []
    let initial: Date, directory: URL
    init(initial: Date, directory: URL) { self.initial = initial; self.directory = directory }
    func now() -> Date {
        let call = lock.withLock { calls += 1; return calls }
        if call < 3 { return initial }
        for name in ["pricing_profiles", "price_protection", "pricing_drafts"] {
            do {
                let held = try FileMutex.tryLock(directory.appendingPathComponent("\(name).mutex"))
                lock.withLock { lockedChecks.append(held == nil) }; held?.release()
            } catch { Issue.record("Synthetic clock could not check the owned mutex") }
        }
        return initial.addingTimeInterval(86_400)
    }
}

@Suite(.serialized) struct NoSalesGuideTests {
    init() throws { _ = try TestIsolation.require() }
    let now = Date(timeIntervalSince1970: 1_772_452_800) // Synthetic 2026-03-02 noon UTC.
    let app = "1000000001"
    func fixtures() throws -> JSONText { try JSONText.parse(Data(contentsOf: try TestIsolation.require().appendingPathComponent("native-fixtures/no-sales-guide.json"))) }
    func number(_ value: JSONText?) throws -> Double { guard case .number(let n)? = value else { throw NoSalesFailure.invalid }; return n }
    func context(_ value: JSONText) throws -> NoSalesContext {
        let coverage = try #require(value["coverage"]), end = try #require(coverage["endDate"]?.text), days = try number(coverage["days"])
        let profileJSON = try #require(value["profile"]), profile = try #require(PricingProfile(profileJSON))
        let history = JSONText.object([("accountId", value["accountId"]!), ("appId", value["appId"]!), ("reports", .array([.object([("beginDate", coverage["beginDate"]!), ("endDate", .string(end)), ("importedAt", .string("2026-03-02T12:00:00.000Z")), ("unitsByTerritory", coverage["unitsByTerritory"]!)])]))])
        return NoSalesContext(accountId: try #require(value["accountId"]?.text), appId: app, profile: profile, coverage: try NoSalesReview(history: history, days: Int(days), endDate: end), prices: WorkspaceSession.items(value["prices"]).compactMap(PriceRow.init), protected: WorkspaceSession.items(value["protected"]).compactMap(\.text), drafts: WorkspaceSession.items(value["drafts"]).compactMap(PricingDraft.init), initialBase: "5")
    }
    func strategy(_ value: JSONText) throws -> NoSalesStrategy {
        let amount = try #require(value["value"]?.text)
        switch value["kind"]?.text {
        case "percent": return .percent(amount)
        case "reduce": return .reduce(amount: amount, base: try #require(value["base"]?.text))
        default: return .model(method: try #require(value["method"]?.text), price: amount, base: try #require(value["base"]?.text))
        }
    }
    func history(_ account: Account, stamp: String = "2026-03-02T12:00:00.000Z", units: [String: Int] = [:]) throws -> JSONText {
        let last = try #require(PeriodDates.number(SalesReports.latestCompletedDay(now: now)))
        let reports = (0..<3).map { offset in SalesRecord(accountId: account.id, appId: app, appSku: nil, productScope: nil, beginDate: PeriodDates.text(last - offset), endDate: PeriodDates.text(last - offset), importedAt: stamp, unitsByTerritory: offset == 0 ? units : [:], source: nil, noSales: offset == 0 && !units.isEmpty ? nil : true).json }
        return .object([("schemaVersion", .number(2)), ("accountId", .string(account.id)), ("appId", .string(app)), ("reports", .array(reports))])
    }
    func seed(_ session: WorkspaceSession, account: Account, reports: JSONText? = nil) async throws {
        let value = try reports ?? history(account)
        try await session.storeAccess { store in try store.transaction { _ in [.delete(namespace: "sales_index", key: "\(account.id):\(app)"), .put(namespace: "sales", key: "\(account.id):\(app)", json: value.data)] } }
    }
    private func setup() async throws -> (WorkspaceSession, URL, Account, AppStoreConnectClient, NoSalesApple, String) {
        let (session, root) = try DraftTests().session(), account = try #require(try await session.accounts().first)
        let host = "no-sales-\(UUID().uuidString.lowercased()).appstoreconnect.test", apple = NoSalesApple()
        StubProtocol.handle(host, apple.answer)
        let client = try PricingTests().stubbedClient(host, account)
        try await seed(session, account: account)
        for namespace in ["pricing_drafts", "price_protection"] {
            let key = namespace == "pricing_drafts" ? "drafts" : "locks", value = JSONText.object([("schemaVersion", .number(1)), (key, .array([]))])
            try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: namespace, key: "current", json: value.data)] } }
        }
        _ = try await session.refreshPricing(account: account, appId: app, client: client, now: now)
        return (session, root, account, client, apple, host)
    }
    func sources(_ id: String) -> PricingSources {
        var sources = PricingSources(); sources.configuration.protocolClasses = [StubProtocol.self]
        let host = "no-sales-sources-\(id).pricing.test"
        sources.frankfurter = URL(string: "https://\(host)/rates")!; sources.exchangeRates = URL(string: "https://\(host)/backup")!
        sources.bigMac = URL(string: "https://\(host)/bigmac")!; sources.worldBank = URL(string: "https://\(host)/ppp")!; sources.worldBankCurrencies = URL(string: "https://\(host)/currencies")!
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "GET")
            let value: Any
            switch request.url!.path {
            case "/rates": value = [["base": "USD", "quote": "SEK", "date": "2026-03-01", "rate": 10], ["base": "USD", "quote": "GBP", "date": "2026-03-01", "rate": 0.8]] as [[String: Any]]
            case "/bigmac": return (200, [:], Data("date,iso_a3,currency_code,local_price\n2026-03-01,USA,USD,1\n2026-03-01,SWE,SEK,10\n2026-03-01,GBR,GBP,0.8\n".utf8))
            case "/ppp": value = [[:], [["countryiso3code": "USA", "date": "2025", "value": 1], ["countryiso3code": "SWE", "date": "2025", "value": 10], ["countryiso3code": "GBR", "date": "2025", "value": 0.8]]] as [Any]
            case "/currencies":
                let variables = [("USA", "US dollar"), ("SWE", "Swedish krona"), ("GBR", "Pound sterling")].map { code, name in ["id": code, "metatype": [["id": "CurrencyUnit", "value": name]]] as [String: Any] }
                value = ["source": [["concept": [["variable": variables]]]]]
            default: Issue.record("Unexpected synthetic pricing source"); return (404, [:], Data())
            }
            return (200, [:], try! JSONSerialization.data(withJSONObject: value))
        }
        return sources
    }
    func loaded(_ session: WorkspaceSession, _ account: Account, days: Int = 3) async throws -> NoSalesContext { try await session.noSalesContext(accountId: account.id, appId: app, profileId: "standard", days: days, now: now) }
    func preview(_ session: WorkspaceSession, _ account: Account, _ client: AppStoreConnectClient, codes: [String] = ["USA", "SWE"], strategy: NoSalesStrategy = .percent("25")) async throws -> NoSalesProposal {
        let current = try await loaded(session, account), fixed = now
        return try await session.previewNoSales(account: account, context: current, codes: codes, maxSales: 0, strategy: strategy, client: client, now: { fixed })
    }
    func commit(_ session: WorkspaceSession, _ account: Account, _ client: AppStoreConnectClient, _ proposal: NoSalesProposal, codes: [String] = ["USA", "SWE"]) async throws -> [PricingDraft] {
        let fixed = now; return try await session.saveNoSales(account: account, proposal: proposal, codes: codes, client: client, now: { fixed })
    }

    @Test func importedReportsWithDistinctUnicodeColumnsRemainReadableByThePriceGuide() async throws {
        let (session, root, account, _, _, _) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try SalesFileTests().golden()
        guard case .array(let vectors)? = fixture["vectors"] else { Issue.record("Missing synthetic report vectors"); return }
        let vector = try #require(vectors.first { $0["id"] == .string("distinct-unicode-columns") })
        let text = try #require(vector["text"]?.text), stamp = try #require(fixture["importedAt"]?.text)
        let records = try SalesFileFormats.parse(text, accountId: account.id, appId: app, importedAt: stamp)
        let history = JSONText.object([("schemaVersion", .number(2)), ("accountId", .string(account.id)), ("appId", .string(app)), ("reports", .array(records.map(\.json)))])
        try await seed(session, account: account, reports: history)
        let checkTime = try #require(ReportTables.dayFormat.date(from: "2026-02-11")).addingTimeInterval(43_200)
        let context = try await session.noSalesContext(accountId: account.id, appId: app, profileId: "standard", days: 1, now: checkTime)
        #expect(context.coverage.complete && context.coverage.coveredDays == 1 && context.coverage.unitsByTerritory == ["USA": 3])
    }

    @Test func compressedUnicodeReportsKeepTheWebSourceLimitWhenOpenedInThePriceGuide() async throws {
        let (session, root, account, _, _, _) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let columns = SalesSyncTests.columns + ["Title"]
        let row = ["APPLE", "SYNTHETIC", app, "1F", "1", ".99", "02/28/2026", "02/28/2026", "US", "", String(repeating: "😀", count: 18)]
        let text = columns.joined(separator: "\t") + "\n" + String(repeating: row.joined(separator: "\t") + "\n", count: 55_000)
        #expect(text.utf8.count <= 8_000_000)
        let decoded = try ReportFiles.texts([ReportFiles.gzip(Data(text.utf8))], purpose: .sales)[0]
        let records = try SalesFileFormats.parse(decoded, accountId: account.id, appId: app, importedAt: CustomerReview.isoString(now))
        let source = try #require(records[0].json["source"]).stringify()
        #expect(source.utf8.count > 8_000_000 && source.utf16.count <= 8_000_000)
        let previous = WorkspaceSession.items(try history(account)["reports"]).filter { $0["beginDate"] != .string("2026-02-28") }
        let history = JSONText.object([("schemaVersion", .number(2)), ("accountId", .string(account.id)), ("appId", .string(app)), ("reports", .array(previous + records.map(\.json)))])
        try await seed(session, account: account, reports: history)
        let context = try await loaded(session, account)
        #expect(context.coverage.complete && context.coverage.coveredDays == 3 && context.coverage.unitsByTerritory == ["USA": 55_000])
    }

    @Test func coverageAndDigestMatchTheWebIncludingUnknownDaysAndUnsafeCounts() throws {
        let vectors = try fixtures()
        for item in WorkspaceSession.items(vectors["reviews"]) {
            let input = try #require(item["history"]), days = try number(item["days"]), end = try #require(item["endDate"]?.text)
            let actual = try NoSalesReview(history: input == .null ? nil : input, days: Int(days), endDate: end).json
            #expect(actual == item["expected"], "Synthetic window \(end) over \(days) days")
        }
        for item in WorkspaceSession.items(vectors["invalid"]) {
            #expect(throws: NoSalesFailure.invalid) { try NoSalesReview(history: nil, days: Int(number(item["days"])), endDate: try #require(item["endDate"]?.text)) }
        }
    }
    @Test func allSixStrategiesAndExistingDraftFiltersMatchTheWeb() throws {
        for item in WorkspaceSession.items(try fixtures()["calculations"]) {
            let current = try context(#require(item["context"])), chosen = WorkspaceSession.items(item["codes"]).compactMap(\.text)
            let countries = WorkspaceSession.items(item["countries"]).map { Territory(code: $0["code"]!.text!, name: $0["name"]!.text!, currency: $0["currency"]!.text!) }
            let points = WorkspaceSession.items(item["points"]).map { PricePoint(id: $0["id"]!.text!, territory: $0["territory"]!.text!, customerPrice: $0["customerPrice"]!.text!) }
            var rates: [String: FxRate] = [:]
            if case .object(let pairs)? = item["rates"] { for (code, rate) in pairs { rates[code] = FxRate(rate: rate["rate"]!.text!, date: rate["date"]!.text!, source: rate["source"]!.text!, providers: nil, fetchedAt: nil) } }
            var index: IndexSnapshot?
            if let value = item["index"], value != .null, case .object(let pairs)? = value["values"] { index = IndexSnapshot(method: value["method"]!.text!, date: value["date"]!.text!, source: value["source"]!.text!, values: Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1.text!) })) }
            let result = try NoSalesGuide.calculate(context: current, codes: chosen, maxSales: Int(number(item["maxSales"])), strategy: strategy(#require(item["strategy"])), countries: countries, points: points, rates: rates, index: index)
            let actual = JSONText.array(result.rows.map { .object([("territory", .string($0.territory)), ("currency", .string($0.currency)), ("amount", .string($0.amount))]) })
            #expect(actual == item["expected"], "Synthetic strategy \(item["strategy"]!.stringify()) · \(item["variant"]!.text!)")
            #expect(JSONText.array(result.skipped.map { .string($0.territory) }) == item["skipped"])
        }
    }
    @Test func everyStrategyPreviewsAndSavesOnlyTheReviewedLocalAmounts() async throws {
        let choices: [NoSalesStrategy] = [.percent("25"), .reduce(amount: "2", base: "USA"), .model(method: "fx", price: "5", base: "USA"), .model(method: "same", price: "5", base: "USA"), .model(method: "ppp", price: "5", base: "USA"), .model(method: "bigmac", price: "5", base: "USA")]
        for strategy in choices {
            let (session, root, account, client, _, host) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
            let current = try await loaded(session, account), fixed = now, sources = sources(UUID().uuidString.lowercased()), codes = ["USA", "SWE", "GBR"]
            let proposal = try await session.previewNoSales(account: account, context: current, codes: codes, maxSales: 0, strategy: strategy, client: client, sources: sources, now: { fixed })
            let expected: [String]
            switch strategy { case .percent: expected = ["7.5", "75", "7.5"]; case .reduce: expected = ["7.5", "80", "7.5"]; case .model("same", _, _): expected = ["5", "5", "5"]; default: expected = ["5", "50", "4"] }
            #expect(proposal.rows.map(\.amount) == expected && proposal.skipped.isEmpty)
            #expect(try await session.pricingDrafts(accountId: account.id, appId: app).isEmpty)
            let saved = try await session.saveNoSales(account: account, proposal: proposal, codes: codes, client: client, sources: sources, now: { fixed })
            #expect(saved.map(\.amount) == expected)
            #expect(try await session.pricingProfiles().profiles[0] == current.profile)
            #expect(StubProtocol.requests(host).allSatisfy { $0.httpMethod == "GET" })
        }
    }
    @Test func missingModelPointsAreSkippedAndExactAmountsNeedAnAppleMatch() async throws {
        let (session, root, account, client, apple, _) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        apple.lock.withLock { apple.pointStatus = 403 }
        let unknown = try await preview(session, account, client, strategy: .model(method: "same", price: "5", base: "USA"))
        #expect(unknown.rows.isEmpty && unknown.skipped.count == 2 && !unknown.warnings.isEmpty)
        apple.lock.withLock { apple.pointStatus = 200; apple.amounts.removeAll { $0 == "5" } }
        let unavailable = try await preview(session, account, client, strategy: .model(method: "same", price: "5", base: "USA"))
        #expect(unavailable.rows.isEmpty && unavailable.skipped.count == 2)
        #expect(try await session.pricingDrafts(accountId: account.id, appId: app).isEmpty)
    }
    @Test func signaturesPinReplacementIDsAndIgnoreCreationTimestamps() throws {
        let fixture = try fixtures(), sample = try #require(WorkspaceSession.items(fixture["calculations"]).first)
        for item in WorkspaceSession.items(fixture["signatures"]) {
            let value = try #require(sample["context"]), base = try context(value)
            let current = NoSalesContext(accountId: base.accountId, appId: base.appId, profile: base.profile, coverage: base.coverage, prices: base.prices, protected: [], drafts: WorkspaceSession.items(item["drafts"]).compactMap(PricingDraft.init), initialBase: "5")
            #expect(current.draftsSignature(["SWE"]) == item["expected"])
        }
    }
    @Test func invalidStrategiesAndSelectionsCannotReachADownloadOrWrite() async throws {
        let (session, root, account, client, _, host) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try await loaded(session, account), fixed = now, before = StubProtocol.requests(host).count
        for strategy: NoSalesStrategy in [.percent("0"), .percent("100"), .percent("1.001"), .reduce(amount: "0", base: "USA"), .reduce(amount: "1", base: "US"), .model(method: "custom", price: "5", base: "USA"), .model(method: "fx", price: "05", base: "USA")] {
            await #expect(throws: NoSalesFailure.invalid) { try await session.previewNoSales(account: account, context: current, codes: ["USA"], maxSales: 0, strategy: strategy, client: client, now: { fixed }) }
        }
        for codes in [[], ["USA", "USA"], ["US"], Array(repeating: "USA", count: 201)] {
            await #expect(throws: NoSalesFailure.invalid) { try await session.previewNoSales(account: account, context: current, codes: codes, maxSales: 0, strategy: .percent("25"), client: client, now: { fixed }) }
        }
        #expect(StubProtocol.requests(host).count == before)
        #expect(try await session.pricingDrafts(accountId: account.id, appId: app).isEmpty)
    }
    @Test func explicitSaveRecalculatesChosenSubsetAndConsumesItsBaseline() async throws {
        let (session, root, account, client, _, host) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("SWE", "SEK", "80"), ("GBR", "GBP", "9")], startDate: nil, endDate: nil)
        let proposal = try await preview(session, account, client)
        #expect(proposal.rows.map(\.amount) == ["7.5", "75"])
        #expect(try await session.pricingDrafts(accountId: account.id, appId: app).map(\.amount) == ["80", "9"])
        let saved = try await commit(session, account, client, proposal, codes: ["SWE"])
        #expect(saved.count == 1 && saved[0].amount == "75" && saved[0].startDate == nil)
        let all = try await session.pricingDrafts(accountId: account.id, appId: app)
        #expect(Set(all.map(\.amount)) == Set(["9", "75"]) && !all.contains { $0.territory == "USA" })
        await #expect(throws: NoSalesFailure.stale) { try await commit(session, account, client, proposal, codes: ["SWE"]) }
        #expect(try await session.publishHistory(accountId: account.id, appId: app).isEmpty)
        #expect(StubProtocol.requests(host).allSatisfy { $0.httpMethod == "GET" })
    }
    @Test func incompleteCoverageFewSalesProtectionAndScheduledDraftsStayDistinct() async throws {
        let (session, root, account, client, _, _) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let fixed = now, unknown = try await loaded(session, account, days: 4)
        #expect(!unknown.coverage.complete && unknown.eligible(maxSales: 1000).isEmpty)
        await #expect(throws: NoSalesFailure.coverage) { try await session.previewNoSales(account: account, context: unknown, codes: ["USA"], maxSales: 0, strategy: .percent("25"), client: client, now: { fixed }) }
        try await seed(session, account: account, reports: history(account, units: ["SWE": 2]))
        var current = try await loaded(session, account)
        #expect(!current.eligible(maxSales: 0).contains { $0.territory == "SWE" } && current.eligible(maxSales: 2).count == 3)
        try await session.protectPrices(accountId: account.id, appId: app, prices: [("USA", "10", "USD")], now: now)
        _ = try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("GBR", "GBP", "7.5")], startDate: "2026-04-01", endDate: "2026-04-07")
        current = try await loaded(session, account)
        #expect(current.eligible(maxSales: 2).map(\.territory) == ["SWE"])
        await #expect(throws: NoSalesFailure.selection) { try await session.previewNoSales(account: account, context: current, codes: ["USA"], maxSales: 2, strategy: .percent("25"), client: client, now: { fixed }) }
        let proposal = try await session.previewNoSales(account: account, context: current, codes: ["SWE"], maxSales: 2, strategy: .percent("25"), client: client, now: { fixed })
        #expect(proposal.rows.map(\.amount) == ["75"])
    }
    @Test func legacySingleDayAndPartitionedReportsHaveTheSameReview() async throws {
        let (session, root, account, _, _, _) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let day = SalesReports.latestCompletedDay(now: now), record = SalesRecord.noSalesDay(accountId: account.id, appId: app, day: day, importedAt: "2026-03-02T12:00:00.000Z")
        try await seed(session, account: account, reports: record.json)
        let legacy = try await loaded(session, account, days: 1)
        #expect(legacy.coverage.complete && legacy.coverage.unitsByTerritory.isEmpty)
        try await session.storeAccess { store in
            try PartitionedReports.replaceAll(SalesRecord.self, family: "sales", legacyKey: "reports", accountId: account.id, appId: app, store: store, stateDirectory: store.directory, bucketOf: { String($0.beginDate.prefix(7)) }, encode: { $0.json }) { _, _ in ([record], nil) }
        }
        let partitioned = try await loaded(session, account, days: 1)
        #expect(partitioned.coverage == legacy.coverage)
    }
    @Test func legacySKUSourceRowsRemainReadableWithoutBeingCountedAsAppPurchases() async throws {
        let (session, root, account, _, _, _) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixtures(), value = try #require(fixture["legacySource"]), report = try #require(value["report"])
        try await seed(session, account: account, reports: report)
        let current = try await loaded(session, account, days: 1)
        #expect(current.coverage.json == value["expected"])
        #expect(current.coverage.complete && current.coverage.unitsByTerritory["USA"] == 1 && current.coverage.unitsByTerritory["SWE"] == nil)
    }
    @Test func malformedOrUnsafeSourceCountsCannotTrapOrEstablishZeroPurchases() throws {
        let fixture = try fixtures(), value = try #require(fixture["legacySource"]), report = try #require(value["report"])
        let source = try #require(report["source"]), table = try JSONDecoder().decode(ReportTable.self, from: source.data)
        for invalid in ["9007199254740992", "9223372036854775807", "-9007199254740992", "1.5"] {
            var rows = table.rows; rows[0][2] = invalid
            #expect(throws: SalesFailure.validation("The sales report has an invalid or fractional unit count. Whole app units are required; no values were rounded.")) {
                try SalesReports.summary(ReportTable(columns: table.columns, rows: rows), appId: app, accountId: "synthetic-account", importedAt: "2026-03-02T12:00:00.000Z", appSku: "synthetic-app-sku", scope: nil, legacy: true)
            }
        }
        var first = table.rows[0]; first[2] = "9007199254740991"
        #expect(throws: SalesFailure.validation("The sales report has too many units for one country.")) {
            try SalesReports.summary(ReportTable(columns: table.columns, rows: [first, table.rows[0]]), appId: app, accountId: "synthetic-account", importedAt: "2026-03-02T12:00:00.000Z", appSku: nil, scope: nil)
        }
        var infinite = table.rows[0]; infinite[4] = String(repeating: "9", count: 400)
        #expect(throws: SalesFailure.validation("The sales report has an invalid customer price.")) {
            try SalesReports.summary(ReportTable(columns: table.columns, rows: [infinite]), appId: app, accountId: "synthetic-account", importedAt: "2026-03-02T12:00:00.000Z", appSku: nil, scope: nil)
        }
    }
    @Test func reportPriceProfileAndSameValueDraftChangesInvalidateTheReview() async throws {
        for change in ["report", "price", "profile", "draft", "protection", "day"] {
            let (session, root, account, client, apple, _) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
            _ = try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("SWE", "SEK", "80")], startDate: nil, endDate: nil)
            let proposal = try await preview(session, account, client, codes: ["SWE"])
            switch change {
            case "report": try await seed(session, account: account, reports: history(account, stamp: "2026-03-02T13:00:00.000Z"))
            case "price": apple.lock.withLock { apple.prices["SWE"] = "100.0" }
            case "profile": var profile = proposal.context.profile; profile.name = "Changed synthetic profile"; try await session.updatePricingProfile("save", id: profile.id, profile: profile, revision: proposal.context.profileRevision)
            case "draft": _ = try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("SWE", "SEK", "80")], startDate: nil, endDate: nil)
            case "protection": try await session.protectPrices(accountId: account.id, appId: app, prices: [("SWE", "100", "SEK")], now: now)
            default: break
            }
            let fixed = change == "day" ? now.addingTimeInterval(86_400) : now
            await #expect(throws: (any Error).self) { try await session.saveNoSales(account: account, proposal: proposal, codes: ["SWE"], client: client, now: { fixed }) }
            #expect(try await session.pricingDrafts(accountId: account.id, appId: app).map(\.amount) == ["80"])
        }
    }
    @Test func changesDuringPricePointDownloadFailTheFinalLockedCheck() async throws {
        let (session, root, account, client, apple, _) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let proposal = try await preview(session, account, client), changed = try history(account, stamp: "2026-03-02T14:00:00.000Z"), database = EncryptedDocumentStore.databaseURL(root: root)
        apple.lock.withLock { apple.onPoints = {
            let store = try EncryptedDocumentStore(url: database, key: Data(0..<32), writable: true)
            let name = "sales-" + JSONText.string("\(account.id)\u{0}1000000001").rawSHA256.prefix(32) + ".mutex"
            try FileMutex.withLock(store.directory.appendingPathComponent(String(name))) { try store.transaction { _ in [.put(namespace: "sales", key: "\(account.id):1000000001", json: changed.data)] } }
        } }
        await #expect(throws: NoSalesFailure.stale) { try await commit(session, account, client, proposal) }
        #expect(try await session.pricingDrafts(accountId: account.id, appId: app).isEmpty)
    }
    @Test func reportingDayIsRecheckedAfterAllWriteLocksAreHeld() async throws {
        let (session, root, account, client, _, _) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try await loaded(session, account), clock = NoSalesClock(initial: now, directory: root.appendingPathComponent("state-v2"))
        await #expect(throws: NoSalesFailure.stale) { try await session.previewNoSales(account: account, context: current, codes: ["SWE"], maxSales: 0, strategy: .percent("25"), client: client, now: clock.now) }
        #expect(clock.lock.withLock { clock.lockedChecks } == [true, true, true])
        #expect(try await session.pricingDrafts(accountId: account.id, appId: app).isEmpty)
    }
    @Test func protectionDraftAndAccountChangesDuringDownloadStopTheCommit() async throws {
        for change in ["protection", "draft", "account"] {
            let (session, root, account, client, apple, _) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
            let proposal = try await preview(session, account, client, codes: ["SWE"]), database = EncryptedDocumentStore.databaseURL(root: root)
            let override = PricingDraft(id: "00000000-0000-4000-8000-000000000050", accountId: account.id, appId: app, territory: "SWE", currency: "SEK", amount: "80", startDate: nil, endDate: nil, createdAt: "2026-03-02T12:00:00.000Z")
            apple.lock.withLock { apple.onPoints = {
                let store = try EncryptedDocumentStore(url: database, key: Data(0..<32), writable: true)
                let namespace = change == "account" ? "accounts" : change == "draft" ? "pricing_drafts" : "price_protection"
                try FileMutex.withLock(store.directory.appendingPathComponent("\(namespace).mutex")) {
                    let value: JSONText
                    if change == "account" { value = .array([]) }
                    else if change == "draft" { value = .object([("schemaVersion", .number(1)), ("drafts", .array([override.json]))]) }
                    else { value = .object([("schemaVersion", .number(1)), ("locks", .array([.object([("accountId", .string(account.id)), ("appId", .string("1000000001")), ("priceProduct", .string("paid-app")), ("territory", .string("SWE")), ("customerPrice", .string("100")), ("currency", .string("SEK")), ("protectedAt", .string("2026-03-02T12:00:00.000Z"))])]))]) }
                    try store.transaction { _ in [.put(namespace: namespace, key: change == "account" ? "all" : "current", json: value.data)] }
                }
            } }
            await #expect(throws: (any Error).self) { try await commit(session, account, client, proposal, codes: ["SWE"]) }
            let remaining = try await session.pricingDrafts(accountId: account.id, appId: app)
            #expect(remaining.map(\.amount) == (change == "draft" ? ["80"] : []))
        }
    }
    @Test func unselectedDraftReplacementDoesNotInvalidateASelectedCountry() async throws {
        let (session, root, account, client, _, _) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let proposal = try await preview(session, account, client)
        _ = try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("USA", "USD", "9")], startDate: nil, endDate: nil)
        let saved = try await commit(session, account, client, proposal, codes: ["SWE"])
        #expect(saved.map(\.amount) == ["75"])
        #expect(Set(try await session.pricingDrafts(accountId: account.id, appId: app).map(\.amount)) == Set(["9", "75"]))
    }
    @Test func pointChangesAndFailuresCannotSaveAnUnreviewedAmount() async throws {
        for failure in [false, true] {
            let (session, root, account, client, apple, _) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
            let proposal = try await preview(session, account, client)
            apple.lock.withLock { if failure { apple.pointStatus = 403 } else { apple.amounts.removeAll { $0 == "75" } } }
            await #expect(throws: failure ? NoSalesFailure.points : NoSalesFailure.stale) { try await commit(session, account, client, proposal) }
            #expect(try await session.pricingDrafts(accountId: account.id, appId: app).isEmpty)
        }
    }
    @Test func separateSessionsHaveOneWinnerAndKeepPermanentMutexInodes() async throws {
        let (first, root, account, client, _, _) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await first.vault), proposal = try await preview(first, account, client)
        let mutex = root.appendingPathComponent("state-v2/pricing_drafts.mutex"), before = try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber
        func attempt(_ session: WorkspaceSession) async -> Bool { do { _ = try await commit(session, account, client, proposal); return true } catch { return false } }
        async let a = attempt(first), b = attempt(second)
        let answers = await [a, b]
        #expect(answers.filter { $0 }.count == 1)
        #expect(try await first.pricingDrafts(accountId: account.id, appId: app).count == 2)
        let after = try FileManager.default.attributesOfItem(atPath: mutex.path)
        #expect(before != nil && after[.systemFileNumber] as? NSNumber == before && after[.size] as? NSNumber == 0)
    }
    @Test func malformedSavedReportsProtectionAndDraftsFailClosed() async throws {
        for kind in ["no-sales", "overlap", "source", "units", "schema", "null", "protection", "draft", "scheduled-overlap"] {
            let (session, root, account, _, _, _) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
            if kind == "scheduled-overlap" {
                let a = PricingDraft(id: "00000000-0000-4000-8000-000000000050", accountId: account.id, appId: app, territory: "SWE", currency: "SEK", amount: "80", startDate: "2026-04-01", endDate: "2026-04-07", createdAt: "2026-03-02T12:00:00.000Z")
                let b = PricingDraft(id: "00000000-0000-4000-8000-000000000051", accountId: account.id, appId: app, territory: "SWE", currency: "SEK", amount: "75", startDate: "2026-04-05", endDate: "2026-04-09", createdAt: a.createdAt)
                try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "pricing_drafts", key: "current", json: JSONText.object([("schemaVersion", .number(1)), ("drafts", .array([a.json, b.json]))]).data)] } }
            } else if kind == "protection" || kind == "draft" {
                let namespace = kind == "draft" ? "pricing_drafts" : "price_protection", key = kind == "draft" ? "drafts" : "locks"
                try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: namespace, key: "current", json: JSONText.object([("schemaVersion", .number(1)), (key, .array([.object([])]))]).data)] } }
            } else {
                var value = try history(account)
                var rows = WorkspaceSession.items(value["reports"])
                if kind == "overlap" { rows.append(rows[0]) }
                if kind == "no-sales" { rows[0] = rows[0].setting("unitsByTerritory", .object([("SWE", .number(1))])) }
                if kind == "source" { rows[0] = rows[0].setting("source", .object([("columns", .array([.string("Apple Identifier")])), ("rows", .array([.array([])]))])) }
                if kind == "units" { rows[0] = rows[0].setting("noSales", .null).setting("unitsByTerritory", .object([("US", .number(1))])) }
                if kind == "schema" { rows[0] = rows[0].setting("schemaVersion", .number(2)) }
                if kind == "null" { rows[0] = rows[0].setting("source", .null) }
                value = value.setting("reports", .array(rows)); try await seed(session, account: account, reports: value)
            }
            await #expect(throws: NoSalesFailure.read) { try await loaded(session, account) }
        }
    }
}
