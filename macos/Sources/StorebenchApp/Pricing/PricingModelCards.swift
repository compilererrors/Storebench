import StorebenchCore
import SwiftUI

/// The app's price in its base country or region, with an optional launch sale and planned price change for a paid app.
/// Apple sets equalized prices in the other countries and regions.
struct AppPriceCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let state: PricingSetupState, model: PricingModelKind
    var done: () -> Void = {}
    @State private var choices = PricingChoices()
    @State private var territory = ""
    @State private var levelId = ""
    @State private var sale = false
    @State private var saleId = ""
    @State private var saleStart = Date()
    @State private var saleEnd = Date().addingTimeInterval(7 * 86_400)
    @State private var change = false
    @State private var changeId = ""
    @State private var changeDate = Date().addingTimeInterval(30 * 86_400)
    /// Free or a paid price, as App Store Connect allows for every model; until chosen, the current price or the model decides.
    @State private var charge: Bool?
    private var free: Bool { !(charge ?? (state.appPrice.isPaid || (!state.appPrice.isFree && model.paidApp))) }
    private var freeLevel: ProductPricePoint? { choices.levels?.first { PricingMath.decimal($0.customerPrice ?? "") == 0 } }
    private func paidLevel(_ id: String) -> Bool { choices.levels?.contains(where: { $0.id == id && PricingMath.decimal($0.customerPrice ?? "").map { $0 > 0 } == true }) == true }
    private var blocked: String? {
        if let reason = choices.levelsBlocked(territory) { return reason }
        if free { return freeLevel == nil ? "Apple has no Free price in this country or region." : nil }
        guard paidLevel(levelId) else { return "Choose a price above Free." }
        if sale {
            guard !saleId.isEmpty else { return "Choose the launch sale price." }
            if saleStart.pricingDay < ReportDay.today { return "Choose today or a later start date for the launch sale." }
            if saleEnd.pricingDay < saleStart.pricingDay { return "The launch sale must end on or after its start date." }
        }
        if change {
            guard paidLevel(changeId) else { return "Choose the new price." }
            if changeDate.pricingDay <= ReportDay.today { return "Choose a date after today for the price change." }
            if sale, changeDate.pricingDay <= saleEnd.pricingDay { return "The price change must start after the launch sale ends." }
        }
        return nil
    }

    var body: some View {
        PricingReviewCard(title: "Price Schedule", subtitle: subtitle,
                          help: "model", account: account, app: app, session: session, blocked: blocked, request: request, done: done) {
            StorebenchChoicePicker("App Price", selection: Binding(get: { !free }, set: { charge = $0 }), options: [(false, "Free"), (true, "Paid")],
                                   hint: PricingFlow.appPriceHint(model, free: free), info: PricingFlow.appPriceChoice(model))
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                Fact(title: "Current Price", value: state.appPrice.label, compact: true)
                Fact(title: "Base Country or Region", value: state.appPrice.territory.map { WorkspaceSession.countryName($0) } ?? "None", compact: true)
            }
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                PricingCountryPicker(title: "Base Country or Region", territories: choices.territories, selection: $territory)
                if free { StorebenchFact(label: "Price", value: "Free") }
                else {
                    PricingLevelPicker(levels: choices.levels, selection: $levelId, includeFree: false, reason: choices.levelsBlocked(territory))
                        .storebenchNeeded(choices.levels != nil && !paidLevel(levelId) ? "Choose the price." : nil)
                }
            }
            if !free {
                StorebenchCardSection(title: "Launch Sale", description: "A lower price for the first days, such as a launch sale. The price returns the day after the end date.") {
                    Toggle("Start with a launch sale", isOn: $sale)
                    StorebenchMetricGrid(maximumColumns: 3, minimumWidth: 200) {
                        PricingLevelPicker(title: "Sale Price", levels: choices.levels, selection: $saleId).disabled(!sale)
                        StorebenchDateField("Start Date", selection: $saleStart, displayedComponents: .date).disabled(!sale)
                        StorebenchDateField("End Date", selection: $saleEnd, displayedComponents: .date).disabled(!sale)
                    }
                }
                StorebenchCardSection(title: "Planned Price Change", description: "A new price from a later date, such as after an introductory period.") {
                    Toggle("Change the price later", isOn: $change)
                    StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                        PricingLevelPicker(title: "New Price", levels: choices.levels, selection: $changeId, includeFree: false).disabled(!change)
                        StorebenchDateField("Start Date", selection: $changeDate, displayedComponents: .date).disabled(!change)
                    }
                }
            }
        }
        .task { await choices.loadTerritories(account: account, session: session); if territory.isEmpty { territory = state.appPrice.territory ?? (choices.territories.contains { $0.code == "USA" } ? "USA" : choices.territories.first?.code ?? "") } }
        .task(id: territory) {
            guard !territory.isEmpty, let session else { return }
            let code = territory; saleId = ""; changeId = ""
            await choices.loadLevels(territory: code) { try await session.appPriceLevels(account: account, appId: app.id, territory: code) }
            if case .paid(let base, let amount, _) = state.appPrice, base == code { levelId = choices.levels?.first { PricingMath.decimal($0.customerPrice ?? "") == PricingMath.decimal(amount) }?.id ?? "" } else { levelId = "" }
        }
    }

    private var subtitle: String {
        let inside = model.sellsSubscriptions ? "subscriptions" : model == .freeWithInAppPurchases ? "in-app purchases" : nil
        if let inside { return "Free is the usual download price for this model: people download the app at no cost and pay for \(inside) inside the app. Choose Paid only to also charge before download." }
        if model == .free { return "Free is the download price for this model. App Store Connect still needs it set before the version can be submitted." }
        return "Choose what people pay to download the app in the Base Country or Region. Apple sets comparable prices in the other countries or regions."
    }

    private func request() throws -> PublishRequest {
        var value = PricingSetupChange(action: .appPrice); value.territory = territory; value.pricePointId = free ? freeLevel?.id : levelId
        if !free, sale { value.salePointId = saleId; value.startDate = saleStart.pricingDay; value.endDate = saleEnd.pricingDay }
        if !free, change { value.changePointId = changeId; value.changeDate = changeDate.pricingDay }
        var request = PublishRequest(accountId: account.id, appId: app.id, scope: .pricingSetup); request.pricingSetup = value
        return request
    }
}

