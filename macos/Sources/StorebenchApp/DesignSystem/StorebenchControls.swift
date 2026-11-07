import AppKit
import Foundation
import StorebenchCore
import SwiftUI

/// Command menus share the control geometry while macOS manages opening and keyboard navigation.
struct StorebenchMenu<Content: View>: View {
    let title, icon: String
    var stretch = false
    @ViewBuilder let content: () -> Content

    init(_ title: String, icon: String, stretch: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.icon = icon; self.stretch = stretch; self.content = content
    }
    var body: some View {
        Menu { content().nativeMenuContent() } label: {
            HStack(spacing: 8) {
                StorebenchLabel(title, icon: icon, size: 16).lineLimit(1)
                Spacer(minLength: 0)
                StorebenchIcon(name: "down", size: 14)
            }
        }.menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(StorebenchButtonStyle(stretch: stretch))
            .help(title).accessibilityLabel(title)
    }
}

extension View {
    /// App colors and custom button drawing must not become native menu-item attributes.
    func nativeMenuContent() -> some View { font(.body).foregroundStyle(.primary).buttonStyle(.automatic).tint(nil) }
}

/// The entire field is one native pop-up control. macOS owns menu text, selection and keyboard tracking.
struct StorebenchNativePicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [SelectionOption<Value>]
    @State private var focused = false
    @State private var hovered = false
    private var available: Bool { options.contains(where: \.isEnabled) && Set(options.map(\.value)).count == options.count }
    private var selected: String { SelectionOption.title(for: selection, in: options) ?? (options.isEmpty ? "No options available" : "Choose…") }
    var body: some View {
        StorebenchSelectionLabel(text: selected)
            .modifier(StorebenchControlSurface(variant: .field, stretch: true, emphasized: hovered, focused: focused))
            .accessibilityHidden(true)
            .overlay {
                NativeSelectionControl(title: title, selection: $selection, options: options, focusChanged: { focused = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(false)
            }
            .disabled(!available).onHover { hovered = $0 }
    }
}

private struct NativeSelectionControl<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [SelectionOption<Value>]
    let focusChanged: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SelectionPopUpButton {
        let view = SelectionPopUpButton(frame: .zero, pullsDown: false)
        view.isTransparent = true; view.focusRingType = .none; view.controlSize = .large
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.target = context.coordinator; view.action = #selector(Coordinator.choose(_:))
        view.prepareForOpening = { [weak coordinator = context.coordinator] in coordinator?.refresh() }
        context.coordinator.view = view
        return view
    }
    func updateNSView(_ view: SelectionPopUpButton, context: Context) {
        context.coordinator.parent = self
        view.focusChanged = focusChanged
        view.isEnabled = context.environment.isEnabled && context.environment.collectionVisible && options.contains(where: \.isEnabled) && Set(options.map(\.value)).count == options.count
        context.coordinator.refresh()
    }
    static func dismantleNSView(_ view: SelectionPopUpButton, coordinator: Coordinator) {
        coordinator.active = false; view.target = nil; view.action = nil; view.focusChanged = nil; view.prepareForOpening = nil; view.menu?.delegate = nil
    }
    final class CapturedChoice: NSObject {
        let option: SelectionOption<Value>
        init(_ option: SelectionOption<Value>) { self.option = option }
    }
    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var parent: NativeSelectionControl
        weak var view: SelectionPopUpButton?
        var active = true, tracking = false
        var rendered: [SelectionOption<Value>]?
        var placeholderShown = false
        init(_ parent: NativeSelectionControl) { self.parent = parent }
        func refresh() {
            guard active, !tracking, let view else { return }
            let index = parent.options.firstIndex(where: { $0.value == parent.selection })
            let missing = index == nil
            if rendered != parent.options || placeholderShown != missing {
                let menu = NSMenu(title: parent.title); menu.autoenablesItems = false; menu.delegate = self
                if missing {
                    let placeholder = NSMenuItem(title: parent.options.isEmpty ? "No options available" : "Choose…", action: nil, keyEquivalent: "")
                    placeholder.isEnabled = false; menu.addItem(placeholder)
                }
                for option in parent.options {
                    let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                    item.isEnabled = option.isEnabled; item.toolTip = option.detail
                    item.representedObject = CapturedChoice(option); menu.addItem(item)
                }
                view.menu = menu; rendered = parent.options; placeholderShown = missing
            }
            view.selectItem(at: index.map { $0 + (placeholderShown ? 1 : 0) } ?? 0)
            let detail = index.map { parent.options[$0].detail ?? parent.options[$0].title } ?? (parent.options.isEmpty ? "No options available" : "Choose…")
            // A tooltip only when the option explains more than its title shows.
            view.toolTip = index.flatMap { parent.options[$0].detail }; view.setAccessibilityLabel(parent.title); view.setAccessibilityValue(detail)
            view.setAccessibilityHelp("Choose an option. " + detail)
            view.menu?.minimumWidth = max(0, view.bounds.width)
        }
        func menuWillOpen(_ menu: NSMenu) { tracking = true; menu.minimumWidth = max(0, view?.bounds.width ?? 0) }
        func menuDidClose(_ menu: NSMenu) {
            tracking = false
            // Preserve the captured item until AppKit sends its action. Cancelled menus refresh before their next opening.
        }
        @objc func choose(_ sender: NSPopUpButton) {
            guard active, sender.isEnabled, let captured = sender.selectedItem?.representedObject as? CapturedChoice,
                  let value = SelectionOption.resolve(captured.option, in: parent.options) else { refresh(); return }
            parent.selection = value; refresh()
        }
    }
}

