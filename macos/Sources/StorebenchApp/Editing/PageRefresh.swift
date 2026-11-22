import StorebenchCore
import SwiftUI

struct PageRefreshContext {
    let owner: EditorRefresh
    let scope: String
}
private struct PageRefreshKey: EnvironmentKey { static var defaultValue: PageRefreshContext? { nil } }
extension EnvironmentValues {
    var pageRefresh: PageRefreshContext? { get { self[PageRefreshKey.self] } set { self[PageRefreshKey.self] = newValue } }
}
private struct PageRefreshParticipant: ViewModifier {
    let generation: String, priority: Int
    let state: @MainActor () -> EditorRefresh.State
    let save: (@MainActor () async -> Bool)?
    let discard: (@MainActor () -> Bool)?
    let refresh: @MainActor () async -> Bool
    @State private var id = UUID()
    @Environment(\.pageRefresh) private var context
    func body(content: Content) -> some View {
        content.onAppear { register() }
            .onChange(of: generation) { register() }
            .onChange(of: context?.scope) { register() }
            .onDisappear { context?.owner.remove(id) }
    }
    private func register() {
        guard let context else { return }
        context.owner.register(id: id, scope: context.scope, generation: generation, priority: priority, state: state, save: save, discard: discard, refresh: refresh)
    }
}
extension View {
    func pageRefreshParticipant(_ generation: String, priority: Int = 0,
                                state: @escaping @MainActor () -> EditorRefresh.State,
                                save: (@MainActor () async -> Bool)? = nil, discard: (@MainActor () -> Bool)? = nil,
                                refresh: @escaping @MainActor () async -> Bool) -> some View {
        modifier(PageRefreshParticipant(generation: generation, priority: priority, state: state, save: save, discard: discard, refresh: refresh))
    }
}

struct PageRefreshConfirmation: View {
    let confirmation: EditorRefresh.Confirmation
    let choose: (EditorRefresh.Choice) -> Void
    var body: some View {
        StorebenchDialog(title: "Save Changes Before Refreshing?", kind: .confirmation, subtitle: "Refresh Status updates the cards in this release step.") {
            Text("Save keeps your edits as local drafts. Discard restores the saved drafts before refreshing. Cancel keeps editing. Nothing is sent to Apple.")
                .font(.sbCallout).fixedSize(horizontal: false, vertical: true)
        } actions: {
            StorebenchActionGroup(alignment: .trailing) {
                Button("Cancel", role: .cancel) { choose(.cancel) }.storebenchControlID("page.refresh.cancel")
                Button("Discard", role: .destructive) { choose(.discard) }.storebenchWorking(!confirmation.canDiscard).storebenchControlID("page.refresh.discard")
                Button("Save") { choose(.save) }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(!confirmation.canSave).storebenchControlID("page.refresh.save")
            }
        }
    }
}
