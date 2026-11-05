import Foundation
import Testing
@testable import StorebenchCore

struct ReleaseGuideTests {
    init() throws { _ = try TestIsolation.require() }

    private func step(_ id: String, _ state: ReleaseReadiness.State) -> ReleaseReadiness.Step {
        .init(id: id, label: id, detail: "Synthetic detail", href: "/synthetic", action: "Open \(id)", state: state, territories: nil, guideHref: nil)
    }

    @Test func withoutAPlanOnlyThePlanCanStart() {
        let guide = ReleaseGuide.guide(nil)
        #expect(guide.phases.map(\.title) == ["New Version", "Text and Screenshots", "Save to App Store Connect", "Build", "App Review Information", "Add for Review", "App Store Version Release"])
        #expect(guide.phases.map(\.number) == Array(1...7))
        #expect(guide.current?.id == "plan" && guide.next == nil)
        #expect(guide.phases.dropFirst().allSatisfy { $0.status == .upcoming })
    }

    @Test func aNewPlanContinuesBySendingTheVersionToAppStoreConnect() {
        let guide = ReleaseGuide.guide([
            step("plan", .ready), step("version", .blocked), step("app-configuration", .review), step("age-rating", .review), step("accessibility", .review),
            step("local:en-US", .review), step("media:en-US", .unknown), step("apple-text:en-US", .unknown), step("apple-info:en-US", .unknown),
            step("copyright", .unknown), step("review-info", .unknown), step("build", .unknown), step("export-compliance", .unknown),
            step("submission", .unknown), step("release", .unknown), step("territories", .ready), step("privacy", .manual), step("tax", .manual),
        ])
        #expect(guide.next?.id == "version")
        #expect(guide.current?.id == "send")
        let status = Dictionary(uniqueKeysWithValues: guide.phases.map { ($0.id, $0.status) })
        #expect(status == ["plan": .done, "listing": .done, "send": .current, "build": .upcoming,
                           "review-information": .upcoming, "submit": .upcoming, "release": .upcoming])
        #expect(guide.completed == 2)
    }

    @Test func withNothingBlockedTheFirstOpenStepInOrderIsNextAndEarlierOnesAreDone() {
        let guide = ReleaseGuide.guide([
            step("plan", .ready), step("local:en-US", .review), step("version", .ready), step("media:en-US", .ready), step("apple-text:en-US", .ready), step("apple-info:en-US", .ready),
            step("copyright", .ready), step("build", .ready), step("export-compliance", .ready), step("review-info", .ready),
            step("submission", .review), step("app-configuration", .ready), step("territories", .ready), step("release", .unknown),
        ], appleState: "PREPARE_FOR_SUBMISSION")
        #expect(guide.current?.id == "submit" && guide.next?.id == "submission")
        #expect(guide.phases.prefix(5).allSatisfy { $0.status == .done })
        #expect(ReleaseWizard.initialPhase(guide) == "submit")
    }

    @Test func anUnsubmittedReleaseWaitsForAddForReviewAndCompleteMediaAtAppleIsDone() {
        let guide = ReleaseGuide.guide([
            step("plan", .ready), step("local:en-US", .review), step("version", .ready), step("media:en-US", .review), step("apple-text:en-US", .ready), step("apple-info:en-US", .ready),
            step("copyright", .ready), step("build", .ready), step("export-compliance", .ready), step("review-info", .ready),
            step("submission", .review), step("accessibility", .unknown), step("release", .blocked),
        ], appleState: "PREPARE_FOR_SUBMISSION")
        let status = Dictionary(uniqueKeysWithValues: guide.phases.map { ($0.id, $0.status) })
        #expect(status["send"] == .done && status["submit"] == .unknown && status["release"] == .upcoming)
        #expect(guide.current == nil && guide.next == nil)
        #expect(ReleaseWizard.initialPhase(guide) == "submit")
    }

    @Test func theFirstBlockedCheckInOrderIsNextEvenWhenLaterStepsAreAlsoBlocked() {
        let guide = ReleaseGuide.guide([step("plan", .ready), step("local:en-US", .blocked), step("local:sv", .review), step("version", .blocked), step("build", .blocked)])
        #expect(guide.next?.id == "local:en-US" && guide.current?.id == "listing")
        #expect(guide.phases.first { $0.id == "listing" }?.focus?.id == "local:en-US")
        #expect(guide.phases.first { $0.id == "send" }?.status == .upcoming && guide.phases.first { $0.id == "build" }?.status == .upcoming)
    }

    @Test func waitingAndFinishedReleasesNameNoBlockedStep() {
        let waiting = ReleaseGuide.guide([step("plan", .ready), step("version", .ready), step("build", .ready), step("review-info", .ready), step("submission", .ready), step("release", .waiting)])
        #expect(waiting.next == nil && waiting.current == nil)
        #expect(waiting.phases.first { $0.id == "release" }?.status == .waiting)
        let unknown = ReleaseGuide.guide([step("plan", .ready), step("version", .unknown)])
        #expect(unknown.phases.first { $0.id == "send" }?.status == .unknown)
    }

    /// Synthetic checks for a version Apple has already accepted for review while the draft on this Mac still differs.
    private var submittedChecks: [ReleaseReadiness.Step] {
        [step("plan", .ready), step("local:en-US", .blocked), step("version", .ready), step("apple-text:en-US", .blocked), step("media:en-US", .ready),
         step("copyright", .ready), step("build", .ready), step("export-compliance", .ready), step("review-info", .unknown),
         step("submission", .ready), step("app-configuration", .review), step("territories", .blocked), step("privacy", .manual), step("release", .waiting)]
    }

    @Test func waitingForReviewSettlesEveryStepBeforeAppReviewWithoutSavingTheLocalDraft() {
        let guide = ReleaseGuide.guide(submittedChecks, appleState: "WAITING_FOR_REVIEW")
        let status = Dictionary(uniqueKeysWithValues: guide.phases.map { ($0.id, $0.status) })
        #expect(status == ["plan": .done, "listing": .differs, "send": .differs, "build": .done,
                           "review-information": .done, "submit": .done, "release": .waiting])
        #expect(guide.phases.map(\.label) == ["Done", "Done at Apple · local draft differs", "Done at Apple · local draft differs", "Done", "Done", "Waiting for Review", "Waiting for Apple"])
        #expect(guide.phases.map(\.locked) == [true, true, true, true, true, true, false])
        #expect(guide.next == nil && guide.current == nil && guide.completed == 6)
        #expect(guide.submitted && guide.removable && guide.lockNotice?.title == "Waiting for Review at Apple")
        #expect(guide.phases.allSatisfy { ReleaseWizard.missing($0).isEmpty })
        #expect(ReleaseWizard.initialPhase(guide) == "submit")
        let review = ReleaseGuide.guide(submittedChecks, appleState: "IN_REVIEW")
        #expect(review.phases.first { $0.id == "submit" }?.label == "In Review" && review.removable)
    }

    @Test func laterAppleStatesNameTheStepTheyBelongTo() {
        let manual = submittedChecks.map { $0.id == "release" ? step("release", .review) : $0 }
        let pending = ReleaseGuide.guide(manual, appleState: "PENDING_DEVELOPER_RELEASE")
        #expect(pending.phases.first { $0.id == "submit" }?.label == "Done")
        #expect(pending.phases.first { $0.id == "release" }.map { ($0.status, $0.label, $0.locked) } ?? (.unknown, "", true) == (.current, "Pending Developer Release", false))
        #expect(!pending.removable && pending.lockNotice?.description.contains("no longer accepts") == true)
        let distributed = ReleaseGuide.guide(submittedChecks.map { $0.id == "release" ? step("release", .ready) : $0 }, appleState: "READY_FOR_DISTRIBUTION")
        #expect(distributed.phases.last.map { ($0.status, $0.label) } ?? (.unknown, "") == (.done, "Ready for Distribution"))

        let export = submittedChecks.map { $0.id == "export-compliance" ? step("export-compliance", .blocked) : $0 }
        let compliance = ReleaseGuide.guide(export, appleState: "WAITING_FOR_EXPORT_COMPLIANCE")
        #expect(compliance.next?.id == "export-compliance" && compliance.current?.id == "build")
        #expect(compliance.phases.first { $0.id == "build" }.map { ($0.label, $0.locked) } ?? ("", true) == ("Waiting for Export Compliance", false))
    }

    @Test func editableOrUnreadAppleStatesKeepTheLocalGuide() {
        for state in [nil, "", "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED"] {
            let guide = ReleaseGuide.guide(submittedChecks, appleState: state)
            #expect(guide.next?.id == "local:en-US" && guide.current?.id == "listing" && !guide.submitted && guide.lockNotice == nil)
            #expect(guide.phases.allSatisfy { !$0.locked && $0.label == $0.status.label })
        }
        #expect(AppStoreNames.state("WAITING_FOR_REVIEW") == "Waiting for Review")
    }

    @Test func automaticChecksFollowAppleWorkAndBackOffAfterFailures() {
        #expect(ReleaseStatusSync.delay(appleState: "WAITING_FOR_REVIEW", sinceWrite: nil, failures: 0) == .seconds(60))
        #expect(ReleaseStatusSync.delay(appleState: "IN_REVIEW", sinceWrite: nil, failures: 3) == .seconds(300))
        #expect(ReleaseStatusSync.delay(appleState: "DEVELOPER_REJECTED", sinceWrite: .seconds(20), failures: 0) == .seconds(10))
        #expect(ReleaseStatusSync.delay(appleState: "DEVELOPER_REJECTED", sinceWrite: .seconds(200), failures: 0) == nil)
        for state in [nil, "PREPARE_FOR_SUBMISSION", "PENDING_DEVELOPER_RELEASE", "READY_FOR_DISTRIBUTION"] { #expect(ReleaseStatusSync.delay(appleState: state, sinceWrite: nil, failures: 0) == nil) }
        #expect(ReleaseStatusSync.label(checked: "12:00:00", busy: true, failed: false, automatic: true, settling: false) == "Checked at 12:00:00. Checking App Store Connect again…")
        #expect(ReleaseStatusSync.label(checked: "12:00:00", busy: false, failed: true, automatic: true, settling: false).hasPrefix("Last confirmed at 12:00:00."))
        #expect(ReleaseStatusSync.label(checked: nil, busy: false, failed: false, automatic: false, settling: false).isEmpty)
    }

    @Test func everyReadinessCheckBelongsToExactlyOnePhase() throws {
        let ids = ["plan", "version", "app-configuration", "age-rating", "accessibility", "local:x", "media:x", "editorial:x", "apple-text:x", "apple-info:x",
                   "copyright", "review-info", "build", "export-compliance", "submission", "release", "territories", "privacy", "tax"]
        for id in ids { #expect(ReleaseGuide.definitions.filter { $0.matches(id) }.count == 1, "Synthetic check \(id)") }
    }
}
