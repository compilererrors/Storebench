import Foundation

/// How an app earns money, in App Store Connect's words: the app price and the kinds of products it sells.
public enum PricingModelKind: String, Sendable, CaseIterable, Identifiable, Codable {
    case free, paid, freeWithInAppPurchases = "free-in-app-purchases", subscriptions, paidWithInAppPurchases = "paid-in-app-purchases"
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .free: "Free"
        case .paid: "Paid"
        case .freeWithInAppPurchases: "Free with In-App Purchases"
        case .subscriptions: "Subscriptions"
        case .paidWithInAppPurchases: "Paid with In-App Purchases"
        }
    }
    public var summary: String {
        switch self {
        case .free: "The app is free to download and sells nothing."
        case .paid: "People pay one price to download the app."
        case .freeWithInAppPurchases: "The app is free to download and sells consumable or non-consumable in-app purchases."
        case .subscriptions: "The app is free to download and sells auto-renewable subscriptions, with optional free trials and offers."
        case .paidWithInAppPurchases: "People pay to download the app and can buy in-app purchases inside it."
        }
    }
    /// Whether the app itself has a price above Free.
    public var paidApp: Bool { self == .paid || self == .paidWithInAppPurchases }
    public var sellsPurchases: Bool { self == .freeWithInAppPurchases || self == .paidWithInAppPurchases }
    public var sellsSubscriptions: Bool { self == .subscriptions }
}

/// The app price at Apple: none yet, Free, or a price in the base country or region.
public enum AppPriceState: Sendable, Equatable {
    case none, free(territory: String), paid(territory: String, amount: String, currency: String), unknown
    public var isPaid: Bool { if case .paid = self { true } else { false } }
    public var isFree: Bool { if case .free = self { true } else { false } }
    public var territory: String? {
        switch self { case .free(let territory), .paid(let territory, _, _): territory; default: nil }
    }
    public var label: String {
        switch self {
        case .none: "No price"
        case .free: "Free"
        case .paid(_, let amount, let currency): "\(amount) \(currency)"
        case .unknown: "Unknown"
        }
    }
}

public struct SubscriptionGroupSummary: Sendable, Equatable, Identifiable {
    public let id, referenceName: String
    public init(id: String, referenceName: String) { self.id = id; self.referenceName = referenceName }
}

/// What App Store Connect has for the app's pricing today, read in one pass. Nil counts mean Apple did not answer completely.
public struct PricingSetupState: Sendable, Equatable {
    public let appPrice: AppPriceState
    public let purchases: [PriceProduct]?, subscriptions: [PriceProduct]?, groups: [SubscriptionGroupSummary]?
    /// Products with at least one price at Apple; nil when the price schedules were not read.
    public let priced: Set<String>?
    /// Why Apple's app price could not be read, when it could not.
    public let priceProblem: String?
    /// Whether the app has App Availability at Apple, which Apple needs before it accepts prices; nil when it could not be read.
    public var appAvailable: Bool? = nil
    /// Each priced product's price schedule as Apple returned it, by product ID.
    public var schedules: [String: ProductPriceSchedule] = [:]
    /// One product's schedule: empty when Apple has no prices for it, nil when Apple's answer for it is missing.
    /// One product that could not be read leaves the others shown.
    public func schedule(_ productId: String) -> ProductPriceSchedule? {
        if let known = schedules[productId] { return known }
        guard let priced else { return nil }
        return priced.contains(productId) ? schedules[productId] : ProductPriceSchedule(baseTerritory: nil, rows: [], available: false, scheduleId: nil)
    }
    public init(appPrice: AppPriceState, purchases: [PriceProduct]?, subscriptions: [PriceProduct]?, groups: [SubscriptionGroupSummary]?, priced: Set<String>?, priceProblem: String? = nil) {
        self.appPrice = appPrice; self.purchases = purchases; self.subscriptions = subscriptions; self.groups = groups; self.priced = priced; self.priceProblem = priceProblem
    }
    public var complete: Bool { appPrice != .unknown && purchases != nil && subscriptions != nil && groups != nil }
    /// Nothing is set up yet: no app price and no products, so the first-time guide applies.
    public var empty: Bool { appPrice == .none && noProducts }
    /// No products at Apple and no price that could be read: the guide is offered, and each step's review reads Apple again before anything is sent.
    public var guideAvailable: Bool { (appPrice == .none || appPrice == .unknown) && noProducts }
    var noProducts: Bool { purchases?.isEmpty == true && subscriptions?.isEmpty == true && groups?.isEmpty == true }
}

