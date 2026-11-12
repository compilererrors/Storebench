import StorebenchCore
import SwiftUI

/// The local working copy of forms whose Apple changes still use their existing guarded review.
struct LocalDraftActions: View {
    let editor: LocalEditorDraftEditor, value: JSONText
    let restore: (JSONText) -> Void
    var blocked = false
    var sync: (() async -> Void)? = nil
    var syncBlocked = false
    var title: String? = nil
    var hint: String? = nil
    var syncTitle = "Sync to Apple"
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            StorebenchEditorFooter(title: title ?? (sync == nil ? "Local Draft" : "Draft and Sync"), detail: editor.status.isEmpty ? (!editor.loaded ? "Read the saved draft to continue." : editor.dirty(value) ? "You have unsaved changes." : "Your draft is saved on this Mac.") : editor.status,
                                  hint: hint ?? (sync == nil ? "Save your inputs here, then use the change's sync command to review it before sending." : "Save Draft keeps your inputs on this Mac. Sync to Apple saves first and opens a review for your approval.")) {
                StorebenchActionGroup(alignment: .trailing) {
                if !editor.loaded {
                    StorebenchBusyButton(title: "Read Draft", loadingTitle: "Reading…", busy: editor.busy) {
                        Task { if let saved = await editor.load(initial: value) { restore(saved) } }
                    }
                }
                StorebenchBusyButton(title: "Save Draft", loadingTitle: "Saving…", busy: editor.busy) { Task { await editor.save(value) } }
                    .storebenchWorking(blocked || !editor.loaded || editor.needsComparison || !editor.dirty(value))
                    .storebenchControlID("draft.save." + editor.scope.editor)
                if let sync {
                    StorebenchBusyButton(title: syncTitle, loadingTitle: "Preparing…", busy: editor.busy, variant: editor.hasChangesToSync(value) ? .primary : .secondary) {
                        Task { if await editor.save(value) { await sync() } }
                    }.storebenchWorking(blocked || !editor.loaded || editor.needsComparison || syncBlocked)
                        .storebenchControlID("draft.sync." + editor.scope.editor)
                }
                }
            }
            if editor.needsComparison || editor.latest != nil {
                LatestSaveReview(busy: editor.busy || blocked, reading: editor.busy, hasEdits: editor.dirty(value), changes: editor.latest.map { comparisons($0.value, value) }, note: nil, onRead: { Task { await editor.readLatest() } }, onKeep: editor.latest == nil ? nil : { _ = editor.acceptLatest(keepEdits: true) }, onUse: editor.latest == nil ? nil : {
                    if let latest = editor.acceptLatest(keepEdits: false) { restore(latest) }
                })
            }
        }.layoutValue(key: StorebenchFullWidthAction.self, value: true)
    }
    private func comparisons(_ saved: JSONText, _ edited: JSONText) -> [SavedValueChange] {
        func fields(_ value: JSONText, path: String = "Local Draft") -> [String: String] {
            switch value {
            case .object(let pairs):
                return pairs.reduce(into: [:]) { result, pair in
                    let name = TextDrafts.labels[pair.0] ?? (AgeRating.frequency + AgeRating.boolean + AgeRating.optional).first { $0.0 == pair.0 }?.1 ?? pair.0.capitalized
                    result.merge(fields(pair.1, path: path == "Local Draft" ? name : path + " · " + name)) { _, next in next }
                }
            case .array(let values): return [path: values.map { fields($0).values.sorted().joined(separator: ", ") }.joined(separator: "\n")]
            case .string(let text): return [path: text.isEmpty ? "Not Set" : text]
            case .bool(let flag): return [path: flag ? "Yes" : "No"]
            case .null: return [path: "Not Set"]
            case .number: return [path: value.stringify()]
            }
        }
        let before = fields(saved), after = fields(edited)
        return Set(before.keys).union(after.keys).sorted().compactMap { key in
            guard before[key] != after[key] else { return nil }
            return .init(id: key, label: key, saved: before[key] ?? "Not Set", edited: after[key] ?? "Not Set")
        }
    }
}
