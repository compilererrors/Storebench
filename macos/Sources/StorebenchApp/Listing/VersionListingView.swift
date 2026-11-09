import StorebenchCore
import SwiftUI

/// Local drafts and guarded Apple reviews are available beside every language's material.
struct VersionListingView: View {
    let account: Account, planEditor: ReleasePlanEditor, session: WorkspaceSession?
    var focusedLocale: Binding<String?>? = nil
    var providedModel: VersionListingEditor? = nil
    var didSync: () -> Void = {}
    @State private var model: VersionListingEditor?
    @State private var operation: Task<Void, Never>?
    @State private var protectionId = UUID().uuidString
    @State private var newLocale = ""
    @State private var copyFrom = ""
    @State private var translatable: Set<String> = []
    @State private var translation: ListingTranslationRequest?
    @State private var status = ""
    @State private var loadAttempt = 0
    @State private var review: PublishReview?
    @State private var publishing = false
    @Environment(\.editorProtection) private var protection
    @Environment(\.releaseFieldFocus) private var fieldFocus
    @Environment(\.releaseChecklistReturn) private var backToChecklist
    private var identity: String { JSONText.array([.string(planEditor.accountId), .string(planEditor.appId), .string(planEditor.plan?.sourceRevisionId ?? ""), .string(planEditor.plan?.baseVersionId ?? "")]).stringify() }

    private static let readingLanguages = "Reading every saved language and media layout…"
    private func reloading(_ model: VersionListingEditor) -> Bool { model.loading && model.revision != nil && model.version != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let model {
                Card(title: "Languages", subtitle: "Edit each language’s text, previews and screenshots below. Drafts stay on this Mac until you sync.", help: "release-material") {
                    let feedback = reloading(model) ? Self.readingLanguages : status.isEmpty ? model.status : status
                    if !feedback.isEmpty { StorebenchTextSlot(text: feedback, height: 40, font: .sbCallout, color: StorebenchTheme.muted, live: true) }
                    if model.catalogFailed { StorebenchReadButton("Read Saved Listing") { await model.load() } }
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
                                    openReview: { review = $0.review; return true }, providedModel: language.text, contained: true, didSync: didSync)
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
                                                targetMode: "release-plan", session: session, openReview: { review = $0.review; return true }, providedModel: media, didSync: didSync)
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
                        }, onBusy: { [weak model] in model?.auxiliaryBusy = $0 }, onSaved: { [weak model] in model?.reconcile($0) }, sync: { run(model, sync: true) })
                            .id("bulk-release-fields-\(model.scope.revisionId)/\(model.versionId)")
                    }
                }
                if let app = account.apps.first(where: { $0.id == model.scope.appId }) {
                    ReviewPanel(account: account, app: app, session: session, review: $review, done: { if review?.state == "complete" { didSync() } }, busyChanged: { publishing = $0 }, actionsBusy: model.busy || model.dirty || model.workflow.blocked, syncConfirmation: true)
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
        .environment(\.draftWorkflowBusy, model?.loading == true || model?.adding == true || model?.auxiliaryBusy == true || model?.workflow.busy == true || planEditor.busy || publishing)
        .onChange(of: model?.workflow.lastResult) {
            if review?.state == "prepared", model?.workflow.lastResult?.reviewReady != true { review = nil }
        }
        .listingTranslation(translation) { request, translate in
            guard let model else { return }
            await add(model, request.target, copyFrom: request.source, translate: translate)
        } finished: { translation = nil }
        .task(id: JSONText.array([.string(newLocale)] + (model?.version?.localizations ?? []).map { .string($0.locale) }).stringify()) {
            let sources = model?.version?.localizations.map(\.locale) ?? [], target = newLocale
            let found = await ListingTranslation.translatableSources(sources, target: target)
            guard !Task.isCancelled, target == newLocale else { return }
            translatable = found
            if let source = Self.translationSource(copyFrom), !found.contains(source) { copyFrom = "" }
        }
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
            selectionOptions((model.version?.localizations ?? []).filter { translatable.contains($0.locale) }) {
                SelectionOption("Translate \(StoreLocales.name($0.locale))", value: Self.translationPrefix + $0.locale)
            }
        }.storebenchFormColumn()
        .help("Translate uses Apple’s translation on this Mac. The name and links are copied unchanged.")
        if !newLocale.isEmpty && (copyFrom.isEmpty || model.workflow.ready) {
            let translating = Self.translationSource(copyFrom) != nil
            Button(model.adding || translation != nil ? (translating ? "Translating…" : "Adding…") : "Add Language") {
                let code = newLocale, source = copyFrom
                if let original = Self.translationSource(source) { translation = ListingTranslationRequest(source: original, target: code); return }
                operation = Task { await add(model, code, copyFrom: source.isEmpty ? nil : source) }
            }.storebenchWorking(model.busy || translation != nil)
        }
    }
    private static let translationPrefix = "translate:"
    private static func translationSource(_ choice: String) -> String? {
        choice.hasPrefix(translationPrefix) ? String(choice.dropFirst(translationPrefix.count)) : nil
    }
    private func add(_ model: VersionListingEditor, _ code: String, copyFrom source: String?, translate: VersionListingEditor.Translate? = nil) async {
        let added = await model.addLanguage(code, copyFrom: source, translate: translate)
        guard model.active, !Task.isCancelled else { return }
        if added { newLocale = model.availableLocales.first ?? ""; copyFrom = "" }; status = model.status
    }
    private func run(_ model: VersionListingEditor, sync: Bool = false) {
        guard model.active, !model.busy, !model.workflow.blocked, !publishing else { return }
        status = ""; review = nil
        operation = Task {
            guard model.active, !Task.isCancelled else { return }
            if let protection, !(await protection.saveAllDrafts()) {
                status = "Some changes could not be saved. Your edits are kept; check the form marked in red before syncing."
                return
            }
            var prepared: LanguageListingReview?, failure: String?
            let prepare: (@MainActor () async throws -> Void)?
            if sync {
                prepare = {
                    guard let session else { throw PublishFailure.conflict }
                    do {
                        let request = try model.publishingRequest()
                        let client = try await session.client(for: account)
                        prepared = try await session.prepareLanguageListingReview(account: account, request: request, client: client)
                    } catch { failure = (error as? PublishFailure)?.message; throw error }
                }
            } else { prepare = nil }
            let result = await model.run(prepare: prepare)
            guard model.active, !Task.isCancelled, model.workflow.owns(result) else { return }
            status = failure ?? model.status
            if result.reviewReady, model.workflow.ready,
               let prepared, prepared.matches(accountId: model.scope.accountId, appId: model.scope.appId, revisionId: model.scope.revisionId, versions: [model.versionId], targetMode: "release-plan") {
                review = prepared.review
            }
        }
    }
}
