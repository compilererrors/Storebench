import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct LanguageEditorLayoutTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/language-layout.json"))) }

    @Test func allGroupsFieldsLegacyDefaultsAndValidationMatchPrimary() throws {
        let fixture = try fixture()
        #expect(LanguageEditorLayout().json == fixture["default"])
        for row in WorkspaceSession.items(fixture["groups"]) {
            let group = try #require(LanguageEditorLayout.Group(rawValue: row["id"]?.text ?? ""))
            #expect(group.title == row["title"]?.text)
            #expect(JSONText.array(group.fields.map(JSONText.string)) == row["fields"])
        }
        for row in WorkspaceSession.items(fixture["models"]) {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: LanguageEditorLayout.Failure.self) { try LanguageEditorLayout(input) } }
            else { #expect(try LanguageEditorLayout(input).json == row["expected"]) }
        }
        for row in WorkspaceSession.items(fixture["patches"]) {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: LanguageEditorLayout.Failure.self) { try LanguageEditorLayout.patch(input) } }
            else { let expected = try #require(row["expected"]); #expect(try LanguageEditorLayout.patch(input) == LanguageEditorLayout.patch(expected)) }
        }
    }

    @Test func everyPrimaryMergeMatchesEncryptedWritesAndInvalidStateIsPreserved() async throws {
        let fixture = try fixture(), (session, root) = try DraftTests().session()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), appId = "1000000001", key = "\(account.id):\(appId)"
        let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let drafts = try store.documents(namespace: "drafts")
        for row in WorkspaceSession.items(fixture["merges"]) {
            let previous = try #require(row["previous"]), rawPatch = try #require(row["patch"]), patch = try LanguageEditorLayout.patch(rawPatch)
            try store.transaction { _ in row["absent"] == .bool(true) ? [.delete(namespace: "language_editor_views", key: key)] : [.put(namespace: "language_editor_views", key: key, json: previous.data)] }
            let before = try store.document(namespace: "language_editor_views", key: key)
            if row["rejected"] == .bool(true) {
                await #expect(throws: LanguageEditorLayout.Failure.self) { try await session.saveLanguageEditorLayout(accountId: account.id, appId: appId, patch: patch) }
                #expect(try store.document(namespace: "language_editor_views", key: key) == before)
            } else {
                let receipt = try await session.saveLanguageEditorLayout(accountId: account.id, appId: appId, patch: patch)
                #expect(receipt.json == row["expected"])
                #expect(try await session.languageEditorLayout(accountId: account.id, appId: appId).json == receipt.json)
                #expect(try store.document(namespace: "language_editor_views", key: key)?.revision == (before?.revision ?? 0) + 1)
            }
        }
        #expect(try store.documents(namespace: "drafts") == drafts)
    }

    @Test func independentSessionsMergeAndPersistOnlyTheirConfiguredScope() async throws {
        let (first, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await first.vault)
        let account = try #require(try await first.accounts().first), appId = "1000000001", key = "\(account.id):\(appId)"
        async let a = first.saveLanguageEditorLayout(accountId: account.id, appId: appId, patch: [.search: false])
        async let b = second.saveLanguageEditorLayout(accountId: account.id, appId: appId, patch: [.privacy: false])
        _ = try await (a, b)
        let saved = try await first.languageEditorLayout(accountId: account.id, appId: appId)
        #expect(saved.expanded == [.copy: true, .search: false, .links: true, .privacy: false])
        #expect(try await second.languageEditorLayout(accountId: account.id, appId: "1000000002") == LanguageEditorLayout())
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: await first.vault)
        #expect(try await reopened.languageEditorLayout(accountId: account.id, appId: appId) == saved)
        await #expect(throws: RevisionHistoryFailure.self) { try await first.saveLanguageEditorLayout(accountId: "synthetic-foreign", appId: appId, patch: [.copy: false]) }
        await #expect(throws: RevisionHistoryFailure.self) { try await first.languageEditorLayout(accountId: account.id, appId: "9999999999") }
        let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let mutex = store.directory.appendingPathComponent(LanguageEditorLayout.mutex(key) + ".mutex")
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        try await first.saveLanguageEditorLayout(accountId: account.id, appId: appId, patch: [.links: false])
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.size] as? NSNumber == 0)
    }

    @MainActor @Test func pendingChangesRetainNewestValuesAfterFailureAndRejectWrongReceipts() async throws {
        let editor = LanguageLayoutEditor(); editor.loaded(LanguageEditorLayout()); editor.change([.search: false])
        var gate: CheckedContinuation<Void, Never>?, attempted: [[LanguageEditorLayout.Group: Bool]] = []
        let first = Task { await editor.flush { patch in
            attempted.append(patch)
            await withCheckedContinuation { gate = $0 }
            throw LanguageEditorLayout.Failure.invalid
        } }
        let clock = ContinuousClock(), deadline = clock.now + .seconds(2)
        while gate == nil, clock.now < deadline { await Task.yield() }
        let release = try #require(gate)
        editor.change([.search: true, .links: false]); release.resume(); await first.value
        #expect(editor.failed && !editor.saving && !editor.saved)
        #expect(editor.layout.expanded[.search] == true && editor.layout.expanded[.links] == false)
        await editor.flush { patch in attempted.append(patch); return try LanguageEditorLayout().merging(patch) }
        #expect(attempted == [[.search: false], [.search: true, .links: false]])
        #expect(editor.saved && !editor.failed)
        editor.change([.privacy: false]); await editor.flush { _ in LanguageEditorLayout() }
        #expect(editor.failed && !editor.saved && editor.layout.expanded[.privacy] == false)
        await editor.flush { try LanguageEditorLayout().merging($0) }
        #expect(editor.saved && !editor.failed)
    }

    @Test func overBudgetLocalTextSurvivesCollapsedSectionsAndStillUsesExactDraftRevision() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), appId = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
        let original = try await session.textDraft(accountId: account.id, appId: appId, revisionId: revision, localizationId: "version-locale-1", scope: .version)
        var fields = original.fields; fields["description"] = String(repeating: "x", count: 4001); fields["keywords"] = String(repeating: "å", count: 51)
        let fingerprint = try await session.saveTextDraft(accountId: account.id, appId: appId, revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: original.fingerprint)
        try await session.saveLanguageEditorLayout(accountId: account.id, appId: appId, patch: [.copy: false, .search: false])
        let loaded = try await session.textDraft(accountId: account.id, appId: appId, revisionId: revision, localizationId: "version-locale-1", scope: .version)
        #expect(TextDrafts.sameFields(loaded.fields, fields) && loaded.fingerprint == fingerprint)
        #expect(TextDrafts.used("keywords", loaded.fields["keywords"]!) == 102 && TextDrafts.used("description", loaded.fields["description"]!) == 4001)
        #expect(throws: PublishFailure.self) { try WorkspaceSession.publishedText([("description", loaded.fields["description"]!)], appInfo: false) }
        #expect(throws: PublishFailure.self) { try WorkspaceSession.publishedText([("keywords", loaded.fields["keywords"]!)], appInfo: false) }
        await #expect(throws: DraftFailure.stale) { try await session.saveTextDraft(accountId: account.id, appId: appId, revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: original.fields, fingerprint: original.fingerprint) }
        fields["description"] = String(repeating: "x", count: 10001)
        await #expect(throws: DraftFailure.invalid) { try await session.saveTextDraft(accountId: account.id, appId: appId, revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: fingerprint) }
        #expect(try await session.textDraft(accountId: account.id, appId: appId, revisionId: revision, localizationId: "version-locale-1", scope: .version).fingerprint == fingerprint)
    }
}
