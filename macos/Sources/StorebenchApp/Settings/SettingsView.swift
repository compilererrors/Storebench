import AppKit
import StorebenchCore
import SwiftUI

/// macOS owns the preference toolbar; the workspace owns edits and navigation approval.
struct SettingsView: View {
    let model: LibraryModel
    let recovery: RecoveryCoordinator
    @State private var protection = EditorProtection()
    @State private var shortcutActions = ShortcutActions()
    @AppStorage("settings.pane") private var tab = "general"
    @State private var recoveryRequest: RecoveryIntent?
    @State private var search = ""
    @State private var searchRequest: SettingsSearchRequest?
    @Environment(\.openURL) private var openURL

    var body: some View {
        let shortcutPane = tab
        return VStack(spacing: 0) {
            StorebenchSearchField("Search Settings", text: $search)
                .onSubmit { if let result = SettingsSearch.results(for: search).first { chooseSearchResult(result) } }
                .storebenchControlID("settings.search")
                .padding(.horizontal, StorebenchTheme.settingsInset).padding(.vertical, 12)
            StorebenchDivider()
            ZStack(alignment: .topLeading) {
                settingsContent.opacity(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)
                    .allowsHitTesting(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHidden(!search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .storebenchWorking(!search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SettingsSearchResults(query: search, choose: chooseSearchResult)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.scrollContentBackground(.hidden)
        .environment(\.settingsSearchRequest, searchRequest)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .storebenchWorking(model.isTerminating)
        .environment(\.settingsPresentation, true)
        .id(model.session.map(ObjectIdentifier.init))
        .trackUnsavedChanges(false, busy: model.state == .closing)
        .frame(width: StorebenchTheme.settingsWindow.width, height: StorebenchTheme.settingsWindow.height).background(StorebenchTheme.page)
        .trackUnsavedChanges(false, busy: shortcutActions.hasPendingActions, id: "keyboard-actions")
        .shortcutNavigation([.nextSection, .previousSection, .help], identity: shortcutPane) { command in
            guard !model.isTerminating, tab == shortcutPane else { return }
            let current = SettingsNavigation.Pane.restored(shortcutPane)
            let next = command == .help ? SettingsNavigation.Pane.help : KeyboardNavigation.adjacent(SettingsNavigation.Pane.allCases, current: current, direction: command == .nextSection ? 1 : -1)
            if let next { choosePane(next) }
        }
        .environment(\.editorProtection, protection).background(EditorWindowGuard(protection: protection).frame(width: 0, height: 0))
        .environment(\.shortcutActions, shortcutActions)
        .focusedSceneValue(\.shortcutActions, shortcutActions).focusedSceneValue(\.shortcutProtection, protection)
        .background(StorebenchSettingsToolbar(selected: SettingsNavigation.Pane.restored(tab)) { pane in
            guard !model.isTerminating else { return }
            choosePane(pane)
        }.frame(width: 0, height: 0))
        .environment(\.recoveryNavigation, RecoveryNavigation(scope: nil, navigate: recover))
        .onAppear { recovery.settingsProtection = protection; updateArea() }
        .onDisappear { if recovery.settingsProtection === protection { recovery.settingsProtection = nil; recovery.selectedArea = nil; recovery.selectedPane = nil } }
        .onChange(of: tab) { updateArea() }
        .onChange(of: recovery.request?.id, initial: true) { receiveRecovery() }
        .onChange(of: recovery.aiRequest, initial: true) {
            guard let id = recovery.aiRequest else { return }
            if recovery.authorizeAI(id, current: protection.policy) { search = ""; searchRequest = nil; tab = "ai" }
            recovery.consumeAI(id)
        }
    }
    private func choosePane(_ pane: SettingsNavigation.Pane) {
        let show: @MainActor @Sendable () -> Void = { search = ""; searchRequest = nil; tab = pane.rawValue }
        if pane.rawValue == tab { show() } else { protection.requestLeaving(show) }
    }
    private func chooseSearchResult(_ result: SettingsSearch.Result) {
        let show: @MainActor @Sendable () -> Void = { tab = result.pane.rawValue; search = ""; searchRequest = SettingsSearchRequest(target: result.id) }
        if result.pane.rawValue == tab { show() } else { protection.requestLeaving(show) }
    }
    @ViewBuilder private var settingsContent: some View {
        switch tab {
        case "periods": PeriodSettings(model: model)
        case "editing": EditingSettings(model: model)
        case "ai": AISettings(model: model)
        case "security": SecuritySettings(model: model)
        case "accounts": AccountSettings(model: model, recoveryRequest: recoveryRequest)
        case "pricing": PricingProfilesSettingsView(model: model)
        case "backups": BackupSettingsView(model: model)
        case "shortcuts": ShortcutSettingsView()
        case "help": HelpSettingsView(requestedTopic: recoveryRequest?.action.target.helpTopic, requestId: recoveryRequest?.id)
        default: GeneralSettings(model: model)
        }
    }
    private func updateArea() {
        recovery.selectedPane = SettingsNavigation.Pane.restored(tab)
        recovery.selectedArea = tab == "accounts" ? .accounts : tab == "general" ? .storage : tab == "help" ? .help : nil
    }
    private func recover(_ action: RecoveryGuidance.Action) {
        switch action.target.area {
        case .accounts, .storage, .help: _ = recovery.open(action)
        case .developerAccount: openURL(URL(string: "https://developer.apple.com/account/")!)
        case .unlock:
            Task { if await EditorWindows.requestClosing(reason: .signOut) { await model.signOut() } }
        default: break
        }
    }
    private func receiveRecovery() {
        guard let request = recovery.request else { return }
        guard recovery.authorize(request.id, current: protection.policy) else { recovery.consume(request.id); return }
        search = ""; searchRequest = nil
        switch request.action.target.area {
        case .accounts: tab = "accounts"
        case .storage: tab = "general"
        case .help: tab = "help"
        default: recovery.consume(request.id); return
        }
        recoveryRequest = request; recovery.consume(request.id)
    }
}
