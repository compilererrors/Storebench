import Foundation

/// A card on the way to another language could not be made.
public struct MediaCardLanguageFailure: Error, Sendable, Equatable {
    public let set: String, card: Int?, reason: String
    public var message: String { card.map { "\(set), card \($0 + 1): \(reason)" } ?? "\(set): \(reason)" }
}

extension WorkspaceSession {
    /// A card set translated for one language: saved on this Mac, its PNGs saved to Asset Library, ready for that language's screenshots.
    public struct TranslatedCards: Sendable {
        public let set: MediaCardSet
        public let files: [(name: String, data: Data)]
    }

    /// Card sets whose text is written in `locale`, for a listing's screenshots. Sets made before a language was chosen count as English (U.S.).
    /// Card sets whose text can be translated from `locale`: those written in it, and those made before a set recorded its
    /// language, which can be translated from whichever language is chosen.
    public func cardSets(accountId: String, appId: String, writtenIn locale: String) throws -> [SavedMediaCardSet] {
        try mediaCardSets(accountId: accountId, appId: appId).filter { ($0.set.language == nil || $0.set.language == locale) && !MediaCardTranslation.segments($0.set).isEmpty }
    }
    /// How many translatable card sets are written in each recorded language, so a step can name the language to translate from.
    public func cardSetLanguages(accountId: String, appId: String) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for saved in try mediaCardSets(accountId: accountId, appId: appId) where !MediaCardTranslation.segments(saved.set).isEmpty {
            if let language = saved.set.language { counts[language, default: 0] += 1 }
        }
        return counts
    }

    /// Translates one card set into `target` and renders its cards. The source set is never changed; an earlier translation of it
    /// into the same language is updated rather than copied again. Every card is rendered before anything is saved, so a card
    /// whose translated text does not fit leaves the earlier translation and Asset Library as they were.
    public func translateCardSet(accountId: String, appId: String, sourceId: String, target: String,
                                 translate: @Sendable (_ texts: [String], _ fields: [String]) async throws -> [String]) async throws -> TranslatedCards {
        let saved = try mediaCardSets(accountId: accountId, appId: appId)
        guard let source = saved.first(where: { $0.set.id == sourceId })?.set else { throw MediaCardFailure.missing }
        let texts = MediaCardTranslation.segments(source)
        let translations = texts.isEmpty ? [] : try await translate(texts, MediaCardTranslation.translationFields(source))
        var copy = try MediaCardTranslation.translated(source, to: target, translations: translations)
        let earlier = saved.first { $0.set.translatedFrom == source.id && $0.set.language == target && $0.set.displayType == source.displayType }
        if let earlier {
            copy.id = earlier.set.id
            // The same card keeps its identity, so an unchanged card finds its earlier Asset Library file instead of adding a copy.
            if earlier.set.cards.count == copy.cards.count { for index in copy.cards.indices { copy.cards[index].id = earlier.set.cards[index].id } }
        }
        var files: [(name: String, data: Data)] = []
        for (index, card) in copy.cards.enumerated() {
            try Task.checkCancellation()
            do {
                var screenshot: DecodedScreenshot?
                if card.layout.usesScreenshot, let shot = card.screenshot {
                    screenshot = try await ScreenshotRenderer.loadAsync(try await mediaCardScreenshot(accountId: accountId, appId: appId, hash: shot.hash))
                }
                var font: Data?
                if card.style.typeface == .file, let file = card.style.fontFile { font = try await mediaCardFont(accountId: accountId, appId: appId, hash: file.hash) }
                let data = try await MediaCardRenderer.exportAsync(card, width: copy.width, height: copy.height, screenshot: screenshot, font: font)
                files.append((MediaCards.fileName(set: copy, index: index), data))
            } catch let failure as MediaCardFailure {
                throw MediaCardLanguageFailure(set: MediaCards.trimmed(source.name), card: index, reason: failure.message)
            }
        }
        _ = try saveMediaCardSet(accountId: accountId, appId: appId, set: copy, expected: earlier?.revision ?? 0)
        _ = try stageCreatedLibraryImages(accountId: accountId, appId: appId, setId: copy.id, images: files.enumerated().map { index, file in
            CreatedLibraryImage(sourceId: copy.cards[index].id, bytes: file.data, fileName: file.name, referenceName: "\(MediaCards.trimmed(copy.name)) \(index + 1)")
        })
        return TranslatedCards(set: copy, files: files)
    }

    /// The localization of `locale` in a version, including one added on this Mac.
    public func localizationId(accountId: String, appId: String, revisionId: String, versionId: String, locale: String) throws -> String? {
        try requireHistoryScope(accountId: accountId, appId: appId)
        let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        return try storeAccess { store in
            guard let document = try store.document(namespace: "revisions", key: key) else { throw DraftFailure.sourceMissing }
            let draft = try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) }
            let revision = Self.overlay(try JSONDecoder().decode(Revision.self, from: document.payload), draft: draft)
            return revision.versions.first { $0.id == versionId }?.localizations.first { $0.locale == locale }?.id
        }
    }
}
