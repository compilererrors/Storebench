import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReleaseTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func continuingAVersionFillsOnlyFieldsAppleLeftEmpty() throws {
        func version(_ id: String, _ number: String, _ fields: [String: String]) -> String {
            let text = fields.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", ")
            return #"{"id": "\#(id)", "fields": {"platform": "MAC_OS", "versionString": "\#(number)"}, "localizations": [{"id": "\#(id)-en", "fields": {"locale": "en-US", \#(text)}, "screenshotSets": []}]}"#
        }
        let json = #"{"schemaVersion": 1, "id": "synthetic-revision", "importedAt": "2026-01-01T00:00:00.000Z", "app": {"id": "1000000001", "name": "Synthetic", "bundleId": "", "sku": "", "primaryLocale": "en-US"}, "appInfos": [], "versions": ["#
            + [version("v16", "1.6", ["promotionalText": "Older promotion", "description": "Older"]), version("v17", "1.7", ["promotionalText": "Synthetic promotion", "description": "Synthetic", "whatsNew": "Earlier notes"]),
               version("v18", "1.8", ["promotionalText": "", "description": "Kept", "whatsNew": ""])].joined(separator: ", ") + "]}"
        let revision = try JSONDecoder().decode(Revision.self, from: Data(json.utf8))
        let draft = WorkspaceSession.carriedText([revision], revisionId: "synthetic-revision", versionId: "v18")
        #expect(draft["texts"] == .object([("v18-en", .object([("promotionalText", .string("Synthetic promotion"))]))]))
        #expect(WorkspaceSession.carriedText([revision], revisionId: "synthetic-revision", versionId: "v16")["texts"] == .object([]))
        #expect(Releases.earlier("1.9", "1.10") && !Releases.earlier("1.10", "1.9"))
    }
    @Test func newVersionPlansStartEmptyOrAsACopy() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001"
        #expect(await session.newVersionAvailability(accountId: account.id, appId: app) == .available(submittedDraft: nil))
        await #expect(throws: ReleaseFailure.invalid("That version number already exists in an import. Enter a new version number.")) {
            try await session.saveReleasePlan(account: account, appId: app, start: .empty(platform: "IOS", locale: "en-US"), sourceRevisionId: nil, baseVersionId: nil, targetVersion: "1.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        }
        let plan = try await session.saveReleasePlan(account: account, appId: app, start: .empty(platform: "IOS", locale: "en-US"), sourceRevisionId: nil, baseVersionId: nil,
                                                     targetVersion: " 2.0 ", releaseType: "SCHEDULED", earliestReleaseDate: Date(timeIntervalSince1970: 2_000_000_000.123), expected: "null", now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(plan.targetVersion == "2.0" && plan.earliestReleaseDate == "2033-05-18T03:33:20.123Z" && plan.label == "iOS 2.0")
        #expect(await session.newVersionAvailability(accountId: account.id, appId: app) == .unavailable(draft: "iOS 2.0"))
        let local = try #require(try await session.revisions(accountId: account.id, appId: app).first { $0.id == plan.sourceRevisionId })
        #expect(local.isLocalDraft && local.versions.first?.localizations.first?.screenshotSets.first?.displayType == "APP_IPHONE_67")
        await #expect(throws: ReleaseFailure.self) {
            try await session.saveReleasePlan(account: account, appId: app, start: .empty(platform: "IOS", locale: "en-US"), sourceRevisionId: nil, baseVersionId: nil, targetVersion: "3.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        }
        _ = try await session.addScreenshots(accountId: account.id, appId: app, revisionId: plan.sourceRevisionId, localizationId: "local-locale-\(plan.sourceRevisionId)", setId: nil, files: [("shot.png", syntheticPNG(width: 1290, height: 2796, seed: 5))])
        let text = try await session.textDraft(accountId: account.id, appId: app, revisionId: plan.sourceRevisionId, localizationId: "local-locale-\(plan.sourceRevisionId)", scope: .version)
        var fields = text.fields; fields["description"] = "Synthetic local description"; fields["whatsNew"] = "Synthetic previous release notes"; fields["promotionalText"] = "Synthetic promotion"
        try await session.saveTextDraft(accountId: account.id, appId: app, revisionId: plan.sourceRevisionId, localizationId: "local-locale-\(plan.sourceRevisionId)", scope: .version, fields: fields, fingerprint: text.fingerprint)
        try await session.removeReleasePlan(accountId: account.id, appId: app, expected: plan.token)
        #expect(try await session.releasePlan(accountId: account.id, appId: app) == nil)

        let copy = try await session.saveReleasePlan(account: account, appId: app, start: .copy, sourceRevisionId: plan.sourceRevisionId, baseVersionId: plan.baseVersionId,
                                                     targetVersion: "2.1", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        #expect(copy.sourceRevisionId != plan.sourceRevisionId && copy.baseVersionId == "local-version-\(copy.sourceRevisionId)")
        let copied = try #require(try await session.revisions(accountId: account.id, appId: app).first { $0.id == copy.sourceRevisionId })
        #expect(copied.versions.first?.number == "2.1" && copied.versions.first?.localizations.first?.screenshotSets.first?.screenshots.first?.fileName == "shot.png")
        let copiedText = try await session.textDraft(accountId: account.id, appId: app, revisionId: copy.sourceRevisionId, localizationId: "local-locale-\(plan.sourceRevisionId)", scope: .version)
        #expect(copiedText.fields["description"] == "Synthetic local description")
        #expect(copiedText.fields["whatsNew"] == "" && copiedText.fields["promotionalText"] == "Synthetic promotion")
        #expect(copied.versions.first?.localizations.first?.fields["whatsNew"]?.text == "")
        #expect(try await session.textDraft(accountId: account.id, appId: app, revisionId: plan.sourceRevisionId, localizationId: "local-locale-\(plan.sourceRevisionId)", scope: .version).fields["whatsNew"] == "Synthetic previous release notes")
        let same = try await session.saveReleasePlan(account: account, appId: app, start: .reuse, sourceRevisionId: copy.sourceRevisionId, baseVersionId: copy.baseVersionId,
                                                     targetVersion: "2.1", releaseType: "MANUAL", earliestReleaseDate: nil, expected: copy.token)
        #expect(same == copy)
    }
}
