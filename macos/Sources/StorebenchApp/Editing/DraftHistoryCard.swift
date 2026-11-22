import AppKit
import StorebenchCore
import SwiftUI

/// Earlier wording from this app's drafts on this Mac, so text that was changed since, such as a promotional text, can be found and used again.
struct DraftHistoryCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var reload = 0
    @State private var changes: [DraftTextChange] = []
    @State private var field = ""
    @State private var status = ""
    private var fields: [String] { Array(Set(changes.map(\.field))).sorted { Self.label($0) < Self.label($1) } }
    private var shown: [DraftTextChange] { field.isEmpty ? changes : changes.filter { $0.field == field } }
    var body: some View {
        Card(title: "Draft History", subtitle: "Earlier text from your drafts on this Mac, newest first. Each save keeps only the fields it changed, and the same text is stored once.") {
            if changes.isEmpty {
                Text("Nothing changed in a saved draft yet. Earlier text appears here after you save a draft.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                StorebenchFormGrid {
                    StorebenchPicker("Field", selection: $field) {
                        SelectionOption("All Fields", value: "")
                        selectionOptions(fields) { SelectionOption(Self.label($0), value: $0) }
                    }
                }
                StorebenchFeedback(text: status, height: 20)
                StorebenchCollection(items: shown, title: { "\(Self.label($0.field)) · \(StoreLocales.name($0.locale))" }, subtitle: { "Saved \(LibraryOverview.timestamp($0.savedAt))" },
                                     preferenceID: "draft-history", empty: "No saved changes for this field.") { change in
                    VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
                        StorebenchStatusList {
                            StorebenchFact(label: "Before", value: change.before.isEmpty ? "Empty" : change.before)
                            StorebenchFact(label: "After", value: change.after.isEmpty ? "Empty" : change.after)
                        }
                        StorebenchActionGroup(alignment: .leading) {
                            Button("Copy Earlier Text") { copy(change.before, change) }.storebenchWorking(change.before.isEmpty)
                                .help("Copy the text from before this save, to paste into the field")
                            Button("Copy Later Text") { copy(change.after, change) }.storebenchWorking(change.after.isEmpty)
                                .help("Copy the text this save kept")
                        }
                    }
                }
            }
        }
        .task(id: "\(account.id)/\(app.id)/\(reload)") {
            guard let session else { return }
            changes = (try? await session.draftTextHistory(accountId: account.id, appId: app.id)) ?? []
            if !field.isEmpty, !changes.contains(where: { $0.field == field }) { field = "" }
        }
    }
    private func copy(_ text: String, _ change: DraftTextChange) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        status = "\(Self.label(change.field)) for \(StoreLocales.name(change.locale)) copied."
    }
    static func label(_ field: String) -> String { TextDrafts.labels[field] ?? field }
}
