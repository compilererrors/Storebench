import StorebenchCore
import SwiftUI

/// A subscription offer in App Store Connect's words, set up under one subscription: an Introductory Offer (Free Trial, Pay As You Go or
/// Pay Up Front), a Promotional Offer, an Offer Code or a Win-Back Offer.
struct SubscriptionOffersCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let state: PricingSetupState
    var title = "Offers"
    /// The kinds of offer this card sets up; the choice is shown only when there is more than one.
    var offered: [PricingSetupChange.Action] = [.introductoryOffer, .promotionalOffer, .offerCode, .winBackOffer]
    var initial: PricingSetupChange.Action = .introductoryOffer
    var done: () -> Void = {}
    /// Opens the Introductory Offers step, where a free trial for new subscribers is set up.
    var introductory: (() -> Void)? = nil
    @State private var choices = PricingChoices()
    @State private var kind: PricingSetupChange.Action = .introductoryOffer
    @State private var subscriptionId = ""
    @State private var mode = "FREE_TRIAL"
    @State private var duration = "ONE_WEEK"
    @State private var periods = 1
    @State private var everywhere = true
    @State private var territory = ""
    @State private var levelId = ""
    @State private var name = ""
    @State private var identifier = ""
    /// The identifier follows the Reference Name until it is typed in.
    @State private var identifierTyped = false
    @State private var eligible: Set<String> = ["NEW"]
    @State private var stacking = "STACK_WITH_INTRO_OFFERS"
    @State private var dated = false
    @State private var start = Date().addingTimeInterval(86_400)
    @State private var ends = false
    @State private var end = Date().addingTimeInterval(31 * 86_400)
    @State private var paidMonths = 3
    @State private var lapsedMinimum = 1
    @State private var lapsedMaximum = 6
    @State private var waits = false
    @State private var waitMonths = 3
    @State private var priority = "NORMAL"
    @State private var applied = false

    private static let kinds: [(PricingSetupChange.Action, String)] = [(.introductoryOffer, "Introductory Offer"), (.promotionalOffer, "Promotional Offer"), (.offerCode, "Offer Code"), (.winBackOffer, "Win-Back Offer")]
    private var product: PriceProduct? { state.subscriptions?.first { $0.id == subscriptionId } }
    private var free: Bool { mode == "FREE_TRIAL" }
    private var named: Bool { kind != .introductoryOffer }
    private var identified: Bool { kind == .promotionalOffer || kind == .winBackOffer }
    private var startsLater: Bool { kind == .winBackOffer || dated }
    private var blocked: String? {
        guard product != nil else { return state.subscriptions?.isEmpty == true ? "Create a subscription first." : "Choose a subscription." }
        if territory.isEmpty { return "Choose a country or region." }
        if !free {
            if let reason = choices.levelsBlocked(territory) { return reason }
            if levelId.isEmpty { return "Choose the offer price." }
        }
        if named, PricingSetupChange.referenceName(name) == nil { return "Enter a Reference Name of up to 64 characters." }
        if identified, !PricingSetupChange.validOfferId(identifier) { return "Enter the \(identifierTitle): letters, numbers, hyphens, underscores or periods, without spaces." }
        if kind == .offerCode, eligible.isEmpty { return "Choose who is eligible." }
        if kind == .winBackOffer, lapsedMinimum > lapsedMaximum { return "The shortest time since the last subscription must not exceed the longest." }
        if startsLater, start.pricingDay < ReportDay.today { return "Choose today or a later start date." }
        if ends, kind == .introductoryOffer || kind == .winBackOffer, end.pricingDay < (startsLater ? start.pricingDay : ReportDay.today) { return "The end date must be on or after the start date." }
        return nil
    }

    var body: some View {
        PricingReviewCard(title: title, subtitle: offered == [.introductoryOffer] ? "A Free Trial, Pay As You Go or Pay Up Front offer for new subscribers of the chosen subscription, in every country or region you choose."
                          : "Promotional Offers for current and former subscribers, Offer Codes to share, and Win-Back Offers for people who stopped, each set up under one subscription.",
                          command: "Save", account: account, app: app, session: session, blocked: blocked, request: request, done: { name = ""; identifier = ""; identifierTyped = false; done() }) {
            if let introductory {
                StorebenchNotice(title: "Looking for a free trial?", description: "A free trial that new subscribers see in the App Store is an Introductory Offer. Promotional Offers only appear when your app's code offers them.", icon: "info") {
                    Button("Introductory Offers") { introductory() }.help("Open the Introductory Offers step to set up a free trial.")
                }
            }
            StorebenchPicker("Subscription", selection: $subscriptionId, hint: "Offers are set up under each subscription, as in App Store Connect.") {
                SelectionOption("Choose a subscription", value: "")
                selectionOptions(state.subscriptions ?? []) { SelectionOption("\($0.name) · \($0.group ?? "")", value: $0.id) }
            }.storebenchNeeded(product == nil ? (state.subscriptions?.isEmpty == true ? "Create a subscription in Subscriptions first." : "Choose the subscription for this offer first.") : nil)
            if offered.count > 1 { StorebenchChoicePicker("Offer", selection: $kind, options: Self.kinds.filter { offered.contains($0.0) }) }
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                StorebenchPicker(kind == .introductoryOffer ? "Introductory Offer" : "Type", selection: $mode) { selectionOptions(PricingSetupChange.offerModes) { SelectionOption($0.1, value: $0.0) } }
                StorebenchPicker("Duration", selection: $duration) { selectionOptions(PricingSetupChange.offerDurations) { SelectionOption($0.1, value: $0.0) } }
                StorebenchStepper("Number of Periods: \(periods)", value: $periods, in: 1...12).disabled(mode != "PAY_AS_YOU_GO")
                StorebenchChoicePicker("Countries or Regions", selection: $everywhere, options: [(true, "All Countries or Regions"), (false, "One Country or Region")])
                PricingCountryPicker(title: everywhere ? "Price Based On" : "Country or Region", territories: choices.territories, selection: $territory)
                PricingLevelPicker(title: "Offer Price", levels: free ? [] : choices.levels, selection: $levelId, includeFree: false,
                                   reason: free ? "A Free Trial has no price." : product == nil ? "Choose a subscription first. Apple's prices are read for each subscription." : choices.levelsBlocked(territory)).disabled(free || product == nil)
                    .storebenchNeeded(!free && product != nil && choices.levels != nil && levelId.isEmpty ? "Choose the offer price." : nil)
                StorebenchTextField("Reference Name", text: Binding(get: { name }, set: { name = $0; if !identifierTyped { identifier = Self.offerId(from: $0) } }), hint: "Shown only in App Store Connect.").disabled(!named)
                StorebenchTextField(identifierTitle, text: Binding(get: { identifier }, set: { identifier = Self.offerId(from: $0); identifierTyped = !$0.isEmpty }),
                                    hint: "Filled in from the Reference Name. Spaces become hyphens.").disabled(!identified)
            }
            if kind == .offerCode { offerCodeFields }
            if kind == .winBackOffer { winBackFields }
            if kind == .introductoryOffer || kind == .winBackOffer { datesFields }
            Text(explanation).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if !applied { kind = offered.contains(initial) ? initial : offered.first ?? .introductoryOffer; applied = true } }
        .task { await choices.loadTerritories(account: account, session: session); if territory.isEmpty { territory = choices.territories.contains { $0.code == "USA" } ? "USA" : choices.territories.first?.code ?? "" } }
        // Follows the subscriptions App Store Connect has, also when they arrive after this step opened: the first one is chosen.
        .task(id: state.subscriptions?.map(\.id) ?? []) { if product == nil { subscriptionId = state.subscriptions?.first?.id ?? "" } }
        .task(id: "\(subscriptionId)/\(territory)/\(free)") {
            guard !free, let product, !territory.isEmpty, let session else { choices.levels = nil; return }
            let code = territory; levelId = ""
            await choices.loadLevels(territory: code) { try await session.productPricePoints(product: product, territory: code, account: account) }
        }
        .onChange(of: mode) { if mode != "PAY_AS_YOU_GO" { periods = 1 } }
    }

    private var offerCodeFields: some View {
        StorebenchCardSection(title: "Customer Eligibility") {
            StorebenchFlow(spacing: 16) {
                ForEach(PricingSetupChange.eligibilities, id: \.0) { code, label in
                    HStack(spacing: 4) {
                        StorebenchCheckbox(label, isOn: Binding(get: { eligible.contains(code) }, set: { if $0 { eligible.insert(code) } else { eligible.remove(code) } }))
                        Text(label).font(.sbCallout)
                    }
                }
            }
            StorebenchPicker("Introductory Offer Eligibility", selection: $stacking) { selectionOptions(PricingSetupChange.stackings) { SelectionOption($0.1, value: $0.0) } }
        }
    }

    private var winBackFields: some View {
        StorebenchCardSection(title: "Customer Eligibility") {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                StorebenchStepper("Paid Subscription Duration: \(paidMonths) months", value: $paidMonths, in: 1...24)
                StorebenchStepper("Time Since Last Subscribed, from: \(lapsedMinimum) months", value: $lapsedMinimum, in: 1...24)
                StorebenchStepper("Time Since Last Subscribed, to: \(lapsedMaximum) months", value: $lapsedMaximum, in: 1...24)
                StorebenchStepper("Wait Between Offers: \(waitMonths) months", value: $waitMonths, in: 1...24).disabled(!waits)
                Toggle("Wait between offers", isOn: $waits)
                StorebenchPicker("Priority", selection: $priority) { selectionOptions(PricingSetupChange.priorities) { SelectionOption($0.1, value: $0.0) } }
            }
        }
    }

    private var identifierTitle: String { kind == .winBackOffer ? "Offer ID" : "Promotional Offer Identifier" }

    /// Apple's offer identifier from free text: spaces become hyphens and other characters are left out.
    static func offerId(from text: String) -> String {
        let joined = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).joined(separator: "-")
        return String(String(joined.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }).prefix(64))
    }

    /// Introductory and Win-Back Offers have dates; Promotional Offers and Offer Codes have none.
    private var datesFields: some View {
        StorebenchCardSection(title: "Start and End Dates") {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                Toggle("Set a start date", isOn: Binding(get: { startsLater }, set: { dated = $0 })).disabled(kind != .introductoryOffer)
                Toggle("Set an end date", isOn: $ends)
                StorebenchDateField("Start Date", selection: $start, displayedComponents: .date).disabled(!startsLater)
                StorebenchDateField("End Date", selection: $end, displayedComponents: .date).disabled(!ends)
            }
        }
    }

    private var explanation: String {
        switch kind {
        case .introductoryOffer: "New subscribers get this once per Subscription Group. Countries or regions that already have an introductory offer are left as they are."
        case .promotionalOffer: "Apple does not show Promotional Offers by itself. After saving, your app's code offers it to current or former subscribers using the Promotional Offer Identifier."
        case .offerCode: "After the review is sent, create one-time use codes or a custom code for this offer in App Store Connect under Monetization → Subscriptions → Offer Codes."
        default: "Apple shows the offer to people who subscribed for the paid duration and stopped within the time range. A start date is required."
        }
    }

    private func request() throws -> PublishRequest {
        var change = PricingSetupChange(action: kind)
        change.subscriptionId = subscriptionId; change.offerMode = mode; change.duration = duration; change.periods = mode == "PAY_AS_YOU_GO" ? periods : 1
        change.allTerritories = everywhere; change.territory = territory; change.pricePointId = free ? nil : levelId
        if named { change.name = name }
        if identified { change.offerId = identifier }
        if kind == .introductoryOffer || kind == .winBackOffer {
            if startsLater { change.startDate = start.pricingDay }
            if ends { change.endDate = end.pricingDay }
        }
        if kind == .offerCode { change.eligibilities = PricingSetupChange.eligibilities.map(\.0).filter(eligible.contains); change.stacking = stacking }
        if kind == .winBackOffer {
            change.paidMonths = paidMonths; change.lapsedMinimum = lapsedMinimum; change.lapsedMaximum = lapsedMaximum; change.priority = priority
            if waits { change.waitMonths = waitMonths }
        }
        var value = PublishRequest(accountId: account.id, appId: app.id, scope: .pricingSetup); value.pricingSetup = change
        return value
    }
}
