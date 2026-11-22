import AppKit
import StorebenchCore
import SwiftUI

/// A choice of several values that is always in view: a field that names what is chosen, like a picker beside it, and opens a
/// dialog with quick choices and every option. A required choice is never folded away.
struct StorebenchMultiSelect: View {
    struct Preset { let title, help: String; let values: Set<String> }
    let title: String
    let dialogTitle: String
    var dialogSubtitle = ""
    @Binding var selection: Set<String>
    let options: [String]
    let name: (String) -> String
    /// A short note after an option's name, such as "In Version"; empty for none.
    var note: (String) -> String = { _ in "" }
    var presets: [Preset] = []
    let summary: String
    var controlID = ""
    /// The prefix of each option's control ID; the field's ID and a dot when empty.
    var optionPrefix = ""
    @State private var open = false
    @State private var focused = false
    var body: some View {
        StorebenchFormField(label: title) {
            // The same macOS selection button as a picker beside it; it opens the dialog rather than a menu.
            StorebenchNativeChoiceButton(title: summary, label: title, focused: $focused) { open = true }
                .padding(.leading, 5).padding(.trailing, 4)
                .frame(minWidth: 0, maxWidth: .infinity)
                .modifier(StorebenchFieldSurface(focused: focused))
                .help(summary + ". Choose to change.")
                .storebenchControlID(controlID)
        }
        .sheet(isPresented: $open) {
            StorebenchDialog(title: dialogTitle, kind: .content, subtitle: dialogSubtitle, close: { open = false }) {
                StorebenchChipGroup {
                    ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                        Button(preset.title) { selection = preset.values }.help(preset.help)
                            .storebenchControlID(controlID + ".preset." + preset.title.lowercased().replacingOccurrences(of: " ", with: "-"))
                    }
                    Button("None") { selection = [] }.storebenchWorking(selection.isEmpty).help("Choose none").storebenchControlID(controlID + ".none")
                }
                StorebenchOptionGrid(maximumColumns: 3, minimumWidth: 200) {
                    ForEach(options, id: \.self) { option in
                        let note = note(option)
                        StorebenchToggle(name(option) + (note.isEmpty ? "" : " · " + note),
                                         isOn: Binding(get: { selection.contains(option) }, set: { if $0 { selection.insert(option) } else { selection.remove(option) } }))
                            .storebenchControlID((optionPrefix.isEmpty ? controlID + "." : optionPrefix) + option)
                    }
                }
            } actions: {
                StorebenchActionRow {
                    Text(selection.isEmpty ? "None chosen" : "\(selection.count) chosen").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                } actions: {
                    Button("Done") { open = false }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchControlID(controlID + ".done")
                }
            }
        }
    }
}

/// A macOS selection button, drawn exactly like the app's pickers, that runs `open` instead of showing a menu: for a choice
/// made in a dialog, such as several languages at once.
struct StorebenchNativeChoiceButton: NSViewRepresentable {
    let title: String
    let label: String
    @Binding var focused: Bool
    let open: () -> Void
    func makeNSView(context: Context) -> ChoiceButton {
        let view = ChoiceButton(frame: .zero, pullsDown: false)
        view.isTransparent = false; view.isBordered = false
        (view.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        view.focusRingType = .none; view.controlSize = .large
        view.font = .systemFont(ofSize: StorebenchTheme.measure("inputFont"))
        view.cell?.lineBreakMode = .byTruncatingMiddle
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: ChoiceButton, context: Context) {
        view.open = open
        let binding = $focused
        view.focusChanged = { value in if binding.wrappedValue != value { binding.wrappedValue = value } }
        view.isEnabled = context.environment.isEnabled
        if view.itemTitles != [title] { view.removeAllItems(); view.addItem(withTitle: title) }
        view.setAccessibilityLabel(label); view.setAccessibilityValue(title)
    }
    static func dismantleNSView(_ view: ChoiceButton, coordinator: ()) { view.open = nil; view.focusChanged = nil }

    final class ChoiceButton: NSPopUpButton {
        var open: (() -> Void)?
        var focusChanged: ((Bool) -> Void)?
        override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); if accepted { focusChanged?(true) }; return accepted }
        override func resignFirstResponder() -> Bool { let accepted = super.resignFirstResponder(); if accepted { focusChanged?(false) }; return accepted }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: StorebenchTheme.controlHeight) }
        override func mouseDown(with event: NSEvent) { if isEnabled { open?() } }
        override func performClick(_ sender: Any?) { if isEnabled { open?() } }
        override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; open?(); return true }
        override func keyDown(with event: NSEvent) {
            // Space, Return and the arrow keys open a pop-up button's choices; here they open the dialog.
            let keys: [Character] = [" ", "\r", Character(UnicodeScalar(NSUpArrowFunctionKey)!), Character(UnicodeScalar(NSDownArrowFunctionKey)!)]
            if isEnabled, let key = event.charactersIgnoringModifiers?.first, keys.contains(key) { open?() } else { super.keyDown(with: event) }
        }
    }
}