/// A temporary price, such as a sale: from its first through its last day, then the previous price returns.
struct TemporaryPriceCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let state: PricingSetupState
    var done: () -> Void = {}
    @State private var choices = PricingChoices()
    @State private var territory = ""
    @State private var levelId = ""
    @State private var start = Date().addingTimeInterval(86_400)
    @State private var end = Date().addingTimeInterval(8 * 86_400)
    private var blocked: String? {
        guard state.appPrice.isPaid else { return "Set the app's price first. A temporary price returns to it afterwards." }
        if let reason = choices.levelsBlocked(territory) { return reason }
        guard !levelId.isEmpty else { return "Choose the temporary price." }
        if start.pricingDay < ReportDay.today { return "Choose today or a later start date." }
        return end.pricingDay < start.pricingDay ? "The end date must be on or after the start date." : nil
    }

    var body: some View {
        PricingReviewCard(title: "Temporary Price", subtitle: "Lower or raise the price for a set time, such as a sale. The previous price returns the day after the end date.",
                          help: "overrides", account: account, app: app, session: session, blocked: blocked, request: request, done: done) {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                PricingCountryPicker(territories: choices.territories, selection: $territory)
                PricingLevelPicker(levels: choices.levels, selection: $levelId)
                StorebenchDateField("Start Date", selection: $start, displayedComponents: .date)
                StorebenchDateField("End Date", selection: $end, displayedComponents: .date)
            }
            Text(territory == state.appPrice.territory ? "This is the base country or region: countries and regions with Apple's equalized prices follow the temporary price." : "Only this country or region changes. Choose the base country or region to change every country and region with Apple's equalized prices.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .task { await choices.loadTerritories(account: account, session: session); if territory.isEmpty { territory = state.appPrice.territory ?? "" } }
        .task(id: territory) {
            guard !territory.isEmpty, let session else { return }
            let code = territory; levelId = ""
            await choices.loadLevels(territory: code) { try await session.appPriceLevels(account: account, appId: app.id, territory: code) }
        }
    }

    private func request() throws -> PublishRequest {
        var change = PricingSetupChange(action: .temporaryAppPrice); change.territory = territory; change.pricePointId = levelId; change.startDate = start.pricingDay; change.endDate = end.pricingDay
        var value = PublishRequest(accountId: account.id, appId: app.id, scope: .pricingSetup); value.pricingSetup = change
        return value
    }
}

