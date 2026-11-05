import Foundation

/// One subscription in a setup: what is created first, then its first price and introductory offer once Apple has it.
public struct SubscriptionPlan: Sendable, Equatable, Identifiable {
    public var id = UUID().uuidString
    /// Created first: Reference Name, Product ID, Subscription Duration and Family Sharing.
    public var name = "", productId = "", duration = "ONE_MONTH"
    public var familySharing = false
    /// Priced second, once Apple has the subscription: its id, the base-country price and an optional introductory offer.
    public var subscriptionId: String?
    public var amount = ""
    public var offerMode: String?, offerDuration: String?, offerPeriods: Int?, offerAmount: String?
    public init() {}
    /// Equal when they describe the same subscription; the list identity is ignored.
    public static func == (a: Self, b: Self) -> Bool { a.savedJSON == b.savedJSON && a.subscriptionId == b.subscriptionId }

    var createJSON: JSONText { .object([("name", .string(name)), ("productId", .string(productId)), ("duration", .string(duration)), ("familySharing", .bool(familySharing))]) }
    var setupJSON: JSONText {
        var fields: [(String, JSONText)] = [("subscriptionId", .string(subscriptionId ?? "")), ("amount", .string(amount))]
        if let offerMode { fields.append(("offerMode", .string(offerMode))) }
        if let offerDuration { fields.append(("offerDuration", .string(offerDuration))) }
        if let offerPeriods { fields.append(("offerPeriods", .number(Double(offerPeriods)))) }
        if let offerAmount { fields.append(("offerAmount", .string(offerAmount))) }
        return .object(fields)
    }
    /// The whole plan, as saved on this Mac between the two reviews.
    var savedJSON: JSONText {
        var fields: [(String, JSONText)] = [("name", .string(name)), ("productId", .string(productId)), ("duration", .string(duration)), ("familySharing", .bool(familySharing)), ("amount", .string(amount))]
        if let offerMode { fields.append(("offerMode", .string(offerMode))) }
        if let offerDuration { fields.append(("offerDuration", .string(offerDuration))) }
        if let offerPeriods { fields.append(("offerPeriods", .number(Double(offerPeriods)))) }
        if let offerAmount { fields.append(("offerAmount", .string(offerAmount))) }
        return .object(fields)
    }
    init(_ value: JSONText) {
        name = value["name"]?.text ?? ""; productId = value["productId"]?.text ?? ""; duration = value["duration"]?.text ?? "ONE_MONTH"
        familySharing = value["familySharing"] == .bool(true); subscriptionId = value["subscriptionId"]?.text; amount = value["amount"]?.text ?? ""
        offerMode = value["offerMode"]?.text; offerDuration = value["offerDuration"]?.text; offerAmount = value["offerAmount"]?.text
        if case .number(let number)? = value["offerPeriods"], (1...12).contains(Int(number)) { offerPeriods = Int(number) }
    }
    static func keys(_ value: JSONText) -> Set<String> { if case .object(let pairs) = value { Set(pairs.map(\.0)) } else { [] } }
    /// A positive Apple price amount, such as 4.99.
    public static func validAmount(_ value: String) -> Bool { PricingMath.decimal(value).map { $0 > 0 && value.count <= 12 } == true }
}

/// One pricing setup change for a review: the app price, a temporary price, a new product, subscription prices or a subscription offer.
public struct PricingSetupChange: Sendable, Equatable {
    public enum Action: String, Sendable, CaseIterable {
        case appPrice = "app-price", temporaryAppPrice = "temporary-app-price", createInAppPurchase = "create-in-app-purchase", createSubscription = "create-subscription"
        case subscriptionSetup = "subscription-setup"
        /// The app's first App Availability: every country or region, and optionally new ones Apple adds.
        case appAvailability = "app-availability"
        /// What App Review needs on a product: its display name and description in one language, its availability and, for a subscription, its group's display name.
        case productInformation = "product-information"
        case subscriptionPrices = "subscription-prices", introductoryOffer = "introductory-offer", promotionalOffer = "promotional-offer", offerCode = "offer-code", winBackOffer = "win-back-offer"
    }
    /// App Store Connect's choices, as Apple's codes with the words App Store Connect shows.
    public static let purchaseTypes = [("CONSUMABLE", "Consumable"), ("NON_CONSUMABLE", "Non-Consumable"), ("NON_RENEWING_SUBSCRIPTION", "Non-Renewing Subscription")]
    public static let subscriptionDurations = [("ONE_WEEK", "1 Week"), ("ONE_MONTH", "1 Month"), ("TWO_MONTHS", "2 Months"), ("THREE_MONTHS", "3 Months"), ("SIX_MONTHS", "6 Months"), ("ONE_YEAR", "1 Year")]
    public static let offerDurations = [("THREE_DAYS", "3 Days"), ("ONE_WEEK", "1 Week"), ("TWO_WEEKS", "2 Weeks"), ("ONE_MONTH", "1 Month"), ("TWO_MONTHS", "2 Months"), ("THREE_MONTHS", "3 Months"), ("SIX_MONTHS", "6 Months"), ("ONE_YEAR", "1 Year")]
    public static let offerModes = [("FREE_TRIAL", "Free Trial"), ("PAY_AS_YOU_GO", "Pay As You Go"), ("PAY_UP_FRONT", "Pay Up Front")]
    public static let eligibilities = [("NEW", "New Subscribers"), ("EXISTING", "Existing Subscribers"), ("EXPIRED", "Expired Subscribers")]
    public static let stackings = [("STACK_WITH_INTRO_OFFERS", "Stack with Introductory Offers"), ("REPLACE_INTRO_OFFERS", "Replace Introductory Offers")]
    public static let priorities = [("NORMAL", "Normal"), ("HIGH", "High")]
    public static func label(_ code: String?, in choices: [(String, String)]) -> String { choices.first { $0.0 == code }?.1 ?? code ?? "" }

    public var action: Action
    public var territory, pricePointId, startDate, endDate: String?
    public var name, productId, productType, groupId, groupName, subscriptionId: String?
    public var offerMode, duration, offerId, stacking, priority: String?
    /// A launch sale (with `startDate` and `endDate`) and a later price change for the app price.
    public var salePointId, changePointId, changeDate: String?
    /// A product's Apple id and kind ("purchase" or "subscription"), with its localized display name, description and group display name.
    public var itemId, itemKind, locale, displayName, details, groupDisplayName: String?
    public var periods, paidMonths, lapsedMinimum, lapsedMaximum, waitMonths: Int?
    public var allTerritories, preserveCurrentPrice, familySharing: Bool?
    public var eligibilities: [String]?
    public var plans: [SubscriptionPlan]?
    /// A subscription price chosen per country or region, such as by a pricing profile: territory code to the Apple price point.
    public var territoryPoints: [String: String]?
    public init(action: Action) { self.action = action }

    private var texts: [(String, String?)] {
        [("territory", territory), ("pricePointId", pricePointId), ("startDate", startDate), ("endDate", endDate), ("name", name), ("productId", productId), ("productType", productType),
         ("groupId", groupId), ("groupName", groupName), ("subscriptionId", subscriptionId), ("offerMode", offerMode), ("duration", duration), ("offerId", offerId), ("stacking", stacking), ("priority", priority),
         ("salePointId", salePointId), ("changePointId", changePointId), ("changeDate", changeDate), ("itemId", itemId), ("itemKind", itemKind), ("locale", locale),
         ("displayName", displayName), ("details", details), ("groupDisplayName", groupDisplayName)]
    }
    private var numbers: [(String, Int?)] { [("periods", periods), ("paidMonths", paidMonths), ("lapsedMinimum", lapsedMinimum), ("lapsedMaximum", lapsedMaximum), ("waitMonths", waitMonths)] }
    private var flags: [(String, Bool?)] { [("allTerritories", allTerritories), ("preserveCurrentPrice", preserveCurrentPrice), ("familySharing", familySharing)] }

