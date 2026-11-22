import AppKit
import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

/// Every command in a card ends on the card's one trailing command column, and a card shown by a disclosure keeps the page's
/// grid, so nested sections never shift it, as in Quick Release's Version Settings and Build steps.
@MainActor @Suite(.serialized) struct CardGridTests {
    init() throws { _ = try TestIsolation.require() }

    struct Page: View {
        @State private var open = true
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Synthetic Build", subtitle: "Synthetic description of the step",
                     actions: AnyView(Button("Refresh Builds") {}.buttonStyle(StorebenchButtonStyle(.secondary)).storebenchControlID("grid.header"))) {
                    Text("Synthetic build list")
                    StorebenchEditorFooter(title: "Synthetic Selection", detail: "Synthetic draft saved on this Mac.") {
                        StorebenchActionGroup(alignment: .trailing) {
                            Button("Save Draft") {}.buttonStyle(StorebenchButtonStyle(.secondary)).storebenchControlID("grid.footer-save")
                            Button("Sync to Apple") {}.buttonStyle(StorebenchButtonStyle(.primary)).storebenchControlID("grid.footer")
                        }
                    }.storebenchControlID("grid.footer-area")
                }
                DisclosureGroup("Synthetic Settings", isExpanded: $open) {
                    Card(title: "Synthetic Nested Card", subtitle: "Inside the disclosure") { Text("Synthetic field").storebenchControlID("grid.nested") }
                }.storebenchControlID("grid.disclosure")
                Card(title: "Synthetic Sibling Card", subtitle: "Beside the disclosure") { Text("Synthetic field").storebenchControlID("grid.sibling") }
            }
            .disclosureGroupStyle(StorebenchDisclosureStyle())
            .padding(24).frame(width: 1000)
        }
    }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func frame(_ id: String, in root: NSView) throws -> CGRect {
        let marker = try #require(views(root).first { ($0 as? StorebenchControlMarker)?.identifier?.rawValue == id }, "\(id) is shown")
        return marker.convert(marker.bounds, to: root)
    }

    @Test func aFootersCommandsEndOnTheCardsCommandColumnAndNestedCardsKeepTheGrid() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1048, height: 900), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: Page())
        window.contentView = root; window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        for _ in 0..<6 { root.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(16)) }
        let header = try frame("grid.header", in: root), footer = try frame("grid.footer", in: root)
        let save = try frame("grid.footer-save", in: root), area = try frame("grid.footer-area", in: root)
        #expect(abs(header.maxX - footer.maxX) < 1, "The footer's Sync to Apple ends where the card's own command does: header \(header), sync \(footer), save \(save), footer \(area)")
        // The text inside each card starts at the same place, so both cards share one grid.
        let nested = try frame("grid.nested", in: root), sibling = try frame("grid.sibling", in: root)
        #expect(abs(nested.minX - sibling.minX) < 1, "A card in a disclosure keeps the page's grid: \(nested) vs \(sibling)")
    }
}
