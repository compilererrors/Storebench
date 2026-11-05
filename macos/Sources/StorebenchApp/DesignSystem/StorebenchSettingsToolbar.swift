import AppKit
import StorebenchCore
import SwiftUI

struct StorebenchSettingsToolbar: NSViewRepresentable {
    let selected: SettingsNavigation.Pane
    let select: (SettingsNavigation.Pane) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selected: selected, select: select) }
    func makeNSView(context: Context) -> Probe { Probe(coordinator: context.coordinator) }
    func updateNSView(_ view: Probe, context: Context) {
        context.coordinator.selected = selected
        context.coordinator.select = select
        if let window = view.window { context.coordinator.attach(to: window) }
    }
    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) { coordinator.detach() }

    final class Probe: NSView {
        let coordinator: Coordinator
        init(coordinator: Coordinator) { self.coordinator = coordinator; super.init(frame: .zero) }
        required init?(coder: NSCoder) { return nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { coordinator.attach(to: window) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSToolbarDelegate {
        var selected: SettingsNavigation.Pane
        var select: (SettingsNavigation.Pane) -> Void
        private weak var window: NSWindow?
        private let toolbar = NSToolbar(identifier: "Storebench.Settings")
        private var images: [String: NSImage] = [:]
        private var identifiers: [NSToolbarItem.Identifier] { SettingsNavigation.Pane.allCases.map { identifier($0) } }

        init(selected: SettingsNavigation.Pane, select: @escaping (SettingsNavigation.Pane) -> Void) {
            self.selected = selected; self.select = select
            super.init()
            toolbar.delegate = self
            toolbar.displayMode = .iconAndLabel
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            toolbar.showsBaselineSeparator = true
        }
        func attach(to window: NSWindow) {
            if self.window !== window {
                detach(); self.window = window
                window.toolbarStyle = .preference
                window.toolbar = toolbar
            }
            toolbar.isVisible = true
            toolbar.selectedItemIdentifier = identifier(selected)
            window.title = selected.title
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
        func detach() {
            if window?.toolbar === toolbar { window?.toolbar = nil }
            window = nil
        }
        private func identifier(_ pane: SettingsNavigation.Pane) -> NSToolbarItem.Identifier { .init(pane.rawValue) }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
        func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            guard let pane = SettingsNavigation.Pane(rawValue: identifier.rawValue) else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = pane.title; item.paletteLabel = pane.title
            item.toolTip = "Show " + pane.title.lowercased() + " settings"
            if images[pane.icon] == nil { images[pane.icon] = StorebenchIcon.templateImage(name: pane.icon, size: 22, inset: 4) }
            item.image = images[pane.icon]
            item.target = self; item.action = #selector(activate(_:))
            return item
        }
        @objc private func activate(_ item: NSToolbarItem) {
            guard let pane = SettingsNavigation.Pane(rawValue: item.itemIdentifier.rawValue) else { return }
            // The selected indicator follows the visible pane, including while a save/discard review is open.
            toolbar.selectedItemIdentifier = identifier(selected)
            select(pane)
            toolbar.selectedItemIdentifier = identifier(selected)
        }
    }
}
