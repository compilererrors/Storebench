import Foundation
import Testing
@testable import StorebenchCore

struct GuideFlowTests {
    init() throws { _ = try TestIsolation.require() }

    private func build(_ id: String, uploaded: String, processing: String = "VALID", encryption: Bool? = false, external: String? = nil) -> TestFlightBuild {
        TestFlightBuild(id: id, version: "1", platform: "IOS", appVersion: "1.0", processingState: processing, uploadedDate: uploaded, expirationDate: "", audience: "APP_STORE_ELIGIBLE",
                        expired: false, usesNonExemptEncryption: encryption, externalState: external, internalState: nil, betaReviewState: nil)
    }
    private func group(_ id: String, isInternal: Bool, link: Bool = false) -> TestFlightGroup {
        TestFlightGroup(id: id, name: "Synthetic \(id)", internalGroup: isInternal, feedbackEnabled: true, publicLinkEnabled: link, hasAccessToAllBuilds: false, publicLink: nil)
    }
    private var review: ReviewInformation {
        var value = ReviewInformation(); value.contactFirstName = "Synthetic"; value.contactLastName = "Tester"; value.contactPhone = "+1 555 0100"; value.contactEmail = "tester@example.com"; return value
    }

    @Test func startTestingOpensOnTheFirstMissingStepAndFollowsTheLatestProcessedBuild() {
        var facts = TestFlightFlow.Facts()
        #expect(TestFlightFlow.steps(facts).first { $0.current }?.id == .build)
        facts.builds = [build("old", uploaded: "2026-10-01"), build("new", uploaded: "2026-10-20", encryption: nil), build("busy", uploaded: "2026-10-30", processing: "PROCESSING")]
        #expect(facts.build?.id == "new")
        let steps = TestFlightFlow.steps(facts)
        #expect(steps.first { $0.id == .build }?.done == true)
        #expect(steps.first { $0.current }?.id == .compliance)
        #expect(steps.filter(\.current).count == 1)
    }

    @Test func startTestingIsDoneForInternalTestersWithoutBetaAppReview() {
        let facts = TestFlightFlow.Facts(builds: [build("b", uploaded: "2026-10-20")], groups: [group("team", isInternal: true)],
                                         members: ["team": .init(builds: ["b"], testers: 2)],
                                         localizations: [TestFlightLocalization(locale: "en-US", description: "Synthetic", feedbackEmail: "beta@example.com")], review: review)
        let steps = TestFlightFlow.steps(facts)
        #expect(steps.filter { $0.id != .betaReview }.allSatisfy { $0.done })
        #expect(steps.first { $0.id == .betaReview }?.optional == true)
        #expect(!steps.contains { $0.current })
    }

    @Test func aPartThatCouldNotBeReadMarksOnlyItsStepWithTheReason() async throws {
        var facts = TestFlightFlow.Facts(builds: [build("b", uploaded: "2026-10-20")], groups: [group("team", isInternal: true)],
                                         members: ["team": .init(builds: ["b"], testers: 2)], review: review)
        facts.unread[.information] = ProductPricing.readProblem(AppStoreConnectClient.Failure.status(500), reading: "the Test Information")
        let steps = TestFlightFlow.steps(facts)
        #expect(steps.first { $0.id == .information }?.needed == ["App Store Connect had a temporary problem (error 500) while reading the Test Information. Refresh to try again."])
        #expect(steps.first { $0.current }?.id == .information)
        let others = steps.filter { [.build, .compliance, .group, .testers].contains($0.id) }
        #expect(others.count == 4 && others.allSatisfy { $0.done })
        let failed = try await WorkspaceSession.part { () async throws -> Int in throw AppStoreConnectClient.Failure.status(403) }
        #expect(throws: AppStoreConnectClient.Failure.status(403)) { try failed.get() }
        await #expect(throws: CancellationError.self) { _ = try await WorkspaceSession.part { () async throws -> Int in throw CancellationError() } }
    }

    @Test func externalGroupsNeedBetaAppReviewAndPlainNeededText() {
        let facts = TestFlightFlow.Facts(builds: [build("b", uploaded: "2026-10-20", external: "READY_FOR_BETA_SUBMISSION")], groups: [group("public", isInternal: false, link: true)],
                                         members: ["public": .init(builds: ["b"], testers: 0)], localizations: [], review: nil)
        let steps = TestFlightFlow.steps(facts)
        #expect(steps.first { $0.id == .testers }?.done == true)
        #expect(steps.first { $0.id == .information }?.needed.contains("Feedback Email") == true)
        let beta = steps.first { $0.id == .betaReview }
        #expect(beta?.optional == false && beta?.done == false && beta?.needed.first?.hasPrefix("Submit") == true)
    }

    @Test func createMediaChecksEachCardAndAsksToSaveAgainAfterChanges() throws {
        #expect(CreateMediaFlow.steps(nil).first { $0.current }?.id == .cardSet)
        var set = MediaCardSet(name: "Synthetic", target: MediaCards.defaultTarget)
        #expect(CreateMediaFlow.steps(set).first { $0.current }?.id == .screenshots)
        set.cards[0].screenshot = .init(hash: "synthetic", name: "one.png", width: 1320, height: 2868)
        set.cards[0].title = "Synthetic title"
        #expect(CreateMediaFlow.steps(set).first { $0.current }?.id == .save)
        set.savedCards = set.cards
        #expect(CreateMediaFlow.steps(set).first { $0.current }?.id == .release)
        set.cards[0].title = "Changed"
        #expect(CreateMediaFlow.needed(.save, set: set).first?.hasPrefix("Cards changed") == true)
        let decoded = try JSONDecoder().decode(MediaCardSet.self, from: JSONEncoder().encode(MediaCardSet(name: "Older", target: MediaCards.defaultTarget)))
        #expect(decoded.savedCards == nil)
    }

    @Test func setUpReportsKeepsEveryStepOnceDone() {
        let done = [SyncItem(key: "sales", state: .synced, detail: "Synthetic", checkedAt: "2026-10-19T08:00:00.000Z", code: nil)]
        #expect(SyncSetupGuide.steps(done) == nil)
        #expect(SyncSetupGuide.progress(done).map(\.id) == ["reports", "analytics", "fiscal", "sync"])
        #expect(SyncSetupGuide.progress(done).allSatisfy { $0.state == .done })
    }
}