/// The app's consumable, non-consumable and non-renewing in-app purchases, and one form that creates a purchase and then sets its price.
struct PurchasesCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let state: PricingSetupState
    var done: () -> Void = {}
    @State private var choices = PricingChoices()
    @State private var type = "CONSUMABLE"
    @State private var name = ""
    @State private var productId = ""
    @State private var family = false
    @State private var territory = ""
    @State private var amount = ""
    @State private var created: (productId: String, territory: String, amount: String)?
    private var blocked: String? {
        guard let purchases = state.purchases, let subscriptions = state.subscriptions else { return "Apple did not return the app's complete product list. Refresh first." }
        if PricingSetupChange.referenceName(name) == nil { return "Enter a Reference Name of up to 64 characters." }
        if !PricingSetupChange.validProductId(productId) { return "Enter a Product ID with letters, numbers, underscores or periods." }
        if (purchases + subscriptions).contains(where: { $0.productId.caseInsensitiveCompare(productId) == .orderedSame }) { return "Another product of this app already uses this Product ID." }
        return !amount.isEmpty && territory.isEmpty ? "Choose the base country or region for the price." : nil
    }

    var body: some View {
        PricingReviewCard(title: "In-App Purchases", subtitle: "Create an in-app purchase with its price. Apple creates it first; the next review sets its price, and Apple equalizes the other countries and regions.",
                          account: account, app: app, session: session, blocked: blocked, request: request, done: done, followUp: priceFollowUp) {
            PricingProductTable(key: "pricing-purchases", products: state.purchases ?? [])
            if state.purchases == nil { Text("Apple did not return a complete in-app purchase list.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            StorebenchCardSection(title: "Create In-App Purchase") {
                StorebenchChoicePicker("Type", selection: $type, options: PricingSetupChange.purchaseTypes)
                StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                    StorebenchTextField("Reference Name", text: $name, hint: "Shown only in App Store Connect and sales reports.")
                        .storebenchNeeded(PricingSetupChange.referenceName(name) == nil ? "Enter the Reference Name, up to 64 characters." : nil)
                    StorebenchTextField("Product ID", text: $productId, hint: "Unique and permanent, such as com.example.app.coins100.")
                        .storebenchNeeded(PricingSetupChange.referenceName(name) != nil && !PricingSetupChange.validProductId(productId) ? "Enter the Product ID with letters, numbers, underscores or periods." : nil)
                    PricingCountryPicker(title: "Base Country or Region", territories: choices.territories, selection: $territory)
                    PricingAmountPicker(levels: choices.levels, selection: $amount, none: "Set the price later")
                }
                Toggle("Family Sharing", isOn: $family).disabled(type != "NON_CONSUMABLE").help(type == "NON_CONSUMABLE" ? "Family members can use the purchase. It cannot be turned off again." : "Family Sharing applies to non-consumable purchases.")
            }
        }
        .task { await choices.loadTerritories(account: account, session: session); if territory.isEmpty { territory = state.appPrice.territory ?? (choices.territories.contains { $0.code == "USA" } ? "USA" : "") } }
        .task(id: territory) {
            guard !territory.isEmpty, let session else { return }
            let code = territory; amount = ""
            await choices.loadLevels(territory: code) { try await session.appPriceLevels(account: account, appId: app.id, territory: code) }
        }
        .onChange(of: type) { if type != "NON_CONSUMABLE" { family = false } }
    }

    private func request() throws -> PublishRequest {
        var change = PricingSetupChange(action: .createInAppPurchase); change.name = name; change.productId = productId; change.productType = type
        if family { change.familySharing = true }
        created = amount.isEmpty ? nil : (productId, territory, amount)
        var value = PublishRequest(accountId: account.id, appId: app.id, scope: .pricingSetup); value.pricingSetup = change
        return value
    }

    /// After the purchase exists: its first price at Apple's level with the chosen amount; nil once it has one.
    private func priceFollowUp() async throws -> PublishRequest? {
        guard let created, let session else { return nil }
        let value = try await session.firstPurchasePriceRequest(account: account, appId: app.id, productId: created.productId, territory: created.territory, amount: created.amount)
        if value == nil { self.created = nil; name = ""; productId = "" }
        return value
    }
}

/// The Subscription Group a new subscription goes in: an existing group, or the Reference Name of a new one. Saved on this Mac;
/// App Store Connect creates a new group with its first subscription in the Subscriptions step.
struct SubscriptionGroupStep: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let state: PricingSetupState
    @State private var draft = SubscriptionSetupDraft()
    @State private var loaded = false
    @State private var status = ""

    var body: some View {
        Card(title: "Subscription Group", subtitle: "People can subscribe to one subscription in a group at a time, and each person can redeem one introductory offer per group. Most apps need one group.") {
            PricingProductTable(key: "pricing-subscription-groups", products: state.subscriptions ?? [], groups: true)
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                StorebenchPicker("Subscription Group", selection: $draft.groupId) {
                    SelectionOption("New Subscription Group", value: "")
                    selectionOptions(state.groups ?? []) { SelectionOption($0.referenceName, value: $0.id) }
                }
                StorebenchTextField("Reference Name", text: $draft.groupName, hint: draft.groupId.isEmpty ? "For the new group, such as Premium. Shown only in App Store Connect." : "Uses the chosen group.").disabled(!draft.groupId.isEmpty)
                    .storebenchNeeded(draft.groupId.isEmpty && PricingSetupChange.referenceName(draft.groupName) == nil ? "Enter the Reference Name for the new group, or choose an existing group." : nil)
            }
            StorebenchTextSlot(text: status, height: 36, font: .sbCallout, color: StorebenchTheme.muted, live: true)
        }
        .task {
            draft = await SubscriptionSetupDraft.load(account: account, app: app, session: session, state: state); loaded = true; describe()
        }
        .task(id: "\(draft.groupId)/\(draft.groupName)") {
            guard loaded else { return }
            describe()
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            try? await session?.saveSubscriptionSetupDraft(draft, accountId: account.id, appId: app.id)
        }
    }

    private func describe() {
        if !draft.groupId.isEmpty { status = "Next: add subscriptions to \(state.groups?.first { $0.id == draft.groupId }?.referenceName ?? "this group") in Subscriptions."; return }
        status = PricingSetupChange.referenceName(draft.groupName) == nil ? "To continue: enter a Reference Name for the new Subscription Group."
            : (state.groups ?? []).contains(where: { $0.referenceName.caseInsensitiveCompare(draft.groupName) == .orderedSame }) ? "A Subscription Group with this Reference Name exists. Choose it instead."
            : "Saved on this Mac. App Store Connect creates the group with its first subscription in Subscriptions."
    }
}

