import AppKit
import StorebenchCore
import SwiftUI

/// Asks before an action removes or discards work on this Mac. Don't ask again skips the question for that kind of action
/// from then on; Settings › Editing turns it back on.
struct DestructiveConfirm {
    var model: LibraryModel?
    /// True when the action may run: confirmed now, or not asked because Don't ask again was chosen for it.
    @MainActor func callAsFunction(_ kind: DestructiveConfirmation, title: String, message: String, action: String, keep: String = "Cancel") -> Bool {
        guard model?.editingPreferences?.asks(kind) ?? true else { return true }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: keep); alert.addButton(withTitle: action)
        alert.buttons[1].hasDestructiveAction = true
        // Without an open workspace the choice could not be saved, so it is not offered.
        alert.showsSuppressionButton = model?.session != nil
        alert.suppressionButton?.title = "Don't ask again"
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        if alert.suppressionButton?.state == .on, let model { Task { try? await model.setConfirmation(kind, asks: false) } }
        return true
    }
}

private struct DestructiveConfirmKey: EnvironmentKey { static var defaultValue: DestructiveConfirm { DestructiveConfirm() } }
extension EnvironmentValues {
    var confirmDestructive: DestructiveConfirm { get { self[DestructiveConfirmKey.self] } set { self[DestructiveConfirmKey.self] = newValue } }
}
