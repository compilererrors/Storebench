import StorebenchCore
import SwiftUI

/// What Apple still needs for the price and each product before they can be submitted: what Apple reports now, with the fix in
/// Storebench or, where Apple's API cannot set it, the exact place in App Store Connect. App Privacy and Tax Category belong to
/// Release and App Store changes, not here.
struct ReviewRequirementsCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let state: PricingSetupState
    var done: () -> Void = {}
    @State private var check: ProductReadinessCheck?
    @State private var limit = ProductReadinessCheck.batch
    /// The app price read by Check Again, shown until the page's own pricing read changes.
    @State private var checkedPrice: AppPriceState?
    @State private var reading = false
    @State private var problem = ""
    @State private var selected: String?
    @State private var ticket = UUID()
    private static let connect = URL(string: "https://appstoreconnect.apple.com/apps")!
    private var sellsProducts: Bool { state.purchases?.isEmpty == false || state.subscriptions?.isEmpty == false }
    private var price: AppPriceState { checkedPrice ?? state.appPrice }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Price and Product Status", subtitle: "What Apple still needs for the price and each product before they can be submitted. Storebench sets what Apple's API allows; the rest opens where App Store Connect asks for it.",
                 help: "model", actions: AnyView(StorebenchReadButton("Check Again") { await load(fresh: true) }.storebenchWorking(session == nil))) {
                StorebenchStatusList {
                    row("Price", detail: price == .none ? "No price is set. Choose Free or a price in Price below." : price == .unknown ? "Apple's price could not be read." : "Apple has the price \(price.label).",
                        status: price == .unknown ? nil : price != .none) { EmptyView() }
                    ForEach(check?.products ?? []) { item in
                        row("\(item.product.name) · \(item.product.kind == .subscription ? "Subscription" : "In-App Purchase")",
                            detail: item.unread ? "Could not be read from App Store Connect in this check. Check Again tries again." : item.ready ? "Ready to Submit." : "Missing: " + item.missing.joined(separator: ", ") + ".",
                            status: item.uncertain ? nil : item.ready) {
                            StorebenchCommand(title: "Complete", busy: false, unavailable: item.unread ? "Check Again reads this product first." : item.missing.contains(where: { !["Review Screenshot", "Price"].contains($0) }) ? nil : "Storebench has set everything it can for this product.", primary: false) { selected = item.id }
                        }
                    }
                    ForEach(check?.unread ?? [], id: \.self) { kind in
                        row(ProductReadinessCheck.family(kind), detail: "\(ProductReadinessCheck.family(kind)) could not be read from App Store Connect, so they are not checked. Check Again tries again.", status: nil) { EmptyView() }
                    }
                    if let unchecked = check?.unchecked, !unchecked.isEmpty {
                        row("\(unchecked.count) More \(unchecked.count == 1 ? "Product" : "Products")", detail: "Not checked yet: " + unchecked.prefix(5).map(\.name).joined(separator: ", ") + (unchecked.count > 5 ? " and \(unchecked.count - 5) more." : "."), status: nil) {
                            StorebenchCommand(title: "Check More", running: "Checking…", busy: reading, unavailable: session == nil ? "Connect the workspace to read App Store Connect." : nil, primary: false) {
                                limit += ProductReadinessCheck.batch; Task { await load() }
                            }.help("Checks the next \(min(unchecked.count, ProductReadinessCheck.batch)) products")
                        }
                    }
                    if sellsProducts && check == nil {
                        row("In-App Purchases and Subscriptions", detail: reading ? "Reading what each product still needs…" : "Not read yet. Check Again reads each product's requirements.", status: nil) { EmptyView() }
                    }
                    if price.isPaid || sellsProducts {
                        manual("Paid Apps Agreement", "Selling the app or products needs an active Paid Apps Agreement with tax and banking information. Check it in App Store Connect under Business.")
                    }
                    if sellsProducts {
                        manual("Review Screenshot", "Upload each product's review screenshot in App Store Connect under Monetization, on the product's page under Review Information.")
                        manual("First Products with the App Version", "Your first in-app purchase and first subscription go to App Review with an app version. In App Store Connect, open the version and select them under In-App Purchases and Subscriptions before Add for Review.", separator: false)
                    }
                }
                StorebenchTextSlot(text: reading ? "Checking each product at App Store Connect…" : "", height: 20, font: .sbCaption, color: StorebenchTheme.muted, live: true)
                if !problem.isEmpty { StorebenchAttention { Text(problem).fixedSize(horizontal: false, vertical: true) } }
            }
            if let selected, let item = check?.products.first(where: { $0.id == selected }) {
                ProductInformationCard(account: account, app: app, session: session, readiness: item, done: { Task { await load(); done() } })
                    .id(item.id)
            }
        }
        .task(id: "\(state.purchases?.count ?? -1)/\(state.subscriptions?.count ?? -1)") { if sellsProducts { await load() } else { check = ProductReadinessCheck(products: []) } }
        .onChange(of: state.appPrice) { checkedPrice = nil }
    }

    private func row<Action: View>(_ title: String, detail: String, status: Bool?, @ViewBuilder action: () -> Action) -> some View {
        let command = action()
        return StorebenchStatusRow(title: title, detail: detail) {
            StorebenchFact(label: "Status", value: status == nil ? "Unknown" : status! ? "Done" : "Needed", problem: status == false, done: status == true)
        } action: { command } details: { EmptyView() }
    }

    private func manual(_ title: String, _ detail: String, separator: Bool = true) -> some View {
        StorebenchStatusRow(title: title, detail: detail, separator: separator) {
            StorebenchFact(label: "Status", value: "Check in App Store Connect")
        } action: {
            StorebenchActionLink("App Store Connect", destination: Self.connect, help: "Open \(title) in App Store Connect")
        } details: { EmptyView() }
    }

    /// The products' requirements and, when `fresh`, the app price too, so Check Again rereads everything the card shows.
    private func load(fresh: Bool = false) async {
        await ScreenReads.reading(fresh: fresh) {
            guard let session else { return }
            let current = UUID(); ticket = current; reading = true
            defer { if ticket == current { reading = false } }
            async let priceRead = fresh ? Self.appPrice(session, account: account, appId: app.id) : nil
            let products: Result<ProductReadinessCheck, Error>
            do { products = .success(try await session.productReadiness(account: account, appId: app.id, fresh: false, limit: limit)) } catch { products = .failure(error) }
            let read = await priceRead
            guard ticket == current else { return }
            if let read { checkedPrice = read }
            switch products {
            case .success(let value): check = value.keeping(check); problem = ""
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                problem = (error as? PublishFailure)?.message ?? "The products' requirements could not be read from App Store Connect. Check Again tries again."
            }
            if fresh { done() }
        }
    }

    /// The app price as Apple reports it now; unknown when it could not be read.
    private nonisolated static func appPrice(_ session: WorkspaceSession, account: Account, appId: String) async -> AppPriceState? {
        do { return try await session.pricingSetupState(account: account, appId: appId, fresh: false).appPrice }
        catch is CancellationError { return nil }
        catch { return .unknown }
    }
}