/// The auto-renewable subscriptions in the chosen Subscription Group: each one's Subscription Duration, Reference Name, Product ID and
/// Family Sharing. Create sends the new ones, with a new group, after the review is approved; prices follow in Subscription Prices.
struct SubscriptionsStep: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let state: PricingSetupState
    var done: () -> Void = {}
    @State private var draft = SubscriptionSetupDraft()
    @State private var loaded = false
    private var existing: [PriceProduct] { state.subscriptions ?? [] }
    private func onApple(_ plan: SubscriptionPlan) -> PriceProduct? { existing.first { $0.productId.caseInsensitiveCompare(plan.productId) == .orderedSame } }
    private var blocked: String? {
        guard let purchases = state.purchases, state.subscriptions != nil, let groups = state.groups else { return "Apple did not return the app's complete product list. Refresh first." }
        if draft.groupId.isEmpty {
            guard PricingSetupChange.referenceName(draft.groupName) != nil else { return "Choose a Subscription Group or name a new one in step Subscription Group." }
            if groups.contains(where: { $0.referenceName.caseInsensitiveCompare(draft.groupName) == .orderedSame }) { return "A Subscription Group with this Reference Name exists. Choose it in step Subscription Group." }
        }
        for (index, plan) in draft.plans.enumerated() where onApple(plan) == nil {
            let label = "Subscription \(index + 1)"
            if PricingSetupChange.referenceName(plan.name) == nil { return "\(label): enter a Reference Name of up to 64 characters." }
            if !PricingSetupChange.validProductId(plan.productId) { return "\(label): enter a Product ID with letters, numbers, underscores or periods." }
            if purchases.contains(where: { $0.productId.caseInsensitiveCompare(plan.productId) == .orderedSame }) { return "\(label): an in-app purchase already uses this Product ID." }
            if draft.plans.filter({ $0.productId.caseInsensitiveCompare(plan.productId) == .orderedSame }).count > 1 { return "\(label): give each subscription its own Product ID." }
        }
        if draft.plans.allSatisfy({ onApple($0) != nil }) { return "App Store Connect has these subscriptions. Add Subscription to create another." }
        return nil
    }

    var body: some View {
        PricingReviewCard(title: "Subscriptions", subtitle: "Group: \(groupName). Create sends the subscriptions App Store Connect does not have yet\(draft.groupId.isEmpty ? ", and the new group first" : ""), after you approve the review. Prices follow in Subscription Prices.",
                          command: "Create", account: account, app: app, session: session, blocked: blocked, request: request, done: done) {
            PricingProductTable(key: "pricing-subscriptions", products: existing, groups: true)
            ForEach($draft.plans) { $plan in planSection($plan) }
            StorebenchActionGroup {
                StorebenchCommand(title: "Add Subscription", busy: false, unavailable: draft.plans.count >= 10 ? "Create up to ten subscriptions at a time." : nil, primary: false) { addPlan() }
            }
        }
        .task { draft = await SubscriptionSetupDraft.load(account: account, app: app, session: session, state: state); loaded = true }
        .task(id: draft) {
            guard loaded else { return }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            try? await session?.saveSubscriptionSetupDraft(draft, accountId: account.id, appId: app.id)
        }
    }

    private var groupName: String {
        draft.groupId.isEmpty ? (draft.groupName.isEmpty ? "not chosen" : "\(draft.groupName) (new)") : state.groups?.first { $0.id == draft.groupId }?.referenceName ?? "chosen group"
    }

    private func planSection(_ plan: Binding<SubscriptionPlan>) -> some View {
        let index = draft.plans.firstIndex { $0.id == plan.wrappedValue.id } ?? 0, apple = onApple(plan.wrappedValue)
        return StorebenchCardSection(title: "Subscription \(index + 1)", description: apple.map { _ in "In App Store Connect. Set its price in Subscription Prices." } ?? "") {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                StorebenchPicker("Subscription Duration", selection: plan.duration) { selectionOptions(PricingSetupChange.subscriptionDurations) { SelectionOption($0.1, value: $0.0) } }
                StorebenchTextField("Reference Name", text: plan.name, hint: "Shown only in App Store Connect and sales reports.")
                    .storebenchNeeded(apple == nil && PricingSetupChange.referenceName(plan.wrappedValue.name) == nil ? "Enter the Reference Name, up to 64 characters." : nil)
                StorebenchTextField("Product ID", text: plan.productId, hint: "Unique and permanent, such as com.example.app.monthly.")
                    .storebenchNeeded(apple == nil && PricingSetupChange.referenceName(plan.wrappedValue.name) != nil && !PricingSetupChange.validProductId(plan.wrappedValue.productId) ? "Enter the Product ID with letters, numbers, underscores or periods." : nil)
            }
            Toggle("Family Sharing", isOn: plan.familySharing).help("Family members share the subscription. It cannot be turned off again.")
            StorebenchActionGroup {
                StorebenchCommand(title: "Remove", busy: false, unavailable: draft.plans.count == 1 ? "Keep at least one subscription." : apple != nil ? "This subscription is in App Store Connect." : nil, primary: false) {
                    draft.plans.removeAll { $0.id == plan.wrappedValue.id }
                }
            }
        }.storebenchWorking(apple != nil)
    }

    private static let names = ["ONE_WEEK": "Weekly", "ONE_MONTH": "Monthly", "TWO_MONTHS": "Every Two Months", "THREE_MONTHS": "Quarterly", "SIX_MONTHS": "Every Six Months", "ONE_YEAR": "Yearly"]
    /// A new subscription suggests the next duration and a Product ID beside the first one's.
    private func addPlan() {
        var plan = SubscriptionPlan()
        plan.duration = PricingSetupChange.subscriptionDurations.map(\.0).first { code in !draft.plans.contains { $0.duration == code } && code != "ONE_WEEK" } ?? "ONE_YEAR"
        plan.name = Self.names[plan.duration] ?? ""
        if let first = draft.plans.first?.productId, let dot = first.lastIndex(of: ".") { plan.productId = first[..<dot] + "." + plan.name.lowercased().replacingOccurrences(of: " ", with: "") }
        draft.plans.append(plan)
    }

    private func request() async throws -> PublishRequest {
        try await session?.saveSubscriptionSetupDraft(draft, accountId: account.id, appId: app.id)
        guard let value = draft.createRequest(accountId: account.id, appId: app.id, existing: existing) else { throw PublishFailure.invalid("App Store Connect already has these subscriptions.") }
        return value
    }
}

