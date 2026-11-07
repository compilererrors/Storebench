import Foundation

/// The builds Release's build step shows for one app, platform and version, and the build Apple has attached to that version.
/// Only build attributes and the pre-release version are read; beta review, beta detail and declaration reads belong to TestFlight.
public struct ReleaseBuildPage: Sendable, Equatable {
    public let builds: [TestFlightBuild]
    public let attachedId: String?
    /// False while Apple has more builds for this version than were read. A build missing from a partial page is not known to be
    /// missing; the attached build is read on its own, so it is always included.
    public let complete: Bool
}

extension WorkspaceSession {
    /// Builds on the first page of Release's build step. A version rarely has more; any further ones are read after it is shown.
    static let releaseBuildPageSize = 50

    /// Apple's build list filtered to the version's platform and version string, newest upload first.
    static func releaseBuildsPath(appId: String, platform: String, version: String) throws -> String {
        guard appId.range(of: #"^\d{1,32}$"#, options: .regularExpression) != nil, platform.range(of: "^[A-Z_]{1,32}$", options: .regularExpression) != nil,
              version.range(of: #"^[0-9A-Za-z][0-9A-Za-z.\-]{0,63}$"#, options: .regularExpression) != nil else { throw PublishFailure.invalid("Choose an Apple version.") }
        return "/v1/builds?filter%5Bapp%5D=\(appId)&filter%5BpreReleaseVersion.platform%5D=\(platform)&filter%5BpreReleaseVersion.version%5D=\(version)"
            + "&include=app%2CpreReleaseVersion&sort=-uploadedDate&limit=\(releaseBuildPageSize)"
    }

    /// Release's build step: the first page of the version's builds with the attached one, or with `all` every page. `latest` reads past the
    /// shared cache, for the check that confirms Apple's newest answer; otherwise the shared read is used and read again if a refresh cancelled it.
    public func releaseBuildPage(account: Account, appId: String, versionId: String?, platform: String, version: String, all: Bool = false, latest: Bool = false) async throws -> ReleaseBuildPage {
        let client = latest ? try client(for: account) : try readClient(for: account)
        return try await AppStoreReadCache.rereadingAfterInvalidation {
            try await releaseBuildPage(appId: appId, versionId: versionId, platform: platform, version: version, all: all, client: client)
        }
    }

    func releaseBuildPage(appId: String, versionId: String?, platform: String, version: String, all: Bool, client: AppStoreConnectClient) async throws -> ReleaseBuildPage {
        try requireFeedbackScope(appId: appId, client: client)
        let path = try Self.releaseBuildsPath(appId: appId, platform: platform, version: version)
        async let attachedRead = attachedBuildId(versionId: versionId, appId: appId, client: client)
        let page: (data: [AppStoreConnectClient.Resource], included: [AppStoreConnectClient.Resource], more: Bool)
        if all { let every = try await client.listWithIncluded(path); page = (every.data, Self.mergedIncluded(every.included), false) } else { page = try await client.firstPageWithIncluded(path) }
        let owned = try await scopedOwners(page.data, type: "builds", appId: appId) { try await client.list($0) }
        // Apple's filter is checked again here: only builds whose pre-release version names this platform and version are shown.
        var builds = try TestFlightObservation.models(appId: appId, builds: owned, included: page.included, declarations: nil).filter { $0.platform == platform && $0.appVersion == version }
        let attachedId = try await attachedRead
        if let attachedId, !builds.contains(where: { $0.id == attachedId }) {
            let one = try await client.listWithIncluded("/v1/builds?filter%5Bapp%5D=\(appId)&filter%5Bid%5D=\(attachedId)&include=app%2CpreReleaseVersion&limit=200")
            let scoped = try await scopedOwners(one.data.filter { $0.id == attachedId }, type: "builds", appId: appId) { try await client.list($0) }
            builds += try TestFlightObservation.models(appId: appId, builds: scoped, included: one.included, declarations: nil)
        }
        try requireFeedbackScope(appId: appId, client: client)
        return ReleaseBuildPage(builds: builds.sorted { $0.uploadedDate > $1.uploadedDate }, attachedId: attachedId, complete: !page.more)
    }

    /// Apple repeats an included resource on every page that links to it. Identical copies count once; copies that differ are all kept,
    /// so a build linked to them stays without a confirmed version.
    static func mergedIncluded(_ included: [AppStoreConnectClient.Resource]) -> [AppStoreConnectClient.Resource] {
        var seen: [String: String] = [:], result: [AppStoreConnectClient.Resource] = []
        for item in included {
            let key = item.type + "\u{0}" + item.id, value = Planner.resource(item).stringify()
            if let known = seen[key], known == value { continue }
            seen[key] = seen[key] == nil ? value : "\u{0}differs"
            result.append(item)
        }
        return result
    }

    private func attachedBuildId(versionId: String?, appId: String, client: AppStoreConnectClient) async throws -> String? {
        guard let versionId else { return nil }
        return try await versionBuildId(versionId: versionId, appId: appId, client: client)
    }

    /// After a Save to App Store Connect, which clears every shared read, reads again in the background what the release steps after
    /// `step` show: the version's builds, App Review Information and Add for Review's choices, so each opens with Apple's current answer at once.
    /// Only shared read-only responses are warmed; every review still reads Apple itself, and nothing is written.
    public func warmReleaseSteps(after step: String, account: Account, appId: String, versionId: String?, plan: ReleasePlan?) async {
        await AppleReadPriority.$current.withValue(.next) { await warmingReleaseSteps(after: step, account: account, appId: appId, versionId: versionId, plan: plan) }
    }
    private func warmingReleaseSteps(after step: String, account: Account, appId: String, versionId: String?, plan: ReleasePlan?) async {
        guard let client = try? readClient(for: account) else { return }
        let order = ["plan", "listing", "send", "build", "review-information", "submit", "release"]
        let later = Set(order.drop { $0 != step })
        await withTaskGroup(of: Void.self) { group in
            if let plan, !later.isDisjoint(with: ["send", "build", "submit"]) {
                group.addTask { _ = try? await self.releaseBuildPage(appId: appId, versionId: versionId, platform: plan.platform, version: plan.targetVersion, all: false, client: client) }
            }
            if let versionId, !later.isDisjoint(with: ["build", "review-information"]) {
                group.addTask { _ = try? await self.reviewInformationSnapshot(account: account, appId: appId, versionId: versionId, client: client) }
            }
            if !later.isDisjoint(with: ["review-information", "submit"]) {
                group.addTask { _ = try? await self.publishingWorkspace(account: account, appId: appId, includeBuilds: true, client: client) }
            }
        }
    }
}
