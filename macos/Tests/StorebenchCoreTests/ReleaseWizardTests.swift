import Foundation
import Testing
@testable import StorebenchCore

struct ReleaseWizardTests {
    init() throws { _ = try TestIsolation.require() }

    private func step(_ id: String, _ state: ReleaseReadiness.State) -> ReleaseReadiness.Step {
        .init(id: id, label: id, detail: "Synthetic detail", href: "/synthetic", action: "Open \(id)", state: state, territories: nil, guideHref: nil)
    }
    private func request(_ scope: PublishRequest.Scope) -> PublishRequest { .init(accountId: "account-1", appId: "1000000001", scope: scope) }

    @Test func phasesKeepTheGuideOrderAndNeighborsStopAtBothEnds() {
        #expect(ReleaseWizard.phaseIds == ["plan", "listing", "send", "build", "review-information", "submit", "release"])
        #expect(ReleaseWizard.neighbors("plan").previous == nil && ReleaseWizard.neighbors("plan").next == "listing")
        #expect(ReleaseWizard.neighbors("send").previous == "listing" && ReleaseWizard.neighbors("send").next == "build")
        #expect(ReleaseWizard.neighbors("release").previous == "submit" && ReleaseWizard.neighbors("release").next == nil)
        #expect(ReleaseWizard.neighbors("unknown").previous == nil && ReleaseWizard.neighbors("unknown").next == nil)
    }

    @Test func theWizardOpensWhereActionIsNeeded() {
        #expect(ReleaseWizard.initialPhase(ReleaseGuide.guide(nil)) == "plan")
        let blocked = ReleaseGuide.guide([step("plan", .ready), step("local:en-US", .review), step("version", .blocked)])
        #expect(ReleaseWizard.initialPhase(blocked) == "send")
        let finished = ReleaseGuide.guide([step("plan", .ready), step("local:en-US", .ready), step("app-configuration", .ready), step("version", .ready),
                                           step("build", .ready), step("review-info", .ready), step("submission", .ready), step("release", .ready)])
        #expect(ReleaseWizard.initialPhase(finished) == "release")
    }

    @Test func checksMapToTheirPhaseAndMissingListsOnlyBlockedChecks() {
        #expect(ReleaseWizard.phase(containing: "territories") == "submit")
        #expect(ReleaseWizard.phase(containing: "media:sv") == "send")
        #expect(ReleaseWizard.phase(containing: "export-compliance") == "build")
        #expect(ReleaseWizard.phase(containing: "submission") == "submit")
        #expect(ReleaseWizard.phase(containing: "not-a-check") == nil)
        let guide = ReleaseGuide.guide([step("plan", .ready), step("app-configuration", .blocked), step("age-rating", .review), step("territories", .blocked)])
        let information = guide.phases.first { $0.id == "submit" }!
        #expect(ReleaseWizard.missing(information).map(\.id) == ["app-configuration", "territories"])
    }

    @Test func actionsStayInsideTheWizard() {
        #expect(ReleaseWizard.destination(stepId: "export-compliance", target: .information("export-compliance")) == .phase("build", .information("export-compliance")))
        #expect(ReleaseWizard.destination(stepId: "build", target: .publishing(request(.submit))) == .phase("build", .publish(request(.submit))))
        #expect(ReleaseWizard.destination(stepId: "submission", target: .publishing(request(.submit))) == .phase("submit", .publish(request(.submit))))
        #expect(ReleaseWizard.destination(stepId: "local:sv", target: .language("sv")) == .phase("listing", .language("sv")))
        #expect(ReleaseWizard.destination(stepId: "review-info", target: .reviewInformation("version-1")) == .phase("review-information", .reviewInformation("version-1")))
        #expect(ReleaseWizard.destination(stepId: "unlisted", target: .publishing(request(.releaseVersion))) == .phase("release", .publish(request(.releaseVersion))))
        let url = URL(string: "https://appstoreconnect.apple.com/")!
        #expect(ReleaseWizard.destination(stepId: "privacy", target: .external(url)) == .external(url))
    }

    @Test func sendingStartsWithTheVersionThenTextThenCopyright() {
        func scope(_ steps: [ReleaseReadiness.Step]) -> PublishRequest.Scope {
            ReleaseWizard.sendScope(ReleaseGuide.guide([step("plan", .ready)] + steps).phases.first { $0.id == "send" }!)
        }
        #expect(scope([step("version", .blocked), step("apple-text:en-US", .unknown), step("copyright", .unknown)]) == .release)
        #expect(scope([step("version", .ready), step("media:en-US", .blocked), step("copyright", .blocked)]) == .metadata)
        #expect(scope([step("version", .ready), step("apple-text:en-US", .ready), step("copyright", .blocked)]) == .versionCopyright)
        #expect(scope([step("version", .ready), step("copyright", .ready)]) == .metadata)
    }

    @Test func guidesComeFirstAndEveryAppStoreConnectPageHasItsOwnMenu() {
        #expect(AppNavigation.Section.release.title == "Release")
        #expect(AppNavigation.Section.release.rawValue == "Version setup")
        #expect(AppNavigation.Section.allCases.filter { $0.group == .guides } == [.release, .quickRelease, .startTesting, .pricing, .createMedia, .setUpReports])
        // Quick Release is its own entry right after Release, with a stable key for saved links.
        #expect(AppNavigation.Section.quickRelease.title == "Quick Release" && LibraryChooser.sections.firstIndex(of: .quickRelease) == LibraryChooser.sections.firstIndex(of: .release).map { $0 + 1 })
        #expect(AppNavigation.Section(key: "quick-release") == .quickRelease)
        #expect(AppNavigation.Section.allCases.filter { ![.release, .pricing].contains($0) }.allSatisfy { $0.title == $0.rawValue })
        // Every App Store Connect page belongs to a guide or stands on its own; a guide never points to another guide.
        #expect(AppNavigation.Section.allCases.compactMap(\.guide).allSatisfy { $0.group == .guides })
        #expect([AppNavigation.Section.groups, .externalTesting, .testers, .testInformation, .feedback].allSatisfy { $0.group == .testflight && $0.guide == .startTesting })
    }

