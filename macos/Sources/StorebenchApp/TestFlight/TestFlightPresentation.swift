import StorebenchCore
import SwiftUI

/// Prepares one TestFlight review. Nothing reaches App Store Connect until the review is approved.
@MainActor func prepareTestFlight(_ account: Account, _ app: Account.App, _ session: WorkspaceSession?, buildId: String? = nil, _ configure: (inout PublishRequest) -> Void) async -> (PublishReview?, String) {
    var request = PublishRequest(accountId: account.id, appId: app.id, scope: .testflight, buildId: buildId)
    configure(&request)
    return await preparePublishReview(account, session, request)
}

/// Prepares one Publish review. Nothing reaches App Store Connect until the review is approved.
@MainActor func preparePublishReview(_ account: Account, _ session: WorkspaceSession?, _ request: PublishRequest) async -> (PublishReview?, String) {
    guard let session else { return (nil, "") }
    do { return (try await session.preparePublishing(account: account, request: request, client: try await session.client(for: account)), "") }
    catch let failure as PublishFailure { return (nil, failure.message) }
    catch AppStoreConnectClient.Failure.status(let code) where code == 401 || code == 403 { return (nil, "Apple did not allow this API key to read what this change needs.") }
    // Apple's answer or the kind of failure names no account or app, and says what to retry or report.
    catch AppStoreConnectClient.Failure.status(let code) { return (nil, "App Store Connect answered \(code) while the review was prepared. Nothing was sent; try again, or copy the error code for support.") }
    catch let error as URLError { return (nil, "The connection to App Store Connect was lost (\(error.code.rawValue)) while the review was prepared. Nothing was sent; try again.") }
    catch { return (nil, "The review could not be prepared (\(String(describing: type(of: error)))). Nothing was sent to App Store Connect.") }
}