    var json: JSONText {
        var fields: [(String, JSONText)] = [("action", .string(action.rawValue))]
        for (key, value) in texts { if let value { fields.append((key, .string(value))) } }
        for (key, value) in numbers { if let value { fields.append((key, .number(Double(value)))) } }
        for (key, value) in flags { if let value { fields.append((key, .bool(value))) } }
        if let eligibilities { fields.append(("eligibilities", .array(eligibilities.map { .string($0) }))) }
        if let plans { fields.append(("plans", .array(plans.map { action == .subscriptionSetup ? $0.setupJSON : $0.createJSON }))) }
        if let territoryPoints { fields.append(("territoryPoints", .object(territoryPoints.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }))) }
        return .object(fields)
    }

    init?(_ value: JSONText) {
        guard let action = value["action"]?.text.flatMap(Action.init) else { return nil }
        self.init(action: action)
        territory = value["territory"]?.text; pricePointId = value["pricePointId"]?.text; startDate = value["startDate"]?.text; endDate = value["endDate"]?.text
        name = value["name"]?.text; productId = value["productId"]?.text; productType = value["productType"]?.text; groupId = value["groupId"]?.text; groupName = value["groupName"]?.text
        subscriptionId = value["subscriptionId"]?.text; offerMode = value["offerMode"]?.text; duration = value["duration"]?.text; offerId = value["offerId"]?.text
        stacking = value["stacking"]?.text; priority = value["priority"]?.text
        salePointId = value["salePointId"]?.text; changePointId = value["changePointId"]?.text; changeDate = value["changeDate"]?.text
        itemId = value["itemId"]?.text; itemKind = value["itemKind"]?.text; locale = value["locale"]?.text; displayName = value["displayName"]?.text; details = value["details"]?.text; groupDisplayName = value["groupDisplayName"]?.text
        func number(_ key: String) -> Int? { if case .number(let number)? = value[key], number.rounded() == number, abs(number) < 10_000 { return Int(number) }; return nil }
        periods = number("periods"); paidMonths = number("paidMonths"); lapsedMinimum = number("lapsedMinimum"); lapsedMaximum = number("lapsedMaximum"); waitMonths = number("waitMonths")
        if case .bool(let flag)? = value["allTerritories"] { allTerritories = flag }
        if case .bool(let flag)? = value["preserveCurrentPrice"] { preserveCurrentPrice = flag }
        if case .bool(let flag)? = value["familySharing"] { familySharing = flag }
        if case .array(let items)? = value["eligibilities"] { eligibilities = items.compactMap(\.text) }
        if case .object(let pairs)? = value["territoryPoints"] {
            guard pairs.count <= 200 else { return nil }
            var points: [String: String] = [:]
            for (code, point) in pairs { guard let id = point.text else { return nil }; points[code] = id }
            territoryPoints = points
        }
        if case .array(let items)? = value["plans"] {
            guard items.count <= 10 else { return nil }
            plans = items.map { item in var plan = SubscriptionPlan(item); plan.id = "plan-\(plan.productId)-\(plan.subscriptionId ?? "")"; return plan }
        }
    }

    public static func == (a: Self, b: Self) -> Bool { a.json == b.json }

    private static let allowed: [Action: Set<String>] = [
        .appPrice: ["territory", "pricePointId", "salePointId", "startDate", "endDate", "changePointId", "changeDate"], .temporaryAppPrice: ["territory", "pricePointId", "startDate", "endDate"],
        .createInAppPurchase: ["name", "productId", "productType", "familySharing"], .createSubscription: ["groupId", "groupName", "plans"],
        .subscriptionSetup: ["territory", "allTerritories", "plans"], .appAvailability: ["allTerritories"],
        .productInformation: ["itemId", "itemKind", "locale", "displayName", "details", "groupDisplayName", "allTerritories"],
        .subscriptionPrices: ["subscriptionId", "territory", "pricePointId", "startDate", "preserveCurrentPrice", "allTerritories", "territoryPoints"],
        .introductoryOffer: ["subscriptionId", "territory", "pricePointId", "startDate", "endDate", "offerMode", "duration", "periods", "allTerritories"],
        .promotionalOffer: ["subscriptionId", "territory", "pricePointId", "name", "offerId", "offerMode", "duration", "periods", "allTerritories"],
        .offerCode: ["subscriptionId", "territory", "pricePointId", "name", "eligibilities", "stacking", "offerMode", "duration", "periods", "allTerritories"],
        .winBackOffer: ["subscriptionId", "territory", "pricePointId", "name", "offerId", "offerMode", "duration", "periods", "allTerritories", "startDate", "endDate", "paidMonths", "lapsedMinimum", "lapsedMaximum", "waitMonths", "priority"],
    ]
    /// Reference Names and offer names: trimmed, up to 64 characters, without control characters.
    public static func referenceName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64, !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        return trimmed
    }
    /// Apple's Product ID: letters, numbers, underscores and periods.
    public static func validProductId(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9._]{1,100}$", options: .regularExpression) != nil }
    public static func validOfferId(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil }
    /// Display text for App Store: trimmed, within Apple's limit, without control characters.
    public static func displayText(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit, !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        return trimmed
    }
    public static let displayNameLimit = 35, descriptionLimit = 55, groupNameLimit = 75
    static func validOffer(mode: String?, duration: String?, periods: Int?) -> Bool {
        offerModes.contains { $0.0 == mode } && offerDurations.contains { $0.0 == duration } && (1...12).contains(periods ?? 0) && (mode == "PAY_AS_YOU_GO" || periods == 1)
    }

    func validated() throws -> Self {
        func need(_ condition: Bool, _ message: String) throws { if !condition { throw PublishFailure.invalid(message) } }
        guard case .object(let fields) = json, Set(fields.map(\.0)).subtracting(["action"]).isSubset(of: Self.allowed[action]!) else { throw PublishFailure.invalid("Choose only the fields for this pricing change.") }
        var result = self
        let dates = [startDate, endDate, changeDate].compactMap { $0 }
        try need(dates.allSatisfy(ProductPricing.calendarDate), "Enter dates as YYYY-MM-DD.")
        if let startDate, let endDate { try need(startDate <= endDate, "The end date must be on or after the start date.") }
        try need([pricePointId, subscriptionId, groupId, salePointId, changePointId].compactMap { $0 }.allSatisfy(ProductPricing.opaque), "Choose a valid Apple product and price level.")
        try need(territory.map(ProductPricing.territory) ?? true, "Choose one country or region.")
        switch action {
        case .appAvailability:
            try need(allTerritories != nil, "Choose whether new countries and regions are included.")
        case .appPrice, .temporaryAppPrice:
            try need(territory != nil && pricePointId != nil, "Choose a country or region and a price.")
            if action == .temporaryAppPrice { try need(startDate != nil && endDate != nil, "Choose the first and last day of the temporary price.") }
            else {
                try need((salePointId == nil) == (startDate == nil) && (startDate == nil) == (endDate == nil), "Choose the launch sale's price, start date and end date.")
                try need((changePointId == nil) == (changeDate == nil), "Choose the new price and the date it starts.")
                if let endDate, let changeDate { try need(changeDate > endDate, "The price change must start after the launch sale ends.") }
            }
        case .createInAppPurchase:
            result.name = Self.referenceName(name)
            try need(result.name != nil, "Enter a Reference Name of up to 64 characters.")
            try need(productId.map(Self.validProductId) == true, "Enter a Product ID with letters, numbers, underscores or periods.")
            try need(Self.purchaseTypes.contains { $0.0 == productType }, "Choose the in-app purchase type.")
            try need(familySharing != true || productType == "NON_CONSUMABLE", "Family Sharing applies to non-consumable in-app purchases.")
        case .createSubscription:
            result.groupName = Self.referenceName(groupName)
            try need((groupId == nil) != (groupName == nil) && (groupName == nil || result.groupName != nil), "Choose an existing Subscription Group or enter a Reference Name for a new one.")
            let plans = plans ?? []
            try need((1...10).contains(plans.count), "Add one to ten subscriptions.")
            try need(plans.allSatisfy { plan in Self.referenceName(plan.name) != nil && Self.validProductId(plan.productId) && Self.subscriptionDurations.contains { $0.0 == plan.duration } },
                     "Give each subscription a Reference Name, a Product ID and a Subscription Duration.")
            try need(Set(plans.map { $0.productId.lowercased() }).count == plans.count, "Give each subscription its own Product ID.")
            result.plans = plans.map { var plan = $0; plan.name = Self.referenceName($0.name)!; plan.subscriptionId = nil; plan.amount = ""; plan.offerMode = nil; plan.offerDuration = nil; plan.offerPeriods = nil; plan.offerAmount = nil; return plan }
        case .subscriptionSetup:
            let plans = plans ?? []
            try need(territory != nil && allTerritories != nil && (1...10).contains(plans.count), "Choose the base country or region and the subscriptions to price.")
            try need(plans.allSatisfy { $0.subscriptionId.map(ProductPricing.opaque) == true && SubscriptionPlan.validAmount($0.amount) }, "Choose a price for each subscription.")
            try need(Set(plans.compactMap(\.subscriptionId)).count == plans.count, "Choose each subscription once.")
            try need(plans.allSatisfy { $0.offerMode == nil ? $0.offerDuration == nil && $0.offerAmount == nil && $0.offerPeriods == nil
                                         : Self.validOffer(mode: $0.offerMode, duration: $0.offerDuration, periods: $0.offerPeriods) && ($0.offerMode == "FREE_TRIAL") == ($0.offerAmount == nil) && ($0.offerAmount.map(SubscriptionPlan.validAmount) ?? true) },
                     "Choose the introductory offer's type, duration and price.")
        case .productInformation:
            try need(itemId.map(ProductPricing.opaque) == true && ["purchase", "subscription"].contains(itemKind ?? ""), "Choose an in-app purchase or subscription.")
            try need(displayName != nil || allTerritories == true || groupDisplayName != nil, "Choose what to set for this product.")
            try need((displayName == nil && details == nil && groupDisplayName == nil) || StoreLocales.codes.contains(locale ?? ""), "Choose an App Store language.")
            try need(allTerritories == nil || allTerritories == true, "Availability can only be set to every country or region here.")
            try need(groupDisplayName == nil || itemKind == "subscription", "A group display name belongs to a subscription.")
            if displayName != nil || details != nil {
                result.displayName = Self.displayText(displayName, limit: Self.displayNameLimit); result.details = Self.displayText(details, limit: Self.descriptionLimit)
                try need(result.displayName != nil && result.details != nil, "Enter a display name of up to 35 characters and a description of up to 55.")
            }
            if groupDisplayName != nil {
                result.groupDisplayName = Self.displayText(groupDisplayName, limit: Self.groupNameLimit)
                try need(result.groupDisplayName != nil, "Enter the Subscription Group display name, up to 75 characters.")
            }
        case .subscriptionPrices:
            try need(subscriptionId != nil && territory != nil && pricePointId != nil, "Choose a subscription, a country or region and a price.")
            try need(preserveCurrentPrice != nil && allTerritories != nil, "Choose whether existing subscribers keep their price and which countries and regions change.")
            if let territoryPoints {
                try need(allTerritories == false && (1...200).contains(territoryPoints.count) && territoryPoints[territory!] == pricePointId,
                         "Prices per country or region include the base country or region and replace Apple's comparable prices.")
                try need(territoryPoints.allSatisfy { ProductPricing.territory($0.key) && ProductPricing.opaque($0.value) }, "Choose a valid Apple price for each country or region.")
            }
        case .introductoryOffer, .promotionalOffer, .offerCode, .winBackOffer:
            try need(subscriptionId != nil && allTerritories != nil && territory != nil, "Choose a subscription and the countries or regions for this offer.")
            try need(Self.offerModes.contains { $0.0 == offerMode } && Self.offerDurations.contains { $0.0 == duration }, "Choose the offer type and duration.")
            try need(Self.validOffer(mode: offerMode, duration: duration, periods: periods), "Pay As You Go runs 1 to 12 periods; other offers run one period.")
            try need((offerMode == "FREE_TRIAL") == (pricePointId == nil), offerMode == "FREE_TRIAL" ? "A free trial has no price." : "Choose the offer price.")
            if action != .introductoryOffer {
                result.name = Self.referenceName(name)
                try need(result.name != nil, "Enter a Reference Name of up to 64 characters.")
            }
            if action == .promotionalOffer || action == .winBackOffer { try need(offerId.map(Self.validOfferId) == true, "Enter an offer identifier with letters, numbers, hyphens, underscores or periods.") }
            if action == .offerCode {
                let chosen = eligibilities ?? []
                try need(!chosen.isEmpty && Set(chosen).count == chosen.count && chosen.allSatisfy { code in Self.eligibilities.contains { $0.0 == code } }, "Choose who is eligible for the offer code.")
                try need(Self.stackings.contains { $0.0 == stacking }, "Choose how the offer code works with introductory offers.")
            }
            if action == .winBackOffer {
                try need(startDate != nil && Self.priorities.contains { $0.0 == priority }, "Choose the start date and priority.")
                try need((1...24).contains(paidMonths ?? 0) && (1...24).contains(lapsedMinimum ?? 0) && (lapsedMinimum ?? 0) <= (lapsedMaximum ?? 0) && (lapsedMaximum ?? 0) <= 24, "Enter eligibility months from 1 to 24.")
                try need(waitMonths.map { (1...24).contains($0) } ?? true, "Enter the wait between offers from 1 to 24 months.")
            }
        }
        return result
    }
}