private final class SelectionPopUpButton: NSPopUpButton {
    var focusChanged: ((Bool) -> Void)?
    var prepareForOpening: (() -> Void)?
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: StorebenchTheme.controlHeight) }
    override func mouseDown(with event: NSEvent) { prepareForOpening?(); super.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) { prepareForOpening?(); super.keyDown(with: event) }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder(); if accepted { focusChanged?(true) }; return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { let changed = focusChanged; Task { @MainActor in changed?(false) } }
        return accepted
    }
}

struct StorebenchActionLink: View {
    let title: String
    let destination: URL
    var icon = "external"
    /// The full destination when the short title alone would not name it.
    var fullTitle: String
    @Environment(\.openURL) private var openURL

    init(_ title: String, destination: URL, icon: String = "external", help: String? = nil) {
        self.title = title; self.destination = destination; self.icon = icon; self.fullTitle = help ?? title
    }
    var body: some View {
        Button { openURL(destination) } label: { StorebenchLabel(title, icon: icon, size: 16) }
            .buttonStyle(StorebenchButtonStyle()).help(fullTitle).accessibilityLabel(fullTitle)
            .accessibilityRemoveTraits(.isButton).accessibilityAddTraits(.isLink)
    }
}

struct StorebenchTextLink: View {
    let title: String
    let destination: URL
    init(_ title: String, destination: URL) { self.title = title; self.destination = destination }
    var body: some View {
        Link(destination: destination) {
            HStack(spacing: StorebenchTheme.space(2)) {
                Text(title).underline().lineLimit(2).fixedSize(horizontal: false, vertical: true)
                StorebenchIcon(name: "external", size: 14)
            }.font(.sbBody).foregroundStyle(StorebenchTheme.color("color-accent-muted"))
                .frame(minHeight: 28, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

struct StorebenchFormField<Content: View>: View {
    let label: String
    var hint = ""
    var hideLabel = false
    var hideHint = false
    var info = ""
    @ViewBuilder let content: () -> Content
    @Environment(\.fieldHintHeight) private var hintHeight
    @Environment(\.settingsPresentation) private var settingsPresentation
    @Environment(\.fieldNeeded) private var needed
    var body: some View {
        Group {
            if settingsPresentation && !hideLabel {
                // Settings rows: the label column takes the remaining width and the control keeps one shared column,
                // so every control in a pane starts on the same edge. Narrow sheets stack the control below its label.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: StorebenchTheme.space(4)) {
                        settingsCopy.frame(minWidth: StorebenchTheme.settingsLabelWidth, idealWidth: StorebenchTheme.settingsLabelWidth, maxWidth: .infinity, alignment: .leading)
                        content().frame(width: StorebenchTheme.settingsControlWidth, alignment: .leading).frame(minHeight: StorebenchTheme.controlHeight)
                    }
                    VStack(alignment: .leading, spacing: StorebenchTheme.measure("fieldGap")) {
                        fieldLabel
                        content().frame(maxWidth: .infinity, alignment: .leading)
                        fieldHint
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: StorebenchTheme.measure("fieldGap")) {
                    if !hideLabel { fieldLabel }
                    content().frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(StorebenchControlOutline(border: needed == nil ? .clear : StorebenchTheme.color("color-danger-border"), focusedOverride: false).allowsHitTesting(false))
                    fieldHint
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    /// The label sits level with the control's text line; a hint continues below it in the same column.
    private var settingsCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            fieldLabel
            if !hideHint && !hint.isEmpty { StorebenchAdaptiveText(text: hint, maximumHeight: StorebenchTheme.textTrackLimit, font: .sbCaption, color: StorebenchTheme.muted) }
        }.padding(.top, max(0, (StorebenchTheme.controlHeight - StorebenchTheme.measure("fieldLabel")) / 2))
    }
    private var fieldLabel: some View {
        HStack(alignment: .center, spacing: StorebenchTheme.space(1)) {
            StorebenchTextSlot(text: label, height: StorebenchTheme.measure("fieldLabel"), font: .sbCallout.weight(.semibold), color: StorebenchTheme.color("color-text-secondary"))
                .fixedSize(horizontal: !info.isEmpty, vertical: false)
            if !info.isEmpty { StorebenchInfoTip(title: label, text: info); Spacer(minLength: 0) }
        }
    }
    /// The hint, or why this field is the one to fill in next, in the hint's own track so nothing moves.
    @ViewBuilder private var fieldHint: some View {
        if let needed, !hideHint {
            StorebenchTextSlot(text: needed, height: hintHeight ?? StorebenchTheme.measure("fieldHint"), font: .sbCaption.weight(.semibold), color: StorebenchTheme.color("color-danger"))
        } else if !hideHint && (!hint.isEmpty || (hintHeight ?? 0) > 0) {
            StorebenchTextSlot(text: hint, height: hintHeight ?? StorebenchTheme.measure("fieldHint"), font: .sbCaption, color: StorebenchTheme.muted)
        }
    }
}

struct StorebenchTextField: View {
    private let title: String, hint: String
    private let control: AnyView
    private var hidden = false
    private var info = ""
    /// `contentType` lets macOS AutoFill offer saved values, such as a username.
    init(_ title: String, text: Binding<String>, hint: String = "", placeholder: String? = nil, contentType: NSTextContentType? = nil) {
        self.title = title; self.hint = hint
        control = AnyView(TextField("", text: text, prompt: Text(placeholder ?? "").foregroundColor(StorebenchTheme.muted)).textFieldStyle(StorebenchTextFieldStyle())
            .textContentType(contentType).accessibilityLabel(title))
    }
    init<F: ParseableFormatStyle>(_ title: String, value: Binding<F.FormatInput>, format: F, hint: String = "") where F.FormatOutput == String, F.FormatInput: Equatable {
        self.title = title; self.hint = hint
        control = AnyView(TextField("", value: value, format: format).textFieldStyle(StorebenchTextFieldStyle()).accessibilityLabel(title))
    }
    func labelsHidden() -> Self { var copy = self; copy.hidden = true; return copy }
    func info(_ text: String) -> Self { var copy = self; copy.info = text; return copy }
    var body: some View {
        StorebenchFormField(label: title, hint: hint, hideLabel: hidden, hideHint: hidden, info: info) { control }
    }
}

struct StorebenchSearchField: View {
    let title: String
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    private var focusOnAppear = false
    init(_ title: String, text: Binding<String>) { self.title = title; _text = text }
    /// Places the cursor in the field when it appears, for search that opens on request.
    func focusedOnAppear() -> Self { var copy = self; copy.focusOnAppear = true; return copy }
    var body: some View {
        HStack(spacing: StorebenchTheme.space(2)) {
            StorebenchIcon(name: "keywords", size: 16).foregroundStyle(StorebenchTheme.muted).accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(title).foregroundColor(StorebenchTheme.muted))
                .textFieldStyle(.plain).font(.system(size: StorebenchTheme.measure("inputFont")))
                .focused($focused).accessibilityLabel(title)
            Button { text = ""; focused = true } label: { StorebenchIcon(name: "close", size: 14) }
                .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon))
                .opacity(text.isEmpty ? 0 : 1).disabled(text.isEmpty)
                .accessibilityHidden(text.isEmpty).accessibilityLabel("Clear " + title).help("Clear search")
        }.padding(.leading, StorebenchTheme.space(3)).frame(height: StorebenchTheme.controlHeight)
            .foregroundStyle(enabled ? StorebenchTheme.ink : StorebenchTheme.subtle)
            .background(enabled ? StorebenchTheme.surface : StorebenchTheme.color("color-surface-sunken"), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
            .overlay(StorebenchControlOutline(focusedOverride: focused))
            .onAppear { if focusOnAppear { Task { @MainActor in focused = true } } }
    }
}

/// A fixed list too long for a menu, such as countries: the field opens a list that narrows as you type, and only a listed
/// entry can be chosen. Typed text filters the list and is never saved as the value.
struct StorebenchSearchPicker<Value: Hashable>: View {
    let title: String
    var hint = ""
    @Binding var selection: Value
    let options: [SelectionOption<Value>]
    private var hideLabel = false
    @State private var open = false
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    init(_ title: String, selection: Binding<Value>, hint: String = "", @SelectionOptionsBuilder<Value> content: () -> [SelectionOption<Value>]) {
        self.title = title; self.hint = hint; _selection = selection; options = content()
    }
    func labelsHidden() -> Self { var copy = self; copy.hideLabel = true; return copy }
    private var selected: String { SelectionOption.title(for: selection, in: options) ?? (options.isEmpty ? "No options available" : "Choose…") }
    var body: some View {
        StorebenchFormField(label: title, hint: hint, hideLabel: hideLabel, hideHint: hideLabel) {
            Button { if enabled { open = true } } label: { StorebenchSelectionLabel(text: selected).foregroundStyle(SelectionOption.title(for: selection, in: options) == nil ? StorebenchTheme.muted : StorebenchTheme.ink) }
                .buttonStyle(StorebenchButtonStyle(.field, stretch: true))
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    StorebenchSearchList(title: title, selection: $selection, options: options) { open = false }
                }
                .accessibilityLabel(title).accessibilityValue(selected).accessibilityHint("Opens a searchable list")
        }
    }
}

private struct StorebenchSearchList<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [SelectionOption<Value>]
    let close: () -> Void
    @State private var query = ""
    @State private var highlighted: Value?
    private var matches: [SelectionOption<Value>] {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return options }
        return options.filter { option in
            let text = option.title + " " + (option.detail ?? "")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            StorebenchSearchField("Search " + title.lowercased(), text: $query).focusedOnAppear()
                .onSubmit { if let value = highlighted ?? matches.first(where: \.isEnabled)?.value { choose(value) } }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { option in row(option).id(option.value) }
                    }
                }.frame(height: min(264, max(28, CGFloat(matches.count) * 28)))
                    .onChange(of: highlighted) { if let highlighted { scroll.scrollTo(highlighted) } }
                    .onAppear {
                        highlighted = selection
                        // The lazy list has rows to scroll to only after its first layout pass.
                        Task { @MainActor in scroll.scrollTo(selection, anchor: .center) }
                    }
            }
            StorebenchTextSlot(text: matches.isEmpty ? "No matches. Try a shorter search." : "\(matches.count) of \(options.count)", height: 16, font: .sbCaption, color: StorebenchTheme.muted, live: true)
        }.padding(StorebenchTheme.space(3)).frame(width: 340)
            .onChange(of: query) { highlighted = matches.first(where: \.isEnabled)?.value }
    }
    private func row(_ option: SelectionOption<Value>) -> some View {
        let chosen = option.value == selection, active = option.value == highlighted
        return Button { choose(option.value) } label: {
            HStack(spacing: StorebenchTheme.space(2)) {
                Text(option.title).font(.sbBody).lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                StorebenchIcon(name: "check", size: 14).opacity(chosen ? 1 : 0)
            }.padding(.horizontal, StorebenchTheme.space(2)).frame(minHeight: 28)
                .foregroundStyle(option.isEnabled ? active ? StorebenchTheme.color("color-on-control") : StorebenchTheme.ink : StorebenchTheme.subtle)
                .background(active && option.isEnabled ? StorebenchTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!option.isEnabled)
            .onHover { if $0 && option.isEnabled { highlighted = option.value } }
            .help(option.detail ?? "").accessibilityLabel(option.title).accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
    private func move(_ direction: Int) {
        let enabled = matches.filter(\.isEnabled).map(\.value)
        guard !enabled.isEmpty else { return }
        let index = highlighted.flatMap { enabled.firstIndex(of: $0) }.map { $0 + direction } ?? (direction > 0 ? 0 : enabled.count - 1)
        highlighted = enabled[min(max(0, index), enabled.count - 1)]
    }
    private func choose(_ value: Value) {
        guard options.contains(where: { $0.value == value && $0.isEnabled }) else { return }
        selection = value; close()
    }
}

struct StorebenchChoicePicker<Selection: Hashable>: View {
    enum Style { case pills, radio }
    let title: String
    @Binding var selection: Selection
    let options: [(Selection, String)]
    var style: Style = .pills
    var hint = ""
    var info = ""
    private var hidden = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.actionBusy) private var actionBusy
    @FocusState private var focusedIndex: Int?
    private var active: Bool { enabled || actionBusy }
    /// Hides the visible label when a step title already names the choice; VoiceOver still reads it.
    func labelsHidden() -> Self { var copy = self; copy.hidden = true; return copy }
    /// `info` explains the choices in an (i) tip beside the label.
    init(_ title: String, selection: Binding<Selection>, options: [(Selection, String)], style: Style = .pills, hint: String = "", info: String = "") {
        self.title = title; _selection = selection; self.options = options; self.style = style; self.hint = hint; self.info = info
    }
    var body: some View {
        StorebenchFormField(label: title, hint: hint, hideLabel: hidden, info: info) {
            if style == .radio {
                VStack(alignment: .leading, spacing: 8) { choices }
            } else {
                StorebenchFlow(spacing: 8) { choices }.frame(minHeight: StorebenchTheme.controlHeight)
            }
        }.accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { index in Text(options[index].1).tag(options[index].0) }
            }.pickerStyle(.inline).disabled(!enabled)
        }
    }
    @ViewBuilder private var choices: some View {
        ForEach(options.indices, id: \.self) { index in
            let option = options[index], chosen = selection == option.0
            Button { selection = option.0 } label: {
                if style == .radio {
                    HStack(spacing: 10) {
                        Circle().strokeBorder(active && chosen ? StorebenchTheme.accent : StorebenchTheme.color("color-border-control"))
                            .overlay { if chosen { Circle().fill(active ? StorebenchTheme.accent : StorebenchTheme.subtle).padding(4) } }
                            .frame(width: 18, height: 18)
                        StorebenchTextSlot(text: option.1, height: StorebenchTheme.measure("choiceLabel"), font: .sbCallout, color: active ? StorebenchTheme.ink : StorebenchTheme.subtle, centered: true)
                    }.padding(.horizontal, 12).padding(.vertical, StorebenchTheme.space(2)).frame(minHeight: StorebenchTheme.measure("choiceHeight"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(surface(chosen), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
                        .overlay(StorebenchControlOutline(border: StorebenchTheme.color(chosen ? "color-border-accent" : "color-border-control")))
                } else {
                    HStack(spacing: StorebenchTheme.space(2)) {
                        if chosen { StorebenchIcon(name: "check", size: 14) }
                        Text(option.1).font(.sbCallout).lineLimit(1)
                    }.padding(.horizontal, 12)
                        .frame(minHeight: StorebenchTheme.measure("pillHeight"))
                        .foregroundStyle(active ? chosen ? StorebenchTheme.ink : StorebenchTheme.color("color-text-secondary") : StorebenchTheme.subtle)
                        .background(surface(chosen), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
                        .overlay(StorebenchControlOutline(border: StorebenchTheme.color(chosen ? "color-border-accent" : "color-border-control")))
                }
            }.buttonStyle(StorebenchPressStyle()).focused($focusedIndex, equals: index)
                .accessibilityLabel(option.1).accessibilityAddTraits(chosen ? [.isSelected] : [])
                .onKeyPress { press in
                    guard enabled, press.modifiers.isEmpty else { return .ignored }
                    let direction: Int
                    switch press.key {
                    case .leftArrow, .upArrow: direction = -1
                    case .rightArrow, .downArrow: direction = 1
                    default: return .ignored
                    }
                    guard let next = KeyboardNavigation.adjacent(Array(options.indices), current: index, direction: direction) else { return .ignored }
                    selection = options[next].0; focusedIndex = next
                    return .handled
                }
        }
    }
    private func surface(_ chosen: Bool) -> Color {
        active ? chosen ? StorebenchTheme.color("color-surface-accent") : StorebenchTheme.surface : StorebenchTheme.color("color-surface-sunken")
    }
}

struct StorebenchSecureField: View {
    let title: String, hint: String
    @Binding private var text: String
    private var hidden = false
    private let contentType: NSTextContentType?
    /// `contentType` lets macOS AutoFill offer a saved password.
    init(_ title: String, text: Binding<String>, hint: String = "", contentType: NSTextContentType? = nil) { self.title = title; _text = text; self.hint = hint; self.contentType = contentType }
    func labelsHidden() -> Self { var copy = self; copy.hidden = true; return copy }
    var body: some View {
        StorebenchFormField(label: title, hint: hint, hideLabel: hidden, hideHint: hidden) {
            SecureField("", text: $text).textFieldStyle(StorebenchTextFieldStyle()).textContentType(contentType).accessibilityLabel(title)
        }
    }
}

struct StorebenchTextArea: View {
    var title = ""
    @Binding var text: String
    var height: CGFloat = StorebenchTheme.textarea()
    var hint = ""
    @Environment(\.isEnabled) private var enabled
    @Environment(\.actionBusy) private var actionBusy
    var body: some View {
        let active = enabled || actionBusy
        return StorebenchFormField(label: title, hint: hint, hideLabel: title.isEmpty, hideHint: title.isEmpty && hint.isEmpty) {
            StorebenchTextSurface(label: title.isEmpty ? "Text editor" : title, initialHeight: height) {
            TextEditor(text: $text).font(.system(size: StorebenchTheme.measure("inputFont")))
                .foregroundStyle(active ? StorebenchTheme.ink : StorebenchTheme.subtle)
                .scrollContentBackground(.hidden)
                .padding(.vertical, StorebenchTheme.measure("textareaPaddingY"))
                .padding(.horizontal, StorebenchTheme.measure("textareaPaddingX"))
                .background(active ? StorebenchTheme.surface : StorebenchTheme.color("color-surface-sunken"))
                .accessibilityLabel(title.isEmpty ? "Text editor" : title)
            }
        }
    }
}

struct StorebenchDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        StorebenchDisclosureBody(configuration: configuration)
    }
}

/// A disclosure header keeps its whole target usable and leaves modified arrow shortcuts to macOS.
struct StorebenchDisclosureButton<Label: View>: View {
    @Binding var isExpanded: Bool
    var section = false
    var card = false
    var compact = false
    @ViewBuilder let label: () -> Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        Group {
            if section || card || compact { control.buttonStyle(StorebenchPressStyle()) }
            else { control.buttonStyle(StorebenchButtonStyle(.quiet, stretch: true)) }
        }
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hide details" : "Show details")
        .help(isExpanded ? "Hide details" : "Show details")
        .onKeyPress { press in
            guard enabled, press.modifiers.isEmpty else { return .ignored }
            switch press.key {
            case .leftArrow: change(false)
            case .rightArrow: change(true)
            default: return .ignored
            }
            return .handled
        }
    }
    private func change(_ next: Bool) {
        guard enabled else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { isExpanded = next }
    }
    private var control: some View {
        Button { change(!isExpanded) } label: {
            if compact {
                HStack(spacing: 8) {
                    StorebenchIcon(name: "next", size: 14).rotationEffect(.degrees(isExpanded ? 90 : 0))
                    label().font(.sbCallout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 4).frame(minHeight: 28, alignment: .leading)
                    .foregroundStyle(enabled ? StorebenchTheme.ink : StorebenchTheme.subtle)
                    .contentShape(Rectangle()).overlay(StorebenchControlOutline(border: .clear))
            } else if card {
                HStack(alignment: .top, spacing: StorebenchTheme.space(3)) {
                    StorebenchIcon(name: "next", size: 16).rotationEffect(.degrees(isExpanded ? 90 : 0)).padding(.top, 4)
                    label().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }.padding(StorebenchTheme.space(2)).frame(maxWidth: .infinity, minHeight: StorebenchTheme.controlHeight, alignment: .leading)
                    .foregroundStyle(enabled ? StorebenchTheme.ink : StorebenchTheme.subtle).contentShape(Rectangle())
                    .background(enabled && hovering ? StorebenchTheme.color("color-surface-subtle") : .clear, in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
                    .overlay(StorebenchControlOutline(border: .clear))
            } else if section {
                HStack(spacing: StorebenchTheme.measure("disclosureGap")) {
                    StorebenchIcon(name: "next", size: StorebenchTheme.measure("disclosureIcon"))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    StorebenchTextTrack(height: StorebenchTheme.measure("disclosureLabel"), centered: true) {
                        label().font(.sbCallout.weight(.semibold))
                    }
                }.padding(.vertical, StorebenchTheme.measure("disclosurePaddingY")).padding(.horizontal, StorebenchTheme.measure("disclosurePaddingX"))
                    .frame(maxWidth: .infinity, minHeight: StorebenchTheme.measure("disclosureControl"), alignment: .leading)
                    .foregroundStyle(enabled ? StorebenchTheme.color("color-accent-muted") : StorebenchTheme.subtle).contentShape(Rectangle())
                    .background(enabled && hovering ? StorebenchTheme.color("color-surface-subtle") : .clear, in: RoundedRectangle(cornerRadius: StorebenchTheme.measure("disclosureRadius")))
                    .overlay(StorebenchControlOutline(border: .clear, radius: StorebenchTheme.measure("disclosureRadius")))
            } else {
                HStack(spacing: StorebenchTheme.space(2)) {
                    StorebenchIcon(name: "next", size: 16).rotationEffect(.degrees(isExpanded ? 90 : 0))
                    label().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
            }
        }.onHover { hovering = $0 }
    }
}

private struct StorebenchDisclosureBody: View {
    let configuration: DisclosureGroupStyleConfiguration
    @State private var mounted = false
    var body: some View {
        surface.frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: configuration.isExpanded, initial: true) { if configuration.isExpanded { mounted = true } }
    }
    /// Every disclosure takes the complete row, open or closed, so stacked disclosures line up.
    private var surface: some View {
        VStack(alignment: .leading, spacing: 0) {
            StorebenchDisclosureButton(isExpanded: Binding(get: { configuration.isExpanded }, set: { configuration.isExpanded = $0 }), section: true) { configuration.label }
            if mounted || configuration.isExpanded {
                VStack(alignment: .leading, spacing: StorebenchTheme.gap) { configuration.content }
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.color("color-text-secondary"))
                    .padding(.top, StorebenchTheme.measure("disclosurePaddingY")).padding(.horizontal, StorebenchTheme.measure("disclosurePaddingX")).padding(.bottom, StorebenchTheme.space(4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .collectionVisibility(configuration.isExpanded)
            }
        }.padding(1).frame(maxWidth: .infinity, alignment: .leading)
            .background(StorebenchTheme.surface, in: RoundedRectangle(cornerRadius: StorebenchTheme.measure("disclosureRadius")))
            .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.measure("disclosureRadius")).strokeBorder(StorebenchTheme.color("color-border-control")))
    }
}

struct StorebenchLabeledContent<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View { StorebenchFormField(label: title) { content() } }
}
extension StorebenchLabeledContent where Content == Text {
    init(_ title: String, value: String) { self.title = title; content = { Text(value) } }
}

