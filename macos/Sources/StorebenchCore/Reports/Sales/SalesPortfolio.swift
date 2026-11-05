import Foundation

/// Shared date-range analysis for all configured apps; absent or unreadable histories retain unknown coverage.
public enum SalesPortfolio {
    fileprivate struct Money: Sendable { let currency: String, value: ReportDecimal }
    fileprivate struct ProjectedPeriod: Sendable {
        let beginDate, endDate: String
        let paid, days: Int
        let moneyComplete, productsComplete: Bool
        let money: [Money]
    }
    private struct Totals {
        var currencies: [String] = [], values: [String: ReportDecimal] = [:]
        mutating func add(_ money: Money) {
            if values[money.currency] == nil { currencies.append(money.currency) }
            values[money.currency] = (values[money.currency] ?? .zero).adding(money.value)
        }
        var amounts: [ReportMoney.Amount] { currencies.map { .init(currency: $0, amount: values[$0]!.plain) } }
    }
    public struct App: Sendable, Identifiable {
        public let accountId, appId, title: String
        public let unavailable: Bool, periods: [SalesPresentation.Period]
        fileprivate let projected: [ProjectedPeriod]
        public var id: String { "\(accountId):\(appId)" }
        public init(accountId: String, appId: String, title: String, unavailable: Bool = false, periods: [SalesPresentation.Period]) throws {
            guard !unavailable || periods.isEmpty else { throw SalesPresentationFailure.format }
            self.accountId = accountId; self.appId = appId; self.title = title; self.unavailable = unavailable; self.periods = periods
            let ordered = periods.sorted { $0.beginDate < $1.beginDate }
            projected = try ordered.enumerated().map { index, period in
                if index > 0, ordered[index - 1].endDate >= period.beginDate { throw SalesPresentationFailure.format }
                let analysis = try SalesPresentation.analyze([period])
                let money = try analysis.proceeds.map { amount in
                    guard let value = ReportDecimal(amount.amount) else { throw SalesPresentationFailure.format }; return Money(currency: amount.currency, value: value)
                }
                return ProjectedPeriod(beginDate: period.beginDate, endDate: period.endDate, paid: analysis.paid, days: try SalesPresentation.days(period.beginDate, period.endDate),
                                       moneyComplete: period.moneyComplete, productsComplete: period.productsComplete, money: money)
            }
        }
    }
    public struct Row: Sendable, Identifiable {
        public let app: App
        public let periods, paid, coveredDays: Int
        public let complete, moneyComplete, productsComplete: Bool
        public let proceeds: [ReportMoney.Amount]
        public var id: String { app.id }
    }
    public struct Analysis: Sendable {
        public let rows: [Row], paid: Int, requestedDays: Int, completeApps: Int
        public let moneyComplete, productsComplete: Bool, proceeds: [ReportMoney.Amount]
    }
    public static func analyze(_ apps: [App], range: SalesPresentation.Range) throws -> Analysis {
        guard Set(apps.map(\.id)).count == apps.count else { throw SalesPresentationFailure.format }
        let requested = try SalesPresentation.days(range.beginDate, range.endDate)
        var rows: [Row] = [], proceeds = Totals(), paid = 0
        for app in apps {
            let included = app.projected.filter { $0.beginDate >= range.beginDate && $0.endDate <= range.endDate }
            var appPaid = 0, covered = 0, amounts = Totals()
            for period in included {
                covered += period.days; appPaid = try SalesPresentation.add(appPaid, period.paid)
                for money in period.money { amounts.add(money); proceeds.add(money) }
            }
            paid = try SalesPresentation.add(paid, appPaid)
            rows.append(Row(app: app, periods: included.count, paid: appPaid, coveredDays: covered, complete: covered == requested && !app.unavailable,
                            moneyComplete: !included.isEmpty && included.allSatisfy(\.moneyComplete), productsComplete: !included.isEmpty && included.allSatisfy(\.productsComplete), proceeds: amounts.amounts))
        }
        return Analysis(rows: rows, paid: paid, requestedDays: requested, completeApps: rows.filter(\.complete).count,
                        moneyComplete: !rows.isEmpty && rows.allSatisfy { $0.moneyComplete && $0.complete }, productsComplete: !rows.isEmpty && rows.allSatisfy(\.productsComplete), proceeds: proceeds.amounts)
    }
}

extension WorkspaceSession {
    public func salesPortfolio() throws -> [SalesPortfolio.App] {
        var result: [SalesPortfolio.App] = []
        for account in try accounts() {
            var seen = Set<String>()
            for app in account.apps where seen.insert(app.id).inserted {
                do { result.append(try SalesPortfolio.App(accountId: account.id, appId: app.id, title: app.name, periods: try salesPresentation(account: account, appId: app.id))) }
                catch { try validateAccess(); result.append(try SalesPortfolio.App(accountId: account.id, appId: app.id, title: app.name, unavailable: true, periods: [])) }
            }
        }
        return result
    }
    public func portfolioMoney(apps: [SalesPortfolio.App], sources: PricingSources = PricingSources(), now: Date = Date()) async throws -> ReportMoney.Context {
        for app in apps { try requireHistoryScope(accountId: app.accountId, appId: app.appId) }
        try Task.checkCancellation()
        let currency = try displayCurrency(), quotes = Set(apps.flatMap(\.periods).flatMap(\.rows).flatMap(\.proceeds).map(\.currency)).sorted()
        let snapshot = try await fxRates(base: currency, quotes: quotes, sources: sources, now: now)
        for app in apps { try requireHistoryScope(accountId: app.accountId, appId: app.appId) }; try Task.checkCancellation()
        return ReportMoney.Context(currency: currency, rates: snapshot.rates.mapValues { ReportMoney.Rate(rate: $0.rate, date: $0.date) }, staleCurrencies: snapshot.stale)
    }
}
