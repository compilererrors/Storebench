import Foundation

extension WorkspaceSession {
    /// Reads in the background what the screens behind Apple's problems show, so the one the user opens to fix it appears at once.
    /// Only shared read-only responses are warmed; every editor and review still reads Apple itself, and nothing is written.
    /// `versionId` names the version whose App Review Information is warmed; without it that area is left out.
    public func warmProblemScreens(_ areas: Set<AppleProblem.Area>, account: Account, appId: String, versionId: String? = nil) async {
        await AppleReadPriority.$current.withValue(.next) { await warmingProblemScreens(areas, account: account, appId: appId, versionId: versionId) }
    }
    private func warmingProblemScreens(_ areas: Set<AppleProblem.Area>, account: Account, appId: String, versionId: String?) async {
        guard !areas.isEmpty, let client = try? readClient(for: account) else { return }
        await withTaskGroup(of: Void.self) { group in
            if areas.contains(.pricing) { group.addTask { _ = try? await self.pricingSetupState(account: account, appId: appId, fresh: false) } }
            if areas.contains(.ageRating) { group.addTask { _ = try? await self.ageRatingAnswers(appId: appId, client: client) } }
            if areas.contains(.reviewInformation), let versionId { group.addTask { _ = try? await self.reviewInformationSnapshot(account: account, appId: appId, versionId: versionId, client: client) } }
            if areas.contains(.accessibility) { group.addTask { _ = try? await self.accessibilityDeclarations(appId: appId, client: client) } }
            if !areas.isDisjoint(with: [.appConfiguration, .availability]) {
                group.addTask { _ = try? await self.appInformationState(appId: appId, categories: areas.contains(.appConfiguration), availability: areas.contains(.availability), client: client) }
            }
            if !areas.isDisjoint(with: [.build, .exportCompliance]) { group.addTask { _ = try? await self.testFlightBuilds(appId: appId, client: client) } }
            if !areas.isDisjoint(with: [.listing, .copyright, .version]) { group.addTask { _ = try? await self.publishingWorkspace(account: account, appId: appId, client: client) } }
        }
    }
}
