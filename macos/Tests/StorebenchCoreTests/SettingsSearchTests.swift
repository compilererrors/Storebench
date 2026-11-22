import Foundation
import Testing
@testable import StorebenchCore

struct SettingsSearchTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func settingsCanBeFoundByTheirLabelsAndEverydayTermsAcrossPanes() throws {
        #expect(SettingsSearch.results(for: "screenshot cards").first?.id == "ai-cards")
        #expect(SettingsSearch.results(for: "minimize release").first?.id == "general-release-cards")
        #expect(SettingsSearch.results(for: "MINIMERA").first?.id == "general-release-cards")
        #expect(SettingsSearch.results(for: "memory budget").first?.id == "general-performance")
        #expect(SettingsSearch.results(for: "automatic save").first?.id == "editing-drafts")
        #expect(SettingsSearch.results(for: "Gemini API").contains { $0.id == "ai-api" })
        #expect(SettingsSearch.results(for: "backup passphrase").first?.pane == .backups)
        #expect(SettingsSearch.results(for: "keyboard").first?.pane == .shortcuts)
        #expect(SettingsSearch.results(for: "\n\t ").isEmpty)
        #expect(SettingsSearch.results(for: "no synthetic match here").isEmpty)
        #expect(Set(SettingsSearch.catalog.map(\.id)).count == SettingsSearch.catalog.count)
        #expect(Set(SettingsSearch.catalog.map(\.pane)) == Set(SettingsNavigation.Pane.allCases))
        #expect(SettingsSearch.results(for: "general").allSatisfy { $0.pane == .general })
    }
}
