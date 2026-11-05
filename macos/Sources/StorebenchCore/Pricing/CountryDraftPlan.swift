import Foundation

/// The change a person chose for the selected countries in Pricing.
public struct CountryDraftRequest: Equatable, Sendable {
    public enum Change: Equatable, Sendable { case percent(String, rounding: String), exact(String) }
    public struct Period: Equatable, Sendable {
        public let start, end: String
        public init(start: String, end: String) { self.start = start; self.end = end }
    }

    public let territories: [String]
    public let change: Change
    public let period: Period?

    public init(territories: some Collection<String>, change: Change, period: Period?) {
        self.territories = territories.sorted(); self.change = change; self.period = period
    }
}

/// Turns a request into one amount per country from the Apple prices the person reviewed. It reads and saves nothing.
struct CountryDraftPlan {
    let basis: [PriceRow], today: String
    private let current: [String: PriceRow]

    init(basis: [PriceRow], today: String) {
        self.basis = basis; self.today = today; current = PricingMath.current(basis, today: today)
    }

    /// Refuses countries without a current price, and temporary periods where Apple already has a price scheduled.
    func check(_ request: CountryDraftRequest) throws {
        guard request.territories.allSatisfy({ current[$0] != nil }) else { throw PricingFailure.selection }
        if let period = request.period, request.territories.contains(where: { PricingMath.scheduledConflict(basis, territory: $0, start: period.start, end: period.end, today: today) }) {
            throw PricingFailure.scheduled
        }
    }

    /// Only a percentage rounded to Apple's price points needs them.
    func needsPricePoints(_ request: CountryDraftRequest) -> Bool {
        if case .percent(_, let rounding) = request.change { rounding != "exact" } else { false }
    }

    func amounts(_ request: CountryDraftRequest, points: [PricePoint]) throws -> [(territory: String, currency: String, amount: String)] {
        try check(request)
        return try request.territories.map { code in
            let row = current[code]!
            switch request.change {
            case .exact(let amount): return (code, row.currency, PricingMath.text(try PricingMath.desired(amount)))
            case .percent(let percent, let rounding): return (code, row.currency, try PricingMath.roundedPercent(row.customerPrice, percent: percent, territory: code, rounding: rounding, points: points))
            }
        }
    }
}