/// Writes this review type sends; each is checked with fresh Apple reads just before it is sent.
enum PricingSetupWrites {
    static let roots: Set<String> = ["appAvailabilities", "appPriceSchedules", "inAppPurchases", "subscriptionGroups", "subscriptions", "subscriptionPrices", "subscriptionIntroductoryOffers", "subscriptionPromotionalOffers", "subscriptionOfferCodes", "winBackOffers",
                                     "subscriptionAvailabilities", "inAppPurchaseAvailabilities", "subscriptionVersions", "inAppPurchaseVersions", "subscriptionGroupVersions", "subscriptionLocalizations", "inAppPurchaseLocalizations", "subscriptionGroupLocalizations"]
    /// Writes Apple accepts only through version 2 of its API.
    static let version2: Set<String> = ["appAvailabilities", "inAppPurchases", "subscriptionLocalizations", "inAppPurchaseLocalizations", "subscriptionGroupLocalizations"]
    /// The app's first availability: every country or region, each a territory availability included in the same request.
    static func appAvailability(appId: String, territories: [String], future: Bool) -> JSONText {
        .object([("data", .object([("type", .string("appAvailabilities")), ("attributes", .object([("availableInNewTerritories", .bool(future))])),
                                   ("relationships", .object([("app", Apple.relationship("apps", .string(appId))),
                                                              ("territoryAvailabilities", .object([("data", .array(territories.map { .object([("type", .string("territoryAvailabilities")), ("id", .string("${\($0)}"))]) }))]))]))])),
                 ("included", .array(territories.map { code in
                     .object([("type", .string("territoryAvailabilities")), ("id", .string("${\(code)}")), ("attributes", .object([("available", .bool(true))])),
                              ("relationships", .object([("territory", Apple.relationship("territories", .string(code)))]))])
                 }))])
    }
    static func offerRoot(_ action: PricingSetupChange.Action) -> (root: String, prices: String, list: String)? {
        switch action {
        case .promotionalOffer: ("subscriptionPromotionalOffers", "subscriptionPromotionalOfferPrices", "promotionalOffers")
        case .offerCode: ("subscriptionOfferCodes", "subscriptionOfferCodePrices", "offerCodes")
        case .winBackOffer: ("winBackOffers", "winBackOfferPrices", "winBackOffers")
        default: nil
        }
    }
    static func digest(_ items: [AppStoreConnectClient.Resource]) -> String {
        Apple.sha(Apple.canonical(.array(items.sorted { ($0.type, $0.id) < ($1.type, $1.id) }.map(Planner.resource))))
    }
    static func productsDigest(_ catalog: ProductCatalog) throws -> String {
        guard let purchases = catalog.purchases, let subscriptions = catalog.subscriptions else { throw PublishFailure.invalid("Apple did not return the app's complete product list. Refresh and try again.") }
        return Apple.sha(Apple.canonical(.array((purchases + subscriptions).map(\.json).sorted { $0.stringify() < $1.stringify() })))
    }
    /// The app's products, leaving out the Product IDs this review creates, so each creation step still matches after the ones before it.
    static func productsDigest(_ catalog: ProductCatalog, excluding planned: [String]) throws -> String {
        guard let purchases = catalog.purchases, let subscriptions = catalog.subscriptions else { throw PublishFailure.invalid("Apple did not return the app's complete product list. Refresh and try again.") }
        return Apple.sha(Apple.canonical(.array((purchases + subscriptions).filter { !planned.contains($0.productId.lowercased()) }.map(\.json).sorted { $0.stringify() < $1.stringify() })))
    }
    static func groupsDigest(_ groups: [SubscriptionGroupSummary]) -> String { Apple.sha(Apple.canonical(.array(groups.map { .string($0.referenceName.lowercased()) }.sorted { $0.stringify() < $1.stringify() }))) }
    static func setupDigest(_ rows: [ProductPrice], _ offers: [AppStoreConnectClient.Resource]) -> String { Apple.sha(rowsDigest(rows) + digest(offers)) }
    static func rowsDigest(_ rows: [ProductPrice]) -> String {
        Apple.sha(Apple.canonical(.array(rows.sorted { ($0.source.rawValue, $0.id) < ($1.source.rawValue, $1.id) }.map(\.json))))
    }
    static func subscription(_ catalog: ProductCatalog, _ id: String?) throws -> PriceProduct {
        guard let product = catalog.subscriptions?.first(where: { $0.id == id }) else { throw PublishFailure.invalid("The subscription is unavailable or no longer belongs to this app.") }
        return product
    }
}

extension WorkspaceSession {
    /// The app's price schedule with at least one manual price, or nil when Apple has no price for the app yet.
    func setupAppSchedule(appId: String, client: AppStoreConnectClient, planner: Planner?) async throws -> (schedule: String, base: String, manual: [PriceRow], automatic: [PriceRow], pointIds: [String: String], digest: String)? {
        let reads = planner.map(AppleReads.init) ?? AppleReads(client)
        guard let id = try await PricingSetupReads.scheduleId(appId: appId, reads: reads) else { return nil }
        if try await reads.pages("/v1/appPriceSchedules/\(id)/manualPrices?limit=200&include=appPricePoint%2Cterritory").data.isEmpty { return nil }
        return try await priceScheduleSnapshot(appId: appId, client: client, planner: planner)
    }

    static func appScheduleBody(appId: String, base: String, intervals: [PriceInterval]) -> JSONText {
        let included = intervals.enumerated().map { index, item in
            JSONText.object([("type", .string("appPrices")), ("id", .string("${price-\(index)}")), ("attributes", .object([("startDate", item.start.map { .string($0) } ?? .null), ("endDate", item.end.map { .string($0) } ?? .null)])),
                             ("relationships", .object([("appPricePoint", Apple.relationship("appPricePoints", .string(item.pointId)))]))])
        }
        return .object([("data", .object([("type", .string("appPriceSchedules")), ("relationships", .object([("app", Apple.relationship("apps", .string(appId))), ("baseTerritory", Apple.relationship("territories", .string(base))),
                                                                                                          ("manualPrices", .object([("data", .array(included.map { .object([("type", $0["type"]!), ("id", $0["id"]!)]) }))]))]))])), ("included", .array(included))])
    }
    static func describe(_ rows: [PriceInterval]) -> String {
        rows.map { "\($0.territory): \($0.amount) \($0.currency) · \($0.start ?? "Now") → \($0.end.map { "before \($0)" } ?? "ongoing")" }.joined(separator: "\n")
    }