public enum PricingSetup {
    /// The model Apple's state shows, or nil while nothing is set up or Apple's answer is incomplete.
    public static func detect(_ state: PricingSetupState) -> PricingModelKind? {
        guard state.complete, !state.empty else { return nil }
        if state.subscriptions?.isEmpty == false || state.groups?.isEmpty == false { return .subscriptions }
        if state.purchases?.isEmpty == false { return state.appPrice.isPaid ? .paidWithInAppPurchases : .freeWithInAppPurchases }
        return state.appPrice.isPaid ? .paid : state.appPrice.isFree ? .free : nil
    }

    /// The model the Pricing section shows: the one chosen on this Mac, else the one Apple's state shows.
    public static func shown(chosen: PricingModelKind?, state: PricingSetupState?) -> PricingModelKind? { chosen ?? state.flatMap(detect) }

    public struct Step: Sendable, Equatable, Identifiable {
        public enum Task: String, Sendable { case freePrice = "free-price", appPrice = "app-price", createPurchase = "create-purchase", purchasePrice = "purchase-price", createSubscription = "create-subscription", subscriptionPrices = "subscription-prices", introductoryOffer = "introductory-offer" }
        public let task: Task, title, description, command: String
        public let optional: Bool
        public var id: String { task.rawValue }
    }

    public static func steps(_ model: PricingModelKind) -> [Step] {
        let free = Step(task: .freePrice, title: "Set the app price", description: "Set the app's download price to Free. App Store Connect needs it before the version can be submitted, even for a free app; subscriptions and in-app purchases keep their own prices.", command: "Set App Price", optional: false)
        let paid = Step(task: .appPrice, title: "Set the app price", description: "Choose the base country or region and its price, and optionally a launch sale and a planned price change. Apple sets equalized prices in the other countries and regions.", command: "Set App Price", optional: false)
        let purchase = Step(task: .createPurchase, title: "Create an in-app purchase", description: "Choose its type, Reference Name, Product ID, Family Sharing and price. Apple creates it first, then the next review sets its price in every country or region.", command: "Create In-App Purchase", optional: false)
        let subscription = Step(task: .createSubscription, title: "Set up subscriptions", description: "Choose the Subscription Group, each plan's duration and price, Family Sharing and a free trial or introductory offer. Apple creates the subscriptions first, then the next review sets their prices and offer in every country or region.", command: "Set Up Subscriptions", optional: false)
        let offers = Step(task: .introductoryOffer, title: "Add more offers", description: "Optional. Promotional offers for current and former subscribers, offer codes to share and win-back offers for people who stopped.", command: "Add Offers", optional: true)
        switch model {
        case .free: return [free]
        case .paid: return [paid]
        case .freeWithInAppPurchases: return [purchase, free]
        case .paidWithInAppPurchases: return [paid, purchase]
        case .subscriptions: return [subscription, free, offers]
        }
    }

    /// Whether Apple already has what a step sets up.
    public static func done(_ task: Step.Task, state: PricingSetupState) -> Bool {
        switch task {
        case .freePrice: state.appPrice.isFree || state.appPrice.isPaid
        case .appPrice: state.appPrice.isPaid
        case .createPurchase, .purchasePrice: state.purchases.map { purchases in !purchases.isEmpty && purchases.allSatisfy { state.priced?.contains($0.id) == true } } ?? false
        case .createSubscription, .subscriptionPrices: state.subscriptions.map { items in !items.isEmpty && items.allSatisfy { state.priced?.contains($0.id) == true } } ?? false
        case .introductoryOffer: false
        }
    }

    /// The first required step Apple does not have yet; nil when the model is fully set up. The steps can be done in any order.
    public static func nextStep(_ model: PricingModelKind, state: PricingSetupState) -> Step? {
        steps(model).first { !$0.optional && !done($0.task, state: state) }
    }

