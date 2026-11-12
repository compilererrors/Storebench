import AppKit
import Observation
import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

@MainActor @Suite(.serialized) struct DesignConsistencyTests {
    init() throws { _ = try TestIsolation.require() }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func frame(_ id: String, in root: NSView) throws -> CGRect {
        let marker = try #require(descendants(root).compactMap { $0 as? StorebenchControlMarker }.first { $0.identifier?.rawValue == id })
        return root.convert(marker.bounds, from: marker)
    }
    private func window<V: View>(_ content: V, width: CGFloat, height: CGFloat = 700) async throws -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.modifier(StorebenchAppearance())
            .frame(width: width, height: height, alignment: .topLeading)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        window.orderBack(nil)
        try await settle(window)
        return window
    }
    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(80))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }

    private var settingsFields: some View {
        StorebenchFormGrid {
            StorebenchFormField(label: "Service", hint: "Choose the service for a new task.") {
                StorebenchNativePicker(title: "Service", selection: .constant("local"), options: [SelectionOption("Synthetic Local Service", value: "local")])
                    .storebenchControlID("service")
            }
            StorebenchFormField(label: "Country", hint: "Search the available choices.") {
                StorebenchSearchPicker("Country", selection: .constant("synthetic")) { SelectionOption("Synthetic Country", value: "synthetic") }
                    .labelsHidden().storebenchControlID("country")
            }
        }.environment(\.settingsPresentation, true)
    }

    @Test func settingsFieldsKeepOneControlColumnAndStackInNarrowPanes() async throws {
        for width: CGFloat in [360, 720, 1000] {
            let window = try await window(settingsFields.padding(20), width: width)
            defer { window.orderOut(nil); window.close() }
            let root = try #require(window.contentView)
            let service = try frame("service", in: root), country = try frame("country", in: root)
            let expected = width < 536 ? width - 40 : StorebenchTheme.settingsControlWidth
            #expect(abs(service.width - expected) < 1 && abs(country.width - expected) < 1)
            #expect(abs(service.minX - country.minX) < 1 && abs(service.maxX - country.maxX) < 1)
            #expect(abs(service.height - StorebenchTheme.controlHeight) < 1 && abs(country.height - StorebenchTheme.controlHeight) < 1)
            #expect(!service.intersects(country) && service.minX >= 0 && country.maxX <= root.bounds.width)
        }
    }

    @MainActor @Observable final class DisclosureState { var expanded = false; var mounts = 0 }
    @MainActor @Observable final class FeedbackState { var text = "" }

    @MainActor private final class SignInReceiver: ChatGPTSignInReceiving {
        var starts = 0, cancelled = false
        private var waiter: CheckedContinuation<URL, Error>?
        func start() async throws -> URL {
            starts += 1
            return URL(string: "http://127.0.0.1:49152/auth/callback")!
        }
        func wait() async throws -> URL {
            if cancelled { throw CancellationError() }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }
        func cancel() { cancelled = true; waiter?.resume(throwing: CancellationError()); waiter = nil }
    }

    @Test func chatGPTButtonStartsOneBrowserAttemptEvenWhenPressedTwice() async throws {
        let root = try TestIsolation.require().appendingPathComponent("synthetic-sign-in-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(root: root), writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage())
        let model = WorkspaceController(workspace: workspace, writer: writer, backupDelay: .seconds(3600), availabilityDelay: .seconds(3600), releaseWarmDelay: nil)
        await model.start(); await model.setUp(password: nil)
        let receiver = SignInReceiver()
        var opens = 0
        let services = ChatGPTSignInServices(receiver: { _ in receiver }, openBrowser: { url in
            #expect(url.scheme == "https" && url.host == "auth.openai.com")
            opens += 1; return true
        })
        let window = try await window(ChatGPTSettings(model: model, signInServices: services).padding(20).environment(\.settingsPresentation, true), width: 720)
        defer { receiver.cancel(); window.orderOut(nil); window.close() }
        let view = try #require(window.contentView)
        var marker: StorebenchControlMarker?
        let readyDeadline = ContinuousClock.now + .seconds(5)
        while marker?.available != true {
            guard ContinuousClock.now < readyDeadline else { Issue.record("The synthetic sign-in button did not become available"); await model.prepareToTerminate(); return }
            try await settle(window)
            marker = descendants(view).compactMap { $0 as? StorebenchControlMarker }.first { $0.identifier?.rawValue == "chatgpt.sign-in" }
        }
        let target = try #require(marker), point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        window.makeKeyAndOrderFront(nil)
        if let native = descendants(view).compactMap({ $0 as? NSControl }).first(where: {
            $0.cell is NSButtonCell && !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: nil).contains(point)
        }) {
            #expect(native.isEnabled)
            native.performClick(nil); native.performClick(nil)
        } else {
            for _ in 0..<2 {
                for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0))
                    window.sendEvent(event)
                }
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while opens == 0 && ContinuousClock.now < deadline { try await settle(window) }
        #expect(receiver.starts == 1 && opens == 1, "A click must start the callback and open the browser; repeated presses must keep that attempt")
        receiver.cancel(); window.contentView = nil
        try await settle(window)
        await model.prepareToTerminate()
    }

    @Test func settingsCardsFitTogetherAndFeedbackDoesNotMoveTheirCommands() async throws {
        let state = FeedbackState(), destination = try TestIsolation.require()
        let preferences = StorebenchAppearancePreferences.shared, previous = preferences.choice
        defer { preferences.choose(previous) }
        for dark in [false, true] {
            preferences.choose(dark ? .dark : .light)
            let content = StorebenchForm {
                StorebenchSectionLinks {
                    Button("ChatGPT") {}; Button("Claude") {}; Button("Apple Intelligence") {}; Button("AI History") {}
                }.storebenchControlID("density.links")
                StorebenchFormSection("Default AI Service", icon: "settings", description: "The starting service for new cards and translations. Each task can choose its own service and model.") {
                    StorebenchPicker("Use for New AI Tasks", selection: .constant("synthetic")) {
                        SelectionOption("Synthetic AI Service", value: "synthetic")
                    }.environment(\.fieldHintHeight, 0).storebenchControlID("density.picker")
                    StorebenchTextSlot(text: state.text, height: 32, font: .sbCaption, color: StorebenchTheme.muted, live: true)
                    DisclosureGroup("Compare Saved Values") { Text("Synthetic comparison") }
                    StorebenchFormFooter { Button("Use As Default") {}.storebenchControlID("density.save") }
                }.storebenchControlID("density.card")
                StorebenchFormSection("Claude", icon: "sparkles", description: "Connect a synthetic service for cards and translations.") {
                    StorebenchTextField("API Key", text: .constant(""))
                    StorebenchFormFooter { Button("Save Connection") {} }
                }.storebenchControlID("density.next")
            }.environment(\.settingsPresentation, true)
            let window = try await window(content, width: 720, height: 700)
            defer { window.orderOut(nil); window.close() }
            let root = try #require(window.contentView)
            let card = try frame("density.card", in: root), save = try frame("density.save", in: root), picker = try frame("density.picker", in: root)
            #expect(card.height <= 280, "An ordinary settings section must not consume most of the window")
            #expect(try frame("density.links", in: root).height <= 33, "Section navigation fits on one row")
            #expect(try frame("density.next", in: root).maxY <= root.bounds.height, "The next settings section remains visible")
            for message in ["Synthetic status", String(repeating: "Synthetic longer feedback. ", count: 30), ""] {
                state.text = message; try await settle(window)
                #expect(try frame("density.card", in: root) == card)
                #expect(try frame("density.save", in: root) == save && frame("density.picker", in: root) == picker)
            }
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: destination.appendingPathComponent(dark ? "settings-density-dark.png" : "settings-density-light.png"))
        }
    }
    private struct RetainedContent: View {
        let state: DisclosureState
        @State private var text = "Synthetic Draft"
        var body: some View {
            StorebenchTextField("Draft", text: $text).onAppear { state.mounts += 1 }
        }
    }

    @Test func disclosureTargetsStayCompactAndReopeningKeepsMountedEditors() async throws {
        let state = DisclosureState()
        let content = VStack(alignment: .leading, spacing: 16) {
            StorebenchDisclosureButton(isExpanded: Binding(get: { state.expanded }, set: { state.expanded = $0 })) { Text("Connection Settings") }
                .storebenchControlID("disclosure")
            DisclosureGroup("Saved Values", isExpanded: Binding(get: { state.expanded }, set: { state.expanded = $0 })) { RetainedContent(state: state) }
        }.padding(20).frame(maxHeight: .infinity, alignment: .top)
        let window = try await window(content, width: 720)
        defer { window.orderOut(nil); window.close() }
        let root = try #require(window.contentView), header = try frame("disclosure", in: root)
        #expect(header.width < 300 && header.height == StorebenchTheme.controlHeight)
        #expect(state.mounts == 0)
        state.expanded = true; try await settle(window)
        #expect(state.mounts == 1)
        state.expanded = false; try await settle(window)
        state.expanded = true; try await settle(window)
        #expect(state.mounts == 1, "Collapsing a section must preserve its editor instead of reloading it")
    }

    @Test func cardsInAGridShareTheirBottomEdgeAndCommandBaseline() async throws {
        let content = StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 280) {
            Card(title: "Short Card", subtitle: "Synthetic description") {
                Text("Synthetic short content")
                StorebenchFormFooter { Button("Save Draft") {}.storebenchControlID("short-command") }
            }.storebenchControlID("short-card")
            Card(title: "Long Card", subtitle: "Synthetic description") {
                StorebenchTextSlot(text: String(repeating: "Synthetic longer content. ", count: 25), height: 80)
                StorebenchFormFooter { Button("Save Draft") {}.storebenchControlID("long-command") }
            }.storebenchControlID("long-card")
        }.padding(20).frame(maxHeight: .infinity, alignment: .top)
        let window = try await window(content, width: 900)
        defer { window.orderOut(nil); window.close() }
        let root = try #require(window.contentView)
        let short = try frame("short-card", in: root), long = try frame("long-card", in: root)
        let first = try frame("short-command", in: root), second = try frame("long-command", in: root)
        #expect(abs(short.height - long.height) < 1 && abs(short.minY - long.minY) < 1)
        #expect(abs(first.midY - second.midY) < 1, "Different amounts of copy must leave commands on one baseline")
        #expect(short.contains(first) && long.contains(second))
    }

    @Test func aLoneFieldKeepsTheColumnOfACompleteFormRow() async throws {
        func field(_ id: String) -> some View {
            StorebenchFormField(label: "Synthetic Choice") {
                StorebenchNativePicker(title: "Choice", selection: .constant(1), options: [SelectionOption("Synthetic Choice", value: 1)])
                    .storebenchControlID(id)
            }
        }
        let content = VStack(alignment: .leading, spacing: 16) {
            StorebenchFormGrid { field("single") }
            StorebenchFormGrid { field("first"); field("second") }
        }.padding(20)
        let window = try await window(content, width: 900)
        defer { window.orderOut(nil); window.close() }
        let root = try #require(window.contentView)
        let single = try frame("single", in: root), first = try frame("first", in: root), second = try frame("second", in: root)
        #expect(abs(single.width - first.width) < 1 && abs(single.minX - first.minX) < 1)
        #expect(abs(first.width - second.width) < 1 && first.maxX < second.minX)
    }

    @Test func cardsOutsideAGridKeepTheirNaturalHeight() async throws {
        let content = VStack(alignment: .leading, spacing: 16) {
            Card(title: "Synthetic Card", subtitle: "Synthetic description") {
                Text("Synthetic content")
                StorebenchFormFooter { Button("Save Draft") {} }
            }.storebenchControlID("natural-card")
            Card(title: "Another Card", subtitle: "Synthetic description") { Text("Synthetic content") }
        }.padding(20).frame(maxHeight: .infinity, alignment: .top)
        var previous: CGFloat?
        for height: CGFloat in [700, 1000] {
            let window = try await window(content, width: 720, height: height)
            defer { window.orderOut(nil); window.close() }
            let root = try #require(window.contentView), card = try frame("natural-card", in: root)
            #expect(card.height < 300 && root.bounds.height <= height + 1)
            if let previous { #expect(abs(card.height - previous) < 1, "A taller viewport must not stretch ordinary form cards") }
            previous = card.height
        }
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
            StorebenchFormSection("Connection", icon: "settings", description: "Synthetic controls using the same field and command surfaces.", accessory: AnyView(
                StorebenchIconMenu(title: "Connection Options") { Button("Synthetic Action") {} }
            )) {
                settingsFields
                DisclosureGroup("Compare Saved Values", isExpanded: .constant(false)) { Text("Synthetic comparison") }
                StorebenchFormFooter { Button("Save Model") {}.buttonStyle(StorebenchButtonStyle(.primary)) }
            }
            StorebenchFormSection("Advanced Options", icon: "security", description: "Related fields follow the same grid when expanded.") {
                DisclosureGroup("Connection Settings", isExpanded: .constant(true)) {
                    StorebenchTextField("Model", text: .constant("Synthetic Model"), hint: "A synthetic value used only for rendering.")
                    StorebenchNavigationSelect(title: "Revision", selected: "Synthetic Saved Revision") { Button("Synthetic Revision") {} }
                }
            }
        }.environment(\.settingsPresentation, true).padding(28).frame(maxHeight: .infinity, alignment: .top)
    }

    @Test func sharedControlsRenderInLightAndDarkWithoutChangingTheirGeometry() async throws {
        let root = try TestIsolation.require()
        let preferences = StorebenchAppearancePreferences.shared, previous = preferences.choice
        defer { preferences.choose(previous) }
        for dark in [false, true] {
            preferences.choose(dark ? .dark : .light)
            let window = try await window(gallery.environment(\.colorScheme, dark ? .dark : .light), width: 720, height: 1050)
            defer { window.orderOut(nil); window.close() }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await settle(window)
            let view = try #require(window.contentView), first = try frame("service", in: view), second = try frame("country", in: view)
            #expect(view.bounds.height <= 1051, "Ordinary settings cards must fit their content instead of inflating the window")
            #expect(first.width == second.width && first.height == second.height)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(bitmap.pixelsWide >= 720 && bitmap.pixelsHigh >= 1050 && !png.isEmpty)
            let background = try #require(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB))
            let brightness = (background.redComponent + background.greenComponent + background.blueComponent) / 3
            #expect(dark ? brightness < 0.35 : brightness > 0.6, "Each appearance must render its own surface palette")
            try png.write(to: root.appendingPathComponent(dark ? "ui-components-dark.png" : "ui-components-light.png"))
        }
    }

    private var compactChoices: some View {
        StorebenchOptionGroup(title: "Creative Directions", description: "Choose any combination. Each option adds guidance to the synthetic brief.") {
            StorebenchOptionGrid {
                ForEach(Array(AICardDirection.allCases.enumerated()), id: \.element) { index, direction in
                    StorebenchToggle(direction.title, isOn: .constant(index < 4)).help(direction.instruction)
                        .storebenchControlID("compact-option-\(index)")
                }
            }
            DisclosureGroup("Preview Prompt Instructions") { Text("Synthetic instructions") }
        }.storebenchControlID("compact-group")
    }

    @Test func optionGroupsStayCompactAndBoundedAndStackInNarrowWindows() async throws {
        for width: CGFloat in [360, 760, 1440] {
            let window = try await window(compactChoices.padding(20), width: width, height: 500)
            defer { window.orderOut(nil); window.close() }
            let root = try #require(window.contentView), group = try frame("compact-group", in: root)
            let first = try frame("compact-option-0", in: root), second = try frame("compact-option-1", in: root), third = try frame("compact-option-2", in: root)
            #expect(group.width <= StorebenchTheme.measure("optionGroupWidth") + 1 && group.minX >= 0 && group.maxX <= root.bounds.width)
            #expect(first.height >= 24 && first.height <= 26 && group.contains(first) && group.contains(third))
            if width == 360 {
                #expect(abs(first.minX - second.minX) < 1 && second.minY > first.maxY)
            } else {
                #expect(abs(first.minY - second.minY) < 1 && second.minX > first.maxX)
                #expect(third.minY - first.minY <= 30, "Options must not inherit empty form-field tracks")
                #expect(group.height < 240, "Six related options and their context stay together")
            }
        }
    }

    @Test func expandedContentStartsUnderTheDisclosureLabel() async throws {
        let content = DisclosureGroup(isExpanded: .constant(true)) {
            DisclosureGroup(isExpanded: .constant(true)) {
                StorebenchToggle("Synthetic Subordinate Option", isOn: .constant(true)).storebenchControlID("nested-option")
            } label: { Text("Nested Options").storebenchControlID("nested-second-label") }
        } label: {
            Text("Advanced Options").storebenchControlID("nested-label")
        }.padding(20).frame(maxHeight: .infinity, alignment: .top)
        let window = try await window(content, width: 720, height: 300)
        defer { window.orderOut(nil); window.close() }
        let root = try #require(window.contentView), label = try frame("nested-label", in: root), child = try frame("nested-second-label", in: root), option = try frame("nested-option", in: root)
        let indent = StorebenchTheme.measure("disclosureIcon") + StorebenchTheme.measure("disclosureGap")
        #expect(abs(child.minX - label.minX - indent) < 1)
        #expect(abs(child.minX - option.minX) < 1 && option.minX > 20)
        #expect(option.minY > child.maxY && option.maxX <= root.bounds.width - 20)
    }

    @Test func compactOptionsAndDisclosureHierarchyRenderInBothAppearances() async throws {
        let root = try TestIsolation.require(), preferences = StorebenchAppearancePreferences.shared, previous = preferences.choice
        defer { preferences.choose(previous) }
        for dark in [false, true] {
            preferences.choose(dark ? .dark : .light)
            let content = VStack(alignment: .leading, spacing: 20) {
                Card(title: "Create AI Cards", subtitle: "Synthetic controls with grouped independent choices.") { compactChoices }
                StorebenchFormSection("Settings", description: "A feature switch and independent options have different purposes.") {
                    StorebenchSettingToggle("Automatic Backups", isOn: .constant(true))
                    StorebenchOptionGrid {
                        StorebenchToggle("Ask Before Removing Drafts", isOn: .constant(true))
                        StorebenchToggle("Ask Before Removing Images", isOn: .constant(false))
                    }
                    DisclosureGroup("Advanced Options", isExpanded: .constant(true)) {
                        StorebenchToggle("Keep the Synthetic Local Copy", isOn: .constant(true))
                        DisclosureGroup("More Details") { Text("Synthetic details") }
                    }
                }
            }.padding(24).frame(maxHeight: .infinity, alignment: .top)
            let window = try await window(content, width: 960, height: 760)
            defer { window.orderOut(nil); window.close() }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await settle(window)
            let view = try #require(window.contentView), bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(!png.isEmpty && view.bounds.height <= 761)
            try png.write(to: root.appendingPathComponent(dark ? "option-components-dark.png" : "option-components-light.png"))
        }
    }

    @Test func promptEditAndResetActionsStayAboveTheTextAtTheTrailingEdge() async throws {
        for width: CGFloat in [360, 720] {
            let content = AICardPromptEditor(customInstructions: .constant("Synthetic custom instructions."), directions: AICardDirection.defaults).padding(20)
            let window = try await window(content, width: width, height: 500)
            defer { window.orderOut(nil); window.close() }
            let root = try #require(window.contentView), edit = try frame("ai-cards.edit-prompt", in: root), reset = try frame("ai-cards.reset-prompt", in: root)
            #expect(abs(edit.width - StorebenchTheme.controlHeight) < 1 && abs(edit.height - StorebenchTheme.controlHeight) < 1)
            #expect(abs(edit.maxX - (root.bounds.width - 20)) < 1 && reset.maxX < edit.minX)
            #expect(edit.minY < 60 && abs(edit.minY - reset.minY) < 1)
        }
    }

    @Test func savedPromptPaintsAfterRepeatedDisclosureAndWindowReopening() async throws {
        let state = DisclosureState(); state.expanded = true
        let text = String(repeating: "Synthetic prompt instructions keep each visible feature distinct. ", count: 24)
        let content = VStack(alignment: .leading, spacing: 16) {
            StorebenchOptionGroup(title: "Creative Directions") { StorebenchToggle("Modern and Clean", isOn: .constant(true)) }
                .storebenchControlID("choices")
            DisclosureGroup(isExpanded: Binding(get: { state.expanded }, set: { state.expanded = $0 })) {
                StorebenchReadOnlyText(title: "", text: text, height: 180).storebenchControlID("saved-prompt")
            } label: { Text("Prompt Instructions") }
        }.padding(20).frame(maxHeight: .infinity, alignment: .top)
        let window = try await window(content, width: 1200, height: 600)
        defer { window.orderOut(nil); window.close() }
        let root = try #require(window.contentView)
        func paintedInk() throws -> Int {
            var area = try frame("saved-prompt", in: root)
            area.size.height = min(170, area.height)
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: area))
            root.cacheDisplay(in: area, to: bitmap)
            var ink = 0
            for y in stride(from: 3, to: bitmap.pixelsHigh - 3, by: 2) {
                for x in stride(from: 3, to: bitmap.pixelsWide - 3, by: 2) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), max(color.redComponent, color.greenComponent, color.blueComponent) < 0.7 { ink += 1 }
                }
            }
            return ink
        }
        let before = try paintedInk()
        #expect(before > 800)
        #expect(try frame("saved-prompt", in: root).width > frame("choices", in: root).width + 300)
        for _ in 0..<3 {
            state.expanded = false; try await settle(window)
            state.expanded = true; try await settle(window)
            window.orderOut(nil); window.orderBack(nil); try await settle(window)
            #expect(try paintedInk() > before * 8 / 10, "Text must repaint without clicking or selecting it")
        }
    }

}
