import Foundation

/// Pricing as numbered steps for one pricing model, in App Store Connect's order and words: what is sold first, then its prices and
/// offers, then the app's Price Schedule. Each step's status comes from what App Store Connect has now; moving between steps changes nothing at Apple.
public enum PricingFlow {
    public enum StepId: String, Sendable, CaseIterable {
        case appAvailability = "app-availability", subscriptionGroup = "subscription-group", subscriptions, subscriptionPrices = "subscription-prices", introductoryOffers = "introductory-offers"
        case otherOffers = "other-offers", inAppPurchases = "in-app-purchases", inAppPurchasePrices = "in-app-purchase-prices"
        case priceSchedule = "price-schedule", temporaryPrice = "temporary-price", status
    }
    public enum Status: Sendable, Equatable {
        case done, current, toDo, optional
        public var label: String {
            switch self { case .done: "Done"; case .current: "Next step"; case .toDo: "To do"; case .optional: "Optional" }
        }
    }
    public struct Step: Sendable, Equatable, Identifiable {
        public let id: StepId
        public let number: Int
        public let status: Status
        public let model: PricingModelKind
        public var title: String { PricingFlow.title(id) }
        public var purpose: String { PricingFlow.purpose(id, model: model) }
        public var optional: Bool { PricingFlow.optional.contains(id) }
    }

    public static let optional: Set<StepId> = [.introductoryOffers, .otherOffers, .temporaryPrice]

    /// App Store Connect's names for each step.
    public static func title(_ id: StepId) -> String {
        switch id {
        case .appAvailability: "App Availability"
        case .subscriptionGroup: "Subscription Group"
        case .subscriptions: "Subscriptions"
        case .subscriptionPrices: "Subscription Prices"
        case .introductoryOffers: "Introductory Offers"
        case .otherOffers: "Promotional Offers, Offer Codes and Win-Back Offers"
        case .inAppPurchases: "In-App Purchases"
        case .inAppPurchasePrices: "In-App Purchase Prices"
        case .priceSchedule: "Price Schedule"
        case .temporaryPrice: "Temporary Price Change"
        case .status: "Price and Product Status"
        }
    }

    public static func purpose(_ id: StepId) -> String {
        switch id {
        case .appAvailability: "The countries or regions where the app is available. App Store Connect needs it before it accepts prices for the app, its subscriptions or its in-app purchases."
        case .subscriptionGroup: "Subscriptions are sold in a Subscription Group. People can subscribe to one subscription in a group at a time. Choose a group or name a new one; a new group is created with its first subscription in the next step."
        case .subscriptions: "Each subscription in the group: its Subscription Duration, Reference Name, Product ID and Family Sharing. Create sends them to App Store Connect after you approve the review."
        case .subscriptionPrices: "Each subscription's price: Apple's comparable prices from one price in the Base Country or Region, or a pricing profile such as Big Mac Index or World Bank purchasing power."
        case .introductoryOffers: "Optional. A Free Trial, Pay As You Go or Pay Up Front offer for new subscribers of one subscription. Each person can redeem one introductory offer per Subscription Group."
        case .otherOffers: "Optional. Promotional Offers for current and former subscribers, Offer Codes to share, and Win-Back Offers for people who stopped, set up under each subscription."
        case .inAppPurchases: "Each consumable, non-consumable or non-renewing subscription in-app purchase: its type, Reference Name, Product ID and price."
        case .inAppPurchasePrices: "Change an in-app purchase's price in the Base Country or Region. Apple sets comparable prices in the other countries or regions."
        case .priceSchedule: "The app's download price: what people pay before they can download the app, separate from subscription and in-app purchase prices. App Store Connect needs it before the version can be submitted, even for a free app."
        case .temporaryPrice: "Optional. A lower price for a set time, such as a sale. The previous price returns afterwards."
        case .status: "What App Store Connect still needs for the price and each product before they can be submitted."
        }
    }

    /// A step's purpose for one pricing model; the Price Schedule says what the download price means next to the model's other prices.
    public static func purpose(_ id: StepId, model: PricingModelKind) -> String {
        guard id == .priceSchedule else { return purpose(id) }
        switch model {
        case .subscriptions: return "The app's download price, separate from the subscription prices. People pay for subscriptions inside the app, so a subscription app is usually Free to download. App Store Connect still needs Free set here before the version can be submitted."
        case .freeWithInAppPurchases: return "The app's download price, separate from the in-app purchase prices. People pay for in-app purchases inside the app, so the app is Free to download. App Store Connect still needs Free set here before the version can be submitted."
        case .free: return "The app's download price. A new app has no price until one is set, so App Store Connect needs Free set here before the version can be submitted."
        case .paid, .paidWithInAppPurchases: return "The app's download price: what people pay once before they can download the app. App Store Connect needs it before the version can be submitted."
        }
    }

