import Foundation

extension SalesPresentation {
    public struct Freshness: Equatable, Sendable {
        public let latestSavedDay: String?, completedThrough: String, daysAfterLatest: Int
        public var message: String {
            guard let latestSavedDay else { return "No saved reports. Download completed reporting days to see purchases." }
            return "Saved through \(latestSavedDay). " + (daysAfterLatest > 0
                ? "\(daysAfterLatest) later completed reporting days are not downloaded. Totals may be lower until reports are updated."
                : "Check reporting coverage for gaps inside the selected dates.")
        }
    }
    public static func freshness(_ periods: [Period], completedThrough: String) -> Freshness {
        let latest = periods.map(\.endDate).max()
        let pending = latest.flatMap(PeriodDates.number).flatMap { day in PeriodDates.number(completedThrough).map { max(0, $0 - day) } } ?? 0
        return Freshness(latestSavedDay: latest, completedThrough: completedThrough, daysAfterLatest: pending)
    }
    public static func proceedsText(_ amounts: [ReportMoney.Amount], complete: Bool) -> String {
        amounts.isEmpty ? (complete ? "No proceeds reported" : "Not available · download original reports")
            : amounts.map { "\($0.amount) \($0.currency)" }.joined(separator: "\n")
    }
    public static func estimateText(_ conversion: ReportMoney.Conversion, context: ReportMoney.Context, complete: Bool, available: Bool) -> String {
        guard available, conversion.amount != nil else { return "—" }
        return ReportMoney.label(conversion.amount, currency: context.currency) + (complete && conversion.complete ? "" : " · Partial")
    }
    public enum Measure: String, CaseIterable, Sendable {
        case paid, free, refunds, inAppPurchases
        public var label: String { switch self { case .paid: "Paid app purchases"; case .free: "Free app downloads"; case .refunds: "Refunded paid units"; case .inAppPurchases: "In-app purchases and subscriptions" } }
    }
    public struct SeriesPoint: Sendable, Identifiable {
        public let beginDate, endDate: String, value: Int, segment: Int
        public var id: String { "\(beginDate):\(endDate)" }
        public var position: Date { Date(timeIntervalSince1970: Double(PeriodDates.number(beginDate)! + PeriodDates.number(endDate)! + 1) / 2 * 86_400) }
    }
    public static func series(_ analysis: Analysis, measure: Measure) -> [SeriesPoint] {
        var segment = 0, previousEnd: Int?
        return analysis.trend.compactMap { point in
            let start = PeriodDates.number(point.beginDate)!
            if let previousEnd, previousEnd + 1 != start { segment += 1 }
            previousEnd = PeriodDates.number(point.endDate)!
            let value: Int? = switch measure { case .paid: point.paid; case .free: point.free; case .refunds: point.refunds; case .inAppPurchases: point.inAppPurchases }
            guard let value else { segment += 1; return nil }
            return SeriesPoint(beginDate: point.beginDate, endDate: point.endDate, value: value, segment: segment)
        }
    }
    public struct Range: Sendable, Equatable {
        public let beginDate, endDate: String
        public init(beginDate: String, endDate: String) throws { _ = try SalesPresentation.days(beginDate, endDate); self.beginDate = beginDate; self.endDate = endDate }
        public var previous: Range? {
            guard let start = PeriodDates.number(beginDate), let length = try? SalesPresentation.days(beginDate, endDate) else { return nil }
            return try? Range(beginDate: PeriodDates.text(start - length), endDate: PeriodDates.text(start - 1))
        }
        var json: JSONText { .object([("beginDate", .string(beginDate)), ("endDate", .string(endDate))]) }
    }
    /// Refreshing reports keeps the user's analysis choice; only relative windows follow new saved dates.
    public static func selectedRange(_ periods: [Period], choice: PeriodRangeChoice, period: String = "range", requested: Range? = nil) -> Range? {
        if let selected = periods.first(where: { $0.id == period }) { return try? Range(beginDate: selected.beginDate, endDate: selected.endDate) }
        if let requested { return requested }
        if let selected = try? choice.resolve(latest: periods.map(\.endDate).max() ?? "") { return try? Range(beginDate: selected.from, endDate: selected.to) }
        guard let begin = periods.map(\.beginDate).min(), let end = periods.map(\.endDate).max() else { return nil }
        return try? Range(beginDate: begin, endDate: end)
    }
    public struct Selection: Sendable {
        public let range: Range, analysis: Analysis
        public let requestedDays, coveredDays, crossingPeriods: Int
        public let missingDays: [String], complete: Bool
        /// Money is complete only when every requested day is saved; undelivered days stay unknown, never zero.
        public var moneyComplete: Bool { complete && analysis.moneyComplete && analysis.productsComplete }
        var json: JSONText { .object([("range", range.json), ("analysis", analysis.json), ("requestedDays", .number(Double(requestedDays))), ("coveredDays", .number(Double(coveredDays))), ("missingDays", .array(missingDays.map(JSONText.string))), ("crossingPeriods", .number(Double(crossingPeriods))), ("complete", .bool(complete))]) }
    }
    public static func select(_ periods: [Period], range: Range, criteria: Criteria = .defaults) throws -> Selection {
        let included = periods.filter { $0.beginDate >= range.beginDate && $0.endDate <= range.endDate }
        let crossing = periods.filter { $0.beginDate <= range.endDate && $0.endDate >= range.beginDate && !($0.beginDate >= range.beginDate && $0.endDate <= range.endDate) }.count
        let analysis = try analyze(included, criteria: criteria), requested = try days(range.beginDate, range.endDate), covered = analysis.coverage?.coveredDays ?? 0
        // Bound missing-day presentation without expanding every covered period into a day set.
        var missing: [String] = []
        var current = PeriodDates.number(range.beginDate)!, index = 0
        let ordered = included.sorted { $0.beginDate < $1.beginDate }, end = PeriodDates.number(range.endDate)!
        while current <= end && missing.count <= 400 {
            let label = PeriodDates.text(current)
            while index < ordered.count && ordered[index].endDate < label { index += 1 }
            if index < ordered.count && ordered[index].beginDate <= label {
                current = PeriodDates.number(ordered[index].endDate)! + 1
            } else { missing.append(label); current += 1 }
        }
        return Selection(range: range, analysis: analysis, requestedDays: requested, coveredDays: covered, crossingPeriods: crossing, missingDays: missing, complete: covered == requested && crossing == 0)
    }
    public static func change(_ current: String?, previous: String?) -> String {
        guard let current, let previous, let after = ReportDecimal(current), let before = ReportDecimal(previous) else { return "Unavailable" }
        if before.isZero { return after.isZero ? "No change" : "No percentage baseline" }
        if before.negative || after.negative { return "Negative amount; compare totals" }
        let opposite = ReportDecimal("-" + previous)!
        let difference = after.adding(opposite, precision: 20), delta = difference.divided(by: before, precision: 20).multiplied(by: ReportDecimal("100")!, precision: 20)
        return (!delta.negative ? "+" : "") + delta.fixed(1) + "%"
    }
    public static func shareLabel(_ purchases: Int, total: Int) -> String {
        guard total > 0 else { return "—" }
        // Preserve binary precision before applying half-up rounding to one decimal place.
        let text = String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), Double(purchases) / Double(total) * 100)
        return ((ReportDecimal(text) ?? ReportDecimal.scientific(text))?.fixed(1) ?? "—") + "%"
    }
    public enum Sort: String, CaseIterable, Sendable { case country, paid, share, refunds, proceeds, estimate }
    public static func countries(_ analysis: Analysis, context: ReportMoney.Context, query: String = "", sort: Sort? = nil, descending: Bool = false) -> [Country] {
        let search = query.lowercased()
        let rows = analysis.rows.filter { search.isEmpty || ($0.name + " " + $0.code).lowercased().range(of: search, options: .literal) != nil }
        guard let sort else { return rows }
        func value(_ row: Country) -> (text: String?, number: Double?) {
            switch sort {
            case .country: return (row.name, nil)
            case .paid: return (nil, Double(row.paid))
            case .share: return (nil, analysis.paid > 0 ? Double(row.paid) / Double(analysis.paid) : nil)
            case .refunds: return (nil, analysis.refunds != nil ? Double(row.refunds) : nil)
            case .proceeds:
                let text = row.proceeds.map { "\($0.currency) \($0.amount)" }.joined(separator: " · ")
                return (text.isEmpty ? nil : text, nil)
            case .estimate:
                let converted = ReportMoney.convert(row.proceeds, context: context)
                return (nil, converted.complete ? converted.amount.flatMap(Double.init) : nil)
            }
        }
        return rows.enumerated().map { (row: $0.element, index: $0.offset, value: value($0.element)) }.sorted { a, b in
            if a.value.text == nil && a.value.number == nil { return b.value.text == nil && b.value.number == nil ? a.index < b.index : false }
            if b.value.text == nil && b.value.number == nil { return true }
            let order = a.value.text.map { $0.compare(b.value.text!, options: [.numeric, .caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")) }
                ?? (a.value.number! < b.value.number! ? .orderedAscending : a.value.number! > b.value.number! ? .orderedDescending : .orderedSame)
            return order == .orderedSame ? a.index < b.index : descending ? order == .orderedDescending : order == .orderedAscending
        }.map(\.row)
    }
    public static func analysisCSV(_ selection: Selection, context: ReportMoney.Context) -> Data {
        let analysis = selection.analysis
        let columns = ["begin_date", "end_date", "covered_days", "requested_days", "crossing_periods", "territory", "paid_purchases", "refunded_units", "free_downloads", "reported_proceeds", "display_currency", "estimated_proceeds", "estimate_complete", "rate_dates", "minimum_purchases", "minimum_country_purchases", "minimum_share_percent", "report_time_zone", "metric_scope", "in_app_purchases", "in_app_refunded_units", "product_scope_complete"]
        let rows = analysis.rows.map { row -> [String] in
            let converted = ReportMoney.convert(row.proceeds, context: context)
            return [selection.range.beginDate, selection.range.endDate, String(selection.coveredDays), String(selection.requestedDays), String(selection.crossingPeriods), row.code, String(row.paid), analysis.refunds == nil ? "" : String(row.refunds), analysis.free == nil ? "" : String(row.free),
                    row.proceeds.map { "\($0.amount) \($0.currency)" }.joined(separator: "; "), context.currency, converted.amount ?? "", String(converted.complete && selection.moneyComplete), converted.dates.joined(separator: "; "),
                    String(analysis.criteria.minimumPurchases), String(analysis.criteria.minimumCountryPurchases), String(analysis.criteria.minimumShare), "America/Los_Angeles", "App downloads counted separately; proceeds include verified associated in-app purchases and subscriptions",
                    analysis.inAppPurchases == nil ? "" : String(row.inAppPurchases), analysis.inAppRefunds == nil ? "" : String(row.inAppRefunds), String(analysis.productsComplete)]
        }
        return Data(Delimited.write(Delimited.Table(columns: columns, rows: rows.map { $0.map(ReportTables.spreadsheetCell) })).utf8)
    }
    public static func writeAnalysisCSV(_ selection: Selection, context: ReportMoney.Context, to url: URL) throws {
        let bytes = analysisCSV(selection, context: context); try ReportFiles.atomicStream(to: url) { try $0(bytes) }
    }
}

extension WorkspaceSession {
    public func salesPresentation(account: Account, appId: String) throws -> [SalesPresentation.Period] {
        try SalesPresentation.prepare(salesFileRecords(account: account, appId: appId), accountId: account.id, appId: appId)
    }
    public func salesMoney(account: Account, appId: String, periods: [SalesPresentation.Period], sources: PricingSources = PricingSources(), now: Date = Date()) async throws -> ReportMoney.Context {
        try salesFileScope(account, appId: appId); try Task.checkCancellation()
        let currency = try displayCurrency(), quotes = Set(periods.flatMap(\.rows).flatMap(\.proceeds).map(\.currency)).sorted()
        let snapshot = try await fxRates(base: currency, quotes: quotes, sources: sources, now: now)
        try salesFileScope(account, appId: appId); try Task.checkCancellation()
        return ReportMoney.Context(currency: currency, rates: snapshot.rates.mapValues { ReportMoney.Rate(rate: $0.rate, date: $0.date) }, staleCurrencies: snapshot.stale)
    }
}
