import AppKit
import StorebenchCore
import SwiftUI

@MainActor final class EditorProtection {
    private let departure = EditorDeparture()
    var policy: EditorProtectionPolicy { get { departure.policy } set { departure.policy = newValue } }
    var closingPolicy: EditorProtectionPolicy { departure.closingPolicy }
    var canSave: Bool { departure.canSave }
    func saveDrafts() {
        guard departure.canSave else { return }
        let ticket = departure.begin()
        Task { @MainActor in
            if !(await departure.saveChanges(for: ticket)), departure.owns(ticket) {
                notSaved("Your inputs are kept. Fix or discard the item marked in red, then save again.")
            }
        }
    }
    func registerSave(id: String, priority: Int = 0, generation: String? = nil, problem: (@MainActor () -> String?)? = nil, save: @escaping @MainActor () async -> Bool) {
        departure.register(id: id, priority: priority, generation: generation, problem: problem, save: save)
    }
    /// Names the item marked in red that stopped the save, then says what to do with it.
    private func notSaved(_ advice: String) {
        let failure = NSAlert(); failure.messageText = "Changes were not saved"
        failure.informativeText = departure.failure.map { $0 + "\n\n" + advice } ?? advice
        failure.addButton(withTitle: "Keep Editing"); failure.runModal()
    }
    func unregisterSave(id: String) { departure.unregisterSave(id: id) }
    func remove(id: String) { departure.remove(id: id) }
    func invalidateNavigation() { _ = departure.begin() }
    func allowLeaving(excluding id: String? = nil) -> Bool {
        _ = departure.begin()
        let starting = id.map(policy.excluding(id:)) ?? policy
        return Self.confirm(starting.navigationDecision) && starting.allowsNavigation(after: id.map(policy.excluding(id:)) ?? policy, discardConfirmed: true)
    }
    func requestLeaving(_ action: @escaping @MainActor () -> Void) {
        let ticket = departure.begin(), starting = policy
        guard starting.navigationDecision != .ready else { action(); return }
        let alert = NSAlert(); alert.messageText = "Save changes before leaving?"
        alert.informativeText = departure.canSave ? "Save your local changes, discard them, or keep editing. Nothing is published to Apple." : "These changes go to App Store Connect only through a review, so they cannot be saved on this Mac. Choose Keep Editing and use Prepare Review on the card you changed, or discard them and continue."
        alert.alertStyle = .warning
        if departure.canSave {
            alert.addButton(withTitle: "Save and Continue")
            alert.addButton(withTitle: "Discard and Continue")
            alert.addButton(withTitle: "Keep Editing").keyEquivalent = "\u{1b}"
            let choice = alert.runModal()
            guard departure.owns(ticket) else { return }
            if choice == .alertFirstButtonReturn {
                Task { @MainActor in
                    guard await departure.saveChanges(for: ticket) else {
                        if departure.owns(ticket) { notSaved("Your inputs are kept. Fix or discard the item marked in red, then save again or discard the changes.") }
                        return
                    }
                    action()
                }
                return
            }
            guard choice == .alertSecondButtonReturn else { return }
        } else {
            alert.addButton(withTitle: "Keep Editing"); alert.addButton(withTitle: "Discard and Continue")
            guard alert.runModal() == .alertSecondButtonReturn, departure.owns(ticket) else { return }
        }
        if starting.allowsNavigation(after: policy, discardConfirmed: true) { action() }
    }
    /// Moves on in a guided flow: local edits are saved on this Mac without asking, then the action runs.
    /// When something cannot be saved here, the usual save, discard or stay choice is shown instead.
    func saveAndContinue(_ action: @escaping @MainActor () -> Void) {
        let ticket = departure.begin()
        guard policy.navigationDecision != .ready else { action(); return }
        guard departure.canSave else { requestLeaving(action); return }
        Task { @MainActor in
            guard await departure.saveChanges(for: ticket) else {
                if departure.owns(ticket) { notSaved("You stayed on this step and your inputs are kept. Fix or discard the item marked in red, then continue again.") }
                return
            }
            action()
        }
    }
    func allowClosing() -> Bool {
        let starting = closingPolicy
        return Self.confirm(starting.decision) && starting.allowsLeaving(after: closingPolicy, discardConfirmed: true)
    }
    static func confirm(_ decision: EditorProtectionPolicy.Decision) -> Bool {
        switch decision {
        case .ready: return true
        case .wait:
            let alert = NSAlert(); alert.messageText = "A workspace operation is finishing"
            alert.informativeText = "You can change views while work continues. Finish the current operation before closing this workspace or signing out."
            alert.addButton(withTitle: "Keep Editing"); alert.runModal(); return false
        case .confirmDiscard:
            let alert = NSAlert(); alert.messageText = "Discard unsaved edits?"
            alert.informativeText = "Leaving this editor discards its unsaved inputs. Saved drafts remain available."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Keep Editing"); alert.addButton(withTitle: "Discard and Continue")
            return alert.runModal() == .alertSecondButtonReturn
        }
    }
}

private struct EditorProtectionKey: EnvironmentKey { static let defaultValue: EditorProtection? = nil }
extension EnvironmentValues {
    var editorProtection: EditorProtection? { get { self[EditorProtectionKey.self] } set { self[EditorProtectionKey.self] = newValue } }
}