struct StorebenchForm<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.settingsPresentation) private var settingsPresentation
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StorebenchTheme.gap) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsPageInsets(settingsPresentation)
        }.scrollBounceBehavior(.basedOnSize)
    }
}

extension View {
    /// Settings panes fill the window like workspace pages: the same side margins, with a shorter top under the pane toolbar.
    @ViewBuilder func settingsPageInsets(_ settings: Bool) -> some View {
        if settings {
            padding(.horizontal, StorebenchTheme.settingsInset).padding(.vertical, StorebenchTheme.space(6))
        } else { padding(28) }
    }
}
struct StorebenchFormSection<Content: View>: View {
    let title: String
    let help: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, help: String = "", @ViewBuilder content: @escaping () -> Content) { self.title = title; self.help = help; self.content = content }
    var body: some View { Card(title: title, subtitle: "", help: help) { content() } }
}

struct StorebenchDateField: View {
    let title: String
    @Binding var selection: Date
    private let range: ClosedRange<Date>
    private let components: DatePickerComponents
    @Environment(\.isEnabled) private var enabled
    @Environment(\.actionBusy) private var actionBusy
    init(_ title: String, selection: Binding<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(title, selection: selection, in: Date.distantPast...Date.distantFuture, displayedComponents: displayedComponents)
    }
    init(_ title: String, selection: Binding<Date>, in range: ClosedRange<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.title = title; _selection = selection; self.range = range; components = displayedComponents
    }
    init(_ title: String, selection: Binding<Date>, in range: PartialRangeThrough<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(title, selection: selection, in: Date.distantPast...range.upperBound, displayedComponents: displayedComponents)
    }
    init(_ title: String, selection: Binding<Date>, in range: PartialRangeFrom<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(title, selection: selection, in: range.lowerBound...Date.distantFuture, displayedComponents: displayedComponents)
    }
    var body: some View {
        StorebenchFormField(label: title) {
            DatePicker(title, selection: $selection, in: range, displayedComponents: components).labelsHidden().datePickerStyle(.field)
                .font(.sbSubheadline).padding(.horizontal, 11).frame(height: StorebenchTheme.controlHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(enabled || actionBusy ? StorebenchTheme.surface : StorebenchTheme.color("color-surface-sunken"), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
                .overlay(StorebenchControlOutline()).accessibilityLabel(title)
        }
    }
}

struct StorebenchStepper: View {
    let title: String
    private let decrement, increment: () -> Void
    private let canDecrement, canIncrement: Bool
    private let accessibilityControl: AnyView
    init<V: Strideable & Comparable>(_ title: String, value: Binding<V>, in range: ClosedRange<V>, step: V.Stride = 1) where V.Stride: SignedNumeric & Comparable {
        self.title = title
        canDecrement = value.wrappedValue > range.lowerBound; canIncrement = value.wrappedValue < range.upperBound
        decrement = { value.wrappedValue = max(range.lowerBound, value.wrappedValue.advanced(by: -step)) }
        increment = { value.wrappedValue = min(range.upperBound, value.wrappedValue.advanced(by: step)) }
        accessibilityControl = AnyView(Stepper(title, value: value, in: range, step: step).accessibilityValue(String(describing: value.wrappedValue)))
    }
    var body: some View {
        HStack(spacing: 8) {
            StorebenchTextSlot(text: title, height: 34, font: .sbCallout, color: StorebenchTheme.muted, centered: true)
            Button(action: decrement) { StorebenchIcon(name: "down", size: 16) }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).disabled(!canDecrement).help("Decrease " + title).accessibilityLabel("Decrease " + title)
            Button(action: increment) { StorebenchIcon(name: "up", size: 16) }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).disabled(!canIncrement).help("Increase " + title).accessibilityLabel("Increase " + title)
        }.frame(minHeight: StorebenchTheme.controlHeight).accessibilityRepresentation { accessibilityControl }
    }
}

