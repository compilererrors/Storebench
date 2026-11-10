import AppKit
import StorebenchCore
import SwiftUI

struct ChatGPTSettings: View {
    let model: LibraryModel
    @Environment(\.editorProtection) private var protection
    @State private var profiles: [ChatGPTProfile] = []
    @State private var selected = ""
    @State private var modelID = ""
    @State private var models: [AIClient.Model] = []
    @State private var connection: AIConnection?
    @State private var loaded = false
    @State private var working = false
    @State private var stale = false
    @State private var status = ""
    @State private var problem = false
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var callback: ChatGPTCallback?
    @State private var attempt: ChatGPTSignIn?
    @State private var latest: [ChatGPTProfile]?
    @State private var latestConnection: AIConnection?
    @State private var readingModels = false
    @State private var modelRequest = UUID()
    private var profile: ChatGPTProfile? { profiles.first { $0.id == selected } }
    private var dirty: Bool { profile != nil && modelID != profile?.model }
    private var modelAvailable: Bool { models.contains { $0.id == modelID } || (models.isEmpty && !modelID.isEmpty && modelID == profile?.model) }
    private var active: Bool { profile?.credentialID != nil && profile?.credentialID == connection?.credentialId }
    private var connectionStatus: String {
        guard loaded else { return problem ? "Saved Connection Unavailable" : "Reading Saved Connection…" }
        if active { return "Connected" }
        guard profile?.credentialID != nil else { return "Not Connected" }
        guard profile?.planEnabled == true else { return "Plan Access Required · Sign In Again" }
        return "Signed In · Choose Use Account"
    }
    var body: some View {
        StorebenchFormSection("ChatGPT Plan", icon: "users", description: "Use your ChatGPT plan for cards and translations. Your plan's usage limits apply.") {
            VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                StorebenchFormField(label: "Connection", hideHint: true) {
                    StorebenchTextSlot(text: connectionStatus, height: StorebenchTheme.controlHeight, font: .sbCallout, color: active ? StorebenchTheme.color("color-success") : StorebenchTheme.muted, live: true)
                }.help("Connection status for the selected ChatGPT account")
                if !profiles.isEmpty {
                    StorebenchPicker("Account", selection: Binding(get: { selected }, set: choose), hint: active ? "Connected · Used for ChatGPT tasks" : "Choose a saved account or add another below.") {
                        if selected.isEmpty { SelectionOption("New Account", value: "") }
                        selectionOptions(profiles) { SelectionOption($0.label + ($0.credentialID == nil ? " · Signed Out" : ""), value: $0.id) }
                    }
                    StorebenchActionGroup(alignment: .trailing) {
                        StorebenchMenu("Account Options", icon: "users") {
                            Button("Add Account…") { selectProfile("", connecting: true) }
                            Button("Sign In Again…") { start { await signIn() } }.disabled(profile == nil)
                            StorebenchMenuSeparator()
                            StorebenchExternalMenuItem("Manage Plan Usage…", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                            Button("Retry Plan Usage") {
                                Task { do { try await model.session?.retryChatGPTPlanUsage(); status = "Plan usage can be retried. Check ChatGPT Settings → Usage if the limit is reached again."; problem = false } catch { report(error) } }
                            }.disabled(!active)
                            StorebenchMenuSeparator()
                            Button("Sign Out", role: .destructive) { start { await signOut() } }.disabled(profile?.credentialID == nil)
                        }
                    }
                    if profile?.credentialID != nil && profile?.planEnabled == true {
                        StorebenchPicker("Default Model", selection: $modelID, hint: "Cards and translations can choose another model for one task.") {
                            if !models.contains(where: { $0.id == modelID }) { SelectionOption(modelID.isEmpty ? "Choose a Model" : modelID + " · Saved", value: modelID) }
                            selectionOptions(models) { SelectionOption($0.name, value: $0.id) }
                        }
                    }
                }
            }.storebenchWorking(working || !loaded)
            StorebenchTextSlot(text: readingModels ? "Reading available ChatGPT models…" : status, height: 44, font: .sbCallout, color: problem && !readingModels ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
            if !profiles.isEmpty {
                LatestSaveReview(busy: working, hasEdits: dirty || stale, available: loaded, changes: differences, note: "Account credentials are never displayed. Choosing a saved baseline does not save your model selection.",
                    onRead: { start { await compare() } }, onKeep: latest == nil ? nil : { useLatest(keepEdits: true) }, onUse: latest == nil ? nil : { useLatest(keepEdits: false) })
            }
            StorebenchFormFooter {
                if working {
                    Button("Cancel", role: .cancel) { cancel() }.disabled(operation == nil)
                } else if profile?.credentialID != nil && profile?.planEnabled == true {
                    Button("Refresh Models") { start { await readModels() } }.storebenchWorking(readingModels || !loaded)
                }
                if profile?.credentialID != nil && profile?.planEnabled == true {
                    Button(active ? "Save Model" : "Use Account") { start { _ = await saveModel() } }
                        .buttonStyle(StorebenchButtonStyle(.primary))
                        .storebenchWorking(working || !loaded || stale || !modelAvailable || (active && !dirty))
                } else {
                    Button("Continue with ChatGPT…") { start { await signIn() } }.buttonStyle(StorebenchButtonStyle(.primary))
                        .storebenchWorking(working || !loaded)
                }
            }
        }
        .task { await load() }
        .task(id: profile) { await readModels(refresh: false) }
        .onDisappear { cancel() }
        .trackUnsavedChanges(dirty, busy: working, generation: selected + modelID, onSave: { await saveModel() })
    }
    private func choose(_ id: String) {
        selectProfile(id, connecting: false)
    }
    private func selectProfile(_ id: String, connecting: Bool) {
        guard id != selected || connecting else { return }
        let change: @MainActor @Sendable () -> Void = {
            selected = id; modelID = profile?.model ?? ""; models = []; modelRequest = UUID(); readingModels = false; latest = nil; stale = false; status = ""
            if connecting { start { await signIn() } }
        }
        if let protection { protection.requestLeaving(change) } else { change() }
    }
    private func start(_ work: @escaping @MainActor () async -> Void) {
        guard !working else { return }
        operation?.cancel()
        let id = UUID(); operationID = id
        operation = Task { await work(); if operationID == id { operation = nil } }
    }
    private func cancel() {
        callback?.cancel(); operation?.cancel()
        if let attempt, let session = model.session { Task { await session.cancelChatGPTSignIn(attempt.id) } }
    }
    private func load() async {
        guard let session = model.session else { return }
        do {
            profiles = try await session.chatGPTProfiles(); connection = try await session.aiConnections().first { $0.provider == .chatgpt }
            selected = profiles.first { $0.credentialID != nil && $0.credentialID == connection?.credentialId }?.id ?? profiles.first?.id ?? ""
            modelID = profile?.model ?? ""; loaded = true
        } catch { report(error) }
    }
    private func signIn() async {
        if dirty, !(await saveModel()) { return }
        guard !working, let session = model.session else { return }
        working = true; defer { working = false; callback = nil; attempt = nil }
        do {
            let state = try ChatGPTOAuth.random(), receiver = ChatGPTCallback(state: state); callback = receiver
            let redirect = try await receiver.start()
            let pending = try await session.beginChatGPTSignIn(redirect: redirect, state: state, profile: profile, writer: model.writer); attempt = pending
            if !profiles.contains(where: { $0.id == pending.profile.id }) { profiles.append(pending.profile) }
            selected = pending.profile.id
            guard !Task.isCancelled, NSWorkspace.shared.open(pending.authorizationURL) else { receiver.cancel(); throw AIFailure.cancelled }
            status = "Finish signing in and approve ChatGPT plan usage in your browser."; problem = false
            let url = try await receiver.wait()
            let result = try await session.finishChatGPTSignIn(pending, callback: url, writer: model.writer)
            profiles = try await session.chatGPTProfiles(); selected = result.profile.id; modelID = result.profile.model; models = result.models
            connection = try await session.aiConnections().first { $0.provider == .chatgpt }
            status = result.active ? "ChatGPT plan connected. Choose your model and Save Model. Default AI Service above chooses the starting service for new tasks." : result.profile.planEnabled ? "Signed in. Choose a model and Use Account to activate this connection." : "Signed in. Continue with ChatGPT again to enable plan usage."
            problem = false; notify()
        } catch {
            if let attempt, let current = try? await session.chatGPTProfiles().first(where: { $0.id == attempt.profile.id }),
               current.revision == attempt.profile.revision + 1, current.model == attempt.profile.model,
               current.credentialID == attempt.profile.credentialID, current.subject == attempt.profile.subject {
                profiles.removeAll { $0.id == current.id }; profiles.append(current)
            }
            report(error)
            if error is CancellationError || (error as? AIFailure) == .cancelled { status = "Sign-in stopped. Continue with ChatGPT to try again."; problem = false }
        }
    }
    private func readModels(refresh: Bool = true) async {
        guard !working, !readingModels, loaded, let session = model.session, let profile, profile.credentialID != nil, profile.planEnabled else { return }
        if !refresh && !models.isEmpty { return }
        let request = UUID(); modelRequest = request; readingModels = true
        defer { if modelRequest == request { readingModels = false } }
        do {
            let available: [AIClient.Model]
            if let connection, connection.credentialId == profile.credentialID { available = try await session.availableAIModels(connection, refresh: refresh) }
            else { available = try await session.chatGPTModels(profile) }
            guard !Task.isCancelled, self.profile == profile, modelRequest == request else { return }
            models = available
            if refresh { status = "Models refreshed. Choose a model, then save it when ready."; problem = false }
        } catch {
            guard !Task.isCancelled, self.profile == profile, modelRequest == request else { return }
            report(error)
        }
    }
    private func saveModel() async -> Bool {
        guard !working, !stale, let session = model.session, let profile, modelAvailable else { return false }
        working = true; defer { working = false }
        do {
            let saved = try await session.activateChatGPTProfile(profile, model: modelID, expectedConnection: connection?.revision ?? 0)
            profiles.removeAll { $0.id == saved.id }; profiles.append(saved); connection = try await session.aiConnections().first { $0.provider == .chatgpt }
            status = "ChatGPT account and model saved. Tasks using ChatGPT start with this model; each task can choose another."
            problem = false; notify(); return true
        } catch { report(error); return false }
    }
    private func signOut() async {
        guard !working, let session = model.session, let profile else { return }; working = true; defer { working = false }
        do {
            let revoked = try await session.signOutChatGPT(profile)
            profiles = try await session.chatGPTProfiles(); connection = try await session.aiConnections().first { $0.provider == .chatgpt }; models = []
            modelID = self.profile?.model ?? ""
            status = revoked ? "Signed out. Saved AI results remain on this Mac." : "Signed out on this Mac. Remote revocation was not confirmed; disconnect Storebench in ChatGPT Settings if needed."
            problem = !revoked; notify()
        } catch { report(error) }
    }
    private func notify() { NotificationCenter.default.post(name: .storebenchAIConnectionsChanged, object: nil) }
    private func report(_ error: Error) { stale = (error as? DraftFailure) == .stale; status = AIFailure.message(error); problem = true }
    private var differences: [SavedValueChange]? {
        guard let latest else { return nil }
        let saved = latest.first { $0.id == selected }
        return [.init(id: "chatgpt-model", label: "ChatGPT Model", saved: saved?.model ?? "No saved account", edited: modelID),
                .init(id: "chatgpt-account", label: "Active Account", saved: latest.first { $0.credentialID != nil && $0.credentialID == latestConnection?.credentialId }?.label ?? "None", edited: active ? profile?.label ?? "None" : "Selected account is not active")]
    }
    private func compare() async {
        guard !working, let session = model.session else { return }; working = true; defer { working = false }
        do { latest = try await session.chatGPTProfiles(); latestConnection = try await session.aiConnections().first { $0.provider == .chatgpt }; status = "Compare the saved account and model before choosing a baseline."; problem = false }
        catch { report(error) }
    }
    private func useLatest(keepEdits: Bool) {
        guard let latest else { return }; profiles = latest; connection = latestConnection; self.latest = nil; stale = false; models = []
        if !keepEdits { modelID = profile?.model ?? "" }
        status = "Baseline chosen. Refresh Models before saving your selection."; problem = false
    }
}
