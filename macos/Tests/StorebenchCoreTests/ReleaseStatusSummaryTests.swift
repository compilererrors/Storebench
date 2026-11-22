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

    @Test func aVersionRemovedForANewBuildMovesToTheNewestProcessedBuildUploadedAfterItsOwn() {
        let current = build("64", uploaded: "2026-03-01T10:00:00.000Z"), older = build("63", uploaded: "2026-02-20T10:00:00.000Z")
        let processing = build("66", uploaded: "2026-03-02T09:00:00.000Z", state: "PROCESSING"), newer = build("65", uploaded: "2026-03-01T18:30:00.000Z")
        #expect(ReleaseWizard.newerBuilds([current, older], attachedId: "64").isEmpty)
        #expect(ReleaseWizard.newerBuilds([older, newer, current, processing], attachedId: "64").map(\.id) == ["66", "65"])
        #expect(ReleaseWizard.newerBuilds([newer, current], attachedId: nil).isEmpty, "Without the version's build, nothing counts as newer")
        // Replacing moves from the version's build to the newest processed newer one; a build still processing is not chosen.
        #expect(ReleaseWizard.chosenBuild("64", matching: [processing, newer, current], attachedId: "64", complete: true, replacing: true) == "65")
        #expect(ReleaseWizard.chosenBuild("64", matching: [processing, current], attachedId: "64", complete: true, replacing: true) == "64")
        #expect(ReleaseWizard.chosenBuild("63", matching: [newer, current, older], attachedId: "64", complete: true, replacing: true) == "63", "Another build the owner chose stays")
        #expect(ReleaseWizard.chosenBuild("64", matching: [newer, current], attachedId: "64", complete: true) == "64", "Without replacing, the version's build stays")
    }

    @Test func anUploadAppleReceivedShowsUntilItsBuildIsListed() {
        func upload(_ number: String, at: String, state: String = "Processing", buildId: String? = nil, version: String = "2.0", platform: String = "IOS") -> BuildDelivery {
            BuildDelivery(id: "upload-\(number)", version: version, buildNumber: number, platform: platform, state: state, createdDate: at, uploadedDate: at, buildId: buildId,
                          deletable: false, details: [], omittedDetails: 0)
        }
        let current = build("64", uploaded: "2026-03-01T10:00:00.000Z")
        let uploads = [upload("63", at: "2026-02-20T10:00:00Z"), upload("64", at: "2026-03-01T10:00:00Z", state: "Complete", buildId: "64"),
                       upload("65", at: "2026-03-01T18:30:00Z"), upload("66", at: "2026-03-02T08:00:00Z", state: "Failed"),
                       upload("67", at: "2026-03-02T09:00:00Z", version: "2.1"), upload("68", at: "2026-03-02T09:00:00Z", platform: "MAC_OS")]
        // Another version, another platform, a completed upload and anything before the version's build are left out; newest first.
        #expect(ReleaseWizard.pendingUploads(uploads, platform: "IOS", version: "2.0", builds: [current], after: current.uploadedDate).map(\.buildNumber) == ["66", "65"])
        #expect(ReleaseWizard.pendingUploads(uploads, platform: "IOS", version: "2.0", builds: [current], after: nil).map(\.buildNumber) == ["66", "65", "63"])
        // Once Apple lists the build, its upload no longer shows on its own.
        #expect(ReleaseWizard.pendingUploads(uploads, platform: "IOS", version: "2.0", builds: [current, build("65", uploaded: "2026-03-01T18:30:00.000Z"), build("66")], after: nil).map(\.buildNumber) == ["63"])
    }

    @Test func aBuildUploadShowsItsDayAndTwentyFourHourTime() throws {
        let utc = try #require(TimeZone(identifier: "UTC")), stockholm = try #require(TimeZone(identifier: "Europe/Stockholm"))
        #expect(AppStoreNames.dateTime("2026-11-20T13:05:00.000Z", timeZone: utc) == "Nov 20, 2026 13:05")
        #expect(AppStoreNames.dateTime("2026-11-20T23:30:00Z", timeZone: stockholm) == "Nov 21, 2026 00:30")
        #expect(AppStoreNames.dateTime("not a date", timeZone: utc) == nil)
    }

    private func build(_ id: String, uploaded: String = "2026-03-01T00:00:00.000Z", state: String = "VALID") -> TestFlightBuild {
        TestFlightBuild(id: id, version: id, platform: "IOS", appVersion: "2.0", processingState: state, uploadedDate: uploaded, expirationDate: "", audience: "APP_STORE_ELIGIBLE",
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
