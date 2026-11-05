import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct SalesPresentationTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func multiUnitReportsUpdatePurchaseTotalsWithoutCountingOtherAppsOrProductsAsAppSales() throws {
        let columns = ["Apple Identifier", "Product Type Identifier", "Units", "Country Code", "Customer Price", "Begin Date", "End Date", "Developer Proceeds", "Currency of Proceeds"]
        func record(_ day: String, _ rows: [[String]]) throws -> SalesRecord {
            let table = ReportTable(columns: columns, rows: rows.map { Array($0.prefix(5)) + [day, day] + Array($0.suffix(2)) })
            return try SalesReports.summary(table, appId: "1000000001", accountId: "synthetic-account", importedAt: "2026-02-10T12:00:00.000Z", appSku: "synthetic-app", scope: ProductScope(ids: ["2000000001"], complete: true))
        }
        let first = try record("02/07/2026", [
            ["1000000001", "1", "8", "US", "4.99", "2.50", "USD"],
            ["1000000001", "1", "13", "GB", "4.99", "2.50", "GBP"],
            ["1000000001", "1", "-2", "US", "4.99", "2.50", "USD"],
            ["1000000001", "1", "5", "CA", "0", "0", "CAD"],
            ["2000000001", "IA1", "9", "US", "1.99", "1.00", "USD"],
            ["3000000001", "1", "500", "US", "4.99", "2.50", "USD"],
        ])
        let second = try record("02/08/2026", [["1000000001", "1", "6", "US", "4.99", "2.50", "USD"]])
        func prepare(_ records: [SalesRecord]) throws -> [SalesPresentation.Period] { try SalesPresentation.prepare(records, accountId: "synthetic-account", appId: "1000000001") }
        #expect(try SalesPresentation.analyze(prepare([first])).paid == 21)
        let updated = try prepare([second, first]), total = try SalesPresentation.select(updated, range: .init(beginDate: "2026-02-07", endDate: "2026-02-09"))
        let before = try prepare([first])
        #expect(SalesPresentation.selectedRange(before, choice: .all)?.beginDate == "2026-02-07")
        #expect(SalesPresentation.selectedRange(updated, choice: .all)?.beginDate == "2026-02-07")
        #expect(SalesPresentation.selectedRange(updated, choice: .all)?.endDate == "2026-02-08")
        #expect(SalesPresentation.selectedRange(updated, choice: .all, period: before[0].id)?.endDate == "2026-02-07")
        let custom = try SalesPresentation.Range(beginDate: "2026-02-01", endDate: "2026-02-28")
        let customDates = try PeriodDateRange(from: custom.beginDate, to: custom.endDate)
        #expect(SalesPresentation.selectedRange(updated, choice: .all, requested: custom) == custom)
        #expect(SalesPresentation.selectedRange(updated, choice: .custom(customDates)) == custom)
        #expect(total.analysis.paid == 27 && total.analysis.refunds == 2 && total.analysis.free == 5 && total.analysis.inAppPurchases == 9)
        #expect(total.coveredDays == 2 && total.requestedDays == 3 && !total.complete && total.missingDays == ["2026-02-09"])
        #expect(try SalesPresentation.select(updated, range: .init(beginDate: "2026-02-08", endDate: "2026-02-08")).analysis.paid == 6)
        let free = try #require(total.analysis.rows.first { $0.code == "CAN" })
        #expect(free.proceeds.isEmpty && SalesPresentation.proceedsText(free.proceeds, complete: true) == "No proceeds reported")
        let missing = ReportMoney.convert([], context: .init(currency: "USD"))
        #expect(SalesPresentation.estimateText(missing, context: .init(currency: "USD"), complete: false, available: true) == "—")
        #expect(SalesPresentation.proceedsText([], complete: false).contains("download original reports"))
        let converted = ReportMoney.convert([.init(currency: "USD", amount: "5")], context: .init(currency: "USD"))
        #expect(SalesPresentation.estimateText(converted, context: .init(currency: "USD"), complete: false, available: true) == "USD 5.00 · Partial")
        #expect(SalesPresentation.estimateText(converted, context: .init(currency: "USD"), complete: true, available: false) == "—")
        #expect(SalesPresentation.freshness(updated, completedThrough: "2026-02-10").daysAfterLatest == 2)
        #expect(SalesPresentation.freshness(updated, completedThrough: "2026-02-08").daysAfterLatest == 0)
        #expect(SalesPresentation.freshness([], completedThrough: "2026-02-10").latestSavedDay == nil)
    }
    func golden() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/sales-presentation.json"))) }
    func array(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw SalesPresentationFailure.format }; return values }
    func integer(_ value: JSONText?) -> Int { if case .number(let number)? = value { return Int(number) }; return -1 }
    func boolean(_ value: JSONText?) -> Bool { value == .bool(true) }
    func canonical(_ value: JSONText) -> JSONText {
        switch value {
        case .object(let fields): .object(fields.sorted { $0.0 < $1.0 }.map { ($0.0, canonical($0.1)) })
        case .array(let values): .array(values.map(canonical))
        default: value
        }
    }
    func same(_ actual: JSONText, _ expected: JSONText?) -> Bool { expected.map { canonical(actual).data == canonical($0).data } ?? false }
    func prepared(_ value: JSONText) throws -> [SalesPresentation.Period] {
        let reports = try JSONDecoder().decode([SalesRecord].self, from: value["reports"]!.data)
        return try SalesPresentation.prepare(reports, accountId: "synthetic-account", appId: "1000000001")
    }
    func range(_ value: JSONText) throws -> SalesPresentation.Range { try .init(beginDate: value["beginDate"]!.text!, endDate: value["endDate"]!.text!) }
    func criteria(_ value: JSONText) throws -> SalesPresentation.Criteria {
        try .init(minimumPurchases: integer(value["minimumPurchases"]), minimumCountryPurchases: integer(value["minimumCountryPurchases"]), minimumShare: integer(value["minimumShare"]))
    }
    func context(_ value: JSONText) throws -> ReportMoney.Context {
        guard let currency = value["currency"]?.text, case .object(let fields)? = value["fx"]?["rates"] else { throw SalesPresentationFailure.format }
        return ReportMoney.Context(currency: currency, rates: Dictionary(uniqueKeysWithValues: fields.map { ($0.0, ReportMoney.Rate(rate: $0.1["rate"]!.text!, date: $0.1["date"]!.text!)) }))
    }
    @Test func calculatedProductsRefundsCoverageInsightsAndCsvMatchTheWeb() throws {
        let cases = try array(golden()["cases"]); #expect(cases.count >= 18)
        for vector in cases {
            let periods = try prepared(vector), label = vector["id"]!.text!
            #expect(same(.array(periods.map(\.json)), vector["periods"]), "Synthetic projection: \(label)")
            for item in try array(vector["analyses"]) {
                #expect(same(try SalesPresentation.analyze(periods, criteria: criteria(item["criteria"]!)).json, item["expected"]), "Synthetic analysis: \(label)")
            }
            for item in try array(vector["selections"]) {
                let selected = try SalesPresentation.select(periods, range: range(item["range"]!), criteria: criteria(item["criteria"]!))
                #expect(same(selected.json, item["expected"]), "Synthetic selection: \(label)")
                for export in try array(item["exports"]) { #expect(SalesPresentation.analysisCSV(selected, context: try context(export["context"]!)) == Data(export["csv"]!.text!.utf8), "Synthetic CSV: \(label)") }
            }
        }
    }
    @Test func everyCountrySearchAndSixStableSortColumnsMatchTheWeb() throws {
        for vector in try array(golden()["cases"]) {
            let analysis = try SalesPresentation.analyze(prepared(vector))
            for item in try array(vector["sorts"]) {
                let rows = SalesPresentation.countries(analysis, context: try context(item["context"]!), query: item["query"]!.text!, sort: SalesPresentation.Sort(rawValue: item["key"]!.text!), descending: item["direction"] == .string("descending"))
                if !same(.array(rows.map { .string($0.code) }), item["expected"]) {
                    let wanted = try array(item["expected"]).compactMap(\.text), actual = rows.map(\.code)
                    let difference = zip(actual, wanted).first { $0 != $1 }
                    Issue.record("Synthetic order mismatch: \(vector["id"]!.text!) / \(item["key"]!.text!) / \(item["direction"]!.text!) / \(item["context"]!["currency"]!.text!): \(difference?.0 ?? "missing") versus \(difference?.1 ?? "missing").")
                }
            }
        }
    }
    @Test func portfolioKeepsWholePeriodsOriginalCurrenciesAndUnreadableAppsUnknown() throws {
        let value = try golden(), cases = try array(value["cases"])
        for vector in try array(value["portfolios"]) {
            let sources = try array(vector["sources"]), apps = try sources.enumerated().map { index, source in
                let input = try #require(cases.first { $0["id"] == source })
                return try SalesPortfolio.App(accountId: "synthetic-\(index)", appId: "100000000\(index + 1)", title: "Synthetic app \(index)", unavailable: index == 2, periods: try prepared(input))
            }
            let analysis = try SalesPortfolio.analyze(apps, range: range(vector["range"]!)), expected = try #require(vector["expected"])
            #expect(analysis.paid == integer(expected["paid"]) && analysis.completeApps == integer(expected["completeApps"]))
            #expect(analysis.moneyComplete == boolean(expected["moneyComplete"]) && analysis.productsComplete == boolean(expected["productsComplete"]))
            let amounts = JSONText.array(analysis.proceeds.map { .object([("currency", .string($0.currency)), ("amount", .string($0.amount))]) })
            #expect(same(amounts, expected["proceeds"]))
            for (row, wanted) in zip(analysis.rows, try array(expected["rows"])) {
                #expect(row.app.id == wanted["key"]!.text && row.periods == integer(wanted["periods"]) && row.paid == integer(wanted["paid"]) && row.coveredDays == integer(wanted["coveredDays"]))
                #expect(row.complete == boolean(wanted["complete"]) && row.moneyComplete == boolean(wanted["moneyComplete"]) && row.productsComplete == boolean(wanted["productsComplete"]))
                #expect(same(.array(row.proceeds.map { .object([("currency", .string($0.currency)), ("amount", .string($0.amount))]) }), wanted["proceeds"]))
            }
            #expect(throws: SalesPresentationFailure.format) { try SalesPortfolio.analyze(apps + [apps[0]], range: range(vector["range"]!)) }
        }
    }
    @Test func rangesChangesAndInvalidCriteriaAreExplicit() throws {
        let value = try golden()
        for item in try array(value["previous"]) { #expect(same(try range(item["range"]!).previous?.json ?? .null, item["expected"])) }
        for item in try array(value["changes"]) {
            let actual = SalesPresentation.change(item["current"]?.text, previous: item["previous"]?.text)
            if actual != item["expected"]?.text { Issue.record("Synthetic change mismatch: \(item["current"]?.text ?? "unknown") / \(item["previous"]?.text ?? "unknown"): \(actual) versus \(item["expected"]?.text ?? "unknown").") }
        }
        for bad in ["", "0", "1000001", " 30", "+30", "1e3", "١", "１", "30\n", "00000030"] { #expect(throws: SalesPresentationFailure.criteria) { try SalesPresentation.Criteria(purchases: bad, country: "20", share: "40") } }
        #expect(throws: SalesPresentationFailure.criteria) { try SalesPresentation.Criteria(purchases: "30", country: "20", share: "101") }
        for bad in ["2026-02-30", "2026-2-01", "2026-02-01\n", "-000001-01-01"] { #expect(throws: SalesPresentationFailure.range) { try SalesPresentation.Range(beginDate: bad, endDate: "2026-03-01") } }
    }
    @Test func unknownDetailsBreakTrendsWhileExplicitNoSalesRemainCheckedZeros() throws {
        let vector = try #require(try array(golden()["cases"]).first { $0["id"] == .string("no-sales-and-unknown") })
        let periods = try prepared(vector), analysis = try SalesPresentation.analyze(periods)
        #expect(analysis.free == nil && analysis.refunds == nil && analysis.inAppPurchases == nil)
        let free = SalesPresentation.series(analysis, measure: .free)
        #expect(free.map(\.value) == [0, 5, 0] && free.map(\.segment) == [0, 0, 1])
        #expect(SalesPresentation.series(analysis, measure: .paid).map(\.value) == [0, 60, 84, 0])
        #expect(periods[0].noSales && periods[0].rows.isEmpty && periods[0].moneyComplete && periods[0].productsComplete)
        let range = try SalesPresentation.Range(beginDate: "2020-01-01", endDate: "2026-01-01")
        #expect(try SalesPresentation.select([], range: range).missingDays.count == 401)
        var huge = SalesPresentation.Country(code: "USA"); huge.paid = SalesFileFormats.maximumUnits
        let period = periods[0]
        let first = SalesPresentation.Period(beginDate: "2026-01-01", endDate: "2026-01-01", importedAt: period.importedAt, hasSource: false, noSales: false, detailsComplete: false, moneyComplete: false, productsComplete: false, rows: [huge])
        let second = SalesPresentation.Period(beginDate: "2026-01-02", endDate: "2026-01-02", importedAt: period.importedAt, hasSource: false, noSales: false, detailsComplete: false, moneyComplete: false, productsComplete: false, rows: [huge])
        #expect(throws: SalesPresentationFailure.overflow) { try SalesPresentation.analyze([first, second]) }
        #expect(throws: SalesPresentationFailure.format) { try SalesPresentation.analyze([first, first]) }
        #expect(throws: SalesPresentationFailure.overflow) { try SalesPortfolio.analyze([.init(accountId: "synthetic", appId: "1", title: "Synthetic", periods: [first]), .init(accountId: "synthetic", appId: "2", title: "Synthetic", periods: [first])], range: .init(beginDate: first.beginDate, endDate: first.endDate)) }
        for input in try array(golden()["cases"]) {
            let summary = try SalesPresentation.analyze(prepared(input))
            for line in try array(input["lines"]) {
                let measure = try #require(SalesPresentation.Measure(rawValue: line["measure"]!.text!)), points = SalesPresentation.series(summary, measure: measure)
                let groups = Dictionary(grouping: points, by: \.segment).sorted { $0.key < $1.key }.map { $0.value.count }.filter { $0 >= 2 }
                #expect(points.count == integer(line["points"]) && same(.array(groups.map { .number(Double($0)) }), line["runs"]))
            }
        }
        let monthly = try #require(try array(golden()["cases"]).first { $0["id"] == .string("monthly") })
        let center = try #require(SalesPresentation.series(SalesPresentation.analyze(prepared(monthly)), measure: .paid).first)
        #expect(center.position == PeriodDates.date("2026-02-15"))
    }
    @Test func exportRetainsCountriesBeyondThePageAndPartialFxWithoutChangingEncryptedReports() async throws {
        let value = try golden(), vector = try #require(try array(value["cases"]).first { $0["id"] == .string("all-countries") })
        let periods = try prepared(vector), selected = try SalesPresentation.select(periods, range: .init(beginDate: "2026-02-10", endDate: "2026-02-10"))
        let money = ReportMoney.Context(currency: "EUR"), root = try TestIsolation.require().appendingPathComponent("synthetic-sales-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic-analysis.csv"); try Data("Synthetic previous export".utf8).write(to: url)
        try SalesPresentation.writeAnalysisCSV(selected, context: money, to: url)
        let table = try Delimited.parse(String(decoding: Data(contentsOf: url), as: UTF8.self))
        #expect(table.columns.count == 22 && table.rows.count == 249 && selected.analysis.rows.count == 249)
        #expect(table.rows.allSatisfy { $0[10] == "EUR" } && table.rows.contains { $0[12] == "false" } && table.rows.contains { !$0[9].isEmpty })
        #expect(table.rows.filter { $0[9].hasSuffix(" EUR") }.allSatisfy { $0[12] == "true" })
        #expect(SalesPresentation.countries(selected.analysis, context: money, query: "missing").isEmpty && table.rows.count > 25)
        #expect(throws: TestIsolation.Failure.outsideRoot) { try SalesPresentation.writeAnalysisCSV(selected, context: money, to: root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("synthetic-rejected.csv")) }
        let (session, databaseRoot) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: databaseRoot) }
        let account = try #require(try await session.accounts().first)
        let before = try await session.salesFileRecords(account: account, appId: "1000000001").map(\.json)
        let apps = try await session.salesPortfolio(); #expect(apps.count == 2 && apps.first { $0.appId == "1000000001" }?.unavailable == false)
        #expect(apps.first { $0.appId == "1000000002" }?.unavailable == true && apps.first { $0.appId == "1000000002" }?.periods.isEmpty == true)
        _ = try await session.salesPresentation(account: account, appId: "1000000001")
        let after = try await session.salesFileRecords(account: account, appId: "1000000001").map(\.json)
        #expect(before == after)
    }
    @Test func referenceCurrencyReadsRecheckTheScopedAccountAfterFetch() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), selected = try prepared(try #require(try array(golden()["cases"]).first))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let primaryHost = "sales-money-primary.example.test", backupHost = "sales-money-backup.example.test"
        var sources = PricingSources(); sources.configuration = configuration
        sources.frankfurter = URL(string: "https://\(primaryHost)/rates")!; sources.exchangeRates = URL(string: "https://\(backupHost)/rates")!
        StubProtocol.handle(primaryHost) { _ in (200, [:], Data(#"[{"base":"USD","quote":"SEK","date":"2026-02-28","rate":10}]"#.utf8)) }
        StubProtocol.handle(backupHost) { _ in (503, [:], Data()) }
        let loaded = try await session.salesMoney(account: account, appId: "1000000001", periods: selected, sources: sources, now: Date(timeIntervalSince1970: 1_772_366_400))
        #expect(loaded.currency == "USD" && loaded.rates["SEK"]?.rate == "10")
        try await session.setDisplayCurrency("EUR")
        StubProtocol.handle(primaryHost) { _ in
            do {
                let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
                let changed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
                try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] }
            } catch { Issue.record("Synthetic account scope change failed.") }
            return (503, [:], Data())
        }
        await #expect(throws: SalesFileFailure.scope) { try await session.salesMoney(account: account, appId: "1000000001", periods: selected, sources: sources) }
    }
}
