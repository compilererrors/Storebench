import AppKit
import StorebenchCore
import SwiftUI

struct StorebenchShortcutRecorder: NSViewRepresentable {
    let recordingChanged: @MainActor (Bool) -> Void
    let captured: @MainActor (ShortcutBinding) -> Void
    func makeNSView(context: Context) -> Recorder {
        let view = Recorder(title: "Record Shortcut", target: nil, action: nil)
        view.bezelStyle = .rounded; view.target = view; view.action = #selector(Recorder.begin)
        view.recordingChanged = recordingChanged; view.captured = captured
        return view
    }
    func updateNSView(_ view: Recorder, context: Context) { view.recordingChanged = recordingChanged; view.captured = captured }
    static func dismantleNSView(_ view: Recorder, coordinator: ()) { view.finish() }
    final class Recorder: NSButton {
        var recordingChanged: (@MainActor (Bool) -> Void)?
        var captured: (@MainActor (ShortcutBinding) -> Void)?
        private var recording = false
        override var acceptsFirstResponder: Bool { true }
        @objc func begin() {
            guard window?.makeFirstResponder(self) == true else { return }
            recording = true; title = "Press a shortcut…"; recordingChanged?(true)
        }
        func finish() { recording = false; title = "Record Shortcut"; recordingChanged?(false) }
        override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
            receive(event); return true
        }
        override func keyDown(with event: NSEvent) { if recording { receive(event) } else { super.keyDown(with: event) } }
        private func receive(_ event: NSEvent) {
            guard !event.isARepeat else { return }
            if event.keyCode == 53 { finish(); return }
            if event.keyCode == 48, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) {
                finish(); if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }; return
            }
            let names: [UInt16: String] = [48: "tab", 36: "return", 49: "space", 123: "left", 124: "right", 125: "down", 126: "up"]
            let functions: [UInt16: Int] = [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20]
            let key = names[event.keyCode] ?? functions[event.keyCode].map { "f\($0)" } ?? event.characters(byApplyingModifiers: []) ?? ""
            var modifiers = Set<ShortcutBinding.Modifier>()
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            guard let binding = try? ShortcutBinding(key: key, modifiers: modifiers) else { title = "Use Command or Control…"; return }
            finish(); captured?(binding)
        }
    }
}
