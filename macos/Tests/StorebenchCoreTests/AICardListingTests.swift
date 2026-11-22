import Foundation
import Testing
@testable import StorebenchCore

/// AI cards are about this app: its own App Store text goes with the screenshots, so a set can be made without writing a brief.
@Suite(.serialized) struct AICardListingTests {
    init() throws { _ = try TestIsolation.require() }
    private let app = "1000000001"

    @Test func theAppsOwnTextGoesWithTheRequestAndMakesTheBriefOptional() throws {
        let listing = JSONText.object([("locale", .string("en-US")), ("name", .string("Synthetic Planner")), ("subtitle", .string("Synthetic plans for every day")),
                                       ("description", .string("Synthetic Planner keeps synthetic tasks in order."))])
        let image = AIImage(data: Data([1]), text: "Synthetic task list")
        let request = try AICards.request(brief: "", language: "en-US", target: MediaCards.defaultTarget, images: [image], listing: listing)
        #expect(request.input.contains("appListing") && request.input.contains("Synthetic Planner keeps synthetic tasks in order."))
        #expect(request.instructions.contains("appListing"), "The model is told the listing is this app's own text")
        // Without the app's text a brief is still needed.
        #expect(throws: AIFailure.configuration) { try AICards.request(brief: "", language: "en-US", target: MediaCards.defaultTarget, images: [image]) }
        #expect(AICards.generationIssue(name: "Synthetic", brief: "", screenshots: 1, provider: "apple", connections: [], localAvailable: true)?.contains("Describe") == true)
        #expect(AICards.generationIssue(name: "Synthetic", brief: "", screenshots: 1, provider: "apple", connections: [], localAvailable: true, usesListing: true) == nil)
    }

    @Test func theListingIsReadInTheCardLanguageOrTheClosestSavedOne() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first).id
        let english = try #require(try await session.aiCardListing(accountId: account, appId: app, language: "en-US"))
        #expect(english["locale"]?.text == "en-US")
        let fields = ["name", "subtitle", "description", "keywords", "promotionalText"].compactMap { english[$0]?.text }.filter { !$0.isEmpty }
        #expect(!fields.isEmpty, "The saved listing supplies the app's own text")
        // A card language the app has no text in uses the app's saved text in another language rather than nothing.
        let other = try #require(try await session.aiCardListing(accountId: account, appId: app, language: "ja"))
        #expect(other["locale"]?.text != nil && other["locale"]?.text != "ja")
        #expect((other["description"]?.text ?? "").utf16.count <= AICards.listingDescriptionLimit)
    }
}
