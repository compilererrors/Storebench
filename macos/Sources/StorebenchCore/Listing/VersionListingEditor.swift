import Foundation
import Observation

extension WorkspaceSession {
    /// Confirms the captured plan and reads its exact material under plan-before-draft protection.
    public func versionListingMaterial(accountId: String, appId: String, revisionId: String, versionId: String, planToken: String) throws -> Revision {
        try withReleaseTextPlan(accountId: accountId, appId: appId, revisionId: revisionId, token: planToken) { plan, store in
            guard plan.baseVersionId.utf8.elementsEqual(versionId.utf8) else { throw ReleaseTextFailure.stale }
            _ = try archivedRevision(accountId: accountId, appId: appId, id: revisionId, store: store)
            return try readReleaseTextDocuments(accountId: accountId, appId: appId, revisionId: revisionId, store: store) { source, draft in
                guard source.schemaVersion == 1, source.id == revisionId, source.app.id == appId,
                      source.versions.contains(where: { $0.id == versionId && $0.platform == plan.platform }) else { throw ReleaseTextFailure.invalid }
                return Self.overlay(source, draft: draft)
            }
        }
    }
}

/// All languages keep their text, layouts and pending originals even when their sections are closed.
@MainActor @Observable public final class VersionListingEditor {
    public struct Language: Identifiable {
        public let locale: String, text: LanguageDraftEditor, media: [MediaListingEditor]
        public var id: String { locale }
    }
    public let scope: MediaDraftScope, versionId: String, planEditor: ReleasePlanEditor
    public let workflow: ListingSaveWorkflow
    public private(set) var revision: Revision?
    public private(set) var version: Revision.Version?
    public private(set) var languages: [Language] = []
    public private(set) var loading = false { didSet { workflow.changed() } }
    public private(set) var adding = false { didSet { workflow.changed() } }
    public private(set) var catalogFailed = false { didSet { workflow.changed() } }
    public private(set) var status = ""
    public private(set) var active = true
    public var auxiliaryBusy = false { didSet { workflow.changed() } }
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    @ObservationIgnored private let session: WorkspaceSession
    @ObservationIgnored private var registration: UUID?
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var planObserver: UUID?
    @ObservationIgnored private var operation: UUID?
    public var dirty: Bool { workflow.dirty }
    public var busy: Bool { loading || adding || auxiliaryBusy || workflow.busy || planEditor.busy || languages.contains { $0.text.busy || $0.media.contains { $0.busy } } }
    /// The first item marked in red across every language, named so it can be found, or nil when nothing is marked.
    public var unsavedItem: String? {
        for language in languages {
            let name = StoreLocales.name(language.locale)
            if language.text.needsComparison { return name + " text changed elsewhere. Compare the latest save in " + name + "." }
            for media in language.media { if let item = media.unsavedItem { return name + " · " + item } }
        }
        if catalogFailed { return "The planned listing could not be read. Choose Read Saved Listing." }
        return nil
    }
    public var matchesPlan: Bool {
        planEditor.active && planEditor.plan.map { $0.accountId == scope.accountId && $0.appId == scope.appId && $0.sourceRevisionId == scope.revisionId && $0.baseVersionId == versionId } == true
    }
    public var availableLocales: [String] { StoreLocales.codes.filter { code in version?.localizations.contains { $0.locale.utf8.elementsEqual(code.utf8) } != true } }