/// One product's display name, description, Subscription Group display name and availability, prepared as one review.
struct ProductInformationCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let readiness: ProductReadiness
    var done: () -> Void = {}
    @State private var locale = "en-US"
    @State private var name = ""
    @State private var details = ""
    @State private var groupName = ""
    @State private var everywhere = true
    private var subscription: Bool { readiness.product.kind == .subscription }
    private var needsAvailability: Bool { readiness.available != true }
    private var blocked: String? {
        if PricingSetupChange.displayText(name, limit: PricingSetupChange.displayNameLimit) == nil { return "Enter a display name of up to 35 characters." }
        if PricingSetupChange.displayText(details, limit: PricingSetupChange.descriptionLimit) == nil { return "Enter a description of up to 55 characters." }
        if subscription, readiness.groupLocales?.isEmpty != false, PricingSetupChange.displayText(groupName, limit: PricingSetupChange.groupNameLimit) == nil { return "Enter the Subscription Group display name." }
        return nil
    }

    var body: some View {
        PricingReviewCard(title: "Product Information · \(readiness.product.name)", subtitle: "What customers and App Review see for this product, and where it is sold.",
                          account: account, app: app, session: session, blocked: blocked, request: request, done: done, followUp: followUp) {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                StorebenchSearchPicker("Language", selection: $locale) { selectionOptions(StoreLocales.codes) { SelectionOption(StoreLocales.name($0), value: $0) } }
                Toggle("Available in all countries and regions", isOn: $everywhere).disabled(!needsAvailability)
                    .help(needsAvailability ? "Apple sells the product wherever the app is available, including new countries and regions." : "Apple already has this product's availability.")
                StorebenchTextField("Display Name", text: $name, hint: "Up to 35 characters, shown on the App Store.")
                StorebenchTextField("Description", text: $details, hint: "Up to 55 characters, shown on the App Store.")
                StorebenchTextField("Subscription Group Display Name", text: $groupName, hint: subscription ? "Shown to subscribers, such as Premium." : "Only for subscriptions.").disabled(!subscription)
            }
            Text("The review screenshot is uploaded in App Store Connect on the product's page under Review Information.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if name.isEmpty { name = readiness.product.name } }
    }

    private func request() throws -> PublishRequest {
        var change = PricingSetupChange(action: .productInformation)
        change.itemId = readiness.product.id; change.itemKind = subscription ? "subscription" : "purchase"; change.locale = locale; change.displayName = name; change.details = details
        if subscription, !groupName.isEmpty { change.groupDisplayName = groupName }
        if needsAvailability, everywhere { change.allTerritories = true }
        var value = PublishRequest(accountId: account.id, appId: app.id, scope: .pricingSetup); value.pricingSetup = change
        return value
    }

    /// After a review, the same text follows as its own review until Apple's newest versions have it, such as when the first review
    /// only started a draft version that copied the earlier text. An answer that cannot be read is not taken as done.
    private func followUp() async throws -> PublishRequest? {
        guard let session else { return nil }
        var value = try request(); value.pricingSetup?.allTerritories = nil
        guard let change = value.pricingSetup else { return nil }
        let matches = (try? await session.productInformationMatches(account: account, appId: app.id, change: change)) ?? false
        return matches ? nil : value
    }
}
