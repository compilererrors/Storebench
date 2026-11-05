import Foundation

extension WorkspaceSession {
    /// The app's TestFlight builds and the build attached to the version, for Release's build step. `latest` reads past the shared
    /// cache, for the check that confirms Apple's newest answer; otherwise the shared read is used and read again if a refresh cancelled it.
    public func releaseBuilds(account: Account, appId: String, versionId: String?, latest: Bool) async throws -> (builds: [TestFlightBuild], attachedId: String?) {
        let client = latest ? try client(for: account) : try readClient(for: account)
        let builds = try await AppStoreReadCache.rereadingAfterInvalidation { try await testFlightBuilds(appId: appId, client: client) }
        guard let versionId else { return (builds, nil) }
        return (builds, try await versionBuildId(versionId: versionId, appId: appId, client: client))
    }

    /// After a Save to App Store Connect, which clears every shared read, reads again in the background what the release steps after
    /// `step` show: the builds, App Review Information and Add for Review's choices, so each opens with Apple's current answer at once.
    /// Only shared read-only responses are warmed; every review still reads Apple itself, and nothing is written.
    public func warmReleaseSteps(after step: String, account: Account, appId: String, versionId: String?) async {
        guard let client = try? readClient(for: account) else { return }
        let order = ["plan", "listing", "send", "build", "review-information", "submit", "release"]
        let later = Set(order.drop { $0 != step })
        await withTaskGroup(of: Void.self) { group in
            if !later.isDisjoint(with: ["send", "build", "submit"]) { group.addTask { _ = try? await self.testFlightBuilds(appId: appId, client: client) } }
            if let versionId, !later.isDisjoint(with: ["build", "review-information"]) {
                group.addTask { _ = try? await self.reviewInformationSnapshot(account: account, appId: appId, versionId: versionId, client: client) }
            }
            if !later.isDisjoint(with: ["review-information", "submit"]) {
                group.addTask { _ = try? await self.publishingWorkspace(account: account, appId: appId, includeBuilds: true, client: client) }
            }
        }
    }
}
