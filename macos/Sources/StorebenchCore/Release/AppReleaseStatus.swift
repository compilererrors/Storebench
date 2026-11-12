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
    public func refreshReleaseOverviews(limit: Int = 20, maxAge: TimeInterval = 60, now: Date = Date()) async {
        await refreshReleaseOverviews(limit: limit, maxAge: maxAge, now: now, clients: { account in try await self.readClient(for: account) })
    }
    func refreshReleaseOverviews(limit: Int = 20, maxAge: TimeInterval = 60, now: Date = Date(),
                                clients: @escaping @Sendable (Account) async throws -> AppStoreConnectClient) async {
        guard !isSample, let accounts = try? accounts() else { return }
        let candidates = accounts.flatMap { account in account.apps.map { app in
            (account, app.id, appReleaseStatus(account: account, appId: app.id)?.attemptedAt)
        } }
        let targets = candidates.filter { account, appId, attempted in
            !appReleaseReads.contains(account.id + ":" + appId) || attempted.map { now.timeIntervalSince($0) >= maxAge } != false
        }.sorted { ($0.2 ?? .distantPast) < ($1.2 ?? .distantPast) }.prefix(max(0, min(100, limit)))
        await AppleReadPriority.$current.withValue(.background) {
            await withTaskGroup(of: Void.self) { group in
                var iterator = targets.makeIterator()
                for _ in 0..<2 { if let target = iterator.next() { group.addTask { await self.refreshReleaseOverview(account: target.0, appId: target.1, clients: clients) } } }
                while await group.next() != nil {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    if let target = iterator.next() { group.addTask { await self.refreshReleaseOverview(account: target.0, appId: target.1, clients: clients) } }
                }
            }
        }
    }
    private func refreshReleaseOverview(account: Account, appId: String, clients: @Sendable (Account) async throws -> AppStoreConnectClient) async {
        let key = account.id + ":" + appId
        guard !Task.isCancelled, !appReleaseChecking.contains(key), AppleRequestBudget.allowsReadingAhead(keyId: account.keyId) else { return }
        appReleaseChecking.insert(key); defer { appReleaseChecking.remove(key) }
        let at = Date()
        do {
            let client = try await clients(account)
            let versions = try await AppStoreReadCache.$revalidatedSince.withValue(.now) { try await currentAppVersions(account: account, appId: appId, client: client) }
            rememberAppReleaseStatus(account: account, appId: appId, versions: versions, at: at)
            if let plan = try? releasePlan(accountId: account.id, appId: appId), LibraryOverview.planState(plan, versions: versions).released {
                try? removeReleasePlan(accountId: account.id, appId: appId, expected: plan.token)
            }
        } catch { if !Task.isCancelled { rememberAppReleaseStatus(account: account, appId: appId, versions: nil, at: at) } }
    }
}