struct StorebenchSpinner: View {
    var inheritForeground = false
    var body: some View {
        symbol.accessibilityElement(children: .ignore).accessibilityLabel("Loading")
    }
    @ViewBuilder private var symbol: some View {
        if inheritForeground { StorebenchActivityIcon(size: 16, active: true) }
        else { StorebenchActivityIcon(size: 16, active: true).foregroundStyle(StorebenchTheme.accent) }
    }
}

/// Both labels occupy the same track, so a pending action keeps its natural width.
struct StorebenchBusyLabel: View {
    let normal, loading: String
    let busy: Bool
    init(_ normal: String, loading: String, busy: Bool) { self.normal = normal; self.loading = loading; self.busy = busy }
    var body: some View {
        ZStack {
            Text(normal).opacity(busy ? 0 : 1)
            HStack(spacing: 7) {
                if busy { StorebenchSpinner(inheritForeground: true) }
                else { Color.clear.frame(width: 16, height: 16) }
                Text(loading)
            }.opacity(busy ? 1 : 0)
        }.accessibilityElement(children: .ignore).accessibilityLabel(busy ? loading : normal)
    }
}

/// Synchronously reserves a read action before scheduling it, including rapid repeated clicks.
struct StorebenchReadButton: View {
    let title: String
    let action: @MainActor () async -> Void
    @State private var reading = false
    @State private var context = UUID()
    @State private var operation: Task<Void, Never>?
    init(_ title: String, action: @escaping @MainActor () async -> Void) { self.title = title; self.action = action }
    /// Explicit reads see current answers; local-only actions still only reread their local store.
    @MainActor static func perform(_ action: @MainActor () async -> Void) async {
        await ScreenReads.reading(fresh: true) { await action() }
    }
    var body: some View {
        Button {
            guard !reading else { return }
            reading = true; let expected = context
            operation = Task {
                await Self.perform(action)
                if context == expected { reading = false; operation = nil }
            }
        } label: { StorebenchBusyLabel(title, loading: "Reading…", busy: reading) }
            .storebenchWorking(reading).onDisappear { operation?.cancel(); operation = nil; context = UUID(); reading = false }
    }
}

