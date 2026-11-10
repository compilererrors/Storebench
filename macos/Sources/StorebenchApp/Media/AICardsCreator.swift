import AppKit
import StorebenchCore
import SwiftUI

struct AICardsCreator: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var selectScreenshots: @MainActor (Int) async throws -> [SelectedFiles.File] = MediaFileSelection.screenshots
    var initialSource: JSONText? = nil
    let opened: (WorkspaceSession.SavedMediaCardSet) -> Void
    @State private var name = ""
    @State private var brief = ""
    @State private var language = "en-US"
    @State private var provider = AIProvider.apple.rawValue
    @State private var modelID = ""
    @State private var targetId = MediaCards.defaultTarget.id
    @State private var directions = Set(AICardDirection.defaults)
    @State private var customInstructions: String?
    @State private var cardBriefs: [String] = []
    @State private var customColors = false
    @State private var palette = AICardPalette()
    @State private var variationID: String?
    @State private var sourceNote = ""
    @State private var previousCard: JSONText?
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
        if let issue = AICards.customInstructionIssue(customInstructions) { return issue }
        if let issue = AICards.cardBriefIssue(cardBriefs) { return issue }
        if !servicesLoaded { return "Checking the selected AI service…" }
        return AICards.generationIssue(name: name, brief: brief, screenshots: shots.count, provider: provider, connections: connections, localAvailable: AppleLocalAI.available)
    }
    private var footerHint: String {
        if working { return "Working… " + executionSummary }
        if let generationIssue { return generationIssue }
        if problem { return "The last saved draft is kept. Read the message above before retrying." }
        return "Each generation creates a new variant. Previous card sets and AI requests stay saved on this Mac."
    }
    private var draftValue: JSONText {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .object([("name", .string(name)), ("brief", .string(brief)), ("language", .string(language)), ("provider", .string(provider)), ("model", .string(modelID)), ("target", .string(targetId)),
            ("screenshots", (try? JSONText.parse(encoder.encode(shots))) ?? .null),
            ("directions", .array(AICardDirection.allCases.filter { directions.contains($0) }.map { .string($0.rawValue) })),
            ("variationID", variationID.map(JSONText.string) ?? .null), ("previousCard", previousCard ?? .null), ("customInstructions", customInstructions.map(JSONText.string) ?? .null),
            ("cardBriefs", .array(cardBriefs.map(JSONText.string))), ("cardPalette", customColors ? palette.value : .null)])
    }
    private func restore(_ value: JSONText) {
        name = value["name"]?.text ?? ""; brief = value["brief"]?.text ?? ""; language = value["language"]?.text ?? "en-US"
        provider = value["provider"]?.text ?? AIProvider.apple.rawValue; targetId = value["target"]?.text ?? MediaCards.defaultTarget.id
        modelID = value["model"]?.text ?? ""
        directions = Set((try? AICardDirection.selected(in: value)) ?? AICardDirection.defaults)
        customInstructions = value["customInstructions"]?.text
        previousCard = value["previousCard"].flatMap { $0 == .null ? nil : $0 }
        variationID = value["variationID"]?.text; sourceNote = value["sourceNote"]?.text ?? ""
        shots = value["screenshots"].flatMap { try? JSONDecoder().decode([MediaCard.Screenshot].self, from: $0.data) } ?? []
        cardBriefs = (try? AICards.cardBriefs(in: value, count: shots.count)) ?? Array(repeating: "", count: shots.count)
        let savedPalette = try? AICardPalette.read(value["cardPalette"])
        customColors = savedPalette != nil; palette = savedPalette ?? AICardPalette()
    }
    var body: some View {
        Card(title: "Create AI Cards", subtitle: "Describe the message and style in one or two sentences. AI proposes editable cards using your original screenshots.") {
            StorebenchTextField("Card Set Name", text: $name, hint: "Up to 80 characters")
            StorebenchTextArea(title: "What Should the Cards Convey? · \(brief.utf16.count)/2000", text: $brief, height: StorebenchTheme.textarea(rows: 3))
            if let previousCard {
                StorebenchCardSection(title: "Improve This Version") {
                    StorebenchAdaptiveText(text: previousCard["title"]?.text ?? "Selected Card")
                    Text("The current wording and colors are included for comparison. Edit the brief or directions below; generating keeps the previous card set.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !sourceNote.isEmpty { Text(sourceNote).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
            StorebenchOptionGroup(title: "Creative Directions", description: "Choose any combination. Hover over an option to read the instruction it adds to your brief.") {
                StorebenchOptionGrid {
                    ForEach(AICardDirection.allCases, id: \.self) { direction in
                        StorebenchToggle(direction.title, isOn: Binding(get: { directions.contains(direction) }, set: { selected in
                            if selected { directions.insert(direction) } else { directions.remove(direction) }
                        })).help(direction.instruction)
                    }
                }
            }
            DisclosureGroup {
                AICardPromptEditor(customInstructions: $customInstructions, directions: AICardDirection.allCases.filter { directions.contains($0) })
            } label: {
                Text("Prompt Instructions").storebenchControlID("ai-cards.prompt-instructions")
            }
            StorebenchFormGrid {
                StorebenchPicker("Display Size", selection: $targetId) { selectionOptions(MediaCards.targets) { SelectionOption($0.label, value: $0.id) } }
                StorebenchPicker("Card Language", selection: $language) { selectionOptions(StoreLocales.codes) { SelectionOption(StoreLocales.name($0), value: $0) } }
            }
            AICardColorControls(custom: $customColors, palette: $palette)
            AIServicePicker(session: session, selection: $provider, modelID: $modelID, sharedContent: "Your brief and selected screenshots", requiresImages: true, loaded: { connections = $0; servicesLoaded = true })
            StorebenchCardSection(title: "Screenshots") {
                Text("\(shots.count) of 10 selected. Their original pixels remain in the cards; AI chooses the text, order and colors. The whole screenshot stays visible unless you allow cropping.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(shots.enumerated()), id: \.offset) { index, shot in
                    StorebenchCardSection(title: "Screenshot \(index + 1)") {
                        StorebenchStatusRow(title: shot.name, detail: "\(shot.width) × \(shot.height) px") { Text("Selected").font(.sbCaption) } action: {
                            Button("Remove") { shots.remove(at: index); cardBriefs.remove(at: index) }
                                .storebenchControlID("ai-cards.remove-screenshot-\(index)")
                        } details: { EmptyView() }
                        StorebenchTextArea(title: "Instructions for This Card (Optional) · \(cardBriefs.indices.contains(index) ? cardBriefs[index].utf16.count : 0)/\(AICards.cardBriefLimit)",
                                           text: cardBrief(index), height: StorebenchTheme.textarea(rows: 2),
                                           hint: "Describe this screenshot's feature or message. Leave empty to use the shared brief and screenshot content.")
                            .storebenchControlID("ai-cards.card-brief-\(index)")
                    }
                }
                StorebenchFormFooter { Button("Add Screenshots…") { choose() }.storebenchControlID("ai-cards.add-screenshots").storebenchWorking(shots.count >= 10) }
            }
            StorebenchTextSlot(text: status, height: 54, font: .sbCallout, color: problem ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
            if let draft {
                StorebenchEditorFooter(title: "AI Card Draft", detail: (draft.dirty(draftValue) ? "Unsaved changes." : "Draft saved on this Mac.") + " · " + executionSummary, hint: footerHint) {
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
            if owner.loaded, let initialSource { restore(initialSource) }
        }
    }
    private func cardBrief(_ index: Int) -> Binding<String> {
        Binding(get: { cardBriefs.indices.contains(index) ? cardBriefs[index] : "" }, set: { value in
            guard cardBriefs.indices.contains(index) else { return }; cardBriefs[index] = value
        })
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
                    cardBriefs.append("")
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
            variationID = UUID().uuidString.lowercased()
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