extension SubscriptionSetupDraft {
    /// The setup saved on this Mac matched to App Store Connect's groups, or a first subscription in the app's first group.
    @MainActor static func load(account: Account, app: Account.App, session: WorkspaceSession?, state: PricingSetupState) async -> SubscriptionSetupDraft {
        if let session, let saved = try? await session.subscriptionSetupDraft(accountId: account.id, appId: app.id) { return saved.matched(groups: state.groups) }
        var draft = SubscriptionSetupDraft(); draft.groupId = state.groups?.first?.id ?? ""; draft.plans[0].name = "Monthly"
        return draft
    }
}

/// One subscription's prices with the shared Price Strategy: Apple's comparable prices from one price in the Base Country or Region,
/// a built-in model such as Big Mac Index or World Bank purchasing power (PPP), prices entered manually, or a pricing profile.
struct SubscriptionPricesCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let state: PricingSetupState
    var done: () -> Void = {}
    @State private var choices = PricingChoices()
    @State private var strategy = PriceStrategyModel()
    @State private var subscriptionId = ""
    @State private var territory = ""
    @State private var levelId = ""
    @State private var everywhere = true
    @State private var start = Date().addingTimeInterval(2 * 86_400)
    @State private var policy = "keep"
    @State private var saved: SavedSubscriptionPrices?
    /// Apple's comparable prices for the chosen price, by country or region; nil until read.
    @State private var comparable: [String: String]?
    private var product: PriceProduct? { state.subscriptions?.first { $0.id == subscriptionId } }
    private var priced: Bool { state.schedule(subscriptionId)?.available == true }
    /// Apple's schedule for the chosen subscription; nil while no subscription is chosen or Apple's prices were not read.
    private var summary: SubscriptionPriceSummary? {
        guard product != nil else { return nil }
        return state.schedule(subscriptionId).map { SubscriptionPriceSummary($0, territory: territory, today: ReportDay.today) }
    }
    /// The price for each country or region this review would set; nil while it is not known yet.
    private var chosenPoints: [String: String]? {
        guard strategy.strategy == .apple else { return strategy.preview?.points }
        guard !levelId.isEmpty, !territory.isEmpty else { return nil }
        guard everywhere else { return [territory: levelId] }
        return comparable.map { $0.merging([territory: levelId]) { _, base in base } }
    }
    private var unchanged: Bool {
        guard priced, let summary, let chosenPoints else { return false }
        return summary.unchanged(chosenPoints, start: start.pricingDay, today: ReportDay.today)
    }
    private var blocked: String? {
        if state.appAvailable == false { return "Set up App Availability first. Apple accepts prices only where the app is available." }
        guard product != nil else { return state.subscriptions?.isEmpty == true ? "Create a subscription in Subscriptions first." : "Choose the subscription to price." }
        if state.schedule(subscriptionId) == nil { return "Apple did not return this subscription's prices. Refresh first." }
        if territory.isEmpty { return "Choose the Base Country or Region." }
        if strategy.strategy == .apple {
            if let reason = choices.levelsBlocked(territory) { return reason }
            guard !levelId.isEmpty else { return "Choose the price." }
        } else if let reason = strategy.blocked(base: territory) { return reason }
        if priced && start.pricingDay <= ReportDay.today { return "Choose a start date after today for the new prices." }
        return unchanged ? "Apple already has these prices. Choose another price or start date to schedule a change." : nil
    }

    var body: some View {
        PricingReviewCard(title: priced ? "Change Subscription Price" : "Subscription Prices",
                          subtitle: priced ? "Schedule new prices for a subscription that already has prices. Apple keeps the current prices until the start date."
                                           : "Choose the subscription, then how its first prices are set in each country or region.",
                          account: account, app: app, session: session, blocked: blocked, request: request, done: done) {
            SubscriptionPriceStatus(app: app, product: product, summary: summary, saved: saved, unread: product != nil && state.schedule(subscriptionId) == nil)
            ProductPriceScheduleTable(kind: product?.kind, schedule: product == nil ? nil : state.schedule(subscriptionId), territories: choices.territories.isEmpty ? nil : choices.territories.count,
                                      unread: product != nil && state.schedule(subscriptionId) == nil)
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                StorebenchPicker("Subscription", selection: $subscriptionId) {
                    SelectionOption("Choose a subscription", value: "")
                    selectionOptions(state.subscriptions ?? []) { SelectionOption("\($0.name) · \($0.group ?? "")", value: $0.id) }
                }.storebenchNeeded(product == nil ? (state.subscriptions?.isEmpty == true ? "Create a subscription in Subscriptions first." : "Choose the subscription to price first.") : nil)
                PricingStrategyPicker(selection: Binding(get: { strategy.strategy }, set: { strategy.strategy = $0 }), profiles: strategy.profiles).storebenchWorking(product == nil)
            }
            Group {
                StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                    PricingCountryPicker(title: "Base Country or Region", territories: choices.territories, selection: $territory)
                        .storebenchNeeded(product != nil && territory.isEmpty ? "Choose the Base Country or Region." : nil)
                    PricingLevelPicker(levels: choices.levels, selection: $levelId, includeFree: false, reason: strategy.strategy == .apple ? choices.levelsBlocked(territory) : "Set by the Price Strategy below.")
                        .storebenchWorking(strategy.strategy != .apple)
                        .storebenchNeeded(strategy.strategy == .apple && product != nil && choices.levels != nil && levelId.isEmpty ? "Choose the price." : nil)
                    StorebenchChoicePicker("Countries or Regions", selection: $everywhere, options: [(true, "All Countries or Regions"), (false, "This Country or Region")]).storebenchWorking(strategy.strategy != .apple)
                }
                PriceStrategyFields(model: strategy, owner: product.map { .subscription($0.id) }, base: territory, territories: choices.territories, account: account, session: session)
                StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                    StorebenchDateField("Start Date", selection: $start, displayedComponents: .date).disabled(!priced)
                    StorebenchPicker("Existing Subscribers", selection: $policy) {
                        SelectionOption("Keep Current Price", value: "keep"); SelectionOption("Apply New Price", value: "apply")
                    }.disabled(!priced)
                }
                Text(product == nil ? "Choose a subscription to set its prices." : priced ? "This subscription has prices. The new prices start on the start date; existing subscribers keep their price unless you apply the new price. Apple asks for consent where an increase requires it."
                     : "This subscription has no prices yet. Its first prices take effect immediately.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }.storebenchWorking(product == nil)
        }
        .task {
            await choices.loadTerritories(account: account, session: session)
            if territory.isEmpty { territory = choices.territories.contains { $0.code == "USA" } ? "USA" : choices.territories.first?.code ?? "" }
            await strategy.loadProfiles(session)
        }
        // Follows the subscriptions App Store Connect has, also when they arrive after this step opened: the first one is chosen.
        .task(id: state.subscriptions?.map(\.id) ?? []) { if product == nil { subscriptionId = state.subscriptions?.first?.id ?? "" } }
        // Apple's prices are read whenever both the subscription and the country or region are set, in any order.
        .task(id: "\(product?.id ?? "")/\(territory)") {
            strategy.invalidate()
            guard let product, !territory.isEmpty, let session else { choices.levels = nil; return }
            let code = territory; levelId = ""
            await choices.loadLevels(territory: code) { try await session.productPricePoints(product: product, territory: code, account: account) }
        }
        // The last completed review for this subscription, read again after each save changes Apple's schedule.
        .task(id: "\(subscriptionId)/\(state.schedules[subscriptionId]?.rows.count ?? -1)") {
            saved = subscriptionId.isEmpty ? nil : try? await session?.savedSubscriptionPrices(accountId: account.id, appId: app.id, subscriptionId: subscriptionId)
        }
        // Apple's comparable prices for the chosen price, so an unchanged choice can be recognised before a review is prepared.
        .task(id: "\(levelId)/\(everywhere)/\(priced)/\(strategy.strategy == .apple)") {
            comparable = nil
            guard priced, everywhere, strategy.strategy == .apple, !levelId.isEmpty, let session else { return }
            let point = levelId
            guard let points = try? await session.comparableSubscriptionPrices(pricePointId: point, account: account), point == levelId else { return }
            comparable = Dictionary(points.map { ($0.territory, $0.id) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private func request() throws -> PublishRequest {
        var change = PricingSetupChange(action: .subscriptionPrices); change.subscriptionId = subscriptionId; change.territory = territory; change.pricePointId = levelId
        change.allTerritories = everywhere; change.startDate = priced ? start.pricingDay : nil; change.preserveCurrentPrice = priced && policy == "keep"
        if strategy.strategy != .apple, let points = strategy.preview?.points {
            let anchor = strategy.anchor(base: territory)
            change.territory = anchor; change.pricePointId = points[anchor]; change.allTerritories = false; change.territoryPoints = points
        }
        var value = PublishRequest(accountId: account.id, appId: app.id, scope: .pricingSetup); value.pricingSetup = change
        return value
    }
}

/// What App Store Connect has for the chosen subscription's prices, in fixed rows that keep their place while Apple's answers arrive:
/// the current prices, any scheduled change and the last price review completed in Storebench.
private struct SubscriptionPriceStatus: View {
    let app: Account.App
    let product: PriceProduct?
    let summary: SubscriptionPriceSummary?
    let saved: SavedSubscriptionPrices?
    let unread: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            StorebenchFact(label: "App Store Connect", value: current, problem: unread, done: summary?.priced == true)
            StorebenchFact(label: "Scheduled", value: summary.map { $0.priced ? $0.scheduledLabel : "No prices yet." } ?? "Unknown")
            StorebenchFact(label: "Last Review", value: saved.map { "\($0.label) · \(LibraryOverview.timestamp($0.completedAt))" } ?? "No completed price review for this subscription in Storebench.", done: saved != nil)
            StorebenchActionLink("Open Subscription Prices", destination: link, help: "Monetization → Subscriptions → \(product?.name ?? "subscription") → Subscription Prices in App Store Connect")
                .storebenchWorking(product == nil)
        }
    }
    private var current: String {
        guard product != nil else { return "Choose a subscription." }
        if unread { return "Apple did not return this subscription's prices. Refresh first." }
        return summary?.label ?? "Reading Apple's prices…"
    }
    private var link: URL {
        URL(string: "https://appstoreconnect.apple.com/apps/\(app.id)/distribution/subscriptions/\(product?.id ?? "")")!
    }
}

