import Foundation

/// A concrete prepared review bound to the language's saved source and target choice.
public struct LanguageListingReview: Sendable, Identifiable {
    public let source: PublishRequest, review: PublishReview
    public var id: String { review.id }
    public var versionSetup: Bool { review.request.scope == .release }
    public func matches(accountId: String, appId: String, revisionId: String?, versions: [String], targetMode: String) -> Bool {
        guard source.scope == .metadata, source.accountId == accountId, source.appId == appId, source.revisionId == revisionId,
              source.versionId.map(versions.contains) == true, source.targetMode == targetMode,
              review.state == "prepared", review.request.accountId == accountId, review.request.appId == appId else { return false }
        if versionSetup { return targetMode == "release-plan" && review.request == PublishRequest(accountId: accountId, appId: appId, scope: .release) }
        return review.request == source
    }
}

extension WorkspaceSession {
    /// Missing planned versions get their own approval; only a no-op setup race retries the material read.
    public func prepareLanguageListingReview(account: Account, request: PublishRequest, client: AppStoreConnectClient) async throws -> LanguageListingReview {
        let source = try request.validated()
        guard source.scope == .metadata, source.revisionId != nil, source.versionId != nil, source.targetMode != nil else { throw PublishFailure.invalid("Choose the saved language's source, version and target.") }
        let review: PublishReview
        do { review = try await preparePublishing(account: account, request: source, client: client) }
        catch PublishFailure.versionRequired where source.targetMode == "release-plan" {
            let setup = try await preparePublishing(account: account, request: .init(accountId: source.accountId, appId: source.appId, scope: .release), client: client)
            review = setup.steps.isEmpty ? try await preparePublishing(account: account, request: source, client: client) : setup
        }
        try Task.checkCancellation()
        let result = LanguageListingReview(source: source, review: review)
        guard result.matches(accountId: source.accountId, appId: source.appId, revisionId: source.revisionId, versions: [source.versionId!], targetMode: source.targetMode ?? "apple-version") else { throw PublishFailure.conflict }
        return result
    }
}
