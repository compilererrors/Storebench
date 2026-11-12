import Foundation

/// Discovery of apps the configured API keys can access. Version state does not restrict this list.
public struct AppCatalogRefresh: Sendable, Equatable {
    public struct Issue: Sendable, Equatable {
        public let accountId, accountName: String
        public let reason: AccountFailure
    }
    public let accounts, refreshedAccounts, appCount: Int
    public let issues: [Issue]
    public let sample: Bool
    public var complete: Bool { issues.isEmpty }
    public var message: String {
        if sample { return "Sample apps reread. Sample data does not contact App Store Connect." }
        if accounts == 0 { return "Connect an Apple account to read its apps from App Store Connect." }
        if !complete {
            return "Refreshed \(refreshedAccounts) of \(accounts) accounts. Apps saved for accounts that failed are still shown. "
                + issues.map { "\($0.accountName): \($0.reason.message)" }.joined(separator: " ")
        }
        return "App list refreshed from App Store Connect: \(appCount) \(appCount == 1 ? "app" : "apps"). Apps preparing their first release are included."
    }
    public static func failureMessage(_ error: Error) -> String {
        (AccountFailure.classify(error) as? AccountFailure)?.message ?? "The app list could not be refreshed. Your saved apps are still available; try again."
    }
}

extension WorkspaceSession {
    /// Explicit discovery reads past the response cache. The existing account writer rechecks the connection under its mutex.
    public func refreshAppCatalog(onlyIfNeeded: Bool = false) async throws -> AppCatalogRefresh {
        try await refreshAppCatalog(onlyIfNeeded: onlyIfNeeded, clientFor: { try readClient(for: $0) })
    }

    func refreshAppCatalog(onlyIfNeeded: Bool = false, now: @Sendable () -> Date = Date.init, clientFor: (Account) throws -> AppStoreConnectClient) async throws -> AppCatalogRefresh {
        let configured = try accounts()
        // Multiple processes may check freshness together. Only the exact job owner performs automatic discovery.
        let release: (() -> Void)?
        if onlyIfNeeded {
            release = try JobLock.acquire(directory: storeAccess { $0.directory }, name: "app_catalog_refresh", id: UUID().uuidString.lowercased())
            guard release != nil else { return .init(accounts: configured.count, refreshedAccounts: 0, appCount: configured.reduce(0) { $0 + $1.appIds.count }, issues: [], sample: false) }
        } else { release = nil }
        defer { release?() }
        var refreshed = 0, issues: [AppCatalogRefresh.Issue] = []
        for account in configured {
            try Task.checkCancellation(); try requireSessionAccess()
            if onlyIfNeeded {
                guard AppleRequestBudget.allowsReadingAhead(keyId: account.keyId), try catalogIsDue(account, now: now()) else { continue }
            }
            let started = now()
            do {
                _ = try await refreshAccountApps(account, client: clientFor(account), now: now)
                refreshed += 1
            } catch {
                try Task.checkCancellation(); try requireSessionAccess()
                if error is CancellationError { throw error }
                try? recordCatalogFailure(account, started: started, now: now())
                let reason = AccountFailure.classify(error) as? AccountFailure ?? .importFailed
                issues.append(.init(accountId: account.id, accountName: account.name, reason: reason))
            }
        }
        try Task.checkCancellation()
        let current = try accounts()
        return AppCatalogRefresh(accounts: configured.count, refreshedAccounts: refreshed, appCount: current.reduce(0) { $0 + $1.appIds.count }, issues: issues, sample: false)
    }
}
