import StorebenchCore
import SwiftUI

/// Local drafts and guarded Apple reviews are available beside every language's material.
struct VersionListingView: View {
    let account: Account, planEditor: ReleasePlanEditor, session: WorkspaceSession?
    var focusedLocale: Binding<String?>? = nil
    var providedModel: VersionListingEditor? = nil
    var didSync: () -> Void = {}
    var didCheck: () -> Void = {}
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
        VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
            if let model {
                Card(title: "Languages", subtitle: "Edit each language’s text, previews and screenshots below. Drafts stay on this Mac until you sync.", help: "release-material") {
                    let feedback = reloading(model) ? Self.readingLanguages : status.isEmpty ? model.status : status
                    if !feedback.isEmpty { StorebenchTextSlot(text: feedback, height: 40, font: .sbCallout, color: StorebenchTheme.muted, live: true) }
                    if model.catalogFailed { StorebenchActionGroup { StorebenchReadButton("Read Saved Listing") { await model.load() } } }
                    addLanguage(model)
                    if model.languages.count > 1 { allLanguages(model) }
                }
                if model.loading && !reloading(model) {
                    StorebenchLoadState(state: .loading(Self.readingLanguages)) { EmptyView() } placeholder: { StorebenchCollectionPlaceholder(rows: 3) }
                }
                if let revision = model.revision, let version = model.version {
                    AIListingTranslationView(account: account, appId: model.scope.appId, revisionId: model.scope.revisionId, version: version, session: session, model: model)
                        .id("\(model.scope.accountId)/\(model.scope.appId)/\(model.scope.revisionId)/ai/\(version.id)")
                    StorebenchCollection(items: model.languages, title: { StoreLocales.name($0.locale) },
                        subtitle: { $0.locale + ($0.text.dirty || $0.media.contains { $0.dirty } ? " · Unsaved changes" : " · Saved language and media") },
                        headerActions: { language in AnyView(HStack(spacing: StorebenchTheme.space(2)) {
                            if model.localOnlyLocalization(language.locale) != nil {
                                Button("Remove Language", role: .destructive) { remove(model, language.locale) }
                                    .help("Remove \(StoreLocales.name(language.locale)) from this version on this Mac. It is not in App Store Connect yet.")
                                    .storebenchWorking(model.busy || publishing)
                                    .storebenchControlID("language.remove." + language.locale)
                            }
                            if let languageLayout { LanguageLayoutControls(editor: languageLayout, accountId: account.id, appId: model.scope.appId, session: session, locale: language.locale) }
                        }) },
                        focusedID: model.languages.first { $0.locale == focusedLocale?.wrappedValue }?.id, empty: "No languages in this version yet. Choose a language under Add language above.") { language in
                            let scope = Editing(accountId: model.scope.accountId, appId: model.scope.appId, revisionId: model.scope.revisionId, local: false)
                            VStack(alignment: .leading, spacing: 16) {
                                LanguageEditor(account: account, revision: revision, version: version, scope: scope, locale: language.locale, targetMode: "release-plan", session: session,
                                    openReview: { review = $0.review; return true }, providedModel: language.text, contained: true, didSync: didSync, didCheck: didCheck)
                                let mediaAnchor = ReleaseReadiness.fieldAnchor(language.locale, "screenshots"), mediaFocused = fieldFocus?.anchor == mediaAnchor
                                VStack(alignment: .leading, spacing: 12) {
                                    if mediaFocused {
                                        ReleaseMediaEditingGuide(locale: language.locale, busy: language.media.contains { $0.busy },
                                            finish: backToChecklist.map { back in {
                                                operation = Task {
                                                    for media in language.media {
                                                        let result = await media.run(onlyThisPart: true)
                                                        guard result.complete, !Task.isCancelled else { return }
                                                    }
                                                    back()
                                                }
                                            } })
                                    }
                                    ForEach(language.media, id: \.localizationId) { media in
                                        if let localization = version.localizations.first(where: { $0.id == media.localizationId }) {
                                            MediaListingView(account: account, version: version, scope: scope, localization: localization, others: version.localizations.filter { $0.id != localization.id },
                                                targetMode: "release-plan", session: session, openReview: { review = $0.review; return true }, providedModel: media, didSync: didSync, didCheck: didCheck)
                                        }
                                    }
                                }
                                .id(mediaAnchor)
                            }.padding(.top, 12)
                            .id(ReleaseReadiness.languageAnchor(language.locale))
                    }
                    if let plan = planEditor.plan {
                        ReleaseTextView(plan: plan, session: session, languages: model.languages.map(\.locale), readiness: { [weak model] in
                            model.map { $0.active && !$0.busy && $0.workflow.ready && $0.matchesPlan } ?? false
                        }, onBusy: { [weak model] in model?.auxiliaryBusy = $0 }, onSaved: { [weak model] in model?.reconcile($0) }, sync: { run(model, sync: true) })
                            .id("bulk-release-fields-\(model.scope.revisionId)/\(model.versionId)")
                    }
                }
                if let app = account.apps.first(where: { $0.id == model.scope.appId }) {
                    ReviewPanel(account: account, app: app, session: session, review: $review, done: { if review?.state == "complete" { didSync() } }, busyChanged: { publishing = $0 }, actionsBusy: model.busy || model.workflow.shown.dirty || model.workflow.shown.blocked, syncConfirmation: true)
                }
            } else if status.isEmpty {
                StorebenchLoadState(state: .loading("Reading planned listing…")) { EmptyView() } placeholder: {
                    StorebenchPlaceholderCard(rows: 4)
                    StorebenchCollectionPlaceholder(rows: 3)
                }
            }
            else {
                StorebenchFeedback(text: status, height: 34)
                StorebenchActionGroup { Button("Read Planned Listing") { status = ""; loadAttempt += 1 } }
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
    @Environment(\.confirmDestructive) private var confirm
    /// One save and one review for every language, beside each language's own commands.
    @ViewBuilder private func allLanguages(_ model: VersionListingEditor) -> some View {
        let unsaved = model.languages.filter { $0.text.dirty || $0.media.contains { $0.dirty } }.map { StoreLocales.name($0.locale) }
        StorebenchTextSlot(text: unsaved.isEmpty ? "Every language is saved on this Mac." : "Unsaved changes: " + unsaved.joined(separator: ", "),
                           height: 40, font: .sbCallout, color: StorebenchTheme.muted, live: true)
        StorebenchFormFooter {
            StorebenchBusyButton(title: "Save All Drafts", loadingTitle: "Saving…", busy: model.workflow.phase == .saving) { run(model) }
                .help("Save the text and media of every language on this Mac")
                .storebenchWorking(unsaved.isEmpty || model.busy || model.workflow.shown.blocked || publishing)
                .storebenchControlID("languages.save-all")
            StorebenchBusyButton(title: "Sync All to Apple", loadingTitle: "Preparing…", busy: model.workflow.phase == .preparing, variant: .primary) { run(model, sync: true) }
                .help("Save every language, then review all language changes for App Store Connect in one approval")
                .storebenchWorking(model.busy || model.workflow.shown.blocked || publishing)
                .storebenchControlID("languages.sync-all")
        }
    }
    private func remove(_ model: VersionListingEditor, _ locale: String) {
        guard model.active, !model.busy, !publishing else { return }
        let name = StoreLocales.name(locale)
        guard confirm(.removeLanguage, title: "Remove \(name) from this version?",
                      message: "\(name) was added on this Mac and is not in App Store Connect. Its local text, screenshot and preview choices are removed, including unsaved edits. Other languages and saved media files are kept.",
                      action: "Remove Language") else { return }
        status = ""; review = nil
        operation = Task {
            _ = await model.removeLanguage(locale)
            guard model.active, !Task.isCancelled else { return }
            status = model.status
            if newLocale.isEmpty || !model.availableLocales.contains(newLocale) { newLocale = model.availableLocales.first ?? "" }
            if copyFrom == locale || Self.translationSource(copyFrom) == locale { copyFrom = "" }
        }
    }
    @ViewBuilder private func addLanguage(_ model: VersionListingEditor) -> some View {
        if !model.availableLocales.isEmpty {
            // One row when it fits, then both choices side by side with the command under them, then one column.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) { languagePickers(model); languageCommand(model) }
                VStack(alignment: .leading, spacing: 12) { HStack(alignment: .bottom, spacing: 12) { languagePickers(model) }; languageCommand(model) }
                VStack(alignment: .leading, spacing: 12) { languagePickers(model); languageCommand(model) }
            }.environment(\.fieldHintHeight, 0)
        }
    }
    @ViewBuilder private func languagePickers(_ model: VersionListingEditor) -> some View {
        StorebenchPicker("Add Language", selection: $newLocale) { selectionOptions(model.availableLocales) { SelectionOption(StoreLocales.name($0), value: $0) } }.storebenchFormColumn()
        StorebenchPicker("Starting Text and Media", selection: $copyFrom) {
            SelectionOption("Start empty", value: "")
            selectionOptions(model.version?.localizations ?? []) { SelectionOption("Copy \(StoreLocales.name($0.locale))", value: $0.locale) }
            selectionOptions((model.version?.localizations ?? []).filter { translatable.contains($0.locale) }) {
                SelectionOption("Translate \(StoreLocales.name($0.locale))", value: Self.translationPrefix + $0.locale)
            }
        }.storebenchFormColumn()
        .help("Translate uses Apple’s translation on this Mac. The name and links are copied unchanged.")
    }
    @ViewBuilder private func languageCommand(_ model: VersionListingEditor) -> some View {
        if !newLocale.isEmpty && (copyFrom.isEmpty || model.workflow.shown.ready) {
            let translating = Self.translationSource(copyFrom) != nil
            StorebenchFieldCommands {
                Button(model.adding || translation != nil ? (translating ? "Translating…" : "Adding…") : "Add Language") {
                    let code = newLocale, source = copyFrom
                    if let original = Self.translationSource(source) { translation = ListingTranslationRequest(source: original, target: code); return }
                    operation = Task { await add(model, code, copyFrom: source.isEmpty ? nil : source) }
                }.storebenchWorking(model.busy || translation != nil)
            }
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
                        prepared = try await session.prepareLanguageListingReview(account: account, request: request)
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
