import Foundation

extension WorkspaceSession {
    /// An app without a release plan whose latest import has a version still in progress at Apple, such as one Developer Rejected
    /// or Waiting for Review, gets the plan Continue Release would make for it, so the release shows in Release and Overview and
    /// its status can be refreshed. Only the local plan is saved; nothing is sent to App Store Connect. A version Apple has released
    /// since, per `versions`, is not continued, and neither is one whose plan the person removed.
    @discardableResult
    public func continueReleaseInProgress(account: Account, appId: String, versions: [PublishingWorkspace.Version]? = nil, now: Date = Date()) throws -> ReleasePlan? {
        guard account.appIds.contains(appId), try releasePlan(accountId: account.id, appId: appId) == nil else { return nil }
        let history = try revisions(accountId: account.id, appId: appId)
        let candidates = ReleaseSetup.candidates(history)
        guard let latest = candidates.first(where: { !$0.revision.isLocalDraft })?.revision.id,
              let current = candidates.first(where: { $0.revision.id == latest && $0.canContinue }) else { return nil }
        if let live = versions?.first(where: { PublishingWorkspace.equal($0.platform, current.version.platform) && PublishingWorkspace.equal($0.number, current.version.number) }),
           LibraryOverview.released.contains(live.state) { return nil }
        guard try !releasePlanDismissed(accountId: account.id, appId: appId, platform: current.version.platform, version: current.version.number) else { return nil }
        let inputs = ReleaseSetup.inputs(.reuse, current, history: history, date: now)
        return try saveReleasePlan(account: account, appId: appId, start: .reuse, sourceRevisionId: inputs.sourceRevisionId, baseVersionId: inputs.baseVersionId,
                                   targetVersion: inputs.targetVersion, releaseType: inputs.releaseType,
                                   earliestReleaseDate: inputs.releaseType == "SCHEDULED" ? inputs.date : nil, expected: nil, now: now)
    }

    /// Removes a plan the person chose to remove, and remembers its version so it is not continued again by itself.
    public func dismissReleasePlan(accountId: String, appId: String, expected: String) throws {
        let plan = try releasePlan(accountId: accountId, appId: appId)
        try removeReleasePlan(accountId: accountId, appId: appId, expected: expected)
        guard let plan else { return }
        let key = "\(accountId):\(appId)"
        try storeAccess { store in
            try store.transaction { current in
                let saved = try current("release_plan_dismissals", key).map { try JSONText.parse($0.payload) }
                let entries = (saved.flatMap { value -> [JSONText]? in if case .array(let items)? = value["versions"] { items } else { nil } } ?? []).suffix(49)
                let entry = JSONText.object([("platform", .string(plan.platform)), ("version", .string(plan.targetVersion))])
                return [.put(namespace: "release_plan_dismissals", key: key, json: JSONText.object([("versions", .array(Array(entries) + [entry]))]).data)]
            }
        }
    }

    func releasePlanDismissed(accountId: String, appId: String, platform: String, version: String) throws -> Bool {
        try storeAccess { store in
            guard let document = try store.document(namespace: "release_plan_dismissals", key: "\(accountId):\(appId)"),
                  case .array(let items)? = try JSONText.parse(document.payload)["versions"] else { return false }
            return items.contains { $0["platform"]?.text == platform && $0["version"]?.text == version }
        }
    }
}
