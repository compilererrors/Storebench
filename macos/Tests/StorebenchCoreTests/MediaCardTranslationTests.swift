import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct MediaCardTranslationTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"

    func source() -> MediaCardSet {
        var set = MediaCardSet(name: "Synthetic launch", target: MediaCards.defaultTarget)
        set.language = "en-US"
        set.cards[0].title = "Synthetic title"; set.cards[0].body = "Synthetic body"
        set.cards[0].style.color = "#123456"; set.cards[0].layout = .textBelow
        var second = MediaCard(style: set.cards[0].style); second.subtitle = "Synthetic subtitle"; second.title = "  "
        set.cards.append(second); set.savedCards = set.cards
        return set
    }

    @Test func translatedSetKeepsLookAndReplacesOnlyText() throws {
        let set = source()
        #expect(MediaCardTranslation.segments(set) == ["Synthetic title", "Synthetic body", "Synthetic subtitle"])
        let copy = try MediaCardTranslation.translated(set, to: "sv", translations: ["Syntetisk rubrik ", "Syntetisk text", "Syntetisk underrubrik"])
        #expect(copy.id != set.id && copy.name == "Synthetic launch · Swedish" && copy.language == "sv" && copy.savedCards == nil)
        #expect(copy.displayType == set.displayType && copy.width == set.width && copy.height == set.height)
        #expect(copy.cards.map(\.title) == ["Syntetisk rubrik", "  "] && copy.cards.map(\.subtitle) == ["", "Syntetisk underrubrik"] && copy.cards[0].body == "Syntetisk text")
        #expect(copy.cards.map(\.style) == set.cards.map(\.style) && copy.cards.map(\.layout) == set.cards.map(\.layout))
        #expect(Set(copy.cards.map(\.id)).isDisjoint(with: set.cards.map(\.id)))
    }

    @Test func translationsThatDoNotFitOrDoNotMatchAreRefused() throws {
        let set = source()
        #expect(throws: MediaCardFailure.translation) { try MediaCardTranslation.translated(set, to: "sv", translations: ["Too few"]) }
        #expect(throws: MediaCardFailure.translation) { try MediaCardTranslation.translated(set, to: "sv", translations: ["", "b", "c"]) }
        #expect(throws: MediaCardFailure.translationLength) {
            try MediaCardTranslation.translated(set, to: "sv", translations: [String(repeating: "a", count: MediaCards.titleLimit + 1), "b", "c"])
        }
        #expect(throws: MediaCardFailure.invalid) { try MediaCardTranslation.translated(set, to: "en-US", translations: ["a", "b", "c"]) }
        #expect(throws: MediaCardFailure.invalid) { try MediaCardTranslation.translated(set, to: "xx", translations: ["a", "b", "c"]) }
        let long = String(repeating: "n", count: MediaCards.nameLimit)
        let name = MediaCardTranslation.name(long, language: "pt-BR")
        #expect(name.utf16.count <= MediaCards.nameLimit && name.hasSuffix(" · Brazilian Portuguese"))
    }

    @Test func languageIsSavedAndSetsWithoutOneStillOpen() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first).id
        var plain = MediaCardSet(name: "Synthetic plain", target: MediaCards.defaultTarget); plain.cards[0].title = "Synthetic title"
        #expect(!String(decoding: try WorkspaceSession.encodeMediaCardSet(plain), as: UTF8.self).contains("language"))
        _ = try await session.saveMediaCardSet(accountId: account, appId: app, set: plain, expected: 0)
        let copy = try MediaCardTranslation.translated(source(), to: "de-DE", translations: ["a", "b", "c"])
        _ = try await session.saveMediaCardSet(accountId: account, appId: app, set: copy, expected: 0)
        let loaded = try await session.mediaCardSets(accountId: account, appId: app)
        #expect(loaded.first { $0.set.id == plain.id }?.set.language == nil && loaded.first { $0.set.id == copy.id }?.set.language == "de-DE")
        var unknown = plain; unknown.language = "xx"
        #expect(throws: MediaCardFailure.invalid) { try MediaCards.validate(unknown) }
    }
}