    /// What Free and Paid mean for the app's download price, next to the model's subscriptions or in-app purchases.
    public static func appPriceChoice(_ model: PricingModelKind) -> String {
        let inside = model.sellsSubscriptions ? "subscriptions" : model.sellsPurchases ? "in-app purchases" : nil
        let free = "Free: people download the app at no cost." + (inside.map { " They pay for \($0) inside the app, and the App Store shows Get with In-App Purchases." } ?? "")
        let paid = "Paid: people pay this price once before they can download the app." + (inside.map { " The \($0) are charged on top of it." } ?? "")
        return free + "\n\n" + paid
    }

    /// One line under the Free and Paid choice that says what the chosen price means for this model.
    public static func appPriceHint(_ model: PricingModelKind, free: Bool) -> String {
        if free { return model.sellsSubscriptions ? "Free to download. Subscriptions keep their own prices." : model.sellsPurchases ? "Free to download. In-app purchases keep their own prices." : "Free to download." }
        return model.sellsSubscriptions ? "People pay to download, then pay for the subscription too." : model.sellsPurchases ? "People pay to download, then pay for in-app purchases too." : "People pay this price once to download the app."
    }

    /// The steps for a pricing model, in App Store Connect's order.
    public static func ids(_ model: PricingModelKind) -> [StepId] {
        switch model {
        case .free: [.appAvailability, .priceSchedule, .status]
        case .paid: [.appAvailability, .priceSchedule, .temporaryPrice, .status]
        case .freeWithInAppPurchases: [.appAvailability, .inAppPurchases, .inAppPurchasePrices, .priceSchedule, .status]
        case .paidWithInAppPurchases: [.appAvailability, .priceSchedule, .temporaryPrice, .inAppPurchases, .inAppPurchasePrices, .status]
        case .subscriptions: [.appAvailability, .subscriptionGroup, .subscriptions, .subscriptionPrices, .introductoryOffers, .otherOffers, .priceSchedule, .status]
        }
    }

    /// Whether App Store Connect has what a required step sets up. Optional steps are never required.
    public static func done(_ id: StepId, state: PricingSetupState) -> Bool {
        func priced(_ items: [PriceProduct]?) -> Bool { items.map { items in !items.isEmpty && items.allSatisfy { state.priced?.contains($0.id) == true } } ?? false }
        switch id {
        case .appAvailability: return state.appAvailable == true
        case .subscriptionGroup: return state.groups?.isEmpty == false
        case .subscriptions: return state.subscriptions?.isEmpty == false
        case .subscriptionPrices: return priced(state.subscriptions)
        case .inAppPurchases: return state.purchases?.isEmpty == false
        case .inAppPurchasePrices: return priced(state.purchases)
        case .priceSchedule: return state.appPrice.isFree || state.appPrice.isPaid
        case .status, .introductoryOffers, .otherOffers, .temporaryPrice: return false
        }
    }

    /// Whether App Store Connect still lists a subscription or in-app purchase as needing something before it can be submitted.
    public static func productsNeedWork(_ state: PricingSetupState) -> Bool {
        ((state.subscriptions ?? []) + (state.purchases ?? [])).contains { ["MISSING_METADATA", "DEVELOPER_ACTION_NEEDED", "REJECTED"].contains($0.state) }
    }

    /// The model's steps with their status: done when Apple has it, the first required step Apple lacks as the next step.
    /// Price and Product Status is done once every required step before it is and no product still needs anything at App Store Connect.
    public static func steps(_ model: PricingModelKind, state: PricingSetupState) -> [Step] {
        let ids = ids(model)
        let required = ids.filter { $0 != .status && !optional.contains($0) }
        let next = required.first { !done($0, state: state) }
        return ids.enumerated().map { index, id in
            let status: Status
            if id == .status { status = next != nil ? .toDo : productsNeedWork(state) ? .current : .done }
            else if optional.contains(id) { status = .optional }
            else if done(id, state: state) { status = .done }
            else { status = id == next ? .current : .toDo }
            return Step(id: id, number: index + 1, status: status, model: model)
        }
    }

    /// The step Pricing opens on: the first required step App Store Connect lacks, else Price and Product Status.
    public static func initial(_ model: PricingModelKind, state: PricingSetupState) -> StepId {
        steps(model, state: state).first { $0.status == .current }?.id ?? .status
    }

    public static func neighbors(_ id: StepId, in model: PricingModelKind) -> (previous: StepId?, next: StepId?) {
        let ids = ids(model)
        guard let index = ids.firstIndex(of: id) else { return (nil, nil) }
        return (index > 0 ? ids[index - 1] : nil, index + 1 < ids.count ? ids[index + 1] : nil)
    }
}
