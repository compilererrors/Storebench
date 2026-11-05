import Foundation

/// Global library projections are local reads; scoped editors and existing jobs retain their own services.
public enum LibraryOverview {
    public enum Section: String, CaseIterable, Sendable {
        case overview = "Overview", apps = "Connected apps", sales = "Sales across apps", history = "History"
        public var selection: String { "library:" + String(describing: self) }
        public static func selected(_ value: String?) -> Section? { value == nil ? .overview : allCases.first { $0.selection == value } }
    }
    public enum Content: Equatable, Sendable { case connection, library(Section), chooser(AppNavigation.Section), app, empty }
    public static func content(selection: String?, connecting: Bool, hasApp: Bool) -> Content {
        if connecting { return .connection }
        if let section = Section.selected(selection) { return .library(section) }
        if let section = LibraryChooser.selected(selection) { return .chooser(section) }
        return hasApp ? .app : .empty
    }
    public struct Release: Identifiable, Sendable, Equatable, Codable {
        public let app: ConnectedApps.Row, plan: ReleasePlan
        public var id: String { app.id }
        public var title: String { app.name + " · " + plan.targetVersion }
    }
    public struct Snapshot: Sendable, Equatable, Codable {
        public let apps: [ConnectedApps.Row], releases: [Release], accountCount: Int, plansUnavailable: Bool
        public var materialApps: Int? { apps.contains { $0.revisionCount == nil } ? nil : apps.filter { ($0.revisionCount ?? 0) > 0 }.count }
        public var awaitingMaterialApps: Int? { materialApps.map { apps.count - $0 } }
        public var releaseCount: Int? { plansUnavailable ? nil : releases.count }
        public init(apps: [ConnectedApps.Row], plans: [ReleasePlan], accountCount: Int, plansUnavailable: Bool = false) throws {
            guard accountCount >= Set(apps.map { $0.account.id }).count,
                  Set(apps.map(\.id)).count == apps.count, !plansUnavailable || plans.isEmpty else { throw ConnectedApps.Failure.changed }
            var scopes = Set<String>()
            for plan in plans { guard scopes.insert(plan.accountId + "/" + plan.appId).inserted else { throw ConnectedApps.Failure.changed } }
            self.apps = apps; self.accountCount = accountCount; self.plansUnavailable = plansUnavailable
            let owned = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
            releases = plans.sorted { $0.updatedAt > $1.updatedAt }.compactMap { plan in
                owned[plan.accountId + "/" + plan.appId].map { Release(app: $0, plan: plan) }
            }
        }
    }
    public struct Destination: Sendable {
        public let row: ConnectedApps.Row, section: AppNavigation.Section, plan: ReleasePlan?
        public init(row: ConnectedApps.Row, section: AppNavigation.Section, plan: ReleasePlan? = nil) throws {
            guard ([.overview, .history] + LibraryChooser.sections).contains(section),
                  plan.map({ section == .release && $0.accountId == row.account.id && $0.appId == row.app.id }) ?? true else { throw ConnectedApps.Failure.changed }
            self.row = row; self.section = section; self.plan = plan
        }
        public var href: String { section.href(scope: try! .init(accountId: row.account.id, appId: row.app.id)) }
        public func allowed(accounts: [Account], decision: EditorProtectionPolicy.Decision, discardConfirmed: Bool = false) -> Bool {
            guard decision == .ready || decision == .confirmDiscard && discardConfirmed else { return false }
            return accounts.contains { $0 == row.account }
        }
    }
    public static func timestamp(_ value: String) -> String {
        guard let date = ReportTimestamps.date(value) else { return "Unknown time" }
        return String(ReportTimestamps.isoUtcText(date).prefix(16)).replacingOccurrences(of: "T", with: " ") + " UTC"
    }
    public static func plans(_ values: [JSONText]) throws -> [ReleasePlan] {
        guard values.count <= 2000 else { throw ConnectedApps.Failure.changed }
        var scopes = Set<String>()
        return try values.map { value in
            guard let plan = ReleasePlan(value),
                  plan.accountId.range(of: #"\A[a-zA-Z0-9_-]+\z"#, options: .regularExpression) != nil,
                  plan.appId.range(of: #"\A[0-9]+\z"#, options: .regularExpression) != nil,
                  plan.sourceRevisionId.range(of: #"\A[a-f0-9-]{36}\z"#, options: .regularExpression) != nil,
                  !plan.baseVersionId.isEmpty, plan.baseVersionId.utf16.count <= 256,
                  plan.platform.range(of: #"\A[A-Z_]{2,24}\z"#, options: .regularExpression) != nil,
                  !plan.targetVersion.isEmpty, plan.targetVersion.utf16.count <= 32, TextSemantics.trim(plan.targetVersion) == plan.targetVersion,
                  !plan.targetVersion.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  ReportTimestamps.valid(plan.updatedAt), scopes.insert(plan.accountId + "/" + plan.appId).inserted else { throw ConnectedApps.Failure.changed }
            let type = value["releaseType"] == .null || value["releaseType"] == nil ? "MANUAL" : value["releaseType"]?.text
            guard let type, Releases.releaseTypes.contains(where: { $0.0 == type }) else { throw ConnectedApps.Failure.changed }
            let earliest = value["earliestReleaseDate"]
            if type == "SCHEDULED" {
                guard let text = earliest?.text, text.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,3})?Z\z"#, options: .regularExpression) != nil,
                      let date = ReportTimestamps.date(text) else { throw ConnectedApps.Failure.changed }
                guard ReportTimestamps.isoUtcText(date).prefix(19) == text.prefix(19) else { throw ConnectedApps.Failure.changed }
            } else { guard earliest == nil || earliest == .null || earliest == .string("") else { throw ConnectedApps.Failure.changed } }
            return plan
        }
    }
}

extension WorkspaceSession {
    public func libraryOverview() throws -> LibraryOverview.Snapshot {
        let configured = try accounts(), rows = try connectedApps()
        var plans: [ReleasePlan] = [], unavailable = false
        do { plans = try storeAccess { try LibraryOverview.plans(plansDocument($0).plans) } }
        catch { try requireSessionAccess(); try Task.checkCancellation(); unavailable = true }
        for row in rows { try validateConnectedApp(row) }
        guard try accounts() == configured else { throw ConnectedApps.Failure.changed }
        return try .init(apps: rows, plans: plans, accountCount: configured.count, plansUnavailable: unavailable)
    }
    public func validateLibraryDestination(_ destination: LibraryOverview.Destination) throws {
        try validateConnectedApp(destination.row)
        if let plan = destination.plan {
            guard try releasePlan(accountId: plan.accountId, appId: plan.appId)?.token == plan.token else { throw ConnectedApps.Failure.changed }
        }
        try Task.checkCancellation(); try requireSessionAccess()
    }
}

extension LibraryOverview {
    /// What App Store Connect reports for a plan's own version: its state code, empty when the version is not there yet.
    public struct PlanState: Sendable, Equatable, Codable {
        public let planToken, state: String
        public var released: Bool { LibraryOverview.released.contains(state) }
    }
    /// The states in which Apple has released a version; a plan for it has nothing left to prepare.
    public static let released: Set<String> = ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION"]
    public static func planState(_ plan: ReleasePlan, versions: [PublishingWorkspace.Version]) -> PlanState {
        let match = versions.first { PublishingWorkspace.equal($0.platform, plan.platform) && PublishingWorkspace.equal($0.number, plan.targetVersion) }
        return PlanState(planToken: plan.token, state: match?.state ?? "")
    }
    /// The card line for a plan: the Apple state once read, the local draft until then.
    public static func planDescription(_ plan: ReleasePlan, state: PlanState?) -> String {
        let platform = Releases.platformName(plan.platform)
        guard let state, state.planToken == plan.token else { return platform + " · Local draft · Checking App Store Connect…" }
        return platform + " · " + (state.state.isEmpty ? "Not in App Store Connect yet" : AppStoreNames.state(state.state))
    }
}

extension WorkspaceSession {
    /// Reads each plan's version from App Store Connect, one read per app. A plan whose version Apple has released is closed;
    /// its local version and drafts stay saved. A read that fails leaves that plan's state unknown and the plan untouched.
    public func releasePlanStates(_ releases: [LibraryOverview.Release]) async -> (states: [String: LibraryOverview.PlanState], closed: [LibraryOverview.Release]) {
        var states: [String: LibraryOverview.PlanState] = [:], closed: [LibraryOverview.Release] = []
        for release in releases {
            guard !Task.isCancelled else { break }
            guard let state = await checkReleasePlan(account: release.app.account, plan: release.plan) else { continue }
            states[release.id] = state
            if state.released { closed.append(release) }
        }
        return (states, closed)
    }
    /// One plan: its version's state at Apple, closing the plan when Apple has released that version. Nil when the read fails.
    public func checkReleasePlan(account: Account, plan: ReleasePlan) async -> LibraryOverview.PlanState? {
        do {
            let versions = try await currentAppVersions(account: account, appId: plan.appId, client: try readClient(for: account))
            let state = LibraryOverview.planState(plan, versions: versions)
            if state.released { try removeReleasePlan(accountId: plan.accountId, appId: plan.appId, expected: plan.token) }
            return state
        } catch { return nil }
    }
}
