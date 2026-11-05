import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct DraftTests {
    init() throws { _ = try TestIsolation.require() }
    func session(directory: URL? = nil) throws -> (WorkspaceSession, URL) {
        let runRoot = try TestIsolation.require()
        let root = directory ?? runRoot.appendingPathComponent("storebench-drafts-\(UUID().uuidString)")
        try TestIsolation.check(root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: try SyntheticFixtures.database(), to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = #"{\"schemaVersion\":1,\"phase\":\"ready\",\"envelope\":{\"version\":1,\"mode\":\"device\",\"key\":\"\#(key)\"}}"#
        let vault = try CredentialVault(json: Data(#"{"version":1,"entries":{"\#(CredentialVault.databaseEntry(root: root))":"\#(record)"}}"#.utf8))
        return (try WorkspaceSession(workspace: Workspace(root: root), vault: vault), root)
    }

    @Test func textDraftsSaveOnTheLoadedVersionOnly() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let revision = "00000000-0000-4000-8000-000000000002"
        let loaded = try await session.textDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version)
        #expect(!loaded.edited && loaded.fields["description"] == "Second synthetic description" && loaded.fields["keywords"] == "sample,test" && loaded.fields["whatsNew"] == "")
        // The fingerprint of "nothing saved yet" is SHA-256 of `null`.
        #expect(loaded.fingerprint == "74234e98afe7498fb5daf1f36ac2d78acc339464f950703b8c019892f982b90b")

        var fields = loaded.fields; fields["promotionalText"] = "Synthetic promotion ✨"
        let saved = try await session.saveTextDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: loaded.fingerprint)
        let reloaded = try await session.textDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version)
        #expect(reloaded.edited && reloaded.fingerprint == saved && reloaded.fields["promotionalText"] == "Synthetic promotion ✨")

        await #expect(throws: DraftFailure.stale) {
            try await session.saveTextDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: loaded.fingerprint)
        }
        await #expect(throws: DraftFailure.invalid) {
            try await session.saveTextDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: ["name": "Not a version field"], fingerprint: saved)
        }
        let stored = try await session.storeAccess { try $0.document(namespace: "drafts", key: "\(account.id):1000000001:\(revision)") }.map { try JSONText.parse($0.payload) }
        #expect(stored?.stringify() == #"{"schemaVersion":1,"revisionId":"\#(revision)","texts":{"version-locale-1":{"description":"Second synthetic description","keywords":"sample,test","promotionalText":"Synthetic promotion ✨","whatsNew":"","supportUrl":"","marketingUrl":""}},"screenshotLayouts":{},"uploads":{}}"#)
        #expect(TextDrafts.used("keywords", "å,b") == 4 && TextDrafts.used("name", "å🎉") == 2)
    }

    @Test func addedLanguagesCopyTextAndShowInTheWorkspace() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let revision = "00000000-0000-4000-8000-000000000002"
        let id = try await session.addLanguage(accountId: account.id, appId: "1000000001", revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: "en-US")
        #expect(id.hasPrefix("local-locale-"))
        await #expect(throws: LanguageFailure.exists) { try await session.addLanguage(accountId: account.id, appId: "1000000001", revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: nil) }
        await #expect(throws: LanguageFailure.unknownLanguage) { try await session.addLanguage(accountId: account.id, appId: "1000000001", revisionId: revision, versionId: "version-1", locale: "xx", copyFrom: nil) }

        let source = try #require(try await session.revisions(accountId: account.id, appId: "1000000001").first { $0.id == revision })
        let workspace = try await session.workspaceRevision(source, accountId: account.id, appId: "1000000001")
        let swedish = try #require(workspace.versions.first?.localizations.first { $0.locale == "sv" })
        #expect(swedish.id == id && swedish.screenshotSets.map(\.displayType) == ["APP_IPHONE_67"])
        #expect(workspace.appInfos.last?.localizations.first?.id == "local-app-info-sv")

        let copied = try await session.textDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: id, scope: .version)
        #expect(copied.edited && copied.fields["description"] == "Second synthetic description")
        let name = try await session.textDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "local-app-info-sv", scope: .appInfo)
        #expect(name.fields["subtitle"] == "Sample subtitle")

        var fields = copied.fields; fields["description"] = "Svensk syntetisk beskrivning"
        try await session.saveTextDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: id, scope: .version, fields: fields, fingerprint: copied.fingerprint)
        let draft = try await session.storeAccess { try $0.document(namespace: "drafts", key: "\(account.id):1000000001:\(revision)") }.map { try JSONText.parse($0.payload) }
        guard case .object(let markers)? = draft?["textSources"]?[id] else { Issue.record("No markers"); return }
        #expect(markers.map(\.0) == ["keywords"])
        #expect(draft?["textSources"]?[id]?["keywords"]?.stringify() == #"{"revisionId":"\#(revision)","localizationId":"version-locale-1","copiedValue":"sample,test","reviewedValue":"sample,test"}"#)
    }
}