    func planPricingSetup(_ planner: Planner) async throws -> String {
        guard let change = planner.request.pricingSetup else { throw PublishFailure.invalid("Choose one pricing change.") }
        let appId = planner.request.appId, reads = AppleReads(planner), today = ProductPricing.today()
        func setupGuard(_ digest: String, _ extra: [(String, JSONText)] = []) -> JSONText { .object([("kind", .string("pricing-setup")), ("action", .string(change.action.rawValue)), ("digest", .string(digest))] + extra) }
        switch change.action {
        case .appPrice, .temporaryAppPrice:
            let territory = change.territory!, snapshot = try await setupAppSchedule(appId: appId, client: planner.client, planner: planner)
            guard try await PricingSetupReads.territories(reads: reads).contains(territory) else { throw PublishFailure.invalid("This country or region is not available at Apple.") }
            let levels = try await PricingSetupReads.appPoints(appId: appId, territory: territory, reads: reads)
            func level(_ id: String?) throws -> PriceInterval? {
                guard let id else { return nil }
                guard let point = levels.first(where: { $0.id == id }), let amount = point.customerPrice, let currency = point.currency else { throw PublishFailure.invalid("The selected price is no longer available at Apple.") }
                return PriceInterval(territory: territory, pointId: point.id, amount: amount, currency: currency, start: nil, end: nil)
            }
            let price = try level(change.pricePointId)!, amount = price.amount, currency = price.currency
            func intervals(_ rows: [PriceRow]) -> [PriceInterval] {
                rows.filter { $0.endDate.map { $0 > today } ?? true }.map { PriceInterval(territory: $0.territory, pointId: snapshot?.pointIds[$0.id] ?? "", amount: $0.customerPrice, currency: $0.currency, start: $0.startDate.flatMap { $0 > today ? $0 : nil }, end: $0.endDate) }
            }
            let manual = snapshot.map { intervals($0.manual) } ?? []
            if change.action == .appPrice {
                let free = PricingMath.decimal(amount) == 0, sale = try level(change.salePointId), later = try level(change.changePointId)
                if let start = change.startDate, start < today { throw PublishFailure.invalid("Choose today or a later start date for the launch sale.") }
                if let date = change.changeDate, date <= today { throw PublishFailure.invalid("Choose a date after today for the price change.") }
                var plan: [PriceInterval] = []
                let saleStart = change.startDate.flatMap { $0 > today ? $0 : nil }
                if sale == nil || saleStart != nil { var first = price; first.end = saleStart ?? change.changeDate; plan.append(first) }
                if var sale, let last = change.endDate {
                    let back = try Self.nextDate(last)
                    sale.start = saleStart; sale.end = back; plan.append(sale)
                    if back != change.changeDate { var after = price; after.start = back; after.end = change.changeDate; plan.append(after) }
                }
                if var later, let date = change.changeDate { later.start = date; plan.append(later) }
                if sale == nil, later == nil, let snapshot, snapshot.base == territory, manual.count == 1, manual[0].pointId == price.pointId, manual[0].start == nil, manual[0].end == nil {
                    planner.notes.append("Apple already has this price. No write is needed."); return free ? "Price already Free" : "Price already set"
                }
                planner.add(.api, method: "POST", path: [.string("appPriceSchedules")], label: free ? "Set the price to Free" : "Set the price · \(amount) \(currency) in \(WorkspaceSession.countryName(territory))",
                            detail: "Replace the app's price schedule with the reviewed base prices. Apple sets equalized prices in the other countries and regions.",
                            before: snapshot == nil ? "No price at Apple" : Self.describe(manual), after: Self.describe(plan) + "\nOther countries and regions: Apple's equalized prices",
                            body: Self.appScheduleBody(appId: appId, base: territory, intervals: plan), guard: setupGuard(snapshot?.digest ?? "none", [("territory", .string(territory)), ("pricePointId", .string(price.pointId))]))
                if let snapshot, manual.count > 1 || snapshot.base != territory { planner.notes.append("This removes the \(manual.count) manual prices listed under Before, including scheduled price changes. Countries and regions you priced by hand then follow Apple's equalized prices.") }
                if sale != nil { planner.notes.append("The launch sale includes \(change.endDate!). The price returns to \(amount) \(currency) the next day.") }
                planner.notes.append(free ? "Free applies in every country or region where the app is available." : "Apple adjusts equalized prices for taxes and exchange rates over time.")
                return free ? "Set the price to Free" : "Set the price · \(amount) \(currency)"
            }
            guard let snapshot else { throw PublishFailure.invalid("Set the app's price first. A temporary price returns to it afterwards.") }
            let start = change.startDate!, last = change.endDate!
            guard start >= today else { throw PublishFailure.invalid("Choose today or a later first day for the temporary price.") }
            let end = try Self.nextDate(last)
            let current = manual.last { $0.territory == territory && $0.start == nil } ?? (snapshot.automatic.contains { $0.territory == territory } ? price : nil)
            guard current != nil else { throw PublishFailure.invalid("\(WorkspaceSession.countryName(territory)) has no current price to return to after the temporary price.") }
            if manual.contains(where: { $0.territory == territory && ($0.start.map { $0 < end } ?? false) && ($0.end.map { $0 > start } ?? true) }) {
                throw PublishFailure.invalid("\(WorkspaceSession.countryName(territory)) already has a scheduled price in these dates. Change or remove it in App Store Connect under Pricing and Availability first.")
            }
            var sale = price; sale.start = start; sale.end = end
            let final = try Self.overlay(manual, sale, today: today)
            guard final.contains(where: { $0.territory == snapshot.base && $0.start == nil }), final.count <= 2000 else { throw PublishFailure.invalid("The base price would be missing. Refresh the app's prices first.") }
            planner.add(.api, method: "POST", path: [.string("appPriceSchedules")], label: "Temporary price · \(amount) \(currency) in \(WorkspaceSession.countryName(territory)) · \(start) to \(last)",
                        detail: "Send the app's manual prices with the temporary price inserted. Every other manual price stays as it is.",
                        before: Self.describe(manual.filter { $0.territory == territory }), after: Self.describe(final.filter { $0.territory == territory }),
                        body: Self.appScheduleBody(appId: appId, base: snapshot.base, intervals: final), guard: setupGuard(snapshot.digest, [("territory", .string(territory)), ("pricePointId", .string(price.pointId))]))
            if territory == snapshot.base { planner.notes.append("Countries and regions with Apple's equalized prices follow the temporary price and return afterwards. Countries and regions you priced by hand keep their prices.") }
            planner.notes.append("The temporary price includes \(last). Apple shows its end as \(end), the first day the previous price returns.")
            return "Temporary price · \(start) to \(last)"

        case .createInAppPurchase:
            let catalog = try await ProductPricing.catalog(appId: appId, reads: reads), digest = try PricingSetupWrites.productsDigest(catalog)
            guard !((catalog.purchases ?? []) + (catalog.subscriptions ?? [])).contains(where: { $0.productId.caseInsensitiveCompare(change.productId!) == .orderedSame }) else { throw PublishFailure.invalid("Another product of this app already uses this Product ID.") }
            let type = PricingSetupChange.label(change.productType, in: PricingSetupChange.purchaseTypes)
            planner.add(.api, method: "POST", path: [.string("v2"), .string("inAppPurchases")], label: "Create \(type) · \(change.name!)", detail: "Create the in-app purchase. Apple adds it as Missing Metadata until it has a price, a localization and a review screenshot.",
                        before: "Not at Apple", after: "\(type)\nReference Name: \(change.name!)\nProduct ID: \(change.productId!)\(change.familySharing == true ? "\nFamily Sharing: On" : "")",
                        body: .object([("data", .object([("type", .string("inAppPurchases")), ("attributes", .object([("name", .string(change.name!)), ("productId", .string(change.productId!)), ("inAppPurchaseType", .string(change.productType!))] + (change.familySharing == true ? [("familySharable", .bool(true))] : []))),
                                                         ("relationships", .object([("app", Apple.relationship("apps", .string(appId)))]))]))]),
                        guard: setupGuard(digest))
            planner.notes.append("A Product ID cannot be changed or used again, even after the product is deleted.")
            planner.notes.append("Next, set its price in In-App Purchases and Subscriptions. Add its localization and review screenshot in App Store Connect under Monetization → In-App Purchases.")
            return "Create in-app purchase · \(change.name!)"

        case .createSubscription:
            let catalog = try await ProductPricing.catalog(appId: appId, reads: reads), plans = change.plans!
            let planned = plans.map { $0.productId.lowercased() }, digest = try PricingSetupWrites.productsDigest(catalog, excluding: planned)
            let groups = try await PricingSetupReads.groups(appId: appId, reads: reads)
            guard !((catalog.purchases ?? []) + (catalog.subscriptions ?? [])).contains(where: { planned.contains($0.productId.lowercased()) }) else { throw PublishFailure.invalid("Another product of this app already uses one of these Product IDs.") }
            let group: JSONText, groupName: String
            if let name = change.groupName {
                guard !groups.contains(where: { $0.referenceName.caseInsensitiveCompare(name) == .orderedSame }) else { throw PublishFailure.invalid("A Subscription Group with this Reference Name already exists. Choose it instead.") }
                let key = planner.add(.api, method: "POST", path: [.string("subscriptionGroups")], label: "Create Subscription Group · \(name)", detail: "Create the group. People can subscribe to one subscription in a group at a time.",
                                      before: "Not at Apple", after: "Reference Name: \(name)",
                                      body: .object([("data", .object([("type", .string("subscriptionGroups")), ("attributes", .object([("referenceName", .string(name))])), ("relationships", .object([("app", Apple.relationship("apps", .string(appId)))]))]))]),
                                      guard: .object([("kind", .string("pricing-setup")), ("action", .string("create-subscription-group")), ("digest", .string(PricingSetupWrites.digest([]))), ("groups", .string(PricingSetupWrites.groupsDigest(groups)))]))
                group = Apple.ref(key); groupName = name
            } else {
                guard let existing = groups.first(where: { $0.id == change.groupId }) else { throw PublishFailure.invalid("The Subscription Group is unavailable or no longer belongs to this app.") }
                group = .string(existing.id); groupName = existing.referenceName
            }
            for plan in plans {
                let duration = PricingSetupChange.label(plan.duration, in: PricingSetupChange.subscriptionDurations)
                var attributes: [(String, JSONText)] = [("name", .string(plan.name)), ("productId", .string(plan.productId)), ("subscriptionPeriod", .string(plan.duration))]
                if plan.familySharing { attributes.append(("familySharable", .bool(true))) }
                planner.add(.api, method: "POST", path: [.string("subscriptions")], label: "Create subscription · \(plan.name) · \(duration)", detail: "Create the auto-renewable subscription in \(groupName). Apple adds it as Missing Metadata until it has prices and a localization.",
                            before: "Not at Apple", after: "Subscription Group: \(groupName)\nReference Name: \(plan.name)\nProduct ID: \(plan.productId)\nSubscription Duration: \(duration)\nFamily Sharing: \(plan.familySharing ? "On" : "Off")",
                            body: .object([("data", .object([("type", .string("subscriptions")), ("attributes", .object(attributes)), ("relationships", .object([("group", Apple.relationship("subscriptionGroups", group))]))]))]),
                            guard: setupGuard(digest, [("planned", .array(planned.map { .string($0) }))]), group: "Subscriptions")
            }
            planner.notes.append("A Product ID cannot be changed or used again, even after the subscription is deleted.")
            if plans.contains(where: \.familySharing) { planner.notes.append("Family Sharing cannot be turned off again once it is on.") }
            planner.notes.append("Apple gives a new subscription its price list once it exists. The next review sets the prices and introductory offer you chose.")
            return plans.count == 1 ? "Create subscription · \(plans[0].name)" : "Create \(plans.count) subscriptions"

        case .subscriptionSetup:
            let catalog = try await ProductPricing.catalog(appId: appId, reads: reads), base = change.territory!
            let everywhere = change.allTerritories == true, territories = try await PricingSetupReads.territories(reads: reads)
            for plan in change.plans! {
                let product = try PricingSetupWrites.subscription(catalog, plan.subscriptionId)
                let schedule = try await ProductPricing.schedule(product, reads: reads)
                guard schedule.rows.isEmpty else { throw PublishFailure.invalid("\(product.name) already has prices. Change them in Subscription Prices.") }
                let points = try await ProductPricing.points(product, territory: base, reads: reads)
                func matching(_ amount: String) async throws -> [ProductPricePoint] {
                    guard let point = points.first(where: { PricingMath.decimal($0.customerPrice ?? "") == PricingMath.decimal(amount) }), point.currency != nil else {
                        throw PublishFailure.invalid("\(amount) is not an Apple subscription price in \(WorkspaceSession.countryName(base)). Choose another price for \(product.name).")
                    }
                    let others = everywhere ? try await PricingSetupReads.equalized(point.id, reads: reads).filter { $0.territory != base } : []
                    guard others.allSatisfy({ $0.customerPrice != nil && $0.currency != nil }) else { throw PublishFailure.invalid("Apple returned an equalized price without an amount.") }
                    return [point] + others
                }
                let prices = try await matching(plan.amount)
                let existing = plan.offerMode == nil ? [] : try await setupOffers(product.id, list: "introductoryOffers", type: "subscriptionIntroductoryOffers", reads: reads)
                guard existing.isEmpty else { throw PublishFailure.invalid("\(product.name) already has an introductory offer. Add more offers in Offers.") }
                var offerPoints: [String: ProductPricePoint]?
                if let amount = plan.offerAmount { offerPoints = Dictionary(uniqueKeysWithValues: try await matching(amount).map { ($0.territory, $0) }) }
                let offerTerritories = plan.offerMode == nil ? [] : offerPoints.map { Array($0.keys).sorted() } ?? (everywhere ? territories : [base])
                var included: [JSONText] = prices.enumerated().map { index, point in
                    .object([("type", .string("subscriptionPrices")), ("id", .string("${price-\(index)}")), ("attributes", .object([("startDate", .null), ("preserveCurrentPrice", .bool(false))])),
                             ("relationships", .object([("subscription", Apple.relationship("subscriptions", .string(product.id))), ("subscriptionPricePoint", Apple.relationship("subscriptionPricePoints", .string(point.id)))]))])
                }
                let offers: [JSONText] = offerTerritories.enumerated().map { index, territory in
                    var relationships: [(String, JSONText)] = [("subscription", Apple.relationship("subscriptions", .string(product.id))), ("territory", Apple.relationship("territories", .string(territory)))]
                    if let point = offerPoints?[territory] { relationships.append(("subscriptionPricePoint", Apple.relationship("subscriptionPricePoints", .string(point.id)))) }
                    return .object([("type", .string("subscriptionIntroductoryOffers")), ("id", .string("${offer-\(index)}")),
                                    ("attributes", .object([("duration", .string(plan.offerDuration!)), ("offerMode", .string(plan.offerMode!)), ("numberOfPeriods", .number(Double(plan.offerPeriods!)))])),
                                    ("relationships", .object(relationships))])
                }
                included += offers
                var relationships: [(String, JSONText)] = [("prices", .object([("data", .array(prices.indices.map { .object([("type", .string("subscriptionPrices")), ("id", .string("${price-\($0)}"))]) }))]))]
                if !offers.isEmpty { relationships.append(("introductoryOffers", .object([("data", .array(offers.map { .object([("type", $0["type"]!), ("id", $0["id"]!)]) }))]))) }
                let mode = PricingSetupChange.label(plan.offerMode, in: PricingSetupChange.offerModes), length = PricingSetupChange.label(plan.offerDuration, in: PricingSetupChange.offerDurations)
                let offerText = plan.offerMode == nil ? "No introductory offer" : "\(mode) · \(length)\(plan.offerMode == "PAY_AS_YOU_GO" ? " × \(plan.offerPeriods!)" : "")\(plan.offerAmount.map { " · \($0) \(prices[0].currency!)" } ?? "") in \(offerTerritories.count) \(offerTerritories.count == 1 ? "country or region" : "countries and regions")"
                planner.add(.api, method: "PATCH", path: [.string("subscriptions"), .string(product.id)], label: "\(product.name) · \(prices[0].customerPrice!) \(prices[0].currency!)\(plan.offerMode == nil ? "" : " · \(mode)")",
                            detail: "Set the first prices\(plan.offerMode == nil ? "" : " and the introductory offer") in one change. They take effect immediately.",
                            before: "No prices · No introductory offer", after: "\(prices.count) \(prices.count == 1 ? "country or region" : "countries and regions") from \(prices[0].customerPrice!) \(prices[0].currency!) in \(WorkspaceSession.countryName(base))\n\(offerText)",
                            body: .object([("data", .object([("type", .string("subscriptions")), ("id", .string(product.id)), ("relationships", .object(relationships))])), ("included", .array(included))]),
                            guard: setupGuard(PricingSetupWrites.setupDigest(schedule.rows, existing), [("subscriptionId", .string(product.id))]), group: "Prices and Offers")
            }
            if everywhere { planner.notes.append("Other countries and regions use Apple's equalized price for the price you chose in \(WorkspaceSession.countryName(base)).") }
            if change.plans!.contains(where: { $0.offerMode != nil }) { planner.notes.append("Each person gets one introductory offer per Subscription Group.") }
            return "Subscription prices and offers"

        case .productInformation:
            return try await planProductInformation(planner, change)

        case .appAvailability:
            if try await PricingSetupReads.appAvailable(appId, reads: reads) == true {
                planner.notes.append("App Store Connect already has the app's availability. Change single countries or regions under App Information → Availability.")
                return "App Availability already set up"
            }
            let territories = try await PricingSetupReads.territories(reads: reads), future = change.allTerritories == true
            planner.add(.api, method: "POST", path: [.string("v2"), .string("appAvailabilities")], label: "App Availability · \(territories.count) countries and regions",
                        detail: "Make the app available in every country or region\(future ? ", and in new ones Apple adds" : ""). Apple then accepts prices there.",
                        before: "No availability", after: "\(territories.count) countries and regions\(future ? " · new countries and regions included" : "")",
                        body: PricingSetupWrites.appAvailability(appId: appId, territories: territories, future: future), guard: setupGuard("none"), group: "App Availability")
            planner.notes.append("Pre-orders and single countries or regions can be changed afterwards under App Information → Availability.")
            return "App Availability"

        case .subscriptionPrices:
            let catalog = try await ProductPricing.catalog(appId: appId, reads: reads), product = try PricingSetupWrites.subscription(catalog, change.subscriptionId)
            let schedule = try await ProductPricing.schedule(product, reads: reads), base = change.territory!
            guard let point = try await ProductPricing.points(product, territory: base, reads: reads).first(where: { $0.id == change.pricePointId }), point.customerPrice != nil, point.currency != nil else {
                throw PublishFailure.invalid("The selected subscription price is no longer available at Apple.")
            }
            if schedule.rows.isEmpty { guard change.startDate == nil else { throw PublishFailure.invalid("The first subscription prices take effect immediately. Clear the start date.") } }
            else { guard let start = change.startDate, start > today else { throw PublishFailure.invalid("This subscription already has prices. Choose a start date after today for the new prices.") } }
            var targets: [ProductPricePoint]
            if let chosen = change.territoryPoints {
                targets = try await PricingSetupReads.chosen(product, points: chosen, reads: reads)
            } else {
                targets = [point] + (change.allTerritories == true ? try await PricingSetupReads.equalized(point.id, reads: reads).filter { $0.territory != base } : [])
            }
            guard targets.allSatisfy({ $0.customerPrice != nil && $0.currency != nil }) else { throw PublishFailure.invalid("Apple returned an equalized price without an amount.") }
            if let available = try await availabilityForPrices(product, territories: targets.map(\.territory), newTerritories: change.allTerritories == true, planner: planner, reads: reads) {
                let skipped = targets.filter { !available.contains($0.territory) }
                guard available.contains(base) else { throw PublishFailure.invalid("\(product.name) is not available in \(WorkspaceSession.countryName(base)). Add it under the subscription's Availability in App Store Connect, or choose another country or region.") }
                targets.removeAll { !available.contains($0.territory) }
                if !skipped.isEmpty { planner.notes.append("\(skipped.count) \(skipped.count == 1 ? "country or region is" : "countries and regions are") not in the subscription's Availability and get no price. Add them in App Store Connect under Availability first.") }
            }
            var sent: [ProductPricePoint] = []
            for target in targets.sorted(by: { WorkspaceSession.countryName($0.territory) < WorkspaceSession.countryName($1.territory) }) {
                let rows = schedule.rows.filter { $0.territory == target.territory }
                if rows.contains(where: { $0.startDate == change.startDate && $0.pricePointId == target.id }) { continue }
                if rows.contains(where: { $0.startDate == change.startDate }) { throw PublishFailure.invalid("\(WorkspaceSession.countryName(target.territory)) already has another price on this date. Choose another start date.") }
                sent.append(target)
            }
            if sent.isEmpty { planner.notes.append("Apple already has these prices. No write is needed.") }
            else if !schedule.rows.isEmpty {
                // Apple changes existing prices one country or region at a time; the publisher sends these steps several at once.
                for target in sent {
                    let rows = schedule.rows.filter { $0.territory == target.territory }
                    planner.add(.api, method: "POST", path: [.string("subscriptionPrices")], label: "\(WorkspaceSession.countryName(target.territory)) · \(target.customerPrice!) \(target.currency!)",
                                detail: change.startDate.map { "Starts \($0)." } ?? "Takes effect immediately.",
                                before: rows.isEmpty ? "No price" : rows.sorted { ($0.startDate ?? "") < ($1.startDate ?? "") }.map { "\($0.startDate ?? "Now"): \($0.customerPrice ?? "Amount unknown") \($0.currency ?? "")" }.joined(separator: "\n"),
                                after: "\(change.startDate ?? "Now"): \(target.customerPrice!) \(target.currency!)",
                                body: .object([("data", .object([("type", .string("subscriptionPrices")), ("attributes", .object([("startDate", change.startDate.map { .string($0) } ?? .null), ("preserveCurrentPrice", .bool(change.preserveCurrentPrice!))])),
                                                                 ("relationships", .object([("subscription", Apple.relationship("subscriptions", .string(product.id))), ("subscriptionPricePoint", Apple.relationship("subscriptionPricePoints", .string(target.id)))]))]))]),
                                guard: setupGuard(PricingSetupWrites.rowsDigest(rows), [("subscriptionId", .string(product.id)), ("territory", .string(target.territory)), ("pricePointId", .string(target.id))]), group: "Prices")
                }
            } else {
                // A subscription's first prices go in one subscription update, as App Store Connect saves them; Apple accepts or refuses them together.
                let included: [JSONText] = sent.enumerated().map { index, target in
                    .object([("type", .string("subscriptionPrices")), ("id", .string("${price-\(index)}")),
                             ("attributes", .object([("startDate", change.startDate.map { .string($0) } ?? .null), ("preserveCurrentPrice", .bool(change.preserveCurrentPrice!))])),
                             ("relationships", .object([("subscription", Apple.relationship("subscriptions", .string(product.id))), ("subscriptionPricePoint", Apple.relationship("subscriptionPricePoints", .string(target.id)))]))])
                }
                let count = "\(sent.count) \(sent.count == 1 ? "country or region" : "countries and regions")"
                planner.add(.api, method: "PATCH", path: [.string("subscriptions"), .string(product.id)], label: "\(product.name) · \(count)",
                            detail: "Set the first prices in one change. They take effect immediately.",
                            before: "No prices",
                            after: sent.map { "\(WorkspaceSession.countryName($0.territory)): \($0.customerPrice!) \($0.currency!)" }.joined(separator: "\n"),
                            body: .object([("data", .object([("type", .string("subscriptions")), ("id", .string(product.id)),
                                                             ("relationships", .object([("prices", .object([("data", .array(included.map { .object([("type", $0["type"]!), ("id", $0["id"]!)]) }))]))]))])),
                                           ("included", .array(included))]),
                            guard: setupGuard(PricingSetupWrites.rowsDigest(schedule.rows), [("subscriptionId", .string(product.id))]), group: "Prices")
            }
            if !schedule.rows.isEmpty { planner.notes.append(change.preserveCurrentPrice! ? "Existing subscribers keep their current price. Only new subscribers pay the new price." : "Existing subscribers move to the new price. Apple notifies them, and for an increase in some countries and regions asks for their consent first.") }
            if change.allTerritories == true { planner.notes.append("Other countries and regions use Apple's equalized price for \(point.customerPrice!) \(point.currency!) in \(WorkspaceSession.countryName(base)).") }
            if change.territoryPoints != nil { planner.notes.append("Each country or region gets the price chosen for it, such as by a pricing profile. Countries and regions not listed keep what Apple has.") }
            return "Subscription prices · \(product.name)"

        case .introductoryOffer:
            let catalog = try await ProductPricing.catalog(appId: appId, reads: reads), product = try PricingSetupWrites.subscription(catalog, change.subscriptionId)
            let existing = try await setupOffers(product.id, list: "introductoryOffers", type: "subscriptionIntroductoryOffers", reads: reads)
            let targets = try await offerTargets(change, product: product, reads: reads)
            if let start = change.startDate, start < today { throw PublishFailure.invalid("Choose today or a later start date.") }
            let mode = PricingSetupChange.label(change.offerMode, in: PricingSetupChange.offerModes), duration = PricingSetupChange.label(change.duration, in: PricingSetupChange.offerDurations)
            var skipped: [String] = [], sent: [(String, ProductPricePoint?)] = []
            for (territory, point) in targets.sorted(by: { WorkspaceSession.countryName($0.0) < WorkspaceSession.countryName($1.0) }) {
                if existing.contains(where: { Apple.owner($0, "territory")?.id == territory }) { skipped.append(territory) } else { sent.append((territory, point)) }
            }
            if !sent.isEmpty {
                var attributes: [(String, JSONText)] = [("duration", .string(change.duration!)), ("offerMode", .string(change.offerMode!)), ("numberOfPeriods", .number(Double(change.periods!)))]
                if let start = change.startDate { attributes.append(("startDate", .string(start))) }
                if let end = change.endDate { attributes.append(("endDate", .string(end))) }
                func relationships(_ target: (String, ProductPricePoint?)) -> [(String, JSONText)] {
                    [("subscription", Apple.relationship("subscriptions", .string(product.id))), ("territory", Apple.relationship("territories", .string(target.0)))]
                        + (target.1.map { [("subscriptionPricePoint", Apple.relationship("subscriptionPricePoints", .string($0.id)))] } ?? [])
                }
                if !existing.isEmpty {
                    // Beside existing offers Apple adds one country or region at a time; the publisher sends these steps several at once.
                    for target in sent {
                        planner.add(.api, method: "POST", path: [.string("subscriptionIntroductoryOffers")], label: "\(WorkspaceSession.countryName(target.0)) · \(mode) · \(duration)\(target.1.map { " · \($0.customerPrice ?? "") \($0.currency ?? "")" } ?? "")",
                                    detail: "New subscribers in this country or region get the introductory offer once.", before: "No introductory offer", after: "\(mode) · \(duration) × \(change.periods!) · \(change.startDate ?? "From now") to \(change.endDate ?? "no end date")",
                                    body: .object([("data", .object([("type", .string("subscriptionIntroductoryOffers")), ("attributes", .object(attributes)), ("relationships", .object(relationships(target)))]))]),
                                    guard: setupGuard(PricingSetupWrites.digest([]), [("subscriptionId", .string(product.id)), ("territory", .string(target.0))]), group: "Introductory Offers")
                    }
                } else {
                    // A subscription's first introductory offer goes in one subscription update, as App Store Connect saves it; Apple accepts or refuses every country or region together.
                    let included: [JSONText] = sent.enumerated().map { index, target in
                        .object([("type", .string("subscriptionIntroductoryOffers")), ("id", .string("${offer-\(index)}")), ("attributes", .object(attributes)), ("relationships", .object(relationships(target)))])
                    }
                    let count = "\(sent.count) \(sent.count == 1 ? "country or region" : "countries and regions")"
                    planner.add(.api, method: "PATCH", path: [.string("subscriptions"), .string(product.id)], label: "\(product.name) · \(mode) · \(duration) · \(count)",
                                detail: "New subscribers in these countries and regions get the introductory offer once. Every country or region is set in one change.",
                                before: "No introductory offer", after: "\(mode) · \(duration) × \(change.periods!) · \(change.startDate ?? "From now") to \(change.endDate ?? "no end date")\n"
                                    + sent.map { "\(WorkspaceSession.countryName($0.0))\($0.1.map { ": \($0.customerPrice ?? "") \($0.currency ?? "")" } ?? "")" }.joined(separator: "\n"),
                                body: .object([("data", .object([("type", .string("subscriptions")), ("id", .string(product.id)),
                                                                 ("relationships", .object([("introductoryOffers", .object([("data", .array(included.map { .object([("type", $0["type"]!), ("id", $0["id"]!)]) }))]))]))])),
                                               ("included", .array(included))]),
                                guard: setupGuard(PricingSetupWrites.digest(existing), [("subscriptionId", .string(product.id))]), group: "Introductory Offers")
                }
            }
            if !skipped.isEmpty { planner.notes.append("\(skipped.count) \(skipped.count == 1 ? "country or region already has" : "countries or regions already have") an introductory offer and \(skipped.count == 1 ? "is" : "are") left as \(skipped.count == 1 ? "it is" : "they are"): \(skipped.map { WorkspaceSession.countryName($0) }.joined(separator: ", ")).") }
            planner.notes.append("Apple gives each person one introductory offer per Subscription Group.")
            return "Introductory offer · \(product.name)"

        case .promotionalOffer, .offerCode, .winBackOffer:
            let catalog = try await ProductPricing.catalog(appId: appId, reads: reads), product = try PricingSetupWrites.subscription(catalog, change.subscriptionId), kind = PricingSetupWrites.offerRoot(change.action)!
            let existing = try await setupOffers(product.id, list: kind.list, type: kind.root, reads: reads)
            let identifier = change.action == .promotionalOffer ? "offerCode" : change.action == .winBackOffer ? "offerId" : "name"
            let wanted = change.action == .offerCode ? change.name! : change.offerId!
            guard !existing.contains(where: { ProductPricing.text($0.attributes?[identifier]).caseInsensitiveCompare(wanted) == .orderedSame || ProductPricing.text($0.attributes?[change.action == .winBackOffer ? "referenceName" : "name"]).caseInsensitiveCompare(change.name!) == .orderedSame }) else {
                throw PublishFailure.invalid("This subscription already has an offer with this name or identifier.")
            }
            if let start = change.startDate, start < today { throw PublishFailure.invalid("Choose today or a later start date.") }
            let targets = try await offerTargets(change, product: product, reads: reads)
            let included = targets.enumerated().map { index, target in
                JSONText.object([("type", .string(kind.prices)), ("id", .string("${price-\(index)}")), ("relationships", .object([("territory", Apple.relationship("territories", .string(target.0)))] + (target.1.map { [("subscriptionPricePoint", Apple.relationship("subscriptionPricePoints", .string($0.id)))] } ?? [])))])
            }
            var attributes: [(String, JSONText)] = [("duration", .string(change.duration!)), ("offerMode", .string(change.offerMode!))]
            let title: String
            switch change.action {
            case .promotionalOffer:
                attributes += [("name", .string(change.name!)), ("offerCode", .string(change.offerId!)), ("numberOfPeriods", .number(Double(change.periods!)))]; title = "Promotional offer"
            case .offerCode:
                attributes += [("name", .string(change.name!)), ("customerEligibilities", .array(change.eligibilities!.map { .string($0) })), ("offerEligibility", .string(change.stacking!)), ("numberOfPeriods", .number(Double(change.periods!)))]; title = "Offer code"
            default:
                attributes += [("referenceName", .string(change.name!)), ("offerId", .string(change.offerId!)), ("periodCount", .number(Double(change.periods!))), ("startDate", .string(change.startDate!)), ("priority", .string(change.priority!)),
                               ("customerEligibilityPaidSubscriptionDurationInMonths", .number(Double(change.paidMonths!))),
                               ("customerEligibilityTimeSinceLastSubscribedInMonths", .object([("minimum", .number(Double(change.lapsedMinimum!))), ("maximum", .number(Double(change.lapsedMaximum!)))]))]
                if let wait = change.waitMonths { attributes.append(("customerEligibilityWaitBetweenOffersInMonths", .number(Double(wait)))) }
                if let end = change.endDate { attributes.append(("endDate", .string(end))) }
                title = "Win-back offer"
            }
            let mode = PricingSetupChange.label(change.offerMode, in: PricingSetupChange.offerModes), duration = PricingSetupChange.label(change.duration, in: PricingSetupChange.offerDurations)
            let first = targets.first.flatMap { $0.1 }
            planner.add(.api, method: "POST", path: [.string(kind.root)], label: "\(title) · \(change.name!) · \(product.name)",
                        detail: change.action == .offerCode ? "Create the offer code. Create one-time use codes or a custom code for it in App Store Connect under Monetization → Subscriptions → Offer Codes."
                            : change.action == .winBackOffer ? "Create the win-back offer for people who subscribed before and stopped." : "Create the promotional offer. Your app's code offers it to current or former subscribers.",
                        before: "Not at Apple", after: "\(mode) · \(duration) × \(change.periods!)\(first.map { " · \($0.customerPrice ?? "") \($0.currency ?? "") in \(WorkspaceSession.countryName($0.territory))" } ?? "")\n\(targets.count) \(targets.count == 1 ? "country or region" : "countries and regions")",
                        body: .object([("data", .object([("type", .string(kind.root)), ("attributes", .object(attributes)), ("relationships", .object([("subscription", Apple.relationship("subscriptions", .string(product.id))),
                            ("prices", .object([("data", .array(included.map { .object([("type", $0["type"]!), ("id", $0["id"]!)]) }))]))]))])), ("included", .array(included))]),
                        guard: setupGuard(PricingSetupWrites.digest(existing), [("subscriptionId", .string(product.id))]))
            if change.allTerritories == true, first != nil { planner.notes.append("Other countries and regions use Apple's equalized price for the offer price you chose.") }
            return "\(title) · \(product.name)"
        }
    }