    /// What changing from one model to another means at Apple. Choosing a model changes nothing there; each change below is its own review.
    public static func changes(from current: PricingModelKind?, to next: PricingModelKind, state: PricingSetupState?) -> [String] {
        var lines: [String] = []
        let price = state?.appPrice ?? .unknown
        if next.paidApp {
            lines.append(price.isPaid ? "The app keeps its price of \(price.label). Change it in Price." : "Next you choose the app's price. Apple then charges it in every country or region where the app is available.")
        } else {
            lines.append(price.isPaid ? "Next you set the app price to Free. Apple stops charging for downloads once that review is sent; people who bought the app keep it." : "The app price stays Free, or is set to Free next.")
        }
        let purchases = state?.purchases?.count ?? 0, subscriptions = state?.subscriptions?.count ?? 0
        if next.sellsPurchases { lines.append(purchases > 0 ? "The \(purchases) existing in-app \(purchases == 1 ? "purchase stays" : "purchases stay") as they are." : "Next you create an in-app purchase and set its price.") }
        else if purchases > 0 { lines.append("The \(purchases) existing in-app \(purchases == 1 ? "purchase is" : "purchases are") not removed. Remove them from sale in App Store Connect under Monetization → In-App Purchases if you no longer sell them.") }
        if next.sellsSubscriptions { lines.append(subscriptions > 0 ? "The \(subscriptions) existing \(subscriptions == 1 ? "subscription stays" : "subscriptions stay") as they are." : "Next you create a subscription group and subscription and set its prices.") }
        else if subscriptions > 0 { lines.append("The \(subscriptions) existing \(subscriptions == 1 ? "subscription is" : "subscriptions are") not removed, and current subscribers keep renewing. Remove them from sale in App Store Connect under Monetization → Subscriptions if you no longer sell them.") }
        if current == next { lines = ["This is the current pricing model. Nothing changes."] }
        lines.append("Choosing a model only changes what Pricing shows on this Mac. Nothing is sent to Apple until you approve a review.")
        return lines
    }
}

/// A subscription setup saved on this Mac between its two reviews: the group, the plans with their prices and offers, and the base country or region.
public struct SubscriptionSetupDraft: Sendable, Equatable {
    public var territory = "", groupId = "", groupName = ""
    public var everywhere = true
    public var plans: [SubscriptionPlan] = [SubscriptionPlan()]
    public init() {}

    var json: JSONText {
        .object([("territory", .string(territory)), ("groupId", .string(groupId)), ("groupName", .string(groupName)), ("everywhere", .bool(everywhere)), ("plans", .array(plans.map(\.savedJSON)))])
    }
    init?(_ value: JSONText?) {
        guard let value, case .array(let items)? = value["plans"], (1...10).contains(items.count) else { return nil }
        territory = value["territory"]?.text ?? ""; groupId = value["groupId"]?.text ?? ""; groupName = value["groupName"]?.text ?? ""; everywhere = value["everywhere"] != .bool(false)
        plans = items.map(SubscriptionPlan.init)
    }

    /// The draft against App Store Connect's groups: a new group App Store Connect has since created with this Reference Name is chosen,
    /// as is the only group when no group is chosen or the chosen one is gone, so a group that exists is never offered as new again.
    public func matched(groups: [SubscriptionGroupSummary]?) -> SubscriptionSetupDraft {
        guard let groups, groupId.isEmpty || !groups.contains(where: { $0.id == groupId }) else { return self }
        var value = self
        if let named = groups.first(where: { $0.referenceName.caseInsensitiveCompare(groupName) == .orderedSame }) { value.groupId = named.id }
        else if PricingSetupChange.referenceName(groupName) == nil, groups.count == 1 { value.groupId = groups[0].id }
        else { value.groupId = "" }
        if !value.groupId.isEmpty { value.groupName = "" }
        return value
    }

