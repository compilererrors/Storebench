import Foundation
import Observation

/// Owns every layout and selected file of one language, including sizes not currently shown.
@MainActor @Observable public final class MediaListingEditor {
    public struct ScreenshotLayout: Identifiable {
        public let id, displayType: String, editor: MediaLayoutEditor
    }
    public struct PreviewLayout: Identifiable {
        public let type: String, editor: MediaLayoutEditor
        public var id: String { type }
    }
    public let scope: MediaDraftScope, localizationId: String, platform: String, locale: String
    public let workflow: ListingSaveWorkflow
    public private(set) var screenshots: [ScreenshotLayout] = []
    public private(set) var previews: [PreviewLayout] = []
    public private(set) var screenshotSelections: [PendingScreenshotSelection] = []
    public private(set) var previewSelections: [PendingPreviewSelection] = []
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    public private(set) var loading = true { didSet { didChange() } }
    public private(set) var copying = false { didSet { didChange() } }
    public private(set) var catalogFailed = false { didSet { inputsChanged() } }
    public private(set) var active = true
    public var fileDialogOpen = false { didSet { inputsChanged() } }
    public private(set) var status = ""
    @ObservationIgnored private let session: WorkspaceSession
    @ObservationIgnored private let ownsWorkflow: Bool
    @ObservationIgnored private var registrations: [UUID] = []
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private let importedOrder: [String: [String]]
    private var syncedSignature: String?
    private var syncRevision = 0
    private var syncScope: LocalEditorDraft.Scope {
        .init(accountId: scope.accountId, appId: scope.appId, editor: "media-sync", resource: JSONText.array([.string(scope.revisionId), .string(localizationId)]).stringify())
    }
    public var syncSignature: String {
        JSONText.array((screenshots.map { ($0.id, $0.editor.inputs.signature) } + previews.map { ($0.id, $0.editor.inputs.signature) })
            .sorted { $0.0 < $1.0 }.map { .array([.string($0.0), .string($0.1)]) }).sha256
    }
    public var needsSync: Bool {
        if dirty { return true }
        if let syncedSignature { return syncSignature != syncedSignature }
        return screenshots.contains { $0.editor.includedOrder != (importedOrder[$0.id] ?? []) } || previews.contains { $0.editor.included > 0 }
    }
    /// A completed guarded review acknowledges only the exact media selection that was reviewed.
    public func acknowledgeSync(signature: String, review: PublishReview) async {
        guard active, review.state == "complete" || review.state == "prepared" && review.steps.isEmpty,
              review.request.accountId == scope.accountId, review.request.appId == scope.appId,
              (review.request.listingLocale == nil || review.request.listingLocale == locale),
              review.request.revisionId == scope.revisionId, review.request.mediaStage == PublishRequest.screenshotsStage else { return }
        guard let savedReview = try? await session.publishReview(accountId: scope.accountId, appId: scope.appId, id: review.id),
              savedReview.fingerprint == review.fingerprint, savedReview.state == review.state, savedReview.request == review.request else { return }
        do {
            let saved = try await session.saveLocalEditorDraft(.string(signature), scope: syncScope, expected: syncRevision)
            guard active else { return }; syncRevision = saved.revision; syncedSignature = signature
        } catch { /* A stale receipt never replaces another editor's acknowledgement. */ }
    }
    public var busy: Bool {
        loading || copying || fileDialogOpen || workflow.busy || screenshots.contains { $0.editor.busy } || previews.contains { $0.editor.busy } ||
        screenshotSelections.contains { $0.busy } || previewSelections.contains { $0.saving }
    }
    public var dirty: Bool {
        screenshots.contains { $0.editor.dirty } || previews.contains { $0.editor.dirty } ||
        screenshotSelections.contains { $0.dirty } || previewSelections.contains { $0.pending }
    }
    public var canRemoveScreenshots: Bool { active && !busy && !catalogFailed && screenshots.allSatisfy { $0.editor.canEditScreenshots } }
    /// Clears every display size of this language without changing previews or deleting originals.
    public func removeAllScreenshots() {
        guard canRemoveScreenshots else { return }
        for layout in screenshots { layout.editor.removeAllScreenshots() }
        status = "All screenshots removed from this language locally. Save to keep the changes, or add replacement screenshots to save the layout with them."
    }
    /// The item marked in red that keeps this language's media from saving, with its next step, or nil when nothing is marked.
    public var unsavedItem: String? {
        if let pending = screenshotSelections.first(where: { $0.dirty && !$0.busy }) {
            let count = pending.selection?.items.count
            let files = count == 1 ? "1 screenshot" : count.map { "\($0) screenshots" } ?? "The chosen screenshots"
            return files + " not added. " + (pending.problem.map { $0 + " Choose Fix Images… or Discard." } ?? "Choose Try Again or Discard.")
        }
        if let pending = previewSelections.first(where: { $0.pending && !$0.saving }) { return pending.name + " not added. Choose Try Again or Discard." }
        if catalogFailed { return "Saved screenshots could not be read. Choose Read Media." }
        if let layout = screenshots.first(where: { $0.editor.needsComparison || $0.editor.problem != nil }) {
            return StoreLocales.displayTypeName(layout.displayType) + " screenshots: " + (layout.editor.problem ?? "the saved order changed elsewhere. Compare the latest save.")
        }
        if let layout = previews.first(where: { $0.editor.needsComparison || $0.editor.problem != nil }) {
            return PreviewSpecs.name(layout.type) + " app previews: " + (layout.editor.problem ?? "the saved order changed elsewhere. Compare the latest save.")
        }
        return nil
    }
    public init(scope: MediaDraftScope, localization: Revision.Localization, platform: String, session: WorkspaceSession, workflow shared: ListingSaveWorkflow? = nil) {
        self.scope = scope; localizationId = localization.id; self.platform = platform; locale = localization.locale; self.session = session
        importedOrder = Dictionary(localization.screenshotSets.map { ($0.id, $0.screenshots.map(\.id)) }, uniquingKeysWith: { first, _ in first })
        ownsWorkflow = shared == nil
        workflow = shared ?? ListingSaveWorkflow(identity: JSONText.array([.string(scope.accountId), .string(scope.appId), .string(scope.revisionId), .string(localization.id)]).stringify())
        observer = workflow.observe { [weak self] in self?.didChange() }
        registrations.append(workflow.register(priority: .layout, state: { [weak self] in
            .init(dirty: false, blocked: self.map { !$0.active || $0.loading || $0.copying || $0.fileDialogOpen || $0.catalogFailed } ?? true, signature: "Media selection controls")
        }, save: { true }))
        for type in PreviewSpecs.types(platform: platform) {
            let key = JSONText.array([.string("previews"), .string(localization.id), .string(type)]).stringify(), localizationId = localization.id
            let model = MediaLayoutEditor(scope: scope, key: key, read: {
                .previews(localizationId: localizationId, type: type, draft: try await session.previewSet(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, localizationId: localizationId, type: type))
            }, save: { inputs, expected in
                .previews(localizationId: localizationId, type: type, draft: try await session.savePreviewLayout(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId,
                    localizationId: localizationId, type: type, order: inputs.order, hidden: inputs.order.filter(inputs.hidden.contains), posterTimes: inputs.posterTimes, expected: expected))
            })
            previews.append(.init(type: type, editor: model)); register(model)
        }
    }
    public func load() async {
        guard active, loading, !Task.isCancelled else { return }
        if let receipt = try? await session.localEditorDraft(syncScope) {
            syncedSignature = receipt.value.text; syncRevision = receipt.revision
        }
        do {
            let catalog = try await session.screenshotCatalog(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, localizationId: localizationId)
            try Task.checkCancellation(); guard active else { return }
            for draft in catalog where !screenshots.contains(where: { $0.id == draft.setId }) {
                addScreenshotLayout(id: draft.setId, displayType: draft.displayType, confirmed: .screenshots(draft))
            }
            catalogFailed = false
        } catch {
            guard active, !Task.isCancelled else { return }
            catalogFailed = true; status = "The saved screenshot catalog could not be read. Choose Read Media to retry; no media was saved."
        }
        for model in screenshots.map(\.editor) + previews.map(\.editor) {
            guard active, !Task.isCancelled else { return }; await model.load()
        }
        if active { loading = false }
    }
    public func retryCatalog() async {
        guard active, !busy, catalogFailed, !Task.isCancelled else { return }
        loading = true; await load()
    }
    public func retire() {
        guard active else { return }; active = false
        if let observer { workflow.removeObserver(observer); self.observer = nil }
        if ownsWorkflow { workflow.cancel() }
        for registration in registrations { workflow.unregister(registration) }; registrations = []
        for model in screenshots.map(\.editor) + previews.map(\.editor) { model.retire() }
        screenshotSelections.forEach { $0.retire() }; previewSelections.forEach { $0.retire() }
        loading = false; copying = false; fileDialogOpen = false
    }
    @discardableResult public func selectScreenshots(_ urls: [URL], setId: String? = nil, displayType: String? = nil) -> PendingScreenshotSelection? {
        guard active, !busy, (1...ScreenshotSpecs.maximum).contains(urls.count), urls.allSatisfy(\.isFileURL),
              setId == nil || screenshots.contains(where: { $0.id == setId && $0.displayType == displayType }) else { return nil }
        let scope = scope, session = session, localizationId = localizationId
        let selection = PendingScreenshotSelection(scope: scope, platform: platform, setId: setId, displayType: displayType, urls: urls, save: { [weak self] snapshot in
            guard let self else { throw CancellationError() }
            try await self.saveScreenshotLayoutsBeforeAdding()
            let receipt = try await session.addScreenshotsWithReceipt(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId,
                localizationId: localizationId, setId: setId, files: snapshot.items.map { ($0.name, $0.data) })
            self.reconcile(receipt); return receipt
        })
        screenshotSelections.append(selection)
        selection.didChange = { [weak self] in self?.inputsChanged() }
        registrations.append(workflow.register(priority: .file, state: { selection.state }, save: { await selection.save() }))
        return selection
    }
    @discardableResult public func selectPreview(_ file: URL, type: String) -> PendingPreviewSelection? {
        guard active, !busy, file.isFileURL, previews.contains(where: { $0.type == type }) else { return nil }
        let scope = scope, session = session, localizationId = localizationId
        let selection = PendingPreviewSelection(scope: scope, type: type, file: file, save: { [weak self] file in
            guard let self else { throw CancellationError() }
            try await self.saveLayoutsBeforeAdding(self.previews.map(\.editor))
            let receipt = try await session.addPreviewWithReceipt(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, localizationId: localizationId, type: type, file: file)
            self.reconcile(receipt); return receipt
        })
        previewSelections.append(selection)
        selection.didChange = { [weak self] in self?.inputsChanged() }
        registrations.append(workflow.register(priority: .file, state: { selection.state }, save: { await selection.save() }))
        return selection
    }
    /// Adds chosen screenshots to this language's draft on this Mac right away. Files that cannot be saved stay listed with their problem.
    @discardableResult public func addScreenshots(_ urls: [URL], setId: String? = nil, displayType: String? = nil) async -> PendingScreenshotSelection? {
        guard active, !workflow.busy else { if active { status = "Wait for the current save to finish, then add the files again." }; return nil }
        guard (1...ScreenshotSpecs.maximum).contains(urls.count) else { status = "Choose between 1 and \(ScreenshotSpecs.maximum) screenshots at a time."; return nil }
        guard let selection = selectScreenshots(urls, setId: setId, displayType: displayType) else { status = "Wait for the current save or read to finish, then add the files again."; return nil }
        status = ""
        if await selection.add(), active { status = selection.status }
        return selection
    }
    /// One file chosen from Asset Library: an original saved on this Mac, such as a card made in Create Media, or a file Apple
    /// already has, which keeps its Asset Library ID so a Save adds it to the version without uploading it again.
    public struct LibraryPick: Sendable { public let name: String, data: Data, assetId: String?
        public init(name: String, data: Data, assetId: String?) { self.name = name; self.data = data; self.assetId = assetId }
    }
    /// Adds screenshots chosen from Asset Library to this language's draft on this Mac right away.
    public func addFromLibrary(_ picks: [LibraryPick], setId: String? = nil) async {
        guard active, !busy, !workflow.blocked, !Task.isCancelled else { if active { status = "Finish or compare current media edits and selected files before adding from Asset Library." }; return }
        guard (1...ScreenshotSpecs.maximum).contains(picks.count) else { status = "Choose between 1 and \(ScreenshotSpecs.maximum) screenshots at a time."; return }
        copying = true; defer { if active { copying = false } }
        do {
            try await saveScreenshotLayoutsBeforeAdding()
            let receipt = try await session.addScreenshotsWithReceipt(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, localizationId: localizationId, setId: setId,
                                                                files: picks.map { ($0.name, $0.data) }, assetIds: picks.map(\.assetId))
            guard active else { return }; reconcile(receipt)
            status = "\(receipt.count) \(receipt.count == 1 ? "screenshot" : "screenshots") added from Asset Library on this Mac."
        } catch {
            guard active else { return }
            if let error = error as? ScreenshotFailure { status = error.message }
            else if let error = error as? DraftFailure { status = error.message }
            else { status = "The screenshots could not be added from Asset Library." }
        }
    }
    /// Adds a chosen app preview to this language's draft on this Mac right away.
    @discardableResult public func addPreview(_ file: URL, type: String) async -> PendingPreviewSelection? {
        guard active, !workflow.busy, let selection = selectPreview(file, type: type) else {
            if active { status = "Wait for the current save or read to finish, then add the video again." }; return nil
        }
        status = ""
        if await selection.save(), active { status = selection.status }
        return selection
    }
    /// Saves are local. The optional preparation only creates a review for the guarded Publish UI.
    public func run(prepare: (@MainActor () async throws -> Void)? = nil) async -> ListingSaveWorkflow.Result {
        guard active, !Task.isCancelled else { return .init(id: UUID(), saves: 0, prepared: false, failure: .cancelled) }
        for model in screenshots.map(\.editor) + previews.map(\.editor) { model.autosave.cancelPending() }
        let result = await workflow.run(prepare: prepare)
        guard active, workflow.owns(result) else { return result }
        switch result.failure {
        case nil: status = prepare == nil ? "Media draft saved on this Mac." : "Confirm the changes in Sync to Apple."
        case .blocked: status = "Finish selecting files and correct or compare the blocked editor before continuing."
        case .changed: status = "Earlier changes were saved. Newer edits or a changed media catalog still need attention."
        case .save: status = "The save stopped. Saved changes are kept; remaining selections and edits are available to retry."
        case .preparation: status = "The App Store review could not be prepared. Local saves are kept; retry Upload."
        case .busy: status = "Wait for the current save or read to finish."
        case .cancelled: status = "The operation stopped. Confirmed local saves remain available."
        }
        return result
    }
    public func copyScreenshots(from sourceId: String) async {
        await copy {
            try await self.session.copyScreenshotsWithReceipt(accountId: self.scope.accountId, appId: self.scope.appId, revisionId: self.scope.revisionId, targetId: self.localizationId, sourceId: sourceId)
        }
    }
    public func copyPreviews(from sourceId: String) async {
        await copy {
            try await self.session.copyPreviewsWithReceipt(accountId: self.scope.accountId, appId: self.scope.appId, revisionId: self.scope.revisionId, targetId: self.localizationId, sourceId: sourceId)
        }
    }
    private func copy(_ write: () async throws -> MediaAdditionReceipt) async {
        guard active, !busy, workflow.ready, !Task.isCancelled else {
            if active { status = "Save current media edits and selected files before copying another language." }; return
        }
        copying = true; defer { if active { copying = false } }
        do {
            let receipt = try await write(); guard active else { return }; reconcile(receipt)
            status = receipt.count == 0 ? "This media is already here." : "\(receipt.count) media files copied on this Mac."
        } catch {
            guard active else { return }
            if let error = error as? ScreenshotFailure { status = error.message }
            else if let error = error as? PreviewFailure { status = error.message }
            else if let error = error as? DraftFailure { status = error.message }
            else { status = "The media could not be copied locally." }
        }
    }
    private func register(_ model: MediaLayoutEditor) {
        model.didChange = { [weak self] in self?.inputsChanged() }
        registrations.append(workflow.register(priority: .layout, state: { model.state }, save: { await model.save() }))
    }
    /// A validated replacement batch needs the saved exclusions before checking the ten-image limit.
    /// Each save still compares its original baseline; a conflict keeps the batch available to retry.
    private func saveScreenshotLayoutsBeforeAdding() async throws {
        try await saveLayoutsBeforeAdding(screenshots.map(\.editor))
    }
    private func saveLayoutsBeforeAdding(_ layouts: [MediaLayoutEditor]) async throws {
        guard active, !Task.isCancelled, layouts.allSatisfy({ !$0.state.blocked }) else { throw ScreenshotFailure.stale }
        for layout in layouts where layout.dirty {
            guard await layout.save(), active, !Task.isCancelled else { throw ScreenshotFailure.stale }
        }
        guard active, !Task.isCancelled, layouts.allSatisfy({ !$0.dirty && !$0.state.blocked }) else { throw ScreenshotFailure.stale }
    }
    private func addScreenshotLayout(id: String, displayType: String, confirmed: MediaLayoutDraft? = nil) {
        let scope = scope, session = session, key = JSONText.array([.string("screenshots"), .string(id)]).stringify()
        let model = MediaLayoutEditor(scope: scope, key: key, draft: confirmed, read: {
            .screenshots(try await session.screenshotSet(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, setId: id))
        }, save: { inputs, expected in
            .screenshots(try await session.saveScreenshotLayout(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, setId: id,
                order: inputs.order, hidden: inputs.order.filter(inputs.hidden.contains), expected: expected))
        })
        screenshots.append(.init(id: id, displayType: displayType, editor: model)); register(model)
    }
    private func reconcile(_ receipt: MediaAdditionReceipt) {
        guard active, receipt.scope == scope else { return }
        for change in receipt.changes {
            if let model = (screenshots.map(\.editor) + previews.map(\.editor)).first(where: { $0.key.utf8.elementsEqual(change.after.key.utf8) }) {
                model.reconcile(change, scope: receipt.scope)
            } else if change.before == nil, case .screenshots(let draft) = change.after {
                addScreenshotLayout(id: draft.setId, displayType: draft.displayType, confirmed: change.after)
            }
        }
    }
    private func inputsChanged() { workflow.changed() }
}
