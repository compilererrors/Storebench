import Foundation
import Testing
@testable import StorebenchCore

@Suite struct ReleaseStatusSummaryTests {
    init() throws { _ = try TestIsolation.require() }
    private func step(_ id: String, _ state: ReleaseReadiness.State, _ label: String = "Synthetic part") -> ReleaseReadiness.Step {
        ReleaseReadiness.Step(id: id, label: label, detail: "Synthetic detail for \(id)", href: "", action: "", state: state, territories: nil, guideHref: nil)
    }

    @Test func versionPartsAndEachLanguageShowTheirLeastFinishedStateAndTheNextAction() {
        let steps = [step("plan", .ready), step("version", .ready, "Version at Apple"), step("build", .unknown, "App Store build"),
                     step("review-info", .blocked, "App Review Information"), step("submission", .review), step("privacy", .manual),
                     step("local:en-US", .review), step("apple-text:en-US", .ready), step("media:en-US", .waiting),
                     step("local:sv", .blocked), step("apple-text:sv", .unknown), step("unrelated", .blocked)]
        let summary = ReleaseStatusSummary(steps: steps, version: "2.0", platform: "IOS", checkedAt: Date(timeIntervalSince1970: 2_000_000_000))
        // The plan itself and parts without a known place stay out; the rest keep the release's order.
        #expect(summary.versionParts.map(\.id) == ["version", "review-info", "build", "submission", "privacy"])
        #expect(summary.languages.map(\.locale) == ["en-US", "sv"])
        #expect(summary.languages[0].parts.map(\.label) == ["Text and Screenshots on This Mac", "Version Text at Apple", "Screenshots at Apple"])
        #expect(summary.languages[0].state == .review && summary.languages[1].state == .blocked)
        // Needs action comes before Unknown, so App Review Information is next although the build is listed after it.
        #expect(summary.next?.id == "review-info")
        let done = ReleaseStatusSummary(steps: [step("version", .ready), step("release", .waiting), step("local:en-US", .ready)], version: "2.0", platform: "IOS", checkedAt: Date())
        #expect(done.next == nil && done.languages[0].state == .ready)
    }

    @Test func aManualCheckIsTheNextStepWhenNothingElseNeedsAction() {
        let manual = ReleaseStatusSummary(steps: [step("version", .ready), step("release", .waiting), step("privacy", .manual, "App Privacy answers"), step("local:en-US", .ready)],
                                          version: "2.0", platform: "IOS", checkedAt: Date())
        #expect(manual.next?.id == "privacy")
        let both = ReleaseStatusSummary(steps: [step("privacy", .manual), step("build", .unknown), step("review-info", .blocked)], version: "2.0", platform: "IOS", checkedAt: Date())
        #expect(both.next?.id == "review-info")
        let unknownFirst = ReleaseStatusSummary(steps: [step("privacy", .manual), step("build", .unknown)], version: "2.0", platform: "IOS", checkedAt: Date())
        #expect(unknownFirst.next?.id == "build")
        let tax = ReleaseStatusSummary(steps: [step("version", .ready), step("tax", .manual), step("submission", .review)], version: "2.0", platform: "IOS", checkedAt: Date())
        #expect(tax.next?.id == "tax")
    }

    private func build(_ id: String) -> TestFlightBuild {
        TestFlightBuild(id: id, version: id, platform: "IOS", appVersion: "2.0", processingState: "VALID", uploadedDate: "2026-03-01T00:00:00.000Z", expirationDate: "", audience: "APP_STORE_ELIGIBLE",
                        expired: false, usesNonExemptEncryption: false, externalState: nil, internalState: nil, betaReviewState: nil)
    }
    @Test func aChosenBuildFromALaterPageStaysUntilTheCompleteListLacksIt() {
        let firstPage = (0..<50).map { build("build-\(100 - $0)") }, older = build("build-20")
        // An older build chosen on page two stays while only the first 50 builds are read.
        #expect(ReleaseWizard.chosenBuild("build-20", matching: firstPage, attachedId: "build-100", complete: false) == "build-20")
        #expect(ReleaseWizard.chosenBuild("build-20", matching: firstPage + [older], attachedId: "build-100", complete: true) == "build-20")
        #expect(ReleaseWizard.chosenBuild("build-20", matching: [], attachedId: nil, complete: false) == "build-20")
        #expect(ReleaseWizard.chosenBuild("build-20", matching: [], attachedId: nil, complete: true) == nil)
        // Only a complete list without it lets the attached build take over; with nothing chosen, the attached build is chosen at once.
        #expect(ReleaseWizard.chosenBuild("build-20", matching: firstPage, attachedId: "build-100", complete: true) == "build-100")
        #expect(ReleaseWizard.chosenBuild(nil, matching: firstPage, attachedId: "build-100", complete: false) == "build-100")
        #expect(ReleaseWizard.chosenBuild(nil, matching: firstPage, attachedId: nil, complete: false) == "build-100")
        // A choice made while the continuation waits takes precedence when the full list arrives.
        let newerChoice = "build-80"
        #expect(ReleaseWizard.chosenBuild(newerChoice, matching: firstPage + [older], attachedId: "build-100", complete: true) == newerChoice)
    }
}
