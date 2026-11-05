import StorebenchCore
import SwiftUI

private struct DraftWorkflowBusyKey: EnvironmentKey { static let defaultValue = false }
private struct EditingPreferencesKey: EnvironmentKey { static let defaultValue: EditingPreferences? = nil }
extension EnvironmentValues {
    var draftWorkflowBusy: Bool { get { self[DraftWorkflowBusyKey.self] } set { self[DraftWorkflowBusyKey.self] = newValue } }
    var editingPreferences: EditingPreferences? { get { self[EditingPreferencesKey.self] } set { self[EditingPreferencesKey.self] = newValue } }
}

private struct DraftAutosaveModifier: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.draftWorkflowBusy) private var workflowBusy
    let controller: DraftAutosave
    let input: DraftAutosave.Input
    let save: @MainActor () async -> Bool
    func body(content: Content) -> some View {
        let request = input.blocking(!enabled || workflowBusy)
        return content.onAppear { controller.update(request, save: save) }
            .onChange(of: request) { controller.update(request, save: save) }
            .onDisappear { controller.stop() }
    }
}
extension View {
    func autosaveDraft(_ controller: DraftAutosave, identity: String, signature: String, enabled: Bool, dirty: Bool, blocked: Bool,
                       save: @escaping @MainActor () async -> Bool) -> some View {
        modifier(DraftAutosaveModifier(controller: controller, input: .init(identity: identity, signature: signature, enabled: enabled, dirty: dirty, blocked: blocked), save: save))
    }
}

@MainActor func draftAutosaveStatus(_ preferences: EditingPreferences?, controller: DraftAutosave) -> String {
    guard let preferences else { return "Editing preferences unavailable. Save drafts with the local save button." }
    guard preferences.autosaveDrafts else { return "Save drafts with the local save button." }
    return controller.phase == .paused ? "Autosave paused. Compare the latest save or choose Save to retry." : "Autosave saves local changes after a short pause."
}

enum MediaInputChanges {
    static func compare(_ saved: MediaDraftInputs, _ edited: MediaDraftInputs, names: [(String, String)]) -> [SavedValueChange] {
        let labels = Dictionary(names, uniquingKeysWith: { _, last in last })
        func describe(_ ids: [String]) -> String { ids.map { (labels[$0] ?? "Media") + " · " + $0 }.joined(separator: "\n") }
        var rows = [SavedValueChange(id: "order", label: "Media order", saved: describe(saved.order), edited: describe(edited.order)),
                    SavedValueChange(id: "included", label: "Included media", saved: describe(saved.order.filter { !saved.hidden.contains($0) }), edited: describe(edited.order.filter { !edited.hidden.contains($0) }))]
        if !saved.posterTimes.isEmpty || !edited.posterTimes.isEmpty {
            func posters(_ values: MediaDraftInputs) -> String { values.order.compactMap { id in values.posterTimes[id].map { (labels[id] ?? "Media") + " · " + String($0) + " s" } }.joined(separator: "\n") }
            rows.append(.init(id: "posters", label: "Poster frames", saved: posters(saved), edited: posters(edited)))
        }
        return rows.filter { !$0.saved.utf8.elementsEqual($0.edited.utf8) }
    }
}

struct MediaLayoutReview: View {
    let editor: MediaLayoutEditor, workflow: ListingSaveWorkflow
    @Environment(\.draftWorkflowBusy) private var workflowBusy
    private var differences: [SavedValueChange]? { editor.latest.map { MediaInputChanges.compare($0.inputs, editor.inputs, names: $0.names) } }
    var body: some View {
        LatestSaveReview(busy: editor.busy || workflowBusy, reading: editor.readingLatest, hasEdits: editor.dirty || editor.needsComparison, available: editor.draft != nil, changes: differences,
            note: "New or removed media follows the reviewed catalog. Kept edits preserve choices for media still available.",
            onRead: { Task { if !workflow.busy { await editor.readLatest() } } },
            onKeep: editor.latest == nil || editor.draft == nil ? nil : { if !workflow.busy { editor.acceptLatest(keepEdits: true) } },
            onUse: editor.latest == nil ? nil : { if !workflow.busy { editor.acceptLatest(keepEdits: false) } })
    }
}
