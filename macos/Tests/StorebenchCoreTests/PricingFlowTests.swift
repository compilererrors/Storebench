import Foundation
import Testing
@testable import StorebenchCore

struct PricingFlowTests {
    init() throws { _ = try TestIsolation.require() }

    private func product(_ id: String, kind: PriceProduct.Kind) -> PriceProduct {
        PriceProduct(id: id, kind: kind, productId: "com.example.synthetic.\(id)", name: "Synthetic \(id)", state: "MISSING_METADATA", type: kind == .subscription ? "AUTO_RENEWABLE" : "CONSUMABLE", group: kind == .subscription ? "Synthetic Group" : nil)
    }
    private func state(price: AppPriceState = .none, subscriptions: [PriceProduct] = [], purchases: [PriceProduct] = [], groups: Int = 0, priced: Set<String> = [], available: Bool = true) -> PricingSetupState {
        var value = PricingSetupState(appPrice: price, purchases: purchases, subscriptions: subscriptions, groups: (0..<groups).map { .init(id: "group-\($0)", referenceName: "Synthetic Group \($0)") }, priced: priced)
        value.appAvailable = available
        return value
    }

    @Test func eachModelListsAppStoreConnectsStepsInOrder() {
        #expect(PricingFlow.ids(.subscriptions) == [.appAvailability, .subscriptionGroup, .subscriptions, .subscriptionPrices, .introductoryOffers, .otherOffers, .priceSchedule, .status])
        #expect(PricingFlow.ids(.free) == [.appAvailability, .priceSchedule, .status])
        #expect(PricingFlow.ids(.paid) == [.appAvailability, .priceSchedule, .temporaryPrice, .status])
        #expect(PricingFlow.ids(.freeWithInAppPurchases) == [.appAvailability, .inAppPurchases, .inAppPurchasePrices, .priceSchedule, .status])
        #expect(PricingFlow.ids(.subscriptions).map(PricingFlow.title) == ["App Availability", "Subscription Group", "Subscriptions", "Subscription Prices", "Introductory Offers",
                                                                         "Promotional Offers, Offer Codes and Win-Back Offers", "Price Schedule", "Price and Product Status"])
        #expect(PricingFlow.neighbors(.appAvailability, in: .subscriptions) == (nil, .subscriptionGroup))
        #expect(PricingFlow.neighbors(.subscriptionGroup, in: .subscriptions) == (.appAvailability, .subscriptions))
        #expect(PricingFlow.neighbors(.status, in: .free) == (.priceSchedule, nil))
    }

    @Test func aNewSubscriptionAppOpensOnTheGroupAndEachStepTurnsDoneWhenAppStoreConnectHasIt() {
        // Without App Availability the app's first step is to set it up, as Apple refuses prices before.
        #expect(PricingFlow.initial(.subscriptions, state: state(available: false)) == .appAvailability)
        let empty = PricingFlow.steps(.subscriptions, state: state())
        #expect(PricingFlow.initial(.subscriptions, state: state()) == .subscriptionGroup)
        #expect(empty.map(\.status) == [.done, .current, .toDo, .toDo, .optional, .optional, .toDo, .toDo])
        let created = state(subscriptions: [product("sub-1", kind: .subscription)], groups: 1)
        #expect(PricingFlow.initial(.subscriptions, state: created) == .subscriptionPrices)
        let priced = state(price: .free(territory: "USA"), subscriptions: [product("sub-1", kind: .subscription)], groups: 1, priced: ["sub-1"])
        // Price and Product Status stays the next step while App Store Connect lists the subscription as Missing Metadata.
        #expect(PricingFlow.steps(.subscriptions, state: priced).map(\.status) == [.done, .done, .done, .done, .optional, .optional, .done, .current])
        #expect(PricingFlow.initial(.subscriptions, state: priced) == .status)
        let ready = PriceProduct(id: "sub-1", kind: .subscription, productId: "com.example.synthetic.sub-1", name: "Synthetic sub-1", state: "READY_TO_SUBMIT", type: "AUTO_RENEWABLE", group: "Synthetic Group")
        let complete = state(price: .free(territory: "USA"), subscriptions: [ready], groups: 1, priced: ["sub-1"])
        #expect(PricingFlow.steps(.subscriptions, state: complete).map(\.status).last == .done)
        // A paid price completes the Price Schedule for every model, as App Store Connect allows.
        let paid = state(price: .paid(territory: "USA", amount: "0.99", currency: "USD"))
        #expect(PricingFlow.steps(.free, state: paid).map(\.status) == [.done, .done, .done])
    }

    @Test func priceScheduleExplainsTheDownloadPriceApartFromSubscriptionAndPurchasePrices() {
        let step = PricingFlow.steps(.subscriptions, state: state()).first { $0.id == .priceSchedule }
        #expect(step?.purpose.contains("separate from the subscription prices") == true && step?.purpose.contains("Free") == true)
        #expect(PricingFlow.purpose(.priceSchedule, model: .paid).contains("pay once before they can download"))
        #expect(PricingFlow.purpose(.subscriptions, model: .subscriptions) == PricingFlow.purpose(.subscriptions))
        let tip = PricingFlow.appPriceChoice(.subscriptions)
        #expect(tip.contains("Free: people download the app at no cost") && tip.contains("subscriptions are charged on top of it"))
        #expect(!PricingFlow.appPriceChoice(.paid).contains("in-app purchases"))
        #expect(PricingFlow.appPriceHint(.subscriptions, free: false).contains("pay for the subscription too"))
        #expect(PricingFlow.appPriceHint(.freeWithInAppPurchases, free: true).contains("In-app purchases keep their own prices"))
    }

    @Test func aSavedNewGroupIsMatchedToTheGroupAppStoreConnectCreatedFromIt() {
        let groups = [SubscriptionGroupSummary(id: "group-1", referenceName: "Monthly")]
        var saved = SubscriptionSetupDraft(); saved.groupName = "monthly"
        let matched = saved.matched(groups: groups)
        #expect(matched.groupId == "group-1" && matched.groupName.isEmpty)
        var unnamed = SubscriptionSetupDraft(); unnamed.groupName = ""
        #expect(unnamed.matched(groups: groups).groupId == "group-1")
        var other = SubscriptionSetupDraft(); other.groupName = "Premium"
        #expect(other.matched(groups: groups).groupId.isEmpty && other.matched(groups: groups).groupName == "Premium")
        var removed = SubscriptionSetupDraft(); removed.groupId = "group-gone"
        #expect(removed.matched(groups: groups).groupId == "group-1")
        #expect(saved.matched(groups: nil) == saved)
    }
    @Test func everyGuideContinuesToThePageItsTaskLeadsTo() {
        let guides = AppNavigation.Section.allCases.filter { $0.group == .guides }
        #expect(guides.allSatisfy { $0.afterGuide != nil && $0.afterGuide != $0 })
        #expect(AppNavigation.Section.pricing.afterGuide == .release && AppNavigation.Section.release.afterGuide == .overview)
    }
}
