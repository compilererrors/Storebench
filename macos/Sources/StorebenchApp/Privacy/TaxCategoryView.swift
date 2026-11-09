import StorebenchCore
import SwiftUI

/// The app's tax category as App Store Connect has it, with Apple's categories, subcategories and conditions in its own words.
/// Read and saved with the Apple ID signed in for App Privacy, because the API key cannot set it; Save opens a review to approve first.
struct TaxCategoryView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let apple: AppleIDAccount?
    /// What App Store Connect showed at the last read, shown while the Apple ID is signed out.
    var saved: SectionCheck? = nil
    var done: () -> Void = {}
    /// Apple ended the Apple ID session.
    var ended: () -> Void = {}
    @Environment(LibraryModel.self) private var model
    @State private var draft: LocalEditorDraftEditor?
    @State private var state: AppTaxCategoryState?
    @State private var top = ""
    @State private var sub = ""
    @State private var conditions: [String] = []
    @State private var reading = false
    @State private var problem = ""

    private var catalog: TaxCategoryCatalog? { state?.catalog }
    private var chosen: String { sub.isEmpty ? top : sub }
    private var subcategories: [TaxCategoryCatalog.Category] { catalog?.category(top).map { item in item.subcategories.compactMap { catalog?.category($0) } } ?? [] }

    var body: some View {
        PricingReviewCard(title: "Tax Category", subtitle: "The tax category App Store Connect uses for the app. Apple applies App Store software until you choose another. Save opens a review to approve first.",
                          command: "Sync to Apple", account: account, app: app, session: session, blocked: blocked, request: request, done: { Task { await read() }; done() }, reviewIdentity: draftValue.sha256) {
            if let draft { LocalDraftActions(editor: draft, value: draftValue, restore: restoreDraft, blocked: reading) }
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                Fact(title: "Saved at Apple", value: state?.label ?? AppPrivacyView.lastRead(saved?.detail, saved), compact: true)
                Fact(title: "Conditions", value: state?.conditionsLabel ?? AppPrivacyView.lastRead(saved?.summary, saved), compact: true)
            }
            StorebenchTextSlot(text: reading ? "Reading the tax category from App Store Connect…" : apple == nil ? "Sign in with an Apple ID above to read and choose the tax category." : unsaved,
                               height: 20, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            if !problem.isEmpty { StorebenchAttention { Text(problem).fixedSize(horizontal: false, vertical: true) } }
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                StorebenchSearchPicker("Category", selection: Binding(get: { top }, set: { top = $0; sub = ""; conditions = [] })) {
                    selectionOptions(catalog?.top ?? []) { SelectionOption($0.name, value: $0.id) }
                }
                StorebenchSearchPicker("Subcategory", selection: Binding(get: { sub }, set: { sub = $0; conditions = conditions.filter(allowed.contains) }),
                                       hint: subcategories.isEmpty ? "This category has no subcategories." : catalog?.category(top)?.subcategoryRequired == true ? "Required for this category." : "Optional.") {
                    selectionOptions(subcategories) { SelectionOption($0.name, value: $0.id) }
                }.disabled(subcategories.isEmpty)
            }
            .storebenchWorking(reading || draft?.loaded != true)
            StorebenchCardSection(title: "Conditions") {
                if allowed.isEmpty {
                    Text("No conditions apply to this category.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(allowed, id: \.self) { id in
                    HStack(spacing: 8) {
                        StorebenchCheckbox(catalog?.conditionNames[id] ?? id, isOn: Binding(get: { conditions.contains(id) }, set: { on in
                            conditions.removeAll { $0 == id }; if on { conditions.append(id) }
                        }))
                        Text(catalog?.conditionNames[id] ?? id).font(.sbCallout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.storebenchWorking(reading || draft?.loaded != true)
        }
        .trackUnsavedChanges(draft?.dirty(draftValue) == true, busy: reading || draft?.busy == true, onSave: { await draft?.saveCurrent(value: { draftValue }) == true })
        .task(id: "\(account.id)/\(app.id)/\(apple?.signedInAt ?? "")") {
            await read()
            if draft == nil, let session {
                let owner = LocalEditorDraftEditor(scope: .init(accountId: account.id, appId: app.id, editor: "tax-category", resource: "selection"), session: session)
                draft = owner
                if let saved = await owner.load(initial: draftValue) { restoreDraft(saved) }
            }
        }
    }

    private var draftValue: JSONText { .object([("category", .string(top)), ("subcategory", .string(sub)), ("conditions", .array(conditions.sorted().map(JSONText.string)))]) }
    private func restoreDraft(_ value: JSONText) {
        top = value["category"]?.text ?? ""; sub = value["subcategory"]?.text ?? ""
        if case .array(let values)? = value["conditions"] { conditions = values.compactMap(\.text) }
    }
    private var allowed: [String] { chosen.isEmpty ? [] : catalog?.conditions(for: chosen) ?? [] }

    /// Whether the choice is what App Store Connect has now, counting Apple's default category as saved, as App Store Connect does.
    private var matchesApple: Bool {
        guard let state else { return false }
        let current = state.configured ? state.category : state.catalog.categories.first { $0.name == state.catalog.defaultName }?.id
        return current == chosen && Set(state.conditions) == Set(allowed.filter(conditions.contains))
    }
    /// Whether the choice differs from what App Store Connect has saved, so Save is still needed.
    private var unsaved: String {
        guard state != nil, !chosen.isEmpty else { return "" }
        return matchesApple ? "" : "This choice is not saved in App Store Connect yet."
    }

    private var blocked: String? {
        if apple == nil { return "Sign in with an Apple ID first. The API key cannot set the tax category." }
        if reading { return "Reading the tax category from App Store Connect…" }
        guard let catalog else { return "The tax category has not been read yet." }
        if top.isEmpty { return "Choose a category." }
        if !catalog.selectable(chosen) { return "Choose a subcategory." }
        if matchesApple { return "No changes to save. App Store Connect already has this tax category." }
        return nil
    }

    private func request() async throws -> PublishRequest {
        guard await draft?.save(draftValue) == true, draft?.dirty(draftValue) == false else { throw DraftFailure.stale }
        var value = PublishRequest(accountId: account.id, appId: app.id, scope: .taxCategory)
        value.taxCategory = TaxCategoryChoice(category: chosen, conditions: allowed.filter(conditions.contains))
        return value
    }

    private func read() async {
        guard let session, apple != nil else { state = nil; return }
        reading = true; defer { reading = false }
        do {
            let value = try await session.taxCategoryState(account: account, appId: app.id, writer: model.writer)
            state = value; problem = ""
            let current = value.category ?? value.catalog.categories.first { $0.name == value.catalog.defaultName }?.id ?? ""
            if draft?.dirty(draftValue) != true {
            if let parent = value.catalog.parent(of: current) { top = parent.id; sub = current } else { top = current; sub = "" }
            conditions = value.conditions
            }
        } catch AppleIDFailure.expired { state = nil; problem = ""; ended() }
        catch let failure as AppleIDFailure { problem = failure.message }
        catch let failure as PublishFailure { problem = failure.message }
        catch is CancellationError {}
        catch { problem = "The tax category could not be read from App Store Connect. Try again, or sign in again." }
    }
}
