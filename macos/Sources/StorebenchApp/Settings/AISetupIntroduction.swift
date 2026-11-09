import StorebenchCore
import SwiftUI

struct AISettingsNavigation: Sendable {
    let open: (@MainActor @Sendable () -> Void)?
    static let empty = Self(open: nil)
}
private struct AISettingsNavigationKey: EnvironmentKey { static let defaultValue = AISettingsNavigation.empty }
extension EnvironmentValues {
    var aiSettingsNavigation: AISettingsNavigation { get { self[AISettingsNavigationKey.self] } set { self[AISettingsNavigationKey.self] = newValue } }
}

struct AISetupIntroduction: ViewModifier {
    let model: LibraryModel, recovery: RecoveryCoordinator
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var preferences: AISetupPreferences?
    @State private var presented = false
    @State private var working = false
    @State private var status = ""
    @State private var owner: ObjectIdentifier?
    func body(content: Content) -> some View {
        content
            .environment(\.aiSettingsNavigation, AISettingsNavigation(open: showSettings))
            .task(id: model.state) { await check() }
            .onChange(of: scenePhase) { if scenePhase == .active { Task { await check() } } }
            .sheet(isPresented: Binding(get: { presented }, set: { if !$0 { Task { await answer(.later) } } })) {
                AISetupDialog(working: working, status: status) { choice in Task { await answer(choice) } }
                    .interactiveDismissDisabled(working)
            }
    }
    private func showSettings() { recovery.openAI(onOpen: { openSettings() }) }
    private func check() async {
        guard !model.showingSampleData, !model.isTerminating, case .unlocked = model.state, let session = model.session else {
            presented = false; preferences = nil; owner = nil; return
        }
        if owner != ObjectIdentifier(session) { presented = false; preferences = nil; owner = ObjectIdentifier(session) }
        guard !working, !presented else { return }
        do {
            let saved = try await session.aiSetupPreferences()
            guard !Task.isCancelled, !working, !presented, model.session === session, !model.showingSampleData,
                  case .unlocked = model.state, saved.revision >= (preferences?.revision ?? 0) else { return }
            preferences = saved; status = ""; presented = saved.shouldAsk()
        } catch { /* AI setup remains available in Settings if local preferences cannot be read. */ }
    }
    private func answer(_ choice: AISetupPreferences.Choice) async {
        guard presented, !working, let preferences, let session = model.session, owner == ObjectIdentifier(session),
              !model.showingSampleData, case .unlocked = model.state else { return }
        working = true; defer { working = false }
        do {
            let saved = try await session.saveAISetupPreferences(preferences.answering(choice))
            guard model.session === session else { return }
            self.preferences = saved; presented = false; status = ""
            if choice == .setup { showSettings() }
        } catch {
            if error as? DraftFailure == .stale, let latest = try? await session.aiSetupPreferences() {
                self.preferences = latest
                let savedChoice = latest.choice == .never ? "Don't Ask Again" : latest.choice == .later ? "Not Now" : latest.choice == .setup ? "Set Up AI" : "No Choice"
                status = "Another window saved \(savedChoice). Your choice was not saved. Choose again to confirm it."
                return
            }
            status = "Your choice could not be saved. Try again; AI setup is always available in Settings."
        }
    }
}

struct AISetupDialog: View {
    let working: Bool, status: String
    let choose: (AISetupPreferences.Choice) -> Void
    @State private var dontAskAgain = false
    private var deferredChoice: AISetupPreferences.Choice { dontAskAgain ? .never : .later }
    var body: some View {
        StorebenchDialog(title: "Use AI in Storebench?", height: 440, busy: working, close: { choose(deferredChoice) }) {
            VStack(alignment: .leading, spacing: StorebenchTheme.space(3)) {
                Text("Turn screenshots into editable App Store cards and translate your listing text.")
                    .font(.sbBody).fixedSize(horizontal: false, vertical: true)
                Text("Use your ChatGPT plan, Apple Intelligence on this Mac or an API service. Selected content is shared only with your chosen service when you generate.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                StorebenchToggle("Don't Ask Again", isOn: $dontAskAgain).storebenchWorking(working)
                StorebenchTextSlot(text: dontAskAgain ? "Choose Not Now to stop these reminders. AI is always available in Settings." : "Not Now reminds you in seven days. You can always set up AI in Settings.", height: 32, font: .sbCaption, color: StorebenchTheme.muted, live: true)
                StorebenchTextSlot(text: status, height: 44, font: .sbCallout, color: StorebenchTheme.color("color-danger"), live: true)
            }
        } actions: {
            StorebenchActionGroup(alignment: .trailing) {
                Button("Not Now") { choose(deferredChoice) }.keyboardShortcut(.cancelAction)
                Button("Set Up AI…") { choose(.setup) }.buttonStyle(StorebenchButtonStyle(.primary)).keyboardShortcut(.defaultAction)
            }.storebenchWorking(working)
        }
    }
}