    /// The first review: the group, if new, and every plan Apple does not have yet; nil once Apple has them all.
    public func createRequest(accountId: String, appId: String, existing: [PriceProduct]) -> PublishRequest? {
        let missing = plans.filter { plan in !existing.contains { $0.productId.caseInsensitiveCompare(plan.productId) == .orderedSame } }
        guard !missing.isEmpty else { return nil }
        var change = PricingSetupChange(action: .createSubscription); change.plans = missing
        if groupId.isEmpty { change.groupName = groupName } else { change.groupId = groupId }
        var value = PublishRequest(accountId: accountId, appId: appId, scope: .pricingSetup); value.pricingSetup = change
        return value
    }

    /// The second review: first prices and introductory offers for the plans Apple has created and not priced yet.
    public func setupRequest(accountId: String, appId: String, subscriptions: [PriceProduct], priced: Set<String>) -> PublishRequest? {
        let ready = plans.compactMap { plan -> SubscriptionPlan? in
            guard let product = subscriptions.first(where: { $0.productId.caseInsensitiveCompare(plan.productId) == .orderedSame }), !priced.contains(product.id) else { return nil }
            var value = plan; value.subscriptionId = product.id; return value
        }
        guard !ready.isEmpty else { return nil }
        var change = PricingSetupChange(action: .subscriptionSetup); change.plans = ready; change.territory = territory; change.allTerritories = everywhere
        var value = PublishRequest(accountId: accountId, appId: appId, scope: .pricingSetup); value.pricingSetup = change
        return value
    }
}

extension WorkspaceSession {
    /// The subscription setup saved on this Mac for one app, if any.
    public func subscriptionSetupDraft(accountId: String, appId: String) throws -> SubscriptionSetupDraft? {
        try storeAccess { store in
            SubscriptionSetupDraft(Self.items(try PricingState.read(store, "pricing_setup").value?["drafts"]).first { $0["accountId"]?.text == accountId && $0["appId"]?.text == appId }?["draft"])
        }
    }

    /// Saves or clears the subscription setup on this Mac. Apple is not contacted.
    public func saveSubscriptionSetupDraft(_ draft: SubscriptionSetupDraft?, accountId: String, appId: String) throws {
        guard try accounts().first(where: { $0.id == accountId })?.appIds.contains(appId) == true else { throw PricingFailure.invalid("App is not configured for this account.") }
        try storeAccess { store in
            try PricingLock.holding([.setup], in: store) {
                let (document, value) = try PricingState.read(store, "pricing_setup")
                var drafts = Self.items(value?["drafts"]).filter { !($0["accountId"]?.text == accountId && $0["appId"]?.text == appId) }
                if let draft { drafts.append(.object([("accountId", .string(accountId)), ("appId", .string(appId)), ("draft", draft.json)])) }
                try PricingState.replace(store, "pricing_setup", previous: document, value: .object([("schemaVersion", .number(1)), ("choices", value?["choices"] ?? .array([])), ("drafts", .array(drafts))]))
            }
        }
    }

    /// The pricing model chosen on this Mac for one app, if any.
    public func chosenPricingModel(accountId: String, appId: String) throws -> PricingModelKind? {
        try storeAccess { store in
            Self.items(try PricingState.read(store, "pricing_setup").value?["choices"]).first { $0["accountId"]?.text == accountId && $0["appId"]?.text == appId }?["model"]?.text.flatMap(PricingModelKind.init)
        }
    }

    /// Saves or clears the pricing model chosen on this Mac. Apple is not contacted.
    public func choosePricingModel(_ model: PricingModelKind?, accountId: String, appId: String) throws {
        guard try accounts().first(where: { $0.id == accountId })?.appIds.contains(appId) == true else { throw PricingFailure.invalid("App is not configured for this account.") }
        try storeAccess { store in
            try PricingLock.holding([.setup], in: store) {
                let (document, value) = try PricingState.read(store, "pricing_setup")
                var choices = Self.items(value?["choices"]).filter { !($0["accountId"]?.text == accountId && $0["appId"]?.text == appId) }
                if let model { choices.append(.object([("accountId", .string(accountId)), ("appId", .string(appId)), ("model", .string(model.rawValue))])) }
                try PricingState.replace(store, "pricing_setup", previous: document, value: .object([("schemaVersion", .number(1)), ("choices", .array(choices)), ("drafts", value?["drafts"] ?? .array([]))]))
            }
        }
    }

