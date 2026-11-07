import StorebenchCore
import SwiftUI

/// How prices are set in each country or region: Apple's comparable prices, a built-in pricing method, a saved pricing profile, or
/// typed prices. Names and explanations come from the shared catalog in `PricingMethod` and `PricingStrategyText`.
enum PriceStrategy: Hashable {
    case apple, model(PricingMethod), profile(String), manual
    var key: String {
        switch self { case .apple: "apple"; case .model(let method): "model:" + method.rawValue; case .profile(let id): "profile:" + id; case .manual: "manual" }
    }
    var savedProfile: Bool { if case .profile = self { true } else { false } }
    /// The model to apply: a saved profile as it is, a built-in method with the Base Country or Region as its guide country.
    func profile(saved: [PricingProfile], base: String) -> PricingProfile? {
        switch self {
        case .profile(let id): return saved.first { $0.id == id }
        case .model(let method) where !base.isEmpty:
            return PricingProfile(id: "built-in-\(method.rawValue)", name: method.name, guideTerritory: base, rounding: PricingRounding.nearest.rawValue, method: method.rawValue, percentages: [:])
        default: return nil
        }
    }
    func explanation(saved: [PricingProfile]) -> String {
        switch self {
        case .apple: return PricingStrategyText.appleExplanation
        case .model(let method): return method.explanation
        case .profile(let id):
            return saved.first { $0.id == id }.map { "Your profile \($0.name), from Settings → Pricing: " + $0.summary } ?? "A pricing profile from Settings → Pricing."
        case .manual: return PricingStrategyText.manualExplanation
        }
    }
    /// Every strategy explained, for the (i) popover.
    static var guide: String {
        (["\(PricingStrategyText.appleName): " + PricingStrategyText.appleExplanation]
         + PricingMethod.builtIn.map { "\($0.name): " + $0.explanation }
         + ["Your pricing profiles: your own recipes from Settings → Pricing. Each has a guide country, rounding and any method, including \(PricingMethod.custom.name) and \(PricingMethod.own.name), and can mix in a second method, adjust countries by percentage and keep prices between a lowest and highest price.",
            "\(PricingStrategyText.manualName): " + PricingStrategyText.manualExplanation + " A CSV file can fill them in.",
            "Every strategy but Apple's comparable prices is previewed per country before anything is sent, and countries without a matching Apple price keep what Apple has."])
            .joined(separator: "\n\n")
    }
}

/// Price Strategy: Apple's comparable prices, a built-in model, a pricing profile or typed prices. The selected strategy's explanation
/// is shown beneath it, and the (i) button explains every strategy.
struct PricingStrategyPicker: View {
    @Binding var selection: PriceStrategy
    let profiles: [PricingProfile]
    var body: some View {
        HStack(alignment: .top, spacing: StorebenchTheme.space(1)) {
            StorebenchPicker("Price Strategy", selection: $selection, hint: selection.explanation(saved: profiles)) {
                SelectionOption(PricingStrategyText.appleName, value: PriceStrategy.apple).help(PricingStrategyText.appleExplanation)
                selectionOptions(PricingMethod.builtIn) { SelectionOption($0.name, value: PriceStrategy.model($0)).help($0.explanation) }
                SelectionOption(PricingStrategyText.manualName, value: PriceStrategy.manual).help(PricingStrategyText.manualExplanation)
                selectionOptions(profiles) { item in
                    SelectionOption("Profile: \(item.name) · \(PricingMethod.name(item.method))", value: PriceStrategy.profile(item.id)).help(PriceStrategy.profile(item.id).explanation(saved: profiles))
                }
            }
            StorebenchInfoTip(title: "Price Strategy", text: PriceStrategy.guide).padding(.top, 22)
        }
    }
}

