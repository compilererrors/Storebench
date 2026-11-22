import StorebenchCore
import SwiftUI

/// One local save covers the app information and version text of the selected language.
struct LanguageEditor: View {
    let account: Account, revision: Revision, version: Revision.Version, scope: Editing, locale: String, targetMode: String, session: WorkspaceSession?
    let openReview: (LanguageListingReview) -> Bool
    var providedModel: LanguageDraftEditor? = nil
    var showActions = true
    var showUpload = true
    var contained = false
    /// A containing editor can keep a primary field beside its own commands.
    var omittedFields: Set<String> = []
    var onSummary: ((String) -> Void)? = nil
    var didSync: () -> Void = {}
    var didCheck: () -> Void = {}
    var reviewPreparer: @MainActor (WorkspaceSession, Account, PublishRequest) async throws -> LanguageListingReview = { session, account, request in
        try await session.prepareLanguageListingReview(account: account, request: request, client: try await session.client(for: account))
    }
    @State private var inlineReview: PublishReview?
    @State private var categories: [String] = []
    @State private var publishing = false
    @State private var latestReading = false
    @State private var model: LanguageDraftEditor?
    @State private var operation: Task<Void, Never>?
    @State private var observer: UUID?
    @State private var protectionId = UUID().uuidString
    @State private var initializationFailed = false
    @State private var status = ""
    @State private var saveFailed = false
    @State private var sources: [String: CopiedText.Review] = [:]
    @State private var sourceStatus = ""
    @State private var showChanges = false
    @State private var keywordField: LanguageEditorState.Field?
    @State private var changesSnapshot: LanguageEditorState?
    @State private var preparedReview: LanguageListingReview?
    @State private var preparedResult: ListingSaveWorkflow.Result?
    @State private var syncReceipt: (signature: String, time: Date, sent: Bool)?
    @State private var reviewedTextSignature: String?
    @State private var fallbackAutosave = DraftAutosave()
    /// App Store Connect shows no What's New for an app's first version on a platform, so the editor leaves it out too.
    @State private var firstVersion = false
    @Environment(\.editorProtection) private var protection
    @Environment(\.draftWorkflowBusy) private var inheritedBusy
    @Environment(\.editingPreferences) private var preferences
    @Environment(\.editorNavigation) private var navigation
    @Environment(\.languageLayout) private var layout
    @Environment(\.releaseFieldFocus) private var fieldFocus
    @Environment(\.releaseChecklistReturn) private var backToChecklist
    @Environment(\.pageScroll) private var pageScroll

    private var editor: LanguageEditorState? { model?.editor }
    private var autosave: DraftAutosave { model?.autosave ?? fallbackAutosave }
    private var changed: Bool { model?.dirty == true }
    private var saving: Bool { model?.saving == true }
    private var preparing: Bool { model?.workflow.phase == .preparing }
    private var reuseWorking: Bool {
        get { model?.auxiliaryBusy == true }
        nonmutating set { model?.auxiliaryBusy = newValue }
    }
    private var loadingDraft: Bool { (model == nil && !initializationFailed) || model?.loading == true }
    private var readingLatest: Bool { model?.readingLatest == true }
    private var failed: Bool { initializationFailed || model?.needsComparison == true || (model != nil && editor == nil && !loadingDraft) }
    private var ownBusy: Bool { model?.busy == true || model?.workflow.busy == true || loadingDraft || publishing }
    private var busy: Bool { ownBusy || inheritedBusy }
    private var editingBlocked: Bool { busy || failed }
    private var identity: String { "\(scope.accountId)/\(scope.appId)/\(scope.revisionId)/\(version.id)/\(locale)/\(targetMode)" }
    private var originalLabel: String { revision.isLocalDraft ? "starting draft" : "last Apple import" }
    private var differences: [SavedValueChange]? {
        guard let latest = model?.latest else { return nil }
        guard let editor else { return [] }
        let saved = Dictionary(uniqueKeysWithValues: latest.map { ($0.selection.id, $0.draft.fields) })
        return editor.fields.compactMap { field in
            let before = saved[field.selection.id]?[field.key] ?? "", after = editor.value(field)
            return before.utf8.elementsEqual(after.utf8) ? nil : .init(id: field.id, label: field.label, saved: before, edited: after)
        }
    }

