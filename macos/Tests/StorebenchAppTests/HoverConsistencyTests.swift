import AppKit
import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

/// Hover looks and behaves the same everywhere: one core follows the pointer, one fill shows it, and a card's own command is a
/// standard command beside its heading.
@MainActor @Suite(.serialized) struct HoverConsistencyTests {
    init() throws { _ = try TestIsolation.require() }

    private func marker(_ id: String, in view: NSView) -> NSView? {
        if (view as? StorebenchControlMarker)?.identifier?.rawValue == id { return view }
        for child in view.subviews { if let found = marker(id, in: child) { return found } }
        return nil
    }

    /// On a release card as wide as the page, Continue Release is the main target across the heading, and showing the
    /// status is the smaller command beside it on the same row.
    @Test func aReleaseCardsHeadingContinuesAndItsSideCommandShowsStatus() throws {
        let card = ReleaseOverviewDisclosureCard(title: "Synthetic App · 1.0", overview: nil, icon: AnyView(Color.gray), expanded: .constant(false),
                                                 identifier: "synthetic.release", open: {})
            .frame(width: 1_400).environment(\.workspaceWidth, 1_600).environment(\.workspaceHeight, 900)
        let host = NSHostingView(rootView: card)
        host.frame.size = host.fittingSize; host.layoutSubtreeIfNeeded()
        let open = try #require(marker("synthetic.release.open", in: host)), disclosure = try #require(marker("synthetic.release.disclosure", in: host))
        let main = open.convert(open.bounds, to: host), side = disclosure.convert(disclosure.bounds, to: host)
        #expect(main.width > host.bounds.width * 0.6, "Continue spans the heading: \(main.width) of \(host.bounds.width)")
        #expect(abs(side.width - CGFloat(StorebenchTheme.actionWidth)) < 0.5, "Show Status keeps the standard command width: \(side.width)")
        #expect(abs(main.height - side.height) < 1 && abs(main.minY - side.minY) < 1, "Both fill one row: \(main) \(side)")
        #expect(side.minX >= main.maxX - 0.5, "They sit side by side without overlapping")
    }

    /// Every control follows the pointer through the shared core, so no control invents its own hover look.
    @Test func onlyTheSharedCoreFollowsThePointer() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorebenchApp")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "The app's sources are readable: \(sources.path)")
        var hovering: [String] = [], ownColours: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8), name = file.lastPathComponent
            if name != "StorebenchHover.swift", text.contains(".onHover") || text.contains("onContinuousHover") { hovering.append(name) }
            // A hover fill made of its own colour instead of the shared one.
            for line in text.split(separator: "\n") where line.contains("hovering ?") || line.contains("hovered ?") || line.contains("Hovered ?") {
                if line.contains("StorebenchTheme.color(\"") || line.contains("StorebenchTheme.page") { ownColours.append(name + ": " + line.trimmingCharacters(in: .whitespaces)) }
            }
        }
        #expect(hovering.isEmpty, "Follow the pointer with storebenchHover: \(hovering)")
        #expect(ownColours.isEmpty, "Draw hover with the shared fill: \(ownColours)")
    }
}

/// Every kind of command and heading looks different while the pointer is over it.
@MainActor @Suite(.serialized) struct HoverRenderTests {
    init() throws { _ = try TestIsolation.require() }

    private func pixels(_ view: some View, hovering: Bool) async throws -> Data {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: view.environment(\.hoverPreview, hovering).padding(20).frame(width: 420, height: 120).background(StorebenchTheme.surface))
        window.orderBack(nil)
        for _ in 0..<4 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(16)) }
        let content = try #require(window.contentView), bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func everyCommandAndHeadingShowsThePointer() async throws {
        let commands: [(String, AnyView)] = [
            ("primary", AnyView(Button("Synthetic Primary") {}.buttonStyle(StorebenchButtonStyle(.primary)))),
            ("secondary", AnyView(Button("Synthetic Secondary") {}.buttonStyle(StorebenchButtonStyle(.secondary)))),
            ("danger", AnyView(Button("Synthetic Remove", role: .destructive) {}.buttonStyle(StorebenchButtonStyle(.secondary)))),
            ("quiet", AnyView(Button("Synthetic Quiet") {}.buttonStyle(StorebenchButtonStyle(.quiet)))),
            ("heading", AnyView(StorebenchDisclosureButton(isExpanded: .constant(false), card: true) { Text("Synthetic Heading") })),
            ("card action", AnyView(StorebenchCardAction(title: "Synthetic Continue", action: {}) { Text("Synthetic App") }.frame(width: 360, height: 70))),
        ]
        for (name, view) in commands {
            let resting = try await pixels(view, hovering: false), over = try await pixels(view, hovering: true)
            #expect(resting != over, "\(name) looks the same with the pointer over it")
        }
    }
}

