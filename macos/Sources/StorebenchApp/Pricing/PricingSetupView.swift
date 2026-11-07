import StorebenchCore
import SwiftUI

/// Pricing: the pricing model, then its steps in App Store Connect's order and words, one at a time like Release, with Back and Next.
/// Every Apple change is prepared as a review below the card that prepared it, and sent only after approval.
struct PricingView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    /// App Store Connect's own page, such as Subscriptions: these steps' cards one below the other, under what is still needed. Nil shows the guide.
    var pages: [PricingFlow.StepId]? = nil
    @State private var setup: PricingSetupState?
    @State private var chosen: PricingModelKind?
    @State private var reading = false
    @State private var readAt: Date?
    @State private var problem = ""
    @State private var changing = false
    @State private var proposal: PricingModelKind = .free
    @State private var saving = false
    @State private var saveProblem = ""
    @State private var ticket = UUID()
    /// The open step; nil opens the first step App Store Connect still needs.
    @State private var step: PricingFlow.StepId?
    @Environment(\.pageScroll) private var pageScroll
    @Environment(\.navigationPresentation) private var presentation
    /// The window keeps each app's last pricing read under this key, so Pricing opens with it while App Store Connect is read again.
    static func readKey(accountId: String, appId: String) -> String { "pricing-setup/\(accountId)/\(appId)" }

    private var shown: PricingModelKind? { PricingSetup.shown(chosen: chosen, state: setup) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let pages { menuPage(pages) }
            else {
                header
                if let setup {
                    if let model = shown { flow(model, setup) } else { chooser }
                }
            }
        }
        .task(id: account.id + "/" + app.id) { await load() }
        .onChange(of: shown) { step = nil }
        .sheet(isPresented: $changing) { changeDialog }
    }

    // MARK: Header

    private var header: some View {
        Card(title: "Pricing Model", subtitle: "How the app earns money. Pricing shows the steps and settings for this model.", help: "model", actions: AnyView(StorebenchActionGroup {
            StorebenchReadButton("Refresh") { await load(fresh: true) }.storebenchWorking(session == nil)
            StorebenchCommand(title: "Change Pricing Model…", busy: false, unavailable: session == nil ? "Connect the workspace to read App Store Connect." : setup == nil ? "Read App Store Connect first." : nil, primary: false) {
                proposal = shown ?? .free; saveProblem = ""; changing = true
            }
        })) {
            StorebenchMetricGrid(maximumColumns: 4, minimumWidth: 180) {
                Fact(title: "Pricing Model", value: shown?.title ?? (setup == nil ? "Unknown" : "Not set up"), compact: true)
                Fact(title: "Price", value: setup?.appPrice.label ?? "Unknown", compact: true)
                Fact(title: "In-App Purchases", value: setup?.purchases.map { "\($0.count)" } ?? "Unknown", compact: true)
                Fact(title: "Subscriptions", value: setup?.subscriptions.map { "\($0.count)" } ?? "Unknown", compact: true)
            }
            StorebenchTextSlot(text: reading ? (setup == nil ? "Reading App Store Connect…" : "Checking App Store Connect for changes…") : session == nil ? "Connect the workspace to read pricing from App Store Connect." : shown.map { $0.summary + (chosen != nil ? " Chosen on this Mac." : " Read from App Store Connect.") } ?? (setup?.guideAvailable == true ? "Choose a pricing model below to set up pricing." : ""),
                               height: 36, font: .sbCallout, color: StorebenchTheme.muted, live: true)
            StorebenchReadAge(readAt: setup == nil ? nil : readAt, reading: false)
            if !problem.isEmpty { StorebenchAttention { Text(problem).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) } }
        }
    }

    private var changeDialog: some View {
        StorebenchDialog(title: "Change Pricing Model", height: 640, busy: saving, close: { changing = false }) {
            StorebenchChoicePicker("Pricing Model", selection: $proposal, options: PricingModelKind.allCases.map { ($0, $0.title) }, style: .radio)
            Text(proposal.summary).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchCardSection(title: "What Changes at Apple") {
                ForEach(PricingSetup.changes(from: shown, to: proposal, state: setup), id: \.self) { line in
                    Text(line).font(.sbCallout).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !saveProblem.isEmpty { StorebenchAttention { Text(saveProblem).fixedSize(horizontal: false, vertical: true) } }
        } actions: {
            StorebenchActionGroup {
                Button("Use Apple's Model") { Task { await choose(nil) } }.storebenchWorking(saving)
                    .disabled(!saving && chosen == nil).help(chosen == nil ? "Pricing already follows App Store Connect." : "Use the model App Store Connect's products and price show.")
                Button("Cancel") { changing = false }.storebenchWorking(saving)
                StorebenchCommand(title: "Use This Model", running: "Saving…", busy: saving, unavailable: proposal == shown && chosen != nil ? "This is the current pricing model." : nil) { Task { await choose(proposal) } }
            }
        }
    }

    // MARK: App Store Connect pages

    @ViewBuilder private func menuPage(_ pages: [PricingFlow.StepId]) -> some View {
        if let setup {
            let model = shown ?? (setup.appPrice.isPaid ? .paid : .free)
            StorebenchChecklist(rows: pages.map { .init(id: $0.rawValue, title: PricingFlow.title($0), done: PricingFlow.done($0, state: setup), optional: PricingFlow.optional.contains($0)) }, guide: .pricing)
            ForEach(pages, id: \.self) { id in content(id, model: model, setup: setup).id("pricing-page-\(id.rawValue)") }
        } else {
            Card(title: "Reading App Store Connect", subtitle: "", actions: AnyView(StorebenchReadButton("Refresh") { await load(fresh: true) }.storebenchWorking(session == nil))) {
                StorebenchTextSlot(text: problem.isEmpty ? (session == nil ? "Connect the workspace to read App Store Connect." : "Reading…") : problem, height: 36, font: .sbCallout, color: StorebenchTheme.muted, live: true)
            }
        }
    }

    // MARK: Steps

    @ViewBuilder private func flow(_ model: PricingModelKind, _ setup: PricingSetupState) -> some View {
        let steps = PricingFlow.steps(model, state: setup)
        let open = step.flatMap { id in steps.first { $0.id == id } } ?? steps.first { $0.id == PricingFlow.initial(model, state: setup) } ?? steps[0]
        StorebenchStepLayout {
            StorebenchStepRail(title: "\(model.title) steps", items: steps.map { .init(id: $0.id.rawValue, number: $0.number, title: $0.title, label: $0.status.label, complete: $0.status == .done, current: $0.status == .current) },
                               selected: open.id.rawValue, select: { go(PricingFlow.StepId(rawValue: $0)) })
            VStack(alignment: .leading, spacing: 20) {
                Card(title: "Step \(open.number) of \(steps.count): \(open.title)", subtitle: open.purpose, help: "model") {
                    StorebenchFact(label: "Status", value: open.status == .current ? "Needed" : open.status.label, done: open.status == .done)
                }.id("pricing-step-heading")
                content(open.id, model: model, setup: setup).id("pricing-step-\(open.id.rawValue)")
                navigation(open, steps: steps, model: model)
            }
        }
    }

    /// The step's card: one form with one command, named as in App Store Connect.
    @ViewBuilder private func content(_ id: PricingFlow.StepId, model: PricingModelKind, setup: PricingSetupState) -> some View {
        switch id {
        case .appAvailability: AppAvailabilityCard(account: account, app: app, session: session, state: setup, done: reload)
        case .subscriptionGroup: SubscriptionGroupStep(account: account, app: app, session: session, state: setup)
        case .subscriptions: SubscriptionsStep(account: account, app: app, session: session, state: setup, done: reload)
        case .subscriptionPrices: SubscriptionPricesCard(account: account, app: app, session: session, state: setup, done: reload)
        case .introductoryOffers: SubscriptionOffersCard(account: account, app: app, session: session, state: setup, title: "Introductory Offers", offered: [.introductoryOffer], done: reload)
        case .otherOffers:
            SubscriptionOffersCard(account: account, app: app, session: session, state: setup, title: PricingFlow.title(.otherOffers), offered: [.promotionalOffer, .offerCode, .winBackOffer], initial: .promotionalOffer, done: reload, introductory: { go(.introductoryOffers) })
        case .inAppPurchases: PurchasesCard(account: account, app: app, session: session, state: setup, done: reload)
        case .inAppPurchasePrices: PurchasePricesCard(account: account, app: app, session: session, state: setup, done: reload)
        case .priceSchedule:
            AppPriceCard(account: account, app: app, session: session, state: setup, model: model, done: reload)
            if model.paidApp || setup.appPrice.isPaid { CountryPriceStrategy(account: account, app: app, session: session, base: setup.appPrice.territory ?? "USA") }
        case .temporaryPrice: TemporaryPriceCard(account: account, app: app, session: session, state: setup, done: reload)
        case .status: ReviewRequirementsCard(account: account, app: app, session: session, state: setup, done: reload)
        }
    }

    /// Back and Next stay in place on every step; at either end the command is dimmed with the reason.
    private func navigation(_ open: PricingFlow.Step, steps: [PricingFlow.Step], model: PricingModelKind) -> some View {
        let (previous, next) = PricingFlow.neighbors(open.id, in: model)
        let name = { (id: PricingFlow.StepId) in steps.first { $0.id == id }.map { "step \($0.number): \($0.title)" } ?? "" }
        return StorebenchActionGroup(alignment: .trailing) {
            StorebenchCommand(title: "Back", busy: false, unavailable: previous == nil ? "This is the first step." : nil, primary: false) { go(previous) }
            if next == nil { StorebenchGuideExit(guide: .pricing) }
            else { StorebenchCommand(title: "Next", busy: false, unavailable: nil) { go(next) } }
        }.help(next.map { "Continue to " + name($0) } ?? "")
    }

    private func go(_ id: PricingFlow.StepId?) {
        guard let id else { return }
        if pages != nil { pageScroll?("pricing-page-\(id.rawValue)", .top); return }
        step = id
        pageScroll?("pricing-step-heading", .top)
    }

    /// No pricing model yet: each model in App Store Connect's words, chosen on this Mac. Nothing is sent to Apple.
    private var chooser: some View {
        Card(title: "Set Up Pricing", subtitle: "This app has no price, in-app purchases or subscriptions in App Store Connect yet. Choose how it earns money; Pricing then shows its steps. You can change it later with Change Pricing Model.", help: "model") {
            StorebenchCardList {
                ForEach(PricingModelKind.allCases) { kind in
                    StorebenchNavigationCard(title: kind.title, description: kind.summary, action: "Choose \(kind.title)", descriptionLines: 2, embedded: false, activate: { Task { await choose(kind) } }) {
                        StorebenchIcon(name: kind.sellsSubscriptions ? "sparkles" : kind.paidApp ? "sales" : "pricing", size: 20)
                    }.storebenchWorking(saving || session == nil)
                    if kind != PricingModelKind.allCases.last { StorebenchDivider() }
                }
            }
            if !saveProblem.isEmpty { StorebenchAttention { Text(saveProblem).fixedSize(horizontal: false, vertical: true) } }
        }
    }

    // MARK: Reads

    private func reload() { Task { await load() } }

    /// Saved pricing shows before Apple is read again. Each review still reads Apple itself.
    private func load(fresh: Bool = false) async {
        guard let session else { return }
        let key = Self.readKey(accountId: account.id, appId: app.id)
        if !fresh, setup == nil, let remembered = presentation?.rememberedRead(key, as: PricingSetupState.self) {
            setup = remembered; readAt = presentation?.rememberedReadAt(key); chosen = try? await session.chosenPricingModel(accountId: account.id, appId: app.id)
        }
        guard !Task.isCancelled else { return }
        let current = UUID(); ticket = current; reading = true
        defer { if ticket == current { reading = false } }
        do {
            let saved = try await session.chosenPricingModel(accountId: account.id, appId: app.id)
            let value = try await ScreenReads.reading(fresh: fresh) { try await session.pricingSetupState(account: account, appId: app.id, fresh: false) }
            guard ticket == current, !Task.isCancelled else { return }
            chosen = saved; if setup != value { setup = value }; readAt = Date()
            presentation?.rememberRead(value, key)
            problem = value.complete ? "" : (value.priceProblem.map { $0 + " " } ?? "") + (value.guideAvailable ? "The setup below reads Apple again before each review." : "App Store Connect did not return the app's complete pricing. What could be read is shown; refresh before changing prices.")
        } catch {
            guard ticket == current, !(error is CancellationError) else { return }
            problem = ProductPricing.readProblem(error, reading: "pricing") + (setup == nil ? "" : " The last pricing read is shown.")
        }
    }

    private func choose(_ model: PricingModelKind?) async {
        guard let session, !saving else { return }
        saving = true; defer { saving = false }
        do {
            try await session.choosePricingModel(model, accountId: account.id, appId: app.id)
            chosen = model; saveProblem = ""; changing = false
        } catch { saveProblem = (error as? PricingFailure)?.message ?? "The pricing model could not be saved on this Mac." }
    }
}

/// A paid app's prices in the other countries or regions, with the shared Price Strategy: Apple's comparable prices from the base price,
/// a built-in model such as Big Mac Index or World Bank purchasing power (PPP), prices entered manually, or a pricing profile. Previewed
/// prices are saved as Country Drafts; the country prices below review and send them.
struct CountryPriceStrategy: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    /// The app's Base Country or Region, the guide country of a built-in model.
    let base: String
    @State private var strategy = PriceStrategyModel()
    @State private var territories: [Territory] = []
    @State private var saving = false
    @State private var status = ""
    @State private var saved = 0

    var body: some View {
        Card(title: "Prices by Country or Region", subtitle: "How the app's price is set in each country or region. Previewed prices are saved as Country Drafts; the country prices below review and send them.") {
            PricingStrategyPicker(selection: Binding(get: { strategy.strategy }, set: { strategy.strategy = $0; status = "" }), profiles: strategy.profiles).storebenchFormColumn()
            PriceStrategyFields(model: strategy, owner: .app(app.id), base: base, territories: territories, account: account, session: session, extra: AnyView(
                StorebenchCommand(title: "Save as Country Drafts", running: "Saving…", busy: saving, unavailable: strategy.preview?.points.isEmpty == false ? nil : "Preview Prices first.", primary: strategy.preview != nil) { Task { await saveDrafts() } }
            ))
            StorebenchTextSlot(text: status, height: 36, font: .sbCallout, color: StorebenchTheme.muted, live: true)
        }
        .task {
            await strategy.loadProfiles(session)
            if let session, territories.isEmpty { territories = (try? await session.territories(account: account)) ?? [] }
        }
        if strategy.strategy != .apple { CountryPricesView(account: account, app: app, session: session).id("country-prices-\(saved)") }
    }

    /// Saves each previewed price as a Country Draft on this Mac. Nothing is sent to Apple until the country prices below are reviewed and approved.
    private func saveDrafts() async {
        guard let session, let preview = strategy.preview, !saving else { return }
        saving = true; defer { saving = false }
        let amounts = preview.rows.compactMap { row in row.amount.flatMap { amount in preview.points[row.territory] == nil ? nil : (territory: row.territory, currency: row.currency, amount: amount) } }
        do {
            _ = try await session.saveCountryDrafts(accountId: account.id, appId: app.id, amounts: amounts, startDate: nil, endDate: nil)
            saved += 1; status = "Saved \(amounts.count) Country Drafts. Review and send them in the country prices below."
        } catch let failure as PricingFailure { status = failure.message }
        catch { status = "The Country Drafts could not be saved." }
    }
}