    /// An offer's countries and regions with their price levels; a free trial has none.
    private func offerTargets(_ change: PricingSetupChange, product: PriceProduct, reads: AppleReads) async throws -> [(String, ProductPricePoint?)] {
        let base = change.territory!
        guard let pointId = change.pricePointId else {
            return change.allTerritories == true ? try await PricingSetupReads.territories(reads: reads).map { ($0, nil) } : [(base, nil)]
        }
        guard let point = try await ProductPricing.points(product, territory: base, reads: reads).first(where: { $0.id == pointId }), point.customerPrice != nil, point.currency != nil else {
            throw PublishFailure.invalid("The selected offer price is no longer available at Apple.")
        }
        let others = change.allTerritories == true ? try await PricingSetupReads.equalized(point.id, reads: reads).filter { $0.territory != base } : []
        return [(base, point)] + others.map { ($0.territory, $0) }
    }

    func setupOffers(_ subscription: String, list: String, type: String, reads: AppleReads) async throws -> [AppStoreConnectClient.Resource] {
        let include = type == "subscriptionIntroductoryOffers" ? "&include=territory" : ""
        let items = try ProductPricing.unique(try await reads.list("/v1/subscriptions/\(subscription)/\(list)?limit=200\(include)"), type)
        guard items.allSatisfy({ Apple.within($0, "subscription", "subscriptions", subscription) }) else { throw PublishFailure.invalid("Apple returned an offer of another subscription.") }
        return items
    }