struct StorebenchProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let fraction = configuration.fractionCompleted {
                if let label = configuration.label { label.font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
                GeometryReader { geometry in
                    Capsule().fill(StorebenchTheme.border)
                        .overlay(alignment: .leading) {
                            Capsule().fill(StorebenchTheme.accent).frame(width: geometry.size.width * min(1, max(0, fraction)))
                        }
                }.frame(height: StorebenchTheme.measure("progressHeight"))
            } else if let label = configuration.label {
                // The spinner sits on the label's first line, also when the label reserves a taller track.
                HStack(alignment: .top, spacing: 8) {
                    StorebenchSpinner().frame(height: Self.lineHeight(StorebenchTheme.design.number("font-size-caption")))
                    label.font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                }
            } else { StorebenchSpinner() }
            if let label = configuration.currentValueLabel { label.font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
        }
        // A bar fills its row; a spinner keeps its own size, so the surrounding view decides where it sits.
        .frame(maxWidth: configuration.fractionCompleted == nil ? nil : .infinity, alignment: .leading)
    }
    /// One line of system text at `size` points.
    static func lineHeight(_ size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return ceil(font.ascender - font.descender + font.leading)
    }
}

struct StorebenchCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.actionBusy) private var actionBusy
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    /// The native checkbox greys whenever it is disabled, so a busy one stays enabled in appearance
    /// while its value and pointer input are locked until the operation ends.
    private var locked: Bool { !enabled && actionBusy }
    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { if !locked { isOn = $0 } })) { EmptyView() }.toggleStyle(.checkbox).labelsHidden()
            .environment(\.isEnabled, enabled || actionBusy).allowsHitTesting(!locked)
            .frame(width: StorebenchTheme.controlHeight, height: StorebenchTheme.controlHeight)
            .help(title).accessibilityLabel(title)
    }
}

extension View {
    /// The only busy lock: inputs cannot change while an operation runs, yet keep their normal colours.
    /// An inner idle lock never clears an outer busy one.
    func storebenchWorking(_ busy: Bool) -> some View { disabled(busy).transformEnvironment(\.actionBusy) { if busy { $0 = true } } }
}

/// A command that is never disabled: while its operation runs it shows its loading label and ignores clicks.
struct StorebenchBusyButton: View {
    let title, loadingTitle: String
    let busy: Bool
    var variant: ControlColors.Variant = .secondary
    let action: () -> Void
    var body: some View {
        Button { if !busy { action() } } label: { StorebenchBusyLabel(title, loading: loadingTitle, busy: busy) }
            .buttonStyle(StorebenchButtonStyle(variant)).transformEnvironment(\.actionBusy) { if busy { $0 = true } }
            .help(busy ? loadingTitle : title).accessibilityLabel(busy ? loadingTitle : title)
    }
}
