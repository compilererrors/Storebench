import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

/// One save covers this language's screenshot layouts, preview layouts and pending files.
struct MediaListingView: View {
    let account: Account, version: Revision.Version, scope: Editing, localization: Revision.Localization, others: [Revision.Localization]
    let targetMode: String, session: WorkspaceSession?, openReview: (LanguageListingReview) -> Bool
    var providedModel: MediaListingEditor? = nil
    var didSync: () -> Void = {}
    private enum FileTarget: Sendable { case screenshots(setId: String?, displayType: String?), preview(String) }
    private struct Prepared { let review: LanguageListingReview, result: ListingSaveWorkflow.Result }
    @State private var model: MediaListingEditor?
    @State private var fileSelection = FileDialogSelection<FileTarget>()
    @State private var choosingPreview = false
    @State private var upload: PendingScreenshotSelection?
    @State private var pickingFromLibrary = false
    @State private var prepared: Prepared?
    @State private var inlineReview: PublishReview?
    @State private var publishing = false
    @State private var reviewedSignature: String?
    @State private var operation: Task<Void, Never>?
    @State private var protectionId = UUID().uuidString
    @State private var observer: UUID?
    @Environment(\.editorProtection) private var protection
    @Environment(\.draftWorkflowBusy) private var inheritedBusy
    private var identity: String { "\(scope.accountId)/\(scope.appId)/\(scope.revisionId)/media/\(localization.id)/\(targetMode)" }
    var body: some View {
        Group {
            if let model {
                let currentReview = reviewedSignature == model.syncSignature
                VStack(alignment: .leading, spacing: 16) {
                    if model.catalogFailed { StorebenchReadButton("Read Media") { await model.retryCatalog() } }
                    PreviewsEditor(scope: scope, model: model, others: others, session: session, add: { begin(.preview($0)) })
                    ScreenshotsEditor(scope: scope, model: model, others: others, session: session, add: { begin(.screenshots(setId: $0, displayType: $1)) }, drop: { receive($0, setId: $1, displayType: $2) }, fix: { upload = $0 }, library: scope.local ? nil : { pickingFromLibrary = true })
                    if !scope.local {
                        StorebenchEditorFooter(title: "App Previews and Screenshots · " + StoreLocales.name(localization.locale),
                            detail: model.dirty ? "Unsaved media changes." : currentReview && inlineReview?.state == "complete" ? "Synced with Apple." : currentReview && inlineReview?.steps.isEmpty == true ? "Up to date with Apple." : model.status.isEmpty ? (model.needsSync ? "Saved on this Mac · Changes to sync." : "Your previews and screenshots are saved on this Mac.") : model.status,
                            hint: "Save Draft keeps changes on this Mac. Sync to Apple saves automatically and asks you to confirm the changes.") {
                            MediaDraftCommands(model: model, blocked: inheritedBusy || publishing, syncing: publishing, sync: { run(model, upload: true) })
                        }
                    }
                    if let app = account.apps.first(where: { $0.id == scope.appId }) {
                        ReviewPanel(account: account, app: app, session: session, review: $inlineReview, done: {
                            if let review = inlineReview, let signature = reviewedSignature {
                                Task {
                                    await model.acknowledgeSync(signature: signature, review: review)
                                    if review.state == "complete" { didSync() }
                                }
                            }
                        }, busyChanged: { publishing = $0 }, actionsBusy: model.busy || inheritedBusy || model.workflow.dirty || model.workflow.blocked, syncConfirmation: true)
                    }
                }
                .padding(StorebenchTheme.padding)
                .background(StorebenchTheme.surface, in: RoundedRectangle(cornerRadius: StorebenchTheme.radius))
            } else {
                StorebenchLoadState(state: .loading("Reading saved media…")) { EmptyView() } placeholder: {
                    VStack(alignment: .leading, spacing: 16) { StorebenchPlaceholderCard(rows: 3); StorebenchPlaceholderCard(rows: 6) }
                }
            }
        }
        .environment(\.draftWorkflowBusy, inheritedBusy || model?.workflow.busy == true || model?.copying == true || model?.fileDialogOpen == true || upload != nil || publishing)
        .onChange(of: model?.workflow.lastResult) {
            if inlineReview?.state == "prepared", model?.workflow.lastResult?.reviewReady != true { inlineReview = nil }
        }
        .trackUnsavedChanges(model?.dirty == true, busy: model?.busy == true, id: protectionId, generation: model.map { String(describing: ObjectIdentifier($0)) },
                             problem: { [weak model] in model?.unsavedItem.map { StoreLocales.name(localization.locale) + " · " + $0 } ?? (model?.status.isEmpty == false ? model?.status : nil) }, onSave: {
            guard let owner = model, owner.active, !owner.busy, !inheritedBusy, !scope.local else { return false }
            let result = await owner.run()
            return result.complete && owner.active && !owner.dirty
        })
        .task(id: identity) {
            guard let session, !Task.isCancelled else { return }
            let owner = providedModel ?? MediaListingEditor(scope: .init(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId), localization: localization, platform: version.platform, session: session)
            guard owner.active, owner.scope == .init(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId), owner.localizationId == localization.id, owner.platform == version.platform else { return }
            let ownerId = protectionId
            observer = owner.workflow.observe { [weak owner, weak editingProtection = protection] in
                guard let owner, owner.active else { editingProtection?.remove(id: ownerId); return }
                editingProtection?.policy.update(id: ownerId, dirty: owner.dirty, busy: owner.busy)
            }
            model = owner; protection?.policy.update(id: protectionId, dirty: false, busy: true)
            await owner.load()
            guard owner.active, !Task.isCancelled else { return }
            protection?.policy.update(id: protectionId, dirty: owner.dirty, busy: owner.busy)
        }
        .onDisappear {
            operation?.cancel(); upload?.setEditing(false)
            if let observer { model?.workflow.removeObserver(observer); self.observer = nil }
            if providedModel == nil { model?.retire() }
            protection?.remove(id: protectionId)
        }
        .shortcutAction(.chooseImages, enabled: model?.active == true && model?.busy == false && !inheritedBusy && !scope.local && upload == nil, identity: identity) { begin(.screenshots(setId: nil, displayType: nil)) }
        .dropDestination(for: URL.self) { urls, _ in receive(urls) }
        .clipShape(RoundedRectangle(cornerRadius: StorebenchTheme.radius))
        .fileImporter(isPresented: $fileSelection.isPresented, allowedContentTypes: choosingPreview ? [.mpeg4Movie, .quickTimeMovie, .movie] : [.png, .jpeg], allowsMultipleSelection: !choosingPreview) { result in
            let target = fileSelection.finish(); model?.fileDialogOpen = false
            guard let target, let model, model.active, !model.busy, case .success(let urls) = result,
                  let session, (try? session.validateAccess()) != nil else { return }
            // Chosen files are saved into the draft right away; problems stay visible in their media section.
            switch target {
            case .screenshots(let setId, let displayType): Task { await model.addScreenshots(urls, setId: setId, displayType: displayType) }
            case .preview(let type): if urls.count == 1, let url = urls.first { Task { await model.addPreview(url, type: type) } }
            }
        }
        .sheet(item: $upload) { selection in
            ScreenshotUploadSheet(model: selection, close: { upload = nil })
        }
        .sheet(isPresented: $pickingFromLibrary) {
            if let model, let session { AssetLibraryPicker(account: account, appId: scope.appId, session: session, model: .init(editor: model, setId: nil), close: { pickingFromLibrary = false }) }
        }
    }
    private func begin(_ target: FileTarget) {
        guard !scope.local, !inheritedBusy, let model, model.active, !model.busy, upload == nil, let session, (try? session.validateAccess()) != nil else { return }
        switch target { case .preview: choosingPreview = true; case .screenshots: choosingPreview = false }
        if fileSelection.begin(target) { model.fileDialogOpen = true }
    }
    private func receive(_ urls: [URL], setId: String? = nil, displayType: String? = nil) -> Bool {
        guard !scope.local, !inheritedBusy, let model, model.active, !model.busy, upload == nil, let session, (try? session.validateAccess()) != nil,
              !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        Task { await model.addScreenshots(urls, setId: setId, displayType: displayType) }; return true
    }
    private func run(_ model: MediaListingEditor, upload: Bool) {
        guard model.active, !model.busy, !inheritedBusy, !publishing, !scope.local else { return }
        prepared = nil; inlineReview = nil; operation?.cancel()
        operation = Task {
            guard model.active, !Task.isCancelled else { return }
            var review: LanguageListingReview?
            let result: ListingSaveWorkflow.Result
            if upload, let session {
                result = await model.run(prepare: {
                    var request = PublishRequest(accountId: scope.accountId, appId: scope.appId, scope: .metadata, targetMode: targetMode, revisionId: scope.revisionId, versionId: version.id)
                    request.mediaStage = PublishRequest.screenshotsStage
                    review = try await session.prepareLanguageListingReview(account: account, request: request, client: try await session.client(for: account))
                })
            } else { result = await model.run() }
            guard model.active, !Task.isCancelled, result.reviewReady, let review, model.workflow.owns(result), model.workflow.ready, !model.busy else { return }
            reviewedSignature = model.syncSignature
            let next = Prepared(review: review, result: result); prepared = next; open(next, model: model)
        }
    }
    private func open(_ prepared: Prepared, model: MediaListingEditor) {
        guard model.active, !model.busy, !inheritedBusy, model.workflow.ready, model.workflow.owns(prepared.result),
              prepared.review.matches(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, versions: [version.id], targetMode: targetMode) else { return }
        // Readiness and its close protection are updated synchronously before navigation.
        protection?.policy.update(id: protectionId, dirty: model.dirty, busy: model.busy)
        inlineReview = prepared.review.review
    }
}