    @Test func languageProblemsNameTheFieldAndWhatToDoAndStayFixableOneByOne() {
        #expect(ReleaseMaterial.problem("whatsNew", value: "  ", required: true) == "What’s New in This Version is empty. Add text.")
        #expect(ReleaseMaterial.problem("whatsNew", value: "", required: false) == nil)
        #expect(ReleaseMaterial.problem("keywords", value: String(repeating: "a", count: 102), required: true) == "Keywords is 2 bytes over Apple’s limit. Shorten it.")
        #expect(ReleaseMaterial.problem("supportUrl", value: "synthetic", required: true)?.hasPrefix("Support URL is not a complete public URL") == true)
        #expect(ReleaseMaterial.required(platform: "MAC_OS", whatsNew: true) == ["description", "keywords", "supportUrl", "name", "whatsNew", "privacyPolicyUrl"])
        #expect(ReleaseMaterial.required(platform: "TV_OS", whatsNew: false).contains("privacyPolicyText"))
        var local = step("local:en-GB", .blocked)
        local.issues = [.init(field: "whatsNew", message: "What's new: add text", section: "text"), .init(field: "keywords", message: "Keywords: 3 bytes over the limit", section: "text"),
                        .init(field: "screenshots", message: "No screenshots selected locally. Reuse images or check inherited screenshots in Apple.", section: "screenshots")]
        let shown = ReleaseWizard.presented(local)
        #expect(shown.label == "British English (en-GB) · Text and Screenshots" && shown.action == "Edit Language" && shown.issues.map(\.field) == ["whatsNew", "keywords", "screenshots"])
        #expect(shown.issues.map(\.message) == ["What’s New in This Version is empty. Add text.", "Keywords is 3 bytes over Apple’s limit. Shorten it.", "No screenshots yet. Add screenshots for this language."])
        #expect(ReleaseReadiness.fieldAnchor("en-GB", "whatsNew") != ReleaseReadiness.fieldAnchor("en-GB", "screenshots"))
    }

    @Test func stepThreeNamesWhatIsOnlyOnThisMac() {
        var text = step("apple-text:en-GB", .blocked)
        text.issues = [.init(field: "promotionalText", message: "Promotional Text", section: "missing"), .init(field: "keywords", message: "Keywords", section: "missing")]
        let shown = ReleaseWizard.presented(text)
        #expect(shown.label == "British English (en-GB) · Version text" && shown.issues.isEmpty)
        #expect(shown.detail == "Only on this Mac, not in App Store Connect yet: Promotional Text, Keywords. Prepare Review below lists the changes, and Save uploads them.")
        var media = step("media:en-GB", .blocked)
        media.issues = [.init(field: "screenshots", message: "Mac screenshots are 2000 × 1220 px. Apple accepts 2880 × 1800 px.", section: "rejected"),
                        .init(field: "screenshots", message: "3 Mac screenshots", section: "missing")]
        #expect(ReleaseWizard.presented(media).detail == "Apple does not accept these sizes. Mac screenshots are 2000 × 1220 px. Apple accepts 2880 × 1800 px. Replace the screenshots in step 2, Text and Screenshots, before saving.")
        media.issues.removeFirst()
        #expect(ReleaseWizard.presented(media).detail.hasPrefix("Only on this Mac, not in App Store Connect yet: 3 Mac screenshots."))
        #expect(ReleaseWizard.presented(step("apple-info:en-GB", .blocked)).detail == "This language's name, subtitle and privacy policy are only on this Mac. Prepare Review below lists the changes, and Save uploads them.")
    }

    @Test func appReviewInformationNamesTheEmptyFieldsInAppStoreConnectsWords() {
        var information = ReviewInformation(); information.contactFirstName = "Synthetic"; information.contactEmail = "not-an-email"; information.demoAccountRequired = true
        #expect(information.missing == ["User name", "Password", "Last name", "Phone number", "Email"])
        var review = step("review-info", .blocked)
        review.issues = ["Phone number", "Email"].map { .init(field: "review", message: $0, section: "missing") }
        #expect(ReleaseWizard.presented(review).detail == "Missing at App Store Connect: Phone number, Email. Fill it in below, choose Save, then Send to Apple in the list of changes to send it.")
        #expect(ReleaseWizard.presented(step("review-info", .ready)).detail == "Synthetic detail")
    }

    @Test func addForReviewWaitsForEveryEarlierStepApplesSubmissionNeeds() throws {
        // Steps 1, 2, 4 and 5 are done, but step 3 still has screenshots only on this Mac: Apple would refuse the version.
        let unsent = ReleaseGuide.guide([step("plan", .ready), step("local:en-GB", .ready), step("version", .ready), step("media:en-GB", .blocked),
                                         step("build", .ready), step("review-info", .ready), step("submission", .blocked)])
        #expect(try #require(ReleaseWizard.unfinished(before: "submit", in: unsent)).id == "send")
        let sent = ReleaseGuide.guide([step("plan", .ready), step("local:en-GB", .ready), step("version", .ready), step("media:en-GB", .ready),
                                       step("build", .ready), step("review-info", .ready), step("submission", .blocked)])
        #expect(ReleaseWizard.unfinished(before: "submit", in: sent) == nil)
    }
}
