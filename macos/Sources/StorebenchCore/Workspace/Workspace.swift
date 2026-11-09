import Foundation

/// Account metadata in `accounts/all`; private keys stay in the selected credential storage.
public struct Account: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let keyId: String
    public let keyType: String
    public let issuerId: String?
    public let appIds: [String]
    public let appNames: [String: String]?

    public init(id: String, name: String, keyId: String, keyType: String, issuerId: String?, appIds: [String], appNames: [String: String]?) {
        self.id = id; self.name = name; self.keyId = keyId; self.keyType = keyType; self.issuerId = issuerId; self.appIds = appIds; self.appNames = appNames
    }

    enum CodingKeys: String, CodingKey { case id, name, keyId, keyType, issuerId, appIds, appNames }
    /// Accounts saved before key types existed are team keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id); name = try container.decode(String.self, forKey: .name); keyId = try container.decode(String.self, forKey: .keyId)
        keyType = try container.decodeIfPresent(String.self, forKey: .keyType) ?? "team"; issuerId = try container.decodeIfPresent(String.self, forKey: .issuerId)
        appIds = try container.decode([String].self, forKey: .appIds); appNames = try container.decodeIfPresent([String: String].self, forKey: .appNames)
    }

    public struct App: Equatable, Identifiable, Sendable, Codable { public let id: String; public let name: String }
    public var apps: [App] { appIds.map { App(id: $0, name: appNames?[$0] ?? "App \($0)") } }
}

/// Opens a workspace using its saved database key record and any required password.
public struct Workspace: Sendable {
    public enum Failure: Error, Equatable { case notSetUp, notReady, missingDatabase }
    public enum Lock: Equatable, Sendable { case device, password }

    public let root: URL

    public init(root: URL = Workspace.defaultRoot) { self.root = root }

    /// `~/Library/Application Support/Storebench`.
    public static var defaultRoot: URL {
        if Network.testMode, let root = try? TestIsolation.require() { return root.appendingPathComponent("data") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Storebench")
    }

    public func lock(in vault: CredentialVault) throws -> Lock {
        guard let record = try vault.databaseKeyRecord(root: root) else { throw Failure.notSetUp }
        guard record.ready else { throw Failure.notReady }
        return record.envelope.requiresPassword ? .password : .device
    }

    /// Run off the main thread: unwrapping a password-protected key runs scrypt.
    public func open(vault: CredentialVault, password: String? = nil, writable: Bool = false) throws -> EncryptedDocumentStore {
        guard let record = try vault.databaseKeyRecord(root: root) else { throw Failure.notSetUp }
        guard record.ready else { throw Failure.notReady }
        let url = EncryptedDocumentStore.databaseURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missingDatabase }
        var key = try record.envelope.unwrap(password: password)
        defer { key.resetBytes(in: 0..<key.count) }
        return try EncryptedDocumentStore(url: url, key: key, writable: writable)
    }

    /// The store together with the encrypted media files beside it, both keyed by the same database key.
    func openWithMedia(vault: CredentialVault, password: String?) throws -> (EncryptedDocumentStore, EncryptedMediaStore) {
        let (store, media, _) = try openWithKey(vault: vault, password: password)
        return (store, media)
    }

    func openWithKey(vault: CredentialVault, password: String?) throws -> (EncryptedDocumentStore, EncryptedMediaStore, Data) {
        guard let record = try vault.databaseKeyRecord(root: root) else { throw Failure.notSetUp }
        guard record.ready else { throw Failure.notReady }
        let url = EncryptedDocumentStore.databaseURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missingDatabase }
        var key = try record.envelope.unwrap(password: password)
        defer { key.resetBytes(in: 0..<key.count) }
        let store = try EncryptedDocumentStore(url: url, key: key, writable: true)
        return (store, try EncryptedMediaStore(directory: store.directory.appendingPathComponent("media"), key: key), Data(key))
    }

    public static func accounts(in store: EncryptedDocumentStore) throws -> [Account] {
        guard let document = try store.document(namespace: "accounts", key: "all") else { return [] }
        return try JSONDecoder().decode([Account].self, from: document.payload)
    }
}

