import AppKit
import StorebenchCore
import SwiftUI

@main
struct StorebenchApp: App {
    @State private var model = LibraryModel()
    @State private var recovery = RecoveryCoordinator()
    @State private var shortcuts = StorebenchShortcutSettings()
    @NSApplicationDelegateAdaptor(StorebenchApplicationDelegate.self) private var applicationDelegate

    init() { NSApplication.shared.setActivationPolicy(.regular); StorebenchAppearancePreferences.shared.applyNativeAppearance() }

    var body: some Scene {
        Group {
            Window("Storebench", id: WindowLifecycle.workspaceID) {
                RootView(model: model, recovery: recovery)
                    .environment(\.shortcutSettings, shortcuts)
                    .modifier(StorebenchAppearance())
                    .modifier(StorebenchViewport())
                    .frame(minWidth: 760, minHeight: 520)
                    .task {
                        applicationDelegate.prepareToTerminate = { await model.prepareToTerminate() }
                        model.cachePolicy = CachePolicy.stored(in: .standard); await model.start()
                    }
            }
            .defaultSize(width: 1280, height: 840)
            Settings { SettingsView(model: model, recovery: recovery).environment(\.shortcutSettings, shortcuts).environment(\.confirmDestructive, DestructiveConfirm(model: model)).modifier(StorebenchAppearance()).modifier(StorebenchViewport()).frame(width: StorebenchTheme.settingsWindow.width, height: StorebenchTheme.settingsWindow.height) }
                .windowResizability(.contentSize)
        }
        .commands {
            StorebenchCommands(shortcuts: shortcuts)
            StorebenchWindowCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About Storebench") { StorebenchAbout.show() }
            }
            CommandGroup(after: .appSettings) {
                Button("Sign Out") {
                    Task { if await EditorWindows.requestClosing(reason: .signOut) { await model.signOut() } }
                }.disabled(model.session == nil || model.lockMode != .password || model.isTerminating)
            }
        }
    }
}

typealias LibraryModel = WorkspaceController
