import StorebenchCore
import SwiftUI

struct AIServicePicker: View {
    let session: WorkspaceSession?
    @Binding var selection: String
    @Binding var modelID: String
    var includesTranslation = false
    var sharedContent = "Selected text"
    var requiresImages = false
    var loaded: ([AIConnection]) -> Void = { _ in }
    @Environment(\.aiSettingsNavigation) private var navigation
    @State private var connections: [AIConnection] = []
    @State private var models: [AIClient.Model] = []
    @State private var reading = false
    @State private var status = ""
    @State private var requestID = UUID()
    private var provider: AIProvider? { AIProvider(rawValue: selection) }
    private var connection: AIConnection? { connections.first { $0.provider == provider } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StorebenchFormGrid {
                StorebenchPicker(includesTranslation ? "Translation Service" : "AI Service", selection: Binding(get: { selection }, set: { selection = $0; modelID = "" })) {
                    if includesTranslation { SelectionOption("Apple Translation · On This Mac", value: "") }
                    selectionOptions([AIProvider.chatgpt, .apple, .openai, .anthropic, .gemini]) { service in
                        SelectionOption(title(service), value: service.rawValue)
                    }
                }
                if let provider, provider != .apple {
                    StorebenchPicker("AI Model", selection: $modelID, hint: requiresImages ? "Choose a model that accepts screenshots." : "") {
                        SelectionOption(connection.map { "Saved Default · " + $0.model } ?? "Connect This Service First", value: "")
                        if !modelID.isEmpty, !models.contains(where: { $0.id == modelID }) { SelectionOption(modelID + " · Selected", value: modelID) }
                        selectionOptions(models) { SelectionOption($0.name, value: $0.id) }
                    }.storebenchWorking(connection == nil)
                } else if provider == .apple {
                    StorebenchLabeledContent("AI Model") { Text("On-Device Model · Managed by macOS").font(.sbCallout).frame(minHeight: StorebenchTheme.controlHeight, alignment: .leading) }
                }
            }
            Text(usage)
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchTextSlot(text: reading ? "Reading available models…" : status, height: 36, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            StorebenchActionGroup {
                if provider != nil && provider != .apple {
                    Button("Refresh Models") { Task { await load(refresh: true) } }.storebenchWorking(reading || connection == nil)
                }
                if let open = navigation.open {
                    Button("AI Settings…", action: open).help("Choose saved defaults and manage ChatGPT or API connections")
                }
            }
        }.task(id: selection) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .storebenchAIConnectionsChanged)) { _ in Task { await load() } }
    }
    private func title(_ service: AIProvider) -> String {
        if service == .apple { return service.title + (AppleLocalAI.available ? " · On This Mac" : " · Unavailable") }
        if connections.contains(where: { $0.provider == service }) { return service.title }
        return service.title + (service == .chatgpt ? " · Sign In" : " · Add API Key")
    }
    private var usage: String {
        if selection.isEmpty { return "Apple translates on this Mac. It may ask to download a language." }
        if provider == .apple { return "Runs on this Mac without API billing. macOS manages the model; Apple Intelligence must be enabled." }
        if connection == nil { return provider == .chatgpt ? "Sign in with ChatGPT in AI Settings to use your plan." : "Add your own API key for this service in AI Settings." }
        if provider == .chatgpt { return "\(sharedContent) will be sent using your ChatGPT plan and its usage limits. This model choice keeps saved defaults unchanged." }
        return "\(sharedContent) will be sent using this service's saved API key. API billing applies; saved defaults stay unchanged."
    }
    private func load(refresh: Bool = false) async {
        let id = UUID(), chosen = selection; requestID = id; models = []; status = ""; reading = false
        guard let session else { connections = []; loaded([]); return }
        do {
            let values = try await session.aiConnections()
            guard !Task.isCancelled, requestID == id, chosen == selection else { return }
            connections = values; loaded(values)
            guard let connection, connection.provider != .apple else { reading = false; return }
            reading = true
            defer { if requestID == id { reading = false } }
            let available = try await session.availableAIModels(connection, refresh: refresh)
            guard !Task.isCancelled, requestID == id, chosen == selection else { return }
            models = available
            status = available.isEmpty ? "No models were listed. The saved model is still available." : ""
        } catch {
            guard !Task.isCancelled, requestID == id, chosen == selection else { return }
            status = "Models could not be refreshed. Your selection is kept; check the connection in AI Settings."
        }
    }
}

extension Notification.Name { static let storebenchAIConnectionsChanged = Notification.Name("StorebenchAIConnectionsChanged") }
