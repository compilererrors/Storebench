import StorebenchCore
import SwiftUI

/// A paid app's country prices: Apple's current prices, protected prices, country drafts and the guide-price model. Nothing here changes App Store Connect.
struct CountryPricesView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @State private var saved: SavedPricing?
    @State private var protection: [PriceProtection] = []
    @State private var drafts: [PricingDraft] = []
    @State private var refreshing = false
    @State private var status = ""
    @State private var draftStatus = ""
    @State private var draftProblem = false
    @State private var query = ""
    @State private var tableSort = "country"
    @State private var tableDescending = false
    @State private var selected: Set<String> = []
    @State private var mode = "percent"
    @State private var percent = "100"
    @State private var amount = ""
    @State private var rounding = "nearest"
    @State private var temporary = false
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(7 * 86_400)
    @State private var working = false
    @State private var guideShown = false
    @State private var guideBusy = false
    @State private var guideProfileId = ""
    @State private var modelBlocked = true
    @State private var sourceVersion = 0
    @State private var modelPreview: [ModelPrice] = []
    @State private var countries: [PricingCountry] = []
    @State private var filteredCountries: [PricingCountry] = []
    @State private var countryPage = CollectionPresentation<String>(pageSize: 20)
    @State private var paidByCountry: [String: Int]?
    @State private var loadTicket = UUID()
    @State private var loaded = false
    @State private var pricingReadable = false
    @State private var expanded: String?
    @Environment(\.navigationPresentation) private var history
    @Environment(\.confirmDestructive) private var confirm
    @State private var historyOwner: NavigationPresentationContext?
    @State private var restoredQuery: String?
    @State private var restoredSort: String?
    @State private var restoredDescending: Bool?
    private struct TableSnapshot {
        let query: String, sort: String, descending: Bool, page: CollectionPresentation<String>, selected: Set<String>, expanded: String?
    }


    private var currentPage: CollectionPresentation<String>.Page { countryPage.page(filteredCountries.map(\.id)) }
    private var current: [PriceRow] { filteredCountries[currentPage.range].map(\.price) }
    private var reading: Bool { !loaded && status.isEmpty && session != nil }
    private func filterCountries(resetPage: Bool = true) {
        let matches = query.isEmpty ? countries : countries.filter { $0.search.localizedCaseInsensitiveContains(query) }
        filteredCountries = DataTablePresentation.sorted(matches, descending: tableDescending) { country in
            let row = country.price
            switch tableSort {
            case "currency": return .text(row.currency)
            case "price": return Decimal(string: row.customerPrice, locale: Locale(identifier: "en_US_POSIX")).map { .money($0, currency: row.currency) } ?? .unknown
            case "units": return paidByCountry?[row.territory].map { .number(Double($0)) } ?? .unknown
            default: return .text(country.name)
            }
        }
        if resetPage { countryPage.resetPage() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            currentPrices
            draftCard
            TransferCard(account: account, app: app, session: session, kind: .prices, title: "Import Country Drafts",
                         subtitle: "Country drafts from a CSV or JSON file, previewed before they are saved. Export Apple Prices… gives a file to edit. Protected countries cannot be imported.",
                         onImported: { await load() })
            if guideShown, let session {
                NoSalesGuideView(account: account, app: app, session: session, profileId: guideProfileId, blocked: modelBlocked || working || refreshing || !pricingReadable, sourceVersion: sourceVersion,
                    onClose: { guideShown = false }, onSaved: { Task { await load() } }, onBusy: { guideBusy = $0 })
            } else {
                Card(title: "Countries with no or few purchases", subtitle: "A guided review of prices where saved Sales reports show no or few purchases. Nothing changes until you save the reviewed drafts.", help: "overrides") {
                    Text("Complete saved reports are required. Save pricing-model edits before opening the guide.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                    if session != nil && saved?.snapshot != nil && !guideProfileId.isEmpty && !modelBlocked && pricingReadable {
                        StorebenchFormFooter {
                            Button("Lower Prices…") { if !working, !refreshing { guideShown = true } }.help("Review Prices for No or Few Purchases").accessibilityLabel("Review Prices for No or Few Purchases").storebenchWorking(working || refreshing)
                        }
                    }
                }
            }
            if loaded { ModelCard(account: account, app: app, session: session, current: saved?.snapshot?.rows ?? [], onState: { id, blocked in guideProfileId = id; modelBlocked = blocked }, onPreview: { modelPreview = $0 }).storebenchWorking(guideBusy) }
            else if reading {
                // The pricing model's own card, with a status line until its prices are read.
                Card(title: "Pricing model", subtitle: "Plan prices across countries from one model.") { StorebenchLoadingStatus(message: "Reading saved prices…", surface: false) }
            }
            SalesReportsView(account: account, app: app, session: session, blocked: guideShown || guideBusy || working || refreshing, onChanged: { await load() })
        }
        .task(id: account.id + "/" + app.id) { restoreTable(); showRemembered(); await load() }
        .onDisappear { saveTable(); loadTicket = UUID() }
        .onChange(of: query) { if restoredQuery == query { restoredQuery = nil } else { filterCountries() }; saveTable() }
        .onChange(of: tableSort) { if restoredSort == tableSort { restoredSort = nil } else { filterCountries() }; saveTable() }
        .onChange(of: tableDescending) { if restoredDescending == tableDescending { restoredDescending = nil } else { filterCountries() }; saveTable() }
        .onChange(of: countryPage) { saveTable() }
        .onChange(of: selected) { saveTable() }
        .onChange(of: expanded) { saveTable() }

    }

    private var currentPrices: some View {
        Card(title: "Apple prices", subtitle: saved.map { "Checked \($0.checkedAt.prefix(16).replacingOccurrences(of: "T", with: " ")) UTC\($0.code != nil ? " · The last refresh failed; the prices shown are the last ones Apple returned." : "")" } ?? "Read the app's current prices from App Store Connect.", help: "protection") {
                StorebenchActionGroup {
                    StorebenchReadButton("Read Saved Prices") { await load(announce: true) }.storebenchWorking(refreshing || guideBusy || session == nil)
                    Button(refreshing ? "Refreshing…" : "Refresh Prices") { Task { await refresh() } }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(refreshing || guideBusy || session == nil)
                }
                VStack(alignment: .leading, spacing: 8) {
                    StorebenchTableControls(query: $query, sort: $tableSort, descending: $tableDescending,
                        options: [("country", "Country"), ("currency", "Currency"), ("price", "Price within currency"), ("units", "Paid units")],
                        pageSize: Binding(get: { countryPage.pageSize }, set: { countryPage.chooseSize($0) }), searchTitle: "Search countries")
                    Text(currentPage.summary + " countries · \(selected.count) selected across pages").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                    StorebenchActionGroup {
                        if !selected.isEmpty && pricingReadable { Button("Keep Current Prices") { Task { await protect(Array(selected)) } }.storebenchWorking(working || guideBusy).help("Protected prices are never changed by drafts or models.") }
                        if !selected.isEmpty { Button("Clear Selection") { selected.removeAll() } }
                    }
                }
                if loaded && filteredCountries.isEmpty { Text(saved == nil ? "No prices read yet." : "No current prices match.").foregroundStyle(StorebenchTheme.muted) }
                StorebenchTableFrame {
                    StorebenchResizableTableViewport(key: "apple-prices", minimum: [84, 190, 132, 164, 112, 152, 112, 244], weights: [0, 2, 1, 2, 1, 1, 1, 0], height: DataTablePresentation.headerHeight + Double(reading ? 1 : current.count) * ComponentLayout.tableRowHeight(lines: 4) + (current.contains { $0.territory == expanded } ? 196 : 0), fixed: [0, 7]) { columns, resize in
                        VStack(alignment: .leading, spacing: 0) {
                            StorebenchTableHeader(columns: zip(["Select", "Country", "Apple price", "Proposed price", "Change", "Apple price in USD", "Paid units", "Actions"], columns).map { ($0.0, CGFloat($0.1)) }, resize: resize, fixed: [0, 7])
                            ForEach(Array(current.enumerated()), id: \.element.id) { index, row in
                                let locked = protection.contains { $0.territory == row.territory }
                                let pending = drafts.filter { $0.territory == row.territory }
                                let calculation = modelPreview.first { $0.territory == row.territory && $0.currency == row.currency }
                                let override = pending.first { $0.startDate == nil && $0.currency == row.currency }
                                let proposed = locked ? row.customerPrice : override?.amount ?? calculation?.amount
                                StorebenchTableRow(index: index) {
                                    Group {
                                        if locked { Color.clear.accessibilityHidden(true) }
                                        else { StorebenchCheckbox("Select " + WorkspaceSession.countryName(row.territory), isOn: Binding(get: { selected.contains(row.territory) }, set: { if $0 { selected.insert(row.territory) } else { selected.remove(row.territory) } })).labelsHidden()
                                            .storebenchWorking(guideBusy || working || !pricingReadable) }
                                    }.frame(height: 52).frame(width: columns[0])
                                    StorebenchTableCell(text: "\(WorkspaceSession.countryName(row.territory))\n\(row.territory)", width: columns[1], title: "Country")
                                    StorebenchTableCell(text: "\(row.customerPrice) \(row.currency)", width: columns[2], title: "Apple price")
                                    StorebenchTableCell(text: proposed.map { "\($0) \(row.currency)\n" + (locked ? "Protected" : override != nil ? "Saved country override" : "Model preview") } ?? "—\nNo preview", width: columns[3], title: "Proposed price")
                                    StorebenchTableCell(text: priceChange(proposed, row: row), width: columns[4], title: "Change")
                                    StorebenchTableCell(text: row.currency == "USD" ? "\(row.customerPrice) USD" : "Unknown", width: columns[5], title: "Apple price in USD")
                                    StorebenchTableCell(text: paidUnits(row.territory), width: columns[6], title: "Paid units")
                                    HStack(spacing: 8) {
                                        Group {
                                            if locked { Color.clear.accessibilityHidden(true) }
                                            else { Button("Override") { selected = [row.territory]; mode = "exact"; amount = row.customerPrice }.storebenchWorking(guideBusy || working || !pricingReadable) }
                                        }.frame(width: 106)
                                        Button(expanded == row.territory ? "Hide" : "Details") { expanded = expanded == row.territory ? nil : row.territory }
                                            .buttonStyle(StorebenchButtonStyle(.quiet)).frame(width: 106)
                                            .accessibilityLabel("Details for " + WorkspaceSession.countryName(row.territory))
                                            .accessibilityValue(expanded == row.territory ? "Expanded" : "Collapsed")
                                            .help(expanded == row.territory ? "Hide country details" : "Show country details")
                                    }.environment(\.naturalActions, true).frame(height: 42).padding(.horizontal, 12).frame(width: columns[7])
                                }
                                if expanded == row.territory {
                                    VStack(alignment: .leading, spacing: 12) {
                                        StorebenchTextSlot(text: "Effective from: \(row.startDate ?? "Not provided")\nApple price type: \(row.source == "manual" ? "Manual" : "Apple generated")\nModel calculation: \(calculation?.problem ?? calculation?.detail ?? "No preview for this country.")\nUSD estimates require a saved currency rate. Paid units cover only complete saved reporting periods.\n" + (pending.isEmpty ? "No country drafts." : pending.map { draft in "Draft: \(draft.amount) \(draft.currency)\(draft.startDate.map { " · \($0) – \(draft.endDate ?? "")" } ?? "")" }.joined(separator: "\n")), height: 108, font: .sbCallout, color: StorebenchTheme.muted)
                                        if locked { Button("Allow Price Changes") { Task { await unprotect(row.territory) } }.storebenchWorking(guideBusy || working || !pricingReadable) }
                                    }.padding(12).frame(width: columns.reduce(0, +), height: 196, alignment: .leading).background(StorebenchTheme.color("color-surface-subtle"))
                                }
                            }
                            // The real table with one status row while the first prices are read; no stand-in rows are drawn.
                            if reading {
                                StorebenchLoadingStatus(message: "Reading saved prices…", surface: false)
                                    .padding(.horizontal, 12).frame(width: columns.reduce(0, +), height: ComponentLayout.tableRowHeight(lines: 4), alignment: .leading)
                            }
                        }.frame(width: columns.reduce(0, +), alignment: .leading)
                    }
                }
                if currentPage.count > 1 { StorebenchPagination(page: currentPage.number, count: currentPage.count) { countryPage.choosePage($0) } }
                StorebenchFeedback(text: status, height: 32)
            }
    }

    private func restoreTable() {
        historyOwner = history
        guard let history, let snapshot = history.store.collection("pricing-countries", entry: history.entry, as: TableSnapshot.self) else { return }
        restoredQuery = query == snapshot.query ? nil : snapshot.query
        restoredSort = tableSort == snapshot.sort ? nil : snapshot.sort
        restoredDescending = tableDescending == snapshot.descending ? nil : snapshot.descending
        query = snapshot.query; tableSort = snapshot.sort; tableDescending = snapshot.descending; countryPage = snapshot.page; selected = snapshot.selected; expanded = snapshot.expanded
    }
    private func saveTable() {
        guard let historyOwner else { return }
        historyOwner.store.saveCollection(TableSnapshot(query: query, sort: tableSort, descending: tableDescending, page: countryPage, selected: selected, expanded: expanded), key: "pricing-countries", entry: historyOwner.entry)
    }

    /// Country drafts for the selected countries; protected countries are refused while protection is held.
    private var draftCard: some View {
        Card(title: "Country drafts", subtitle: "Planned prices are saved on this Mac and published later in App Store changes.", help: "overrides") {
            Text(selected.isEmpty ? "Select countries in Apple prices." : "\(selected.count) countries selected").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            StorebenchCardSection(title: "Draft settings", help: "methods") {
            StorebenchChoicePicker("Change", selection: $mode, options: [("percent", "Percentage of current price"), ("exact", "Exact price")])
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                if mode == "percent" {
                    StorebenchTextField("Percent", text: $percent).info("Starts from the current Apple price. Use a negative number to lower prices, such as -10 for 10 percent lower.")
                    StorebenchPicker("Rounding", selection: $rounding) { selectionOptions(PricingRounding.allCases) { SelectionOption($0.name, value: $0.rawValue) } }
                } else {
                    StorebenchTextField("Amount", text: $amount)
                }
            }
            Toggle("Temporary price", isOn: $temporary)
            if temporary {
                StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) { StorebenchDateField("From", selection: $start, displayedComponents: .date); StorebenchDateField("Through", selection: $end, displayedComponents: .date) }
            }
            }
            if mode == "exact" && selected.count > 1 { Text("An exact price applies to one country. Select a single country in Apple prices.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            if !pricingReadable && !selected.isEmpty { Text("Apple prices are not read yet. Choose Read Saved Prices or Refresh Prices above, then save the drafts.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
            if pricingReadable && !selected.isEmpty && !(mode == "exact" && selected.count != 1) {
                StorebenchFormFooter {
                    Button(working ? "Saving…" : "Save Country Drafts") { Task { await saveDrafts() } }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(guideBusy || working)
                }
            }
            StorebenchFeedback(text: draftStatus, height: 40, error: draftProblem)
            StorebenchCollection(items: drafts, title: { WorkspaceSession.countryName($0.territory) }, subtitle: { $0.amount + " " + $0.currency },
                                 empty: "No country drafts yet. Select countries in Apple prices, choose a change, then Save Country Drafts.") { draft in
                HStack {
                    Text("\(WorkspaceSession.countryName(draft.territory)) · \(draft.amount) \(draft.currency)\(draft.startDate.map { " · \($0) – \(draft.endDate ?? "")" } ?? "")")
                    Spacer()
                    Button("Remove", role: .destructive) {
                        guard confirm(.removePriceDraft, title: "Remove the \(WorkspaceSession.countryName(draft.territory)) price draft?", message: "The draft is removed from this Mac. Prices at App Store Connect do not change.", action: "Remove") else { return }
                        Task { await remove(draft) }
                    }.buttonStyle(StorebenchButtonStyle(.quiet)).storebenchWorking(guideBusy || working || !pricingReadable)
                }
            }
        }
    }

    private func priceChange(_ amount: String?, row: PriceRow) -> String {
        guard let amount, let proposed = PricingMath.decimal(amount), let before = PricingMath.decimal(row.customerPrice) else { return "—" }
        let delta = proposed - before
        return "\(delta > 0 ? "+" : "")\(PricingMath.text(delta)) \(row.currency)"
    }
    private func paidUnits(_ territory: String) -> String {
        guard let paidByCountry else { return "Unknown" }
        return String(paidByCountry[territory] ?? 0)
    }
    private var readKey: String { "pricing/\(account.id)/\(app.id)" }
    /// The prices read on an earlier visit in this window show at once; actions stay locked until the read that follows confirms them.
    private func showRemembered() {
        guard !loaded, let value = history?.rememberedRead(readKey, as: PricingScreen.self) else { return }
        apply(value); loaded = true
    }
    private func apply(_ value: PricingScreen) {
        saved = value.saved; protection = value.protection; drafts = value.drafts
        countries = value.countries; paidByCountry = value.paidUnits
        filterCountries(resetPage: false); countryPage.reconcile(filteredCountries.map(\.id))
    }
    private var pricing: PricingService? { session.map { PricingService(session: $0, account: account, appId: app.id) } }

    private func load(announce: Bool = false) async {
        guard let pricing else { return }
        let ticket = UUID(); loadTicket = ticket; pricingReadable = false
        do {
            let value = try await pricing.screen()
            guard loadTicket == ticket, !Task.isCancelled else { return }
            apply(value); history?.rememberRead(value, readKey)
            sourceVersion += 1; loaded = true; pricingReadable = true
            // Read Saved Prices always answers, also when nothing is saved yet.
            if announce { status = value.saved == nil ? "No prices are saved on this Mac yet. Refresh Prices reads them from App Store Connect." : "Saved prices read." }
        } catch {
            guard loadTicket == ticket, !Task.isCancelled else { return }
            status = "Saved pricing could not be confirmed. Your current prices and edits are kept; retry before saving changes."
        }
    }

    private func refresh() async {
        guard let pricing else { return }
        refreshing = true; defer { refreshing = false }
        do { try await pricing.refresh(); status = "" }
        catch PricingFailure.access { status = PricingFailure.access.message }
        catch { status = "Prices could not be read. The last saved prices are kept." }
        await load()
    }

    private func protect(_ territories: [String]) async {
        guard pricingReadable, !working, !guideBusy else { return }
        guard let pricing else { return }
        working = true; defer { working = false }
        do { status = "\(try await pricing.protect(territories, basis: saved?.snapshot?.rows ?? [], today: ReportDay.today)) prices protected." }
        catch let failure as PricingFailure { status = failure.message } catch { status = PricingFailure.read.message }
        await load()
    }

    private func unprotect(_ territory: String) async {
        guard pricingReadable, !working, !guideBusy else { return }
        try? await pricing?.allowChanges(territory)
        await load()
    }

    private func remove(_ draft: PricingDraft) async {
        guard pricingReadable, !working, !guideBusy else { return }
        do { try await pricing?.removeDraft(draft); draftProblem = false; draftStatus = "\(WorkspaceSession.countryName(draft.territory)) draft removed on this Mac." }
        catch { draftProblem = true; draftStatus = "The \(WorkspaceSession.countryName(draft.territory)) draft was not removed. It is still saved; try again." }
        await load()
    }

    private func saveDrafts() async {
        guard pricingReadable, !working, !guideBusy else { return }
        guard let pricing else { return }
        working = true; defer { working = false }
        let request = CountryDraftRequest(territories: selected, change: mode == "exact" ? .exact(amount) : .percent(percent, rounding: rounding),
                                          period: temporary ? CountryDraftRequest.Period(start: ReportDay.format(start), end: ReportDay.format(end)) : nil)
        do {
            let saved = try await pricing.saveDrafts(request, basis: self.saved?.snapshot?.rows ?? [], today: ReportDay.today)
            draftProblem = false; draftStatus = "\(saved.count) country drafts saved on this Mac."; selected = []
        } catch let failure as PricingFailure { draftProblem = true; draftStatus = "Not saved. " + failure.message } catch { draftProblem = true; draftStatus = "Not saved. Check the amounts and dates; temporary periods cannot overlap." }
        await load()
    }
}