/// The one Price Strategy every price form shares: which strategy, the guide price or typed prices, and the per-country preview.
/// The same engine prices the app, subscriptions and in-app purchases, each rounded to its own Apple prices.
@MainActor @Observable final class PriceStrategyModel {
    var strategy = PriceStrategy.apple { didSet { if strategy != oldValue { invalidate() } } }
    var profiles: [PricingProfile] = [] { didSet { if profiles != oldValue { invalidate() } } }
    var guide = "" { didSet { if guide != oldValue { invalidate() } } }
    var typed: [String: String] = [:] { didSet { if typed != oldValue { invalidate() } } }
    private(set) var preview: (rows: [ModelPrice], warnings: [String], points: [String: String])?
    private(set) var previewing = false
    private(set) var problem = ""
    /// The inputs a calculation started from: any change to the strategy, profiles, prices, product or country makes a new generation,
    /// so an answer that arrives later can neither bring back an old preview nor replace the current feedback.
    struct Ticket: Equatable { let generation: Int, owner: PriceOwner, base: String }
    private var generation = 0
    /// The inputs the shown preview was calculated for.
    private(set) var previewed: Ticket?
    func ticket(_ owner: PriceOwner, base: String) -> Ticket { Ticket(generation: generation, owner: owner, base: base) }
    func current(_ ticket: Ticket) -> Bool { ticket.generation == generation }

    /// A model applied to a guide price: a saved profile, or a built-in model with `base` as its guide country.
    func model(base: String) -> PricingProfile? { strategy.profile(saved: profiles, base: base) }
    /// The country whose price anchors the change: a saved profile's guide country, else `base`.
    func anchor(base: String) -> String { model(base: base)?.guideTerritory ?? base }
    func invalidate() { generation += 1; preview = nil; previewed = nil; problem = "" }

    func loadProfiles(_ session: WorkspaceSession?) async { profiles = (try? await session?.pricingProfiles().profiles) ?? profiles }

    /// Why Preview Prices cannot run; nil when it can. Apple's comparable prices need no preview.
    func previewUnavailable(base: String, territories: [Territory]) -> String? {
        if strategy == .apple { return "Apple's comparable prices need no preview." }
        if territories.isEmpty { return "Apple's countries and regions are not read yet." }
        if strategy == .manual { return typed.values.contains { PricingMath.decimal($0).map { $0 > 0 } == true } ? nil : "Enter a price for at least one country or region." }
        if anchor(base: base).isEmpty { return "Choose the Base Country or Region." }
        return PricingMath.decimal(guide).map { $0 > 0 } == true ? nil : "Enter a guide price above zero."
    }

    /// Why the previewed prices cannot be used yet; nil once the anchor country has a matching Apple price.
    func blocked(base: String) -> String? {
        if previewing { return "Calculating the prices…" }
        guard let preview, previewed?.base == base else { return strategy == .manual ? "Enter the prices, then Preview Prices." : "Enter the guide price, then Preview Prices." }
        let anchor = anchor(base: base)
        if preview.points[anchor] == nil { return "\(WorkspaceSession.countryName(anchor)) has no matching Apple price. " + (strategy == .manual ? "Enter its price." : "Change the guide price.") }
        return nil
    }

    func calculate(_ owner: PriceOwner, base: String, territories: [Territory], account: Account, session: WorkspaceSession?) async {
        guard let session, !previewing else { return }
        previewing = true; defer { previewing = false }
        let ticket = ticket(owner, base: base), strategy = strategy, typed = typed, guide = guide, model = model(base: base)
        do {
            let value: (rows: [ModelPrice], warnings: [String], points: [String: String])?
            if strategy == .manual { value = try await session.manualPrices(owner, amounts: typed, countries: territories, account: account) }
            else if let model {
                let currency = territories.first { $0.code == model.guideTerritory }?.currency ?? ""
                value = try await session.modelPrices(owner, profile: model.validated(), base: guide, countries: territories, guideCurrency: currency, account: account)
            } else { value = nil }
            accept(value, for: ticket)
        } catch let failure as PricingFailure { if current(ticket) { problem = failure.message } }
        catch is CancellationError {}
        catch { if current(ticket) { problem = "The prices could not be calculated. Check the prices and try again." } }
    }

