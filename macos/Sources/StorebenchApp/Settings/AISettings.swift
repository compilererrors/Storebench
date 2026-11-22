import StorebenchCore
import SwiftUI

struct AISettings: View {
    let model: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var defaultServices: [AIConnection] = []
    @State private var working = false
    @State private var preferences: AISetupPreferences?
    @State private var defaultProvider = AIProvider.chatgpt.rawValue
    @State private var defaultStatus = ""
    @State private var defaultStale = false
    @State private var latestDefault: AISetupPreferences?
    @State private var otherServicesExpanded = false
    @Environment(\.settingsSearchRequest) private var searchRequest
    var body: some View {
        ScrollViewReader { scroll in
        StorebenchForm {
            StorebenchSectionLinks {
                sectionLink("ChatGPT", target: "ai-chatgpt", scroll: scroll)
                sectionLink("Claude", target: "ai-claude", scroll: scroll)
                sectionLink("Apple Intelligence", target: "ai-apple", scroll: scroll)
                sectionLink("Other API Services", target: "ai-api", scroll: scroll)
                sectionLink("AI History", target: "ai-history", scroll: scroll)
            }.accessibilityLabel("AI Settings Sections")
            StorebenchFormSection("Default AI Service", icon: "settings", description: "The starting service for new cards and translations. Each task can choose its own service and model.") {
                StorebenchPicker("Use for New AI Tasks", selection: $defaultProvider) {
                    selectionOptions(AIProvider.allCases) { service in
                        SelectionOption(defaultTitle(service), value: service.rawValue)
                    }
                }.environment(\.fieldHintHeight, 0)
                StorebenchTextSlot(text: defaultStatus, height: StorebenchTheme.design.number("status-height"), font: .sbCaption, color: StorebenchTheme.muted, live: true)
                if preferences != nil {
                    LatestSaveReview(busy: working, hasEdits: defaultStale || preferences?.defaultProvider.rawValue != defaultProvider,
                        changes: latestDefault.map { [.init(id: "default", label: "Default AI Service", saved: $0.defaultProvider.title, edited: AIProvider(rawValue: defaultProvider)?.title ?? "Choose a Service")] },
                        note: "Choose the saved baseline explicitly. Reading it never saves your selection.",
                        onRead: { Task { await readDefault() } },
                        onKeep: latestDefault == nil ? nil : { chooseDefault(keepEdits: true) },
                        onUse: latestDefault == nil ? nil : { chooseDefault(keepEdits: false) })
                }
                StorebenchFormFooter {
                    Button("Use As Default") { Task { _ = await saveDefault() } }
                        .storebenchWorking(defaultStale || preferences == nil || defaultProvider == preferences?.defaultProvider.rawValue)
                }
            }
            .settingsSearchAnchor("ai-default")
            AICardDefaultsSettings().settingsSearchAnchor("ai-cards")
            ChatGPTSettings(model: model).settingsSearchAnchor("ai-chatgpt")
            APIServiceSettings(model: model, provider: .anthropic).settingsSearchAnchor("ai-claude")
            StorebenchFormSection("Apple Intelligence", icon: "display", description: "Apple models run on this Mac. Local AI uses no API credits.") {
                StorebenchFormField(label: "Availability", hint: AppleLocalAI.available ? "Ready for local AI tasks." : "Requires a compatible Mac, macOS 26 or later and an enabled, downloaded model.") {
                    StorebenchTextSlot(text: AppleLocalAI.available ? "Available on This Mac" : "Unavailable on This Mac", height: StorebenchTheme.controlHeight, font: .sbCallout, color: StorebenchTheme.muted, centered: true, live: true)
                }
                Text("Apple Translation remains available for supported languages. Local card generation uses your brief and text extracted from screenshots.")
                    .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }.settingsSearchAnchor("ai-apple")
            DisclosureGroup("Other API Services", isExpanded: $otherServicesExpanded) {
                APIServiceSettings(model: model, provider: .openai)
                APIServiceSettings(model: model, provider: .gemini)
            }.settingsSearchAnchor("ai-api")
            AIHistorySection(session: model.session).settingsSearchAnchor("ai-history")
        }.storebenchWorking(working || model.session == nil || model.showingSampleData)
            .trackUnsavedChanges(defaultStale || preferences.map { $0.defaultProvider.rawValue != defaultProvider } == true, busy: working, id: "ai-default-service", onSave: { await saveDefault() })
            .task { await load() }
            .onChange(of: searchRequest, initial: true) { if searchRequest?.target == "ai-api" { otherServicesExpanded = true } }
            .onReceive(NotificationCenter.default.publisher(for: .storebenchAIConnectionsChanged)) { _ in
                Task { await refreshChoices() }
            }
        }
    }
    private func sectionLink(_ title: String, target: String, scroll: ScrollViewProxy) -> some View {
        Button(title) {
            if target == "ai-api" { otherServicesExpanded = true }
            scroll.scrollTo(target, anchor: .top)
        }.help("Show " + title)
    }
    private func defaultTitle(_ service: AIProvider) -> String {
        if let connection = defaultServices.first(where: { $0.provider == service }) { return connection.title }
        if service == .apple { return service.title + (AppleLocalAI.available ? " · On This Mac" : " · Unavailable") }
        return service.title + (service == .chatgpt ? " · Sign In Required" : " · Not Connected")
    }
    private func load() async {
        guard let session = model.session else { return }
        do {
            defaultServices = try await session.aiConnections()
            preferences = try await session.aiSetupPreferences(); defaultProvider = preferences?.defaultProvider.rawValue ?? AIProvider.chatgpt.rawValue
            defaultStatus = "New AI tasks use \(preferences?.defaultProvider.title ?? AIProvider.chatgpt.title)."
        }
        catch { defaultStatus = AIFailure.message(error) }
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
}
