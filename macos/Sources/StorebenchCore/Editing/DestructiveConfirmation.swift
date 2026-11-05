import Foundation

/// Actions that remove or discard work on this Mac. Each asks first unless Don't ask again was chosen for it; Settings turns the question back on.
/// Apple changes are not listed: they are prepared as a review and only sent when you approve it.
public enum DestructiveConfirmation: String, CaseIterable, Sendable, Hashable {
    case removeVersion = "remove-version", deleteRevision = "delete-revision", discardChanges = "discard-changes"
    case removeKeywordIdeas = "remove-keyword-ideas", removePriceDraft = "remove-price-draft", deletePricingProfile = "delete-pricing-profile"
    case deleteCreatedMedia = "delete-created-media", removeLocalFile = "remove-local-file", removeReportPeriod = "remove-report-period", disconnectReporter = "disconnect-reporter"

    /// What the setting in Settings asks before.
    public var title: String {
        switch self {
        case .removeVersion: "Removing a version from this Mac"
        case .deleteRevision: "Deleting a saved import or draft"
        case .discardChanges: "Discarding unsaved changes"
        case .removeKeywordIdeas: "Removing keyword ideas"
        case .removePriceDraft: "Removing a country price draft"
        case .deletePricingProfile: "Deleting a pricing profile"
        case .deleteCreatedMedia: "Deleting cards and card sets in Create Media"
        case .removeLocalFile: "Removing local files and packages"
        case .removeReportPeriod: "Removing saved report periods"
        case .disconnectReporter: "Disconnecting Reporter"
        }
    }
}
