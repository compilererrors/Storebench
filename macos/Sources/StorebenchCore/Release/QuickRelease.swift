import Foundation

/// Quick Release: the next version of a published app in a few steps, with only the fields an update needs.
/// It shares the version plan, local drafts and readiness checks with Release, and every Apple change is still its own prepared review.
public enum QuickRelease {
    public static let stepIDs = ["version", "text", "build", "submit"]
    /// Internal destinations always resolve to one of this page's four steps.
    public static func step(for check: String?) -> String {
        guard let check else { return "version" }
        if ["plan", "version", "send", "create"].contains(check) { return "version" }
        if check == "listing" || check == "text" || check.hasPrefix("local:") || check.hasPrefix("apple-text:") || check.hasPrefix("apple-info:") { return "text" }
        if check == "build" || check == "export-compliance" { return "build" }
        return "submit"
    }
    public static func textNeedsAction(_ step: ReleaseReadiness.Step) -> Bool {
        if step.id.hasPrefix("apple-text:") || step.id.hasPrefix("apple-info:") { return step.state != .ready }
        return step.state == .blocked && step.id.hasPrefix("local:") && !fieldIssues(step).isEmpty
    }
    /// The fields included in the compact text review; What's New is the primary input.
    public static let fields = ["description", "subtitle", "keywords", "whatsNew"]
    /// The fields saved to the version's localizations.
    public static let versionFields: Set<String> = ["description", "keywords", "whatsNew"]
    /// Subtitle belongs to App Information, so it is saved to the app information localization.
    public static let appInfoFields: Set<String> = ["subtitle"]

    public static func releaseNotesIssue(_ value: String, required: Bool = true) -> String? {
        if required && TextSemantics.trim(value).isEmpty { return "Add release notes for this language." }
        if TextDrafts.used("whatsNew", value) > (TextDrafts.limits["whatsNew"] ?? 4000) { return "Keep release notes within Apple's limit of 4,000 characters." }
        if !TextSemantics.validControlText(value) { return "Remove control characters from the release notes." }
        return nil
    }

    /// Only the Quick Release fields of a language's text are sent. Other local drafts, such as Promotional Text, stay on this Mac.
    static func sent(_ fields: [(String, String)], appInfo: Bool) -> [(String, String)] {
        let allowed = appInfo ? appInfoFields : versionFields
        return fields.filter { allowed.contains($0.0) }
    }

    /// The review that saves this plan's Quick Release text to the version at App Store Connect, without screenshots or other fields.
    public static func textRequest(accountId: String, appId: String, plan: ReleasePlan, includingOtherText: Bool = false) -> PublishRequest {
        var request = PublishRequest(accountId: accountId, appId: appId, scope: .metadata, targetMode: "release-plan", revisionId: plan.sourceRevisionId, versionId: plan.baseVersionId)
        request.mediaStage = includingOtherText ? PublishRequest.textStage : PublishRequest.quickStage
        return request
    }

    /// Checks the page answers itself: the version, its text at Apple, the build and its export compliance, and the submission.
    public static func handledHere(_ stepId: String) -> Bool {
        ["plan", "version", "build", "export-compliance", "submission", "release"].contains(stepId) || stepId.hasPrefix("apple-text:") || stepId.hasPrefix("apple-info:")
    }

    /// What still blocks this update and is fixed somewhere else, in Release's order. A step that is only unknown is not shown as a blocker.
    public static func blockers(_ steps: [ReleaseReadiness.Step]) -> [ReleaseReadiness.Step] {
        steps.filter { $0.state == .blocked && !handledHere($0.id) }
    }

    /// The language's own problems that one of the page's fields answers; the page shows them at that field.
    public static func fieldIssues(_ step: ReleaseReadiness.Step) -> [ReleaseMaterial.Issue] {
        step.id.hasPrefix("local:") ? step.issues.filter { fields.contains($0.field) } : []
    }

    /// A step whose every problem is a field on the page is fixed there, not in Release.
    public static func fixedHere(_ step: ReleaseReadiness.Step) -> Bool {
        step.id.hasPrefix("local:") && !step.issues.isEmpty && step.issues.allSatisfy { fields.contains($0.field) }
    }

    /// A first version needs the full starting fields rather than the existing listing shortcut.
    public static func needsFullRelease(_ inputs: ReleasePlanInputs, history: [Revision]) -> Bool {
        if case .empty = inputs.start { return true }
        return ReleaseSetup.candidates(history).allSatisfy(\.revision.isLocalDraft)
    }

    public enum Stage: Equatable, Sendable {
        /// The version is only on this Mac; Create prepares the review that creates it at Apple.
        case create
        /// The version exists at Apple and can take text, a build and the submission.
        case prepare
        /// Apple has the version with App Review or later; show its current status.
        case submitted(String)
    }

    /// Where the update stands at Apple, read from the release status.
    public static func stage(_ snapshot: ReleaseReadinessSnapshot) -> Stage {
        guard snapshot.targetVersionId != nil else { return .create }
        if let state = snapshot.targetState, ReleaseReadiness.submitted.contains(state) { return .submitted(state) }
        return .prepare
    }
}