    /// Shows a calculated preview only when it belongs to the inputs shown now.
    func accept(_ value: (rows: [ModelPrice], warnings: [String], points: [String: String])?, for ticket: Ticket) {
        guard current(ticket) else { return }
        preview = value; previewed = value == nil ? nil : ticket; problem = ""
    }
}

/// The fields of a model or manual Price Strategy: the guide price or a price per country, Preview Prices, and every country's
/// previewed price. Apple's comparable prices show nothing here; their own form sets the one base price.
struct PriceStrategyFields: View {
    let model: PriceStrategyModel
    let owner: PriceOwner?
    let base: String
    let territories: [Territory]
    let account: Account, session: WorkspaceSession?
    /// Commands placed beside Preview Prices, such as Save as Country Drafts.
    var extra: AnyView? = nil
    private var currency: String { territories.first { $0.code == model.anchor(base: base) }?.currency ?? "" }

    var body: some View {
        StorebenchCardSection(title: "Prices from a CSV File", description: model.strategy == .manual
                              ? "Fill in your prices from a CSV file. Rows replace what is typed for those countries or regions."
                              : "Importing a CSV file switches to \(PricingStrategyText.manualName) and fills in its prices. Nothing is sent until you review it.") {
            PricingCSVButtons(kind: .prices, territories: territories) { values in model.strategy = .manual; model.typed.merge(values) { _, imported in imported } }
        }
        if model.strategy != .apple {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                if model.strategy == .manual { StorebenchFact(label: "Prices", value: "Entered below for each country or region") }
                else {
                    StorebenchTextField("Guide Price in \(WorkspaceSession.countryName(model.anchor(base: base)))\(currency.isEmpty ? "" : " (\(currency))")", text: Binding(get: { model.guide }, set: { model.guide = $0 }),
                                        hint: "The price the model starts from, such as 4.99.")
                        .storebenchNeeded(owner != nil && PricingMath.decimal(model.guide).map { $0 > 0 } != true ? "Enter the guide price." : nil)
                }
                StorebenchFieldCommands {
                    let unavailable = owner == nil ? "Choose what to price first." : model.previewUnavailable(base: base, territories: territories)
                    StorebenchCommand(title: "Preview Prices", running: "Calculating…", busy: model.previewing, unavailable: unavailable, primary: model.preview == nil && unavailable == nil) {
                        guard let owner else { return }
                        Task { await model.calculate(owner, base: base, territories: territories, account: account, session: session) }
                    }
                    if let extra { extra }
                }
            }
            if model.strategy == .manual {
                StorebenchCardSection(title: "Your Prices", description: "Enter the price in each country's own currency. Each is rounded to the nearest Apple price there; empty countries or regions keep their price.") {
                    StorebenchMetricGrid(maximumColumns: 3, minimumWidth: 200) {
                        ForEach(territories) { country in
                            StorebenchTextField("\(country.name) (\(country.currency))", text: Binding(get: { model.typed[country.code] ?? "" }, set: { model.typed[country.code] = $0.isEmpty ? nil : $0 }))
                        }
                    }
                }
            }
            StorebenchCardSection(title: "Prices by Country or Region", description: model.preview.map { "\($0.points.count) of \($0.rows.count) countries or regions have a matching Apple price; the others keep what Apple has." + ($0.warnings.isEmpty ? "" : " " + $0.warnings.joined(separator: " ")) }
                                  ?? (model.problem.isEmpty ? "Preview Prices shows each country's price, rounded to Apple's prices, before anything is sent." : model.problem)) {
                ForEach(model.preview?.rows ?? []) { row in
                    StorebenchFact(label: WorkspaceSession.countryName(row.territory), value: row.amount.map { "\($0) \(row.currency)" } ?? (row.problem ?? "No price"), problem: model.preview?.points[row.territory] == nil)
                }
            }
        }
    }
}
