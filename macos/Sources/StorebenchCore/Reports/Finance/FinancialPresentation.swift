import Foundation

/// Validated fiscal periods and original currency amounts for Finance presentation.
public enum FinancialPresentation {
    public struct Fact: Sendable, Identifiable, Equatable, Codable {
        public let territory: String, paid: Int, returned: Int, other: Int, proceeds: [ReportMoney.Amount]
        public var id: String { territory }
    }
    public struct Period: Sendable, Identifiable, Equatable, Codable {
        public let key: String, basis: String, region: String, beginDate: String, endDate: String, importedAt: String, rows: [Fact]
        public var id: String { key }
        public var dateKey: String { "\(beginDate):\(endDate)" }
        public init(_ value: JSONText) throws {
            guard let key = value["key"]?.text, let basis = value["basis"]?.text, let region = value["region"]?.text,
                  let begin = value["beginDate"]?.text, let end = value["endDate"]?.text, let stamp = value["importedAt"]?.text,
                  case .array(let rows)? = value["rows"] else { throw FinanceFailure.format }
            self.key = key; self.basis = basis; self.region = region; self.beginDate = begin; self.endDate = end; self.importedAt = stamp
            self.rows = try rows.map { row in
                guard let territory = row["territory"]?.text, case .object(let proceeds)? = row["proceeds"] else { throw FinanceFailure.format }
                let amounts = try proceeds.map { currency, value in
                    guard let amount = value.text else { throw FinanceFailure.format }; return ReportMoney.Amount(currency: currency, amount: amount)
                }
                return Fact(territory: territory, paid: try Self.units(row["paid"]), returned: try Self.units(row["returned"]), other: try Self.units(row["other"]), proceeds: amounts)
            }
            try FinancialPresentation.validate([self])
        }
        static func units(_ value: JSONText?) throws -> Int {
            guard case .number(let number)? = value, number.isFinite, number.rounded() == number, abs(number) <= 9_007_199_254_740_991 else { throw FinanceFailure.format }; return Int(number)
        }
        init(report: FinancialReport, rows: [Fact]) {
            key = report.key; basis = report.basis; region = report.region; beginDate = report.beginDate; endDate = report.endDate; importedAt = report.importedAt; self.rows = rows
        }
    }
    public struct Summary: Sendable {
        public let rows: [Fact], paid: Int, returned: Int, other: Int, net: Int, proceeds: [ReportMoney.Amount]
    }
    public enum Sort: String, CaseIterable, Sendable { case territory, paid, returned, net, proceeds, estimate }
    public enum CurrencySort: String, CaseIterable, Sendable { case currency, amount }
    static func add(_ a: Int, _ b: Int) throws -> Int {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow, result.partialValue >= -9_007_199_254_740_991, result.partialValue <= 9_007_199_254_740_991 else { throw FinanceFailure.format }; return result.partialValue
    }
    static func validate(_ periods: [Period]) throws {
        guard Set(periods.map(\.basis)).count <= 1 else { throw FinanceFailure.overlap }
        var keys = Set<String>(), units = 0
        for period in periods {
            let expectedBasis = period.region == "ZZ" ? "consolidated" : period.region == "Z1" ? "detailed" : "regional"
            guard FinancialReports.downloadRegions.contains(period.region), period.basis == expectedBasis,
                  period.key == "\(period.beginDate):\(period.endDate):\(period.region)", keys.insert(period.key).inserted,
                  ReportTables.validDate(period.beginDate), ReportTables.validDate(period.endDate), period.beginDate <= period.endDate,
                  let first = ReportTables.dayFormat.date(from: period.beginDate), let last = ReportTables.dayFormat.date(from: period.endDate), last.timeIntervalSince(first) <= 40 * 86_400,
                  ReportTimestamps.valid(period.importedAt), Set(period.rows.map(\.territory)).count == period.rows.count else { throw FinanceFailure.format }
            for row in period.rows {
                guard Territories.alpha3.values.contains(row.territory), row.paid >= 0, row.returned >= 0, row.other >= -9_007_199_254_740_991,
                      row.other <= 9_007_199_254_740_991, Set(row.proceeds.map(\.currency)).count == row.proceeds.count,
                      row.proceeds.allSatisfy({ $0.currency.range(of: #"\A[A-Z]{3}\z"#, options: .regularExpression) != nil && ReportDecimal($0.amount) != nil }) else { throw FinanceFailure.format }
                units = try add(units, row.paid); units = try add(units, row.returned); units = try add(units, abs(row.other))
            }
        }
    }
    /// Report validation precedes source projection, including direct-app attribution and fiscal overlap checks.
    public static func prepare(_ reports: [FinancialReport]) throws -> [Period] {
        let checked = try reports.map { report in
            guard let column = report.source.columns.firstIndex(of: "Apple Identifier"), let first = report.source.rows.first, first.count == report.source.columns.count else { throw FinanceFailure.format }
            let value = try FinancialReports.fromTable(report.source, scope: report.region, appId: first[column], importedAt: report.importedAt)
            guard value.key == report.key, value.basis == report.basis, value.source.rows.count == report.source.rows.count else { throw FinanceFailure.format }; return value
        }
        try FinancialReports.check(checked)
        return checked.sorted { $0.key < $1.key }.map { report in
            let positions = { (name: String) in report.source.columns.firstIndex(of: name)! }
            let country = positions("Country of Sale"), quantity = positions("Quantity"), product = positions("Product Type Identifier"), price = positions("Customer Price"), currency = positions("Partner Share Currency"), amount = positions("Extended Partner Share")
            var order: [String] = [], counts: [String: (paid: Int, returned: Int, other: Int)] = [:], currencies: [String: [String]] = [:], money: [String: [String: ReportDecimal]] = [:]
            for row in report.source.rows {
                let territory = Territories.alpha3[row[country]]!, units = Int(row[quantity])!
                if counts[territory] == nil { order.append(territory); counts[territory] = (0, 0, 0) }
                if FinancialReports.purchases.contains(row[product]), FinancialReports.money(row[price])! != 0 {
                    if units > 0 { counts[territory]!.paid += units } else { counts[territory]!.returned -= units }
                } else { counts[territory]!.other += units }
                if money[territory]?[row[currency]] == nil { currencies[territory, default: []].append(row[currency]) }
                money[territory, default: [:]][row[currency]] = (money[territory]?[row[currency]] ?? .zero).adding(ReportDecimal(row[amount])!)
            }
            return Period(report: report, rows: order.map { code in Fact(territory: code, paid: counts[code]!.paid, returned: counts[code]!.returned, other: counts[code]!.other,
                proceeds: currencies[code]!.map { ReportMoney.Amount(currency: $0, amount: money[code]![$0]!.text) }) })
        }
    }
    public static func summary(_ periods: [Period]) throws -> Summary {
        try validate(periods)
        var counts: [String: (paid: Int, returned: Int, other: Int)] = [:], currencies: [String: [String]] = [:], amounts: [String: [String: ReportDecimal]] = [:], totals: [String: ReportDecimal] = [:]
        for period in periods { for row in period.rows {
            let previous = counts[row.territory] ?? (0, 0, 0)
            counts[row.territory] = (try add(previous.0, row.paid), try add(previous.1, row.returned), try add(previous.2, row.other))
            for item in row.proceeds {
                if amounts[row.territory]?[item.currency] == nil { currencies[row.territory, default: []].append(item.currency) }
                let value = ReportDecimal(item.amount)!
                amounts[row.territory, default: [:]][item.currency] = (amounts[row.territory]?[item.currency] ?? .zero).adding(value)
                totals[item.currency] = (totals[item.currency] ?? .zero).adding(value)
            }
        } }
        let rows = counts.keys.map { code in Fact(territory: code, paid: counts[code]!.paid, returned: counts[code]!.returned, other: counts[code]!.other,
            proceeds: (currencies[code] ?? []).map { ReportMoney.Amount(currency: $0, amount: amounts[code]![$0]!.text) }) }.sorted { $0.paid == $1.paid ? $0.territory < $1.territory : $0.paid > $1.paid }
        var paid = 0, returned = 0, other = 0
        for row in rows { paid = try add(paid, row.paid); returned = try add(returned, row.returned); other = try add(other, row.other) }
        return Summary(rows: rows, paid: paid, returned: returned, other: other, net: try add(paid, -returned), proceeds: totals.keys.sorted().map { ReportMoney.Amount(currency: $0, amount: totals[$0]!.text) })
    }
    public static func territories(_ summary: Summary, context: ReportMoney.Context, query: String = "", sort: Sort? = nil, descending: Bool = false) -> [Fact] {
        let search = TextSemantics.trim(query).lowercased()
        let rows = summary.rows.filter { search.isEmpty || ($0.territory + " " + Territories.name($0.territory)).lowercased().range(of: search, options: .literal) != nil }
        guard let sort else { return rows }
        func value(_ row: Fact) -> (text: String?, number: Double?) {
            switch sort {
            case .territory: return (Territories.name(row.territory), nil)
            case .proceeds: return (row.proceeds.map { "\($0.currency) \($0.amount)" }.joined(separator: " · "), nil)
            case .paid: return (nil, Double(row.paid))
            case .returned: return (nil, Double(row.returned))
            case .net: return (nil, Double(row.paid - row.returned))
            case .estimate:
                let result = ReportMoney.convert(row.proceeds, context: context)
                return (nil, result.complete ? result.amount.flatMap(Double.init) : nil)
            }
        }
        return rows.enumerated().map { (element: $0.element, offset: $0.offset, value: value($0.element)) }.sorted { left, right in
            let a = left.value, b = right.value
            if a.text == nil && a.number == nil { return b.text == nil && b.number == nil ? left.offset < right.offset : false }
            if b.text == nil && b.number == nil { return true }
            let compared: ComparisonResult = a.text.map { $0.compare(b.text!, options: [.numeric, .caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")) } ?? (a.number! < b.number! ? .orderedAscending : a.number! > b.number! ? .orderedDescending : .orderedSame)
            return compared == .orderedSame ? left.offset < right.offset : descending ? compared == .orderedDescending : compared == .orderedAscending
        }.map(\.element)
    }
    public static func currencies(_ summary: Summary, sort: CurrencySort? = nil, descending: Bool = false) -> [ReportMoney.Amount] {
        guard let sort else { return summary.proceeds }
        return summary.proceeds.enumerated().sorted { a, b in
            let compared: ComparisonResult
            if sort == .currency { compared = a.element.currency.compare(b.element.currency, options: .numeric, locale: Locale(identifier: "en")) }
            else { let left = Double(a.element.amount) ?? 0, right = Double(b.element.amount) ?? 0; compared = left < right ? .orderedAscending : left > right ? .orderedDescending : .orderedSame }
            return compared == .orderedSame ? a.offset < b.offset : descending ? compared == .orderedDescending : compared == .orderedAscending
        }.map(\.element)
    }
    public static func analysisCSV(_ periods: [Period], context: ReportMoney.Context) throws -> Data {
        let summary = try summary(periods), dates = Set(periods.map { "\($0.beginDate)/\($0.endDate)" }).sorted().joined(separator: "; ")
        let columns = ["report_basis", "fiscal_periods", "territory", "paid_units", "returned_units", "net_paid_units", "other_net_units", "reported_proceeds", "display_currency", "estimated_proceeds", "conversion_complete", "rate_dates"]
        let rows = summary.rows.map { row -> [String] in
            let estimate = ReportMoney.convert(row.proceeds, context: context)
            return [periods.first?.basis ?? "", dates, row.territory, String(row.paid), String(row.returned), String(row.paid - row.returned), String(row.other),
                    row.proceeds.map { "\($0.amount) \($0.currency)" }.joined(separator: "; "), context.currency, estimate.amount ?? "", String(estimate.complete), estimate.dates.joined(separator: "; ")]
        }
        // Derived date lists can span the whole history; upload cell limits do not truncate this generated analysis.
        return Data(Delimited.write(Delimited.Table(columns: columns, rows: rows.map { $0.map(ReportTables.spreadsheetCell) })).utf8)
    }
    public static func writeAnalysisCSV(_ periods: [Period], context: ReportMoney.Context, to url: URL) throws {
        let bytes = try analysisCSV(periods, context: context)
        try ReportFiles.atomicStream(to: url) { try $0(bytes) }
    }
}

extension WorkspaceSession {
    public func financialMoney(account: Account, appId: String, periods: [FinancialPresentation.Period], sources: PricingSources = PricingSources(), now: Date = Date()) async throws -> ReportMoney.Context {
        try financialFileScope(account, appId: appId); try Task.checkCancellation()
        let currency = try displayCurrency(), quotes = Set(periods.flatMap(\.rows).flatMap(\.proceeds).map(\.currency)).sorted()
        let snapshot = try await fxRates(base: currency, quotes: quotes, sources: sources, now: now)
        try financialFileScope(account, appId: appId); try Task.checkCancellation()
        return ReportMoney.Context(currency: currency, rates: snapshot.rates.mapValues { ReportMoney.Rate(rate: $0.rate, date: $0.date) }, staleCurrencies: snapshot.stale)
    }
}
