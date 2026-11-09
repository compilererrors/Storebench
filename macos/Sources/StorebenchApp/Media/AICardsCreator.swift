import AppKit
import StorebenchCore
import SwiftUI

struct AICardsCreator: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var selectScreenshots: @MainActor (Int) async throws -> [SelectedFiles.File] = MediaFileSelection.screenshots
    let opened: (WorkspaceSession.SavedMediaCardSet) -> Void
    @State private var name = ""
    @State private var brief = ""
    @State private var language = "en-US"
    @State private var provider = AIProvider.apple.rawValue
    @State private var modelID = ""
    @State private var targetId = MediaCards.defaultTarget.id
    @State private var shots: [MediaCard.Screenshot] = []
    @State private var draft: LocalEditorDraftEditor?
    @State private var working = false
    @State private var status = ""
    @State private var problem = false
    @State private var connections: [AIConnection] = []
    @State private var servicesLoaded = false
    private var executionSummary: String {
        guard let service = AIProvider(rawValue: provider) else { return "Choose an AI Service" }
        if service == .apple { return "Apple Intelligence · On This Mac" }
        let model = modelID.isEmpty ? connections.first(where: { $0.provider == service })?.model ?? "Not Connected" : modelID
        return service.title + " · " + model
    }
    private var generationIssue: String? {
        if !servicesLoaded { return "Checking the selected AI service…" }
        return AICards.generationIssue(name: name, brief: brief, screenshots: shots.count, provider: provider, connections: connections, localAvailable: AppleLocalAI.available)
    }
    private var draftValue: JSONText {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .object([("name", .string(name)), ("brief", .string(brief)), ("language", .string(language)), ("provider", .string(provider)), ("model", .string(modelID)), ("target", .string(targetId)),
            ("screenshots", (try? JSONText.parse(encoder.encode(shots))) ?? .null)])
    }
    private func restore(_ value: JSONText) {
        name = value["name"]?.text ?? ""; brief = value["brief"]?.text ?? ""; language = value["language"]?.text ?? "en-US"
        provider = value["provider"]?.text ?? AIProvider.apple.rawValue; targetId = value["target"]?.text ?? MediaCards.defaultTarget.id
        modelID = value["model"]?.text ?? ""
        shots = value["screenshots"].flatMap { try? JSONDecoder().decode([MediaCard.Screenshot].self, from: $0.data) } ?? []
    }
    var body: some View {
        Card(title: "AI Generate Cards from Screenshots", subtitle: "Describe the message and style in one or two sentences. AI proposes editable cards using your original screenshots.") {
            StorebenchTextField("Card Set Name", text: $name, hint: "Up to 80 characters")
            StorebenchTextArea(title: "What Should the Cards Convey? · \(brief.utf16.count)/2000", text: $brief, height: StorebenchTheme.textarea(rows: 3))
            StorebenchFormGrid {
                StorebenchPicker("Display Size", selection: $targetId) { selectionOptions(MediaCards.targets) { SelectionOption($0.label, value: $0.id) } }
                StorebenchPicker("Card Language", selection: $language) { selectionOptions(StoreLocales.codes) { SelectionOption(StoreLocales.name($0), value: $0) } }
            }
            AIServicePicker(session: session, selection: $provider, modelID: $modelID, sharedContent: "Your brief and selected screenshots", requiresImages: true, loaded: { connections = $0; servicesLoaded = true })
            StorebenchCardSection(title: "Screenshots") {
                Text("\(shots.count) of 10 selected. Their original pixels remain in the cards; AI chooses the text, order, layout and colors.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(shots.enumerated()), id: \.offset) { index, shot in
                    StorebenchStatusRow(title: shot.name, detail: "\(shot.width) × \(shot.height) px") { Text("Selected").font(.sbCaption) } action: { Button("Remove") { shots.remove(at: index) } } details: { EmptyView() }
                }
                StorebenchFormFooter { Button("Add Screenshots…") { choose() }.storebenchControlID("ai-cards.add-screenshots").storebenchWorking(shots.count >= 10) }
            }
            StorebenchTextSlot(text: status, height: 54, font: .sbCallout, color: problem ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
            if let draft {
                StorebenchEditorFooter(title: "AI Card Draft", detail: (draft.dirty(draftValue) ? "Unsaved changes." : "Draft saved on this Mac.") + " · " + executionSummary, hint: generationIssue ?? "Ready to generate. Your draft is saved automatically; matching completed AI results are reused.") {
                    StorebenchActionGroup {
                        Button("Save Draft") { Task { await saveDraft() } }.storebenchControlID("ai-cards.save-draft").storebenchWorking(draft.busy || draft.needsComparison)
                        Button("Generate Cards") { Task { await generate() } }.buttonStyle(StorebenchButtonStyle(.primary))
                            .storebenchControlID("ai-cards.generate")
                            .storebenchWorking(generationIssue != nil || draft.busy || draft.needsComparison)
                            .help(generationIssue ?? "Save the draft and generate editable cards with the selected AI service")
                    }
                }
                if draft.needsComparison { LocalDraftActions(editor: draft, value: draftValue, restore: restore, blocked: working) }
            }
        }.storebenchWorking(working || draft?.loaded != true)
        .trackUnsavedChanges(draft?.dirty(draftValue) == true, onSave: { await draft?.saveCurrent(value: { draftValue }) == true })
        .task {
            guard let session else { return }
            let owner = LocalEditorDraftEditor(scope: .init(accountId: account.id, appId: app.id, editor: "ai-cards", resource: "composer"), session: session); draft = owner
            if let saved = await owner.load(initial: draftValue) { restore(saved) }
            else if owner.syncSnapshot()?.revision == 0, let preferences = try? await session.aiSetupPreferences() { provider = preferences.defaultProvider.rawValue }
        }
    }
    private func saveDraft() async {
        guard !working, let draft else { return }
        working = true; defer { working = false }
        let saved = await draft.saveCurrent(value: { draftValue })
        status = saved ? "Draft saved on this Mac. You can leave and continue later." : draft.status
        problem = !saved
    }
    private func choose() {
        guard !working, let session else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let files = try await selectScreenshots(10 - shots.count)
                guard !files.isEmpty else { return }
                guard shots.count + files.count <= 10 else { status = "Choose no more than 10 screenshots in this set."; problem = true; return }
                for file in files {
                    let shot = try await session.stageMediaCardScreenshot(accountId: account.id, appId: app.id, bytes: file.data, name: file.name)
                    shots.append(shot)
                }
                let saved = await draft?.saveCurrent(value: { draftValue }) == true
                status = saved ? "Screenshots added and the draft is saved on this Mac." : (draft?.status ?? "Screenshots added. Save the draft before leaving.")
                problem = !saved
            } catch { status = AIFailure.message(error); problem = true }
        }
    }
    private func generate() async {
        guard !working, let session else { return }
        if let generationIssue { status = generationIssue; problem = true; return }
        working = true; status = "Generating cards…"; problem = false; defer { working = false }
        do {
            guard await draft?.saveCurrent(value: { draftValue }) == true, let snapshot = draft?.syncSnapshot() else {
                status = draft?.status ?? "Open the draft before generating."; problem = true; return
            }
            let input = draftValue
            let set = try await session.proposeAICards(accountId: account.id, appId: app.id, expected: snapshot.revision)
            guard input == draftValue else { throw AIFailure.changed }
            opened(try await session.saveProposedAICards(accountId: account.id, appId: app.id, set: set))
        } catch { status = (error as? MediaCardFailure)?.message ?? AIFailure.message(error); problem = true }
    }
}
