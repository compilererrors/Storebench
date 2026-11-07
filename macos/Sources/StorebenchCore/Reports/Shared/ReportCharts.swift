import Foundation

/// Report charts preserve the saved interval and distinguish unknown values from checked zero activity.
public enum ReportCharts {
    public static let analyticsLabels = ["first": "First-time downloads", "redownload": "Redownloads", "updates": "Updates", "restores": "Restores", "impressions": "Impressions", "views": "Product page views", "get": "Get / Buy / Pre-order taps", "other": "Other interactions"]
    public static func analytics(_ periods: [AnalyticsPeriod], metrics: [String], indexed: Bool) throws -> [SavedTimeSeries.Series] {
        let points = try AnalyticsPresentation.points(periods, metrics: metrics, indexed: indexed)
        return metrics.map { metric in
            .init(key: metric, label: analyticsLabels[metric]!, points: points.filter { $0.metric == metric }.map { .init(start: $0.start, end: $0.end, value: $0.value) })
        }
    }
    public static let salesMeasures: [SalesPresentation.Measure] = [.paid, .free, .inAppPurchases, .refunds]
    public static func salesLabel(_ measure: SalesPresentation.Measure) -> String {
        switch measure { case .paid: "Paid purchases"; case .free: "Free downloads"; case .inAppPurchases: "In-app purchases"; case .refunds: "Refunded units" }
    }
    public struct Sales: Sendable {
        public let measure: SalesPresentation.Measure, series: [SavedTimeSeries.Series], total: Double?, totalLabel: String, note: String?
        public var json: JSONText { .object([("measure", .string(measure.rawValue)), ("series", .array(series.map(\.json))), ("total", total.map(JSONText.number) ?? .null), ("totalLabel", .string(totalLabel)), ("note", note.map(JSONText.string) ?? .null)]) }
    }
    public static func sales(_ analysis: SalesPresentation.Analysis, measure requested: SalesPresentation.Measure? = nil) -> Sales {
        let measure = requested ?? (analysis.paid == 0 && (analysis.free ?? 0) > 0 ? .free : .paid)
        let points = analysis.trend.map { point in
            let value: Int? = switch measure { case .paid: point.paid; case .free: point.free; case .refunds: point.refunds; case .inAppPurchases: point.inAppPurchases }
            return SavedTimeSeries.Point(start: point.beginDate, end: point.endDate, value: value.map(Double.init))
        }
        let known = points.compactMap(\.value), partial = known.count < points.count
        return Sales(measure: measure, series: [.init(key: measure.rawValue, label: salesLabel(measure), points: points)], total: known.isEmpty ? nil : known.reduce(0, +), totalLabel: "Total\(partial ? " · partial" : "")",
                     note: partial ? "Some periods lack Apple’s original report rows; their value is not reported and breaks the line." : nil)
    }
    public static let salesEstimateKey = "proceeds"
    /// One series per chosen measure, in the order chosen, for one chart.
    public static func salesOverlay(_ analysis: SalesPresentation.Analysis, measures: [SalesPresentation.Measure]) -> [SavedTimeSeries.Series] {
        measures.flatMap { sales(analysis, measure: $0).series }
    }
    /// Estimated proceeds per report period in the display currency. A period whose amounts or product coverage are not
    /// verified, or whose currencies cannot all be converted, stays unknown.
    public static func salesEstimate(_ periods: [SalesPresentation.Period], context: ReportMoney.Context) -> SavedTimeSeries.Series {
        let points = periods.sorted { $0.beginDate < $1.beginDate }.map { period -> SavedTimeSeries.Point in
            guard period.moneyComplete, period.productsComplete else { return .init(start: period.beginDate, end: period.endDate, value: nil) }
            let amounts = period.rows.flatMap(\.proceeds)
            guard !amounts.isEmpty else { return .init(start: period.beginDate, end: period.endDate, value: 0) }
            let conversion = ReportMoney.convert(amounts, context: context)
            guard conversion.complete, let amount = conversion.amount else { return .init(start: period.beginDate, end: period.endDate, value: nil) }
            return moneyPoint(.init(currency: context.currency, amount: amount), start: period.beginDate, end: period.endDate)
        }
        return .init(key: salesEstimateKey, label: "Estimated proceeds · " + context.currency, points: points)
    }
    public static func financial(_ periods: [FinancialPresentation.Period], metric: String, currency: String = "") throws -> [SavedTimeSeries.Series] {
        _ = try FinancialPresentation.summary(periods)
        guard ["paid", "returned", "net", "other", "proceeds"].contains(metric) else { throw FinanceFailure.format }
        let groups = Dictionary(grouping: periods, by: \.dateKey)
        let points = try groups.keys.sorted().map { key -> SavedTimeSeries.Point in
            let rows = groups[key]!, first = rows[0], summary = try FinancialPresentation.summary(rows)
            if metric == "proceeds" {
                let amount = summary.proceeds.first { $0.currency == currency }
                return moneyPoint(amount, start: first.beginDate, end: first.endDate)
            }
            let count = metric == "paid" ? summary.paid : metric == "returned" ? summary.returned : metric == "net" ? summary.net : summary.other
            return .init(start: first.beginDate, end: first.endDate, value: Double(count))
        }
        let label = ["paid": "Paid units", "returned": "Returned units", "net": "Net units", "other": "Other net units", "proceeds": "Reported proceeds · " + currency][metric]!
        return [.init(key: metric + ":" + currency, label: label, points: points)]
    }
    /// Report periods whose proceeds stay unknown in the chart because their amounts or product coverage are not verified.
    public static func unverifiedProceeds(_ periods: [SalesPresentation.Period]) -> Int { periods.filter { !$0.moneyComplete || !$0.productsComplete }.count }
    public static func salesProceeds(_ periods: [SalesPresentation.Period], currency: String) throws -> [SavedTimeSeries.Series] {
        _ = try SalesPresentation.analyze(periods)
        let points = periods.sorted { $0.beginDate < $1.beginDate }.map { period -> SavedTimeSeries.Point in
            guard period.moneyComplete, period.productsComplete else { return .init(start: period.beginDate, end: period.endDate, value: nil) }
            guard let analysis = try? SalesPresentation.analyze([period]) else { return .init(start: period.beginDate, end: period.endDate, value: nil) }
            // A verified report without proceeds in this currency reported none that day; only unverified days stay unknown.
            guard let amount = analysis.proceeds.first(where: { $0.currency == currency }) else { return .init(start: period.beginDate, end: period.endDate, value: 0) }
            return moneyPoint(amount, start: period.beginDate, end: period.endDate)
        }
        return [.init(key: "proceeds:" + currency, label: "Reported proceeds · " + currency, points: points)]
    }
    private static func moneyPoint(_ amount: ReportMoney.Amount?, start: String, end: String) -> SavedTimeSeries.Point {
        guard let amount, let decimal = Decimal(string: amount.amount, locale: Locale(identifier: "en_US_POSIX")) else { return .init(start: start, end: end, value: nil) }
        let plotted = NSDecimalNumber(decimal: decimal).doubleValue
        return .init(start: start, end: end, value: plotted.isFinite ? plotted : nil, exactLabel: amount.amount + " " + amount.currency)
    }
}