    /// Pricing setup write check: the body has only the reviewed shape, every product belongs to the approved app and Apple's state is unchanged.
    func verifyPricingSetupWrite(root: String, method: String, path: String, parts: [String], body: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        let reads = AppleReads(client), data = body?["data"], action = guardValue?["action"]?.text ?? ""
        func refuse() -> PublishFailure { .write("Unsupported pricing change.") }
        func changed() -> PublishFailure { .write("Apple's pricing changed after approval. Prepare a new review.") }
        func relation(_ name: String) -> (type: String, id: String)? {
            guard let item = data?["relationships"]?[name]?["data"], let type = item["type"]?.text, let id = item["id"]?.text else { return nil }
            return (type, id)
        }
        func keys(_ value: JSONText?) -> Set<String> { if case .object(let pairs)? = value { Set(pairs.map(\.0)) } else { [] } }
        if action == "product-information" {
            try await verifyProductInformation(root: root, method: method, path: path, parts: parts, body: body, guardValue: guardValue, appId: appId, reads: reads); return
        }
        if action == "app-availability" {
            guard method == "POST", parts == ["appAvailabilities"], path.hasPrefix("/v2/"), keys(body) == ["data", "included"], data?["type"]?.text == "appAvailabilities", case .bool(let future)? = data?["attributes"]?["availableInNewTerritories"],
                  relation("app").map({ $0 == ("apps", appId) }) == true, case .array(let included)? = body?["included"] else { throw refuse() }
            let territories = try await PricingSetupReads.territories(reads: reads)
            guard Apple.canonical(body!) == Apple.canonical(PricingSetupWrites.appAvailability(appId: appId, territories: territories, future: future)), !included.isEmpty else { throw refuse() }
            guard try await PricingSetupReads.appAvailable(appId, reads: reads) == false else { throw changed() }
            return
        }
        if action == "subscription-setup" {
            try await verifySubscriptionSetup(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, reads: reads); return
        }
        if method == "PATCH", ["subscription-prices", "introductory-offer"].contains(action) {
            try await verifyFirstSubscriptionBatch(action: action, parts: parts, body: body, guardValue: guardValue, appId: appId, reads: reads); return
        }
        guard method == "POST", parts == [root], data?["type"]?.text == root, data?["id"] == nil, (root == "inAppPurchases") == (path == "/v2/inAppPurchases") else { throw refuse() }
        switch root {
        case "appPriceSchedules":
            guard ["app-price", "temporary-app-price"].contains(action), relation("app").map({ $0 == ("apps", appId) }) == true, keys(body) == ["data", "included"], case .array(let included)? = body?["included"], !included.isEmpty, included.count <= 2000,
                  included.allSatisfy({ $0["type"]?.text == "appPrices" && keys($0["relationships"]) == ["appPricePoint"] && $0["relationships"]?["appPricePoint"]?["data"]?["type"]?.text == "appPricePoints" }),
                  included.contains(where: { $0["relationships"]?["appPricePoint"]?["data"]?["id"]?.text == guardValue?["pricePointId"]?.text }) else { throw refuse() }
            if action == "app-price" { guard included.count <= 4, relation("baseTerritory")?.id == guardValue?["territory"]?.text else { throw refuse() } }
            let current = try await setupAppSchedule(appId: appId, client: client, planner: nil)
            guard (current?.digest ?? "none") == guardValue?["digest"]?.text, action == "app-price" || current?.base == relation("baseTerritory")?.id else { throw changed() }
        case "inAppPurchases", "subscriptions":
            let attributes: Set<String> = root == "inAppPurchases" ? ["name", "productId", "inAppPurchaseType"] : ["name", "productId", "subscriptionPeriod"]
            guard action == (root == "inAppPurchases" ? "create-in-app-purchase" : "create-subscription"), keys(data?["attributes"]).subtracting(["familySharable"]) == attributes,
                  data?["attributes"]?["familySharable"].map({ $0 == .bool(true) }) ?? true, keys(body) == ["data"],
                  PricingSetupChange.referenceName(data?["attributes"]?["name"]?.text) != nil, data?["attributes"]?["productId"]?.text.map(PricingSetupChange.validProductId) == true else { throw refuse() }
            let catalog = try await ProductPricing.catalog(appId: appId, reads: reads)
            let planned = WorkspaceSession.strings(guardValue?["planned"])
            guard try (planned.isEmpty ? PricingSetupWrites.productsDigest(catalog) : PricingSetupWrites.productsDigest(catalog, excluding: planned)) == guardValue?["digest"]?.text,
                  planned.isEmpty || planned.contains(data?["attributes"]?["productId"]?.text?.lowercased() ?? ""),
                  !((catalog.purchases ?? []) + (catalog.subscriptions ?? [])).contains(where: { $0.productId.caseInsensitiveCompare(data?["attributes"]?["productId"]?.text ?? "") == .orderedSame }) else { throw changed() }
            if root == "inAppPurchases" { guard relation("app").map({ $0 == ("apps", appId) }) == true, keys(data?["relationships"]) == ["app"] else { throw refuse() } }
            else {
                guard let group = relation("group"), group.type == "subscriptionGroups", keys(data?["relationships"]) == ["group"], try await PricingSetupReads.groups(appId: appId, reads: reads).contains(where: { $0.id == group.id }) else { throw refuse() }
            }
        case "subscriptionGroups":
            guard action == "create-subscription-group", keys(data?["attributes"]) == ["referenceName"], keys(data?["relationships"]) == ["app"], relation("app").map({ $0 == ("apps", appId) }) == true, keys(body) == ["data"],
                  let name = PricingSetupChange.referenceName(data?["attributes"]?["referenceName"]?.text) else { throw refuse() }
            let groups = try await PricingSetupReads.groups(appId: appId, reads: reads)
            guard PricingSetupWrites.groupsDigest(groups) == guardValue?["groups"]?.text,
                  !groups.contains(where: { $0.referenceName.caseInsensitiveCompare(name) == .orderedSame }) else { throw changed() }
        case "subscriptionPrices":
            guard action == "subscription-prices", let subscription = guardValue?["subscriptionId"]?.text, let territory = guardValue?["territory"]?.text, ProductPricing.territory(territory),
                  relation("subscription").map({ $0 == ("subscriptions", subscription) }) == true, relation("subscriptionPricePoint").map({ $0 == ("subscriptionPricePoints", guardValue?["pricePointId"]?.text ?? "") }) == true,
                  keys(data?["relationships"]) == ["subscription", "subscriptionPricePoint"], keys(data?["attributes"]) == ["startDate", "preserveCurrentPrice"], keys(body) == ["data"] else { throw refuse() }
            _ = try PricingSetupWrites.subscription(try await ProductPricing.catalog(appId: appId, reads: reads), subscription)
            let rows = try ProductPricing.prices(try await reads.pages("/v1/subscriptions/\(subscription)/prices?filter%5Bterritory%5D=\(territory)&include=subscriptionPricePoint%2Cterritory&limit=200"), source: .subscription).filter { $0.territory == territory }
            guard PricingSetupWrites.rowsDigest(rows) == guardValue?["digest"]?.text else { throw changed() }
        case "subscriptionIntroductoryOffers":
            guard action == "introductory-offer", let subscription = guardValue?["subscriptionId"]?.text, let territory = guardValue?["territory"]?.text, relation("subscription").map({ $0 == ("subscriptions", subscription) }) == true,
                  relation("territory").map({ $0 == ("territories", territory) }) == true, keys(data?["relationships"]).isSubset(of: ["subscription", "territory", "subscriptionPricePoint"]),
                  keys(data?["attributes"]).isSubset(of: ["duration", "offerMode", "numberOfPeriods", "startDate", "endDate"]), keys(body) == ["data"] else { throw refuse() }
            _ = try PricingSetupWrites.subscription(try await ProductPricing.catalog(appId: appId, reads: reads), subscription)
            let current = try await setupOffers(subscription, list: "introductoryOffers", type: root, reads: reads).filter { Apple.owner($0, "territory")?.id == territory }
            guard PricingSetupWrites.digest(current) == guardValue?["digest"]?.text else { throw changed() }
        default:
            guard let action = PricingSetupChange.Action(rawValue: action), let kind = PricingSetupWrites.offerRoot(action), kind.root == root, let subscription = guardValue?["subscriptionId"]?.text,
                  relation("subscription").map({ $0 == ("subscriptions", subscription) }) == true, keys(data?["relationships"]) == ["subscription", "prices"], keys(body) == ["data", "included"],
                  case .array(let included)? = body?["included"], !included.isEmpty, included.count <= 200,
                  included.allSatisfy({ $0["type"]?.text == kind.prices && $0["relationships"]?["territory"]?["data"]?["type"]?.text == "territories" && keys($0["relationships"]).isSubset(of: ["territory", "subscriptionPricePoint"]) }) else { throw refuse() }
            _ = try PricingSetupWrites.subscription(try await ProductPricing.catalog(appId: appId, reads: reads), subscription)
            guard PricingSetupWrites.digest(try await setupOffers(subscription, list: kind.list, type: root, reads: reads)) == guardValue?["digest"]?.text else { throw changed() }
        }
    }

