import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

/// App Encryption Documentation: declarations and their PDF, each sent through a review.
struct ExportComplianceCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let prepare: (PublishRequest) async -> Void
    var changed: () -> Void = {}
    /// Off where the page already offers App Store Connect's questions, so this card only lists declarations and their documents.
    var offersNewDeclaration = true
    @State private var declarations: [EncryptionDeclaration]?
    @State private var questions = EncryptionQuestionnaire()
    @State private var draft: LocalEditorDraftEditor?
    @State private var fileSelection = FileDialogSelection<String>()
    @State private var status = ""
    @State private var working = false

    var body: some View {
        Card(title: "App Encryption Documentation", subtitle: "Export compliance declarations for apps that use non-exempt encryption. Apple reviews each declaration.") {
            if declarations?.isEmpty == true { Text("This app has no declarations at Apple yet.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            if declarations == nil && status.isEmpty { Text("Reading Apple's declarations…").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            ForEach(declarations ?? []) { declaration in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        StorebenchTextSlot(text: declaration.description.isEmpty ? declaration.id : declaration.description, height: 34)
                        Text("\(AppStoreNames.state(declaration.state))\(declaration.platform.isEmpty ? "" : " · \(Releases.platformName(declaration.platform))")").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                    }
                    Spacer()
                    if ["CREATED", "IN_REVIEW"].contains(declaration.state) { Button("Upload PDF…") { changed(); fileSelection.begin(declaration.id) } }
                }
                StorebenchDivider()
            }
            if offersNewDeclaration {
                // App Store Connect's own questions; the description Apple's API needs is built from the answers.
                Text("New declaration").font(.sbHeadline)
                StorebenchChoicePicker(EncryptionAlgorithms.question, selection: $questions.algorithms, options: EncryptionAlgorithms.allCases.map { ($0.rawValue, $0.label) }, style: .radio).storebenchWorking(draft?.loaded != true)
                if let chosen = questions.chosen, !chosen.exempt {
                    StorebenchChoicePicker("Is your app going to be available on the App Store in France?", selection: $questions.france, options: [("yes", "Yes"), ("no", "No")], style: .radio).storebenchWorking(draft?.loaded != true)
                }
            }
            StorebenchFeedback(text: status, height: 40, error: !status.isEmpty)
            if offersNewDeclaration {
                let note = questions.needsDeclaration == false ? "Apple keeps no declaration for encryption within Apple's operating system or for standard encryption outside France. Answer it on the build's Export Compliance questions." : questions.missing ?? questions.nextStep
                Text(note).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                if let draft {
                    LocalDraftActions(editor: draft, value: questions.json, restore: { questions = EncryptionQuestionnaire(json: $0) }, blocked: working, sync: {
                        guard !draft.dirty(questions.json), let answers = questions.answers else { return }
                        var request = PublishRequest(accountId: account.id, appId: app.id, scope: .exportCompliance); request.encryptionDeclaration = answers
                        await prepare(request)
                    }, syncBlocked: questions.answers == nil)
                }
            }
        }
        .storebenchWorking(working)
        .onChange(of: questions) { changed() }
        .trackUnsavedChanges(draft?.dirty(questions.json) == true, busy: working || fileSelection.pending || draft?.busy == true, onSave: { await draft?.saveCurrent(value: { questions.json }) == true })
        .task {
            if offersNewDeclaration, let session {
                let owner = LocalEditorDraftEditor(scope: .init(accountId: account.id, appId: app.id, editor: "encryption-declaration", resource: "new"), session: session)
                draft = owner
                if let saved = await owner.load(initial: questions.json) { questions = EncryptionQuestionnaire(json: saved) }
            }
            await load()
        }
        .fileImporter(isPresented: $fileSelection.isPresented, allowedContentTypes: [.pdf]) { result in
            let declarationId = fileSelection.finish()
            guard !working, case .success(let url) = result, let declarationId, let session else { return }
            working = true
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { working = false; if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let revision = (try await session.stagedEncryptionDocument(accountId: account.id, appId: app.id, declarationId: declarationId))?.revision ?? 0
                    let files = try await SelectedFiles.readAsync([url], purpose: .encryptionDocument)
                    let staged = try await session.stageEncryptionDocument(accountId: account.id, appId: app.id, declarationId: declarationId, expectedRevision: revision, fileName: files[0].name, data: files[0].data)
                    var request = PublishRequest(accountId: account.id, appId: app.id, scope: .exportDocument); request.declarationId = declarationId; request.documentRevision = staged.revision
                    await prepare(request)
                } catch let failure as SelectedFiles.Failure { status = [.fileSize, .batchSize].contains(failure) ? "Choose a valid PDF up to 50 MB." : "The PDF could not be read. Choose a regular file and retry." }
                catch let failure as PublishFailure { status = failure.message } catch { status = "The PDF could not be saved." }
            }
        }
    }

    private func load() async {
        guard let session else { return }
        do {
            let client = try await session.readClient(for: account)
            let values = try await AppStoreReadCache.rereadingAfterInvalidation { try await session.encryptionDeclarations(appId: app.id, client: client) }
            try Task.checkCancellation(); declarations = values
        } catch {
            guard !Task.isCancelled else { return }
            declarations = nil; status = AppInformation.loadMessage(error, subject: "this app's encryption declarations")
        }
    }
}