    /// Pricing as it opens: Apple's answers warmed earlier in this session, or read again when `fresh`. Each review still reads Apple itself.
    public func pricingSetupState(account: Account, appId: String, fresh: Bool) async throws -> PricingSetupState {
        if fresh { await invalidateAppleReads() }
        let client = try readClient(for: account)
        return try await AppStoreReadCache.rereadingAfterInvalidation { try await pricingSetupState(account: account, appId: appId, client: client) }
    }

    /// Reads the app price, products, subscription groups and which products have prices. Nothing is written.
    public func pricingSetupState(account: Account, appId: String, client: AppStoreConnectClient) async throws -> PricingSetupState {
        try requirePublishingAccount(account, appId: appId, client: client)
        let reads = AppleReads(client)
        // The price, products, groups and App Availability are independent reads, sent together.
        async let priceRead: (AppPriceState, String?) = {
            do { return (try await PricingSetupReads.appPrice(appId: appId, reads: reads), nil) }
            catch let error where Self.cancelled(error) { throw error }
            catch { return (.unknown, PricingSetupReads.describe(error)) }
        }()
        async let catalogRead = ProductPricing.catalog(appId: appId, reads: reads)
        async let groupsRead = ProductPricing.optional { try await PricingSetupReads.groups(appId: appId, reads: reads) }
        async let availableRead = ProductPricing.optional { try await PricingSetupReads.appAvailable(appId, reads: reads) }
        let (price, priceProblem) = try await priceRead
        if price != .unknown { try? recordSectionCheck(.pricing, answered: price.isFree || price.isPaid, detail: price.label, accountId: account.id, appId: appId) }
        let catalog = try await catalogRead, groups = try await groupsRead
        let products = (catalog.purchases ?? []) + (catalog.subscriptions ?? [])
        var priced: Set<String>? = [], schedules: [String: ProductPriceSchedule] = [:]
        if products.count > 60 { priced = nil }
        else {
            let read = try await reads.each(products) { product in try await ProductPricing.optional { try await ProductPricing.schedule(product, reads: reads) } }
            for (product, schedule) in zip(products, read) {
                guard let schedule else { priced = nil; continue }
                if schedule.available { priced?.insert(product.id); schedules[product.id] = schedule }
            }
        }
        let available = try await availableRead
        try Task.checkCancellation(); try requirePublishingAccount(account, appId: appId, client: client)
        var state = PricingSetupState(appPrice: price, purchases: catalog.purchases, subscriptions: catalog.subscriptions, groups: groups, priced: priced, priceProblem: priceProblem)
        state.schedules = schedules
        state.appAvailable = available ?? nil
        return state
    }
    nonisolated static func cancelled(_ error: Error) -> Bool { error is CancellationError || (error as? URLError)?.code == .cancelled }

    /// The first price of a purchase created in an earlier review: the Apple price level with this amount in the base country or region.
    public func firstPurchasePriceRequest(account: Account, appId: String, productId: String, territory: String, amount: String, client: AppStoreConnectClient) async throws -> PublishRequest? {
        try requirePublishingAccount(account, appId: appId, client: client)
        let reads = AppleReads(client)
        guard let product = try await ProductPricing.catalog(appId: appId, reads: reads).purchases?.first(where: { $0.productId.caseInsensitiveCompare(productId) == .orderedSame }) else { return nil }
        guard ProductPricing.initial(try await ProductPricing.schedule(product, reads: reads)) else { return nil }
        guard let point = try await ProductPricing.points(product, territory: territory, reads: reads).first(where: { PricingMath.decimal($0.customerPrice ?? "") == PricingMath.decimal(amount) }) else {
            throw PublishFailure.invalid("\(amount) is not an Apple in-app purchase price in \(WorkspaceSession.countryName(territory)). Set its price in In-App Purchases and Subscriptions.")
        }
        var request = PublishRequest(accountId: account.id, appId: appId, scope: .productPricing)
        request.purchasePrice = PurchasePriceChange(productId: product.id, territory: territory, pricePointId: point.id, startDate: nil)
        try Task.checkCancellation(); try requirePublishingAccount(account, appId: appId, client: client)
        return try request.validated()
    }