    /// A subscription's first prices, or its first introductory offer, in every chosen country or region as one subscription update with inline items.
    private func verifyFirstSubscriptionBatch(action: String, parts: [String], body: JSONText?, guardValue: JSONText?, appId: String, reads: AppleReads) async throws {
        let data = body?["data"], prices = action == "subscription-prices"
        let relation = prices ? "prices" : "introductoryOffers", type = prices ? "subscriptionPrices" : "subscriptionIntroductoryOffers"
        func keys(_ value: JSONText?) -> Set<String> { if case .object(let pairs)? = value { Set(pairs.map(\.0)) } else { [] } }
        func linked(_ item: JSONText, _ name: String) -> String? { item["relationships"]?[name]?["data"]?["id"]?.text }
        guard parts.count == 2, parts[0] == "subscriptions", let subscription = guardValue?["subscriptionId"]?.text, parts[1] == subscription,
              data?["type"]?.text == "subscriptions", data?["id"]?.text == subscription, keys(data) == ["type", "id", "relationships"], keys(data?["relationships"]) == [relation], keys(body) == ["data", "included"],
              case .array(let included)? = body?["included"], (1...500).contains(included.count), case .array(let listed)? = data?["relationships"]?[relation]?["data"],
              Set(listed.compactMap { $0["type"]?.text == type ? $0["id"]?.text : nil }) == Set(included.compactMap { $0["id"]?.text }), Set(included.compactMap { $0["id"]?.text }).count == included.count,
              included.allSatisfy({ item in
                  item["type"]?.text == type && linked(item, "subscription") == subscription && (prices
                      ? keys(item["relationships"]) == ["subscription", "subscriptionPricePoint"] && keys(item["attributes"]) == ["startDate", "preserveCurrentPrice"] && item["attributes"]?["startDate"] == .null
                      : keys(item["relationships"]).isSubset(of: ["subscription", "territory", "subscriptionPricePoint"]) && linked(item, "territory") != nil
                          && keys(item["attributes"]).isSubset(of: ["duration", "offerMode", "numberOfPeriods", "startDate", "endDate"]) && keys(item["attributes"]).isSuperset(of: ["duration", "offerMode", "numberOfPeriods"]))
              }),
              prices || Set(included.compactMap { linked($0, "territory") }).count == included.count else { throw PublishFailure.write("Unsupported pricing change.") }
        let product = try PricingSetupWrites.subscription(try await ProductPricing.catalog(appId: appId, reads: reads), subscription)
        // Only a subscription without prices, or without introductory offers, gets them in one update, so nothing already at Apple is replaced.
        let digest: String
        if prices {
            let rows = try await ProductPricing.schedule(product, reads: reads).rows
            guard rows.isEmpty else { throw PublishFailure.write("Apple's pricing changed after approval. Prepare a new review.") }
            digest = PricingSetupWrites.rowsDigest(rows)
        } else {
            let offers = try await setupOffers(subscription, list: "introductoryOffers", type: type, reads: reads)
            guard offers.isEmpty else { throw PublishFailure.write("Apple's pricing changed after approval. Prepare a new review.") }
            digest = PricingSetupWrites.digest(offers)
        }
        guard digest == guardValue?["digest"]?.text else { throw PublishFailure.write("Apple's pricing changed after approval. Prepare a new review.") }
    }

