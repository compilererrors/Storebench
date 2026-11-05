import AppKit
import Observation
import StorebenchCore
import SwiftUI

struct StorebenchWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(WindowLifecycle.openWorkspaceTitle) { openWindow(id: WindowLifecycle.workspaceID) }.keyboardShortcut("n", modifiers: .command)
        }
    }
}

@MainActor @Observable final class StorebenchShortcutSettings {
    private let defaults: UserDefaults
    private(set) var keymap: ShortcutKeymap
    private var recorder = ShortcutRecording()
    var recording: Bool { recorder.active }
    var issue = ""
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: "keyboard.shortcuts.v1") {
            do { keymap = try ShortcutKeymap(serialized: raw) }
            catch { keymap = try! ShortcutKeymap(); issue = "Saved shortcuts could not be validated. Defaults are active; restore defaults to replace the invalid settings." }
        } else { keymap = try! ShortcutKeymap() }
    }
    @discardableResult func assign(_ command: ShortcutCommand, specification: String?) -> Bool {
        do {
            let next = try keymap.replacing(command, specification: specification), serialized = try next.serialized()
            defaults.set(serialized, forKey: "keyboard.shortcuts.v1"); keymap = next; issue = "Shortcut saved."
            return true
        } catch ShortcutKeymap.Failure.conflict(let other) { issue = "Already assigned to \(other.title). Change or disable that shortcut first." }
        catch ShortcutKeymap.Failure.reserved { issue = "This combination belongs to macOS or text editing. Choose another shortcut." }
        catch { issue = "Use Command or Control with one key. Settings always uses Command+Comma." }
        return false
    }
    func restore() {
        keymap = try! ShortcutKeymap(); defaults.removeObject(forKey: "keyboard.shortcuts.v1"); issue = "Default shortcuts restored."
    }
    func recording(_ active: Bool, owner: UUID) { recorder.update(active: active, owner: owner) }
}

private struct ShortcutSettingsKey: EnvironmentKey { static let defaultValue: StorebenchShortcutSettings? = nil }
private struct ShortcutActionsKey: EnvironmentKey { static let defaultValue: ShortcutActions? = nil }
private struct FocusedShortcutActions: FocusedValueKey { typealias Value = ShortcutActions }
private struct FocusedShortcutProtection: FocusedValueKey { typealias Value = EditorProtection }
extension EnvironmentValues {
    var shortcutSettings: StorebenchShortcutSettings? { get { self[ShortcutSettingsKey.self] } set { self[ShortcutSettingsKey.self] = newValue } }
    var shortcutActions: ShortcutActions? { get { self[ShortcutActionsKey.self] } set { self[ShortcutActionsKey.self] = newValue } }
}
extension FocusedValues {
    var shortcutActions: ShortcutActions? { get { self[FocusedShortcutActions.self] } set { self[FocusedShortcutActions.self] = newValue } }
    var shortcutProtection: EditorProtection? { get { self[FocusedShortcutProtection.self] } set { self[FocusedShortcutProtection.self] = newValue } }
}

struct StorebenchCommands: Commands {
    let shortcuts: StorebenchShortcutSettings
    @FocusedValue(\.shortcutActions) private var actions
    @FocusedValue(\.shortcutProtection) private var protection
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            SettingsLink { Text("Settings…") }.keyboardShortcut(",", modifiers: .command).disabled(shortcuts.recording)
        }
        CommandGroup(after: .saveItem) {
            Button(ShortcutCommand.save.title) { if allowed(.save, enabled: protection?.canSave == true) { protection?.saveDrafts() } }
                .modifier(StorebenchCommandBinding(binding: shortcuts.keymap.binding(.save)))
                .disabled(shortcuts.recording || protection?.canSave != true)
        }
        CommandMenu("Navigate") {
            ForEach(ShortcutCommand.allCases.filter { $0.group == "Navigation" }, id: \.self) { command in commandButton(command) }
        }
        CommandMenu("Actions") {
            ForEach([ShortcutCommand.refresh, .syncApp, .syncAll, .retry, .stop, .chooseImages], id: \.self) { command in commandButton(command) }
        }
        CommandGroup(replacing: .help) { commandButton(.help) }
    }
    private func commandButton(_ command: ShortcutCommand) -> some View {
        Button(command.title + (actions?.busy(command) == true ? "…" : "")) { if allowed(command, enabled: actions?.enabled(command) == true) { actions?.perform(command) } }
            .modifier(StorebenchCommandBinding(binding: shortcuts.keymap.binding(command)))
            .disabled(shortcuts.recording || actions?.enabled(command) != true)
    }
    private func allowed(_ command: ShortcutCommand, enabled: Bool) -> Bool {
        ShortcutDispatchPolicy.allows(command, enabled: enabled, recording: shortcuts.recording,
            modal: NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil || NSApp.keyWindow?.sheetParent != nil,
            repeated: NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.isARepeat == true)
    }
}