    var body: some View {
        Group {
            if contained { draftContent }
            else { Card(title: "\(locale) language draft", subtitle: summary) { draftContent } }
        }
        .task(id: scope.appId) { categories = await session?.searchCategoryNames(account: account, appId: scope.appId) ?? [] }
        .task(id: identity) {
            firstVersion = (try? await session?.isFirstVersion(accountId: account.id, appId: revision.app.id, platform: version.platform, number: version.number)) ?? false
            await load()
        }
        .onChange(of: summary, initial: true) { onSummary?(summary) }
        .onChange(of: fieldFocus?.ticket, initial: true) { revealFocusedGroup() }
        .onChange(of: layout?.ready) { revealFocusedGroup() }
        .onChange(of: model?.workflow.lastResult) {
            if inlineReview?.state == "prepared", model?.workflow.lastResult?.reviewReady != true { inlineReview = nil }
        }
        .sheet(isPresented: Binding(get: { keywordField != nil }, set: { if !$0 { keywordField = nil; model?.dialogOpen = false } })) {
            if let field = keywordField, let appScope = try? RecoveryGuidance.Scope(accountId: scope.accountId, appId: scope.appId) {
                KeywordPickerView(scope: appScope, locale: locale, current: editor?.value(field) ?? "", session: session) { value in change(field, value); keywordField = nil; model?.dialogOpen = false }
            }
        }
        .sheet(isPresented: Binding(get: { changesSnapshot != nil }, set: { if !$0 { closeChanges() } })) {
            if let changesSnapshot {
                LanguageChangesView(editor: changesSnapshot, locale: locale, localDraft: revision.isLocalDraft, close: closeChanges)
            }
        }
        .onDisappear {
            operation?.cancel(); autosave.cancelPending()
            keywordField = nil; changesSnapshot = nil; model?.dialogOpen = false
            if let observer { model?.workflow.removeObserver(observer); self.observer = nil }
            if providedModel == nil { model?.retire() }
            protection?.remove(id: protectionId)
        }
        .autosaveDraft(autosave, identity: identity, signature: editor?.signature ?? "", enabled: preferences?.autosaveDrafts == true,
                       dirty: changed, blocked: busy || keywordField != nil || failed || editor == nil) { await save(automatic: true) }
        .pageRefreshParticipant(identity + "/" + (model.map { String(describing: ObjectIdentifier($0)) } ?? "loading"),
            state: { .init(dirty: changed, busy: ownBusy, signature: editor?.signature ?? "") },
            save: {
                guard let owner = model, owner.active, !ownBusy else { return false }
                return await owner.save()
            }, discard: {
                guard let owner = model, owner.active, !ownBusy else { return false }
                owner.autosave.cancelPending(); owner.revert(); preparedReview = nil; preparedResult = nil; inlineReview = nil
                return !owner.dirty
            }, refresh: {
                guard let owner = model, owner.active, !ownBusy, !owner.dirty else { return false }
                await owner.readLatest()
                guard owner.active, owner.latest != nil, !owner.dirty else { return false }
                owner.acceptLatest(keepEdits: false)
                owner.auxiliaryBusy = true; await refreshSources(owner); if owner.active { owner.auxiliaryBusy = false }
                let checked = await checkApple(); return checked && sourceStatus.isEmpty
            })
    }