/// One in-app purchase's prices with the shared Price Strategy. Apple's comparable prices set one price in the Base Country or Region;
/// a model or manual prices add a price for each other country or region to the same reviewed price schedule.
struct PurchasePricesCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let state: PricingSetupState
    var done: () -> Void = {}
    @State private var choices = PricingChoices()
    @State private var strategy = PriceStrategyModel()
    @State private var purchaseId = ""
    @State private var territory = ""
    @State private var levelId = ""
    @State private var start = Date().addingTimeInterval(2 * 86_400)
    private var product: PriceProduct? { state.purchases?.first { $0.id == purchaseId } }
    private var priced: Bool { state.schedule(purchaseId)?.available == true }
    private var blocked: String? {
        if state.appAvailable == false { return "Set up App Availability first. Apple accepts prices only where the app is available." }
        guard product != nil else { return state.purchases?.isEmpty == true ? "Create an in-app purchase in In-App Purchases first." : "Choose the in-app purchase to price." }
        if state.schedule(purchaseId) == nil { return "Apple did not return this in-app purchase's prices. Refresh first." }
        if territory.isEmpty { return "Choose the Base Country or Region." }
        if strategy.strategy == .apple {
            if let reason = choices.levelsBlocked(territory) { return reason }
            guard !levelId.isEmpty else { return "Choose the price." }
        } else if let reason = strategy.blocked(base: territory) { return reason }
        return priced && start.pricingDay < ReportDay.today ? "Choose today or a later start date for the new prices." : nil
    }

    var body: some View {
        PricingReviewCard(title: "In-App Purchase Prices", subtitle: "Choose the in-app purchase, then how its prices are set in each country or region.",
                          account: account, app: app, session: session, blocked: blocked, request: request, done: done) {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                StorebenchPicker("In-App Purchase", selection: $purchaseId) {
                    SelectionOption("Choose an in-app purchase", value: "")
                    selectionOptions(state.purchases ?? []) { SelectionOption("\($0.name) · \($0.productId)", value: $0.id) }
                }.storebenchNeeded(product == nil ? (state.purchases?.isEmpty == true ? "Create an in-app purchase in In-App Purchases first." : "Choose the in-app purchase to price first.") : nil)
                PricingStrategyPicker(selection: Binding(get: { strategy.strategy }, set: { strategy.strategy = $0 }), profiles: strategy.profiles).storebenchWorking(product == nil)
            }
            ProductPriceScheduleTable(kind: product?.kind, schedule: product == nil ? nil : state.schedule(purchaseId), territories: choices.territories.isEmpty ? nil : choices.territories.count,
                                      unread: product != nil && state.schedule(purchaseId) == nil)
            Group {
                StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                    PricingCountryPicker(title: "Base Country or Region", territories: choices.territories, selection: $territory)
                        .storebenchNeeded(product != nil && territory.isEmpty ? "Choose the Base Country or Region." : nil)
                    PricingLevelPicker(levels: choices.levels, selection: $levelId, includeFree: false, reason: strategy.strategy == .apple ? choices.levelsBlocked(territory) : "Set by the Price Strategy below.")
                        .storebenchWorking(strategy.strategy != .apple)
                        .storebenchNeeded(strategy.strategy == .apple && product != nil && choices.levels != nil && levelId.isEmpty ? "Choose the price." : nil)
                }
                PriceStrategyFields(model: strategy, owner: product.map { .purchase($0.id) }, base: territory, territories: choices.territories, account: account, session: session)
                StorebenchDateField("Start Date", selection: $start, displayedComponents: .date).disabled(!priced).storebenchFormColumn()
                Text(product == nil ? "Choose an in-app purchase to set its prices." : priced ? "This in-app purchase has prices. The new prices start on the start date; Apple keeps every other manual price in its schedule."
                     : "This in-app purchase has no prices yet. Its first prices take effect immediately.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }.storebenchWorking(product == nil)
        }
        .task {
            await choices.loadTerritories(account: account, session: session)
            if territory.isEmpty { territory = state.appPrice.territory ?? (choices.territories.contains { $0.code == "USA" } ? "USA" : choices.territories.first?.code ?? "") }
            await strategy.loadProfiles(session)
        }
        .task(id: state.purchases?.map(\.id) ?? []) { if product == nil { purchaseId = state.purchases?.first?.id ?? "" } }
        .task(id: "\(product?.id ?? "")/\(territory)") {
            strategy.invalidate()
            guard let product, !territory.isEmpty, let session else { choices.levels = nil; return }
            let code = territory; levelId = ""
            await choices.loadLevels(territory: code) { try await session.productPricePoints(product: product, territory: code, account: account) }
        }
    }

    private func request() throws -> PublishRequest {
        var change = PurchasePriceChange(productId: purchaseId, territory: territory, pricePointId: levelId, startDate: priced ? start.pricingDay : nil)
        if strategy.strategy != .apple, let points = strategy.preview?.points {
            let anchor = strategy.anchor(base: territory)
            guard let point = points[anchor] else { throw PublishFailure.invalid("\(WorkspaceSession.countryName(anchor)) has no matching Apple price.") }
            change.territory = anchor; change.pricePointId = point
            let others = points.filter { $0.key != anchor }
            change.territoryPoints = others.isEmpty ? nil : others
        }
        var value = PublishRequest(accountId: account.id, appId: app.id, scope: .productPricing); value.purchasePrice = change
        return value
    }
}

