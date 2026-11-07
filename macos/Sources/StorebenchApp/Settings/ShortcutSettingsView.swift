import StorebenchCore
import SwiftUI

struct ShortcutSettingsView: View {
    @Environment(\.shortcutSettings) private var settings
    @State private var query = ""
    @State private var restoring = false
    @State private var editing: Edit?
    private struct Edit: Identifiable { let id = UUID(); let command: ShortcutCommand }
    var body: some View {
        StorebenchForm {
            Card(title: "Keyboard shortcuts", subtitle: "Customize actions and navigation. Shortcuts apply to the active window. Command+Comma always opens Settings.") {
                HStack(spacing: StorebenchTheme.space(3)) {
                    StorebenchSearchField("Search actions or sections", text: $query)
                    Button("Restore Defaults") { if settings?.recording != true { restoring = true } }.storebenchWorking(settings?.recording == true).fixedSize()
                }
                StorebenchFeedback(text: settings?.issue ?? "", height: 48)
                Text("Tab moves between controls. Arrow keys move focus in the sidebar and section tabs; Return or Space opens the focused section. Next section: \(settings?.keymap.binding(.nextSection)?.display ?? "Unassigned"). Previous section: \(settings?.keymap.binding(.previousSection)?.display ?? "Unassigned").")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(["Actions", "Navigation"], id: \.self) { group in
                let commands = ShortcutCommand.allCases.filter { $0.group == group && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
                if !commands.isEmpty {
                    StorebenchFormSection(group) {
                        StorebenchStatusList {
                            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                                StorebenchStatusRow(title: command.title, detail: command == .settings ? "Fixed macOS shortcut" : settings?.keymap.overrides[command.rawValue] != nil ? "Custom" : "Default", separator: index < commands.count - 1) {
                                    StorebenchTextSlot(text: settings?.keymap.binding(command)?.display ?? "Unassigned", height: 44, font: .sbCallout)
                                } action: {
                                    if command != .settings { Button("Change") { editing = Edit(command: command) } }
                                } details: { EmptyView() }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { edit in
            if let settings { ShortcutEditor(command: edit.command, settings: settings, close: { editing = nil }) }
        }
        .confirmationDialog("Restore all default shortcuts?", isPresented: $restoring) {
            Button("Restore Defaults") { settings?.restore() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your custom combinations will be removed. No app data changes.") }
    }
}

private struct ShortcutEditor: View {
    let command: ShortcutCommand, settings: StorebenchShortcutSettings, close: () -> Void
    @State private var draft: String
    @State private var recordingOwner = UUID()
    private let baseline: String
    init(command: ShortcutCommand, settings: StorebenchShortcutSettings, close: @escaping () -> Void) {
        self.command = command; self.settings = settings; self.close = close
        let value = settings.keymap.binding(command)?.specification ?? "none"
        baseline = value; _draft = State(initialValue: value)
    }
    var body: some View {
        StorebenchDialog(title: command.title, height: 440, close: close) {
            Text("Choose Record Shortcut, then press the combination. Use Command or Control. Reserved combinations and conflicts keep the current shortcut.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchLabeledContent("New shortcut") {
                Text(draft == "none" ? "None" : (try? ShortcutBinding(specification: draft))?.display ?? draft)
                    .font(.sbBody.monospaced()).frame(maxWidth: .infinity, minHeight: StorebenchTheme.controlHeight, alignment: .leading)
            }
            StorebenchShortcutRecorder(recordingChanged: { settings.recording($0, owner: recordingOwner) }, captured: { draft = $0.specification })
                .frame(height: 36).accessibilityLabel("Record shortcut for " + command.title)
            StorebenchActionGroup {
                Button("Remove Shortcut") { draft = "none" }
                Button("Use Default") { draft = command.defaultSpecification ?? "none" }
            }
            StorebenchFeedback(text: settings.issue, height: 48)
        } actions: {
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            Button("Use Shortcut") { if settings.assign(command, specification: draft) { close() } }
                .buttonStyle(StorebenchButtonStyle(.primary)).keyboardShortcut(.defaultAction).storebenchWorking(settings.recording)
        }
        .trackUnsavedChanges(draft != baseline)
        .onAppear { settings.issue = "" }.onDisappear { settings.recording(false, owner: recordingOwner) }
    }
}
