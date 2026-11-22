import Foundation

/// App Store Connect's own button names for the change a review sends, so each press names what happens at Apple.
/// `command` is the button on the review and `confirmation` the one that sends. They differ only where App Store Connect takes
/// two presses: Add for Review, then Submit to App Review.
public struct PublishCommandName: Sendable, Equatable {
    public let command: String, confirmation: String
    init(_ command: String, then confirmation: String? = nil) { self.command = command; self.confirmation = confirmation ?? command }

    public static let addForReview = PublishCommandName("Add for Review", then: "Submit to App Review")

    /// The name for a prepared review. A release review that creates the version uses App Store Connect's Create.
    public static func of(_ review: PublishReview) -> PublishCommandName {
        if review.request.scope == .release,
           review.steps.contains(where: { $0.method == "POST" && $0.path.first?.text == "appStoreVersions" }) { return PublishCommandName("Create") }
        return of(review.request)
    }

    public static func of(_ request: PublishRequest) -> PublishCommandName {
        if request.mediaStage == PublishRequest.uploadStage { return PublishCommandName("Upload") }
        switch request.scope {
        case .submit: return addForReview
        case .releaseVersion: return PublishCommandName("Release This Version")
        case .cancelSubmission: return PublishCommandName("Remove from Review")
        case .pricing, .productPricing: return PublishCommandName("Confirm")
        case .appPrivacy: return PublishCommandName("Publish")
        case .exportDocument: return PublishCommandName("Upload")
        case .analyticsOngoing, .analyticsSnapshot: return PublishCommandName("Request Reports")
        case .testflight: return PublishCommandName(testFlight(request.testflightAction))
        case .assetLibrary:
            guard let action = request.assetLibraryChange?.action else { return PublishCommandName("Save") }
            return action == .submit ? addForReview : PublishCommandName(assetLibrary(action))
        case .release, .metadata, .versionCopyright, .pricingSetup, .taxCategory, .reviewInfo, .appInformation, .availability,
             .ageRating, .accessibility, .exportCompliance, .versionBuild:
            return PublishCommandName("Save")
        }
    }

    /// TestFlight's buttons for each change a TestFlight review makes.
    static func testFlight(_ action: String?) -> String {
        switch action {
        case "submit-beta-review": "Submit for Review"
        case "notify-build-testers": "Notify Testers"
        case "expire-build": "Expire Build"
        case "invite-tester", "invite-individual-tester": "Invite"
        case "add-build", "add-tester", "assign-individual-tester": "Add"
        case "remove-build", "remove-tester", "remove-app-tester", "remove-individual-tester": "Remove"
        case "create-group", "create-in-app-purchase", "create-subscription", "create-subscription-group": "Create"
        case "delete-group", "delete-build-upload", "delete-failed-upload", "delete-draft": "Delete"
        default: "Save"
        }
    }

    static func assetLibrary(_ action: AssetLibrary.Action) -> String {
        switch action {
        case .upload: "Upload"
        case .archive: "Archive"
        case .restore: "Restore"
        case .delete: "Delete"
        case .removePlacement: "Remove"
        case .submit: "Add for Review"
        case .rename, .poster, .place, .reorder: "Save"
        }
    }
}
