import StorebenchCore
import SwiftUI

/// A single listing save includes every language's text, layouts and pending files. The guide's next step sends them to Apple.
struct VersionListingView: View {
    let account: Account, planEditor: ReleasePlanEditor, session: WorkspaceSession?
    var focusedLocale: Binding<String?>? = nil
    var providedModel: VersionListingEditor? = nil
    /// After Save stored every language, such as Release continuing to the step that sends the text.
    var saved: (() -> Void)? = nil
    @State private var model: VersionListingEditor?
    @State private var operation: Task<Void, Never>?
    @State private var protectionId = UUID().uuidString
    @State private var newLocale = ""
    @State private var copyFrom = ""
    @State private var status = ""
    @State private var loadAttempt = 0
    @Environment(\.editorProtection) private var protection
    @Environment(\.releaseFieldFocus) private var fieldFocus
    @Environment(\.releaseChecklistReturn) private var backToChecklist
    private var identity: String { JSONText.array([.string(planEditor.accountId), .string(planEditor.appId), .string(planEditor.plan?.sourceRevisionId ?? ""), .string(planEditor.plan?.baseVersionId ?? "")]).stringify() }

    private static let readingLanguages = "Reading every saved language and media layout…"
    private func reloading(_ model: VersionListingEditor) -> Bool { model.loading && model.revision != nil && model.version != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let model {
                Card(title: "Languages", subtitle: "Edit each language below. Next saves everything on this Mac; nothing is sent to Apple in this step.", help: "release-material") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { actions(model) }
                        VStack(alignment: .leading, spacing: 12) { actions(model) }
                    }
                    let feedback = reloading(model) ? Self.readingLanguages : status.isEmpty ? model.status : status
                    if !feedback.isEmpty { StorebenchTextSlot(text: feedback, height: 40, font: .sbCallout, color: StorebenchTheme.muted, live: true) }
                    addLanguage(model)
                }
                if model.loading && !reloading(model) {
                    StorebenchLoadState(state: .loading(Self.readingLanguages)) { EmptyView() } placeholder: { StorebenchCollectionPlaceholder(rows: 3) }
                }
                if let revision = model.revision, let version = model.version {
                    if let languageLayout { LanguageLayoutControls(editor: languageLayout, accountId: account.id, appId: model.scope.appId, session: session) }
                    StorebenchCollection(items: model.languages, title: { StoreLocales.name($0.locale) },
                        subtitle: { $0.locale + ($0.text.dirty || $0.media.contains { $0.dirty } ? " · Unsaved changes" : " · Saved language and media") },
                        focusedID: model.languages.first { $0.locale == focusedLocale?.wrappedValue }?.id, empty: "No languages in this version yet. Choose a language under Add language above.") { language in
                            let scope = Editing(accountId: model.scope.accountId, appId: model.scope.appId, revisionId: model.scope.revisionId, local: false)
                            VStack(alignment: .leading, spacing: 16) {
                                LanguageEditor(account: account, revision: revision, version: version, scope: scope, locale: language.locale, targetMode: "release-plan", session: session,
                                    openReview: { _ in false }, providedModel: language.text, showUpload: false, contained: true)
                                let mediaAnchor = ReleaseReadiness.fieldAnchor(language.locale, "screenshots"), mediaFocused = fieldFocus?.anchor == mediaAnchor
                                VStack(alignment: .leading, spacing: 12) {
                                    if mediaFocused {
                                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                                            Text("Add screenshots for \(StoreLocales.name(language.locale)) below. They are saved on this Mac right away.").font(.sbCallout)
                                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                            if let backToChecklist { Button("Done", action: backToChecklist).help("Save this language and go back to the step’s list") }
                                        }
                                    }
                                    ForEach(language.media, id: \.localizationId) { media in
                                        if let localization = version.localizations.first(where: { $0.id == media.localizationId }) {
                                            MediaListingView(account: account, version: version, scope: scope, localization: localization, others: version.localizations.filter { $0.id != localization.id },
                                                targetMode: "release-plan", session: session, openReview: { _ in false }, providedModel: media, showActions: false)
                                        }
                                    }
                                }
                                .background { ReleaseFocusFrame(visible: mediaFocused) }
                                .animation(.easeInOut(duration: 0.3), value: mediaFocused)
                                .id(mediaAnchor)
                            }.padding(.top, 12)
                            .id(ReleaseReadiness.languageAnchor(language.locale))
                    }
                    if let plan = planEditor.plan {
                        ReleaseTextView(plan: plan, session: session, readiness: { [weak model] in
                            model.map { $0.active && !$0.busy && $0.workflow.ready && $0.matchesPlan } ?? false
                        }, onBusy: { [weak model] in model?.auxiliaryBusy = $0 }, onSaved: { [weak model] in model?.reconcile($0) })
                            .id("bulk-release-fields-\(model.scope.revisionId)/\(model.versionId)")
                    }
                }
            } else if status.isEmpty {
                StorebenchLoadState(state: .loading("Reading planned listing…")) { EmptyView() } placeholder: {
                    StorebenchPlaceholderCard(rows: 4)
                    StorebenchCollectionPlaceholder(rows: 3)
                }
            }
            else {
                StorebenchFeedback(text: status, height: 34)
                Button("Read Planned Listing") { status = ""; loadAttempt += 1 }
            }
        }
        .environment(\.draftWorkflowBusy, model?.busy == true)
        .task(id: "\(identity)/\(loadAttempt)") {
            guard let session, !Task.isCancelled else { return }
            do {
                let owner = try providedModel ?? VersionListingEditor(planEditor: planEditor, session: session), ownerId = protectionId
                owner.didChange = { [weak owner, weak editingProtection = protection] in
                    guard let owner, owner.active else { editingProtection?.remove(id: ownerId); return }
                    editingProtection?.policy.update(id: ownerId, dirty: owner.dirty, busy: owner.busy)
                }
                protection?.registerSave(id: ownerId, priority: -5, generation: String(describing: ObjectIdentifier(owner)), problem: { [weak owner] in
                    owner?.unsavedItem ?? (owner?.status.isEmpty == false ? owner?.status : nil)
                }) { [weak owner] in
                    guard let owner, owner.active, !owner.busy else { return false }
                    let result = await owner.run()
                    return result.complete && owner.active && !owner.dirty
                }
                model = owner; protection?.policy.update(id: protectionId, dirty: false, busy: true)
                await owner.load(); guard owner.active, !Task.isCancelled else { return }
                newLocale = owner.availableLocales.first ?? ""
            } catch { status = "The planned listing could not be opened. Confirm the saved version plan before continuing."; protection?.remove(id: protectionId) }
        }
        .onDisappear {
            operation?.cancel()
            if providedModel == nil { model?.retire() } else { model?.didChange = {} }
            protection?.remove(id: protectionId)
        }
    }
    @Environment(\.languageLayout) private var languageLayout
    @ViewBuilder private func actions(_ model: VersionListingEditor) -> some View {
        if model.catalogFailed || model.revision == nil {
            StorebenchBusyButton(title: "Read Saved Listing", loadingTitle: "Reading…", busy: model.busy) { operation = Task { await model.load() } }
        }
        StorebenchBusyButton(title: "Save", loadingTitle: "Saving…", busy: model.workflow.phase == .saving) { run(model) }.help("Save all languages on this Mac")
                .storebenchWorking(!(!model.workflow.blocked && (model.dirty || model.workflow.phase == .saving)))
    }
    @ViewBuilder private func addLanguage(_ model: VersionListingEditor) -> some View {
        if !model.availableLocales.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) { languageChoices(model) }
                VStack(alignment: .leading, spacing: 12) { languageChoices(model) }
            }.environment(\.fieldHintHeight, 0)
        }
    }
    @ViewBuilder private func languageChoices(_ model: VersionListingEditor) -> some View {
        StorebenchPicker("Add language", selection: $newLocale) { selectionOptions(model.availableLocales) { SelectionOption(StoreLocales.name($0), value: $0) } }.storebenchFormColumn()
        StorebenchPicker("Starting text and media", selection: $copyFrom) {
            SelectionOption("Start empty", value: "")
            selectionOptions(model.version?.localizations ?? []) { SelectionOption("Copy \(StoreLocales.name($0.locale))", value: $0.locale) }
        }.storebenchFormColumn()
        if !newLocale.isEmpty && (copyFrom.isEmpty || model.workflow.ready) {
            Button(model.adding ? "Adding…" : "Add Language") {
                let code = newLocale, source = copyFrom
                operation = Task {
                    let added = await model.addLanguage(code, copyFrom: source.isEmpty ? nil : source)
                    guard model.active, !Task.isCancelled else { return }
                    if added { newLocale = model.availableLocales.first ?? "" }; status = model.status
                }
            }.storebenchWorking(model.busy)
        }
    }
    private func run(_ model: VersionListingEditor) {
        guard model.active, !model.busy, !model.workflow.blocked else { return }
        status = ""
        operation = Task {
            guard model.active, !Task.isCancelled else { return }
            let result = await model.run()
            if result.complete, result.savedAny, !Task.isCancelled { saved?() }
        }
    }
}
