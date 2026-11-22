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
        window.contentView = NSHostingView(rootView: content.frame(width: width, height: height, alignment: .topLeading)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        window.orderBack(nil)
        return window
    }

    private func marker(_ id: String, in root: NSView) throws -> StorebenchControlMarker {
        try #require(descendants(root).compactMap { $0 as? StorebenchControlMarker }.first { $0.identifier?.rawValue == id })
    }
    private func click(_ marker: StorebenchControlMarker, in window: NSWindow) throws {
        window.makeKeyAndOrderFront(nil)
        let point = marker.convert(.init(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    @MainActor @Observable final class ContextState {
        var selection = "saved"
        var refreshes = 0
    }
    private struct FieldWithAction: View {
        let state: ContextState
        var body: some View {
            StorebenchFormField(label: "AI Model", hint: "Refresh the model list for this service.", accessory: AnyView(
                StorebenchIconButton(title: "Refresh Models", icon: "refresh") { state.refreshes += 1 }.storebenchControlID("model.refresh")
            )) {
                StorebenchNativePicker(title: "AI Model", selection: Binding(get: { state.selection }, set: { state.selection = $0 }), options: [SelectionOption("Synthetic Saved Model", value: "saved")])
                    .storebenchControlID("model.input")
            }.environment(\.settingsPresentation, true).padding(20)
        }
    }

    @Test func aFieldCommandStaysBesideItsInputAndDoesNotChangeTheSelection() async throws {
        for width: CGFloat in [360, 720] {
            let state = ContextState(), window = self.window(FieldWithAction(state: state).modifier(StorebenchAppearance()), width: width, height: 180)
            defer { window.orderOut(nil); window.close() }
            try await settle(window)
            let root = try #require(window.contentView), input = try marker("model.input", in: root), refresh = try marker("model.refresh", in: root)
            let field = root.convert(input.bounds, from: input), command = root.convert(refresh.bounds, from: refresh)
            #expect(command.minX >= field.maxX && command.minX - field.maxX <= 9)
            #expect(abs(field.midY - command.midY) < 1 && abs(command.width - StorebenchTheme.controlHeight) < 1)
            #expect(command.maxX <= root.bounds.maxX && field.minX >= 0)
            try click(refresh, in: window); try await settle(window)
            #expect(state.refreshes == 1 && state.selection == "saved")
        }
    }

    @Test func aRecordMenuStaysOutsideItsDisclosureAndAvailableWhenClosed() async throws {
        for width: CGFloat in [360, 720] {
            let editor = LanguageLayoutEditor(); editor.loaded(LanguageEditorLayout())
            let content = StorebenchCollection(items: [StorebenchCollectionEntry(id: "synthetic-language", value: "en-US")], title: { _ in "Synthetic Language With a Longer Name" },
                subtitle: { _ in "Saved Text · 2 Changed Fields" }, headerActions: { item in AnyView(
                    LanguageLayoutControls(editor: editor, accountId: "synthetic-account", appId: "synthetic-app", session: nil, locale: item.value)
                ) }, empty: "No Languages") { _ in Text("Synthetic language editor").storebenchControlID("synthetic-editor") }
                .padding(20).frame(maxHeight: .infinity, alignment: .top).modifier(StorebenchAppearance())
            let window = self.window(content, width: width, height: 280); defer { window.orderOut(nil); window.close() }
            try await settle(window)
            let root = try #require(window.contentView), disclosure = try marker("collection.disclosure.synthetic-language", in: root), menu = try marker("language.sections.en-US", in: root)
            let heading = root.convert(disclosure.bounds, from: disclosure), action = root.convert(menu.bounds, from: menu)
            #expect(menu.available && action.minX >= heading.maxX && action.minX - heading.maxX <= 9)
            #expect(action.width == StorebenchTheme.controlHeight && action.maxX <= root.bounds.maxX - 20)
            #expect(heading.minY <= action.midY && heading.maxY >= action.midY)
            #expect(!descendants(root).contains { ($0 as? StorebenchControlMarker)?.identifier?.rawValue == "synthetic-editor" })
            try click(disclosure, in: window); try await settle(window)
            #expect(try marker("synthetic-editor", in: root).available)
            #expect(root.convert(menu.bounds, from: menu) == action, "Opening a card must keep its context menu anchored to the header")
            if width == 720 {
                let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let scaleX = CGFloat(bitmap.pixelsWide) / root.bounds.width, scaleY = CGFloat(bitmap.pixelsHigh) / root.bounds.height
                func ink(at y: CGFloat) -> Int {
                    let rect = CGRect(x: action.minX * scaleX, y: y * scaleY, width: action.width * scaleX, height: action.height * scaleY).integral
                    guard let base = bitmap.colorAt(x: Int(rect.minX + 1), y: Int(rect.minY + 1))?.usingColorSpace(.deviceRGB) else { return 0 }
                    var count = 0
                    for x in Int(rect.minX + 3)..<Int(rect.maxX - 3) {
                        for y in Int(rect.minY + 3)..<Int(rect.maxY - 3) {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                            if abs(color.redComponent - base.redComponent) + abs(color.greenComponent - base.greenComponent) + abs(color.blueComponent - base.blueComponent) > 0.3 { count += 1 }
                        }
                    }
                    return count
                }
                #expect(max(ink(at: action.minY), ink(at: root.bounds.height - action.maxY)) > 4, "The menu target must draw its visible ellipsis")
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: TestIsolation.require().appendingPathComponent("contextual-language-controls.png"))
            }
            editor.change([.privacy: false])
            await editor.flush { _ in throw LanguageEditorLayout.Failure.invalid }
            try await settle(window)
            #expect(editor.failed && root.convert(menu.bounds, from: menu) == action, "Save feedback must not move the menu or resize the record header")
        }
    }

    @Test func nativeSelectionUsesTheFullTitleAndDoesNotSubstituteMissingValues() async throws {
        let choices = Choices(), window = self.window(PickerExample(choices: choices)); defer { window.orderOut(nil); window.close() }
        try await settle(window)
        let root = try #require(window.contentView), popup = try #require(descendants(root).compactMap { $0 as? NSPopUpButton }.first)
        // The native pop-up keeps its menu and keyboard focus inside the shared field, which draws the border and focus ring.
        #expect(!popup.isTransparent && !popup.isBordered && popup.focusRingType == .none && !popup.pullsDown)
        #expect(window.makeFirstResponder(popup) && window.firstResponder === popup, "The native popup remains the keyboard focus target")
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
