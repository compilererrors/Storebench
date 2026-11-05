import Foundation

/// What Apple's price schedule for one subscription holds today: the countries and regions with a current price, the price in one
/// country or region, and the price changes Apple has scheduled. Read from Apple's schedule only.
public struct SubscriptionPriceSummary: Sendable, Equatable {
    public let countries: Int
    public let territory: String
    public let current: ProductPrice?
    /// Rows that start after today, earliest first.
    public let scheduled: [ProductPrice]
    let rows: [ProductPrice]

    public init(_ schedule: ProductPriceSchedule, territory: String, today: String) {
        let phases = ProductPricing.phases(schedule.rows, today: today)
        let current = schedule.rows.filter { phases[$0.key] == .current }
        self.rows = schedule.rows
        self.territory = territory
        self.countries = Set(current.map(\.territory)).count
        let base = current.filter { $0.territory == territory }
        self.current = base.count == 1 ? base[0] : nil
        self.scheduled = schedule.rows.filter { phases[$0.key] == .future }.sorted { (($0.startDate ?? ""), $0.territory) < (($1.startDate ?? ""), $1.territory) }
    }

    public var priced: Bool { !rows.isEmpty }

    /// For example "Apple has prices in 175 countries and regions · United States 1.99 USD".
    public var label: String {
        guard priced else { return "Apple has no prices for this subscription yet." }
        let count = "\(countries) \(countries == 1 ? "country or region" : "countries and regions")"
        let base = current.flatMap { row in row.customerPrice.map { "\(WorkspaceSession.countryName(territory)) \($0) \(row.currency ?? "")".trimmingCharacters(in: .whitespaces) } }
            ?? "No current price in \(WorkspaceSession.countryName(territory))"
        return "Apple has prices in \(count) · \(base)"
    }

    /// The next scheduled change, or that none is scheduled.
    public var scheduledLabel: String {
        guard let first = scheduled.first, let start = first.startDate else { return "No price change scheduled." }
        let same = scheduled.filter { $0.startDate == start }
        let count = "\(same.count) \(same.count == 1 ? "country or region" : "countries and regions")"
        let base = same.first { $0.territory == territory }.flatMap { row in row.customerPrice.map { " · \(WorkspaceSession.countryName(territory)) \($0) \(row.currency ?? "")" } } ?? ""
        let later = Set(scheduled.compactMap(\.startDate)).count - 1
        return "Scheduled from \(start): \(count)\(base)" + (later > 0 ? " · \(later) later \(later == 1 ? "change" : "changes")" : "")
    }

    /// Whether Apple already has these prices in effect on `start` (today when nil) in every chosen country or region it prices.
    /// Countries or regions without any Apple price are left out, since Apple prices a subscription only where it is available.
    /// Unclear rows, such as two prices starting the same day, count as a change so Save stays available.
    public func unchanged(_ points: [String: String], start: String?, today: String) -> Bool {
        guard priced, !points.isEmpty else { return false }
        let day = start ?? today
        var compared = 0
        for (code, point) in points {
            let territoryRows = rows.filter { $0.territory == code && $0.preserved != true }
            if territoryRows.isEmpty { continue }
            guard territoryRows.allSatisfy({ $0.startKnown }) else { return false }
            let started = territoryRows.filter { ($0.startDate ?? "") <= day }
            guard let latest = started.map({ $0.startDate ?? "" }).max() else { return false }
            let effective = started.filter { ($0.startDate ?? "") == latest }
            guard effective.count == 1, effective[0].pricePointId == point else { return false }
            compared += 1
        }
        return compared > 0
    }
}

/// The newest completed price review for one subscription.
public struct SavedSubscriptionPrices: Sendable, Equatable {
    public let countries: Int
    public let completedAt: String
    public var label: String { "Saved · \(countries) \(countries == 1 ? "country or region" : "countries and regions")" }
}

extension WorkspaceSession {
    /// The newest complete Subscription Prices review that sent prices for this subscription, from the saved publish history.
    public func savedSubscriptionPrices(accountId: String, appId: String, subscriptionId: String) throws -> SavedSubscriptionPrices? {
        for review in try publishHistory(accountId: accountId, appId: appId) where review.state == "complete" {
            guard review.request.scope == .pricingSetup, let change = review.request.pricingSetup, change.action == .subscriptionPrices, change.subscriptionId == subscriptionId,
                  let at = review.completedAt else { continue }
            let countries = Self.sentPrices(review.steps, subscriptionId: subscriptionId)
            if countries > 0 { return SavedSubscriptionPrices(countries: countries, completedAt: at) }
        }
        return nil
    }

    /// Countries and regions a review sent prices for: one per price change, or each price included in the first-prices update.
    static func sentPrices(_ steps: [PublishStep], subscriptionId: String) -> Int {
        steps.reduce(0) { total, step in
            guard step.kind == .api, step.state == "done" else { return total }
            if step.method == "POST", step.path == [.string("subscriptionPrices")] { return total + 1 }
            if step.method == "PATCH", step.path == [.string("subscriptions"), .string(subscriptionId)], case .array(let included)? = step.body?["included"] {
                return total + included.filter { $0["type"]?.text == "subscriptionPrices" }.count
            }
            return total
        }
    }
}
