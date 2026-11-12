import AppKit
import SwiftUI

/// A native window-modal question. It overlays its owner and never becomes part of the page layout.
struct StorebenchNativeQuestion: NSViewRepresentable {
    struct Choice: Sendable {
        let id, title: String
        var isDefault = false
        var isCancel = false
    }
    @Binding var presented: Bool
    let identifier, title, message: String
    let choices: [Choice]
    let select: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Probe { Probe(context.coordinator) }
    func updateNSView(_ view: Probe, context: Context) {
        context.coordinator.configuration = self
        if let window = view.window { context.coordinator.update(in: window) }
    }
    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) { coordinator.dismiss() }
    final class Probe: NSView {
        let coordinator: Coordinator
        init(_ coordinator: Coordinator) { self.coordinator = coordinator; super.init(frame: .zero); setAccessibilityElement(false) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { coordinator.update(in: window) } }
    }
    @MainActor final class Coordinator {
        var configuration: StorebenchNativeQuestion
        private var alert: NSAlert?
        private weak var owner: NSWindow?
        init(_ configuration: StorebenchNativeQuestion) { self.configuration = configuration }
        func update(in window: NSWindow) {
            guard configuration.presented else { dismiss(); return }
            guard alert == nil, window.attachedSheet == nil else { return }
            let question = NSAlert(); question.alertStyle = .informational
            question.messageText = configuration.title; question.informativeText = configuration.message
            question.window.identifier = NSUserInterfaceItemIdentifier(configuration.identifier)
            for choice in configuration.choices {
                let button = question.addButton(withTitle: choice.title)
                button.identifier = NSUserInterfaceItemIdentifier(choice.id)
                button.keyEquivalent = choice.isDefault ? "\r" : choice.isCancel ? "\u{1b}" : ""
            }
            owner = window; alert = question
            let choices = configuration.choices
            question.beginSheetModal(for: window) { [weak self, weak question] response in
                guard let self, self.alert === question else { return }
                self.alert = nil; self.owner = nil
                let requested = self.configuration.presented
                self.configuration.presented = false
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                if requested, choices.indices.contains(index) { self.configuration.select(choices[index].id) }
            }
        }
        func dismiss() {
            guard let alert else { return }
            self.alert = nil
            owner?.endSheet(alert.window, returnCode: .abort); alert.window.orderOut(nil); owner = nil
        }
    }
}
