import StorebenchCore
import SwiftUI

private struct LanguageLayoutKey: EnvironmentKey { static let defaultValue: LanguageLayoutEditor? = nil }
extension EnvironmentValues {
    var languageLayout: LanguageLayoutEditor? {
        get { self[LanguageLayoutKey.self] }
        set { self[LanguageLayoutKey.self] = newValue }
    }
}

struct LanguageLayoutControls: View {
    let editor: LanguageLayoutEditor
    let accountId: String, appId: String, session: WorkspaceSession?
    var body: some View {
        DisclosureGroup("Text section preferences") {
            Text("Choose the text sections shown inside language cards. These choices are remembered for this app across languages and versions.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            StorebenchActionGroup { actions }
            ScrollView {
                Text(editor.failed ? editor.ready ? "View layout could not be saved. Your text is unchanged. Retry the layout save." : "View layout could not be read. Read it again before changing sections." : editor.saving ? "Saving view layout for this app…" : editor.saved ? "View layout saved for this app." : "Collapsing a section keeps your text edits and shows unsaved and text-limit counts.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 48).accessibilityLabel("Language section layout status")
            Button(editor.ready ? "Retry Layout Save" : "Read Layout Again") { guard editor.failed, !editor.saving else { return }; Task { if editor.ready { await flush() } else { await load() } } }
                .storebenchWorking(editor.saving).opacity(editor.failed ? 1 : 0).allowsHitTesting(editor.failed).accessibilityHidden(!editor.failed)
        }.task { if !editor.ready { await load() } }
            .trackUnsavedChanges(false, busy: editor.saving)
    }
    private var actions: some View {
        Group {
            if editor.ready && !editor.layout.expanded.values.allSatisfy({ $0 }) { Button("Expand All Sections") { change(true) } }
            if editor.ready && !editor.layout.expanded.values.allSatisfy({ !$0 }) { Button("Collapse All Sections") { change(false) } }
        }
    }
    private func change(_ value: Bool) {
        editor.change(Dictionary(uniqueKeysWithValues: LanguageEditorLayout.Group.allCases.map { ($0, value) })); Task { await flush() }
    }
    private func load() async {
        guard let session else { return }
        do { let value = try await session.languageEditorLayout(accountId: accountId, appId: appId); try Task.checkCancellation(); editor.loaded(value) }
        catch { if !Task.isCancelled { editor.readFailed() } }
    }
    private func flush() async {
        guard let session else { return }
        await editor.flush { try await session.saveLanguageEditorLayout(accountId: accountId, appId: appId, patch: $0) }
    }
}
