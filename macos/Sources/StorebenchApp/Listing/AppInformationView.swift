import StorebenchCore
import SwiftUI

/// App settings are read independently; Apple changes always use the guarded publishing review.
struct AppInformationView: View {
    enum Part: CaseIterable { case categories, ageRating, accessibility, exportCompliance, availability }
    static let all: Set<Part> = Set(Part.allCases)
    let account: Account, app: Account.App, session: WorkspaceSession?
    var parts: Set<Part> = AppInformationView.all
    /// On App Store Connect's App Information page, what is still needed shows first.
    var checklist = false
    /// Told when a review from these cards reaches Apple, so a page that checks Apple's state, such as Release, checks again.
    var changed: () -> Void = {}
    @State private var editor = AppInformationEditor()
    @State private var draft: LocalEditorDraftEditor?
    @State private var review: PublishReview?
    /// The card whose Prepare Review made the review, which then shows right below that card.
    @State private var reviewPart: Part?
    @State private var status = ""
    @State private var ageStatus = ""
    @State private var accessibilityStatus = ""
    @State private var query = ""
    @State private var family = "IPHONE"
    @State private var working = false
    @State private var publishing = false
    @State private var attempted = false
    @Environment(\.navigationPresentation) private var history
    /// A view showing only some cards remembers only what it read.
    private var readKey: String { "app-information/\(account.id)/\(app.id)" + (parts == Self.all ? "" : "/" + Part.allCases.filter(parts.contains).map { "\($0)" }.joined(separator: ",")) }
    private struct Choices: Equatable { var query, family: String }

