import StorebenchCore
import SwiftUI

/// Four-step review of local reductions; Apple changes still use App Store changes.
struct NoSalesGuideView: View {
    let account: Account, app: Account.App, session: WorkspaceSession, profileId: String
    var initialMethod: PricingMethod? = nil
    let blocked: Bool, sourceVersion: Int
    let onClose: () -> Void, onSaved: () -> Void, onBusy: (Bool) -> Void
    @State private var periods = ViewPeriods()
    @State private var context: NoSalesContext?
    @State private var catalog: [Territory] = []
    @State private var step = 1
    @State private var qualify = "none"
    @State private var limit = "2"
    @State private var chosen: Set<String>?
    @State private var method = PricingMethod.ppp.rawValue
    @State private var base = ""
    @State private var basePrice = ""
    @State private var reduction = "1"
    @State private var percent = "25"
    @State private var proposal: NoSalesProposal?
    @State private var selected: Set<String> = []
    @State private var page = 1
    @State private var saved = false
    @State private var stale = false
    @State private var busy = false
    @State private var status = ""
    @State private var loadId = UUID()
    private let pageSize = 25
    private var days: Int { periods.days(.noSalesDays) }
    private var maxSales: Int? { qualify == "none" ? 0 : limit.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil ? Int(limit).flatMap { (0...1000).contains($0) ? $0 : nil } : nil }
    private var eligible: [PriceRow] { guard let context, context.coverage.days == days, let maxSales else { return [] }; return context.eligible(maxSales: maxSales) }
    private var picked: [String] { let available = Set(eligible.map(\.territory)); return (chosen ?? available).intersection(available).sorted() }
    private var strategy: NoSalesStrategy { method == "percent" ? .percent(percent) : method == "reduce" ? .reduce(amount: reduction, base: base) : .model(method: method, price: basePrice, base: base) }
    private var dirty: Bool { step >= 3 && !saved }
    private var unavailable: Bool { busy || blocked || stale }
    private var validStrategy: Bool { do { try strategy.validate(); return true } catch { return false } }
    private static let titles = ["Choose a Period", "Choose Countries", "Price Strategy", "Review Reductions"]
    /// Back and the step's one next command, in the page's step bar; Close and Restart stay with the guide.
    private var stepBar: StorebenchStepBarState {
        let wait = blocked ? "Save or review your pricing-model edits before continuing." : stale && !saved ? NoSalesFailure.stale.message : busy ? "Wait for the current check to finish." : nil
        var next: [StorebenchStepCommand] = []
        switch step {
        case 1:
            next = [.init(title: "Choose Countries", unavailable: wait ?? (context?.coverage.complete != true ? "Choose a period with complete saved reports." : eligible.isEmpty ? "No countries qualify in this period." : nil),
                          help: "Next: Choose Countries") { if !unavailable { step = 2; page = 1 } }]
        case 2:
            next = [.init(title: "Price Strategy", unavailable: wait ?? (picked.isEmpty ? "Choose at least one country." : picked.count > 200 ? "Choose 200 countries or fewer." : nil),
                          help: "Next: Price Strategy") { if !unavailable { step = 3; page = 1 } }]
        case 3:
            next = [.init(title: "Review Reductions", running: "Checking Prices…", busy: busy, unavailable: blocked || stale ? wait : picked.isEmpty ? "Choose at least one country." : !validStrategy ? "Choose a valid price strategy." : nil) { Task { await preview() } }]
        default:
            if !saved {
                next = [.init(title: "Save Reductions", running: "Saving Locally…", busy: busy, unavailable: blocked || stale ? wait : selected.isEmpty ? "Choose at least one reduction to save." : nil,
                              help: "Save \(selected.count) Local Reductions") { Task { await save() } }]
            }
        }
        return .init(id: "no-sales/\(step)", title: "Step \(step) of 4: \(Self.titles[max(0, min(step - 1, 3))])", detail: saved ? "Saved locally." : status.isEmpty ? "Only local drafts are saved." : status,
                     back: step > 1 && !saved ? .init(title: "Back", unavailable: busy ? "Wait for the current check to finish." : nil, primary: false) { back() } : nil, next: next)
    }
    private var hint: String { NoSalesStrategy.choices.first { $0.id == method }?.explanation ?? "" }

