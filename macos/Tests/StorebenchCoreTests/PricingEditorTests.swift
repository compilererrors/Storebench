import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct PricingEditorTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func readingLatestDoesNotChangeInputsOrRefreshTheRevision() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try #require(try await session.pricingProfiles().profiles.first)
        var editor = SavedValueReview(value: PricingProfileInputs(initial), revision: PricingModels.profileRevision(initial))
        editor.inputs.name = "My unsaved model"
        var other = initial; other.name = "Saved elsewhere"; other.percentages = ["SWE": 80]
        try await session.updatePricingProfile("save", id: initial.id, profile: other, revision: editor.baseline.revision)
        let latest = try #require(try await session.pricingProfiles().profiles.first)
        editor.compare(value: PricingProfileInputs(latest), revision: PricingModels.profileRevision(latest))
        #expect(editor.inputs.name == "My unsaved model" && editor.baseline.value.name == initial.name && editor.dirty)
        await #expect(throws: PricingFailure.stale) {
            try await session.updatePricingProfile("save", id: initial.id, profile: editor.inputs.validated(), revision: editor.baseline.revision)
        }
        editor.acceptLatest(useSaved: false)
        #expect(editor.inputs.name == "My unsaved model" && editor.baseline.value.name == latest.name && editor.comparison == nil && editor.dirty)
        #expect(try await session.pricingProfiles().profiles.first?.name == "Saved elsewhere")
        try await session.updatePricingProfile("save", id: initial.id, profile: editor.inputs.validated(), revision: editor.baseline.revision)
        let saved = try #require(try await session.pricingProfiles().profiles.first)
        editor.compare(value: PricingProfileInputs(saved), revision: PricingModels.profileRevision(saved))
        editor.acceptLatest(useSaved: true)
        #expect(!editor.dirty && editor.inputs.name == "My unsaved model")
    }

    @Test func profilesAndDefaultSelectionRequireTheStartingRevision() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try #require(try await session.pricingProfiles().profiles.first), revision = PricingModels.profileRevision(initial)
        try await session.updatePricingProfile("duplicate", id: initial.id, revision: revision)
        let copy = try #require(try await session.pricingProfiles().profiles.first { $0.id != initial.id })
        try await session.updatePricingProfile("default", id: copy.id, revision: PricingModels.profileRevision(copy), expectedDefault: initial.id)
        await #expect(throws: PricingFailure.stale) { try await session.updatePricingProfile("delete", id: initial.id, revision: revision, expectedDefault: initial.id) }
        await #expect(throws: PricingFailure.stale) { try await session.updatePricingProfile("default", id: initial.id, revision: revision, expectedDefault: initial.id) }
        await #expect(throws: PricingFailure.invalid("Choose another default profile before deleting this one.")) {
            try await session.updatePricingProfile("delete", id: copy.id, revision: PricingModels.profileRevision(copy), expectedDefault: copy.id)
        }
        try await session.updatePricingProfile("delete", id: initial.id, revision: revision, expectedDefault: copy.id)
        #expect(try await session.pricingProfiles().profiles.map(\.id) == [copy.id])
    }

    @Test func incompleteOverridesAndUnicodeNamesAreValidatedWithoutDroppingInputs() throws {
        let profile = PricingProfile(id: "standard", name: "Standard", guideTerritory: "USA", rounding: "nearest", method: "custom", percentages: [:])
        var inputs = PricingProfileInputs(profile)
        inputs.overrides = [.init(territory: " swe ", percentage: "85.50"), .init(territory: "SWE", percentage: "90")]
        #expect(throws: PricingFailure.self) { try inputs.validated() }
        inputs.overrides.removeLast(); inputs.overrides[0].percentage = "-"
        #expect(throws: PricingFailure.self) { try inputs.validated() }
        #expect(inputs.overrides[0].percentage == "-")
        inputs.overrides[0].percentage = "85.50"; inputs.name = "\u{feff}Synthetic model\u{feff}"; inputs.guideTerritory = "\u{feff}usa\u{feff}"
        #expect(try inputs.validated().name == "Synthetic model" && inputs.validated().percentages == ["SWE": 85.5])
        inputs.name = String(repeating: "😀", count: 41)
        #expect(throws: PricingFailure.self) { try inputs.validated() }
        var composed = profile, decomposed = profile; composed.name = "é"; decomposed.name = "e\u{301}"
        #expect(composed != decomposed && PricingProfileInputs(composed) != PricingProfileInputs(decomposed))
    }
}
