import Foundation

/// A small, account-scoped observation of Apple's versions. Listing text and media remain in their revision stores.
public struct AppReleaseStatus: Codable, Sendable, Equatable {
    public struct Version: Codable, Sendable, Equatable {
        public let id, platform, number, state, releaseType, copyright: String
        init(_ value: PublishingWorkspace.Version) {
            id = value.id; platform = value.platform; number = value.number; state = value.state
            releaseType = value.releaseType; copyright = value.copyright
        }
        var json: JSONText { .object([("id", .string(id)), ("platform", .string(platform)), ("number", .string(number)),
            ("state", .string(state)), ("releaseType", .string(releaseType)), ("copyright", .string(copyright))]) }
    }
    let schemaVersion: Int
    let accountId, appId, accountToken: String
    public let versions: [Version]
    public let checkedAt: Date?, attemptedAt: Date, failed: Bool

    init(account: Account, appId: String, versions: [PublishingWorkspace.Version]?, previous: Self?, at: Date) {
        schemaVersion = 1; accountId = account.id; self.appId = appId; accountToken = ConnectedApps.AccountSnapshot(account).token
        self.versions = versions.map { $0.map(Version.init) } ?? previous?.versions ?? []
        checkedAt = versions == nil ? previous?.checkedAt : at; attemptedAt = at; failed = versions == nil
    }
    func valid(account: Account, appId: String) -> Bool {
        schemaVersion == 1 && accountId == account.id && self.appId == appId && accountToken == ConnectedApps.AccountSnapshot(account).token
            && attemptedAt.timeIntervalSince1970.isFinite && checkedAt.map { $0.timeIntervalSince1970.isFinite && $0 <= attemptedAt } != false
            && (failed || checkedAt != nil) && (checkedAt != nil || versions.isEmpty)
            && versions.count <= 2000 && Set(versions.map(\.id)).count == versions.count && versions.allSatisfy {
                AppOverviewMaterial.identifier($0.id) && !$0.platform.isEmpty && $0.platform.utf16.count <= 24
                    && !$0.number.isEmpty && $0.number.utf16.count <= 64 && $0.state.utf16.count <= 128
                    && $0.releaseType.utf16.count <= 64 && $0.copyright.utf16.count <= 1024
            }
    }
    public func version(for plan: ReleasePlan?) -> Version? {
        if let plan {
            guard plan.accountId == accountId, plan.appId == appId else { return nil }
            return versions.first { $0.platform == plan.platform && $0.number == plan.targetVersion }
        }
        // An old rejection must never outrank a newer published version of the same platform.
        let latest = Dictionary(grouping: versions, by: \.platform).values.compactMap { rows in
            rows.max { $0.number.compare($1.number, options: .numeric) == .orderedAscending }
        }
        return latest.sorted {
            let left = LibraryOverview.released.contains($0.state), right = LibraryOverview.released.contains($1.state)
            if left != right { return !left }
            if $0.number != $1.number { return $0.number.compare($1.number, options: .numeric) == .orderedDescending }
            return $0.platform < $1.platform
        }.first
    }
}

extension WorkspaceSession {
    private static let appReleaseNamespace = "app_release_status"
    func appReleaseStatus(account: Account, appId: String) -> AppReleaseStatus? {
        guard (try? currentAccount(account, exact: true)) != nil, account.appIds.contains(appId),
              let data = try? storeAccess({ try $0.document(namespace: Self.appReleaseNamespace, key: account.id + ":" + appId)?.payload }),
              data.count <= 1024 * 1024, let value = try? JSONDecoder().decode(AppReleaseStatus.self, from: data), value.valid(account: account, appId: appId) else { return nil }
        return value
    }
    /// The previous confirmation survives a failed check. Read, stale comparison and replacement share the permanent OS mutex.
    func rememberAppReleaseStatus(account: Account, appId: String, versions: [PublishingWorkspace.Version]?, at: Date) {
        guard !Task.isCancelled else { return }
        do {
            _ = try currentAccount(account, exact: true); try requireHistoryScope(accountId: account.id, appId: appId)
            let key = account.id + ":" + appId
            let mutex = try storeAccess { $0.directory.appendingPathComponent("app_release_status_\(JSONText.string(key).rawSHA256.prefix(32)).mutex") }
            try FileMutex.withLock(mutex) {
                _ = try currentAccount(account, exact: true); try requireHistoryScope(accountId: account.id, appId: appId)
                let previous = appReleaseStatus(account: account, appId: appId)
                guard previous.map({ $0.attemptedAt > at }) != true else { return }
                let next = AppReleaseStatus(account: account, appId: appId, versions: versions, previous: previous, at: at)
                guard next.valid(account: account, appId: appId) else { return }
                let data = try JSONEncoder().encode(next)
                guard data.count <= 1024 * 1024 else { return }
                try storeAccess { store in try store.transaction { _ in [.put(namespace: Self.appReleaseNamespace, key: key, json: data)] } }
            }
            appReleaseReads.insert(key)
        } catch { /* A status cache never prevents a live read or an editor from opening. */ }
    }

