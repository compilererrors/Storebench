import StorebenchCore
import SwiftUI

/// A read-only snapshot keeps the comparison stable while the editor waits underneath.
struct LanguageChangesView: View {
    let editor: LanguageEditorState
    let locale: String
    let localDraft: Bool
    let close: () -> Void
    @State private var baseline = "imported"
    private var baselineTitle: String { baseline == "saved" ? "Loaded Draft" : localDraft ? "Starting Draft" : "Last Apple Import" }
    private func before(_ field: LanguageEditorState.Field) -> String { baseline == "saved" ? editor.saved(field) : editor.original(field) }
    private var changed: [LanguageEditorState.Field] { editor.fields.filter { baseline == "saved" ? editor.unsaved($0) : editor.differsFromImport($0) } }
    var body: some View {
        StorebenchDialog(title: StoreLocales.name(locale) + " · Changes", wide: true, height: 680,
                         subtitle: "Compare the current text with its import or the draft loaded in this editor.", close: close) {
            StorebenchPicker("Compare With", selection: $baseline) {
                SelectionOption(localDraft ? "Starting Draft" : "Last Apple Import", value: "imported")
                SelectionOption("Loaded Draft", value: "saved")
            }.environment(\.fieldHintHeight, 0).storebenchControlID("language.diff.baseline")
            StorebenchHeader {
                Text("\(changed.count) Changed \(changed.count == 1 ? "Field" : "Fields")").font(.sbHeadline)
            } actions: {
                HStack(spacing: 16) {
                    Text("Removed").strikethrough().foregroundStyle(StorebenchTheme.color("color-danger"))
                    Text("Added").bold().foregroundStyle(StorebenchTheme.color("color-success"))
                }.font(.sbCaption)
            }
            if changed.isEmpty {
                Text("The current text matches \(baselineTitle.lowercased()).").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            }
            ForEach(changed) { field in
                StorebenchCardSection(title: field.label) {
                    StorebenchTextDifference(segments: AsoProgress.wordDiff(before(field), editor.value(field)))
                        .storebenchControlID("language.diff.field." + field.key)
                    DisclosureGroup("Before and After") {
                        StorebenchReadOnlyText(title: baselineTitle, text: before(field).isEmpty ? "Empty" : before(field), height: 120)
                        StorebenchReadOnlyText(title: "Current Editor", text: editor.value(field).isEmpty ? "Empty" : editor.value(field), height: 120)
                    }
                }
            }
        } actions: {
            Button("Back to Editor", action: close).buttonStyle(StorebenchButtonStyle(.primary))
                .storebenchControlID("language.diff.close")
        }
        .task {
            if !editor.fields.contains(where: { editor.differsFromImport($0) }), editor.dirty { baseline = "saved" }
        }
    }
}