    private var busy: Bool { working || publishing }
    private func reading(_ ready: Bool) -> Bool { !ready && session != nil && (working || !attempted) }
    private var top: [AppCategory] { editor.categoryChoices.filter { $0.parentId == nil } }
    private func children(_ parent: String?) -> [AppCategory] { editor.categoryChoices.filter { $0.parentId != nil && $0.parentId == parent } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if checklist, editor.informationReady {
                StorebenchChecklist(rows: [
                    .init(id: "rights", title: "Content Rights", done: editor.information?.contentRights?.isEmpty == false),
                    .init(id: "category", title: "Primary Category", done: (editor.information?.categories?["primaryCategory"] ?? nil) != nil),
                    .init(id: "age", title: "Age Rating", done: editor.ageReady && editor.ageAnswers.map { AgeRating.unanswered(.object($0.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })).isEmpty } == true),
                ], guide: .release)
            }
            // Apple's current answers are read here; the read lives in a headed card like every other section, never loose on the page.
            Card(title: "App Information at Apple", subtitle: "Apple's current answers for this app. Change them below; each card prepares its own review.", actions: AnyView(Group { if session != nil { StorebenchBusyButton(title: "Refresh", loadingTitle: "Loading…", busy: busy) { Task { await load(fresh: true) } }.help("Refresh App Information").accessibilityLabel("Refresh App Information") } })) {
                StorebenchFeedback(text: status, height: 40)
                if let draft, !draft.loaded { LocalDraftActions(editor: draft, value: editor.localDraft, restore: { editor.restoreLocalDraft($0) }, blocked: busy) }
            }
            VStack(alignment: .leading, spacing: 20) {
                if parts.contains(.categories) { informationCard.id("release-info-categories"); reviewPanel(.categories) }
                if parts.contains(.ageRating) { ageCard.id("release-info-age-rating"); reviewPanel(.ageRating) }
                if parts.contains(.accessibility) { accessibilityCard.id("release-info-accessibility"); reviewPanel(.accessibility) }
                if parts.contains(.exportCompliance) {
                    ExportComplianceCard(account: account, app: app, session: session, prepare: { await prepare($0, part: .exportCompliance) }, changed: { review = nil })
                        .id("release-info-export-compliance")
                    reviewPanel(.exportCompliance)
                }
                if parts.contains(.availability) { availabilityCard.id("release-info-availability"); reviewPanel(.availability) }
            }.storebenchWorking(busy || draft?.loaded != true)
        }
        .trackUnsavedChanges(draft?.dirty(editor.localDraft) ?? editor.dirty, busy: busy || draft?.busy == true, onSave: { await draft?.saveCurrent(value: { editor.localDraft }) == true })
        .historyValue("app-information", Binding(get: { Choices(query: query, family: family) }, set: { query = $0.query; family = $0.family }))
        .task {
            // Apple's answers last read in this window show at once, read-only while they are read again.
            if !editor.informationReady, !editor.ageReady, !editor.accessibilityReady, let remembered = history?.rememberedRead(readKey, as: AppInformationEditor.self) { editor = remembered }
            await load()
            if let session {
                let owner = LocalEditorDraftEditor(scope: .init(accountId: account.id, appId: app.id, editor: "app-information", resource: parts.map { String(describing: $0) }.sorted().joined(separator: "/")), session: session)
                draft = owner
                if let saved = await owner.load(initial: editor.localDraft) { editor.restoreLocalDraft(saved) }
            }
        }
    }

    private var draftFieldsForReview: [[String]]? {
        switch review?.request.scope {
        case .appInformation: return [["rights"], ["categories"]]
        case .ageRating: return [["ages"]]
        case .accessibility:
            guard review?.request.accessibilityAction == "save-draft", let family = review?.request.accessibilityFamily else { return nil }
            return [["accessibility", family]]
        default: return nil
        }
    }

    /// The review prepared from one card, right below it, so preparing never moves the page.
    @ViewBuilder private func reviewPanel(_ part: Part) -> some View {
        if reviewPart == part, review != nil {
            ReviewPanel(account: account, app: app, session: session, review: $review, done: {
                if review?.state == "complete" { changed(); Task { await load(fresh: true) } }
            }, busyChanged: { publishing = $0 }, syncConfirmation: true, localDraft: draftFieldsForReview == nil ? nil : draft, draftPaths: draftFieldsForReview).storebenchWorking(working)
        }
    }

    private var informationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Content Rights", subtitle: "Does your app contain, show, or access third-party content?") {
                if !editor.informationReady && !reading(editor.informationReady) { notReady }
                else { StorebenchChoicePicker("Content rights", selection: Binding(get: { editor.rights }, set: { editor.chooseRights($0); review = nil }), options: [("", "Not declared"), ("DOES_NOT_USE_THIRD_PARTY_CONTENT", "No, it doesn't contain third-party content"), ("USES_THIRD_PARTY_CONTENT", "Yes, it contains third-party content and I have the necessary rights")], style: .radio).storebenchPlaceholder(!editor.informationReady) }
            }
            Card(title: "Category", subtitle: "The primary category is required. Subcategories are available for some categories, such as Games.") {
                if let error = editor.information?.categoryError { Text(error).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
                if !editor.informationReady && !reading(editor.informationReady) { notReady }
                else if editor.information?.categories != nil || !editor.informationReady {
                StorebenchFormGrid() {
                    categoryPicker("primaryCategory", top, optional: false)
                    categoryPicker("secondaryCategory", top)
                    if !children(category("primaryCategory")).isEmpty {
                        categoryPicker("primarySubcategoryOne", children(category("primaryCategory")))
                        categoryPicker("primarySubcategoryTwo", children(category("primaryCategory")))
                    }
                    if !children(category("secondaryCategory")).isEmpty {
                        categoryPicker("secondarySubcategoryOne", children(category("secondaryCategory")))
                        categoryPicker("secondarySubcategoryTwo", children(category("secondaryCategory")))
                    }
                }.storebenchPlaceholder(!editor.informationReady)
                }
                // Content Rights and Category are reviewed together, so their one Prepare Review sits in the Category card's footer.
                StorebenchFormFooter {
                    if let draft {
                        LocalDraftActions(editor: draft, value: editor.localDraft, restore: { editor.restoreLocalDraft($0); review = nil }, blocked: busy,
                                          sync: { await prepareInformation() }, syncBlocked: !editor.informationChanged)
                    }
                }
            }
        }
    }

    private var ageCard: some View {
        Card(title: "Age Rating", subtitle: "Check each answer against your app's content. Apple calculates the displayed rating.") {
            StorebenchFeedback(text: ageStatus, height: 40)
            if editor.ageReady || reading(editor.ageReady) {
            StorebenchActionGroup {
                Button("All None") { editor.chooseAllAges(frequency: "NONE"); review = nil }.help("Answer None to every content question")
                Button("All Infrequent") { editor.chooseAllAges(frequency: "INFREQUENT"); review = nil }.help("Answer Infrequent to every content question")
                Button("All Frequent") { editor.chooseAllAges(frequency: "FREQUENT"); review = nil }.help("Answer Frequent to every content question")
                Button("All No") { editor.chooseAllAges(flag: false); review = nil }.help("Answer No to every yes or no question")
                Button("All Yes") { editor.chooseAllAges(flag: true); review = nil }.help("Answer Yes to every yes or no question")
            }.storebenchWorking(!editor.ageReady)
            StorebenchFormGrid(maximumColumns: 3) {
                ForEach(AgeRating.frequency, id: \.0) { key, label in
                        StorebenchPicker(label, selection: ageBinding(key, emptyClears: false)) {
                            SelectionOption("Choose an answer", value: "")
                            SelectionOption("None", value: "NONE"); SelectionOption("Infrequent", value: "INFREQUENT"); SelectionOption("Frequent", value: "FREQUENT")
                            if let current = editor.ageValue(key)?.text, ["INFREQUENT_OR_MILD", "FREQUENT_OR_INTENSE"].contains(current) {
                                SelectionOption("Current Apple answer · \(AgeRating.describe(.string(current)))", value: current)
                            }
                        }
                }
                ForEach(AgeRating.boolean, id: \.0) { key, label in
                        StorebenchPicker(label, selection: Binding(get: { editor.ageValue(key) == .bool(true) ? "yes" : editor.ageValue(key) == .bool(false) ? "no" : "" }, set: {
                            editor.chooseAge(key, $0 == "yes" ? .bool(true) : $0 == "no" ? .bool(false) : nil); review = nil
                        })) { SelectionOption("Choose an answer", value: ""); SelectionOption("No", value: "no"); SelectionOption("Yes", value: "yes") }
                }
                ageOptions("kidsAgeBand", AgeRating.kidsValues, emptyClears: true)
                ageOptions("ageRatingOverrideV2", AgeRating.globalValues)
                ageOptions("koreaAgeRatingOverride", AgeRating.koreaValues)
                StorebenchTextField("Age rating information URL", text: ageBinding("developerAgeRatingInfoUrl", emptyClears: true), placeholder: "Optional HTTPS URL")
            }.storebenchPlaceholder(!editor.ageReady)
            }
            Text("\(editor.ageChanges.count) \(editor.ageChanges.count == 1 ? "answer" : "answers") changed for review.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            StorebenchFormFooter {
                if let draft {
                    LocalDraftActions(editor: draft, value: editor.localDraft, restore: { editor.restoreLocalDraft($0); review = nil }, blocked: busy,
                                      sync: { await prepareAges() }, syncBlocked: !editor.ageReady || editor.ageChanges.isEmpty)
                }
            }
        }
    }

    private var accessibilityCard: some View {
        Card(title: "Accessibility", subtitle: "Self-reported accessibility features, per device family. Saving an Apple draft and publishing it require separate reviews.") {
            StorebenchFeedback(text: accessibilityStatus, height: 40)
            StorebenchPicker("Device family", selection: $family) { selectionOptions(AccessibilityDeclarations.families) { SelectionOption($0.1, value: $0.0) } }.storebenchFormColumn().onChange(of: family) { review = nil }
            if editor.accessibilityReady || reading(editor.accessibilityReady) {
                let records = (editor.declarations ?? []).filter { $0.family == family && $0.state != "REPLACED" }
                Text(records.isEmpty ? "No declaration for this device family." : records.map { "\($0.state.capitalized) declaration" }.joined(separator: " · ")).font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                    .storebenchPlaceholder(!editor.accessibilityReady)
            }
            if editor.accessibilityReady || reading(editor.accessibilityReady) {
                StorebenchActionGroup {
                    ForEach([("All No", false), ("All Yes", true)], id: \.0) { title, value in
                        Button(title) { for feature in AccessibilityDeclarations.applicable(family) { editor.chooseAccessibility(family, feature.key, value) }; review = nil }
                            .help("Answer \(value ? "Yes" : "No") to every feature for this device family")
                    }
                }.storebenchWorking(!editor.accessibilityReady)
            }
            if editor.accessibilityReady || reading(editor.accessibilityReady) { ForEach(AccessibilityDeclarations.applicable(family), id: \.key) { feature in
                StorebenchPicker(feature.label, selection: Binding(get: { editor.answers(for: family)[feature.key].map { $0 ? "yes" : "no" } ?? "" }, set: {
                    editor.chooseAccessibility(family, feature.key, $0 == "yes" ? true : $0 == "no" ? false : nil); review = nil
                })) { SelectionOption("Not answered", value: ""); SelectionOption("Yes", value: "yes"); SelectionOption("No", value: "no") }.storebenchFormColumn()
                    .storebenchPlaceholder(!editor.accessibilityReady)
            } }
            let count = AccessibilityDeclarations.applicable(family).filter { editor.answers(for: family)[$0.key] != nil }.count
            Text("\(count) of \(AccessibilityDeclarations.applicable(family).count) features answered for this draft.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            let canDelete = editor.accessibilityReady && editor.draft(for: family) != nil
            if let draft {
                LocalDraftActions(editor: draft, value: editor.localDraft, restore: { editor.restoreLocalDraft($0); review = nil }, blocked: busy,
                                  sync: { await prepareAccessibility("save-draft") }, syncBlocked: !editor.canSaveAccessibility(family))
            }
            StorebenchFormFooter {
                Button("Review Publication") { Task { await prepareAccessibility("publish-draft") } }.storebenchWorking(!editor.canPublishAccessibility(family))
                    .help(editor.canPublishAccessibility(family) ? "Prepare Publication Review" : "Save a complete draft at Apple first").accessibilityLabel("Prepare Publication Review")
                Button("Review Deletion", role: .destructive) { Task { await prepareAccessibility("delete-draft") } }.storebenchWorking(!canDelete)
                    .help(canDelete ? "Prepare Deletion Review" : "There is no draft to delete").accessibilityLabel("Prepare Deletion Review")
            }
        }
    }

    private var availabilityCard: some View {
        Card(title: "Availability", subtitle: "Review one country or region at a time. Apple controls regional restrictions and when distribution becomes available.") {
            if let error = editor.information?.availabilityError { Text(error).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
            Text("Future App Store territories: \(editor.information?.availableInNewTerritories.map { $0 ? "Automatically added" : "Not automatically added" } ?? "Unavailable")").font(.sbCallout)
            Text("Future territories, pre-orders and unknown pre-order settings are managed under Pricing and Availability → App Availability in App Store Connect.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            if editor.informationReady && editor.information?.availabilityError == nil {
            StorebenchTextField("Search countries", text: $query).storebenchFormColumn()
            StorebenchCollection(items: editor.ordinaryTerritories.filter { query.isEmpty || (WorkspaceSession.countryName($0.id) + " " + $0.id).range(of: query, options: [.caseInsensitive, .literal]) != nil }, title: { WorkspaceSession.countryName($0.id) }, subtitle: { $0.available ? "Selected at Apple" : "Not selected at Apple" }, empty: query.isEmpty ? "No supported region changes are available." : "No countries or regions match. Change or clear the search.") { territory in
                HStack {
                    Text(WorkspaceSession.countryName(territory.id)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(territory.available ? "Selected at Apple" : "Not selected at Apple").foregroundStyle(StorebenchTheme.muted)
                    Button(territory.available ? "Review Removal" : "Review Selection") { Task { await prepareRegion(territory) } }.buttonStyle(StorebenchButtonStyle(.quiet))
                }
            }
            } else if reading(editor.informationReady) {
                StorebenchTextField("Search countries", text: .constant("")).storebenchFormColumn().storebenchPlaceholder()
                ForEach(0..<5, id: \.self) { _ in
                    HStack { Text("Country or region name"); Spacer(); Text("Not selected at Apple"); Button("Review Selection") {}.buttonStyle(StorebenchButtonStyle(.quiet)) }.storebenchPlaceholder()
                }
            } else if !editor.informationReady { notReady }
        }
    }

    private var notReady: some View {
        Text(working ? "Reading from App Store Connect…" : "Not read from App Store Connect yet. Use Refresh above.")
            .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
    }
    private func category(_ field: String) -> String? { editor.categories[field] ?? nil }
    private func categoryPicker(_ field: String, _ options: [AppCategory], optional: Bool = true) -> some View {
        StorebenchPicker(["primaryCategory": "Primary category", "secondaryCategory": "Secondary category (optional)", "primarySubcategoryOne": "Primary subcategory 1", "primarySubcategoryTwo": "Primary subcategory 2", "secondarySubcategoryOne": "Secondary subcategory 1", "secondarySubcategoryTwo": "Secondary subcategory 2"][field] ?? "Category", selection: Binding(get: { category(field) ?? "" }, set: { editor.chooseCategory(field, $0.isEmpty ? nil : $0); review = nil })) {
            SelectionOption(optional ? "None" : "Choose primary category", value: "")
            if let current = category(field), !options.contains(where: { $0.id == current }) { SelectionOption("Current Apple choice · \(AppInformation.categoryName(current))", value: current) }
            // A category already chosen in the paired field is left out rather than shown unavailable.
            selectionOptions(options.filter { option in !((field == "secondaryCategory" && option.id == category("primaryCategory")) ||
                (field == "primarySubcategoryTwo" && option.id == category("primarySubcategoryOne")) || (field == "secondarySubcategoryTwo" && option.id == category("secondarySubcategoryOne"))) }) { option in
                SelectionOption(AppInformation.categoryName(option.id), value: option.id)
            }
        }
    }
    private func ageBinding(_ key: String, emptyClears: Bool) -> Binding<String> {
        Binding(get: { editor.ageValue(key)?.text ?? "" }, set: { editor.chooseAge(key, $0.isEmpty ? (emptyClears ? .null : nil) : .string($0)); review = nil })
    }
    private func ageOptions(_ key: String, _ values: [String], emptyClears: Bool = false) -> some View {
        StorebenchPicker(AgeRating.label(key), selection: ageBinding(key, emptyClears: emptyClears)) {
            SelectionOption(emptyClears ? "None" : "Choose an override", value: "")
            selectionOptions(values) { SelectionOption(AgeRating.describe(.string($0)), value: $0) }
        }
    }

    private func load(fresh: Bool = false) async {
        await ScreenReads.reading(fresh: fresh) {
            attempted = true
            guard let session, !busy else { return }
            working = true; defer { working = false }
            if review?.state == "prepared" { review = nil }
            do {
                let client = try await session.readClient(for: account)
                if parts.contains(.categories) || parts.contains(.availability) {
                    do { let loaded = try await session.appInformationState(appId: app.id, categories: parts.contains(.categories), availability: parts.contains(.availability), client: client); try Task.checkCancellation(); editor.receive(loaded); status = "" }
                    catch { try Task.checkCancellation(); editor.informationFailed(); status = AppInformation.loadMessage(error, subject: "App Information") + " Your changes are retained." }
                }
                if parts.contains(.ageRating) {
                    do { let answers = try await session.ageRatingAnswers(appId: app.id, client: client); try Task.checkCancellation(); editor.receiveAgeAnswers(answers); ageStatus = "" }
                    catch { try Task.checkCancellation(); editor.ageFailed(); ageStatus = AppInformation.loadMessage(error, subject: "age rating answers") + " Your changes are retained." }
                }
                if parts.contains(.accessibility) {
                    do { let declarations = try await session.accessibilityDeclarations(appId: app.id, client: client); try Task.checkCancellation(); editor.receiveDeclarations(declarations); accessibilityStatus = "" }
                    catch { try Task.checkCancellation(); editor.accessibilityFailed(); accessibilityStatus = "Accessibility declarations are unavailable. Refresh to retry; your changes are retained." }
                }
            } catch {
                guard !Task.isCancelled else { return }
                editor.informationFailed(); editor.ageFailed(); editor.accessibilityFailed(); status = "App Information could not be loaded. Refresh to retry; your changes are retained."
            }
            if !editor.dirty, editor.informationReady || editor.ageReady || editor.accessibilityReady { history?.rememberRead(editor, readKey) }
        }
    }

    private func prepareInformation() async {
        guard let request = editor.informationRequest(accountId: account.id, appId: app.id) else { return }
        await prepare(request, part: .categories)
    }
    private func prepareAccessibility(_ action: String) async {
        guard editor.accessibilityReady else { return }
        var request = PublishRequest(accountId: account.id, appId: app.id, scope: .accessibility)
        request.accessibilityAction = action; request.accessibilityFamily = family
        if action == "save-draft" { request.accessibilityAnswers = AccessibilityDeclarations.applicable(family).compactMap { feature in editor.answers(for: family)[feature.key].map { (feature.key, $0) } } }
        await prepare(request, part: .accessibility)
    }
    private func prepareAges() async {
        guard editor.ageReady, !editor.ageChanges.isEmpty else { return }
        var request = PublishRequest(accountId: account.id, appId: app.id, scope: .ageRating); request.ageRatingChanges = editor.orderedAgeChanges
        await prepare(request, part: .ageRating)
    }
    private func prepareRegion(_ territory: TerritoryAvailability) async {
        guard editor.informationReady, editor.information?.availabilityError == nil, territory.supportsOrdinaryChange else { return }
        var request = PublishRequest(accountId: account.id, appId: app.id, scope: .availability)
        request.territoryId = territory.id; request.territoryAvailable = !territory.available
        await prepare(request, part: .availability)
    }
    private func prepare(_ request: PublishRequest, part: Part) async {
        guard let session, !busy else { return }
        working = true; review = nil; reviewPart = part; defer { working = false }
        if part != .exportCompliance, let draft {
            guard await draft.save(editor.localDraft), !draft.dirty(editor.localDraft) else { status = draft.status; return }
        }
        do { let prepared = try await session.preparePublishing(account: account, request: request, client: try await session.client(for: account)); try Task.checkCancellation(); review = prepared; status = "" }
        catch {
            guard !Task.isCancelled else { return }
            status = (error as? PublishFailure)?.message ?? "The review could not be prepared. Nothing was sent to App Store Connect."
        }
    }
}
