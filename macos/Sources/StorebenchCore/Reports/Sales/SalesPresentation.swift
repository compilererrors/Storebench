import Foundation

public enum SalesPresentationFailure: Error, Equatable {
    case format, range, criteria, overflow
    public var message: String {
        switch self {
        case .format: "Saved sales figures could not be validated. Read the original reports again."
        case .range: "Choose valid start and end dates in order."
        case .criteria: "Use whole numbers: purchases from 1 to 1,000,000 and country share from 1 to 100%. Suggestions are hidden until the criteria are valid."
        case .overflow: "Imported sales exceed the supported unit count."
        }
    }
}

/// Calculated Sales facts only. Original report rows remain in the encrypted report store.
public enum SalesPresentation {
    public struct Criteria: Sendable, Equatable {
        public let minimumPurchases, minimumCountryPurchases, minimumShare: Int
        public static let defaults = try! Criteria(minimumPurchases: 30, minimumCountryPurchases: 20, minimumShare: 40)
        public init(minimumPurchases: Int, minimumCountryPurchases: Int, minimumShare: Int) throws {
            guard (1...1_000_000).contains(minimumPurchases), (1...1_000_000).contains(minimumCountryPurchases), (1...100).contains(minimumShare) else { throw SalesPresentationFailure.criteria }
            self.minimumPurchases = minimumPurchases; self.minimumCountryPurchases = minimumCountryPurchases; self.minimumShare = minimumShare
        }
        public init(purchases: String, country: String, share: String) throws {
            let values = try [purchases, country, share].map { value in
                guard value.range(of: #"\A[0-9]{1,7}\z"#, options: .regularExpression) != nil, let number = Int(value) else { throw SalesPresentationFailure.criteria }; return number
            }
            try self.init(minimumPurchases: values[0], minimumCountryPurchases: values[1], minimumShare: values[2])
        }
        var json: JSONText { .object([("minimumPurchases", .number(Double(minimumPurchases))), ("minimumCountryPurchases", .number(Double(minimumCountryPurchases))), ("minimumShare", .number(Double(minimumShare)))]) }
    }
    public struct Country: Sendable, Identifiable, Equatable, Codable {
        public let code: String
        public var paid = 0, refunds = 0, free = 0, inAppPurchases = 0, inAppRefunds = 0
        public var proceeds: [ReportMoney.Amount] = []
        public var id: String { code }
        public var name: String { Territories.name(code) }
        func json(named: Bool = false) -> JSONText {
            var fields: [(String, JSONText)] = [("code", .string(code))]
            if named { fields.append(("name", .string(name))) }
            fields += [("paid", .number(Double(paid))), ("refunds", .number(Double(refunds))), ("free", .number(Double(free))),
                       ("inAppPurchases", .number(Double(inAppPurchases))), ("inAppRefunds", .number(Double(inAppRefunds))),
                       ("proceeds", .object(proceeds.map { ($0.currency, .string($0.amount)) }))]
            return .object(fields)
        }
    }
    public struct Period: Sendable, Identifiable, Equatable, Codable {
        public let beginDate, endDate, importedAt: String
        public let hasSource, noSales, detailsComplete, moneyComplete, productsComplete: Bool
        public let rows: [Country]
        public var id: String { "\(beginDate):\(endDate)" }
        var json: JSONText {
            var fields: [(String, JSONText)] = [("beginDate", .string(beginDate)), ("endDate", .string(endDate)), ("importedAt", .string(importedAt)), ("hasSource", .bool(hasSource))]
            if noSales { fields.append(("noSales", .bool(true))) }
            fields += [("detailsComplete", .bool(detailsComplete)), ("moneyComplete", .bool(moneyComplete)), ("productsComplete", .bool(productsComplete)), ("rows", .array(rows.map { $0.json() }))]
            return .object(fields)
        }
    }
    public struct Coverage: Sendable {
        public let beginDate, endDate: String
        public let periods: [Period]
        public let hasGaps: Bool, coveredDays: Int
        var json: JSONText { .object([("beginDate", .string(beginDate)), ("endDate", .string(endDate)), ("periods", .array(periods.map { .object([("beginDate", .string($0.beginDate)), ("endDate", .string($0.endDate)), ("importedAt", .string($0.importedAt)), ("hasSource", .bool($0.hasSource))]) })), ("hasGaps", .bool(hasGaps)), ("coveredDays", .number(Double(coveredDays)))]) }
    }
    public struct Insight: Sendable, Identifiable {
        public let id, title, evidence, suggestion: String
        public let section: String?
        var json: JSONText {
            var fields: [(String, JSONText)] = [("id", .string(id)), ("title", .string(title)), ("evidence", .string(evidence)), ("suggestion", .string(suggestion))]
            if let section { fields.append(("section", .string(section))) }; return .object(fields)
        }
    }
    public struct Trend: Sendable, Identifiable {
        public let beginDate, endDate: String
        public let paid: Int, free: Int?, refunds: Int?, inAppPurchases: Int?
        public var id: String { "\(beginDate):\(endDate)" }
        var json: JSONText { .object([("beginDate", .string(beginDate)), ("endDate", .string(endDate)), ("paid", .number(Double(paid))), ("free", SalesPresentation.number(free)), ("refunds", SalesPresentation.number(refunds)), ("inAppPurchases", SalesPresentation.number(inAppPurchases))]) }
    }
    public struct Analysis: Sendable {
        public let rows: [Country], paid: Int, refunds: Int?, free: Int?, inAppPurchases: Int?, inAppRefunds: Int?
        public let proceeds: [ReportMoney.Amount], moneyComplete: Bool, productsComplete: Bool
        public let coverage: Coverage?, criteria: Criteria, insights: [Insight], trend: [Trend], comparable: Bool
        var json: JSONText { .object([("rows", .array(rows.map { $0.json(named: true) })), ("paid", .number(Double(paid))), ("refunds", SalesPresentation.number(refunds)), ("free", SalesPresentation.number(free)), ("inAppPurchases", SalesPresentation.number(inAppPurchases)), ("inAppRefunds", SalesPresentation.number(inAppRefunds)), ("proceeds", .array(proceeds.map { .object([("currency", .string($0.currency)), ("amount", .string($0.amount))]) })), ("moneyComplete", .bool(moneyComplete)), ("productsComplete", .bool(productsComplete)), ("coverage", coverage?.json ?? .null), ("criteria", criteria.json), ("insights", .array(insights.map(\.json))), ("trend", .array(trend.map(\.json))), ("comparable", .bool(comparable))]) }
    }
    static let inAppTypes: Set<String> = ["FI1", "IA1", "IA1-M", "IA9", "IA9-M", "IAY", "IAY-M", "IAC", "IAC-M"]
    static func number(_ value: Int?) -> JSONText { value.map { .number(Double($0)) } ?? .null }
    static func add(_ a: Int, _ b: Int) throws -> Int {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow, result.partialValue >= 0, result.partialValue <= SalesFileFormats.maximumUnits else { throw SalesPresentationFailure.overflow }; return result.partialValue
    }
    static func sum(_ rows: [Country], _ key: KeyPath<Country, Int>) throws -> Int { try rows.reduce(0) { try add($0, $1[keyPath: key]) } }
    static func days(_ first: String, _ last: String) throws -> Int {
        guard let a = PeriodDates.number(first), let b = PeriodDates.number(last), a <= b else { throw SalesPresentationFailure.range }
        return b - a + 1
    }
    static func addingMoney(_ amounts: inout [ReportMoney.Amount], currency: String, value: ReportDecimal) {
        if let index = amounts.firstIndex(where: { $0.currency == currency }) {
            amounts[index] = .init(currency: currency, amount: (ReportDecimal(amounts[index].amount) ?? .zero).adding(value).plain)
        } else { amounts.append(.init(currency: currency, amount: value.plain)) }
    }
    public static func prepare(_ records: [SalesRecord], accountId: String, appId: String) throws -> [Period] {
        try SalesFileFormats.validate(records, accountId: accountId, appId: appId)
        return try records.sorted { $0.beginDate < $1.beginDate }.compactMap { report in
            if report.noSales == true { return Period(beginDate: report.beginDate, endDate: report.endDate, importedAt: report.importedAt, hasSource: false, noSales: true, detailsComplete: true, moneyComplete: true, productsComplete: true, rows: []) }
            var rows: [Country] = [], details = true, moneyComplete = true
            let verified = Set(report.productScope?.ids ?? [])
            if let source = report.source {
                let product = source.columns.firstIndex(of: "Apple Identifier")!, type = source.columns.firstIndex(of: "Product Type Identifier")!
                guard source.rows.contains(where: { verified.contains($0[product]) || $0[product] == appId && !inAppTypes.contains($0[type]) && $0[type] != "IA3" }) else { return nil }
            }
            // Original paid rows preserve Apple's country order; summary-only countries have no money ordering.
            var order: [String] = []
            if let source = report.source {
                let country = source.columns.firstIndex(of: "Country Code")!, type = source.columns.firstIndex(of: "Product Type Identifier")!, units = source.columns.firstIndex(of: "Units")!, price = source.columns.firstIndex(of: "Customer Price")!
                for row in source.rows {
                    if SalesReports.appPurchaseTypes.contains(row[type]), (Double(row[units]) ?? 0) > 0, (Double(row[price]) ?? 0) != 0,
                       let code = Territories.alpha3[row[country]], report.unitsByTerritory[code] != nil, !order.contains(code) { order.append(code) }
                }
            }
            order += report.unitsByTerritory.keys.sorted().filter { !order.contains($0) }
            rows = order.map { var row = Country(code: $0); row.paid = report.unitsByTerritory[$0]!; return row }
            if let source = report.source {
                func column(_ name: String) -> Int? { source.columns.firstIndex(of: name) }
                let money = column("Developer Proceeds") ?? column("Developer Proceeds (per unit)"), currency = column("Currency of Proceeds")
                let type = column("Product Type Identifier")!, units = column("Units")!, price = column("Customer Price")!, country = column("Country Code")!, product = column("Apple Identifier")!
                for values in source.rows {
                    let appPurchase = SalesReports.appPurchaseTypes.contains(values[type]), inApp = inAppTypes.contains(values[type])
                    if (inApp || values[type] == "IA3") && !verified.contains(values[product]) { moneyComplete = false; continue }
                    let amountText = money.map { values[$0] } ?? "", amount = ReportDecimal(amountText)
                    if !appPurchase && !inApp {
                        if (Double(values[price]) ?? .nan) != 0 || !amountText.isEmpty && (amount == nil || !amount!.isZero) { moneyComplete = false }; continue
                    }
                    guard let code = Territories.alpha3[values[country]], let quantity = Double(values[units]), quantity.isFinite, quantity.rounded() == quantity, abs(quantity) <= Double(SalesFileFormats.maximumUnits),
                          let customerPrice = Double(values[price]), customerPrice.isFinite else { details = false; moneyComplete = false; continue }
                    let count = Int(quantity)
                    let index = rows.firstIndex { $0.code == code } ?? rows.count
                    if index == rows.count { rows.append(Country(code: code)) }
                    if appPurchase && customerPrice != 0 && count < 0 { rows[index].refunds = try add(rows[index].refunds, -count) }
                    if appPurchase && customerPrice == 0 && count > 0 { rows[index].free = try add(rows[index].free, count) }
                    if inApp && customerPrice != 0 && count > 0 { rows[index].inAppPurchases = try add(rows[index].inAppPurchases, count) }
                    if inApp && customerPrice != 0 && count < 0 { rows[index].inAppRefunds = try add(rows[index].inAppRefunds, -count) }
                    if !amountText.isEmpty && amount == nil { moneyComplete = false }
                    if count == 0 && (customerPrice != 0 || amount != nil && !amount!.isZero) { moneyComplete = false }
                    else if count != 0 && (customerPrice != 0 || amount != nil && !amount!.isZero) {
                        guard let currency, let amount, values[currency].range(of: #"\A[A-Z]{3}\z"#, options: .regularExpression) != nil else { moneyComplete = false; continue }
                        addingMoney(&rows[index].proceeds, currency: values[currency], value: amount.multiplied(by: ReportDecimal(String(count))!))
                    }
                }
            } else { details = false; moneyComplete = false }
            return Period(beginDate: report.beginDate, endDate: report.endDate, importedAt: report.importedAt, hasSource: report.source != nil, noSales: false, detailsComplete: details,
                          moneyComplete: moneyComplete, productsComplete: report.source != nil && report.productScope?.complete == true, rows: rows)
        }
    }

    public static func analyze(_ periods: [Period], criteria: Criteria = .defaults) throws -> Analysis {
        let reports = periods.sorted { $0.beginDate < $1.beginDate }
        var countries: [Country] = [], proceeds: [ReportMoney.Amount] = [], coveredDays = 0, gaps = false
        for (index, report) in reports.enumerated() {
            coveredDays += try days(report.beginDate, report.endDate)
            if index > 0 {
                guard reports[index - 1].endDate < report.beginDate else { throw SalesPresentationFailure.format }
                let distance = try days(reports[index - 1].endDate, report.beginDate)
                gaps = gaps || distance != 2
            }
            for item in report.rows {
                let row = countries.firstIndex { $0.code == item.code } ?? countries.count
                if row == countries.count { countries.append(Country(code: item.code)) }
                countries[row].paid = try add(countries[row].paid, item.paid); countries[row].refunds = try add(countries[row].refunds, item.refunds); countries[row].free = try add(countries[row].free, item.free)
                countries[row].inAppPurchases = try add(countries[row].inAppPurchases, item.inAppPurchases); countries[row].inAppRefunds = try add(countries[row].inAppRefunds, item.inAppRefunds)
                for amount in item.proceeds {
                    guard let value = ReportDecimal(amount.amount) else { throw SalesPresentationFailure.format }
                    addingMoney(&countries[row].proceeds, currency: amount.currency, value: value); addingMoney(&proceeds, currency: amount.currency, value: value)
                }
            }
        }
        countries.sort { $0.paid == $1.paid ? $0.name.compare($1.name, locale: Locale(identifier: "en")) == .orderedAscending : $0.paid > $1.paid }
        let paid = try sum(countries, \.paid), refunds = try sum(countries, \.refunds), free = try sum(countries, \.free), inApp = try sum(countries, \.inAppPurchases), inAppRefunds = try sum(countries, \.inAppRefunds)
        let details = reports.allSatisfy(\.detailsComplete), products = !reports.isEmpty && reports.allSatisfy(\.productsComplete)
        let coverage = reports.first.map { Coverage(beginDate: $0.beginDate, endDate: reports.last!.endDate, periods: reports, hasGaps: gaps, coveredDays: coveredDays) }
        var insights: [Insight] = []
        func tip(_ id: String, _ title: String, _ evidence: String, _ suggestion: String, _ section: String? = nil) { insights.append(Insight(id: id, title: title, evidence: evidence, suggestion: suggestion, section: section)) }
        if gaps { tip("gaps", "Fill the reporting gaps", "Some days between the first and last imported period are missing.", "Import the missing periods before comparing trends. Missing reports do not mean zero sales.") }
        if paid < criteria.minimumPurchases { tip("sample", "Build a larger sample", "\(paid) paid app purchases in the selected reports; your minimum is \(criteria.minimumPurchases).", "Collect more reporting periods before drawing conclusions about countries or changing prices.") }
        else if let first = countries.first, first.paid >= criteria.minimumCountryPurchases, first.paid * 100 >= paid * criteria.minimumShare {
            let leaders = countries.filter { $0.paid == first.paid }, share = String(shareLabel(first.paid, total: paid).dropLast())
            if leaders.count == 1 { tip("concentration", "\(first.name) leads paid purchases", "\(first.paid) of \(paid) purchases (\(share)%) are in this storefront.", "Review listing language, screenshots and support for this market. Check other periods before deciding on an experiment.", "localizations") }
            else { tip("concentration", "Countries share the lead", "\(leaders.count) countries each have \(first.paid) of \(paid) paid purchases (\(share)%).", "Compare these countries in the table before prioritizing languages or screenshots. No single country leads this selection.", "localizations") }
        }
        if details && paid >= criteria.minimumPurchases && refunds >= 3 && Double(refunds) / Double(paid) >= 0.1 { tip("refunds", "Review refund activity", "\(refunds) paid units refunded alongside \(paid) purchases in these reports.", "Check support requests, reviews and recent releases. Refunds can relate to purchases outside these periods.") }
        let previous = reports.count >= 2 ? reports[reports.count - 2] : nil, latest = reports.last
        let comparable = try previous.map { before in try days(before.beginDate, before.endDate) == days(latest!.beginDate, latest!.endDate) && days(before.endDate, latest!.beginDate) == 2 } ?? false
        if comparable, let before = previous, let after = latest, try sum(before.rows, \.paid) >= criteria.minimumPurchases, try sum(after.rows, \.paid) >= criteria.minimumPurchases {
            if let growth = countries.first(where: { row in let a = before.rows.first { $0.code == row.code }?.paid ?? 0, b = after.rows.first { $0.code == row.code }?.paid ?? 0; return a >= 10 && b >= 20 && Double(b) >= Double(a) * 1.3 }) {
                tip("growth", "\(growth.name) increased", "\(before.rows.first { $0.code == growth.code }!.paid) → \(after.rows.first { $0.code == growth.code }!.paid) paid purchases across the last two adjacent \(try days(after.beginDate, after.endDate))-day reports.", "Compare release dates and marketing activity. Repeat the comparison before attributing the increase to a price or listing change.", "pricing")
            }
        }
        if !details { tip("summary", "More detail is available", "Some selected periods lack complete download and refund details.", "Import the original Apple reports for refunds, free downloads and reported proceeds.") }
        let trend = try reports.map { report in Trend(beginDate: report.beginDate, endDate: report.endDate, paid: try sum(report.rows, \.paid), free: report.detailsComplete ? try sum(report.rows, \.free) : nil,
                                                     refunds: report.detailsComplete ? try sum(report.rows, \.refunds) : nil, inAppPurchases: report.detailsComplete && report.productsComplete ? try sum(report.rows, \.inAppPurchases) : nil) }
        return Analysis(rows: countries, paid: paid, refunds: details ? refunds : nil, free: details ? free : nil, inAppPurchases: details && products ? inApp : nil, inAppRefunds: details && products ? inAppRefunds : nil,
                        proceeds: proceeds, moneyComplete: reports.allSatisfy(\.moneyComplete), productsComplete: products, coverage: coverage, criteria: criteria, insights: insights, trend: trend, comparable: comparable)
    }
}
