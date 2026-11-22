import Foundation
import Testing
@testable import StorebenchCore

/// Translated screenshots: a card set made in Create Media is translated, rendered, saved and placed in another language.
@Suite(.serialized) struct MediaCardLanguagesTests {
    init() throws { _ = try TestIsolation.require() }
    private let app = "1000000001", revision = "00000000-0000-4000-8000-000000000002", localization = "version-locale-1"

    private func textCards(_ name: String) -> MediaCardSet {
        var set = MediaCardSet(name: name, target: MediaCards.defaultTarget); set.language = "en-US"
        set.cards[0].layout = .textOnly; set.cards[0].title = "Synthetic title"; set.cards[0].subtitle = "Synthetic subtitle"
        var second = MediaCard(); second.layout = .textOnly; second.title = "Second synthetic title"; set.cards.append(second)
        return set
    }

    @Test func aTranslatedCardSetIsSavedLinkedToItsSourceAndUpdatedTheNextTime() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first).id
        let source = textCards("Synthetic launch")
        _ = try await session.saveMediaCardSet(accountId: account, appId: app, set: source, expected: 0)
        #expect(try await session.cardSets(accountId: account, appId: app, writtenIn: "en-US").map(\.set.id) == [source.id])
        #expect(try await session.cardSets(accountId: account, appId: app, writtenIn: "sv").isEmpty)
        let libraryBefore = try await session.assetLibraryFiles(accountId: account, appId: app).count

        let first = try await session.translateCardSet(accountId: account, appId: app, sourceId: source.id, target: "sv") { texts, fields in
            #expect(fields == ["card-title", "card-subtitle", "card-title"])
            return texts.map { "Svensk " + $0.lowercased() }
        }
        #expect(first.set.language == "sv" && first.set.translatedFrom == source.id && first.set.cards[0].title == "Svensk synthetic title")
        #expect(first.files.count == 2)
        for file in first.files {
            let image = try ScreenshotSpecs.validate(file.data)
            #expect(image.contentType == "image/png" && image.width == source.width && image.height == source.height)
        }
        #expect(try await session.assetLibraryFiles(accountId: account, appId: app).count == libraryBefore + 2)

        // Translating again updates the same Swedish copy instead of adding another set.
        let second = try await session.translateCardSet(accountId: account, appId: app, sourceId: source.id, target: "sv") { texts, _ in texts.map { "Ny " + $0.lowercased() } }
        #expect(second.set.id == first.set.id && second.set.cards.map(\.id) == first.set.cards.map(\.id))
        let sets = try await session.mediaCardSets(accountId: account, appId: app)
        #expect(sets.count == 2)
        #expect(sets.first { $0.set.id == source.id }?.set == source, "The source set is never changed")
        #expect(sets.first { $0.set.id == first.set.id }?.set.cards[0].title == "Ny synthetic title")
    }

    @Test func aTranslationThatIsTooLongLeavesCardsAndAssetLibraryAsTheyWere() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first).id
        let source = textCards("Synthetic launch")
        _ = try await session.saveMediaCardSet(accountId: account, appId: app, set: source, expected: 0)
        let libraryBefore = try await session.assetLibraryFiles(accountId: account, appId: app).count
        await #expect(throws: MediaCardFailure.translationLength) {
            try await session.translateCardSet(accountId: account, appId: app, sourceId: source.id, target: "sv") { texts, _ in texts.map { _ in String(repeating: "x", count: 600) } }
        }
        #expect(try await session.mediaCardSets(accountId: account, appId: app).count == 1)
        #expect(try await session.assetLibraryFiles(accountId: account, appId: app).count == libraryBefore)
    }

    @Test func translatedCardsFillOnlyAnEmptySizeUnlessReplacingIsChosen() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first).id
        let source = textCards("Synthetic launch")
        _ = try await session.saveMediaCardSet(accountId: account, appId: app, set: source, expected: 0)
        let cards = try await session.translateCardSet(accountId: account, appId: app, sourceId: source.id, target: "sv") { texts, _ in texts.map { "Svensk " + $0 } }
        func size() async throws -> ScreenshotSetDraft {
            try #require(try await session.screenshotCatalog(accountId: account, appId: app, revisionId: revision, localizationId: localization).first { $0.displayType == source.displayType })
        }
        func shown(_ draft: ScreenshotSetDraft) -> [String] { draft.items.filter { !draft.hidden.contains($0.id) }.map(\.sha256) }

        // The size gets screenshots, then an addition that only fills empty sizes leaves it alone.
        _ = try await session.addScreenshotsWithReceipt(accountId: account, appId: app, revisionId: revision, localizationId: localization, setId: nil, files: [cards.files[0]])
        let before = try await size()
        #expect(!shown(before).isEmpty)
        await #expect(throws: ScreenshotFailure.occupied(source.displayType)) {
            try await session.addScreenshotsWithReceipt(accountId: account, appId: app, revisionId: revision, localizationId: localization, setId: nil, files: cards.files, addition: .onlyIntoEmpty)
        }
        #expect(shown(try await size()) == shown(before))

        // Replacing shows only the translated cards, in card order; the earlier screenshots stay saved, excluded.
        _ = try await session.addScreenshotsWithReceipt(accountId: account, appId: app, revisionId: revision, localizationId: localization, setId: nil, files: cards.files, addition: .replace)
        let after = try await size()
        let hashes = try cards.files.map { try ScreenshotSpecs.validate($0.data).sha256 }
        #expect(shown(after) == hashes)
        #expect(Set(before.items.map(\.id)).isSubset(of: after.hidden))
        #expect(ScreenshotFailure.occupied(source.displayType).message.contains("Replace Existing"))
    }

    @Test func cardsWithoutARecordedLanguageAreOfferedForAnySourceAndOtherLanguagesAreNamed() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first).id
        var unrecorded = textCards("Synthetic older cards"); unrecorded.language = nil
        let american = textCards("Synthetic American cards")
        _ = try await session.saveMediaCardSet(accountId: account, appId: app, set: unrecorded, expected: 0)
        _ = try await session.saveMediaCardSet(accountId: account, appId: app, set: american, expected: 0)
        // Cards made before their language was recorded can be translated from whichever language is chosen.
        #expect(try await session.cardSets(accountId: account, appId: app, writtenIn: "en-GB").map(\.set.id) == [unrecorded.id])
        #expect(Set(try await session.cardSets(accountId: account, appId: app, writtenIn: "en-US").map(\.set.id)) == [unrecorded.id, american.id])
        // Card sets in another language are named, so the step can say which language to translate from.
        #expect(try await session.cardSetLanguages(accountId: account, appId: app) == ["en-US": 1])
    }
}