private struct EditorProtectionTracking: ViewModifier {
    @Environment(\.editorProtection) private var protection
    @State private var id = UUID().uuidString
    let explicitId: String?
    let dirty, busy: Bool
    let generation: String?
    let problem: (@MainActor () -> String?)?
    let onSave: (@MainActor () async -> Bool)?
    func body(content: Content) -> some View {
        content.onAppear { update() }.onChange(of: dirty) { update() }.onChange(of: busy) { update() }.onChange(of: onSave == nil) { update() }.onChange(of: generation) { update() }
            .onDisappear { protection?.remove(id: explicitId ?? id) }
    }
    private func update() {
        let owner = explicitId ?? id
        protection?.policy.update(id: owner, dirty: dirty, busy: busy)
        if let onSave { protection?.registerSave(id: owner, generation: generation, problem: problem, save: onSave) }
        else { protection?.unregisterSave(id: owner) }
    }
}
extension View {
    /// `problem` names the item marked in red when a save fails, so the "Changes were not saved" alert can point to it.
    func trackUnsavedChanges(_ dirty: Bool, busy: Bool = false, id: String? = nil, generation: String? = nil, problem: (@MainActor () -> String?)? = nil, onSave: (@MainActor () async -> Bool)? = nil) -> some View {
        modifier(EditorProtectionTracking(explicitId: id, dirty: dirty, busy: busy, generation: generation, problem: problem, onSave: onSave))
    }
}

@MainActor private final class WeakEditorProtection {
    weak var value: EditorProtection?
    init(_ value: EditorProtection) { self.value = value }
}
@MainActor enum EditorWindows {
    private static var windows: [ObjectIdentifier: WeakEditorProtection] = [:]
    static func register(_ protection: EditorProtection) { windows[ObjectIdentifier(protection)] = WeakEditorProtection(protection) }
    static func unregister(_ protection: EditorProtection) { windows.removeValue(forKey: ObjectIdentifier(protection)) }
    static var decision: EditorProtectionPolicy.Decision { EditorProtectionPolicy.combined(windows.values.compactMap { $0.value?.closingPolicy }) }
    static func decision(excluding id: String) -> EditorProtectionPolicy.Decision { EditorProtectionPolicy.combined(windows.values.compactMap { $0.value?.closingPolicy.excluding(id: id) }) }
    static func allowLeaving(excluding id: String? = nil) -> Bool {
        func snapshot() -> [ObjectIdentifier: EditorProtectionPolicy] {
            windows.compactMapValues { holder in holder.value.map { id.map($0.closingPolicy.excluding(id:)) ?? $0.closingPolicy } }
        }
        let starting = snapshot()
        return EditorProtection.confirm(EditorProtectionPolicy.combined(Array(starting.values))) &&
            EditorProtectionPolicy.allowsLeaving(starting: starting, latest: snapshot(), discardConfirmed: true)
    }
}

/// Installs a close veto while forwarding the window's existing delegate callbacks.
struct EditorWindowGuard: NSViewRepresentable {
    let protection: EditorProtection
    var role: WindowLifecycle.Role = .auxiliary
    func makeCoordinator() -> Coordinator { Coordinator(protection, role: role) }
    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe(); view.coordinator = context.coordinator; return view
    }
    func updateNSView(_ nsView: WindowProbe, context: Context) { context.coordinator.install(nsView.window) }
    static func dismantleNSView(_ nsView: WindowProbe, coordinator: Coordinator) { coordinator.detach() }

    final class WindowProbe: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.install(window) }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let protection: EditorProtection
        let role: WindowLifecycle.Role
        weak var window: NSWindow?
        nonisolated(unsafe) var previous: (any NSWindowDelegate)?
        init(_ protection: EditorProtection, role: WindowLifecycle.Role) { self.protection = protection; self.role = role }
        func install(_ window: NSWindow?) {
            guard let window, self.window !== window else { return }
            detach(); self.window = window; previous = window.delegate; window.delegate = self
            if role == .workspace { window.identifier = NSUserInterfaceItemIdentifier(WindowLifecycle.workspaceID) }
            EditorWindows.register(protection)
        }
        func detach() {
            if let window, window.delegate === self { window.delegate = previous }
            window = nil; previous = nil; EditorWindows.unregister(protection)
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            protection.allowClosing() && (previous?.windowShouldClose?(sender) ?? true)
        }
        func windowWillClose(_ notification: Notification) {
            let delegate = previous
            if role == .workspace { window?.identifier = nil }
            detach(); delegate?.windowWillClose?(notification)
        }
        nonisolated override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || previous?.responds(to: selector) == true }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? { previous }
    }
}

@MainActor final class StorebenchApplicationDelegate: NSObject, NSApplicationDelegate {
    private var requestingWorkspace = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.reopenWorkspace() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenWorkspace(); return false
    }
    private func reopenWorkspace() {
        guard !requestingWorkspace else { return }
        let windows = NSApp.windows.filter { $0.identifier?.rawValue == WindowLifecycle.workspaceID }
        let snapshot = windows.map { WindowLifecycle.Window(id: $0.windowNumber, role: .workspace, visible: $0.isVisible, miniaturized: $0.isMiniaturized) }
        switch WindowLifecycle.reopen(snapshot) {
        case .present(let id):
            guard let window = windows.first(where: { $0.windowNumber == id }) else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        case .createWorkspace:
            guard let item = workspaceMenuItem(NSApp.mainMenu), let action = item.action else { return }
            requestingWorkspace = true
            _ = NSApp.sendAction(action, to: item.target, from: item)
            DispatchQueue.main.async { [weak self] in self?.requestingWorkspace = false; NSApp.activate(ignoringOtherApps: true) }
        }
    }
    private func workspaceMenuItem(_ menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == WindowLifecycle.openWorkspaceTitle { return item }
            if let found = workspaceMenuItem(item.submenu) { return found }
        }
        return nil
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        EditorWindows.allowLeaving() ? .terminateNow : .terminateCancel
    }
}
