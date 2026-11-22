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

    /// Quick Release prepares new versions: one already submitted or in review is the base of the next number, never reopened.
    @Test func quickReleaseStartsTheNextVersionAfterASubmittedOne() throws {
        for state in ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "READY_FOR_DISTRIBUTION"] {
            let history = [try revision("import-4", importedAt: "2026-11-16T19:05:00.000Z", versions: [("v27", "MAC_OS", "2.7", state, "AFTER_APPROVAL")])]
            let quick = ReleaseSetup.quickSuggestion(history, date: date)
            #expect(quick.start == .copy && quick.baseVersionId == "v27" && quick.targetVersion == "2.8" && quick.releaseType == "AFTER_APPROVAL", "\(state): \(quick)")
        }
        // Release itself keeps following a version in review until it is out.
        let inReview = [try revision("import-4", importedAt: "2026-11-16T19:05:00.000Z", versions: [("v27", "MAC_OS", "2.7", "IN_REVIEW", "MANUAL")])]
        #expect(ReleaseSetup.suggestion(inReview, date: date).start == .reuse)
    }

    /// When the last import is older than a version Apple released since, that version's number is never suggested again:
    /// a plan that released 1.10 from a 1.9 import suggests 1.11, and an imported 1.10 still being prepared is not reopened.
    @Test func quickReleaseSkipsNumbersAppleAlreadyHas() throws {
        let older = [try revision("import-6", importedAt: "2026-11-10T08:00:00.000Z", versions: [("v19", "MAC_OS", "1.9", "READY_FOR_DISTRIBUTION", "MANUAL")])]
        #expect(ReleaseSetup.quickSuggestion(older, date: date).targetVersion == "1.10")
        let quick = ReleaseSetup.quickSuggestion(older, date: date, known: ["1.10"])
        #expect(quick.start == .copy && quick.targetVersion == "1.11", "\(quick)")
        let preparing = [try revision("import-7", importedAt: "2026-11-10T08:00:00.000Z", versions: [("v110", "MAC_OS", "1.10", "PREPARE_FOR_SUBMISSION", "MANUAL"), ("v19", "MAC_OS", "1.9", "READY_FOR_DISTRIBUTION", "MANUAL")])]
        let next = ReleaseSetup.quickSuggestion(preparing, date: date, known: ["1.10"])
        #expect(next.start == .copy && next.targetVersion == "1.11", "\(next)")
    }

    /// Apple's saved version numbers number a copy past a release the last import doesn't have yet, without stopping Quick Release
    /// from continuing a version Apple is still preparing.
    @Test func applesSavedNumbersNumberACopyButKeepAVersionInPreparation() throws {
        let older = [try revision("import-9", importedAt: "2026-11-10T08:00:00.000Z", versions: [("v19", "MAC_OS", "1.9", "READY_FOR_DISTRIBUTION", "MANUAL")])]
        #expect(ReleaseSetup.quickSuggestion(older, date: date, apple: ["MAC_OS": ["1.9", "1.10"]]).targetVersion == "1.11")
        #expect(ReleaseSetup.quickSuggestion(older, date: date, apple: ["IOS": ["1.10"]]).targetVersion == "1.10", "Another platform's numbers don't count")
        let preparing = [try revision("import-10", importedAt: "2026-11-10T08:00:00.000Z", versions: [("v111", "MAC_OS", "1.11", "PREPARE_FOR_SUBMISSION", "MANUAL"), ("v110", "MAC_OS", "1.10", "READY_FOR_DISTRIBUTION", "MANUAL")])]
        let quick = ReleaseSetup.quickSuggestion(preparing, date: date, apple: ["MAC_OS": ["1.10", "1.11"]])
        #expect(quick.start == .reuse && quick.targetVersion == "1.11", "\(quick)")
    }

    /// A new release starts from the saved import at once while it matches Apple's version list; a new version, number or state
    /// at Apple means a fresh download first.
    @Test func theSavedImportIsUsedWhileItMatchesApplesVersions() throws {
        let saved = try revision("import-8", importedAt: "2026-11-10T08:00:00.000Z", versions: [("v110", "MAC_OS", "1.10", "READY_FOR_DISTRIBUTION", "MANUAL"), ("v19", "MAC_OS", "1.9", "REPLACED_WITH_NEW_VERSION", "MANUAL")]).versions
        let apple = [PublishingWorkspace.Version(id: "v110", platform: "MAC_OS", number: "1.10", state: "READY_FOR_DISTRIBUTION"),
                     PublishingWorkspace.Version(id: "v19", platform: "MAC_OS", number: "1.9", state: "REPLACED_WITH_NEW_VERSION")]
        #expect(WorkspaceSession.sameVersions(saved, apple))
        #expect(!WorkspaceSession.sameVersions(saved, apple + [.init(id: "v111", platform: "MAC_OS", number: "1.11", state: "PREPARE_FOR_SUBMISSION")]), "A new version at Apple")
        #expect(!WorkspaceSession.sameVersions(saved, [.init(id: "v110", platform: "MAC_OS", number: "1.10", state: "READY_FOR_SALE"), apple[1]]), "A changed state")
        #expect(!WorkspaceSession.sameVersions(saved, [apple[0]]), "A version Apple no longer lists")
    }

    @Test func quickReleaseContinuesAVersionAppleStillLetsYouEdit() throws {
        let history = [try revision("import-5", importedAt: "2026-11-16T19:05:00.000Z", versions: [("v28", "MAC_OS", "2.8", "PREPARE_FOR_SUBMISSION", "MANUAL"), ("v27", "MAC_OS", "2.7", "READY_FOR_DISTRIBUTION", "MANUAL")])]
        let quick = ReleaseSetup.quickSuggestion(history, date: date)
        #expect(quick.start == .reuse && quick.baseVersionId == "v28" && quick.targetVersion == "2.8")
    }

    @Test func anAppWithNothingSavedStartsItsFirstVersion() {
        let inputs = ReleaseSetup.suggestion([], date: date)
        #expect(inputs.start == .empty(platform: "IOS", locale: "en-US") && inputs.targetVersion == "1.0")
    }

    @Test func firstVersionsRemainAvailableAcrossEveryAppStoreConnectStage() throws {
        let states = ["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "READY_FOR_DISTRIBUTION", "REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED", "PROCESSING_FOR_APP_STORE", "SYNTHETIC_FUTURE_STATE"]
        for (index, state) in states.enumerated() {
            let saved = try revision("synthetic-\(index)", importedAt: "2026-03-01T00:00:00.000Z", versions: [("synthetic-first", "MAC_OS", "1.0", state, "MANUAL")])
            #expect(ReleaseSetup.candidates([saved]).map(\.version.id) == ["synthetic-first"])
            if try #require(ReleaseSetup.candidates([saved]).first).canContinue {
                let next = ReleaseSetup.suggestion([saved], date: date)
                #expect(next.start == .reuse && next.targetVersion == "1.0")
            }
        }
    }

    @Test func aFirstVersionWaitingForManualReleaseKeepsItsOwnPlan() throws {
        let saved = try revision("synthetic-first", importedAt: "2026-03-01T00:00:00.000Z", versions: [("synthetic-first-version", "MAC_OS", "1.0", "PENDING_DEVELOPER_RELEASE", "MANUAL")])
        let next = ReleaseSetup.suggestion([saved], date: date)
        #expect(next.start == .reuse && next.baseVersionId == "synthetic-first-version" && next.targetVersion == "1.0")
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