    /// Two small reads at a time, behind visible work. A new session confirms every app again; later ticks reuse fresh results.
    /// `first` names the cards on screen, as "account:app", which are read before any other app. Without `limit`, the Performance
    /// setting decides how many apps one check reads.
    public func refreshReleaseOverviews(limit: Int? = nil, maxAge: TimeInterval = 60, now: Date = Date(), first: [String] = []) async {
        await refreshReleaseOverviews(limit: limit, maxAge: maxAge, now: now, first: first, clients: { account in try await self.readClient(for: account) })
    }
    /// Reads one app's release status at once, as when its card is expanded, unless it was read in the last `maxAge` seconds.
    public func checkReleaseStatus(accountId: String, appId: String, maxAge: TimeInterval = 30) async {
        await checkReleaseStatus(accountId: accountId, appId: appId, maxAge: maxAge, clients: { account in try await self.readClient(for: account) })
    }
    func checkReleaseStatus(accountId: String, appId: String, maxAge: TimeInterval = 30, now: Date = Date(),
                            clients: @escaping @Sendable (Account) async throws -> AppStoreConnectClient) async {
        guard !isSample, let account = (try? accounts())?.first(where: { $0.id == accountId }), account.appIds.contains(appId) else { return }
        if appReleaseReads.contains(accountId + ":" + appId), let attempted = appReleaseStatus(account: account, appId: appId)?.attemptedAt,
           now.timeIntervalSince(attempted) < maxAge { return }
        await AppleReadPriority.$current.withValue(.next) {
            await refreshReleaseOverview(account: account, appId: appId, requested: true, clients: clients)
        }
    }
    /// The apps to check: the cards on screen first, then apps with a saved release plan because their cards lead Overview,
    /// then the longest unchecked.
    func releaseOverviewTargets(limit: Int? = nil, maxAge: TimeInterval = 60, now: Date = Date(), first: [String] = []) -> [(account: Account, appId: String, planned: Bool)] {
        guard !isSample, let accounts = try? accounts() else { return [] }
        let candidates = accounts.flatMap { account in account.apps.map { app in
            (account: account, appId: app.id, attempted: appReleaseStatus(account: account, appId: app.id)?.attemptedAt,
             planned: (try? releasePlan(accountId: account.id, appId: app.id)) != nil)
        } }
        let shown = Dictionary(first.enumerated().map { ($1, $0) }, uniquingKeysWith: { earlier, _ in earlier })
        return candidates.filter { candidate in
            !appReleaseReads.contains(candidate.account.id + ":" + candidate.appId) || candidate.attempted.map { now.timeIntervalSince($0) >= maxAge } != false
        }.sorted { left, right in
            let leftShown = shown[left.account.id + ":" + left.appId], rightShown = shown[right.account.id + ":" + right.appId]
            if leftShown != nil || rightShown != nil { return (leftShown ?? .max) < (rightShown ?? .max) }
            return left.planned != right.planned ? left.planned : (left.attempted ?? .distantPast) < (right.attempted ?? .distantPast)
        }.prefix(max(0, min(100, limit ?? cacheBudget.releaseStatusChecks))).map { ($0.account, $0.appId, $0.planned) }
    }
    func refreshReleaseOverviews(limit: Int? = nil, maxAge: TimeInterval = 60, now: Date = Date(), first: [String] = [],
                                clients: @escaping @Sendable (Account) async throws -> AppStoreConnectClient) async {
        let targets = releaseOverviewTargets(limit: limit, maxAge: maxAge, now: now, first: first)
        guard !targets.isEmpty else { return }
        // A planned release is on the first screen, so it is read as the likely next step; other apps fill in behind it.
        func check(_ target: (account: Account, appId: String, planned: Bool)) async {
            await AppleReadPriority.$current.withValue(target.planned ? .next : .background) {
                await self.refreshReleaseOverview(account: target.account, appId: target.appId, clients: clients)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            var iterator = targets.makeIterator()
            for _ in 0..<2 { if let target = iterator.next() { group.addTask { await check(target) } } }
            while await group.next() != nil {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let target = iterator.next() { group.addTask { await check(target) } }
            }
        }
    }
    /// `requested` is a read the user asked for, such as by expanding a card, rather than one read ahead in the background.
    private func refreshReleaseOverview(account: Account, appId: String, requested: Bool = false, clients: @Sendable (Account) async throws -> AppStoreConnectClient) async {
        let key = account.id + ":" + appId
        guard !Task.isCancelled, !appReleaseChecking.contains(key), requested || AppleRequestBudget.allowsReadingAhead(keyId: account.keyId) else { return }
        appReleaseChecking.insert(key); defer { appReleaseChecking.remove(key) }
        let at = Date()
        do {
            let client = try await clients(account)
            let versions = try await AppStoreReadCache.$revalidatedSince.withValue(.now) { try await currentAppVersions(account: account, appId: appId, client: client) }
            rememberAppReleaseStatus(account: account, appId: appId, versions: versions, at: at)
            if let plan = try? releasePlan(accountId: account.id, appId: appId), LibraryOverview.planState(plan, versions: versions).released {
                try? removeReleasePlan(accountId: account.id, appId: appId, expected: plan.token)
            } else {
                // A version still in progress at Apple, such as one Developer Rejected, is followed even without a plan made here.
                try? continueReleaseInProgress(account: account, appId: appId, versions: versions)
            }
        } catch { if !Task.isCancelled { rememberAppReleaseStatus(account: account, appId: appId, versions: nil, at: at) } }
    }
}
