import Foundation
import Testing
@testable import StorebenchCore

/// While a new version is prepared, App Store Connect keeps the live App Information beside an editable one, each with the same
/// languages. Storebench works with the editable one, so its languages show once and are compared once.
@Suite(.serialized) struct AppInfoChoiceTests {
    init() throws { _ = try TestIsolation.require() }

    private func info(_ id: String, state: String) -> JSONText {
        .object([("id", .string(id)), ("fields", .object([("appStoreState", .string(state)), ("state", .string(state))])),
                 ("localizations", .array([.object([("id", .string(id + "-en")), ("fields", .object([("locale", .string("en-US")), ("privacyPolicyUrl", .string("https://example.com/privacy"))]))])]))])
    }

    @Test func theRecordBeingPreparedIsTheOneUsed() {
        let records = [info("live", state: "READY_FOR_DISTRIBUTION"), info("next", state: "PREPARE_FOR_SUBMISSION")]
        #expect(AppInfoChoice.current(records).compactMap { $0["id"]?.text } == ["next"])
        // In review beside the live record, the one in review is current.
        #expect(AppInfoChoice.current([info("live", state: "READY_FOR_DISTRIBUTION"), info("review", state: "IN_REVIEW")]).compactMap { $0["id"]?.text } == ["review"])
        // A single record is always used, whatever its state.
        #expect(AppInfoChoice.current([info("only", state: "READY_FOR_DISTRIBUTION")]).compactMap { $0["id"]?.text } == ["only"])
    }

    @Test func aRevisionShowsEachLanguagesAppInformationOnce() throws {
        let json = JSONText.object([("schemaVersion", .number(1)), ("id", .string("synthetic-import")), ("importedAt", .string("2026-11-16T19:05:00.000Z")),
            ("app", .object([("id", .string("1000000001")), ("name", .string("Synthetic App")), ("bundleId", .string("com.example.synthetic")), ("sku", .string("synthetic")), ("primaryLocale", .string("en-US"))])),
            ("appInfos", .array([info("live", state: "READY_FOR_DISTRIBUTION"), info("next", state: "PREPARE_FOR_SUBMISSION")])), ("versions", .array([]))])
        let revision = try JSONDecoder().decode(Revision.self, from: json.data)
        #expect(revision.appInfos.count == 2)
        #expect(revision.currentAppInfos.map(\.id) == ["next"])
        #expect(revision.currentAppInfos.flatMap(\.localizations).filter { $0.fields["locale"]?.text == "en-US" }.count == 1)
    }

    /// The language editor shows a language's app information once, and a change goes to every record of the language,
    /// since they are saved and synced together.
    @Test func theEditorShowsAppInformationOnceAndChangesItEverywhere() throws {
        func section(_ id: String, _ scope: TextDrafts.Scope) -> LanguageDrafts.Section {
            let values = Dictionary(uniqueKeysWithValues: TextDrafts.fields(scope).map { ($0, $0 == "privacyPolicyUrl" ? "https://example.com/privacy" : "") })
            return .init(selection: .init(id: id, scope: scope), imported: values, draft: TextDraft(fields: values, fingerprint: String(repeating: "a", count: 64), edited: false))
        }
        var editor = try LanguageEditorState([section("synthetic-version-en", .version), section("synthetic-live-en", .appInfo), section("synthetic-next-en", .appInfo)])
        let shown = editor.shownFields.filter { $0.key == "privacyPolicyUrl" }
        #expect(shown.count == 1 && editor.fields.filter { $0.key == "privacyPolicyUrl" }.count == 2)
        try editor.changeShown(try #require(shown.first), to: "https://example.com/new-privacy")
        #expect(editor.fields.filter { $0.key == "privacyPolicyUrl" }.allSatisfy { editor.value($0) == "https://example.com/new-privacy" })
        #expect(try editor.entries().count == 2, "Both records are saved together")
    }

    /// The editor drafts both records of a language, and publishing sends the draft of the record Apple lets you edit, once.
    @Test func publishingSendsOneAppInformationDraftPerLanguage() throws {
        let records = [info("live", state: "READY_FOR_DISTRIBUTION"), info("next", state: "PREPARE_FOR_SUBMISSION")]
        let edits = records.flatMap { WorkspaceSession.items($0["localizations"]) }
        let same = JSONText.object([("live-en", .object([("privacyPolicyUrl", .string("https://example.com/new"))])), ("next-en", .object([("privacyPolicyUrl", .string("https://example.com/new"))]))])
        #expect(try WorkspaceSession.appInfoDrafts(edits, records: records, editable: "next", drafts: same).compactMap { $0["id"]?.text } == ["next-en"])
        // The editable record's draft wins even when an older draft of the live record differs.
        let differing = JSONText.object([("live-en", .object([("privacyPolicyUrl", .string("https://example.com/old"))])), ("next-en", .object([("privacyPolicyUrl", .string("https://example.com/new"))]))])
        #expect(try WorkspaceSession.appInfoDrafts(edits, records: records, editable: "next", drafts: differing).compactMap { $0["id"]?.text } == ["next-en"])
        // Two records Apple does not let you edit are sent once when their drafts agree, and refused when they differ.
        #expect(try WorkspaceSession.appInfoDrafts(edits, records: records, editable: "other", drafts: same).count == 1)
        #expect(throws: PublishFailure.self) { try WorkspaceSession.appInfoDrafts(edits, records: records, editable: "other", drafts: differing) }
    }
}
