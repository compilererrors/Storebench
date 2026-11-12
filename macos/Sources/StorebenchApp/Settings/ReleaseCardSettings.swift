import StorebenchCore
import SwiftUI

struct ReleaseCardSettings: View {
    let model: LibraryModel
    @State private var editor: ReleaseCardsEditor?
    var body: some View {
        StorebenchFormSection("Release Cards", icon: "release", description: "Keep Overview focused on the releases you are working on.") {
            if let editor, let preferences = editor.preferences {
                StorebenchPicker("New Release Cards", selection: Binding(get: { preferences.defaultExpanded }, set: { editor.change(.defaultExpanded($0)) }),
                    hint: "Applies when a release first appears. Existing cards keep your last expand or minimize choice.") {
                    SelectionOption("Expanded", value: true)
                    SelectionOption("Minimized", value: false)
                }.storebenchControlID("settings.release-cards.default")
                StorebenchSettingToggle("Ask When I Minimize All", isOn: Binding(get: { preferences.asksAboutMinimizing }, set: { editor.change(.suggestions($0)) }))
                    .storebenchControlID("settings.release-cards.suggestions")
                Text("After you minimize every release card, Storebench can suggest starting new cards minimized. Ask Later postpones the question for a day; No turns it off until you enable it here.")
                    .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                StorebenchFeedback(text: editor.status, height: 40, error: !editor.status.isEmpty)
                if !editor.status.isEmpty { StorebenchActionGroup { Button("Try Again") { editor.retry() } } }
            } else {
                StorebenchLoadState(state: editor?.status.isEmpty == false
                    ? .failed(editor?.status ?? "Release card settings could not be read.", retry: { await editor?.load() })
                    : model.session == nil ? .failed("Unlock a workspace to change release card preferences.", retry: { await editor?.load() }) : .loading("Reading release card preferences…")) { EmptyView() }
            }
        }.settingsSearchAnchor("general-release-cards")
        .task(id: model.session.map(ObjectIdentifier.init)) {
            guard let session = model.session else { editor = nil; return }
            if editor?.session !== session { editor = ReleaseCardsEditor(session: session) }
            await StorebenchPolling.repeating(every: .seconds(2), while: { !Task.isCancelled }) { await editor?.load() }
        }
    }
}
