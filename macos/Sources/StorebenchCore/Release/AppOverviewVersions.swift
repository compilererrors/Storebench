import Foundation

/// A live version check never uses an archived state as evidence of current Apple status.
public enum AppOverviewVersions {
    public struct Entry: Identifiable, Sendable, Codable {
        public let value: PublishingWorkspace.Version
        public var id: String { value.id }
        public var state: String { AppStoreNames.primaryState(value.state) }
        public var inReview: Bool { ["WAITING_FOR_REVIEW", "IN_REVIEW"].contains(value.state) }
        public var json: JSONText { .object([("id", .string(id)), ("platform", .string(value.platform)), ("number", .string(value.number)), ("state", .string(state)), ("inReview", .bool(inReview))]) }
        public init(_ value: PublishingWorkspace.Version) { self.value = value }
    }
    public static func targetExists(_ plan: ReleasePlan, versions: [Entry]) -> Bool { target(plan, versions: versions) != nil }
    /// The Apple version a plan prepares, when Apple has it.
    public static func target(_ plan: ReleasePlan, versions: [Entry]) -> Entry? {
        versions.first { PublishingWorkspace.equal($0.value.platform, plan.platform) && PublishingWorkspace.equal($0.value.number, plan.targetVersion) }
    }
    public struct Cancellation: Sendable {
        public let scope: RecoveryGuidance.Scope, versionId: String
        public init(scope: RecoveryGuidance.Scope, version: Entry) throws {
            guard version.inReview, AppOverviewMaterial.identifier(version.id) else { throw PublishFailure.invalid("Choose a current Apple version in review.") }
            self.scope = scope; versionId = version.id
        }
        public var request: PublishRequest { .init(accountId: scope.accountId, appId: scope.appId, scope: .cancelSubmission, versionId: versionId) }
        public var href: String { scope.root + "/publish?scope=cancel-submission&versionId=" + versionId }
        public func allowed(current: RecoveryGuidance.Scope?, decision: EditorProtectionPolicy.Decision, discardConfirmed: Bool = false) -> Bool {
            guard scope == current else { return false }
            return decision == .ready || decision == .confirmDiscard && discardConfirmed
        }
    }
}

extension WorkspaceSession {
    public func currentAppVersions(account: Account, appId: String, client: AppStoreConnectClient) async throws -> [PublishingWorkspace.Version] {
        try requirePublishingAccount(account, appId: appId, client: client); try Task.checkCancellation()
        let items: [AppStoreConnectClient.Resource]
        do { items = try await client.list("/v1/apps/\(appId)/appStoreVersions?include=app&limit=200") }
        catch { try Task.checkCancellation(); throw error }
        var seen = Set<String>()
        let versions = try items.map { item -> PublishingWorkspace.Version in
            guard item.type == "appStoreVersions", AppOverviewMaterial.identifier(item.id), seen.insert(item.id).inserted, Apple.owned(item, "app", "apps", appId),
                  let platform = item.attributes?["platform"]?.string, !platform.isEmpty, let number = item.attributes?["versionString"]?.string, !number.isEmpty else { throw PublishFailure.invalid("Apple returned invalid or unowned version choices.") }
            return .init(id: item.id, platform: platform, number: number, state: Apple.state(item), releaseType: item.attributes?["releaseType"]?.string ?? "", copyright: item.attributes?["copyright"]?.string ?? "")
        }
        try requirePublishingAccount(account, appId: appId, client: client); try Task.checkCancellation(); return versions
    }
}
