import Foundation
import Testing
@testable import StorebenchCore

/// New AI card sets start from simple defaults that Settings can change: Quick, the app's own App Store text, a language and a size.
@Suite struct AICardDefaultsTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func theDefaultIsQuickWithTheAppsOwnText() {
        let defaults = AICardDefaults()
        #expect(defaults.mode == .quick && defaults.useListing && defaults.language == "en-US" && defaults.targetId == MediaCards.defaultTarget.id)
        #expect(AICardDefaults.Mode.allCases.map(\.title) == ["Quick", "Guided"])
    }

    @Test func choicesAreRememberedAndInvalidOnesFallBack() throws {
        let store = try #require(UserDefaults(suiteName: "synthetic.aicards.\(UUID().uuidString)"))
        #expect(AICardDefaults.stored(in: store) == AICardDefaults())
        let chosen = AICardDefaults(mode: .guided, language: "sv", targetId: MediaCards.targets.last!.id, useListing: false)
        chosen.save(in: store)
        #expect(AICardDefaults.stored(in: store) == chosen)
        // A language or size Storebench no longer knows falls back rather than breaking new card sets.
        store.set(Data(#"{"mode":"guided","language":"xx","targetId":"unknown","useListing":true}"#.utf8), forKey: AICardDefaults.defaultsKey)
        let repaired = AICardDefaults.stored(in: store)
        #expect(repaired.mode == .guided && repaired.language == "en-US" && repaired.targetId == MediaCards.defaultTarget.id)
    }
}