    /// Apple's app price levels in one country or region, for choosing a price or a temporary price.
    public func appPriceLevels(account: Account, appId: String, territory: String, client: AppStoreConnectClient) async throws -> [ProductPricePoint] {
        try requirePublishingAccount(account, appId: appId, client: client)
        let value = try await PricingSetupReads.appPoints(appId: appId, territory: territory, reads: AppleReads(client))
        try Task.checkCancellation(); try requirePublishingAccount(account, appId: appId, client: client); return value
    }
}

/// Apple reads shared by the setup state, the planner and the write checks, so all three see the same values.
enum PricingSetupReads {
    static func appPrice(appId: String, reads: AppleReads) async throws -> AppPriceState {
        guard let schedule = try await scheduleId(appId: appId, reads: reads) else { return .none }
        let page: (data: [AppStoreConnectClient.Resource], included: [AppStoreConnectClient.Resource])
        do { page = try await reads.pages("/v1/appPriceSchedules/\(schedule)/manualPrices?limit=200&include=appPricePoint%2Cterritory") }
        catch AppStoreConnectClient.Failure.status(404) { return .none }
        let rows = WorkspaceSession.priceRows(page, source: "manual")
        guard !rows.isEmpty else { return .none }
        guard let base = try await reads.get("/v1/appPriceSchedules/\(schedule)/baseTerritory").first, base.type == "territories", ProductPricing.territory(base.id) else { return .unknown }
        guard let current = PricingMath.current(rows, today: ProductPricing.today())[base.id], let amount = PricingMath.decimal(current.customerPrice) else { return .unknown }
        return amount == 0 ? .free(territory: base.id) : .paid(territory: base.id, amount: current.customerPrice, currency: current.currency)
    }

    /// Apple's answer to a failed price read, in a sentence the Pricing header shows.
    static func describe(_ error: Error) -> String { ProductPricing.readProblem(error, reading: "the app price") }

    /// The app's price schedule, or nil when Apple has none for it yet.
    static func scheduleId(appId: String, reads: AppleReads) async throws -> String? {
        let items: [AppStoreConnectClient.Resource]
        do { items = try await reads.get("/v1/apps/\(appId)/appPriceSchedule?include=app") }
        catch AppStoreConnectClient.Failure.status(404) { return nil }
        guard let schedule = items.first else { return nil }
        guard items.count == 1, schedule.type == "appPriceSchedules", Apple.within(schedule, "app", "apps", appId) else { throw PublishFailure.invalid("Apple price schedule no longer belongs to the approved app.") }
        return schedule.id
    }

    static func groups(appId: String, reads: AppleReads) async throws -> [SubscriptionGroupSummary] {
        let items = try ProductPricing.unique(try await reads.list("/v1/apps/\(appId)/subscriptionGroups?limit=200"), "subscriptionGroups")
        guard items.allSatisfy({ Apple.within($0, "app", "apps", appId) }) else { throw PublishFailure.invalid("Apple returned a subscription group of another app.") }
        return items.map { SubscriptionGroupSummary(id: $0.id, referenceName: ProductPricing.text($0.attributes?["referenceName"]).isEmpty ? $0.id : ProductPricing.text($0.attributes?["referenceName"])) }
            .sorted { ($0.referenceName, $0.id) < ($1.referenceName, $1.id) }
    }

    static func appPoints(appId: String, territory: String, reads: AppleReads) async throws -> [ProductPricePoint] {
        guard ProductPricing.territory(territory) else { throw PublishFailure.invalid("Choose one Apple territory.") }
        let page = try await reads.pages("/v1/apps/\(appId)/appPricePoints?filter%5Bterritory%5D=\(territory)&include=territory&limit=200")
        guard page.data.count <= 1200 else { throw PublishFailure.invalid("Too many price points for one territory.") }
        let currency = ProductPricing.text(page.included.first { $0.type == "territories" && $0.id == territory }?.attributes?["currency"], 10)
        return try ProductPricing.unique(page.data, "appPricePoints").map { item in
            guard Apple.owned(item, "territory", "territories", territory) else { throw PublishFailure.invalid("Apple returned a price point for another territory.") }
            return ProductPricePoint(id: item.id, territory: territory, currency: currency.isEmpty ? nil : currency, customerPrice: Apple.text(item.attributes?["customerPrice"]))
        }.sorted { (PricingMath.decimal($0.customerPrice ?? "") ?? -1, $0.id) < (PricingMath.decimal($1.customerPrice ?? "") ?? -1, $1.id) }
    }