    /// Whether each language gets its screenshot and preview editors. Quick Release edits text only and leaves them out.
    public let includesMedia: Bool
    public init(planEditor: ReleasePlanEditor, session: WorkspaceSession, media: Bool = true) throws {
        includesMedia = media
        guard planEditor.loaded, let plan = planEditor.plan else { throw ReleaseFailure.sourceUnavailable }
        self.planEditor = planEditor; self.session = session; versionId = plan.baseVersionId
        scope = .init(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId)
        workflow = ListingSaveWorkflow(identity: JSONText.array([.string(plan.accountId), .string(plan.appId), .string(plan.sourceRevisionId), .string(plan.baseVersionId)]).stringify())
        observer = workflow.observe { [weak self] in self?.didChange() }
        planObserver = planEditor.observe { [weak self] in self?.workflow.changed() }
        registration = workflow.register(priority: .text, state: { [weak self] in
            guard let self else { return .init(dirty: false, blocked: true, signature: "Retired version listing") }
            return .init(dirty: false, blocked: !self.active || self.loading || self.adding || self.auxiliaryBusy || self.catalogFailed || self.revision == nil ||
                !self.matchesPlan || !self.planEditor.ready || self.planEditor.dirty, signature: self.planEditor.expected ?? "Unread version plan")
        }, save: { true })
    }
    public func retire() {
        guard active else { return }; active = false; operation = nil; workflow.cancel()
        if let planObserver { planEditor.removeObserver(planObserver); self.planObserver = nil }
        if let observer { workflow.removeObserver(observer); self.observer = nil }
        if let registration { workflow.unregister(registration); self.registration = nil }
        for language in languages { language.text.retire(); language.media.forEach { $0.retire() } }
        loading = false; adding = false; didChange()
    }
    public func load() async {
        guard active, !busy, revision == nil || catalogFailed, !Task.isCancelled else { return }
        let ticket = UUID(); operation = ticket; loading = true
        defer { if owns(ticket) { operation = nil; loading = false } }
        do {
            try await refresh(ticket)
            guard owns(ticket) else { return }; catalogFailed = false; status = ""
        } catch {
            guard owns(ticket) else { return }; catalogFailed = true
            status = "The planned listing could not be confirmed. Read the saved listing again; existing edits are kept."
        }
    }
    public typealias Translate = TextTranslator
    /// Adds a language without replacing any existing editor or accepting another writer's baseline.
    /// With a translator, the copied wording is translated first, outside every draft lock.
    public func addLanguage(_ locale: String, copyFrom: String? = nil, translate: Translate? = nil) async -> Bool {
        guard active, !busy, matchesPlan, planEditor.ready, !planEditor.dirty, !catalogFailed, revision != nil, !Task.isCancelled,
              availableLocales.contains(where: { $0.utf8.elementsEqual(locale.utf8) }) else { return false }
        // Copying requires every source/destination editor to have a confirmed save.
        if copyFrom != nil, !workflow.ready { status = "Save all pending listing changes before copying a saved language."; return false }
        // A language that so far only has App Information text gains version text and media; its editor is rebuilt from the saved draft.
        if let existing = languages.first(where: { $0.locale.utf8.elementsEqual(locale.utf8) }), existing.text.dirty || existing.text.busy || existing.text.needsComparison {
            status = "Save the \(StoreLocales.name(locale)) App Information text before adding this language to the version."; return false
        }
        let ticket = UUID(); operation = ticket; adding = true
        defer { if owns(ticket) { operation = nil; adding = false } }
        do {
            var translation: LanguageTranslation?
            if let translate, let copyFrom {
                let request = try await session.translationRequest(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, versionId: versionId, sourceLocale: copyFrom)
                guard owns(ticket), !Task.isCancelled else { return false }
                do { translation = try request.translation(try await translate(request.segments)) }
                catch { guard owns(ticket) else { return false }; status = LanguageFailure.translationFailed.message; return false }
                guard owns(ticket), !Task.isCancelled else { return false }
            }
            let added = try await session.addLanguage(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, versionId: versionId, locale: locale, copyFrom: copyFrom, translation: translation)
            guard owns(ticket), !Task.isCancelled else { return true }
            try await refresh(ticket, added: (locale, added))
            status = translation == nil ? "Language added on this Mac. Existing editor inputs are kept."
                : "Language added on this Mac with translated text. The name and links are copied unchanged; read each translated field before sending it."
            return true
        } catch LanguageFailure.sourceChanged {
            guard owns(ticket) else { return false }; status = LanguageFailure.sourceChanged.message; return false
        } catch {
            guard owns(ticket) else { return false }
            status = (error as? LanguageFailure)?.message ?? "The language could not be confirmed. Existing edits are kept; read the saved listing again."
            catalogFailed = true; return false
        }
    }
    public func run(prepare: (@MainActor () async throws -> Void)? = nil) async -> ListingSaveWorkflow.Result {
        guard active, !Task.isCancelled else { return .init(id: UUID(), saves: 0, prepared: false, failure: .cancelled) }
        for language in languages {
            language.text.autosave.cancelPending()
            for media in language.media { for layout in media.screenshots.map(\.editor) + media.previews.map(\.editor) { layout.autosave.cancelPending() } }
        }
        let result = await workflow.run(prepare: prepare)
        guard active, workflow.owns(result) else { return result }
        switch result.failure {
        case nil: status = prepare == nil ? "All listing changes saved on this Mac." : "Confirm the changes in Sync to Apple."
        case .blocked: status = "Confirm the version plan and finish reading or comparing every language and media editor before continuing."
        case .changed: status = "Earlier changes were saved. Newer inputs or changed editor owners still need attention."
        case .save: status = "Saving stopped. Confirmed saves remain; unsaved text, layouts and selected originals are kept for retry."
        case .preparation: status = "The review could not be prepared. Local saves are kept; retry Upload after checking the saved listing."
        case .busy: status = "Wait for the current listing operation to finish."
        case .cancelled: status = "The operation stopped. Confirmed local saves remain available."
        }
        return result
    }
    public func publishingRequest() throws -> PublishRequest {
        guard active, matchesPlan, planEditor.ready, !planEditor.dirty, !workflow.dirty, !workflow.blocked else { throw PublishFailure.conflict }
        return try PublishRequest(accountId: scope.accountId, appId: scope.appId, scope: .metadata, targetMode: "release-plan", revisionId: scope.revisionId, versionId: versionId).validated()
    }
    public func reconcile(_ receipt: ReleaseTextSaveReceipt) {
        guard active, receipt.scope == scope else { return }
        for language in languages { _ = language.text.reconcile(receipt) }
    }
    private func owns(_ ticket: UUID) -> Bool { active && operation == ticket }
    /// Reads the planned listing. `added` is this editor's own confirmed language addition: only that locale may gain
    /// its new version section and media, and only when its editor has nothing unsaved. Any other change in structure is stale.
    private func refresh(_ ticket: UUID, added: (locale: String, localizationId: String)? = nil) async throws {
        guard matchesPlan, let token = planEditor.expected else { throw ReleaseTextFailure.stale }
        let source = try await session.versionListingMaterial(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, versionId: versionId, planToken: token)
        try Task.checkCancellation()
        guard owns(ticket), matchesPlan, token.utf8.elementsEqual((planEditor.expected ?? "").utf8),
              let version = source.versions.first(where: { $0.id == versionId }) else { throw ReleaseTextFailure.stale }
        var codes: [String] = []
        for code in version.localizations.map(\.locale) + source.appInfos.flatMap(\.localizations).map({ $0.fields["locale"]?.text ?? "" }) where !code.isEmpty {
            if !codes.contains(where: { $0.utf8.elementsEqual(code.utf8) }) { codes.append(code) }
        }
        guard !codes.isEmpty else { throw ReleaseTextFailure.invalid }
        var additions: [Language] = [], replaced: [String] = []
        do {
            for code in codes {
                let selections = try LanguageEditorState.selections(revision: source, versionId: versionId, locale: code)
                let localizations = Set(version.localizations.filter { $0.locale.utf8.elementsEqual(code.utf8) }.map(\.id))
                if let existing = languages.first(where: { $0.locale.utf8.elementsEqual(code.utf8) }) {
                    guard let editor = existing.text.editor else { throw ReleaseTextFailure.stale }
                    func held(_ next: LanguageDrafts.Selection) -> Bool { editor.selections.contains { $0.id.utf8.elementsEqual(next.id.utf8) && $0.scope == next.scope } }
                    if editor.selections.count == selections.count, selections.allSatisfy(held), !includesMedia || Set(existing.media.map(\.localizationId)) == localizations { continue }
                    let grown = selections.filter { !held($0) }
                    guard let added, added.locale.utf8.elementsEqual(code.utf8), !existing.text.dirty, existing.media.isEmpty,
                          editor.selections.count + 1 == selections.count, grown.count == 1, grown[0].scope == .version,
                          grown[0].id.utf8.elementsEqual(added.localizationId.utf8), localizations == [added.localizationId] else { throw ReleaseTextFailure.stale }
                    replaced.append(code)
                }
                let text = try LanguageDraftEditor(scope: scope, revision: source, versionId: versionId, locale: code, session: session, workflow: workflow)
                let media = !includesMedia ? [] : version.localizations.filter { $0.locale.utf8.elementsEqual(code.utf8) }.map {
                    MediaListingEditor(scope: scope, localization: $0, platform: version.platform, session: session, workflow: workflow)
                }
                let added = Language(locale: code, text: text, media: media); additions.append(added)
                await text.load(); for model in media { await model.load() }
                try Task.checkCancellation(); guard owns(ticket), text.editor != nil else { throw DraftFailure.invalid }
            }
            guard languages.allSatisfy({ old in codes.contains { old.locale.utf8.elementsEqual($0.utf8) } }), owns(ticket), matchesPlan,
                  token.utf8.elementsEqual((planEditor.expected ?? "").utf8),
                  replaced.allSatisfy({ code in languages.first { $0.locale.utf8.elementsEqual(code.utf8) }?.text.dirty == false }) else { throw ReleaseTextFailure.stale }
            for code in replaced {
                guard let index = languages.firstIndex(where: { $0.locale.utf8.elementsEqual(code.utf8) }),
                      let next = additions.firstIndex(where: { $0.locale.utf8.elementsEqual(code.utf8) }) else { continue }
                let old = languages[index]; languages[index] = additions.remove(at: next); old.text.retire()
            }
            languages += additions; revision = source; self.version = version
        } catch {
            for added in additions { added.text.retire(); added.media.forEach { $0.retire() } }; throw error
        }
    }
}
