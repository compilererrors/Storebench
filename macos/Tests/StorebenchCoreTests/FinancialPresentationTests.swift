import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct FinancialPresentationTests {
    init() throws { _ = try TestIsolation.require() }
    func golden() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/financial-presentation.json"))) }
    func periods(_ value: JSONText) throws -> [FinancialPresentation.Period] {
        guard case .array(let values) = value else { throw FinanceFailure.format }; return try values.map(FinancialPresentation.Period.init)
    }
    func context(_ value: JSONText) throws -> ReportMoney.Context {
        guard let currency = value["currency"]?.text, case .object(let values)? = value["fx"]?["rates"] else { throw FinanceFailure.format }
        let pairs = try values.map { code, value in
            guard let rate = value["rate"]?.text, let date = value["date"]?.text else { throw FinanceFailure.format }; return (code, ReportMoney.Rate(rate: rate, date: date))
        }
        return ReportMoney.Context(currency: currency, rates: Dictionary(uniqueKeysWithValues: pairs))
    }
    func factJSON(_ row: FinancialPresentation.Fact) -> JSONText {
        .object([("territory", .string(row.territory)), ("paid", .number(Double(row.paid))), ("returned", .number(Double(row.returned))), ("other", .number(Double(row.other))), ("proceeds", .object(row.proceeds.map { ($0.currency, .string($0.amount)) }))])
    }
    func periodJSON(_ period: FinancialPresentation.Period) -> JSONText {
        .object([("key", .string(period.key)), ("basis", .string(period.basis)), ("region", .string(period.region)), ("beginDate", .string(period.beginDate)), ("endDate", .string(period.endDate)), ("importedAt", .string(period.importedAt)), ("rows", .array(period.rows.map(factJSON)))])
    }
    func summaryJSON(_ summary: FinancialPresentation.Summary) -> JSONText {
        .object([("rows", .array(summary.rows.map(factJSON))), ("paid", .number(Double(summary.paid))), ("returned", .number(Double(summary.returned))), ("other", .number(Double(summary.other))), ("net", .number(Double(summary.net))),
                 ("proceeds", .array(summary.proceeds.map { .object([("currency", .string($0.currency)), ("amount", .string($0.amount))]) }))])
    }
    func conversionJSON(_ value: ReportMoney.Conversion) -> JSONText {
        .object([("amount", value.amount.map(JSONText.string) ?? .null), ("missing", .array(value.missing.map(JSONText.string))), ("dates", .array(value.dates.map(JSONText.string))), ("complete", .bool(value.complete))])
    }
    @Test func fiscalSourceProjectionTotalsAndAnalysisBytesMatchEveryWebDataset() throws {
        let value = try golden(), reportsJSON = try #require(value["reports"]), periodsJSON = try #require(value["periods"])
        let reports = try JSONDecoder().decode([FinancialReport].self, from: reportsJSON.data)
        let prepared = try FinancialPresentation.prepare(reports)
        #expect(JSONText.array(prepared.map(periodJSON)).data == periodsJSON.data)
        #expect(throws: FinanceFailure.overlap) { try FinancialPresentation.summary(prepared) }
        guard case .array(let cases)? = value["cases"] else { throw FinanceFailure.format }
        for vector in cases {
            let rawPeriods = try #require(vector["periods"]), rawContext = try #require(vector["context"])
            let selected = try periods(rawPeriods), money = try context(rawContext), summary = try FinancialPresentation.summary(selected)
            #expect(summaryJSON(summary).data == vector["summary"]?.data)
            #expect(conversionJSON(ReportMoney.convert(summary.proceeds, context: money)).data == vector["conversion"]?.data)
            #expect(try FinancialPresentation.analysisCSV(selected, context: money) == Data(vector["csv"]!.text!.utf8))
        }
    }
    @Test func decimalQuotesRoundingPrecisionReturnsZerosAndCurrencyDigitsMatchTheWeb() throws {
        let value = try golden()
        guard case .array(let vectors)? = value["conversions"], case .array(let labels)? = value["labels"] else { throw FinanceFailure.format }
        #expect(vectors.count > 400)
        for vector in vectors {
            guard case .array(let rawAmounts)? = vector["amounts"] else { throw FinanceFailure.format }
            let rawContext = try #require(vector["context"]), money = try context(rawContext)
            let amounts = rawAmounts.map { ReportMoney.Amount(currency: $0["currency"]!.text!, amount: $0["amount"]!.text!) }
            #expect(conversionJSON(ReportMoney.convert(amounts, context: money)).data == vector["expected"]?.data, "Synthetic conversion: \(vector["id"]!.text!)")
        }
        for vector in labels { #expect(ReportMoney.label(vector["amount"]?.text, currency: vector["currency"]!.text!) == vector["expected"]?.text) }
    }
    @Test func searchesSixSortColumnsAndCurrencyOrderingMatchTheWebWithoutChangingTotals() throws {
        guard case .array(let cases)? = try golden()["cases"] else { throw FinanceFailure.format }
        for vector in cases {
            let rawPeriods = try #require(vector["periods"]), rawContext = try #require(vector["context"])
            let summary = try FinancialPresentation.summary(periods(rawPeriods)), money = try context(rawContext)
            guard case .array(let sorts)? = vector["sorts"], case .array(let currencies)? = vector["currencySorts"] else { throw FinanceFailure.format }
            for sort in sorts {
                let rows = FinancialPresentation.territories(summary, context: money, query: sort["query"]!.text!, sort: FinancialPresentation.Sort(rawValue: sort["key"]!.text!), descending: sort["direction"] == .string("descending"))
                #expect(JSONText.array(rows.map { .string($0.territory) }).data == sort["expected"]?.data)
            }
            for sort in currencies {
                let rows = FinancialPresentation.currencies(summary, sort: FinancialPresentation.CurrencySort(rawValue: sort["key"]!.text!), descending: sort["direction"] == .string("descending"))
                #expect(JSONText.array(rows.map { .string($0.currency) }).data == sort["expected"]?.data)
            }
        }
    }
    @Test func malformedFactsDatesDatasetsAndUnsafeUnitsCannotProduceATotal() throws {
        guard case .array(let values)? = try golden()["periods"], let first = values.first, case .array(let rows)? = first["rows"], let row = rows.first else { throw FinanceFailure.format }
        func replace(_ value: JSONText, _ field: String, _ next: JSONText) -> JSONText {
            guard case .object(let fields) = value else { return value }; return .object(fields.map { ($0.0, $0.0 == field ? next : $0.1) })
        }
        for (field, next) in [("paid", JSONText.number(-1)), ("returned", .number(0.5)), ("other", .number(-9_007_199_254_740_992)), ("territory", .string("UNKNOWN")), ("paid", .bool(true)), ("proceeds", .object([("USD", .string("1e3"))]))] {
            #expect(throws: FinanceFailure.format) { try FinancialPresentation.Period(replace(first, "rows", .array([replace(row, field, next)]))) }
        }
        for (field, next) in [("basis", JSONText.string("unsupported")), ("key", .string("synthetic-wrong-key")), ("endDate", .string("2026-02-30")), ("importedAt", .string("invalid")), ("rows", .array([row, row]))] {
            #expect(throws: FinanceFailure.format) { try FinancialPresentation.Period(replace(first, field, next)) }
        }
        let period = try FinancialPresentation.Period(first)
        #expect(throws: FinanceFailure.format) { try FinancialPresentation.summary([period, period]) }
    }
    @Test func analysisExportKeepsAllSelectedTerritoriesAndUsesGuardedAtomicDestination() throws {
        guard case .array(let cases)? = try golden()["cases"], let vector = cases.first else { throw FinanceFailure.format }
        let rawPeriods = try #require(vector["periods"]), rawContext = try #require(vector["context"])
        let selected = try periods(rawPeriods), money = try context(rawContext)
        let root = try TestIsolation.require().appendingPathComponent("financial-analysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("synthetic-analysis.csv"); try Data("Synthetic earlier export".utf8).write(to: target)
        try FinancialPresentation.writeAnalysisCSV(selected, context: money, to: target)
        #expect(try Data(contentsOf: target) == Data(vector["csv"]!.text!.utf8))
        let summary = try FinancialPresentation.summary(selected)
        #expect(FinancialPresentation.territories(summary, context: money, query: "missing").isEmpty && summary.rows.count == 2)
        #expect(try Delimited.parse(String(decoding: Data(contentsOf: target), as: UTF8.self)).rows.count == summary.rows.count)
        #expect(throws: TestIsolation.Failure.outsideRoot) { try FinancialPresentation.writeAnalysisCSV(selected, context: money, to: root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("synthetic-guard-rejected.csv")) }
    }
    @Test func datedCurrencyReadsReuseCacheMarkStaleQuotesAndRecheckTheAccountAfterFetch() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), appId = "1000000001", value = try golden()
        guard case .array(let cases)? = value["cases"], let first = cases.first else { throw FinanceFailure.format }
        let rawPeriods = try #require(first["periods"]), selected = try periods(rawPeriods), now = Date(timeIntervalSince1970: 1_772_366_400)
        let primaryHost = "financial-money-primary.example.test", backupHost = "financial-money-backup.example.test"
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        var primary = PricingSources(); primary.configuration = configuration
        primary.frankfurter = URL(string: "https://\(primaryHost)/rates")!; primary.exchangeRates = URL(string: "https://\(backupHost)/latest")!
        StubProtocol.handle(primaryHost) { _ in (200, [:], Data(#"[{"base":"USD","quote":"SEK","date":"2026-02-28","rate":10}]"#.utf8)) }
        StubProtocol.handle(backupHost) { _ in (503, [:], Data()) }
        let loaded = try await session.financialMoney(account: account, appId: appId, periods: selected, sources: primary, now: now)
        #expect(loaded.rates["SEK"]?.rate == "10" && loaded.staleCurrencies.isEmpty)
        StubProtocol.handle(primaryHost) { _ in (503, [:], Data()) }
        let cached = try await session.financialMoney(account: account, appId: appId, periods: selected, sources: primary, now: now)
        #expect(cached.rates["SEK"] == loaded.rates["SEK"] && cached.staleCurrencies.isEmpty)
        #expect(StubProtocol.requests(primaryHost).isEmpty && StubProtocol.requests(backupHost).isEmpty)
        let stale = try await session.financialMoney(account: account, appId: appId, periods: selected, sources: primary, now: now.addingTimeInterval(7 * 3_600))
        #expect(stale.rates["SEK"] == loaded.rates["SEK"] && stale.staleCurrencies == ["SEK"])
        try await session.setDisplayCurrency("JPY")
        StubProtocol.handle(backupHost) { request in
            #expect(request.url?.path == "/latest/JPY")
            return (200, [:], Data(#"{"result":"success","base_code":"JPY","time_last_update_unix":1772236800,"rates":{"USD":0.01,"SEK":0.1}}"#.utf8))
        }
        let alternate = try await session.financialMoney(account: account, appId: appId, periods: selected, sources: primary, now: now)
        let summary = try FinancialPresentation.summary(selected)
        #expect(ReportMoney.convert(summary.proceeds, context: alternate).amount == "16800")
        try await session.setDisplayCurrency("KWD")
        StubProtocol.handle(backupHost) { _ in (503, [:], Data()) }
        StubProtocol.handle(primaryHost) { _ in
            do {
                let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
                let changed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
                try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] }
            } catch { Issue.record("Synthetic account change failed.") }
            return (503, [:], Data())
        }
        await #expect(throws: FinanceFailure.scope) { try await session.financialMoney(account: account, appId: appId, periods: selected, sources: primary, now: now) }
    }
    @Test func analysisKeepsEveryFiscalDateWhenHistoryExceedsAnUploadCellLimit() throws {
        guard case .array(let values)? = try golden()["periods"], let first = values.first, case .object(let fields) = first else { throw FinanceFailure.format }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let selected = try (0..<540).map { index in
            let start = calendar.date(from: DateComponents(year: 1980 + index / 12, month: index % 12 + 1, day: 1))!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!.addingTimeInterval(-86_400)
            let beginDate = ReportTables.dayFormat.string(from: start), endDate = ReportTables.dayFormat.string(from: end)
            return try FinancialPresentation.Period(.object(fields.map { key, value in
                (key, key == "beginDate" ? .string(beginDate) : key == "endDate" ? .string(endDate) : key == "key" ? .string("\(beginDate):\(endDate):\(first["region"]!.text!)") : value)
            }))
        }
        let csv = try FinancialPresentation.analysisCSV(selected, context: ReportMoney.Context(currency: "USD")), table = try Delimited.parse(String(decoding: csv, as: UTF8.self))
        let column = try #require(table.columns.firstIndex(of: "fiscal_periods")), dates = try #require(table.rows.first?[column])
        #expect(dates.utf16.count > 10_000 && dates.components(separatedBy: "; ").count == 540)
        #expect(dates.hasPrefix("1980-01-01/1980-01-31") && dates.hasSuffix("2024-12-01/2024-12-31"))
    }
}
