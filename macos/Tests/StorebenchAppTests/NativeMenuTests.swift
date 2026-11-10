import AppKit
import Observation
import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

@MainActor @Suite(.serialized) struct NativeMenuTests {
    init() throws { _ = try TestIsolation.require() }

    @MainActor @Observable final class Choices {
        var selected = "first"
        var options = [SelectionOption("Synthetic First", value: "first"), SelectionOption("Synthetic Second", value: "second")]
        var enabled = true
    }
    private struct PickerExample: View {
        let choices: Choices
        var body: some View {
            StorebenchNativePicker(title: "Synthetic Choice", selection: Binding(get: { choices.selected }, set: { choices.selected = $0 }), options: choices.options)
                .disabled(!choices.enabled).padding(20)
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(80))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    private func window<V: View>(_ content: V, width: CGFloat = 540, height: CGFloat = 180) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.transaction { $0.animation = nil; $0.disablesAnimations = true })
        window.orderBack(nil)
        return window
    }

    @Test func nativeSelectionUsesTheFullTitleAndDoesNotSubstituteMissingValues() async throws {
        let choices = Choices(), window = self.window(PickerExample(choices: choices)); defer { window.orderOut(nil); window.close() }
        try await settle(window)
        let root = try #require(window.contentView), popup = try #require(descendants(root).compactMap { $0 as? NSPopUpButton }.first)
        #expect(!popup.isTransparent && popup.isBordered && popup.focusRingType == .none && !popup.pullsDown)
        #expect(window.makeFirstResponder(popup) && window.firstResponder === popup, "The shared face retains the native keyboard focus target")
        #expect(popup.titleOfSelectedItem == "Synthetic First" && popup.toolTip?.contains("Synthetic First") == true)
        let long = String(repeating: "Synthetic model detail ", count: 12)
        choices.options = [SelectionOption(long, value: "first")]
        try await settle(window)
        #expect(popup.titleOfSelectedItem == long && popup.toolTip?.contains(long) == true && popup.accessibilityValue() as? String == long)
        choices.options = [SelectionOption("Synthetic Second", value: "second")]
        try await settle(window)
        #expect(choices.selected == "first" && popup.titleOfSelectedItem == "Choose…")
        #expect(popup.selectedItem?.isEnabled == false)
    }

    @Test func aMenuOpenedBeforeOptionsChangeCannotApplyAnOldChoice() async throws {
        let choices = Choices(), window = self.window(PickerExample(choices: choices)); defer { window.orderOut(nil); window.close() }
        try await settle(window)
        let root = try #require(window.contentView), popup = try #require(descendants(root).compactMap { $0 as? NSPopUpButton }.first)
        let menu = try #require(popup.menu), action = try #require(popup.action)
        menu.delegate?.menuWillOpen?(menu)
        choices.options = [SelectionOption("Synthetic First", value: "first")]
        try await settle(window)
        popup.selectItem(withTitle: "Synthetic Second")
        NSApp.sendAction(action, to: popup.target, from: popup)
        #expect(choices.selected == "first")
        menu.delegate?.menuDidClose?(menu)
        choices.options.append(SelectionOption("Synthetic Second", value: "second"))
        try await settle(window)
        popup.selectItem(withTitle: "Synthetic Second")
        NSApp.sendAction(action, to: popup.target, from: popup)
        #expect(choices.selected == "second")
        choices.enabled = false
        try await settle(window)
        #expect(!popup.isEnabled)
    }

    @Test func footerKeepsSecondaryAndPrimaryCommandsOnTheTrailingEdge() async throws {
        let window = self.window(StorebenchFormFooter {
            Button("Cancel") {}.buttonStyle(StorebenchButtonStyle()).storebenchControlID("synthetic-cancel")
            Button("Save Draft") {}.buttonStyle(StorebenchButtonStyle(.primary)).storebenchControlID("synthetic-save")
        }, width: 720)
        defer { window.orderOut(nil); window.close() }
        try await settle(window)
        let root = try #require(window.contentView), markers = descendants(root).compactMap { $0 as? StorebenchControlMarker }
        let cancel = try #require(markers.first { $0.identifier?.rawValue == "synthetic-cancel" })
        let save = try #require(markers.first { $0.identifier?.rawValue == "synthetic-save" })
        let first = root.convert(cancel.bounds, from: cancel), last = root.convert(save.bounds, from: save)
        #expect(abs(last.maxX - root.bounds.maxX) < 1 && last.minX > first.maxX)
        #expect(abs(first.midY - last.midY) < 1 && abs(first.width - last.width) < 1)
        #expect(abs(last.width - StorebenchTheme.actionWidth) < 1)
    }

    @Test func sidebarScrollViewportStaysBetweenItsHeaderAndFooter() async throws {
        for height: CGFloat in [260, 700] {
            let window = self.window(StorebenchSidebar(selection: LibraryOverview.Section.overview.selection, section: .overview, hasApp: false,
                selectLibrary: { _ in }, selectSection: { _ in }, settings: {}, help: {}), width: 248, height: height)
            defer { window.orderOut(nil); window.close() }
            try await settle(window)
            let root = try #require(window.contentView), views = descendants(root)
            let markers = views.compactMap { $0 as? StorebenchControlMarker }
            let header = try #require(markers.first { $0.identifier?.rawValue == "sidebar.header" })
            let footer = try #require(markers.first { $0.identifier?.rawValue == "sidebar.footer" })
            let scroll = try #require(views.compactMap { $0 as? NSScrollView }.first)
            let top = root.convert(header.bounds, from: header), bottom = root.convert(footer.bounds, from: footer)
            let viewport = root.convert(scroll.contentView.bounds, from: scroll.contentView)
            if root.isFlipped {
                #expect(viewport.minY >= top.maxY - 1 && viewport.maxY <= bottom.minY + 1)
            } else {
                #expect(viewport.maxY <= top.minY + 1 && viewport.minY >= bottom.maxY - 1)
            }
            #expect(viewport.height > 0 && viewport.width > 0)
        }
    }
}