    /// The first prices and introductory offer of one subscription, sent together as Apple's subscription update with its inline prices and offers.
    private func verifySubscriptionSetup(method: String, parts: [String], body: JSONText?, guardValue: JSONText?, appId: String, reads: AppleReads) async throws {
        let data = body?["data"]
        func keys(_ value: JSONText?) -> Set<String> { if case .object(let pairs)? = value { Set(pairs.map(\.0)) } else { [] } }
        func linked(_ item: JSONText, _ name: String) -> String? { item["relationships"]?[name]?["data"]?["id"]?.text }
        guard method == "PATCH", parts.count == 2, parts[0] == "subscriptions", let subscription = guardValue?["subscriptionId"]?.text, parts[1] == subscription,
              data?["type"]?.text == "subscriptions", data?["id"]?.text == subscription, keys(data).isSubset(of: ["type", "id", "relationships"]), keys(body) == ["data", "included"],
              keys(data?["relationships"]).isSubset(of: ["prices", "introductoryOffers"]), data?["relationships"]?["prices"] != nil,
              case .array(let included)? = body?["included"], !included.isEmpty, included.count <= 500,
              included.allSatisfy({ item in
                  linked(item, "subscription") == subscription && (item["type"]?.text == "subscriptionPrices" ? keys(item["relationships"]) == ["subscription", "subscriptionPricePoint"] && keys(item["attributes"]) == ["startDate", "preserveCurrentPrice"]
                      : item["type"]?.text == "subscriptionIntroductoryOffers" && keys(item["relationships"]).isSubset(of: ["subscription", "territory", "subscriptionPricePoint"]) && linked(item, "territory") != nil
                          && keys(item["attributes"]) == ["duration", "offerMode", "numberOfPeriods"])
              }) else { throw PublishFailure.write("Unsupported subscription price setup.") }
        let product = try PricingSetupWrites.subscription(try await ProductPricing.catalog(appId: appId, reads: reads), subscription)
        let rows = try await ProductPricing.schedule(product, reads: reads).rows, offers = try await setupOffers(subscription, list: "introductoryOffers", type: "subscriptionIntroductoryOffers", reads: reads)
        guard PricingSetupWrites.setupDigest(rows, offers) == guardValue?["digest"]?.text else { throw PublishFailure.write("Apple's subscription prices changed after approval. Prepare a new review.") }
    }
}
