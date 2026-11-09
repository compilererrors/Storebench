import StorebenchCore
import SwiftUI

struct AISettings: View {
    let model: LibraryModel
    @Environment(\.editorProtection) private var protection
    @State private var connections: [AIConnection] = []
    @State private var defaultServices: [AIConnection] = []
    @State private var provider = AIProvider.openai
    @State private var modelId = ""
    @State private var apiKey = ""
    @State private var models: [AIClient.Model] = []
    @State private var working = false
    @State private var loaded = false
    @State private var status = ""
    @State private var problem = false
    @State private var stale = false
    @State private var latest: [AIConnection]?
    @State private var preferences: AISetupPreferences?
    @State private var defaultProvider = AIProvider.chatgpt.rawValue
    @State private var defaultStatus = ""
    @State private var defaultStale = false
    @State private var latestDefault: AISetupPreferences?
    @State private var apiExpanded = false
    @State private var readingModels = false
    @State private var modelRequest = UUID()
    private var current: AIConnection? { connections.first { $0.provider == provider } }
    private var dirty: Bool { !apiKey.isEmpty || modelId != (current?.model ?? "") }
    var body: some View {
        StorebenchForm {
            StorebenchFormSection("Default AI Service") {
                StorebenchPicker("Use for New AI Tasks", selection: $defaultProvider) {
                    if let connection = defaultServices.first(where: { $0.provider == .chatgpt }) { SelectionOption(connection.title, value: connection.id) }
                    else { SelectionOption("ChatGPT Plan · Sign In Required", value: AIProvider.chatgpt.rawValue) }
                    SelectionOption(AppleLocalAI.available ? "Apple Intelligence · On This Mac" : "Apple Intelligence · Unavailable", value: AIProvider.apple.rawValue)
                    if let service = AIProvider(rawValue: defaultProvider), service.usesAPIKey, !defaultServices.contains(where: { $0.provider == service }) {
                        SelectionOption(service.title + " · Not Connected", value: defaultProvider)
                    }
                    selectionOptions(defaultServices.filter { $0.provider != .chatgpt }) { SelectionOption($0.title, value: $0.id) }
                }
                Text("The starting service for new cards and translations. Each task can choose its own service and model.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                StorebenchTextSlot(text: defaultStatus, height: 44, font: .sbCallout, color: StorebenchTheme.muted, live: true)
                if preferences != nil {
                    LatestSaveReview(busy: working, hasEdits: defaultStale || preferences?.defaultProvider.rawValue != defaultProvider,
                        changes: latestDefault.map { [.init(id: "default", label: "Default AI Service", saved: $0.defaultProvider.title, edited: AIProvider(rawValue: defaultProvider)?.title ?? "Choose a Service")] },
                        note: "Choose the saved baseline explicitly. Reading it never saves your selection.",
                        onRead: { Task { await readDefault() } },
                        onKeep: latestDefault == nil ? nil : { chooseDefault(keepEdits: true) },
                        onUse: latestDefault == nil ? nil : { chooseDefault(keepEdits: false) })
                }
                StorebenchFormFooter {
                    Button("Use As Default") { Task { _ = await saveDefault() } }.buttonStyle(StorebenchButtonStyle(.primary))
                        .storebenchWorking(defaultStale || preferences == nil || defaultProvider == preferences?.defaultProvider.rawValue)
                }
            }
            ChatGPTSettings(model: model)
            StorebenchFormSection("Apple Intelligence") {
                Text(AppleLocalAI.available ? "Ready on this Mac. Local AI uses no API credits." : "Unavailable on this Mac. Apple Intelligence needs a compatible Mac, macOS 26 or later and an enabled, downloaded model.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                Text("Apple Translation remains available for supported languages. Local card generation uses your brief and text extracted from screenshots.")
                    .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("API Services", isExpanded: $apiExpanded) {
                StorebenchFormSection("API Connections") {
                    StorebenchPicker("AI Service", selection: Binding(get: { provider }, set: { value in
                        if let protection { protection.requestLeaving { provider = value } } else { provider = value }
                    })) {
                        selectionOptions(AIProvider.allCases.filter(\.usesAPIKey)) { SelectionOption($0.title, value: $0) }
                    }.onChange(of: provider) { modelId = current?.model ?? ""; apiKey = ""; models = []; modelRequest = UUID(); readingModels = false; status = ""; stale = false; latest = nil }
                    StorebenchSecureField("API Key", text: $apiKey, hint: current == nil ? "Your own key from the provider" : "Leave empty to keep the saved key")
                    if current != nil || !models.isEmpty {
                        StorebenchPicker("Default API Model", selection: $modelId) {
                            SelectionOption("Choose a Model", value: "")
                            if !modelId.isEmpty, !models.contains(where: { $0.id == modelId }) { SelectionOption(modelId + " · Selected", value: modelId) }
                            selectionOptions(models) { SelectionOption($0.name, value: $0.id) }
                        }
                        DisclosureGroup("Enter a Model ID") {
                            StorebenchTextField("Model ID", text: $modelId, hint: "Use an exact model ID supplied by the service.")
                        }
                    } else {
                        StorebenchTextField("Default API Model", text: $modelId, hint: "Refresh Models to choose from this connection, or enter a model ID. Cards need image input.")
                    }
                    Text("API requests use the provider's API billing. Selected text and screenshots are sent only when you run an AI task. Keys use your workspace's credential storage and are excluded from backups.")
                        .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                    StorebenchTextSlot(text: readingModels ? "Reading available API models…" : status, height: 54, font: .sbCallout, color: problem && !readingModels ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
                    if loaded {
                        LatestSaveReview(busy: working, hasEdits: dirty || stale, changes: differences, note: "API keys are never displayed. Keep My Edits retains a newly entered key; an empty key field uses the connection you explicitly choose here.",
                            onRead: { Task { await readLatest() } },
                            onKeep: latest == nil ? nil : { chooseLatest(keepEdits: true) },
                            onUse: latest == nil ? nil : { chooseLatest(keepEdits: false) })
                    }
                    StorebenchFormFooter {
                        if current != nil {
                            StorebenchMenu("Connection Options", icon: "settings") {
                                Button("Refresh Models") { Task { await readModels() } }.disabled(readingModels)
                                StorebenchMenuSeparator()
                                Button("Disconnect", role: .destructive) { Task { await disconnect() } }.disabled(stale)
                            }
                        } else {
                            Button("Refresh Models") { Task { await readModels() } }.storebenchWorking(readingModels || apiKey.isEmpty)
                        }
                        Button("Save Connection") { Task { _ = await save() } }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(!loaded || !dirty || stale || modelId.isEmpty || model.session == nil)
                    }
                }
            }
        }.storebenchWorking(working || model.session == nil || model.showingSampleData)
            .trackUnsavedChanges(dirty, busy: working, onSave: { await save() })
            .trackUnsavedChanges(defaultStale || preferences.map { $0.defaultProvider.rawValue != defaultProvider } == true, busy: working, id: "ai-default-service", onSave: { await saveDefault() })
            .task { await load() }
            .task(id: apiExpanded ? provider.rawValue + ":" + String(current?.revision ?? 0) : "") {
                if apiExpanded, apiKey.isEmpty, current != nil { await readModels(refresh: false) }
            }
            .onChange(of: defaultProvider) {
                if let service = AIProvider(rawValue: defaultProvider), service.usesAPIKey {
                    apiExpanded = true
                    if !dirty { provider = service }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .storebenchAIConnectionsChanged)) { _ in
                Task { await refreshChoices() }
            }
    }
    private var differences: [SavedValueChange]? {
        guard let latest else { return nil }
        let saved = latest.first { $0.provider == provider }
        var result: [SavedValueChange] = []
        if saved?.model != modelId { result.append(.init(id: "model", label: "Model", saved: saved?.model ?? "No connection", edited: modelId)) }
        if saved != current { result.append(.init(id: "connection", label: "Connection", saved: saved == nil ? "Disconnected" : "Updated saved connection", edited: current == nil ? "New connection" : "Previously loaded connection")) }
        if !apiKey.isEmpty { result.append(.init(id: "key", label: "API Key", saved: saved == nil ? "No saved key" : "Saved key hidden", edited: "New key entered · hidden")) }
        return result
    }
    private func readLatest() async {
        guard !working, let session = model.session else { return }; working = true; defer { working = false }
        do { latest = try await session.aiConnections(); status = "Compare the saved connection, then choose which values to use."; problem = false }
        catch { status = AIFailure.message(error); problem = true }
    }
    private func chooseLatest(keepEdits: Bool) {
        guard let latest else { return }
        connections = latest; self.latest = nil; stale = false
        if !keepEdits { modelId = current?.model ?? ""; apiKey = "" }
        status = keepEdits ? "Your edits are kept against the chosen save. Save Connection when ready." : "Saved connection loaded. Nothing was saved."
        problem = false
    }
    private func load() async {
        guard let session = model.session else { return }
        do {
            connections = try await session.aiConnections(); defaultServices = connections; modelId = current?.model ?? ""; loaded = true
            preferences = try await session.aiSetupPreferences(); defaultProvider = preferences?.defaultProvider.rawValue ?? AIProvider.chatgpt.rawValue
            apiExpanded = connections.contains { $0.provider.usesAPIKey }
            defaultStatus = "New AI tasks use \(preferences?.defaultProvider.title ?? AIProvider.chatgpt.title)."
        }
        catch { status = AIFailure.message(error); problem = true }
    }
    private func refreshChoices() async {
        guard let session = model.session else { return }
        let baseline = preferences, selected = defaultProvider
        do {
            defaultServices = try await session.aiConnections()
            let current = try await session.aiSetupPreferences()
            guard preferences == baseline, defaultProvider == selected else { return }
            if !defaultStale, baseline?.defaultProvider.rawValue == selected {
                preferences = current; defaultProvider = current.defaultProvider.rawValue
                defaultStatus = "New AI tasks use \(current.defaultProvider.title)."
            } else if baseline?.revision != current.revision {
                defaultStale = true; defaultStatus = "The saved default changed. Compare it before saving your selection."
            }
        } catch { defaultStatus = "AI choices could not be refreshed. Your selection is kept here." }
    }
    private func saveDefault() async -> Bool {
        guard !working, !defaultStale, var preferences, let provider = AIProvider(rawValue: defaultProvider), let session = model.session else { return false }
        guard provider == .apple || defaultServices.contains(where: { $0.provider == provider }) else { defaultStatus = "Connect this AI service before choosing it as the default."; return false }
        working = true; defer { working = false }
        preferences.defaultProvider = provider
        if preferences.choice != .never { preferences = preferences.answering(.setup) }
        do {
            self.preferences = try await session.saveAISetupPreferences(preferences)
            latestDefault = nil
            defaultStatus = "Default saved. New AI tasks will use \(provider.title)."
            return true
        } catch {
            if error as? DraftFailure == .stale {
                defaultStale = true
                defaultStatus = "The default changed in another window. Read the saved default before choosing again."
            } else { defaultStatus = "The default could not be saved. Your choice is kept here." }
            return false
        }
    }
    private func readDefault() async {
        guard !working, let session = model.session else { return }
        working = true; defer { working = false }
        do { latestDefault = try await session.aiSetupPreferences(); defaultStatus = "Compare the saved default, then choose which selection to keep." }
        catch { defaultStatus = "The saved default could not be read. Your selection is kept here." }
    }
    private func chooseDefault(keepEdits: Bool) {
        guard let latestDefault else { return }
        preferences = latestDefault; self.latestDefault = nil; defaultStale = false
        if !keepEdits { defaultProvider = latestDefault.defaultProvider.rawValue }
        defaultStatus = keepEdits ? "Your selection is kept. Choose Use As Default when ready." : "Saved default loaded. Nothing was saved."
    }
    private func readModels(refresh: Bool = true) async {
        guard !working, !readingModels else { return }
        let chosen = provider, key = apiKey, connection = current, request = UUID()
        modelRequest = request; readingModels = true
        defer { if modelRequest == request { readingModels = false } }
        do {
            let available: [AIClient.Model]
            if key.isEmpty, let connection, let session = model.session {
                available = try await session.availableAIModels(connection, refresh: refresh)
            } else { available = try await AIClient(provider: chosen, key: key).models() }
            guard !Task.isCancelled, modelRequest == request, provider == chosen, apiKey == key, current == connection else { return }
            models = available
            if refresh { status = "Choose a model, then Save Connection. Reading models does not generate content."; problem = false }
        } catch {
            guard !Task.isCancelled, modelRequest == request, provider == chosen, apiKey == key, current == connection else { return }
            stale = (error as? AIFailure) == .changed; status = AIFailure.message(error); problem = true
        }
    }
    private func save() async -> Bool {
        guard !working, loaded, !stale, let session = model.session else { return false }
        working = true; defer { working = false }
        do {
            let saved = try await session.saveAIConnection(provider: provider, model: modelId, apiKey: apiKey, expected: current?.revision ?? 0, writer: model.writer)
            connections.removeAll { $0.provider == provider }; connections.append(saved); apiKey = ""; latest = nil
            NotificationCenter.default.post(name: .storebenchAIConnectionsChanged, object: nil)
            status = "Connection saved. AI tasks use this provider's API billing."; problem = false; return true
        } catch { stale = (error as? DraftFailure) == .stale; status = (error as? DraftFailure)?.message ?? AIFailure.message(error); problem = true; return false }
    }
    private func disconnect() async {
        guard !working, !stale, let session = model.session, let current else { return }; working = true; defer { working = false }
        do { try await session.disconnectAI(current, writer: model.writer); connections.removeAll { $0.id == current.id }; modelId = ""; apiKey = ""; latest = nil; NotificationCenter.default.post(name: .storebenchAIConnectionsChanged, object: nil); status = "Disconnected. Saved AI results remain on this Mac."; problem = false }
        catch { stale = (error as? DraftFailure) == .stale; status = (error as? DraftFailure)?.message ?? AIFailure.message(error); problem = true }
    }
}