    /// Apple's equalized subscription price points in every other country or region, from one chosen price point.
    /// The subscription's own Apple price points chosen per country or region, each checked to belong to that subscription and territory.
    static func chosen(_ product: PriceProduct, points chosen: [String: String], reads: AppleReads) async throws -> [ProductPricePoint] {
        let codes = chosen.keys.sorted()
        let currencies = Dictionary(try ProductPricing.unique(try await reads.list("/v1/territories?limit=200"), "territories").map { ($0.id, ProductPricing.text($0.attributes?["currency"], 10)) }, uniquingKeysWith: { first, _ in first })
        var result: [ProductPricePoint] = []
        for start in stride(from: 0, to: codes.count, by: PricePointCatalog.batchSize) {
            let batch = Array(codes[start..<min(start + PricePointCatalog.batchSize, codes.count)])
            let points = try await PricePointCatalog.read(.subscription(product.id), territories: batch, list: { try await reads.list($0) })
            for code in batch {
                guard let point = points.first(where: { $0.territory == code && $0.id == chosen[code] }) else {
                    throw PublishFailure.invalid("The chosen price for \(WorkspaceSession.countryName(code)) is not one of this subscription's Apple prices. Preview the prices again.")
                }
                let currency = currencies[code] ?? ""
                result.append(ProductPricePoint(id: point.id, territory: code, currency: currency.isEmpty ? nil : currency, customerPrice: point.customerPrice))
            }
        }
        return result
    }

    static func equalized(_ point: String, reads: AppleReads) async throws -> [ProductPricePoint] {
        guard ProductPricing.opaque(point) else { throw PublishFailure.invalid("Choose a valid Apple price level.") }
        let page = try await reads.pages("/v1/subscriptionPricePoints/\(point)/equalizations?include=territory&limit=200")
        let territories = Dictionary(page.included.filter { $0.type == "territories" }.map { ($0.id, ProductPricing.text($0.attributes?["currency"], 10)) }, uniquingKeysWith: { first, _ in first })
        let points = try ProductPricing.unique(page.data, "subscriptionPricePoints").map { item -> ProductPricePoint in
            guard let territory = Apple.owner(item, "territory"), territory.type == "territories", ProductPricing.territory(territory.id) else { throw PublishFailure.invalid("Apple returned an equalized price without a territory.") }
            let currency = territories[territory.id] ?? ""
            return ProductPricePoint(id: item.id, territory: territory.id, currency: currency.isEmpty ? nil : currency, customerPrice: Apple.text(item.attributes?["customerPrice"]))
        }
        guard Set(points.map(\.territory)).count == points.count else { throw PublishFailure.invalid("Apple returned two equalized prices for one territory.") }
        return points.sorted { $0.territory < $1.territory }
    }

    /// Whether the app has App Availability at Apple; nil when Apple's answer could not be read.
    static func appAvailable(_ appId: String, reads: AppleReads) async throws -> Bool? {
        do { return try await reads.get("/v1/apps/\(appId)/appAvailabilityV2").contains { $0.type == "appAvailabilities" } }
        catch AppStoreConnectClient.Failure.status(404) { return false }
    }
    static func territories(reads: AppleReads) async throws -> [String] {
        let items = try ProductPricing.unique(try await reads.list("/v1/territories?limit=200"), "territories")
        guard !items.isEmpty, items.allSatisfy({ ProductPricing.territory($0.id) }) else { throw PublishFailure.invalid("Apple returned an incomplete territory catalog.") }
        return items.map(\.id).sorted()
    }
}