    /// The same checks as the release step, live as you type.
    private var required: Set<String> { ReleaseMaterial.required(platform: version.platform, whatsNew: targetMode == "release-plan") }
    private func problem(_ field: LanguageEditorState.Field) -> String? {
        editor.flatMap { ReleaseMaterial.problem(field.key, value: $0.value(field), required: required.contains(field.key)) }
    }
    private func focused(_ field: LanguageEditorState.Field) -> Bool { fieldFocus?.anchor == ReleaseReadiness.fieldAnchor(locale, field.key) }
    private var summary: String {
        if failed { return "Read or compare the saved text before editing" }
        if loadingDraft { return "Reading saved language text…" }
        let count = editor?.fields.filter { editor?.differsFromImport($0) == true }.count ?? 0
        let over = editor?.fields.filter { TextDrafts.used($0.key, editor?.value($0) ?? "") > (TextDrafts.limits[$0.key] ?? .max) }.count ?? 0
        return (changed ? "Unsaved changes" : "Saved text") + " · \(count) \(count == 1 ? "field differs" : "fields differ")" + (over == 0 ? "" : " · \(over) over limit") + (busy ? " · Working" : "")
    }
    private var draftContent: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
            if failed { Text("The saved language text could not be confirmed. Read the latest save before continuing.").foregroundStyle(StorebenchTheme.muted) }
            StorebenchCardSection(title: "Language Fields · " + StoreLocales.name(locale)) { textFields }.storebenchLoading(loadingDraft ? "Reading saved language text…" : nil)
            if showActions {
                StorebenchEditorFooter(title: StoreLocales.name(locale) + " Text", detail: syncDetail,
                                      hint: showUpload ? "Save Draft keeps this language on your Mac. Sync to Apple opens the review for this language's text." : "Save this language's text on your Mac to continue later.",
                                      reservesStatusIcon: true, statusIcon: synced ? "check" : nil, statusColor: synced ? StorebenchTheme.color("color-success") : nil) {
                    StorebenchActionGroup(alignment: .trailing) { draftActions }
                }.storebenchControlID("language.sync-status." + locale)
            }
            if let app = account.apps.first(where: { $0.id == scope.appId }) {
                ReviewPanel(account: account, app: app, session: session, review: $inlineReview, done: finishedSync, busyChanged: { publishing = $0 }, actionsBusy: changed || failed || busy, syncConfirmation: true)
            }
            StorebenchCardSection(title: "Saved Baseline and Reused Text", accessory: AnyView(
                StorebenchIconButton(title: "Refresh Copied Sources", icon: "refresh") { Task { await readSources() } }.storebenchWorking(busy || failed)
            )) {
            LatestSaveReview(busy: busy, reading: latestReading, hasEdits: changed || failed, available: model != nil, changes: differences, note: nil, onRead: { Task { await readLatest() } },
                             onKeep: model?.latest == nil ? nil : { acceptLatest(keepEdits: true) }, onUse: model?.latest == nil ? nil : { acceptLatest(keepEdits: false) })
            TextReuseView(version: version, scope: scope, currentLocale: locale, session: session, hasUnsaved: changed || busy || failed,
                          changed: { operation = Task { await load(afterReuse: true) } }, onBusy: { reuseWorking = $0 }, readiness: { [weak model = model] in
                guard let model else { return false }; return model.active && !model.busy && !model.workflow.busy && !model.workflow.dirty && !model.workflow.blocked
            })
            statusTrack(sourceStatus, height: 20)
            }
        }
    }

    private var textFields: AnyView {
        guard let editor else { return AnyView(EmptyView()) }
        return AnyView(Group {
            StorebenchHeader {
                let differing = editor.fields.filter { editor.differsFromImport($0) }.count
                Text("\(differing) \(differing == 1 ? "field differs" : "fields differ") from the \(originalLabel)").font(.sbCallout)
            } actions: {
                StorebenchActionGroup(alignment: .trailing) {
                    Button("View Changes", action: openChanges).storebenchControlID("language.diff")
                        .storebenchWorking(busy || !hasDifferences).help("Compare all changed fields with the import or the loaded draft")
                    if !failed { StorebenchToggle("Show changed fields only", isOn: $showChanges).storebenchWorking(busy) }
                }
            }
            if !failed { ForEach(LanguageEditorLayout.Group.allCases, id: \.self) { group in
                let entries = group.fields.filter { !omittedFields.contains($0) && !(firstVersion && $0 == "whatsNew") }.flatMap { key in editor.shownFields.filter { $0.key == key } }
                if !entries.isEmpty {
                    if group != .copy { StorebenchDivider().padding(.vertical, StorebenchTheme.space(1)) }
                    DisclosureGroup(isExpanded: groupBinding(group)) {
                        if showChanges && !entries.contains(where: visible) { Text("No fields in this section differ from the \(originalLabel).").foregroundStyle(StorebenchTheme.muted) }
                        ForEach(Array(entries.filter(visible).enumerated()), id: \.element.id) { index, field in
                            if index > 0 { StorebenchDivider().padding(.vertical, 4) }
                            fieldEditor(field)
                        }
                    } label: {
                        HStack(spacing: StorebenchTheme.space(3)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.heading).font(.sbHeadline).fixedSize(horizontal: false, vertical: true)
                                Text(StoreLocales.name(locale) + " · " + entries.map(\.label).joined(separator: ", "))
                                    .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(groupSummary(entries)).font(.sbCaption).foregroundStyle(entries.contains { problem($0) != nil } ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true).frame(width: 120, alignment: .trailing)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        .storebenchControlID("language.section-toggle." + locale + "." + group.rawValue)
                    }.storebenchWorking(busy || layout?.ready == false)
                        .id(LanguageSectionNavigation.anchor(locale, group))
                        .storebenchControlID("language.section." + locale + "." + group.rawValue)
                }
            } }
            DisclosureGroup("View \(revision.isLocalDraft ? "starting" : "archived") text") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(editor.fields) { field in
                            Text(field.label).font(.sbCaption.weight(.semibold))
                            Text(editor.original(field).isEmpty ? "Empty" : editor.original(field)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 280)
            }
        })
    }
    @ViewBuilder private var draftActions: some View {
        Button("View Changes", action: openChanges).storebenchControlID("language.diff.footer")
            .storebenchWorking(busy || !hasDifferences)
        // Save Draft has something to do only with unsaved edits; Sync to Apple saves them first, and rests once Apple has this text.
        StorebenchBusyButton(title: "Save Draft", loadingTitle: "Saving…", busy: saving) { operation = Task { _ = await save() } }
            .storebenchControlID("language.save.\(locale)")
            .storebenchWorking(failed || session == nil || (!changed && !saving) || (busy && !saving))
            .help(changed ? "Save this language's text on your Mac" : "Everything is saved on this Mac")
        if showUpload && !failed && editor != nil && session != nil {
            StorebenchBusyButton(title: "Sync to Apple", loadingTitle: "Preparing…", busy: preparing || publishing, variant: .primary) { operation = Task { await prepare() } }
                .storebenchControlID("language.sync.\(locale)")
                .storebenchWorking((synced && !changed) || (busy && !preparing && !publishing))
                .help(synced && !changed ? "App Store Connect already has this language's text" : changed ? "Save your edits, then open the review that sends them to App Store Connect" : "Open the review that sends this language's text to App Store Connect")
        }
    }
    private var hasDifferences: Bool { editor.map { value in value.dirty || value.fields.contains { value.differsFromImport($0) } } == true }
    private func openChanges() {
        guard !busy, let editor, hasDifferences else { return }
        autosave.cancelPending(); changesSnapshot = editor; model?.dialogOpen = true
    }
    private func closeChanges() { changesSnapshot = nil; model?.dialogOpen = false }
    private func statusTrack(_ text: String, height: CGFloat, error: Bool = false) -> some View {
        StorebenchTextSlot(text: text, height: height, font: .sbCallout, color: error ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
    }
    private func visible(_ field: LanguageEditorState.Field) -> Bool {
        guard let editor else { return false }
        if !showChanges || editor.differsFromImport(field) || problem(field) != nil || focused(field) { return true }
        return sources[field.id].map { editor.sourceVisible($0) && $0.needsReview } ?? false
    }
    private func fieldEditor(_ field: LanguageEditorState.Field) -> AnyView {
        guard let editor else { return AnyView(EmptyView()) }
        let value = editor.value(field), used = TextDrafts.used(field.key, value), limit = TextDrafts.limits[field.key] ?? 0
        let title = editor.searchTitle
        let lint = field.key == "keywords" ? SearchLint(value, name: title.name, subtitle: title.subtitle, locale: locale, categories: categories) : nil
        let problem = problem(field), focused = focused(field), danger = StorebenchTheme.color("color-danger")
        return AnyView(VStack(alignment: .leading, spacing: 6) {
            // The label keeps the field's left edge; a problem follows it on the same line, so nothing below moves.
            HStack(spacing: 6) {
                Text(field.label).font(.sbCaption.weight(.semibold)).foregroundStyle(problem == nil ? StorebenchTheme.muted : danger).layoutPriority(1)
                if let problem, backToChecklist == nil {
                    StorebenchIcon(name: "warning", size: 12).foregroundStyle(danger).accessibilityHidden(true)
                    Text(problem).font(.sbCaption).foregroundStyle(danger).lineLimit(1).truncationMode(.tail).help(problem)
                }
                Spacer(minLength: StorebenchTheme.space(2))
                Text("\(used) / \(limit)\(field.key == "keywords" ? " bytes" : "")").font(.sbCaption.monospacedDigit()).foregroundStyle(used > limit ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
            }
            LanguageTextControl(field: field.key, label: field.label, text: Binding(get: { self.editor?.value(field) ?? "" }, set: { change(field, $0) }), focusRequest: focused ? fieldFocus?.ticket : nil)
                .storebenchControlID("language.field.\(locale).\(field.key)")
                .overlay(StorebenchControlOutline(border: problem == nil ? .clear : StorebenchTheme.color("color-danger-border")).allowsHitTesting(false))
            VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
                // Returning to the step's checklist keeps its status and Done command under each field.
                if backToChecklist != nil {
                    StorebenchActionRow {
                        HStack(alignment: .center, spacing: 8) {
                            StorebenchIcon(name: problem == nil ? "check" : "warning", size: 14).foregroundStyle(problem == nil ? StorebenchTheme.color("color-success") : danger)
                                .opacity(problem != nil || focused ? 1 : 0).accessibilityHidden(true)
                            StorebenchTextSlot(text: problem ?? (focused ? "Looks good. Done saves it and checks the step again." : ""), height: 34, font: .sbCallout, color: problem == nil ? StorebenchTheme.ink : danger, live: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } actions: {
                        if let backToChecklist {
                            StorebenchBusyButton(title: "Done", loadingTitle: "Saving…", busy: busy, variant: problem == nil ? .primary : .secondary) { operation = Task { await finishField(backToChecklist) } }
                                .help("Save this language and go back to the step’s list")
                                .storebenchControlID("language.done.\(locale).\(field.key)")
                                .opacity(focused ? 1 : 0).allowsHitTesting(focused).accessibilityHidden(!focused)
                        }
                    }
                }
                if editor.differsFromImport(field) {
                    DisclosureGroup("Compare \(field.label.lowercased()) with \(originalLabel)") {
                        LanguageTextComparison(before: editor.original(field), after: value, beforeLabel: revision.isLocalDraft ? "Starting text" : "Imported text", afterLabel: "Current editor")
                        Text("Updates this editor. Save the draft to keep it.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                        StorebenchActionGroup(alignment: .leading) {
                            Button(revision.isLocalDraft ? "Use Starting" : "Use Imported") { do { if let original = model?.editor?.original(field) { try model?.changeShown(field, to: original) }; preparedReview = nil; status = "" } catch { status = DraftFailure.invalid.message } }.help("Use \(revision.isLocalDraft ? "Starting" : "Imported") \(field.label)").accessibilityLabel("Use \(revision.isLocalDraft ? "Starting" : "Imported") \(field.label)")
                        }
                    }
                }
            }
            if let review = sources[field.id], editor.sourceVisible(review) {
                CopiedTextReviewView(review: review, disabled: editingBlocked || saving || !editor.canAcknowledge(review) || !sourceStatus.isEmpty) { Task { await acknowledge(review) } }
            }
            if let lint { keywordTools(field, lint: lint) }
        }
        .background { ReleaseFocusFrame(visible: focused, identifier: "language.focus.\(locale).\(field.key)") }
        .onChange(of: focused ? fieldFocus?.ticket : nil, initial: true) {
            // Once per request: a field shown again after the editor reloads, as after a save, leaves the page where it is.
            guard focused, let ticket = fieldFocus?.ticket, !StorebenchFocusRequests.applied(ticket, .page) else { return }
            StorebenchFocusRequests.record(ticket, .page)
            pageScroll?(ReleaseReadiness.fieldAnchor(locale, field.key), .center)
        }
        .id(ReleaseReadiness.fieldAnchor(locale, field.key)))
    }
    /// The keyword check and its commands as one group under the field: what can be improved, then one row of commands.
    private func keywordTools(_ field: LanguageEditorState.Field, lint: SearchLint) -> some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            if !lint.findings.isEmpty || !lint.nameAndSubtitle.isEmpty {
                let count = lint.findings.count + (lint.nameAndSubtitle.isEmpty ? 0 : 1)
                DisclosureGroup("Keyword check · \(count) \(count == 1 ? "suggestion" : "suggestions")\(lint.freedBytes > 0 ? " · \(lint.freedBytes) bytes can be freed" : "")") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(SearchLintPresentation.lines(lint), id: \.self) { Text($0).font(.sbCallout).fixedSize(horizontal: false, vertical: true) }
                            Text("These are suggestions; nothing changes until you choose Clean Up Keywords. Cleanup keeps your order and leaves possible overlaps in place.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 200)
                }
            }
            StorebenchActionGroup(alignment: .leading) {
                if lint.freedBytes > 0 {
                    Button("Clean Up Keywords") { change(field, lint.cleaned) }
                        .help("Remove repeated words, filler words and words already in the name or subtitle. Frees \(lint.freedBytes) bytes and keeps your order.")
                }
                Button("Choose Ideas") { autosave.cancelPending(); model?.dialogOpen = true; keywordField = field }.help("Choose Keyword Ideas").accessibilityLabel("Choose Keyword Ideas").storebenchWorking(saving)
                if navigation.navigate != nil { Button("Open Keyword Ideas") { navigation.open(.keywords, locale: locale) }.help("Open Keyword Ideas for this language").storebenchWorking(busy) }
            }
        }
    }
    private func change(_ field: LanguageEditorState.Field, _ value: String) {
        do { try model?.changeShown(field, to: value); preparedReview = nil; preparedResult = nil; syncReceipt = nil; inlineReview = nil; status = "" }
        catch { status = "Keep each local text field within 10,000 UTF-16 characters. Your previous text is retained." }
    }
    private func groupBinding(_ group: LanguageEditorLayout.Group) -> Binding<Bool> {
        Binding(get: { layout?.layout.isExpanded(group, locale: locale) ?? true }, set: { value in
            guard let layout, let session else { return }; layout.change([group: value], locale: locale)
            Task { await layout.flushScoped { patch, locale in try await session.saveLanguageEditorLayout(accountId: scope.accountId, appId: scope.appId, patch: patch, locale: locale) } }
        })
    }
    private func revealFocusedGroup() {
        guard let fieldFocus, let layout, layout.ready, let session,
              let field = editor?.fields.first(where: { ReleaseReadiness.fieldAnchor(locale, $0.key) == fieldFocus.anchor }),
              let group = LanguageEditorLayout.Group.allCases.first(where: { $0.fields.contains(field.key) }), !layout.layout.isExpanded(group, locale: locale) else { return }
        layout.change([group: true], locale: locale)
        Task { await layout.flushScoped { patch, locale in try await session.saveLanguageEditorLayout(accountId: scope.accountId, appId: scope.appId, patch: patch, locale: locale) } }
    }
    private func finishField(_ done: () -> Void) async {
        guard let owner = model, !busy, !failed else { return }
        let result = await owner.runText()
        guard owner.active, model === owner, !Task.isCancelled else { return }
        guard result.complete else { status = owner.problem ?? result.failure?.message ?? owner.status; return }
        status = owner.status; preparedReview = nil; preparedResult = nil
        done()
    }
    private func groupSummary(_ entries: [LanguageEditorState.Field]) -> String {
        guard let editor else { return "" }
        let dirty = entries.filter { editor.unsaved($0) }.count
        let over = entries.filter { TextDrafts.used($0.key, editor.value($0)) > (TextDrafts.limits[$0.key] ?? .max) }.count
        let reviews = entries.filter { field in sources[field.id].map { editor.sourceVisible($0) && $0.needsReview } ?? false }.count
        let problems = entries.filter { problem($0) != nil }.count
        let leading = problems > 0 ? "\(problems) to fix" : over > 0 ? "\(over) over limit" : reviews > 0 ? "\(reviews) source review" : ""
        return [leading, dirty > 0 ? "\(dirty) unsaved" : leading.isEmpty ? "\(entries.count) fields" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func load(afterReuse: Bool = false) async {
        guard let session, !Task.isCancelled else { return }
        do {
            if model == nil {
                initializationFailed = false
                protection?.policy.update(id: protectionId, dirty: false, busy: true)
                let owner: LanguageDraftEditor
                if let providedModel {
                    guard providedModel.active, providedModel.scope == .init(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId),
                          providedModel.versionId == version.id, providedModel.locale.utf8.elementsEqual(locale.utf8) else { throw DraftFailure.invalid }
                    owner = providedModel
                } else {
                    owner = try LanguageDraftEditor(scope: .init(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId),
                        revision: revision, versionId: version.id, locale: locale, session: session)
                }
                let ownerId = protectionId
                observer = owner.workflow.observe { [weak owner, weak editingProtection = protection] in
                    guard let owner, owner.active else { editingProtection?.remove(id: ownerId); return }
                    editingProtection?.policy.update(id: ownerId, dirty: owner.workflow.dirty, busy: owner.busy || owner.workflow.busy)
                }
                model = owner
                protection?.registerSave(id: ownerId, generation: String(describing: ObjectIdentifier(owner)), problem: { [weak owner, locale] in
                    guard let owner else { return nil }
                    if owner.needsComparison { return StoreLocales.name(locale) + " text changed elsewhere. Compare the latest save in its language draft." }
                    return owner.status.isEmpty ? nil : StoreLocales.name(locale) + " text: " + owner.status
                }) { [weak owner] in
                    guard let owner, owner.active, !owner.busy, !owner.workflow.busy else { return false }
                    let saved = await owner.save()
                    return saved && owner.active && !owner.workflow.dirty
                }
            }
            guard let owner = model, owner.active else { return }
            await owner.load(afterReuse: afterReuse)
            guard owner.active, model === owner, !Task.isCancelled, owner.editor != nil else { return }
            preparedReview = nil; preparedResult = nil; status = owner.status
            owner.auxiliaryBusy = true; await refreshSources(owner)
            if owner.active { owner.auxiliaryBusy = false }
        } catch {
            protection?.remove(id: protectionId)
            if !Task.isCancelled { initializationFailed = true; status = "The saved language editor could not be opened. Read the saved app material and try again." }
        }
    }
    private func save(automatic: Bool = false) async -> Bool {
        guard let owner = model, owner.active, !busy, !failed else { return false }
        let saved = await owner.save(automatic: automatic)
        guard owner.active, model === owner else { return saved }
        status = owner.status; saveFailed = !saved; preparedReview = nil; preparedResult = nil
        if saved, !Task.isCancelled {
            owner.auxiliaryBusy = true; await refreshSources(owner)
            if owner.active { owner.auxiliaryBusy = false }
        }
        return saved
    }
    private func readLatest() async {
        latestReading = true; defer { latestReading = false }
        if model == nil { await load(); return }
        guard let owner = model, owner.active, !busy else { return }
        preparedReview = nil; preparedResult = nil; await owner.readLatest()
        if owner.active, model === owner { status = owner.status }
    }
    private func acceptLatest(keepEdits: Bool) {
        guard let owner = model, owner.active, !busy, owner.latest != nil else { return }
        owner.acceptLatest(keepEdits: keepEdits); preparedReview = nil; preparedResult = nil; status = owner.status
        sources = [:]; operation = Task { await readSources() }
    }
    private func refreshSources(_ owner: LanguageDraftEditor) async {
        guard let session, let editor = owner.editor else { return }
        do {
            var result: [String: CopiedText.Review] = [:]
            for selection in editor.selections {
                let reviews = try await session.copiedTextReviews(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, localizationId: selection.id, scope: selection.scope, versionId: version.id)
                for (field, review) in reviews { result[selection.id + ":" + field] = review }
            }
            try Task.checkCancellation(); guard owner.active, model === owner else { return }
            sources = result; sourceStatus = ""
        } catch { if owner.active, model === owner { sourceStatus = "Copied source status could not be read. Refresh it before acknowledging comparisons." } }
    }
    private func readSources() async {
        guard let owner = model, owner.active, !busy, !failed, let session else { return }
        owner.auxiliaryBusy = true; defer { if owner.active { owner.auxiliaryBusy = false } }
        do { try await session.validateAccess(); await refreshSources(owner) }
        catch { if owner.active, model === owner { sourceStatus = "Copied source status could not be read." } }
    }
    private func acknowledge(_ review: CopiedText.Review) async {
        guard let owner = model, owner.active, !busy, !failed, owner.editor?.canAcknowledge(review) == true, let session else { return }
        owner.auxiliaryBusy = true; defer { if owner.active { owner.auxiliaryBusy = false } }
        do {
            try await session.acknowledgeCopiedText(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, review: review)
            await refreshSources(owner)
            if owner.active, model === owner { status = "Source comparison saved. Destination wording was preserved." }
        } catch let failure as CopiedTextFailure { if owner.active, model === owner { status = failure.message } }
        catch { if owner.active, model === owner { sourceStatus = "The source comparison could not be saved. Refresh and compare again." } }
    }
    private var canOpenPrepared: Bool {
        guard let owner = model, let preparedResult else { return false }
        // The parent's environment can still show this workflow's earlier busy frame after it has finished.
        // The owned workflow rechecks the selected language and required version/account gates synchronously.
        return owner.active && !owner.busy && !publishing && owner.publishingReady && owner.workflow.owns(preparedResult) && preparedResult.reviewReady
    }
    private func openPrepared(_ review: LanguageListingReview) {
        guard canOpenPrepared, let owner = model,
              review.matches(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, versions: [version.id], targetMode: targetMode),
              (try? owner.publishingRequest(targetMode: targetMode)) != nil else {
            status = "The language or version changed before its review opened. Your draft is kept. Choose Sync to Apple again."
            return
        }
        reviewedTextSignature = owner.editor?.signature; inlineReview = review.review
    }
    private func prepare() async {
        guard let owner = model, !busy, !failed, let session else { return }
        autosave.cancelPending(); preparedReview = nil; preparedResult = nil; inlineReview = nil
        syncReceipt = nil; status = "Saving this language and checking App Store Connect…"
        var review: LanguageListingReview?, failureMessage: String?, matches = false
        let result = await owner.runText(prepare: {
            do {
                var request = try owner.publishingRequest(targetMode: targetMode)
                request.mediaStage = PublishRequest.textStage
                review = try await reviewPreparer(session, account, request)
            } catch PublishFailure.noChanges { matches = true }
            catch {
                failureMessage = (error as? PublishFailure)?.message
                throw error
            }
        })
        guard owner.active, model === owner, !Task.isCancelled else { return }
        if result.reviewReady, owner.workflow.owns(result), owner.publishingReady, matches {
            confirmSync(sent: false); didCheck(); return
        }
        guard result.reviewReady, owner.workflow.owns(result), owner.publishingReady, let review else {
            status = failureMessage ?? owner.problem ?? (result.failure == .save && !owner.status.isEmpty ? owner.status : result.failure?.message ?? "The selected text changed. Prepare this language again.")
            return
        }
        preparedReview = review; preparedResult = result
        if review.review.steps.isEmpty { confirmSync(sent: false); didCheck(); return }
        status = review.versionSetup ? "Review Apple version creation first. Saved language text and media require a separate approval afterward." : "Confirm the changes in Sync to Apple."
        openPrepared(review)
    }
    private var synced: Bool { !ownBusy && !changed && syncReceipt?.signature == editor?.signature && syncReceipt != nil }
    private var syncDetail: String {
        if publishing || inlineReview?.state == "running" { return "Syncing this language’s text with App Store Connect…" }
        if synced, let receipt = syncReceipt {
            return (receipt.sent ? "Synced with Apple" : "Up to Date with Apple") + " · " + receipt.time.formatted(date: .omitted, time: .standard)
        }
        return status.isEmpty ? summary : status
    }
    private func confirmSync(sent: Bool) {
        guard let editor else { return }
        syncReceipt = (editor.signature, Date(), sent); status = ""
    }
    private func finishedSync() {
        if inlineReview?.state == "complete" {
            if !changed, reviewedTextSignature == editor?.signature { confirmSync(sent: true) }
            else { syncReceipt = nil; status = "Earlier text synced with Apple. Newer edits still need to be saved and reviewed." }
        }
        else if let review = inlineReview { syncReceipt = nil; status = review.error ?? "The sync stopped. Your draft is kept; choose Sync to Apple to compare the remaining changes." }
        // A stopped approval may have applied earlier steps, so its parent checks Apple again too.
        if inlineReview?.approvedAt != nil { didSync() }
    }
    private func checkApple() async -> Bool {
        guard let owner = model, let current = owner.editor, owner.active, !ownBusy, !failed, !owner.dirty, let session else { return false }
        status = "Checking this language’s saved text with App Store Connect…"; syncReceipt = nil
        owner.auxiliaryBusy = true; defer { if owner.active { owner.auxiliaryBusy = false } }
        do {
            var request = try current.publishingRequest(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, versionId: version.id, targetMode: targetMode)
            request.listingLocale = locale; request.mediaStage = PublishRequest.textStage
            let compared = try await reviewPreparer(session, account, request)
            guard owner.active, model === owner, !Task.isCancelled else { return false }
            inlineReview = nil; preparedReview = nil; preparedResult = nil
            if compared.review.steps.isEmpty { confirmSync(sent: false) }
            else { status = "Saved on this Mac · Changes to sync. Choose Sync to Apple to review them." }
            return true
        } catch PublishFailure.noChanges {
            guard owner.active, model === owner, !Task.isCancelled else { return false }
            inlineReview = nil; preparedReview = nil; preparedResult = nil; confirmSync(sent: false); return true
        } catch {
            guard owner.active, model === owner, !Task.isCancelled else { return false }
            status = "Apple’s current text could not be checked. Your local draft is kept. Try Refresh Status again."; return false
        }
    }

}

struct LanguageTextControl: View {
    let field: String, label: String
    @Binding var text: String
    var focusRequest: UUID? = nil
    private var long: Bool { ["description", "whatsNew", "promotionalText", "privacyPolicyText"].contains(field) }
    var body: some View {
        if long {
            StorebenchTextArea(text: $text, height: TextSurfacePresentation.initialHeight(field: field)).requestFocus(focusRequest).accessibilityLabel(label)
        } else { StorebenchTextField(label, text: $text).requestFocus(focusRequest).labelsHidden().accessibilityLabel(label) }
    }
}
private struct LanguageTextComparison: View {
    let before: String, after: String, beforeLabel: String, afterLabel: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StorebenchReadOnlyText(title: beforeLabel, text: before, height: 90)
            StorebenchReadOnlyText(title: afterLabel, text: after, height: 90)
        }
    }
}