private struct StorebenchCommandBinding: ViewModifier {
    let binding: ShortcutBinding?
    func body(content: Content) -> some View { content.keyboardShortcut(binding.map { KeyboardShortcut($0.equivalent, modifiers: $0.eventModifiers) }) }
}
extension ShortcutBinding {
    var equivalent: KeyEquivalent {
        switch key {
        case "tab": .tab
        case "space": .space
        case "return": .return
        case "escape": .escape
        case "left": .leftArrow
        case "right": .rightArrow
        case "up": .upArrow
        case "down": .downArrow
        default: KeyEquivalent(key.hasPrefix("f") && key.count > 1 ? Character(UnicodeScalar(0xf703 + Int(key.dropFirst())!)!) : key.first!)
        }
    }
    var eventModifiers: EventModifiers {
        modifiers.reduce(into: EventModifiers()) { result, modifier in
            switch modifier { case .command: result.insert(.command); case .control: result.insert(.control); case .option: result.insert(.option); case .shift: result.insert(.shift) }
        }
    }
}

private struct StorebenchShortcutAction: ViewModifier {
    let command: ShortcutCommand, enabled: Bool, priority: Int, identity: String
    let action: @MainActor () async -> Void
    @Environment(\.shortcutActions) private var actions
    @Environment(\.collectionVisible) private var visible
    @State private var owner = UUID()
    func body(content: Content) -> some View {
        content.onAppear { register() }.onChange(of: visible) { register() }.onChange(of: enabled) { register() }
            .onChange(of: identity) { actions?.remove(command, owner: owner); owner = UUID(); register() }
            .onDisappear { actions?.remove(command, owner: owner) }
    }
    private func register() {
        if visible { actions?.register(command, owner: owner, priority: priority, enabled: enabled, action: action) }
        else { actions?.remove(command, owner: owner) }
    }
}
private struct StorebenchShortcutNavigation: ViewModifier {
    let commands: [ShortcutCommand], identity: String
    let navigate: @MainActor (ShortcutCommand) -> Void
    @Environment(\.shortcutActions) private var actions
    @Environment(\.collectionVisible) private var visible
    @State private var owner = UUID()
    @State private var registered: [ShortcutCommand] = []
    func body(content: Content) -> some View {
        content.onAppear { register() }.onChange(of: visible) { register() }.onChange(of: commands) { register() }
            .onChange(of: identity) { remove(); owner = UUID(); register() }.onDisappear { remove() }
    }
    private func register() {
        remove(); guard visible else { return }; registered = commands
        for command in commands { actions?.register(command, owner: owner, enabled: true) { navigate(command) } }
    }
    private func remove() { for command in registered { actions?.remove(command, owner: owner) }; registered = [] }
}
extension View {
    func shortcutAction(_ command: ShortcutCommand, enabled: Bool = true, priority: Int = 10, identity: String = "", action: @escaping @MainActor () async -> Void) -> some View {
        modifier(StorebenchShortcutAction(command: command, enabled: enabled, priority: priority, identity: identity, action: action))
    }
    func shortcutNavigation(_ commands: [ShortcutCommand], identity: String, navigate: @escaping @MainActor (ShortcutCommand) -> Void) -> some View {
        modifier(StorebenchShortcutNavigation(commands: commands, identity: identity, navigate: navigate))
    }
}
