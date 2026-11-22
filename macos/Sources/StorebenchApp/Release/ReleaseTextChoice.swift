import StorebenchCore
import SwiftUI

/// The person's choice for a field App Store Connect changed since the draft took its text. Both only change the draft on this Mac.
enum ReleaseTextChoice {
    /// Uses App Store Connect's text, or keeps this Mac's so the step's review sends it, then reads the open language editors again.
    /// Returns what went wrong, or nil.
    @MainActor static func resolve(_ issue: ReleaseMaterial.Issue, keepMine: Bool, session: WorkspaceSession, account: Account, appId: String,
                                   plan: ReleasePlan, listing: VersionListingEditor?) async -> String? {
        guard let localization = issue.localizationId, let scope = issue.scope, let apple = issue.apple else { return "Refresh Status, then choose again." }
        do {
            if keepMine {
                try await session.keepDraftText(accountId: account.id, appId: appId, revisionId: plan.sourceRevisionId, localizationId: localization, scope: scope, apple: [issue.field: apple])
            } else {
                try await session.useAppStoreConnectText(accountId: account.id, appId: appId, revisionId: plan.sourceRevisionId, localizationId: localization, scope: scope, values: [issue.field: apple])
            }
            for language in listing?.languages ?? [] { await language.text.load(afterReuse: true) }
            return nil
        } catch { return (error as? DraftFailure)?.message ?? "Your draft could not be updated. It is unchanged." }
    }
}
