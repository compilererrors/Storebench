import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct TextReuseTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func plansAndWritesMatchSyntheticReferenceResults() throws {
        let file = try TestIsolation.require().appendingPathComponent("native-fixtures/text-reuse.json")
        let vector = try JSONText.parse(Data(contentsOf: file))
        let source = try JSONDecoder().decode(Revision.self, from: try #require(vector["source"]).data)
        let draft = try #require(vector["draft"])
        for item in WorkspaceSession.items(vector["vectors"]) {
            let modeName = try #require(item["mode"]?.text)
            let mode = try #require(TextReuse.Mode(rawValue: modeName))
            let selection = TextReuse.Selection(versionId: "version-1", sourceLocale: "en-US", targetLocales: ["sv"], fields: ["description", "whatsNew", "keywords", "promotionalText"], mode: mode)
            let plan = try TextReuse.plan(source: source, draft: draft, selection: selection, accountId: "synthetic-account", appId: "1000000001")
            #expect(plan.preview.fingerprint == item["fingerprint"]?.text)
            #expect(JSONText.array(plan.preview.changes.map(\.json)) == item["changes"])
            #expect(TextReuse.apply(plan, to: draft) == item["applied"])
        }
    }

    @Test func previewChangesNothingAndApplyRejectsSourceDestinationAndMarkerEdits() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = "synthetic-account", app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
        let target = try await session.addLanguage(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: nil)
        let selection = TextReuse.Selection(versionId: "version-1", sourceLocale: "en-US", targetLocales: ["sv"], fields: ["description", "keywords", "whatsNew"], mode: .empty)
        let before = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: target, scope: .version)
        let preview = try await session.previewTextReuse(accountId: account, appId: app, revisionId: revision, selection: selection)
        #expect(preview.changes.map(\.field) == ["description", "keywords"])
        #expect(try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: target, scope: .version) == before)
        let source = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version)
        var fields = source.fields; fields["description"] = "Changed synthetic source"
        try await session.saveTextDraft(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: source.fingerprint)
        await #expect(throws: TextReuseFailure.stale) { try await session.applyTextReuse(accountId: account, appId: app, revisionId: revision, selection: selection, fingerprint: preview.fingerprint) }
        let fresh = try await session.previewTextReuse(accountId: account, appId: app, revisionId: revision, selection: selection)
        var translated = before.fields; translated["description"] = "Synthetic saved translation"
        try await session.saveTextDraft(accountId: account, appId: app, revisionId: revision, localizationId: target, scope: .version, fields: translated, fingerprint: before.fingerprint)
        await #expect(throws: TextReuseFailure.stale) { try await session.applyTextReuse(accountId: account, appId: app, revisionId: revision, selection: selection, fingerprint: fresh.fingerprint) }
        let fill = try await session.previewTextReuse(accountId: account, appId: app, revisionId: revision, selection: selection)
        #expect(fill.changes.map(\.field) == ["keywords"])
        _ = try await session.applyTextReuse(accountId: account, appId: app, revisionId: revision, selection: selection, fingerprint: fill.fingerprint)
        let saved = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: target, scope: .version)
        #expect(saved.fields["description"] == "Synthetic saved translation" && saved.fields["keywords"] == "sample,test")
        await #expect(throws: TextReuseFailure.stale) { try await session.applyTextReuse(accountId: account, appId: app, revisionId: revision, selection: selection, fingerprint: fill.fingerprint) }
        let replace = TextReuse.Selection(versionId: "version-1", sourceLocale: "en-US", targetLocales: ["sv"], fields: ["description", "keywords"], mode: .replace)
        let markerPreview = try await session.previewTextReuse(accountId: account, appId: app, revisionId: revision, selection: replace)
        try await session.mutateDraft(accountId: account, appId: app, revisionId: revision) { draft, _ in
            let sources = draft["textSources"] ?? .object([])
            return (draft.setting("textSources", sources.setting(target, .object([]))), ())
        }
        await #expect(throws: TextReuseFailure.stale) { try await session.applyTextReuse(accountId: account, appId: app, revisionId: revision, selection: replace, fingerprint: markerPreview.fingerprint) }
        let invalid = TextReuse.Selection(versionId: "version-1", sourceLocale: "en-US", targetLocales: ["en-US"], fields: ["description"], mode: .replace)
        await #expect(throws: TextReuseFailure.destination) { try await session.previewTextReuse(accountId: account, appId: app, revisionId: revision, selection: invalid) }
    }
}
