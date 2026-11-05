import Foundation
import CryptoKit

/// Saved library metadata and scoped destinations; sync/import still use their existing services and owners.
public enum ConnectedApps {
    struct Metadata: Sendable {
        let name: String?, count: Int, importedAt: String?
        var cost: Int { 256 + (name?.utf8.count ?? 0) + (importedAt?.utf8.count ?? 0) }
    }
    public enum Failure: Error { case changed }
    public static func name(saved: String?, configured: String?, appId: String) -> String {
        if let saved, !saved.isEmpty { return saved }
        if let configured, !configured.isEmpty { return configured }
        return "App " + appId
    }
    /// One immutable account projection reused by its cards; mutations require a new snapshot.
    public struct AccountSnapshot: Sendable {
        public let account: Account
        fileprivate let appIds: Set<String>, token: String
        public init(_ account: Account) {
            self.account = account; appIds = Set(account.appIds)
            token = SHA256.hash(data: WorkspaceSession.json(account).data).map { String(format: "%02x", $0) }.joined()
        }
    }
    /// A library total requires every stored revision to pass the primary archive contract.
    public static func savedRevision(_ value: JSONText, accountId: String, appId: String, id: String, documentRevision: Int) throws -> ArchivedRevision {
        let revision = try ArchivedRevision(value, accountId: accountId, appId: appId, id: id, documentRevision: documentRevision)
        guard ReportTimestamps.valid(revision.importedAt) else { throw RevisionHistoryFailure.invalid }
        func array(_ value: JSONText?) throws -> [JSONText] {
            guard case .array(let rows)? = value else { throw RevisionHistoryFailure.invalid }; return rows
        }
        for version in try array(value["versions"]) {
            for locale in try array(version["localizations"]) {
                for set in try array(locale["screenshotSets"]) {
                    for image in try array(set["screenshots"]) {
                        guard let hash = image["sha256"]?.text, hash.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
                              image["contentType"] == .string("image/png") || image["contentType"] == .string("image/jpeg") else { throw RevisionHistoryFailure.invalid }
                    }
                }
            }
        }
        return revision
    }
    public struct Row: Identifiable, Sendable, Equatable, Codable {
        public let account: Account, app: Account.App, name: String, revisionCount: Int?, accountToken: String
        public let latestImportedAt: String?
        public let sync: SyncJob?, material: ImportJob?
        public let syncUnavailable, materialUnavailable: Bool
        public let aggregateActive: Bool
        public var id: String { "\(account.id)/\(app.id)" }
        public var historyLabel: String { revisionCount.map { "\($0) \($0 == 1 ? "revision" : "revisions")" } ?? "Saved history unavailable" }
        public var syncLabel: String {
            if syncUnavailable { return "Sync status unavailable" }
            guard let sync else { return "No data synced yet" }
            return sync.statusOnly ? "Setup checked · Data not synced" : "\(sync.counts.synced) of \(sync.counts.total) sources synced"
        }
        /// The short label on the sync command; `syncLabel` explains it on hover.
        public var syncButtonLabel: String {
            if syncUnavailable { return "Unavailable" }
            guard let sync else { return "Not synced" }
            return sync.statusOnly ? "Setup only" : "\(sync.counts.synced) of \(sync.counts.total) synced"
        }
        public var syncFeedback: String {
            if syncUnavailable { return "Sync results unavailable. Refresh status to check this app." }
            guard let sync else { return "No sources checked yet." }
            let sources = SyncSourceSummary(job: sync)
            if sync.statusOnly { return "Setup checked · " + sources.details + " · Data not synced" }
            if sync.isActive {
                let phase = sync.items.contains { $0.detail == AppSync.waitingForSlot } ? "Queued" : "Syncing"
                return "\(phase) · \(sync.counts.checked) of \(sync.counts.total) checked · " + sources.details
            }
            return sources.details + " · Last sync " + LibraryOverview.timestamp(sync.updatedAt)
        }
        public var needsRetry: Bool { sync?.needsRetry == true }
        public var canSync: Bool { !syncUnavailable && !aggregateActive }
        public init(account: Account, app: Account.App, savedName: String?, revisionCount: Int?, latestImportedAt: String? = nil, sync: SyncJob? = nil, material: ImportJob? = nil, syncUnavailable: Bool = false, materialUnavailable: Bool = false, aggregateActive: Bool? = nil) throws {
            try self.init(snapshot: AccountSnapshot(account), app: app, savedName: savedName, revisionCount: revisionCount, latestImportedAt: latestImportedAt,
                          sync: sync, material: material, syncUnavailable: syncUnavailable, materialUnavailable: materialUnavailable, aggregateActive: aggregateActive)
        }
        public init(snapshot: AccountSnapshot, app: Account.App, savedName: String?, revisionCount: Int?, latestImportedAt: String? = nil, sync: SyncJob? = nil, material: ImportJob? = nil, syncUnavailable: Bool = false, materialUnavailable: Bool = false, aggregateActive: Bool? = nil) throws {
            let account = snapshot.account
            _ = try RecoveryGuidance.Scope(accountId: account.id, appId: app.id)
            guard snapshot.appIds.contains(app.id), revisionCount.map({ $0 >= 0 }) ?? true,
                  latestImportedAt.map({ ReportTimestamps.valid($0) && (revisionCount ?? 0) > 0 }) ?? true,
                  sync.map({ $0.accountId == account.id && $0.appId == app.id }) ?? true,
                  !syncUnavailable || sync == nil, !materialUnavailable || material == nil else { throw Failure.changed }
            self.account = account; self.app = app; name = ConnectedApps.name(saved: savedName, configured: account.appNames?[app.id], appId: app.id)
            accountToken = snapshot.token
            self.revisionCount = revisionCount; self.sync = sync; self.material = material; self.syncUnavailable = syncUnavailable; self.materialUnavailable = materialUnavailable
            self.latestImportedAt = latestImportedAt
            self.aggregateActive = aggregateActive ?? (sync?.isActive == true)
        }
    }
    public struct Destination: Sendable, Equatable {
        public let scope: RecoveryGuidance.Scope, section: AppNavigation.Section, analyticsKind: String?
        public let recoveryAction: RecoveryGuidance.Action?
        public init(scope: RecoveryGuidance.Scope, recovery action: RecoveryGuidance.Action) throws {
            guard action.allowed(current: scope, decision: .ready), let section = action.target.section else { throw Failure.changed }
            self.scope = scope; self.section = section; analyticsKind = nil; recoveryAction = action
        }
        public init(scope: RecoveryGuidance.Scope, source: String? = nil) throws {
            self.scope = scope
            recoveryAction = nil
            switch source {
            case nil, "material": section = .overview; analyticsKind = nil
            case "pricing": section = .pricing; analyticsKind = nil
            case "sales": section = .sales; analyticsKind = nil
            case "downloads", "engagement": section = .analytics; analyticsKind = source
            case "finance": section = .finance; analyticsKind = nil
            case "reviews": section = .reviews; analyticsKind = nil
            default: throw Failure.changed
            }
        }
        public var href: String { section.href(scope: scope) + (analyticsKind.map { "?kind=" + $0 } ?? "") }
        public func allowed(accounts: [Account], decision: EditorProtectionPolicy.Decision, discardConfirmed: Bool = false) -> Bool {
            guard decision == .ready || decision == .confirmDiscard && discardConfirmed else { return false }
            return accounts.contains { $0.id == scope.accountId && $0.appIds.contains(scope.appId) }
        }
    }
}

