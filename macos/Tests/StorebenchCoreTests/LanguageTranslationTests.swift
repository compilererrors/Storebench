import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct LanguageTranslationTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"

    /// A synthetic translator that marks each text so the result can be traced back to its source.
    static func translate(_ texts: [String]) -> [String] { texts.map { "sv " + $0 } }

    @Test func requestsTranslateKeywordsTermByTermAndKeepEmptyFields() throws {
        let request = LanguageTranslation.Request(sourceLocale: "en-US", version: ["description": "Synthetic text", "keywords": "alpha, beta,,gamma", "promotionalText": " ", "whatsNew": ""],
                                                  appInfo: ["subtitle": "Synthetic subtitle", "privacyPolicyText": ""])
        #expect(request.segments == ["Synthetic text", "alpha", "beta", "gamma", "Synthetic subtitle"])
        let translation = try request.translation(["Syntetisk text", "alfa", "be,ta", "gamma ", "Syntetisk undertitel"])
        #expect(translation.version["keywords"] == .init(source: "alpha, beta,,gamma", text: "alfa,be ta,gamma"))
        #expect(translation.version["promotionalText"] == .init(source: " ", text: " ") && translation.version["whatsNew"] == .init(source: "", text: ""))
        #expect(translation.appInfo["subtitle"]?.text == "Syntetisk undertitel" && translation.appInfo["privacyPolicyText"]?.text == "")
        #expect(throws: LanguageFailure.translationFailed) { try request.translation(["Too few"]) }
        #expect(throws: LanguageFailure.translationFailed) { try request.translation(["", "a", "b", "c", "d"]) }
    }

    @Test func translatedLanguageKeepsNameAndLinksAndMarksTranslatedFields() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first).id
        let request = try await session.translationRequest(accountId: account, appId: app, revisionId: revision, versionId: "version-1", sourceLocale: "en-US")
        let translation = try request.translation(Self.translate(request.segments))
        let id = try await session.addLanguage(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: "en-US", translation: translation)

        let source = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version)
        let text = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: id, scope: .version)
        #expect(text.fields["description"] == "sv Second synthetic description" && text.fields["keywords"] == "sv sample,sv test")
        #expect(text.fields["supportUrl"] == source.fields["supportUrl"] && text.fields["marketingUrl"] == source.fields["marketingUrl"])
        let info = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: "local-app-info-sv", scope: .appInfo)
        let sourceInfoId = try #require(try await session.copiedTextReviews(accountId: account, appId: app, revisionId: revision, localizationId: "local-app-info-sv", scope: .appInfo)["name"]).marker.localizationId
        let sourceInfo = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: sourceInfoId, scope: .appInfo)
        #expect(info.fields["subtitle"] == "sv Sample subtitle" && info.fields["name"] == sourceInfo.fields["name"])

        let reviews = try await session.copiedTextReviews(accountId: account, appId: app, revisionId: revision, localizationId: id, scope: .version)
        let keywords = try #require(reviews["keywords"])
        #expect(keywords.marker.translated && !keywords.needsReview && keywords.marker.copiedValue == "sv sample,sv test" && keywords.marker.reviewedValue == "sample,test")
        let names = try await session.copiedTextReviews(accountId: account, appId: app, revisionId: revision, localizationId: "local-app-info-sv", scope: .appInfo)
        #expect(names["subtitle"]?.marker.translated == true && names["name"]?.marker.translated == false)

        var fields = source.fields; fields["keywords"] = "sample,changed"
        try await session.saveTextDraft(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: source.fingerprint)
        let changed = try await session.copiedTextReviews(accountId: account, appId: app, revisionId: revision, localizationId: id, scope: .version)
        #expect(changed["keywords"]?.needsReview == true)
    }

    @Test func sourceChangedWhileTranslatingAddsNothing() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first).id
        let request = try await session.translationRequest(accountId: account, appId: app, revisionId: revision, versionId: "version-1", sourceLocale: "en-US")
        let translation = try request.translation(Self.translate(request.segments))
        let source = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version)
        var fields = source.fields; fields["description"] = "Newer synthetic description"
        try await session.saveTextDraft(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: source.fingerprint)

        await #expect(throws: LanguageFailure.sourceChanged) {
            try await session.addLanguage(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: "en-US", translation: translation)
        }
        await #expect(throws: LanguageFailure.sourceChanged) {
            try await session.addLanguage(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: "en-GB", translation: translation)
        }
        let stored = try await session.storeAccess { try $0.document(namespace: "drafts", key: "\(account):\(app):\(revision)") }.map { try JSONText.parse($0.payload) }
        let added = WorkspaceSession.items(stored?["addedLocalizations"])
        #expect(added.isEmpty)
    }

    @Test func oversizedTranslationAddsNothingAndKeepsOtherLanguagesReadable() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first).id
        let request = try await session.translationRequest(accountId: account, appId: app, revisionId: revision, versionId: "version-1", sourceLocale: "en-US")
        // Each emoji is two UTF-16 units, so these texts sit exactly at and one unit past the stored limit.
        let fits = String(repeating: "😀", count: TextDrafts.storedLimit / 2), over = fits + "x"
        func translated(_ description: String) throws -> LanguageTranslation {
            try request.translation(request.segments.map { $0 == request.version["description"] ? description : "sv " + $0 })
        }
        await #expect(throws: LanguageFailure.translationTooLong(field: "description")) {
            try await session.addLanguage(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: "en-US", translation: try translated(over))
        }
        let stored = try await session.storeAccess { try $0.document(namespace: "drafts", key: "\(account):\(app):\(revision)") }.map { try JSONText.parse($0.payload) }
        let added = WorkspaceSession.items(stored?["addedLocalizations"])
        #expect(added.isEmpty)
        let source = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version)
        #expect(source.fields["description"] == request.version["description"])
        #expect(LanguageFailure.translationTooLong(field: "description").message.hasPrefix("The translated Description is longer than 10,000 characters"))

        let id = try await session.addLanguage(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: "en-US", translation: try translated(fits))
        let text = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: id, scope: .version)
        #expect(text.fields["description"] == fits)
        let sections = try await session.languageTextDrafts(accountId: account, appId: app, revisionId: revision, selections: [.init(id: "version-locale-1", scope: .version), .init(id: id, scope: .version)])
        #expect(sections.count == 2)
    }
}