/// The app's pricing model retains its original revision until an explicit save or baseline choice.
private struct PricingModelInput: Equatable, Sendable {
    var profile: PricingProfileInputs
    var base, currency: String
}

struct ModelCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, current: [PriceRow]
    var onState: (String, Bool) -> Void = { _, _ in }
    var onPreview: ([ModelPrice]) -> Void = { _ in }
    @State private var latestReading = false
    @State private var profiles: [PricingProfile] = []
    @State private var profileId = ""
    @State private var editor: SavedValueReview<PricingModelInput>?
    @State private var rows: [ModelPrice] = []
    @State private var previewQuery = ""
    @State private var previewSort = "country"
    @State private var previewDescending = false
    @State private var previewPage = CollectionPresentation<String>(pageSize: 20)
    @State private var warnings: [String] = []
    @State private var status = ""
    @State private var working = false
    @State private var pendingProfile: String?
    @State private var confirmingSwitch = false

    private var compatible: Bool {
        guard let editor, let comparison = editor.comparison else { return false }
        return comparison.value.profile.guideTerritory == editor.inputs.profile.guideTerritory && comparison.value.currency == editor.inputs.currency
    }
    private var comparison: [SavedValueChange]? {
        guard let editor, let latest = editor.comparison?.value else { return nil }
        var changes = PricingInputChanges.compare(latest.profile, editor.inputs.profile, identity: false)
        if latest.base != editor.inputs.base { changes.insert(.init(id: "base", label: "Guide price", saved: latest.base, edited: editor.inputs.base), at: 0) }
        if !compatible { changes.insert(.init(id: "context", label: "Guide country and currency", saved: "\(latest.profile.guideTerritory) (\(latest.currency))", edited: "\(editor.inputs.profile.guideTerritory) (\(editor.inputs.currency))"), at: 0) }
        return changes
    }

    var body: some View {
        Card(title: "Pricing model", subtitle: "Set a guide price and how other countries follow it. The preview uses Apple's price points; nothing is published.", help: "model") {
            StorebenchCardSection(title: "Model and guide price") {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                StorebenchPicker("Profile", selection: Binding(get: { profileId }, set: requestProfile)) { selectionOptions(profiles) { SelectionOption($0.name, value: $0.id) } }.storebenchWorking(working)
                if let editor {
                    StorebenchTextField("Guide price", text: Binding(get: { self.editor?.inputs.base ?? "" }, set: { self.editor?.inputs.base = $0 })).storebenchWorking(working)
                }
            }
            if let editor { Text("Guide price: \(editor.inputs.currency) in \(WorkspaceSession.countryName(editor.inputs.profile.guideTerritory))").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
            }
            if editor != nil {
                PricingInputFields(inputs: Binding(get: { editor!.inputs.profile }, set: { editor?.inputs.profile = $0 }), identity: false).storebenchWorking(working)
                if editor?.inputs.base.isEmpty == false {
                    StorebenchFormFooter {
                        Button(working ? "Working…" : "Preview Prices") { Task { await preview() } }
                        Button("Save Model") { Task { await save() } }.buttonStyle(StorebenchButtonStyle(.primary))
                    }.storebenchWorking(working)
                } else { Text("Enter a guide price to preview or save the model.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                LatestSaveReview(busy: working, reading: latestReading, hasEdits: editor?.dirty == true, available: editor != nil, changes: comparison, note: editor?.comparison != nil && !compatible ? "The shared profile now uses another guide country or currency. Your amounts remain in their original context. Load the updated context only after retaining any edits you need." : nil,
                    onRead: { Task { await readLatest() } }, onKeep: compatible ? { acceptLatest(useSaved: false) } : nil, onUse: compatible ? { acceptLatest(useSaved: true) } : nil)
                if editor?.comparison != nil && !compatible { Button("Load Context…") { pendingProfile = profileId; confirmingSwitch = true }.help("Load Updated Context").accessibilityLabel("Load Updated Context").storebenchWorking(working) }
                Text(editor?.dirty == true ? "Your model edits are not saved." : "Model values match the chosen saved baseline.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            } else if !profileId.isEmpty {
                Button("Load Model") { Task { await load(profileId) } }.storebenchWorking(working)
            }
            ForEach(warnings, id: \.self) { Text($0).font(.sbCallout).foregroundStyle(StorebenchTheme.color("color-warning")) }
            StorebenchFeedback(text: status, height: 34)
            if !rows.isEmpty {
                let filtered = DataTablePresentation.sorted(rows.filter { previewQuery.isEmpty || (WorkspaceSession.countryName($0.territory) + " " + $0.currency + " " + $0.territory).localizedCaseInsensitiveContains(previewQuery) }, descending: previewDescending) { row in
                    if previewSort == "price", let amount = row.amount, let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) { return .money(value, currency: row.currency) }
                    if previewSort == "price" { return .unknown }
                    return .text(WorkspaceSession.countryName(row.territory))
                }
                let page = previewPage.page(filtered.map(\.id))
                StorebenchTableControls(query: $previewQuery, sort: $previewSort, descending: $previewDescending,
                    options: [("country", "Country"), ("price", "Proposed price within currency")],
                    pageSize: Binding(get: { previewPage.pageSize }, set: { previewPage.chooseSize($0) }), searchTitle: "Find model preview countries")
                    .onChange(of: previewQuery) { previewPage.resetPage() }.onChange(of: previewSort) { previewPage.resetPage() }.onChange(of: previewDescending) { previewPage.resetPage() }
                Text(page.summary + " preview countries").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                StorebenchTableFrame {
                    StorebenchResizableTableViewport(key: "price-model-preview", minimum: [210, 150, 440], weights: [1, 1, 2], height: DataTablePresentation.headerHeight + Double(page.range.count) * ComponentLayout.tableRowHeight(lines: 3)) { columns, resize in
                        VStack(alignment: .leading, spacing: 0) {
                            StorebenchTableHeader(columns: zip(["Country", "Proposed price", "Model calculation"], columns).map { ($0.0, CGFloat($0.1)) }, resize: resize)
                            ForEach(Array(filtered[page.range].enumerated()), id: \.element.id) { index, row in
                                StorebenchTableRow(index: index) {
                                    StorebenchTableCell(text: WorkspaceSession.countryName(row.territory), width: columns[0], title: "Country")
                                    StorebenchTableCell(text: row.amount.map { "\($0) \(row.currency)" } ?? "—", width: columns[1], title: "Proposed price")
                                    StorebenchTableCell(text: row.problem ?? row.detail, width: columns[2], title: "Model calculation")
                                }
                            }
                        }.frame(width: columns.reduce(0, +))
                    }
                }
                if page.count > 1 { StorebenchPagination(page: page.number, count: page.count) { previewPage.choosePage($0) } }
            }
        }
        .task { await initial() }
        .trackUnsavedChanges(editor?.dirty == true, busy: working, onSave: { await save(); return editor?.dirty == false })
        .onChange(of: editor?.inputs) { rows = []; warnings = [] }
        .onChange(of: rows) { previewPage.resetPage(); onPreview(rows) }
        .onChange(of: profileId) { notifyState() }
        .onChange(of: editor?.dirty) { notifyState() }
        .onChange(of: working) { notifyState() }
        .confirmationDialog("Discard the current model's unsaved edits and load another pricing context?", isPresented: $confirmingSwitch) {
            Button("Discard Edits and Load", role: .destructive) {
                guard let pendingProfile else { return }
                Task { await load(pendingProfile) }
            }
        }
    }

    private func notifyState() { onState(profileId, editor == nil || editor?.dirty == true || working) }

    private func requestProfile(_ id: String) {
        guard !working, id != profileId else { return }
        if editor?.dirty == true { pendingProfile = id; confirmingSwitch = true }
        else { Task { await load(id) } }
    }

    private func initial() async {
        guard editor == nil, !working, let session else { return }
        do {
            let state = try await session.pricingProfiles(); profiles = state.profiles
            await load(profileId.isEmpty ? state.defaultId : profileId)
        } catch { status = "Pricing profiles could not be read." }
    }

    /// Currency/catalog downloads finish before the scoped model is read under its storage lock.
    private func snapshot(_ id: String) async throws -> (value: PricingModelInput, revision: String, profiles: [PricingProfile]) {
        guard let session else { throw PricingFailure.read }
        let state = try await session.pricingProfiles()
        guard let profile = state.profiles.first(where: { $0.id == id }) else { throw PricingFailure.stale }
        var currency = current.first { $0.territory == profile.guideTerritory }?.currency ?? ""
        if currency.isEmpty {
            let territories = try await session.territories(account: account)
            currency = territories.first { $0.code == profile.guideTerritory }?.currency ?? ""
        }
        guard !currency.isEmpty else { throw PricingFailure.invalid("Refresh Apple prices to load the guide country's currency.") }
        guard let saved = try await session.appPricingModel(accountId: account.id, appId: app.id, profileId: id, currency: currency), saved.profile.guideTerritory == profile.guideTerritory else { throw PricingFailure.stale }
        return (PricingModelInput(profile: PricingProfileInputs(saved.profile), base: saved.base, currency: currency), saved.revision, state.profiles)
    }

    private func load(_ id: String) async {
        guard !working else { return }
        working = true; defer { working = false }
        do {
            let saved = try await snapshot(id)
            editor = SavedValueReview(value: saved.value, revision: saved.revision); profiles = saved.profiles; profileId = id
            rows = []; warnings = []; status = ""; pendingProfile = nil
        } catch let failure as PricingFailure { status = failure.message }
        catch { status = "The pricing model could not be read. Your current inputs remain here." }
    }

    private func preview() async {
        guard !working, let session, let input = editor?.inputs else { return }
        working = true; defer { working = false }
        do {
            let model = try input.profile.validated(), client = try await session.client(for: account)
            let catalog = try await session.territories(account: account, client: client)
            let result = try await session.modelPreview(appId: app.id, profile: model, base: input.base, countries: catalog, guideCurrency: input.currency, client: client)
            rows = result.rows; warnings = result.warnings; status = ""
        } catch let failure as PricingFailure { status = failure.message }
        catch { status = "The preview could not be calculated. Check the guide price and retry." }
    }

    private func save() async {
        guard !working, let session, let editor else { return }
        working = true; defer { working = false }
        do {
            let model = try editor.inputs.profile.validated(), base = PricingMath.text(try PricingMath.desired(editor.inputs.base))
            let revision = try await session.savePricingTarget(accountId: account.id, appId: app.id, profileId: profileId, currency: editor.inputs.currency, amount: base, model: model, revision: editor.baseline.revision)
            self.editor = SavedValueReview(value: PricingModelInput(profile: PricingProfileInputs(model), base: base, currency: editor.inputs.currency), revision: revision)
            status = "Pricing model saved on this Mac."
        } catch PricingFailure.stale { status = "The shared profile or this app's model changed elsewhere. Your inputs remain here. Compare with the latest save before saving again." }
        catch let failure as PricingFailure { status = failure.message }
        catch { status = "The pricing model could not be saved." }
    }

    private func readLatest() async {
        guard !working else { return }
        latestReading = true; defer { latestReading = false }
        working = true; defer { working = false }
        do {
            let saved = try await snapshot(profileId)
            editor?.compare(value: saved.value, revision: saved.revision); status = ""
        } catch let failure as PricingFailure { status = failure.message }
        catch { status = "The latest model could not be read. Your inputs and revision are unchanged." }
    }

    private func acceptLatest(useSaved: Bool) {
        guard !working, compatible else { return }
        editor?.acceptLatest(useSaved: useSaved); rows = []; warnings = []
        status = useSaved ? "Saved model values loaded. Nothing was saved." : "Your edits are kept against the chosen latest save. Nothing was saved."
    }
}

enum ReportDay {
    static var today: String { format(Date()) }
    static func format(_ date: Date) -> String { let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"; format.timeZone = TimeZone(identifier: "UTC"); format.locale = Locale(identifier: "en_US_POSIX"); return format.string(from: date) }
}
