import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct CopiedTextTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func comparisonAndAcknowledgementMatchWebAndPreserveDestination() throws {
        let vector = try ReleaseTextTests().fixture(), source = try JSONDecoder().decode(Revision.self, from: #require(vector["source"]).data)
        let draft = try #require(vector["copiedDraft"])
        let review = try #require(CopiedText.review(source: source, draft: draft, scope: .version, versionId: "version-1", targetId: "synthetic-fr-FR", field: "whatsNew"))
        #expect(review.needsReview && review.canAcknowledge)
        #expect(review.targetValue == vector["copiedReview"]?["targetValue"]?.text && review.sourceValue == vector["copiedReview"]?["sourceValue"]?.text)
        let saved = try CopiedText.acknowledge(source: source, draft: draft, expected: review)
        #expect(saved.data == vector["acknowledged"]?.data)
        #expect(saved["texts"] == draft["texts"])
        #expect(CopiedText.review(source: source, draft: saved, scope: .version, versionId: "version-1", targetId: review.targetId, field: review.field)?.needsReview == false)
        #expect(throws: CopiedTextFailure.stale) { try CopiedText.acknowledge(source: source, draft: saved, expected: review) }
    }
    @Test func changedSourceDestinationMarkerAndMissingSourceCannotBeAcknowledged() throws {
        let vector = try ReleaseTextTests().fixture(), source = try JSONDecoder().decode(Revision.self, from: #require(vector["source"]).data)
        let draft = try #require(vector["copiedDraft"])
        let review = try #require(CopiedText.review(source: source, draft: draft, scope: .version, versionId: "version-1", targetId: "synthetic-fr-FR", field: "whatsNew"))
        let texts = try #require(draft["texts"])
        for (id, value) in [("version-locale-1", "Newest synthetic source"), (review.targetId, "New synthetic destination")] {
            let changed = draft.setting("texts", texts.setting(id, (texts[id] ?? .object([])).setting("whatsNew", .string(value))))
            #expect(throws: CopiedTextFailure.stale) { try CopiedText.acknowledge(source: source, draft: changed, expected: review) }
        }
        let sources = try #require(draft["textSources"]), fields = try #require(sources[review.targetId]), marker = try #require(fields[review.field])
        for (field, value) in [("copiedValue", "Different synthetic copy"), ("reviewedValue", "Different synthetic review"), ("localizationId", "synthetic-missing-source"), ("revisionId", "00000000-0000-4000-8000-000000000099")] {
            let changed = draft.setting("textSources", sources.setting(review.targetId, fields.setting(review.field, marker.setting(field, .string(value)))))
            #expect(throws: CopiedTextFailure.stale) { try CopiedText.acknowledge(source: source, draft: changed, expected: review) }
            if field == "localizationId" || field == "revisionId" {
                let unavailable = try #require(CopiedText.review(source: source, draft: changed, scope: .version, versionId: "version-1", targetId: review.targetId, field: review.field))
                #expect(unavailable.needsReview && !unavailable.canAcknowledge)
            }
        }
    }
    @Test func appInformationSourcesAndIndividualFieldsAreReviewedIndependently() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = "synthetic-account", app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
        _ = try await session.addLanguage(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: "en-US")
        let reviews = try await session.copiedTextReviews(accountId: account, appId: app, revisionId: revision, localizationId: "local-app-info-sv", scope: .appInfo)
        let initial = try #require(reviews["name"])
        #expect(!initial.needsReview)
        let saved = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: initial.marker.localizationId, scope: .appInfo)
        var fields = saved.fields; fields["name"] = "Synthetic revised title"
        try await session.saveTextDraft(accountId: account, appId: app, revisionId: revision, localizationId: initial.marker.localizationId, scope: .appInfo, fields: fields, fingerprint: saved.fingerprint)
        let changed = try await session.copiedTextReviews(accountId: account, appId: app, revisionId: revision, localizationId: initial.targetId, scope: .appInfo)
        let review = try #require(changed["name"])
        #expect(review.needsReview && changed["subtitle"]?.needsReview == false)
        let before = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: review.targetId, scope: .appInfo)
        try await session.acknowledgeCopiedText(accountId: account, appId: app, revisionId: revision, review: review)
        #expect(try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: review.targetId, scope: .appInfo) == before)
        await #expect(throws: CopiedTextFailure.stale) { try await session.acknowledgeCopiedText(accountId: account, appId: app, revisionId: revision, review: review) }
    }
}
