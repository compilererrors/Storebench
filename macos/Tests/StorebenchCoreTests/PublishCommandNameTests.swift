import Foundation
import Testing
@testable import StorebenchCore

/// Every command that sends a review uses App Store Connect's own button name, so each press says what happens at Apple.
struct PublishCommandNameTests {
    init() throws { _ = try TestIsolation.require() }

    private func request(_ scope: PublishRequest.Scope) -> PublishRequest { PublishRequest(accountId: "synthetic-account", appId: "synthetic-app", scope: scope) }
    private func review(_ request: PublishRequest, _ steps: [(String, String)]) -> PublishReview {
        let planned = steps.map { method, root in
            PublishStep(key: root, group: nil, label: "Synthetic", detail: "", before: nil, after: nil, kind: .api, method: method, path: [.string(root)],
                        body: nil, asset: nil, guardValue: nil, state: "pending", resultId: nil)
        }
        return PublishReview(plan: PublishPlan(title: "Synthetic review", request: request, fingerprint: "synthetic", steps: planned, notes: []), id: "synthetic-review", now: Date())
    }

    @Test func addForReviewIsFollowedBySubmitToAppReviewAsInAppStoreConnect() {
        let name = PublishCommandName.of(request(.submit))
        #expect(name.command == "Add for Review" && name.confirmation == "Submit to App Review")
        var library = request(.assetLibrary); var change = AssetLibrary.Change(action: .submit); change.assetIds = ["synthetic-asset"]; library.assetLibraryChange = change
        #expect(PublishCommandName.of(library) == .addForReview)
    }

    @Test func singlePressChangesUseTheirAppStoreConnectButtonForBothPresses() {
        let expected: [(PublishRequest.Scope, String)] = [(.metadata, "Save"), (.reviewInfo, "Save"), (.versionBuild, "Save"), (.appInformation, "Save"),
                                                          (.releaseVersion, "Release This Version"), (.cancelSubmission, "Remove from Review"),
                                                          (.appPrivacy, "Publish"), (.pricing, "Confirm"), (.exportDocument, "Upload")]
        for (scope, title) in expected {
            let name = PublishCommandName.of(request(scope))
            #expect(name.command == title && name.confirmation == title, "\(scope) uses \(name)")
        }
        var upload = request(.metadata); upload.mediaStage = PublishRequest.uploadStage
        #expect(PublishCommandName.of(upload).command == "Upload")
    }

    @Test func testFlightChangesUseTestFlightButtons() {
        for (action, title) in [("submit-beta-review", "Submit for Review"), ("notify-build-testers", "Notify Testers"), ("expire-build", "Expire Build"),
                                ("invite-tester", "Invite"), ("create-group", "Create"), ("delete-group", "Delete"), ("save-build-notes", "Save")] {
            var testFlight = request(.testflight); testFlight.testflightAction = action
            #expect(PublishCommandName.of(testFlight).command == title, "\(action)")
        }
    }

    @Test func noSendCommandFallsBackToAWordAppStoreConnectDoesNotUse() {
        for scope in PublishRequest.Scope.allCases {
            let name = PublishCommandName.of(request(scope))
            #expect(!["Send to Apple", "Approve and Publish", "Sync to Apple"].contains(name.command), "\(scope) uses \(name.command)")
        }
    }

    @Test func aReleaseReviewThatCreatesTheVersionUsesCreate() {
        #expect(PublishCommandName.of(review(request(.release), [("POST", "appStoreVersions")])).command == "Create")
        #expect(PublishCommandName.of(review(request(.release), [("PATCH", "appStoreVersions")])).command == "Save")
        #expect(PublishCommandName.of(review(request(.submit), [("POST", "reviewSubmissions"), ("PATCH", "reviewSubmissions")])) == .addForReview)
    }
}
