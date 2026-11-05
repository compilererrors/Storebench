import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct LanguageDraftTests {
    init() throws { _ = try TestIsolation.require() }
    private let revisionId = "00000000-0000-4000-8000-000000000002"
    private func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/language-draft.json"))) }
    private func entries(_ value: JSONText) throws -> [LanguageDrafts.Entry] {
        guard case .array(let rows) = value else { throw DraftFailure.invalid }
        return try rows.map { row in
            guard let id = row["id"]?.text, let scopeName = row["scope"]?.text, let scope = TextDrafts.Scope(rawValue: scopeName),
                  let fields = TextDrafts.strings(row["fields"]), let fingerprint = row["fingerprint"]?.text else { throw DraftFailure.invalid }
            return .init(id: id, scope: scope, fields: fields, fingerprint: fingerprint)
        }
    }
    @Test func completeJoinedSavesAndReadsMatchActualPrimaryContracts() throws {
        let fixture = try fixture()
        guard case .array(let cases)? = fixture["cases"], case .array(let reads)? = fixture["readCases"] else { throw DraftFailure.invalid }
        #expect(cases.count >= 25 && reads.count == 5)
        for row in cases {
            let source = try #require(row["source"]), draft = try #require(row["draft"]), rawEntries = try #require(row["entries"])
            if let expected = row["expected"] {
                let result = try LanguageDrafts.saving(source: source, draft: draft, entries: entries(rawEntries))
                #expect(result.draft == expected["draft"])
                #expect(result.fingerprints == TextDrafts.strings(expected["fingerprints"]))
            } else {
                let expected: DraftFailure = row["error"]?.text == "stale" ? .stale : .invalid
                #expect(throws: expected) { try LanguageDrafts.saving(source: source, draft: draft, entries: entries(rawEntries)) }
            }
        }
        for row in reads {
            let source = try #require(row["source"]), draft = try #require(row["draft"])
            guard case .array(let expected)? = row["sections"] else { throw DraftFailure.invalid }
            let selections = try expected.map { item -> LanguageDrafts.Selection in
                let id = try #require(item["id"]?.text), rawScope = try #require(item["scope"]?.text)
                let scope = try #require(TextDrafts.Scope(rawValue: rawScope))
                return .init(id: id, scope: scope)
            }
            let result = try LanguageDrafts.sections(source: source, draft: draft, selections: selections)
            #expect(JSONText.array(result.map(\.json)) == .array(expected))
        }
    }
    private func selections() -> [LanguageDrafts.Selection] { [.init(id: "info-locale-1", scope: .appInfo), .init(id: "version-locale-1", scope: .version)] }
    private func changed(_ sections: [LanguageDrafts.Section], suffix: String) -> [LanguageDrafts.Entry] {
        sections.map { section in
            var fields = section.draft.fields
            fields[section.selection.scope == .appInfo ? "subtitle" : "description"] = "Synthetic joined " + suffix
            return .init(id: section.selection.id, scope: section.selection.scope, fields: fields, fingerprint: section.draft.fingerprint)
        }
    }
    @Test func scopedJoinedSaveKeepsBothEditorsOnStaleAndSurvivesReopen() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let initial = try await session.languageTextDrafts(accountId: account.id, appId: "1000000001", revisionId: revisionId, selections: selections())
        let edits = changed(initial, suffix: "first"), receipt = try await session.saveLanguageDraft(accountId: account.id, appId: "1000000001", revisionId: revisionId, entries: edits)
        #expect(receipt.count == 2 && receipt.allSatisfy { $0.value.count == 64 })
        let latest = try await session.languageTextDrafts(accountId: account.id, appId: "1000000001", revisionId: revisionId, selections: selections())
        #expect(latest.allSatisfy { $0.draft.edited })
        for section in latest { #expect(section.draft.fields == edits.first(where: { $0.selection.id == section.selection.id })?.fields) }
        let another = changed(latest, suffix: "must not partly save")
        for batch in [[another[0], edits[1]], [edits[1], another[0]]] {
            await #expect(throws: DraftFailure.stale) { try await session.saveLanguageDraft(accountId: account.id, appId: "1000000001", revisionId: revisionId, entries: batch) }
        }
        let unchanged = try await session.languageTextDrafts(accountId: account.id, appId: "1000000001", revisionId: revisionId, selections: selections())
        #expect(unchanged.map(\.json) == latest.map(\.json))
        _ = session.lifetime.beginClosing()
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record: [String: Any] = ["schemaVersion": 1, "phase": "ready", "envelope": ["version": 1, "mode": "device", "key": key]]
        let recordText = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        let vault = try CredentialVault(json: JSONSerialization.data(withJSONObject: ["version": 1, "entries": [CredentialVault.databaseEntry(root: root): recordText]]))
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: vault)
        let read = try await reopened.languageTextDrafts(accountId: account.id, appId: "1000000001", revisionId: revisionId, selections: selections())
        #expect(read.map(\.json) == latest.map(\.json))
    }
    @Test func twoIndependentSessionsRejectOneConcurrentJoinedSave() async throws {
        let (first, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await first.accounts().first)
        let sections = try await first.languageTextDrafts(accountId: account.id, appId: "1000000001", revisionId: revisionId, selections: selections())
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record: [String: Any] = ["schemaVersion": 1, "phase": "ready", "envelope": ["version": 1, "mode": "device", "key": key]]
        let recordText = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        let vault = try CredentialVault(json: JSONSerialization.data(withJSONObject: ["version": 1, "entries": [CredentialVault.databaseEntry(root: root): recordText]]))
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: vault)
        let left = changed(sections, suffix: "A"), right = changed(sections, suffix: "B")
        func save(_ session: WorkspaceSession, _ entries: [LanguageDrafts.Entry]) async -> Bool {
            do { _ = try await session.saveLanguageDraft(accountId: account.id, appId: "1000000001", revisionId: revisionId, entries: entries); return true }
            catch DraftFailure.stale { return false }
            catch { Issue.record("Unexpected synthetic concurrent-save failure"); return false }
        }
        async let a = save(first, left), b = save(second, right)
        let results = await [a, b]; #expect(results.filter { $0 }.count == 1)
        let current = try await first.languageTextDrafts(accountId: account.id, appId: "1000000001", revisionId: revisionId, selections: selections())
        let winner = results[0] ? left : right
        for section in current { #expect(section.draft.fields == winner.first(where: { $0.selection.id == section.selection.id })?.fields) }
    }
    @Test func foreignClosedCanceledAndOversizedBatchesNeverCommit() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let sections = try await session.languageTextDrafts(accountId: "synthetic-account", appId: "1000000001", revisionId: revisionId, selections: selections())
        let edits = changed(sections, suffix: "guarded")
        await #expect(throws: RevisionHistoryFailure.invalid) { try await session.saveLanguageDraft(accountId: "synthetic-foreign", appId: "1000000001", revisionId: revisionId, entries: edits) }
        await #expect(throws: RevisionHistoryFailure.invalid) { try await session.saveLanguageDraft(accountId: "synthetic-account", appId: "9999999999", revisionId: revisionId, entries: edits) }
        let canceled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await session.saveLanguageDraft(accountId: "synthetic-account", appId: "1000000001", revisionId: revisionId, entries: edits) }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        let largeFields = Dictionary(uniqueKeysWithValues: TextDrafts.versionFields.map { ($0, String(repeating: "x", count: 10_000)) })
        let tooLarge = (0..<20).map { LanguageDrafts.Entry(id: "synthetic-large-\($0)", scope: .version, fields: largeFields, fingerprint: TextDrafts.fingerprint(nil)) }
        await #expect(throws: DraftFailure.tooLarge) { try await session.saveLanguageDraft(accountId: "synthetic-account", appId: "1000000001", revisionId: revisionId, entries: tooLarge) }
        let key = "synthetic-account:1000000001:\(revisionId)"
        let saved = try await session.storeAccess { try $0.document(namespace: "drafts", key: key) }
        #expect(saved == nil)
        _ = session.lifetime.beginClosing()
        await #expect(throws: SessionFailure.closed) { try await session.saveLanguageDraft(accountId: "synthetic-account", appId: "1000000001", revisionId: revisionId, entries: edits) }
        await #expect(throws: SessionFailure.closed) { try await session.languageTextDrafts(accountId: "synthetic-account", appId: "1000000001", revisionId: revisionId, selections: selections()) }
    }
    @Test func sourceRevisionChangedDuringSyntheticMutationRejectsTheWholeDraft() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let key = "synthetic-account:1000000001:\(revisionId)"
        let original = try #require(try await session.storeAccess { try $0.document(namespace: "revisions", key: key) })
        await #expect(throws: DraftFailure.stale) {
            try await session.syntheticSourceChangeBeforeDraftCommit(revisionId: revisionId)
        }
        let draft = try await session.storeAccess { try $0.document(namespace: "drafts", key: key) }
        let current = try await session.storeAccess { try $0.document(namespace: "revisions", key: key) }
        #expect(draft == nil && current?.revision != original.revision)
    }
}

extension WorkspaceSession {
    /// A separate owned connection simulates an interrupted source writer, within this actor's isolation.
    fileprivate func syntheticSourceChangeBeforeDraftCommit(revisionId: String) throws {
        try TestIsolation.check(root)
        let other = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let key = try TextDrafts.key(accountId: "synthetic-account", appId: "1000000001", revisionId: revisionId)
        _ = try mutateDraft(accountId: "synthetic-account", appId: "1000000001", revisionId: revisionId) { draft, source in
            guard let app = source["app"] else { throw DraftFailure.invalid }
            let changed = source.setting("app", app.setting("name", .string("Synthetic changed source")))
            try other.transaction { _ in [.put(namespace: "revisions", key: key, json: changed.data)] }
            return (draft.setting("texts", .object([])), true)
        }
    }
}
