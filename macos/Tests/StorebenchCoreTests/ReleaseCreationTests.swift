import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReleaseCreationTests {
    init() throws { _ = try TestIsolation.require() }
    private func version(_ number: String, _ state: String, platform: String = "IOS") -> PublishingWorkspace.Version {
        .init(id: "synthetic-" + platform + "-" + number, platform: platform, number: number, state: state)
    }
    @Test func onlyTheLatestVersionOnTheSelectedPlatformBlocksCreation() {
        let old = version("1.9", "REJECTED"), live = version("1.10", "READY_FOR_DISTRIBUTION")
        #expect(ReleaseCreation.blocker(platform: "IOS", number: "1.11", versions: [old, live]) == nil)
        let pending = version("1.11", "WAITING_FOR_REVIEW")
        let blocker = ReleaseCreation.blocker(platform: "IOS", number: "1.12", versions: [live, pending])
        #expect(blocker?.version.id == pending.id && blocker?.detail.contains("Waiting for Review") == true)
        #expect(ReleaseCreation.blocker(platform: "IOS", number: "1.11", versions: [live, pending]) == nil)
        #expect(ReleaseCreation.blocker(platform: "MAC_OS", number: "1.0", versions: [pending]) == nil)
        #expect(ReleaseCreation.blocker(platform: "IOS", number: "1.0", versions: []) == nil)
        #expect(ReleaseCreation.blocker(platform: "IOS", number: "1.8", versions: [live]) != nil)
        #expect(ReleaseCreation.blocker(platform: "IOS", number: "1.12", versions: [version("1.11", "")]) != nil)
    }
    @Test func openVersionNamesItsPlatformAndKnownFailuresHaveSpecificGuidance() {
        #expect(ReleaseCreation.versionURL(appId: "1000000001", platform: "MAC_OS")?.path == "/apps/1000000001/distribution/macos/version/inflight")
        #expect(ReleaseCreation.versionURL(appId: "../1000000001", platform: "IOS") == nil)
        #expect(ReleaseCreation.versionURL(appId: "1000000001", platform: "UNKNOWN") == nil)
        let problem = AppleProblem(code: "ENTITY_ERROR.RELATIONSHIP.INVALID", resource: "appStoreVersions", field: "app", detail: "Synthetic version cannot be created.")
        #expect(problem.area == .version)
        #expect(PublishFailure.refused("Synthetic refusal", problems: [problem]).recoveryCode == "SB-PUBLISH-REFUSED")
        #expect(PublishFailure.versionRequired.recoveryCode == "SB-PUBLISH-REQUIREMENTS")
        #expect(PublishFailure.conflict.recoveryCode == "SB-PUBLISH-REVIEW")
        let request = PublishRequest(accountId: "synthetic-account", appId: "1000000001", scope: .release)
        #expect(ReleaseWizard.destination(stepId: "version", target: .publishing(request)) == .phase("plan", .plan))
        #expect(PublishingReviewPresentation.recoveryTarget(.version) == .open(.release, anchor: "release-version"))
    }
    @Test(arguments: ["PREPARE_FOR_SUBMISSION", "WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "REJECTED"])
    func anExistingVersionStopsPreparationBeforeAnyWrite(_ state: String) async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "blocked-release.appstoreconnect.test"
        apple.setVersionState(state); StubProtocol.handle(host) { apple.handle($0) }
        _ = try await session.saveReleasePlan(account: account, appId: "1000000001", start: .empty(platform: "IOS", locale: "en-US"), sourceRevisionId: nil, baseVersionId: nil, targetVersion: "2.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        let client = try PublishingTests().client(account, host: host)
        do {
            _ = try await session.preparePublishing(account: account, request: .init(accountId: account.id, appId: "1000000001", scope: .release), client: client)
            Issue.record("The existing version must be resolved before creation can be reviewed.")
        } catch PublishFailure.refused(let detail, let problems) {
            #expect(detail.contains(AppStoreNames.state(state)) && problems.first?.area == .version)
        }
        #expect(apple.writes.isEmpty)
        #expect(try await session.publishHistory(accountId: account.id, appId: "1000000001").isEmpty)
    }
    @Test func aVersionThatChangesAfterApprovalWasPreparedCannotBeCreatedOrReplayed() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "changed-release.appstoreconnect.test"
        apple.setVersionState("READY_FOR_DISTRIBUTION"); StubProtocol.handle(host) { apple.handle($0) }
        _ = try await session.saveReleasePlan(account: account, appId: "1000000001", start: .empty(platform: "IOS", locale: "en-US"), sourceRevisionId: nil, baseVersionId: nil, targetVersion: "2.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        let client = try PublishingTests().client(account, host: host)
        let review = try await session.preparePublishing(account: account, request: .init(accountId: account.id, appId: "1000000001", scope: .release), client: client)
        apple.setVersionState("WAITING_FOR_REVIEW")
        await #expect(throws: PublishFailure.self) { try await session.approvePublishing(account: account, appId: "1000000001", id: review.id, fingerprint: review.fingerprint, client: client) }
        let stopped = try await session.publishReview(accountId: account.id, appId: "1000000001", id: review.id)
        #expect(stopped.state == "conflict" && stopped.errorCode == "SB-PUBLISH-REFUSED" && stopped.approvedAt == nil)
        #expect(stopped.problems.first?.area == .version && apple.writes.isEmpty)
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: "1000000001", id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(apple.writes.isEmpty)
    }
}
