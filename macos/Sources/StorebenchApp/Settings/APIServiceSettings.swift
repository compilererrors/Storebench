import StorebenchCore
import SwiftUI

/// Each provider retains its own unsaved key, model selection and saved revision.
struct APIServiceSettings: View {
    let model: LibraryModel
    let provider: AIProvider
    @State private var connection: AIConnection?
    @State private var modelID = ""
    @State private var apiKey = ""
    @State private var models: [AIClient.Model] = []
    @State private var loaded = false
    @State private var working = false
    @State private var reading = false
    @State private var stale = false
    @State private var status = ""
    @State private var problem = false
    @State private var latest: [AIConnection]?
    @State private var requestID = UUID()
    private var dirty: Bool { !apiKey.isEmpty || modelID != (connection?.model ?? "") }
    private var serviceName: String { provider == .anthropic ? "Claude" : provider.title }
    var body: some View {
        StorebenchFormSection(serviceName, icon: "sparkles", description: "Connect your own \(serviceName) API key for cards and translations. API billing applies.", accessory: AnyView(connectionOptions)) {
            StorebenchFormField(label: "Connection", hideHint: true) {
                StorebenchAdaptiveText(text: loaded ? connection == nil ? "Not Connected" : "Connected" : "Reading Connection…",
                                       color: connection == nil ? StorebenchTheme.muted : StorebenchTheme.color("color-success"))
            }
            StorebenchSecureField("API Key", text: $apiKey, hint: connection == nil ? "Use a key from the provider's console." : "Leave empty to keep the saved key.")
            if !models.isEmpty {
                StorebenchPicker("Default Model", selection: $modelID, hint: "Each task can choose another model.") {
                    SelectionOption("Choose a Model", value: "")
                    if !modelID.isEmpty && !models.contains(where: { $0.id == modelID }) { SelectionOption(modelID + " · Selected", value: modelID) }
                    selectionOptions(models) { SelectionOption($0.name, value: $0.id) }
                }
                DisclosureGroup("Enter a Model ID") {
                    StorebenchTextField("Model ID", text: $modelID, hint: "Use an exact model ID supplied by the service.")
                }
            } else {
                StorebenchTextField("Default Model", text: $modelID, hint: "Refresh models from this connection’s options menu, or enter an exact model ID.")
            }
            Text("Keys stay in protected credential storage and are excluded from backups. Selected text and screenshots are sent only when you run an AI task.")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchTextSlot(text: reading ? "Reading available models…" : status, height: StorebenchTheme.design.number("status-height"), font: .sbCaption,
                               color: problem && !reading ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
            LatestSaveReview(busy: working, hasEdits: dirty || stale, available: loaded, changes: differences,
                             note: "API keys are never displayed. Reading a saved connection does not save your edits.",
                             onRead: { Task { await compare() } }, onKeep: latest == nil ? nil : { chooseLatest(keepEdits: true) },
                             onUse: latest == nil ? nil : { chooseLatest(keepEdits: false) })
            StorebenchFormFooter {
                Button("Save Connection") { Task { _ = await save() } }.buttonStyle(StorebenchButtonStyle(.primary))
                    .storebenchWorking(!loaded || !dirty || stale || modelID.isEmpty || model.session == nil)
            }
        }.storebenchWorking(working || model.session == nil || model.showingSampleData)
            .trackUnsavedChanges(dirty, busy: working, id: "api-service-" + provider.rawValue, onSave: { await save() })
            .task { await load() }
    }
    private var connectionOptions: some View {
        StorebenchIconMenu(title: serviceName + " Connection Options") {
            Button("Refresh Models") { Task { await readModels() } }.disabled(reading || !loaded || (apiKey.isEmpty && connection == nil))
            if provider == .anthropic { StorebenchExternalMenuItem("Open Claude Console…", destination: URL(string: "https://console.anthropic.com/settings/keys")!) }
            StorebenchMenuSeparator()
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }.disabled(connection == nil || stale)
        }
    }
    private var differences: [SavedValueChange]? {
        guard let latest else { return nil }
        let saved = latest.first { $0.provider == provider }
        var result: [SavedValueChange] = []
        if saved?.model != modelID { result.append(.init(id: "model", label: "Model", saved: saved?.model ?? "No Connection", edited: modelID)) }
        if saved != connection { result.append(.init(id: "connection", label: "Connection", saved: saved == nil ? "Disconnected" : "Updated Saved Connection", edited: connection == nil ? "New Connection" : "Previously Loaded Connection")) }
        if !apiKey.isEmpty { result.append(.init(id: "key", label: "API Key", saved: "Saved Key Hidden", edited: "New Key Entered · Hidden")) }
        return result
    }
    private func load() async {
        guard let session = model.session else { return }
        do {
            connection = try await session.aiConnections().first { $0.provider == provider }
            modelID = connection?.model ?? ""; loaded = true
            if connection != nil { await readModels(refresh: false) }
        } catch { status = AIFailure.message(error); problem = true }
    }
    private func readModels(refresh: Bool = true) async {
        guard !working, !reading else { return }
        let key = apiKey, baseline = connection, id = UUID(); requestID = id; reading = true
        defer { if requestID == id { reading = false } }
        do {
            let available: [AIClient.Model]
            if key.isEmpty, let baseline, let session = model.session { available = try await session.availableAIModels(baseline, refresh: refresh) }
            else { available = try await AIClient(provider: provider, key: key).models() }
            guard !Task.isCancelled, requestID == id, apiKey == key, connection == baseline else { return }
            models = available
            if refresh { status = "Choose a model, then Save Connection."; problem = false }
        } catch {
            guard !Task.isCancelled, requestID == id, apiKey == key, connection == baseline else { return }
            stale = (error as? AIFailure) == .changed; status = AIFailure.message(error); problem = true
        }
    }
    private func save() async -> Bool {
        guard !working, loaded, !stale, let session = model.session else { return false }
        working = true; defer { working = false }
        do {
            connection = try await session.saveAIConnection(provider: provider, model: modelID, apiKey: apiKey, expected: connection?.revision ?? 0, writer: model.writer)
            apiKey = ""; latest = nil; status = "Connection saved. \(serviceName) is available for AI tasks."; problem = false; notify(); return true
        } catch { stale = (error as? DraftFailure) == .stale; status = AIFailure.message(error); problem = true; return false }
    }
    private func disconnect() async {
        guard !working, !stale, let session = model.session, let connection else { return }
        working = true; defer { working = false }
        do {
            try await session.disconnectAI(connection, writer: model.writer)
            self.connection = nil; modelID = ""; apiKey = ""; models = []; latest = nil; requestID = UUID(); reading = false
            status = "Disconnected. Saved AI results remain on this Mac."; problem = false; notify()
        } catch { stale = (error as? DraftFailure) == .stale; status = AIFailure.message(error); problem = true }
    }
    private func compare() async {
        guard !working, let session = model.session else { return }
        working = true; defer { working = false }
        do { latest = try await session.aiConnections(); status = "Compare the saved connection before choosing a baseline."; problem = false }
        catch { status = AIFailure.message(error); problem = true }
    }
    private func chooseLatest(keepEdits: Bool) {
        guard let latest else { return }
        connection = latest.first { $0.provider == provider }; self.latest = nil; stale = false; models = []; requestID = UUID(); reading = false
        if !keepEdits { modelID = connection?.model ?? ""; apiKey = "" }
        status = keepEdits ? "Your edits are kept. Save Connection when ready." : "Saved connection loaded. Nothing was saved."; problem = false
    }
    private func notify() { NotificationCenter.default.post(name: .storebenchAIConnectionsChanged, object: nil) }
}
