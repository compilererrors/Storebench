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
            if model.isTerminating { ProgressView("Finishing work before quitting…") }
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
            .onChange(of: scenePhase) { if scenePhase == .active { Task { await model.reloadEditingPreferences() } } }
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
        case .loading: ProgressView("Opening Storebench…")
        case .unlocking: ProgressView(model.loadingSampleData ? "Loading sample data…" : "Unlocking saved data…")
        case .closing: ProgressView("Signing out after active work finishes…")
        case .chooseStorage: StorageChoiceView(model: model)
        case .migrateStorage: PasswordStorageMigrationView(model: model)
        case .notSetUp: SetupView(model: model)
        case .failed(let message):
            StorebenchAuthScreen {
                StorebenchAuthCard(title: "Saved data could not be opened", message: message) {
                    Button("Try Again") { Task { await model.retryStart() } }.buttonStyle(StorebenchButtonStyle(.primary))
                    if model.storageMode == .keychain { Button("Choose Protection") { model.reviewStorageChoice() }.help("Choose Storage Protection").accessibilityLabel("Choose Storage Protection") }
                }
            }
        case .locked: UnlockView(model: model)
        case .unlocked(let accounts): LibraryView(accounts: accounts, model: model, initialLocation: initialLocation)
        }
    }
}