/// The app's App Availability, as in App Store Connect's Pricing and Availability: every country or region, optionally with new ones
/// Apple adds. Apple accepts prices only where the app is available. Single countries, regions and pre-orders change later under App Information.
struct AppAvailabilityCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let state: PricingSetupState
    var done: () -> Void = {}
    @State private var future = true
    private var blocked: String? {
        switch state.appAvailable {
        case true?: return "App Store Connect already has the app's availability. Change single countries or regions under App Information → Availability."
        case nil: return "App Availability could not be read from App Store Connect. Refresh first."
        default: return nil
        }
    }

    var body: some View {
        PricingReviewCard(title: "App Availability", subtitle: "Make the app available in every country or region. Save opens a review; nothing is sent until you approve it.",
                          account: account, app: app, session: session, blocked: blocked, request: request, done: done) {
            StorebenchFact(label: "App Store Connect", value: state.appAvailable == true ? "Available" : state.appAvailable == false ? "Not set up" : "Unknown", done: state.appAvailable == true)
            StorebenchChoicePicker("New Countries or Regions", selection: $future, options: [(true, "Make available automatically"), (false, "Don't make available")],
                                   hint: "Whether the app becomes available in countries or regions Apple adds later.").storebenchWorking(state.appAvailable == true)
        }
    }

    private func request() throws -> PublishRequest {
        var change = PricingSetupChange(action: .appAvailability); change.allTerritories = future
        var value = PublishRequest(accountId: account.id, appId: app.id, scope: .pricingSetup); value.pricingSetup = change
        return value
    }
}