/// A required choice is always in view: Translate Languages shows From and Into as two fields on one row, never a folded list.
@MainActor @Suite(.serialized) struct RequiredChoiceTests {
    init() throws { _ = try TestIsolation.require() }
    private func marker(_ id: String, in view: NSView) -> NSView? {
        if (view as? StorebenchControlMarker)?.identifier?.rawValue == id { return view }
        for child in view.subviews { if let found = marker(id, in: child) { return found } }
        return nil
    }
    struct Fields: View {
        @State var source = "en-US"
        @State var targets: Set<String> = ["de-DE", "fr-FR", "ja"]
        var body: some View {
            StorebenchFormGrid {
                StorebenchPicker("From", selection: $source) { SelectionOption("English (U.S.)", value: "en-US") }.storebenchControlID("synthetic.from")
                StorebenchMultiSelect(title: "Into", dialogTitle: "Choose Languages", selection: $targets, options: StoreLocales.codes, name: StoreLocales.name,
                                      summary: TranslationTargets.summary(targets), controlID: "synthetic.into")
            }.environment(\.fieldHintHeight, 0)
        }
    }

    /// Selections and text fields share one look: no selection keeps macOS's own pop-up bezel beside a text field.
    @Test func selectionsAndTextFieldsShareTheFieldLook() throws {
        struct Form: View {
            @State var set = "a"
            @State var name = "Synthetic Cards"
            @State var targets: Set<String> = ["de-DE"]
            var body: some View {
                StorebenchFormGrid {
                    StorebenchPicker("Card Set", selection: $set) { SelectionOption("Synthetic Cards", value: "a") }
                    StorebenchTextField("Card Set Name", text: $name)
                    StorebenchMultiSelect(title: "Into", dialogTitle: "Choose Languages", selection: $targets, options: StoreLocales.codes, name: StoreLocales.name,
                                          summary: TranslationTargets.summary(targets), controlID: "synthetic.into")
                }.environment(\.fieldHintHeight, 0)
            }
        }
        let host = NSHostingView(rootView: Form().frame(width: 1_000).environment(\.workspaceWidth, 1_400).environment(\.workspaceHeight, 900))
        host.frame.size = host.fittingSize; host.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let popUps = all(host).compactMap { $0 as? NSPopUpButton }
        #expect(popUps.count == 2, "Card Set and Into are selections: \(popUps.count)")
        #expect(popUps.allSatisfy { !$0.isBordered }, "Selections draw the shared field, not the native bezel")
    }

    @Test func fromAndIntoAreTwoVisibleFieldsOnOneRow() throws {
        let host = NSHostingView(rootView: Fields().frame(width: 1_000).environment(\.workspaceWidth, 1_400).environment(\.workspaceHeight, 900))
        host.frame.size = host.fittingSize; host.layoutSubtreeIfNeeded()
        let from = try #require(marker("synthetic.from", in: host)), into = try #require(marker("synthetic.into", in: host))
        let left = from.convert(from.bounds, to: host), right = into.convert(into.bounds, to: host)
        #expect(right.height >= CGFloat(StorebenchTheme.controlHeight) - 0.5 && right.width > 200, "Into is a full field: \(right)")
        // From's marker covers its whole field, label and hint track included; Into's face sits within that same row.
        #expect(left.maxX <= right.minX && right.minY >= left.minY && right.maxY <= left.maxY + 0.5, "From and Into share one row: \(left) \(right)")
        #expect(TranslationTargets.summary(["de-DE", "fr-FR", "ja"]).hasSuffix("3 Languages"))
    }
}
