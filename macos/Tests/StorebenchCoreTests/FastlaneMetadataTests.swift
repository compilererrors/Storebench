import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct FastlaneMetadataTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture(_ name: String) throws -> Data { try Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/\(name)")) }

    @Test func archivesMatchTheWebExportAndPreserveExactText() throws {
        let vector = try JSONText.parse(fixture("fastlane.json")), archive = try fixture("fastlane.zip")
        let source = try JSONDecoder().decode(Revision.self, from: try #require(vector["source"]).data), draft = try #require(vector["draft"])
        #expect(try FastlaneMetadata.export(source: source, draft: draft, versionId: "version-1") == archive)
        let parsed = try FastlaneMetadata.parse(archive, appId: "1000000001", versionId: "version-1")
        #expect(parsed.files == 9 && parsed.ignored == 0 && parsed.omitted.isEmpty)
        #expect(JSONText.array(parsed.table.rows.map { .array($0.map(JSONText.string)) }) == vector["parsed"]?["table"]?["rows"])
        let compressed = try FastlaneMetadata.parse(fixture("fastlane-compressed.zip"), appId: "1000000001", versionId: "version-1")
        #expect(compressed.files == 3 && compressed.ignored == 1 && compressed.clears == 1 && compressed.locales == ["en-US", "sv"])
        #expect(compressed.table.rows[0][5] == "Synthetic imported description å🎉\nsecond line")
    }

    @Test func archivesRejectUnsafeDamagedAndOversizedEntries() throws {
        for value in WorkspaceSession.items(try JSONText.parse(fixture("fastlane-rejected.json"))) {
            let encoded = try #require(value.text), data = try #require(Data(base64Encoded: encoded))
            #expect(throws: TransferFailure.self) { try FastlaneMetadata.parse(data, appId: "1000000001", versionId: "version-1") }
        }
        let original = try fixture("fastlane.zip")
        #expect(throws: TransferFailure.self) { try FastlaneMetadata.parse(Data(original.dropLast()), appId: "1000000001", versionId: "version-1") }
        var changed = original; let range = try #require(changed.range(of: Data("Second synthetic description".utf8)))
        changed[range.lowerBound] ^= 1
        #expect(throws: TransferFailure.self) { try FastlaneMetadata.parse(changed, appId: "1000000001", versionId: "version-1") }
        #expect(throws: TransferFailure.self) { try FastlaneMetadata.parse(Data(repeating: 0, count: 4_000_001), appId: "1000000001", versionId: "version-1") }
    }

    @Test func importsRequireTheReviewedArchiveDraftAndReleaseSource() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
        let archive = try fixture("fastlane-compressed.zip")
        let preview = try await session.importFastlaneMetadata(account: account, appId: app, versionId: "version-1", archive: archive, revisionId: revision)
        #expect(!preview.transfer.saved && preview.transfer.added == 1)
        let before = try await session.textDraft(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version)
        #expect(before.fields["description"] == "Second synthetic description")
        let otherArchive = try fixture("fastlane.zip")
        await #expect(throws: TransferFailure.changed) { try await session.importFastlaneMetadata(account: account, appId: app, versionId: "version-1", archive: otherArchive, revisionId: revision, fingerprint: preview.transfer.fingerprint) }
        var fields = before.fields; fields["marketingUrl"] = "https://example.invalid/synthetic"
        try await session.saveTextDraft(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: before.fingerprint)
        await #expect(throws: TransferFailure.changed) { try await session.importFastlaneMetadata(account: account, appId: app, versionId: "version-1", archive: archive, revisionId: revision, fingerprint: preview.transfer.fingerprint) }
        let fresh = try await session.importFastlaneMetadata(account: account, appId: app, versionId: "version-1", archive: archive, revisionId: revision)
        let saved = try await session.importFastlaneMetadata(account: account, appId: app, versionId: "version-1", archive: archive, revisionId: revision, fingerprint: fresh.transfer.fingerprint)
        #expect(saved.transfer.saved && saved.transfer.changes == fresh.transfer.changes)
        let after = try await session.textDraft(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version)
        #expect(after.fields["description"] == "Synthetic imported description å🎉\nsecond line")
        #expect(after.fields["keywords"] == "sample,test" && after.fields["marketingUrl"] == "https://example.invalid/synthetic")
        await #expect(throws: TransferFailure.changed) { try await session.importFastlaneMetadata(account: account, appId: app, versionId: "version-1", archive: archive, revisionId: revision, fingerprint: fresh.transfer.fingerprint) }
        _ = try await session.saveReleasePlan(account: account, appId: app, start: .reuse, sourceRevisionId: revision, baseVersionId: "version-1", targetVersion: "3.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: nil)
        await #expect(throws: TransferFailure.self) { try await session.exportFastlaneMetadata(account: account, appId: app, versionId: "another-version", revisionId: revision) }
    }
}
