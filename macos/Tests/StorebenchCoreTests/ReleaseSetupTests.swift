import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReleaseSetupTests {
    init() throws { _ = try TestIsolation.require() }

    private func revision(_ id: String, importedAt: String, local: Bool = false, versions: [(id: String, platform: String, number: String, state: String, release: String)]) throws -> Revision {
        let items = versions.map { #"{"id":"\#($0.id)","fields":{"platform":"\#($0.platform)","versionString":"\#($0.number)","appVersionState":"\#($0.state)","releaseType":"\#($0.release)"},"localizations":[]}"# }
        let json = #"{"schemaVersion":1,\#(local ? #""origin":"local","# : "")"id":"\#(id)","importedAt":"\#(importedAt)","app":{"id":"1000000001","name":"Synthetic App","bundleId":"com.example.synthetic","sku":"synthetic","primaryLocale":"en-US"},"appInfos":[],"versions":[\#(items.joined(separator: ","))]}"#
        return try JSONDecoder().decode(Revision.self, from: Data(json.utf8))
    }
    private let date = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func aVersionInPreparationIsContinuedWithItsOwnNumberAndReleaseMethod() throws {
        let history = [try revision("import-2", importedAt: "2026-10-10T20:33:50.902Z", versions: [("v2", "MAC_OS", "1.0", "PREPARE_FOR_SUBMISSION", "AFTER_APPROVAL")])]
        let inputs = ReleaseSetup.suggestion(history, date: date)
        #expect(inputs.start == .reuse && inputs.sourceRevisionId == "import-2" && inputs.baseVersionId == "v2")
        #expect(inputs.targetVersion == "1.0" && inputs.releaseType == "AFTER_APPROVAL")
    }

    @Test func aReleasedVersionIsCopiedIntoTheNextFreeNumber() throws {
        let history = [try revision("import-3", importedAt: "2026-10-12T08:00:00.000Z", versions: [("v3", "IOS", "1.1", "READY_FOR_DISTRIBUTION", "MANUAL"), ("v1", "IOS", "1.2", "REJECTED_BY_ROBOT", "MANUAL")])]
        let inputs = ReleaseSetup.suggestion(history, date: date)
        #expect(inputs.start == .copy && inputs.baseVersionId == "v3" && inputs.targetVersion == "1.3")
    }

    @Test func anAppWithNothingSavedStartsItsFirstVersion() {
        let inputs = ReleaseSetup.suggestion([], date: date)
        #expect(inputs.start == .empty(platform: "IOS", locale: "en-US") && inputs.targetVersion == "1.0")
    }

    @Test func olderPreparationStatesNeverOverrideTheNewestImportAndCopyUsesTheHighestReleasedVersion() throws {
        let old = try revision("import-old", importedAt: "2026-01-01T00:00:00.000Z", versions: [("v1", "IOS", "1.0", "PREPARE_FOR_SUBMISSION", "MANUAL")])
        let latest = try revision("import-latest", importedAt: "2026-02-01T00:00:00.000Z", versions: [
            ("v1", "IOS", "1.0", "REPLACED_WITH_NEW_VERSION", "MANUAL"), ("v2", "IOS", "2.0", "READY_FOR_DISTRIBUTION", "MANUAL")])
        let input = ReleaseSetup.suggestion([old, latest], date: date)
        #expect(input.start == .copy && input.sourceRevisionId == latest.id && input.baseVersionId == "v2" && input.targetVersion == "2.1")
    }

    @Test func nextNumbersSkipTakenOnesAndKeepTheirShape() {
        #expect(ReleaseSetup.nextNumber(after: "1.0", taken: []) == "1.1")
        #expect(ReleaseSetup.nextNumber(after: "1.0", taken: ["1.1", "1.2"]) == "1.3")
        #expect(ReleaseSetup.nextNumber(after: "2.3.4", taken: []) == "2.3.5")
        #expect(ReleaseSetup.nextNumber(after: "3", taken: []) == "3.1")
        #expect(ReleaseSetup.nextNumber(after: "0.9", taken: [], firstVersion: true) == "1.0")
        #expect(ReleaseSetup.nextNumber(after: "0.9", taken: ["1.0"], firstVersion: true) == "1.1")
        #expect(ReleaseSetup.nextNumber(after: "1.0", taken: ["1.0", "2.4"]) == "2.5")
        #expect(ReleaseSetup.nextNumber(after: "beta", taken: []) == "1.0")
    }

    @Test func candidatesShowVersionStateAndAReadableImportDate() throws {
        let history = [try revision("import-2", importedAt: "2026-10-10T20:33:50.902Z", versions: [("v2", "MAC_OS", "1.0", "PREPARE_FOR_SUBMISSION", "MANUAL")]),
                       try revision("draft-1", importedAt: "2026-10-11T09:00:00.000Z", local: true, versions: [("local-version-draft-1", "MAC_OS", "1.1", "", "MANUAL")])]
        let candidates = ReleaseSetup.candidates(history)
        #expect(candidates.map(\.version.id) == ["v2", "local-version-draft-1"])
        #expect(candidates[0].inProgress && !candidates[1].inProgress)
        let text = ReleaseSetup.describe(candidates[0], locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(text.hasPrefix("macOS 1.0 · Prepare for Submission · imported Oct 10, 2026"))
        #expect(!text.contains("T20:33:50"))
        #expect(ReleaseSetup.describe(candidates[1], locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!).hasPrefix("macOS 1.1 · local draft · saved "))
    }

    @Test func continuingAnImportedVersionKeepsItsNumber() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001"
        let imported = try #require(try await session.revisions(accountId: account.id, appId: app).first { !$0.isLocalDraft && $0.versions.contains { $0.id == "version-1" } })
        let number = try #require(imported.versions.first { $0.id == "version-1" }?.number)
        let plan = try await session.saveReleasePlan(account: account, appId: app, start: .reuse, sourceRevisionId: imported.id, baseVersionId: "version-1",
                                                     targetVersion: number, releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        #expect(plan.targetVersion == number && plan.baseVersionId == "version-1")
    }
}
