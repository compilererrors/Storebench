import StorebenchCore
import SwiftUI

struct EditorNavigation: Sendable {
    let scope: RecoveryGuidance.Scope?
    let navigate: (@MainActor @Sendable (AppNavigation.Destination) -> Void)?
    @MainActor func open(_ section: AppNavigation.Section, locale: String?) {
        guard let scope, let context = try? AppNavigation.Context(scope: scope, locale: locale) else { return }
        navigate?(AppNavigation.Destination(source: scope, scope: scope, section: section, context: context))
    }
}
private struct EditorNavigationKey: EnvironmentKey { static let defaultValue = EditorNavigation(scope: nil, navigate: nil) }
extension EnvironmentValues {
    var editorNavigation: EditorNavigation { get { self[EditorNavigationKey.self] } set { self[EditorNavigationKey.self] = newValue } }
}

/// Reads only saved ideas. Applying a selection changes the current unsaved text, never a notebook or Apple.
struct KeywordPickerView: View {
    let scope: RecoveryGuidance.Scope, locale: String, current: String, session: WorkspaceSession?, use: (String) -> Void
    @State private var snapshot: KeywordPickerSnapshot?
    @State private var chosen: Set<String> = []
    @State private var territory = ""
    @State private var sort = ""
    @State private var descending = false
    @State private var page = 1
    @State private var mode = KeywordListingSelection.Mode.append
    @State private var working = false
    @State private var loaded = false
    @State private var message = ""
    @State private var issueCode: String?
    @Environment(\.navigationPresentation) private var history
    private var readKey: String { "keyword-picker/\(scope.accountId)/\(scope.appId)/\(locale)" }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.editorNavigation) private var navigation
    private var matching: [KeywordIdea] { (snapshot?.rows ?? []).filter { territory.isEmpty || (territory == "any" ? $0.territory.isEmpty : $0.territory == territory) } }
    private var rows: Keywords.Page { .init(Keywords.ordered(matching, key: sort, descending: descending, picker: true), requested: page, size: 8) }
    private var selection: KeywordListingSelection? { try? snapshot?.selection(current: current, selected: chosen, mode: mode) }

    var body: some View {
        StorebenchDialog(title: "Choose keyword ideas", wide: true, close: { dismiss() }) {
            StorebenchTextSlot(text: "Saved Ready to try ideas for \(locale). Choose terms and compare the resulting keywords. Using them changes this unsaved editor only; it does not save or publish the listing.", height: 56, font: .sbCallout, color: StorebenchTheme.muted)
            if !loaded && issueCode == nil { StorebenchLoadState(state: .loading("Reading saved keyword ideas…")) { EmptyView() } }
            if loaded {
            VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
                StorebenchFormGrid {
                    StorebenchPicker("Idea territory", selection: $territory) {
                        SelectionOption("All research territories", value: ""); SelectionOption("Any / unspecified", value: "any")
                        selectionOptions(Array(Set((snapshot?.rows ?? []).map(\.territory).filter { !$0.isEmpty })).sorted()) { SelectionOption($0, value: $0) }
                    }
                    StorebenchPicker("Sort", selection: $sort) { SelectionOption("Default order", value: ""); SelectionOption("Keyword", value: "keyword"); SelectionOption("Source", value: "source") }
                }
                StorebenchToggle("Descending", isOn: $descending)
            }.storebenchWorking(working)
            HStack {
                if !matching.isEmpty { Button("Select Matching") { chosen.formUnion(matching.map(\.id)) }.help("Select Matching Keyword Ideas").accessibilityLabel("Select Matching Keyword Ideas") }
                if !chosen.isEmpty { Button("Clear Chosen Ideas") { chosen = [] } }
            }.storebenchWorking(working)
            KeywordRows(rows: rows.rows, chosen: $chosen, picker: true).storebenchWorking(working).frame(maxHeight: 230)
            StorebenchPagination(page: rows.number, count: rows.count) { page = $0 }
            StorebenchPicker("Use chosen keywords", selection: $mode) { SelectionOption("Add to current keywords", value: KeywordListingSelection.Mode.append); SelectionOption("Replace current keywords", value: KeywordListingSelection.Mode.replace) }
            Text("\(selection?.selectedCount ?? 0) selected ideas · \(selection?.bytes ?? 0) of 100 bytes").font(.sbCaption).foregroundStyle(selection?.exceeded == true ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 260) {
                comparison("Current unsaved keywords", current)
                comparison("Proposed unsaved keywords", selection?.proposed ?? "")
            }
            }
            StorebenchTextSlot(text: !message.isEmpty ? message : selection?.exceeded == true ? "This selection exceeds the keyword byte limit. Choose fewer terms or use replacement mode." : "Nothing is saved or sent to Apple by this dialog.", height: 48, font: .sbCallout, color: StorebenchTheme.muted, live: true)
            RecoveryActions(code: issueCode)


        } actions: {
            StorebenchActionGroup(alignment: .trailing) {
                Button("Cancel") { dismiss() }
                if navigation.navigate != nil { Button("Open Keyword Ideas") { if !working { navigation.open(.keywords, locale: locale) } }.storebenchWorking(working) }
                if issueCode != nil { Button("Retry Saved Ideas") { Task { await load() } }.storebenchWorking(working) }

                if loaded && selection?.canUse == true {
                    Button("Use Selection") {
                        guard loaded, !working, let selection, selection.canUse else { return }
                        use(selection.proposed); dismiss()
                    }.help("Use Selection in Editor").accessibilityLabel("Use Selection in Editor").buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(working)
                }

            }
        }
        .task { await load() }
        .onChange(of: territory) { page = 1 }.onChange(of: sort) { page = 1 }.onChange(of: descending) { page = 1 }
        .trackUnsavedChanges(false, busy: working)
    }
    private func comparison(_ label: String, _ text: String) -> some View {
        StorebenchReadOnlyText(title: label, text: text, field: "keywords")
    }
    private func load() async {
        guard !working, let session else { return }; chosen = []; working = true; issueCode = nil; message = "Reading saved ideas…"; defer { working = false }
        // The ideas read earlier in this window show at once; a selection is used only after they are read again.
        if let saved = history?.rememberedRead(readKey, as: KeywordPickerSnapshot.self) { snapshot = saved; loaded = true } else { loaded = false; snapshot = nil }
        do {
            let value = try await session.keywordNotebook(accountId: scope.accountId, appId: scope.appId); try Task.checkCancellation()
            let latest = try KeywordPickerSnapshot(notebook: value.notebook, scope: scope, locale: locale)
            snapshot = latest; loaded = true; message = ""; history?.rememberRead(latest, readKey)
        } catch { loaded = false; snapshot = nil; issueCode = "SB-KEYWORDS-STORAGE"; message = "Saved ideas could not be read. Retry before using a selection." }
    }
}