extension WorkspaceSession {
    /// Independent unavailable histories or saved job reads remain unknown; session/catalog changes fail the whole snapshot.
    public func connectedApps() throws -> [ConnectedApps.Row] {
        try requireSessionAccess(); try Task.checkCancellation()
        let configured = try accounts()
        guard Set(configured.map(\.id)).count == configured.count else { throw ConnectedApps.Failure.changed }
        var result: [ConnectedApps.Row] = []
        for account in configured {
            let snapshot = ConnectedApps.AccountSnapshot(account)
            var seen = Set<String>()
            for app in account.apps where seen.insert(app.id).inserted {
                try Task.checkCancellation(); _ = try currentAccount(account, exact: true)
                var metadata: ConnectedApps.Metadata?, sync: SyncJob?, material: ImportJob?
                var syncUnavailable = false, materialUnavailable = false
                var aggregateActive = false
                do { metadata = try connectedAppMetadata(accountId: account.id, appId: app.id) }
                catch { try requireSessionAccess(); try Task.checkCancellation(); _ = try currentAccount(account, exact: true) }
                do { let presentation = try syncPresentation(account: account, appId: app.id); sync = presentation.status; aggregateActive = presentation.activeJobId != nil }
                catch { try requireSessionAccess(); try Task.checkCancellation(); _ = try currentAccount(account, exact: true); syncUnavailable = true }
                do { material = try importJob(account: account, appId: app.id) }
                catch { try requireSessionAccess(); try Task.checkCancellation(); _ = try currentAccount(account, exact: true); materialUnavailable = true }
                result.append(try .init(snapshot: snapshot, app: app, savedName: metadata?.name, revisionCount: metadata?.count,
                                        latestImportedAt: metadata?.importedAt,
                                        sync: sync, material: material, syncUnavailable: syncUnavailable, materialUnavailable: materialUnavailable, aggregateActive: aggregateActive))
            }
        }
        for account in configured { _ = try currentAccount(account, exact: true) }
        guard try accounts().map(\.id) == configured.map(\.id) else { throw ConnectedApps.Failure.changed }
        try requireSessionAccess(); try Task.checkCancellation()
        return result
    }
    public func validateConnectedApp(_ row: ConnectedApps.Row) throws {
        try requireSessionAccess(); try Task.checkCancellation()
        _ = try currentAccount(row.account, exact: true)
        try requireHistoryScope(accountId: row.account.id, appId: row.app.id)
    }
    func connectedAppHistory(accountId: String, appId: String) throws -> [ArchivedRevision] {
        try requireHistoryScope(accountId: accountId, appId: appId)
        let prefix = "\(accountId):\(appId):"
        return try storeAccess { store in
            try store.documents(namespace: "revisions", prefix: prefix).map { document in
                try ConnectedApps.savedRevision(JSONText.parse(document.payload), accountId: accountId, appId: appId,
                                                id: String(document.key.dropFirst(prefix.count)), documentRevision: document.revision)
            }.sorted { $0.importedAt > $1.importedAt }
        }
    }
    /// Cache only validated summary values, never entire archives or credentials. The database
    /// stamp detects own writes, other connections and delete/reinsert even at the same revision.
    func connectedAppMetadata(accountId: String, appId: String) throws -> ConnectedApps.Metadata {
        try requireHistoryScope(accountId: accountId, appId: appId); try Task.checkCancellation()
        let stamp = try storeAccess { try $0.changeStamp() }
        if stamp != libraryMetadataStamp { libraryMetadataCache.removeAll(); libraryMetadataStamp = stamp }
        let key = accountId + ":" + appId
        if let cached = libraryMetadataCache.value(for: key) { return cached }
        let rows = try connectedAppHistory(accountId: accountId, appId: appId)
        let value = ConnectedApps.Metadata(name: rows.first?.value["app"]?["name"]?.text, count: rows.count, importedAt: rows.first?.importedAt)
        try requireHistoryScope(accountId: accountId, appId: appId); try Task.checkCancellation()
        guard try storeAccess({ try $0.changeStamp() }) == stamp else { throw ConnectedApps.Failure.changed }
        libraryMetadataCache.insert(value, for: key, cost: value.cost)
        return value
    }
}
