import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

/// One save covers this language's screenshot layouts, preview layouts and pending files.
struct MediaListingView: View {
    let account: Account, version: Revision.Version, scope: Editing, localization: Revision.Localization, others: [Revision.Localization]
    let targetMode: String, session: WorkspaceSession?, openReview: (LanguageListingReview) -> Bool
    var providedModel: MediaListingEditor? = nil
    var showActions = true
    private enum FileTarget: Sendable { case screenshots(setId: String?, displayType: String?), preview(String) }
    private struct Prepared { let review: LanguageListingReview, result: ListingSaveWorkflow.Result }
    @State private var model: MediaListingEditor?
    @State private var fileSelection = FileDialogSelection<FileTarget>()
    @State private var choosingPreview = false
    @State private var upload: PendingScreenshotSelection?
    @State private var pickingFromLibrary = false
    @State private var prepared: Prepared?
    @State private var operation: Task<Void, Never>?
    @State private var protectionId = UUID().uuidString
    @State private var observer: UUID?
    @Environment(\.editorProtection) private var protection
    @Environment(\.draftWorkflowBusy) private var inheritedBusy
    private var identity: String { "\(scope.accountId)/\(scope.appId)/\(scope.revisionId)/media/\(localization.id)/\(targetMode)" }
    /// Where the files chosen here end up, in App Store Connect's words, so it is clear what each Release part sends where.
    private var destinations: some View {
        Card(title: "Where these files go", subtitle: "") {
            VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
                StorebenchFact(label: "Here", value: "Choose and order this version's app previews and screenshots. They are saved on this Mac only.")
                StorebenchFact(label: "Asset Library", value: "Release step 3, part 1 (Upload) uploads new files there. Files Apple already has are reused, never uploaded again.")
                StorebenchFact(label: "App Previews and Screenshots", value: "Release step 3, part 2 (Save) adds them to this version in the order chosen here.")
            }
        }
    }
    var body: some View {
        Group {
            if let model {
                VStack(alignment: .leading, spacing: 16) {
                    if !scope.local && showActions { actions(model) }
                    if !scope.local { destinations }
                    PreviewsEditor(scope: scope, model: model, others: others, session: session, add: { begin(.preview($0)) })
                    ScreenshotsEditor(scope: scope, model: model, others: others, session: session, add: { begin(.screenshots(setId: $0, displayType: $1)) }, drop: { receive($0, setId: $1, displayType: $2) }, fix: { upload = $0 }, library: scope.local ? nil : { pickingFromLibrary = true })
                    if !scope.local && !showActions { inlineSave(model) }
                    if !scope.local { StorebenchFeedback(text: model.status, height: 40) }
                }
            } else {
                StorebenchLoadState(state: .loading("Reading saved media…")) { EmptyView() } placeholder: {
                    VStack(alignment: .leading, spacing: 16) { StorebenchPlaceholderCard(rows: 3); StorebenchPlaceholderCard(rows: 6) }
                }
            }
        }
        .environment(\.draftWorkflowBusy, inheritedBusy || model?.busy == true || upload != nil)
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
    @ViewBuilder private func actions(_ model: MediaListingEditor) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { saveActions(model) }
            VStack(alignment: .leading, spacing: 12) { saveActions(model) }
        }
        Text(model.workflow.blocked ? "Fix or discard the items marked in red before saving." : "Save keeps all media changes on this Mac. Upload saves them first, then prepares a concrete review in Publish.")
            .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        if let prepared, model.active, model.workflow.ready, model.workflow.owns(prepared.result) {
            Button("Open Review") { open(prepared, model: model) }.help("Open Prepared Review").accessibilityLabel("Open Prepared Review").storebenchWorking(model.busy || inheritedBusy)
        }
    }
    /// In a guided step the Save for this language's media sits right below its screenshots, so an unsaved change is never hidden.
    @ViewBuilder private func inlineSave(_ model: MediaListingEditor) -> some View {
        if !model.workflow.blocked && (model.dirty || model.workflow.phase == .saving) {
            StorebenchHeader {
                Text("Unsaved media changes for \(StoreLocales.name(localization.locale)).").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            } actions: {
                StorebenchBusyButton(title: "Save", loadingTitle: "Saving…", busy: model.busy || inheritedBusy, variant: .primary) { run(model, upload: false) }.help("Save Media on This Mac")
            }
        }
    }
    @ViewBuilder private func saveActions(_ model: MediaListingEditor) -> some View {
        if model.catalogFailed { StorebenchBusyButton(title: "Read Media", loadingTitle: "Reading…", busy: model.busy || inheritedBusy) { Task { await model.retryCatalog() } } }
        StorebenchBusyButton(title: "Save", loadingTitle: "Saving…", busy: model.busy || inheritedBusy, variant: .primary) { run(model, upload: false) }
            .storebenchWorking(model.workflow.blocked || !(model.dirty || model.workflow.phase == .saving))
        StorebenchBusyButton(title: "Upload", loadingTitle: "Preparing…", busy: model.busy || inheritedBusy) { run(model, upload: true) }
            .storebenchWorking(model.workflow.blocked)
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
        guard model.active, !model.busy, !inheritedBusy, !scope.local else { return }
        prepared = nil; operation?.cancel()
        operation = Task {
            guard model.active, !Task.isCancelled else { return }
            var review: LanguageListingReview?
            let result: ListingSaveWorkflow.Result
            if upload, let session {
                result = await model.run(prepare: {
                    let request = PublishRequest(accountId: scope.accountId, appId: scope.appId, scope: .metadata, targetMode: targetMode, revisionId: scope.revisionId, versionId: version.id)
                    review = try await session.prepareLanguageListingReview(account: account, request: request, client: try await session.client(for: account))
                })
            } else { result = await model.run() }
            guard model.active, !Task.isCancelled, result.reviewReady, let review, model.workflow.owns(result), model.workflow.ready, !model.busy else { return }
            let next = Prepared(review: review, result: result); prepared = next; open(next, model: model)
        }
    }
    private func open(_ prepared: Prepared, model: MediaListingEditor) {
        guard model.active, !model.busy, !inheritedBusy, model.workflow.ready, model.workflow.owns(prepared.result),
              prepared.review.matches(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, versions: [version.id], targetMode: targetMode) else { return }
        // Readiness and its close protection are updated synchronously before navigation.
        protection?.policy.update(id: protectionId, dirty: model.dirty, busy: model.busy)
        if openReview(prepared.review) { self.prepared = nil }
    }
}
