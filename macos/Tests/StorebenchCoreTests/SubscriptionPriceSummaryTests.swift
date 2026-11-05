import Foundation
import Testing
@testable import StorebenchCore

struct SubscriptionPriceSummaryTests {
    init() throws { _ = try TestIsolation.require() }

    private func row(_ territory: String, point: String, price: String, currency: String, start: String?) -> ProductPrice {
        ProductPrice(id: "price-\(territory)-\(start ?? "now")", territory: territory, currency: currency, customerPrice: price, proceeds: nil, startDate: start, startKnown: true,
                     endDate: nil, endKnown: true, source: .subscription, pricePointId: point, preserved: false, planType: "MONTHLY")
    }
    private func schedule(_ rows: [ProductPrice]) -> ProductPriceSchedule { ProductPriceSchedule(baseTerritory: nil, rows: rows, available: !rows.isEmpty, scheduleId: nil) }
    private func step(_ method: String, _ path: [JSONText], body: JSONText? = nil, state: String = "done") -> PublishStep {
        PublishStep(key: "step", group: "Prices", label: "Synthetic", detail: "", before: nil, after: nil, kind: .api, method: method, path: path, body: body, asset: nil, guardValue: nil, state: state, resultId: nil)
    }

    @Test func summaryShowsApplesCurrentPricesAndTheNextScheduledChange() {
        let rows = [row("USA", point: "p-usa-1", price: "1.99", currency: "USD", start: nil), row("SWE", point: "p-swe-1", price: "25.00", currency: "SEK", start: nil),
                    row("USA", point: "p-usa-2", price: "2.99", currency: "USD", start: "2026-12-01"), row("SWE", point: "p-swe-2", price: "35.00", currency: "SEK", start: "2026-12-01")]
        let summary = SubscriptionPriceSummary(schedule(rows), territory: "USA", today: "2026-11-02")
        #expect(summary.countries == 2)
        #expect(summary.label == "Apple has prices in 2 countries and regions · United States 1.99 USD")
        #expect(summary.scheduledLabel == "Scheduled from 2026-12-01: 2 countries and regions · United States 2.99 USD")
        #expect(SubscriptionPriceSummary(schedule([]), territory: "USA", today: "2026-11-02").label == "Apple has no prices for this subscription yet.")
    }

    @Test func aChoiceMatchingThePriceInEffectOnTheStartDateIsUnchanged() {
        let rows = [row("USA", point: "p-usa-1", price: "1.99", currency: "USD", start: nil), row("SWE", point: "p-swe-1", price: "25.00", currency: "SEK", start: nil),
                    row("USA", point: "p-usa-2", price: "2.99", currency: "USD", start: "2026-12-01")]
        let summary = SubscriptionPriceSummary(schedule(rows), territory: "USA", today: "2026-11-02")
        // Countries without an Apple price are left out; the subscription is not available there.
        #expect(summary.unchanged(["USA": "p-usa-1", "SWE": "p-swe-1", "NOR": "p-nor-1"], start: "2026-11-10", today: "2026-11-02"))
        #expect(!summary.unchanged(["USA": "p-usa-2", "SWE": "p-swe-1"], start: "2026-11-10", today: "2026-11-02"))
        // After the scheduled change, the scheduled price is the one in effect.
        #expect(summary.unchanged(["USA": "p-usa-2"], start: "2026-12-05", today: "2026-11-02"))
        #expect(!summary.unchanged(["USA": "p-usa-1"], start: "2026-12-05", today: "2026-11-02"))
        #expect(!SubscriptionPriceSummary(schedule([]), territory: "USA", today: "2026-11-02").unchanged(["USA": "p-usa-1"], start: nil, today: "2026-11-02"))
    }

    @Test func savedPricesCountEachSentPriceAndSkipOtherSteps() {
        let included: JSONText = .object([("included", .array([.object([("type", .string("subscriptionPrices"))]), .object([("type", .string("subscriptionPrices"))]), .object([("type", .string("other"))])]))])
        let first = [step("POST", [.string("subscriptionAvailabilities")]), step("PATCH", [.string("subscriptions"), .string("sub-1")], body: included)]
        #expect(WorkspaceSession.sentPrices(first, subscriptionId: "sub-1") == 2)
        let changes = [step("POST", [.string("subscriptionPrices")]), step("POST", [.string("subscriptionPrices")]), step("POST", [.string("subscriptionPrices")], state: "failed")]
        #expect(WorkspaceSession.sentPrices(changes, subscriptionId: "sub-1") == 2)
        #expect(WorkspaceSession.sentPrices(first, subscriptionId: "sub-2") == 0)
    }
}