/// Keeps the opened store on one actor, so views can read while it stays open.
public actor WorkspaceSession {
    private let store: EncryptedDocumentStore
    private var accountCatalogCache: (document: EncryptedDocumentStore.Document?, value: [Account])?
    let appleReadCache = AppStoreReadCache()
    let media: EncryptedMediaStore
    let mediaFileWork = MediaFileWork()
    let aiQueue = AIWorkQueue()
    var aiTasks: [String: Task<JSONText, Error>] = [:]
    var aiModelReads: [AIConnection: AIModelRead] = [:]
    var aiModelCatalogs: [AIProvider: AIModelCatalog] = [:]
    var aiTestConfiguration: (@Sendable () -> URLSessionConfiguration)?
    var chatGPTAttempts: [String: ChatGPTSignIn] = [:]
    var chatGPTSignInTasks: [String: Task<ChatGPTSignInResult, Error>] = [:]
    var chatGPTRenewals: [String: Task<String, Error>] = [:]
    var chatGPTSignOutTasks: [String: Task<Bool, Error>] = [:]
    var chatGPTBlocks: [String: AIFailure] = [:]

    /// The open store's key, kept for the session for encrypted snapshots.
    var databaseKey: Data
    let root: URL
    nonisolated let lifetime = SessionLifetime()
    nonisolated let accessGeneration: String
    nonisolated let accessMarker: URL
    /// A sample workspace holds synthetic data only. It opens with an in-memory key and never reads or writes credentials.
    public nonisolated let isSample: Bool

    public init(workspace: Workspace, vault: CredentialVault? = nil, password: String? = nil, credentialWriter: VaultWriter? = nil) throws {
        try self.init(workspace: workspace, vault: vault, password: password, credentialWriter: credentialWriter, sample: false)
    }

    init(workspace: Workspace, vault: CredentialVault?, password: String?, credentialWriter: VaultWriter?, sample: Bool) throws {
        isSample = sample
        let writer = sample ? nil : credentialWriter ?? (Network.testMode ? nil : VaultWriter(dataRoot: Workspace.defaultRoot))
        let opened: ((EncryptedDocumentStore, EncryptedMediaStore, Data), VaultWriter.Snapshot?, String)
        if let writer {
            let directory = try Setup.privateDirectory(root: workspace.root)
            opened = try FileMutex.withLock(directory.appendingPathComponent("bootstrap.mutex")) {
                let snapshot = try writer.snapshot(migrating: CredentialVault.databaseEntry(root: workspace.root))
                return (try workspace.openWithKey(vault: snapshot.vault, password: password), snapshot, try VaultWriter.markerVersion(directory.appendingPathComponent("access-generation")))
            }
        } else {
            guard let vault else { throw Workspace.Failure.notSetUp }
            let directory = try Setup.privateDirectory(root: workspace.root)
            opened = try FileMutex.withLock(directory.appendingPathComponent("bootstrap.mutex")) {
                (try workspace.openWithKey(vault: vault, password: password), nil, try VaultWriter.markerVersion(directory.appendingPathComponent("access-generation")))
            }
        }
        guard let current = opened.1?.vault ?? vault else { throw Workspace.Failure.notSetUp }
        (store, media, databaseKey) = opened.0
        self.vault = current; root = workspace.root; self.credentialWriter = writer; credentialSnapshot = opened.1
        accessGeneration = opened.2
        accessMarker = opened.0.0.directory.appendingPathComponent("access-generation")
    }

    /// Setup already owns the bootstrap mutex; do not acquire it recursively while constructing the actor.
    init(unlocked workspace: Workspace, snapshot: VaultWriter.Snapshot, password: String?, writer: VaultWriter) throws {
        isSample = false
        (store, media, databaseKey) = try workspace.openWithKey(vault: snapshot.vault, password: password)
        vault = snapshot.vault; root = workspace.root; credentialWriter = writer; credentialSnapshot = snapshot
        accessGeneration = try VaultWriter.markerVersion(store.directory.appendingPathComponent("access-generation"))
        accessMarker = store.directory.appendingPathComponent("access-generation")
    }

    var vault: CredentialVault
    var credentialWriter: VaultWriter?
    var credentialSnapshot: VaultWriter.Snapshot?
    var credentialFailures: Set<String> = []
    var credentialVersions: [String: String] = [:]
    var pricingCaches = PricingCaches()
    var libraryProcessingWait = LibraryProcessingWait()
    /// Tests give App Privacy a synthetic Apple ID session and network instead of Keychain and Apple.
    var appleWebTestRoute: (session: AppleWebSession, configuration: @Sendable () -> URLSessionConfiguration)?
    /// Synthetic read transport, available only in an owned isolated test run.
    private var appleReadTestRoute: (origin: URL, configuration: @Sendable () -> URLSessionConfiguration)?
    func configureAppleReadTestRoute(origin: URL, configuration: @escaping @Sendable () -> URLSessionConfiguration) throws {
        _ = try TestIsolation.require()
        guard Network.testMode, origin.scheme == "https", origin.host?.hasSuffix(".test") == true,
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil else { throw AppStoreConnectClient.Failure.invalidPath }
        appleReadTestRoute = (origin, configuration)
    }
    var libraryMetadataStamp: String?
    var libraryMetadataCache = BoundedMemoryCache<String, ConnectedApps.Metadata>(capacity: 64, byteLimit: 256 * 1_024)
    var iconCache = AppIcons.Cache()
    /// The last screen read saved per key in this session, so an unchanged read is not written again.
    var viewReadDigests: [String: String] = [:]
    /// Changes when Clear Cache removes the saved screen reads, so a read a window captured before that is not saved afterwards.
    public internal(set) var viewReadEpoch = 0
    /// Saved screen reads counted at the last cleanup plus those added since; nil until the first cleanup.
    var viewReadCount: Int?
    var viewReadCleanedAt: ContinuousClock.Instant?
    /// Saved revisions decoded in this session, reused while a document's payload is byte for byte the same.
    var decodedRevisions = BoundedMemoryCache<String, (payload: Data, revision: Revision)>(CachePolicy.standardBudget.decodedRevisions)
    var archivedRevisions = BoundedMemoryCache<String, (payload: Data, value: ArchivedRevision)>(CachePolicy.standardBudget.archivedRevisions)
    var releaseStatusMemory = BoundedMemoryCache<String, (snapshot: ReleaseReadinessSnapshot, checkedAt: Date)>(CachePolicy.standardBudget.releaseStatus)
    /// The budget the session caches follow, from the Performance setting.
    var cacheBudget = CachePolicy.standardBudget
    var iconTasks: [String: (id: UUID, task: Task<AppIcons.Image?, Error>)] = [:]
    var reportTasks: [String: (id: String, cancel: @Sendable () -> Void)] = [:]
    var reportTaskFailures: Set<String> = []
    /// Reviews prepared before their step opens, so the step shows them at once. Each is used once.
    var reviewsAhead: [ReviewAhead] = []
    func vaultEntry(_ key: String) throws -> String? { try credentialCapture(key) }

    /// A client scoped to one connected account and signed with its stored private key.
    public func client(for account: Account) throws -> AppStoreConnectClient {
        try appleClient(for: account, sharingReads: false)
    }
    /// Read-only screens share response bytes and in-flight requests across the opened workspace.
    /// Editors still read their local draft revisions; publishing always uses `client(for:)`.
    public func readClient(for account: Account) throws -> AppStoreConnectClient {
        try appleClient(for: account, sharingReads: true)
    }
    public func invalidateAppleReads() async { await appleReadCache.invalidate() }
    private func appleClient(for account: Account, sharingReads: Bool) throws -> AppStoreConnectClient {
        _ = try currentAccount(account, exact: sharingReads)
        guard let pem = try vaultEntry("apple:\(account.id)") else { throw ReviewsFailure.noKey }
        let scope = JSONText.array([Self.json(account), .string(credentialVersions["apple:\(account.id)"] ?? "initial")]).sha256
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: pem), origin: appleReadTestRoute?.origin ?? AppStoreConnectClient.base,
                                    configuration: appleReadTestRoute?.configuration(), readCache: sharingReads ? appleReadCache : nil,
                                    readCacheScope: scope, accessCheck: sessionRequestCheck())
    }
    nonisolated func sessionRequestCheck() -> @Sendable () throws -> Void {
        { try self.requireSessionAccess() }
    }

    nonisolated func requireSessionAccess() throws {
        try lifetime.require()
        guard try VaultWriter.markerVersion(accessMarker) == accessGeneration else { throw SessionFailure.changed }
        // The read is concurrent with closing. Recheck the exact ticket after reading the marker.
        try lifetime.require()
    }

    public func accounts() throws -> [Account] {
        let document = try storeAccess { try $0.document(namespace: "accounts", key: "all") }
        if let cached = accountCatalogCache, cached.document == document { return cached.value }
        let value = try document.map { try JSONDecoder().decode([Account].self, from: $0.payload) } ?? []
        accountCatalogCache = (document, value)
        return value
    }

    /// Materialize older per-entry credentials before the explicit backend copy.
    func prepareCredentialCopy(writer: VaultWriter) throws {
        try requireSessionAccess(); try requireOwnWorkspace()
        var keys = [CredentialVault.databaseEntry(root: root)]
        for account in try accounts() {
            keys.append("apple:" + account.id)
            if let document = try storeAccess({ try $0.document(namespace: "sales_connection", key: account.id) }),
               let reporter = try ReportingConnection(json: JSONText.parse(document.payload)).reporter {
                keys.append("reporter:" + reporter.credentialId)
            }
        }
        if let secret = try BackupSchedule.read(root: root).secretId { keys.append(BackupSchedule.vaultKey(root: root, secretId: secret)) }
        for key in keys { _ = try writer.snapshot(migrating: key) }
    }

    func storeAccess<T>(_ read: (EncryptedDocumentStore) throws -> T) throws -> T { try requireSessionAccess(); return try read(store) }

    /// Saved imports and local drafts for one app, newest first; unreadable entries are skipped.
    /// The revision a saved document holds. A payload equal to the one decoded before reuses that result; anything else decodes again.
    func decodedRevision(_ document: EncryptedDocumentStore.Document, cacheKey: String, decode: () throws -> Revision) throws -> Revision {
        if let cached = decodedRevisions.value(for: cacheKey), cached.payload == document.payload { return cached.revision }
        let revision = try decode()
        decodedRevisions.insert((document.payload, revision), for: cacheKey, cost: document.payload.count * 3)
        return revision
    }
    /// A saved source revision validated as JSON first, as media reads require.
    func parsedRevision(_ document: EncryptedDocumentStore.Document) throws -> Revision {
        try decodedRevision(document, cacheKey: "parsed/" + document.key) { try JSONDecoder().decode(Revision.self, from: JSONText.parse(document.payload).data) }
    }
    public func revisions(accountId: String, appId: String) throws -> [Revision] {
        try requireSessionAccess()
        let decoder = JSONDecoder()
        return try store.documents(namespace: "revisions", prefix: "\(accountId):\(appId):")
            .compactMap { document in try? decodedRevision(document, cacheKey: "direct/" + document.key) { try decoder.decode(Revision.self, from: document.payload) } }
            .filter { $0.schemaVersion == 1 }
            .sorted { $0.importedAt > $1.importedAt }
    }

    /// Stops new work, cancels only owned report tasks, drains admitted work and closes this session.
    /// Session tokens and the access generation are revoked under the bootstrap mutex.
    public func signOut() async throws {
        try await closeSession(change: nil)
    }
    public nonisolated func validateAccess() throws { try requireSessionAccess() }
    struct ProtectionChange { let writer: VaultWriter; let previous: String; let currentPassword, newPassword: String? }
    /// A rejected current password leaves the session and its background work open.
    public func changeLock(writer: VaultWriter, currentPassword: String?, newPassword: String?) async throws {
        try requireOwnWorkspace()
        try requireSessionAccess()
        guard lifetime.status == .open else { throw SessionFailure.closed }
        if let newPassword, !(12...256).contains(newPassword.utf16.count) { throw Setup.Failure.invalidPassword }
        if writer.usesPasswordFile && newPassword == nil { throw PasswordVaultStorage.Failure.passwordRequired }
        let workspace = Workspace(root: root)
        let previous = try FileMutex.withLock(store.directory.appendingPathComponent("bootstrap.mutex")) {
            try requireSessionAccess()
            return try workspace.verifyLockUnderBootstrap(writer: writer, password: currentPassword)
        }
        try await closeSession(change: ProtectionChange(writer: writer, previous: previous, currentPassword: currentPassword, newPassword: newPassword))
    }
    private func closeSession(change: ProtectionChange?) async throws {
        guard lifetime.beginClosing() else {
            await lifetime.closed()
            if let failure = lifetime.closeFailure { throw failure }
            return
        }
        for task in reportTasks.values { task.cancel() }
        for task in aiTasks.values { task.cancel() }
        for read in aiModelReads.values { read.task.cancel() }
        aiModelCatalogs.removeAll()
        chatGPTAttempts.removeAll()
        for task in chatGPTSignInTasks.values { task.cancel() }
        for task in chatGPTRenewals.values { task.cancel() }
        for task in chatGPTSignOutTasks.values { task.cancel() }
        for icon in iconTasks.values { icon.task.cancel() }
        await appleReadCache.invalidate()
        releaseStatusMemory.removeAll()
        await lifetime.drained()
        var failure: SessionFailure?
        do {
            try FileMutex.withLock(store.directory.appendingPathComponent("bootstrap.mutex")) {
                // A stale session must not revoke a newer protection generation.
                guard try VaultWriter.markerVersion(store.directory.appendingPathComponent("access-generation")) == accessGeneration else {
                    if change != nil { throw SessionFailure.changed }
                    return
                }
                if let change, try change.writer.value(CredentialVault.databaseEntry(root: root)) != change.previous { throw SessionFailure.changed }
                try store.transaction { current in
                    if let saved = try current("local_sessions", "signing_key") { _ = try LocalSessionKey(JSONText.parse(saved.payload)) }
                    let value = try LocalSessionKey.fresh()
                    return [.put(namespace: "local_sessions", key: "signing_key", json: value.json.data)]
                }
                if let change { try Workspace(root: root).changeLockUnderBootstrap(writer: change.writer, currentPassword: change.currentPassword, newPassword: change.newPassword) }
                else { try Setup.replaceGeneration(store.directory) }
            }
        } catch { failure = error as? SessionFailure ?? .revocation }
        store.close()
        media.discardKey()
        databaseKey.resetBytes(in: 0..<databaseKey.count); databaseKey.removeAll()
        vault = .empty
        accountCatalogCache = nil
        pricingCaches = PricingCaches()
        libraryMetadataCache.removeAll(); libraryMetadataStamp = nil
        credentialWriter?.lockCredentials()
        credentialWriter = nil; credentialSnapshot = nil
        credentialFailures.removeAll(); credentialVersions.removeAll()
        iconCache = .init(); iconTasks.removeAll()
        decodedRevisions.removeAll(); archivedRevisions.removeAll(); viewReadDigests.removeAll()
        reportTasks.removeAll(); reportTaskFailures.removeAll()
        lifetime.finishClosing(failure: failure)
        if let failure { throw failure }
    }
}