    /// The four steps beside the open one. Earlier steps can be opened again; a later step needs the one before it.
    private var rail: some View {
        StorebenchStepRail(title: "Lower Prices steps", items: Self.titles.enumerated().map { index, title in
            let number = index + 1, done = saved || number < step
            return .init(id: "\(number)", number: number, title: title, label: done ? "Done" : number == step ? "Next step" : "Later",
                         complete: done, current: !saved && number == step,
                         unavailable: number == step ? nil : saved ? "These reductions are saved. Restart to choose again."
                            : busy ? "Wait for the current check to finish." : number > step ? "Finish step \(step) first." : nil)
        }, selected: "\(step)", select: { id in if let number = Int(id) { open(number) } }, identifierPrefix: "no-sales.step.", showsNumbers: false)
        .storebenchControlID("no-sales.rail")
    }

    var body: some View {
        StorebenchStepLayout {
            rail
            guide
        }
    }

    private var guide: some View {
        Card(title: "Prices for countries with no or few purchases", subtitle: "Step \(step) of 4 · Review reductions against complete saved reports. Only local drafts are saved.", help: "no-sales-pricing") {
            if step == 1 { periodStep }
            if step == 2 { countryStep }
            if step == 3 { methodStep }
            if step == 4, let proposal { reviewStep(proposal) }
            Text(blocked ? "Save or review your pricing-model edits before continuing." : stale && !saved ? NoSalesFailure.stale.message : status)
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
            StorebenchStepCommands(state: stepBar)
            StorebenchActionGroup(alignment: .trailing) {
                Button(saved ? "Close Guide" : "Close…") { close() }
                if !saved { Button("Restart…") { restart() }.help("Restart with Saved Data").accessibilityLabel("Restart with Saved Data") }
            }.storebenchWorking(busy)
            if saved { Text("Saved locally. Review these prices in App Store changes before approving any Apple update.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
        }
        .task { if let initialMethod { method = initialMethod.rawValue }; await periods.load(session, scope: try? PeriodScope(accountId: account.id, appId: app.id)); await load() }
        .onChange(of: days) { chosen = nil; Task { await load() } }
        .onChange(of: qualify) { chosen = nil }
        .onChange(of: limit) { chosen = nil }
        .onChange(of: sourceVersion) { if !saved { stale = true } }
        .onChange(of: profileId) { if !saved { stale = true } }
        .onChange(of: busy) { onBusy(busy) }
        .onDisappear { loadId = UUID(); onBusy(false) }
        .trackUnsavedChanges(dirty, busy: busy)
    }

    private var periodStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeriodDaysField(title: "Completed Pacific reporting days", value: periods.daysBinding(.noSalesDays, session: session), presets: [7, 14, 30, 60, 90, 180, 365]).storebenchFormColumn().storebenchWorking(busy)
            PeriodPreferencesNotice(periods: periods)
            StorebenchPicker("A country qualifies with", selection: $qualify) { SelectionOption("No paid purchases", value: "none"); SelectionOption("At most a number of purchases", value: "few") }.storebenchFormColumn().storebenchWorking(busy)
            if qualify == "few" { StorebenchTextField("Most paid purchases (0–1,000)", text: $limit).storebenchFormColumn().storebenchWorking(busy) }
            if let coverage = context?.coverage, coverage.days == days {
                Text("\(coverage.beginDate) through \(coverage.endDate) · \(coverage.coveredDays) of \(days) days checked · \(eligible.count) eligible countries.")
                if !coverage.complete { Text("Download missing days in Sales, then restart this guide. Missing reports remain unknown.").foregroundStyle(StorebenchTheme.muted) }
            } else { Text("Reading report coverage…").foregroundStyle(StorebenchTheme.muted) }
        }
    }
    private var countryStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(picked.count) of \(eligible.count) countries selected · Up to 200 per review.").font(.sbCallout).fixedSize(horizontal: false, vertical: true)
            StorebenchActionGroup(alignment: .leading) {
                Button("Choose All") { chosen = Set(eligible.prefix(200).map(\.territory)) }
                if !picked.isEmpty { Button("Clear All") { chosen = [] } }
            }.storebenchWorking(busy)
            StorebenchTableFrame {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        StorebenchTableHeader(columns: [("Select", 42), ("Country", 200), ("Paid purchases", 130), ("Apple price", 160)])
                        ForEach(Array(eligible.dropFirst((page - 1) * pageSize).prefix(pageSize).enumerated()), id: \.element.id) { index, row in
                            StorebenchTableRow(index: index) {
                                StorebenchCheckbox("Select " + WorkspaceSession.countryName(row.territory), isOn: Binding(get: { picked.contains(row.territory) }, set: { value in var next = Set(picked); if value { next.insert(row.territory) } else { next.remove(row.territory) }; chosen = next })).labelsHidden().storebenchWorking(busy).frame(height: 42).frame(width: 42)
                                StorebenchTableCell(text: WorkspaceSession.countryName(row.territory), width: 200, lines: 2)
                                StorebenchTableCell(text: "\(Int(context?.coverage.unitsByTerritory[row.territory] ?? 0))", width: 130, lines: 2)
                                StorebenchTableCell(text: "\(row.customerPrice) \(row.currency)", width: 160, lines: 2)
                            }
                        }
                    }.frame(width: 532)
                }
            }
            pagination(count: eligible.count)
        }
    }
    private var methodStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            StorebenchPicker("Price Reduction Strategy", selection: $method) { selectionOptions(NoSalesStrategy.choices) { SelectionOption($0.name, value: $0.id) } }.storebenchFormColumn()
            Text(hint + " Only positive results below the current price and every existing local override can be saved.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            if method == "percent" { StorebenchTextField("Reduction (%)", text: $percent).storebenchFormColumn() }
            else {
                StorebenchFormGrid {
                    StorebenchPicker("Guide Country", selection: Binding(get: { base }, set: { code in base = code; basePrice = context?.prices.first { $0.territory == code }?.customerPrice ?? "" })) { selectionOptions(catalog) { SelectionOption("\($0.name) (\($0.currency))", value: $0.code) } }
                    StorebenchTextField(method == "reduce" ? "Reduction in guide currency" : "Guide price", text: method == "reduce" ? $reduction : $basePrice)
                }
                Text("Your shared pricing profile stays unchanged.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            }
            if !validStrategy { Text("Enter a valid price or reduction to review reductions.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
        }.storebenchWorking(busy)
    }
    private func reviewStep(_ proposal: NoSalesProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(proposal.rows.count) reductions available · \(proposal.skipped.count) skipped · \(proposal.context.coverage.beginDate) through \(proposal.context.coverage.endDate).")
            ForEach(proposal.warnings, id: \.self) { Text($0).font(.sbCallout).foregroundStyle(StorebenchTheme.color("color-warning")) }
            if !proposal.skipped.isEmpty {
                DisclosureGroup("Why Countries Were Skipped") {
                    ForEach(proposal.skipped) { item in Text("\(WorkspaceSession.countryName(item.territory)): \(item.reason)").font(.sbCallout).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            StorebenchTableFrame {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        StorebenchTableHeader(columns: [("Select", 42), ("Country", 200), ("Apple price", 160), ("Proposed price", 160), ("Saved country draft", 200), ("Calculation", 360)])
                        ForEach(Array(proposal.rows.dropFirst((page - 1) * pageSize).prefix(pageSize).enumerated()), id: \.element.id) { index, row in
                            StorebenchTableRow(index: index) {
                                if saved { StorebenchTableCell(text: selected.contains(row.territory) ? "Yes" : "No", width: 42) }
                                else { StorebenchCheckbox("Select " + WorkspaceSession.countryName(row.territory), isOn: Binding(get: { selected.contains(row.territory) }, set: { if $0 { selected.insert(row.territory) } else { selected.remove(row.territory) } })).labelsHidden().storebenchWorking(busy).frame(height: 42).frame(width: 42) }
                                StorebenchTableCell(text: WorkspaceSession.countryName(row.territory), width: 200)
                                StorebenchTableCell(text: "\(row.before) \(row.currency)", width: 160)
                                StorebenchTableCell(text: "\(row.amount) \(row.currency)", width: 160)
                                StorebenchTableCell(text: proposal.context.drafts.first { $0.territory == row.territory && $0.startDate == nil }.map { "\($0.amount) \($0.currency)" } ?? "None", width: 200)
                                StorebenchTableCell(text: row.detail, width: 360)
                            }
                        }
                    }.frame(width: 1122)
                }
            }
            pagination(count: proposal.rows.count)
        }
    }
    private func pagination(count: Int) -> some View {
        let pages = max(1, (count + pageSize - 1) / pageSize)
        return StorebenchPagination(page: min(max(1, page), pages), count: pages) { page = $0 }.storebenchWorking(busy)
    }
    private func back() {
        guard !busy, step > 1 else { return }
        if step == 4 { proposal = nil; selected = [] }
        step -= 1; page = 1; status = ""
    }
    /// Opens an earlier step again, as Back does one step at a time.
    private func open(_ number: Int) {
        while !busy, !saved, step > number { back() }
    }
    private func close() { if !busy && (!dirty || EditorProtection.confirm(.confirmDiscard)) { onClose() } }
    private func restart() {
        guard !busy, !dirty || EditorProtection.confirm(.confirmDiscard) else { return }
        step = 1; page = 1; proposal = nil; selected = []; chosen = nil; saved = false; context = nil
        Task { await load() }
    }
    private func load() async {
        let id = UUID(); loadId = id; busy = true
        defer { if loadId == id { busy = false } }
        do {
            let current = try await session.noSalesContext(accountId: account.id, appId: app.id, profileId: profileId, days: days)
            let client = try await session.client(for: account)
            var countries = (try? await session.territories(account: account, client: client)) ?? []
            for country in current.countries where !countries.contains(where: { $0.code == country.code }) { countries.append(country) }
            guard loadId == id, !Task.isCancelled else { return }
            context = current; catalog = countries.filter { !$0.currency.isEmpty }.sorted { $0.name < $1.name }
            base = current.profile.guideTerritory; basePrice = current.initialBase; stale = false; status = ""
        } catch { guard loadId == id, !Task.isCancelled else { return }; context = nil; status = message(error) }
    }
    private func preview() async {
        guard !unavailable, let context, let maxSales else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await session.previewNoSales(account: account, context: context, codes: picked, maxSales: maxSales, strategy: strategy, client: try await session.client(for: account))
            proposal = result; selected = Set(result.rows.map(\.territory)); saved = false; page = 1; step = 4
            status = result.rows.isEmpty ? "No lower prices are available with this strategy. Go back to review another method." : "Review the proposed amounts and deselect any country before saving locally."
        } catch { status = message(error); if error as? NoSalesFailure == .stale { stale = true } }
    }
    private func save() async {
        guard !unavailable, let proposal, !selected.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            let drafts = try await session.saveNoSales(account: account, proposal: proposal, codes: selected.sorted(), client: try await session.client(for: account))
            saved = true; status = "\(drafts.count) reductions saved on this Mac."; onSaved()
        } catch { status = message(error); if error as? NoSalesFailure == .stale { stale = true } }
    }
    private func message(_ error: Error) -> String { (error as? NoSalesFailure)?.message ?? (error as? PricingFailure)?.message ?? "Prices could not be verified. Nothing was saved. Retry or restart the guide." }
}
