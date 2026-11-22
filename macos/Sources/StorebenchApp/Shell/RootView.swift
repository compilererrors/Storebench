import StorebenchCore
import SwiftUI

struct RootView: View {
    let model: LibraryModel
    let recovery: RecoveryCoordinator
    var initialLocation = LibraryLocation()
    @State private var protection = EditorProtection()
    @State private var shortcutActions = ShortcutActions()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if model.isTerminating { QuittingView(model: model) }
            else { content }
        }.id(model.session.map(ObjectIdentifier.init))
            .trackUnsavedChanges(false, busy: model.state == .closing)
            .trackUnsavedChanges(false, busy: shortcutActions.hasPendingActions, id: "keyboard-actions")
            .environment(\.editingPreferences, model.editingPreferences).environment(\.editorProtection, protection)
            .environment(\.confirmDestructive, DestructiveConfirm(model: model))
            .environment(model)
            .background(EditorWindowGuard(protection: protection, role: .workspace).frame(width: 0, height: 0))
            .environment(\.recoveryNavigation, RecoveryNavigation(scope: nil, navigate: recover))
            .environment(\.shortcutActions, shortcutActions)
            .focusedSceneValue(\.shortcutActions, shortcutActions).focusedSceneValue(\.shortcutProtection, protection)
            .modifier(AISetupIntroduction(model: model, recovery: recovery))
            // The lowest activity level draws every change at once instead of animating it.
            .transaction { if !model.workPlan.animations { $0.disablesAnimations = true; $0.animation = nil } }
            .onChange(of: scenePhase) {
                if scenePhase == .active { Task { await model.reloadEditingPreferences(); await model.refreshBackgroundReads() } }
            }
            .onChange(of: protection.policy.navigationDecision) {
                if protection.policy.navigationDecision == .ready { Task { await model.reloadAccounts(automatically: true) } }
            }
    }

    private func recover(_ action: RecoveryGuidance.Action) {
        switch action.target.area {
        case .accounts, .storage, .help: _ = recovery.open(action, onOpen: { openSettings() })
        case .developerAccount: openURL(URL(string: "https://developer.apple.com/account/")!)
        case .unlock:
            Task { if await EditorWindows.requestClosing(reason: .signOut) { await model.signOut() } }
        default: break
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading: StorebenchLaunchScreen(message: "Opening Storebench…")
        case .unlocking: StorebenchLaunchScreen(message: model.loadingSampleData ? "Loading sample data…" : "Unlocking saved data…")
        case .closing: StorebenchLoadingStatus(message: "Signing out after active work finishes…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .chooseStorage: StorageChoiceView(model: model)
        case .migrateStorage: PasswordStorageMigrationView(model: model)
        case .notSetUp: SetupView(model: model)
        case .failed(let message):
            StorebenchAuthScreen {
                StorebenchAuthCard(title: "Saved data could not be opened", message: message) {
                    StorebenchActionGroup {
                        Button("Try Again") { Task { await model.retryStart() } }.buttonStyle(StorebenchButtonStyle(.primary))
                        if model.storageMode == .keychain { Button("Choose Protection") { model.reviewStorageChoice() }.help("Choose Storage Protection").accessibilityLabel("Choose Storage Protection") }
                    }
                }
            }
        case .locked: UnlockView(model: model)
        case .unlocked(let accounts): LibraryView(accounts: accounts, model: model, initialLocation: initialLocation)
        }
    }
}

/// Shown while quitting waits for work that was already started, such as a sync being sent to App Store Connect.
/// It names what it waits for and keeps Quit Now in place for leaving at once.
struct QuittingView: View {
    let model: LibraryModel
    @State private var waiting: [String] = []
    var body: some View {
        StorebenchAuthScreen {
            StorebenchAuthCard(title: "Finishing Work Before Quitting", message: "Storebench quits by itself as soon as the work below is done. Saved drafts and downloaded data are already on this Mac.") {
                StorebenchProgressStatus(message: waiting.isEmpty ? "Closing saved data…" : waiting.joined(separator: " · ") + "…")
                StorebenchActionGroup {
                    Button("Quit Now") { model.quitNow() }
                        .help("Quit without waiting. A sync being sent to App Store Connect stops where it is; Storebench shows it as stopped next time and never sends it again by itself.")
                }
            }
        }
        .task { await StorebenchPolling.repeating(every: .milliseconds(500), while: { true }) { waiting = model.unfinishedWork() } }
    }
}
