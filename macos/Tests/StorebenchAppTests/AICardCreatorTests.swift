import AppKit
import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

/// Creating AI cards has a simple default and a guided way: Quick asks only for screenshots and uses the app's own App Store
/// text; Guided adds the brief, the style and a message per card. Both can add screenshots from files or Asset Library.
@MainActor @Suite(.serialized) struct AICardCreatorTests {
    init() throws { _ = try TestIsolation.require() }
    private func markers(_ view: NSView) -> Set<String> {
        Set(((view as? StorebenchControlMarker)?.identifier?.rawValue).map { [$0] } ?? []).union(view.subviews.flatMap(markers))
    }
    private func render(_ mode: AICardDefaults.Mode) throws -> Set<String> {
        let store = UserDefaults.standard, previous = store.data(forKey: AICardDefaults.defaultsKey)
        defer { if let previous { store.set(previous, forKey: AICardDefaults.defaultsKey) } else { store.removeObject(forKey: AICardDefaults.defaultsKey) } }
        AICardDefaults(mode: mode).save(in: store)
        let account = Account(id: "synthetic-account", name: "Synthetic", keyId: "SYNTHKEY01", keyType: "team", issuerId: "00000000-0000-4000-8000-000000000000", appIds: ["1000000001"], appNames: nil)
        let creator = AICardsCreator(account: account, app: try #require(account.apps.first), session: nil) { _ in }
        let host = NSHostingView(rootView: creator.frame(width: 1_100).environment(\.workspaceWidth, 1_400).environment(\.workspaceHeight, 900))
        host.frame.size = host.fittingSize; host.layoutSubtreeIfNeeded()
        return markers(host)
    }

    @Test func quickAsksOnlyForScreenshotsAndUsesTheAppsOwnText() throws {
        let quick = try render(.quick)
        #expect(quick.isSuperset(of: ["ai-cards.mode", "ai-cards.use-listing", "ai-cards.add-screenshots", "ai-cards.add-library"]), "\(quick)")
        #expect(!quick.contains("ai-cards.prompt-instructions"), "Quick leaves the style and prompt to the defaults")
    }

    @Test func guidedAddsTheBriefStyleAndMessages() throws {
        let guided = try render(.guided)
        #expect(guided.isSuperset(of: ["ai-cards.mode", "ai-cards.use-listing", "ai-cards.prompt-instructions", "ai-cards.add-library"]), "\(guided)")
    }
}
