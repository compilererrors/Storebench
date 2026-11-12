import Foundation

/// A compact release card: Apple's state, confirmed work to finish, and checks that are still unknown.
public struct ReleaseOverview: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public let id, title, detail, kind: String
    }
    public let version, platform: String
    public let appleState: String?
    public let hasPlan, checking, failed: Bool
    public let checkedAt: Date?
    public let items: [Item]
    public var preview: [Item] { Array(items.prefix(3)) }
    public var moreCount: Int { max(0, items.count - 3) }
    public var submitted: Bool { appleState.map(ReleaseReadiness.submitted.contains) == true }
    public var status: String {
        if let appleState { return appleState.isEmpty ? "Unknown" : AppStoreNames.state(appleState) }
        return hasPlan ? "Saved on This Mac" : checkedAt == nil ? "Not Checked" : "No App Store Version"
    }
    public var action: String { hasPlan ? "Continue Release" : "Open Release" }
    public var detail: String {
        if !items.isEmpty {
            let missing = items.filter { $0.kind == "blocked" }.count
            return missing > 0 ? "\(missing) \(missing == 1 ? "item needs" : "items need") action" : "Review the remaining release requirements"
        }
        if appleState.map(ReleaseReadiness.submitted.contains) == true { return "Follow this version in Release" }
        return hasPlan ? "Open Release to continue" : "Prepare or follow an App Store version"
    }

    public init(plan: ReleasePlan?, snapshot: ReleaseReadinessSnapshot?, status: AppReleaseStatus?, checking: Bool = false, readinessCheckedAt: Date? = nil) {
        let snapshot = snapshot.flatMap { value -> ReleaseReadinessSnapshot? in
            guard let plan, value.plan.token == plan.token, value.scope.accountId == plan.accountId, value.scope.appId == plan.appId else { return nil }
            return value
        }
        let version = status?.version(for: plan)
        self.version = plan?.targetVersion ?? version?.number ?? ""
        platform = plan?.platform ?? version?.platform ?? ""
        hasPlan = plan != nil; self.checking = checking
        failed = status?.failed == true && (status?.attemptedAt ?? .distantPast) >= (readinessCheckedAt ?? .distantPast)
        checkedAt = [status?.checkedAt, readinessCheckedAt].compactMap { $0 }.max()
        let appleState = snapshot?.targetState ?? version?.state
        self.appleState = appleState
        guard let plan else { items = []; return }
        guard let snapshot, snapshot.plan.token == plan.token, snapshot.scope.accountId == plan.accountId, snapshot.scope.appId == plan.appId else {
            items = [.init(id: "checks", title: "Check Release Requirements", detail: "Open Release to check this saved version's text, screenshots, build and App Review Information.", kind: "unknown")]; return
        }
        let guide = ReleaseGuide.guide(snapshot.steps, appleState: appleState)
        let steps = guide.phases.filter { $0.id != "release" && (!$0.locked || appleState == "WAITING_FOR_EXPORT_COMPLIANCE" && $0.id == "build") }.flatMap(\.steps)
        var pending: [Item] = []
        for state: ReleaseReadiness.State in [.blocked, .manual, .review] {
            for step in steps where step.state == state && step.id != "submission" && !ReleaseGuide.satisfied(step) {
                if state == .blocked, !step.issues.isEmpty {
                    let locale = step.id.hasPrefix("local:") ? String(step.id.dropFirst(6)) : ""
                    pending += step.issues.map { issue in
                        let name = issue.field == "screenshots" ? "Previews and Screenshots" : TextDrafts.labels[issue.field] ?? issue.field
                        return Item(id: step.id + ":" + issue.field, title: (locale.isEmpty ? "" : StoreLocales.name(locale) + " · ") + name,
                                    detail: ReleaseMaterial.presented(issue).message, kind: state.rawValue)
                    }
                } else { pending.append(.init(id: step.id, title: step.label, detail: step.detail, kind: state.rawValue)) }
            }
        }
        if ["REJECTED", "METADATA_REJECTED"].contains(appleState ?? "") {
            pending.insert(.init(id: "app-review-feedback", title: "App Review Feedback", detail: "Read Apple's App Review feedback before preparing the next submission.", kind: "blocked"), at: 0)
        }
        let unknown = steps.filter { $0.state == .unknown }.count
        if unknown > 0 { pending.append(.init(id: "checks", title: "\(unknown) Release \(unknown == 1 ? "Check" : "Checks") Pending", detail: "These requirements have not been confirmed yet. Open Release to check them; they are not confirmed missing fields.", kind: "unknown")) }
        var seen = Set<String>()
        items = pending.filter { seen.insert($0.id).inserted }
    }
}

extension WorkspaceSession {
    /// Builds from saved local edits and existing Apple observations. No network, imports or Apple changes.
    func releaseOverview(account: Account, appId: String) -> ReleaseOverview? {
        do {
            let plan = try releasePlan(accountId: account.id, appId: appId), status = appReleaseStatus(account: account, appId: appId)
            let earlier = plan.flatMap { rememberedReleaseReadiness(accountId: account.id, appId: appId, planToken: $0.token) }
            let snapshot = plan.flatMap { try? overviewReadiness(account: account, appId: appId, plan: $0, status: status, earlier: earlier) }
            return ReleaseOverview(plan: plan, snapshot: snapshot, status: status, checking: appReleaseChecking.contains(account.id + ":" + appId), readinessCheckedAt: earlier?.checkedAt)
        } catch { return nil }
    }
}
