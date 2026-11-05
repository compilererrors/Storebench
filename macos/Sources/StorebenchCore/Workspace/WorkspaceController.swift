import Foundation
import Observation
import Security

/// Shared native startup, authentication and scheduled backup lifecycle.
@MainActor @Observable public final class WorkspaceController {
    public enum State: Equatable { case loading, chooseStorage, migrateStorage, notSetUp, locked, unlocking, closing, unlocked([Account]), failed(String) }
    public private(set) var session: WorkspaceSession?
    public private(set) var state: State = .loading
    public private(set) var editingPreferences: EditingPreferences?
    public private(set) var lockMode: Workspace.Lock?
    public var lastError = ""
    public private(set) var writer: VaultWriter
    public private(set) var storageMode: CredentialStorageMode?
    public private(set) var requiresDeviceAuthentication = false
    private let workspace: Workspace
    private let choosesStorage: Bool
    private let keychainStorage: VaultStorage
    private let protectedStorage: VaultStorage
    private let authenticator: WorkspaceAuthenticating
    private let backupDelay: Duration, availabilityDelay: Duration
    /// The wait after unlocking before recently planned releases are read in the background; nil turns the warm-up off.
    private let releaseWarmDelay: Duration?
    @ObservationIgnored private var releaseWarmTask: Task<Void, Never>?
    private var transitioning = false
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    @ObservationIgnored private var availabilityTask: Task<Void, Never>?
    @ObservationIgnored private var memoryPressure: DispatchSourceMemoryPressure?
    /// The open windows' remembered screen reads, so Clear Cache, memory pressure and the size shown reach them too.
    @ObservationIgnored private let windowReads = NSHashTable<NavigationPresentation>.weakObjects()
    /// The Performance setting. The open session follows a change at once; a newly opened one starts with it.
    public var cachePolicy = CachePolicy() {
        didSet { if cachePolicy != oldValue, let session { let policy = cachePolicy; Task { await session.applyCachePolicy(policy) } } }
    }

    public init(workspace: Workspace = Workspace(), writer: VaultWriter? = nil, keychainStorage: VaultStorage = KeychainVaultStorage(), authenticator: WorkspaceAuthenticating = DeviceOwnerAuthentication(), protectedStorage: VaultStorage? = nil, backupDelay: Duration = .seconds(15 * 60), availabilityDelay: Duration = .seconds(1), releaseWarmDelay: Duration? = .seconds(5)) {
        self.workspace = workspace; self.writer = writer ?? VaultWriter(dataRoot: workspace.root)
        self.choosesStorage = writer == nil; self.keychainStorage = keychainStorage
        self.authenticator = authenticator; self.protectedStorage = protectedStorage ?? TouchIDKeychainStorage(dataRoot: workspace.root)
        self.backupDelay = backupDelay; self.availabilityDelay = availabilityDelay; self.releaseWarmDelay = releaseWarmDelay
    }
    deinit { backupTask?.cancel(); availabilityTask?.cancel(); releaseWarmTask?.cancel(); memoryPressure?.cancel() }

    public func start() async {
        guard !transitioning, session == nil else { return }
        guard state == .loading else { return }
        transitioning = true; defer { transitioning = false }
        state = .loading
        let workspace = workspace
        do {
            if choosesStorage {
                let preference = try await Task.detached { try CredentialStorageChoice.preference(root: workspace.root) }.value
                let choice = preference?.mode
                let local = PasswordVaultStorage(dataRoot: workspace.root)
                let localExists = try await Task.detached { try local.exists() }.value
                if localExists || choice == .password {
                    requiresDeviceAuthentication = false
                    storageMode = .password; self.writer = VaultWriter(dataRoot: workspace.root, storage: local)
                    lockMode = .password
                    if localExists { state = .locked }
                    else if FileManager.default.fileExists(atPath: EncryptedDocumentStore.databaseURL(root: workspace.root).path) { state = .migrateStorage }
                    else { state = .notSetUp }
                    return
                }
                if choice == .touchID {
                    storageMode = .touchID; requiresDeviceAuthentication = true
                    self.writer = VaultWriter(dataRoot: workspace.root, storage: protectedStorage, protectedKeychain: true)
                    lockMode = .device; state = .locked; return
                }
                guard choice == .keychain else { storageMode = nil; state = .chooseStorage; return }
                storageMode = .keychain; self.writer = VaultWriter(dataRoot: workspace.root, storage: keychainStorage)
                requiresDeviceAuthentication = preference?.requireDeviceAuthentication == true
                if requiresDeviceAuthentication { lockMode = .device; state = .locked; return }
            }
            let writer = self.writer
            lockMode = try await Task.detached { try workspace.lock(writer: writer) }.value
            switch lockMode {
            case nil:
                if Backups.exists(workspace.root.appendingPathComponent("pending-restore")) { lockMode = .password; state = .locked }
                else { state = .notSetUp }
            case .password?: state = .locked
            case .device?: try await open(password: nil)
            }
        } catch { state = .failed(Self.message(for: error)) }
    }

    /// The explicit user choice precedes all automatic Keychain access.
    public func selectStorage(_ mode: CredentialStorageMode) async {
        guard choosesStorage, !transitioning, session == nil, mode != .touchID, storageMode != .touchID else { return }
        switch state { case .chooseStorage, .migrateStorage, .notSetUp, .failed: break; default: return }
        transitioning = true; lastError = ""
        let workspace = workspace, expected = storageMode
        do {
            try await Task.detached { try CredentialStorageChoice.save(mode, root: workspace.root, expected: expected) }.value
            if mode == .keychain { keychainStorage.retryAccess() }
            storageMode = mode; state = .loading; transitioning = false
            await start()
        } catch { transitioning = false; state = .failed(Self.message(for: error)) }
    }

    public func reviewStorageChoice() {
        guard choosesStorage, !transitioning, session == nil else { return }
        switch state { case .chooseStorage, .migrateStorage, .notSetUp, .failed: state = .chooseStorage; lastError = ""; default: return }
    }

    public func choosePasswordStorage() async {
        guard choosesStorage, !transitioning, storageMode == .keychain, writer.usesKeychain, session != nil else { return }
        await signOut()
        guard !transitioning, session == nil, state == .locked else { return }
        state = .chooseStorage
        await selectStorage(.password)
    }

    public func migrateStorage(currentPassword: String?, newPassword: String) async {
        guard !transitioning, session == nil, state == .migrateStorage, let local = writer.passwordStorage else { return }
        transitioning = true; defer { transitioning = false }
        state = .unlocking; lastError = ""
        let workspace = workspace, destination = writer, source = VaultWriter(dataRoot: workspace.root, storage: keychainStorage)
        source.retryKeychainAccess()
        do {
            try await Task.detached { try workspace.migrateToPasswordStorage(from: source, to: destination, currentPassword: currentPassword, newPassword: newPassword) }.value
            try await open(password: nil)
        } catch {
            local.lock(); writer.discardCachedCredentials()
            state = (try? local.exists()) == true ? .locked : .migrateStorage
            lastError = error is KeyEnvelope.Failure ? "Enter the current Storebench password if your saved data already requires one." : Self.message(for: error)
        }
    }

    /// Only an explicit user retry may reopen the shared Keychain permission attempt.
    public func retryStart() async {
        guard !transitioning, session == nil, case .failed = state else { return }
        writer.retryKeychainAccess(); state = .loading
        await start()
    }

    public func unlock(password: String) async {
        guard !transitioning, session == nil, state == .locked else { return }
        transitioning = true; defer { transitioning = false }
        do {
            if requiresDeviceAuthentication {
                state = .unlocking; lastError = ""
                if storageMode != .touchID { try await authenticator.authenticate() }
                writer.retryKeychainAccess()
                let workspace = workspace, writer = writer
                lockMode = try await Task.detached { try workspace.lock(writer: writer) }.value
                if lockMode == nil { state = .notSetUp; return }
                if lockMode == .password, password.isEmpty { state = .locked; lastError = "Mac authentication succeeded. Enter your Storebench password to open this password-protected database."; return }
            }
            if !requiresDeviceAuthentication { writer.retryKeychainAccess() }
            if let storage = writer.passwordStorage {
                try await Task.detached { try storage.unlock(password: password) }.value
                let workspace = workspace, writer = writer
                try await Task.detached { try workspace.resumePendingRestore(writer: writer, password: password) }.value
                if try await Task.detached(operation: { try workspace.lock(writer: writer) }).value == nil {
                    state = .notSetUp; lastError = "Finish setup with the same Storebench password."; return
                }
            }
            try await open(password: lockMode == .device ? nil : password)
        }
        catch let failure as WorkspaceAuthenticationFailure { state = .locked; lastError = failure.message }
        catch let failure as TouchIDKeychainFailure { state = .locked; lastError = failure.message }
        catch CredentialVault.Failure.keychain(errSecUserCanceled) { state = .locked; lastError = WorkspaceAuthenticationFailure.cancelled.message }
        catch CredentialVault.Failure.keychain(errSecAuthFailed) { state = .locked; lastError = WorkspaceAuthenticationFailure.denied.message }
        catch is CancellationError { state = .locked; lastError = WorkspaceAuthenticationFailure.cancelled.message }
        catch KeyEnvelope.Failure.incorrectPassword { state = .locked; lastError = "The password could not unlock the encrypted database." }
        catch { state = .failed(Self.message(for: error)) }
    }

    public func setUp(password: String?) async {
        guard !transitioning, session == nil, state == .notSetUp else { return }
        transitioning = true; defer { transitioning = false }
        state = .unlocking; lastError = ""
        let workspace = workspace, writer = writer
        do {
            if let storage = writer.passwordStorage {
                guard let password else { throw PasswordVaultStorage.Failure.passwordRequired }
                try await Task.detached {
                    if try storage.exists() { try storage.unlock(password: password) }
                    else { try storage.create(password: password) }
                }.value
            }
            let created = try await Task.detached { try workspace.createFresh(writer: writer, password: password) }.value
            lockMode = writer.usesPasswordFile || password != nil ? .password : .device
            try await accept(created)
        } catch Setup.Failure.invalidPassword, PasswordVaultStorage.Failure.passwordRequired, KeyEnvelope.Failure.incorrectPassword { state = .notSetUp; lastError = "Use a password of 12 to 256 characters. If setup was interrupted, use the original password." }
        catch { state = .failed(Self.message(for: error)) }
    }

    public func workspaceLock() throws -> Workspace.Lock? {
        // Settings can open before onboarding; merely inspecting its Security pane must not prompt.
        if choosesStorage && storageMode == nil { return nil }
        if storageMode == .password || writer.usesPasswordFile { return .password }
        if requiresDeviceAuthentication && session == nil { return lockMode ?? .device }
        return try workspace.lock(writer: writer)
    }

    public func changeDeviceAuthentication(required: Bool) async throws {
        guard choosesStorage, !transitioning, storageMode == .keychain, writer.usesKeychain, let current = session, required != requiresDeviceAuthentication else { throw CredentialAccessFailure.changed }
        transitioning = true; defer { transitioning = false }
        let expected = requiresDeviceAuthentication, workspace = workspace
        try await authenticator.authenticate()
        guard session === current else { throw SessionFailure.closed }
        try current.validateAccess()
        try await Task.detached { try CredentialStorageChoice.saveAuthentication(required, root: workspace.root, expected: expected) }.value
        requiresDeviceAuthentication = required
    }

    /// Explicit storage transition. The source remains a recovery copy; this backend never falls back to it.
    public func enableTouchIDKeychain() async throws {
        guard choosesStorage, !transitioning, storageMode == .keychain, lockMode == .device, let current = session else { throw CredentialAccessFailure.changed }
        try protectedStorage.validateAccess()
        transitioning = true; defer { transitioning = false }
        let source = writer, destination = protectedStorage, workspace = workspace, expected = requiresDeviceAuthentication
        try current.validateAccess()
        try await current.prepareCredentialCopy(writer: source)
        state = .closing
        do {
            try await current.signOut(); drop(current)
            try await Task.detached { try CredentialStorageChoice.enableTouchID(root: workspace.root, source: source, destination: destination, expectedAuthentication: expected) }.value
            destination.lockAccess()
            writer = VaultWriter(dataRoot: workspace.root, storage: destination, protectedKeychain: true)
            storageMode = .touchID; requiresDeviceAuthentication = true; lockMode = .device
            state = .locked; lastError = "Unlock with Touch ID or your Mac login password. Your original login Keychain copy is kept for recovery."
        } catch {
            if session != nil { drop(current) }
            destination.lockAccess(); state = .locked; lastError = Self.message(for: error)
            throw error
        }
    }

    public func changeLock(currentPassword: String?, newPassword: String?) async throws {
        guard !transitioning, let current = session else { throw SessionFailure.closed }
        transitioning = true; defer { transitioning = false }
        do {
            try await current.changeLock(writer: writer, currentPassword: currentPassword, newPassword: newPassword)
            // The protection change was authorized by the open session; read its newly committed mode before dropping it.
            let updatedLock: Workspace.Lock?
            if writer.usesPasswordFile { updatedLock = .password }
            else { updatedLock = try workspace.lock(writer: writer) }
            drop(current)
            lockMode = updatedLock
            if lockMode == .device && !requiresDeviceAuthentication { try await open(password: nil) }
            else {
                state = .locked
                lastError = lockMode == .device ? "Storage protection changed. Unlock Storebench with your Mac." : "Storage protection changed. Unlock Storebench with the new password."
            }
        } catch {
            if await current.lifetime.status != .open { drop(current); lockMode = try? workspaceLock(); state = .locked; lastError = Self.message(for: error) }
            throw error
        }
    }

    /// Lets Clear Cache, memory pressure and the measured size reach this window's remembered reads.
    public func registerWindowReads(_ presentation: NavigationPresentation) { windowReads.add(presentation) }
    /// Clear Cache: the windows stop saving reads first, so nothing captured before the session clears is saved again afterwards.
    public func clearCachedReads() async {
        guard let session else { return }
        let windows = windowReads.allObjects
        windows.forEach { $0.clearReads() }
        let epoch = await session.clearCachedReads()
        windows.forEach { $0.resume(epoch: epoch) }
    }
    /// Estimated bytes kept by the session caches and the open windows' remembered reads.
    public func cachedMemoryBytes() async -> Int {
        let windows = windowReads.allObjects.reduce(0) { $0 + $1.retainedReadBytes }
        guard let session else { return windows }
        return await session.cachedMemoryBytes() + windows
    }

    public func signOut() async {
        guard !transitioning, let current = session else { return }
        transitioning = true; defer { transitioning = false }
        state = .closing; lastError = ""
        backupTask?.cancel(); availabilityTask?.cancel(); releaseWarmTask?.cancel()
        do { try await current.signOut() }
        catch { lastError = Self.message(for: error) }
        drop(current); lockMode = try? workspaceLock(); state = .locked
    }

    public func restore(backup: URL, password: String) async {
        guard !transitioning, session == nil, state == .notSetUp else { return }
        transitioning = true; defer { transitioning = false }
        state = .unlocking; lastError = ""
        let workspace = workspace, writer = writer
        do {
            try await Task.detached { try workspace.restoreIntoEmptyWorkspace(backup: backup, password: password, writer: writer) }.value
            try await open(password: password)
        } catch let failure as BackupFailure { state = .notSetUp; lastError = failure.message }
        catch { state = .notSetUp; lastError = "The backup could not be restored. Nothing was changed." }
    }

    /// Turns a destructive action's confirmation on or off and keeps the shown preferences in step with the saved ones.
    public func setConfirmation(_ kind: DestructiveConfirmation, asks: Bool) async throws {
        guard let current = session else { return }
        let saved = try await current.updateEditingPreferences { if asks { $0.skippedConfirmations.remove(kind) } else { $0.skippedConfirmations.insert(kind) } }
        guard session === current else { return }; editingPreferences = saved
    }
    public func reloadEditingPreferences() async {
        guard let current = session else { editingPreferences = nil; return }
        let preferences = try? await current.editingPreferences()
        guard session === current else { return }; editingPreferences = preferences
    }
    public func reloadAccounts() async {
        guard !transitioning, let current = session else { return }
        let accounts = try? await current.accounts()
        guard session === current, !transitioning, let accounts else { return }; state = .unlocked(accounts)
    }

    private func accept(_ opened: WorkspaceSession) async throws {
        do {
            let accounts = try await opened.accounts(), preferences = try? await opened.editingPreferences()
            await opened.applyCachePolicy(cachePolicy)
            session = opened; editingPreferences = preferences; state = .unlocked(accounts); lastError = ""
            startBackgroundWork(opened)
        } catch { try? await opened.signOut(); throw error }
    }
    private func open(password: String?) async throws {
        state = .unlocking
        let workspace = workspace, writer = writer
        let opened = try await Task.detached {
            try workspace.resumePendingRestore(writer: writer, password: password)
            do { return try WorkspaceSession(workspace: workspace, password: password, credentialWriter: writer) }
            catch Workspace.Failure.notReady { return try workspace.completeSetup(writer: writer, password: password) }
        }.value
        lockMode = try workspaceLock()
        try await accept(opened)
    }
    private func drop(_ expected: WorkspaceSession) {
        guard session === expected else { return }
        backupTask?.cancel(); backupTask = nil; availabilityTask?.cancel(); availabilityTask = nil; releaseWarmTask?.cancel(); releaseWarmTask = nil
        memoryPressure?.cancel(); memoryPressure = nil
        session = nil; editingPreferences = nil
        writer.lockCredentials()
    }
    private func startBackgroundWork(_ expected: WorkspaceSession) {
        backupTask?.cancel(); availabilityTask?.cancel(); releaseWarmTask?.cancel(); releaseWarmTask = nil
        // Under memory pressure the session frees what it can read or decode again, whatever the Performance setting allows.
        memoryPressure?.cancel()
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            guard MainActor.assumeIsolated({ self?.session === expected }) else { return }
            MainActor.assumeIsolated { self?.windowReads.allObjects.forEach { $0.releaseReads() } }
            Task { await expected.trimCachedMemory() }
        }
        pressure.resume(); memoryPressure = pressure
        if let warm = releaseWarmDelay {
            // A light start: one app at a time, after the workspace has opened, so Release opens with saved and then fresh status.
            releaseWarmTask = Task { [weak self] in
                do { try await Task.sleep(for: warm) } catch { return }
                guard !Task.isCancelled, self?.session === expected else { return }
                await expected.warmReleaseStatus()
            }
        }
        let writer = writer, delay = backupDelay
        backupTask = Task { [weak self] in
            while !Task.isCancelled, self?.session === expected {
                _ = try? await expected.runBackups(writer: writer)
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
        let interval = availabilityDelay
        availabilityTask = Task { [weak self] in
            while !Task.isCancelled, self?.session === expected {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self, !self.transitioning, self.session === expected else { continue }
                do { try expected.validateAccess() }
                catch {
                    self.transitioning = true; self.state = .closing; self.backupTask?.cancel(); self.releaseWarmTask?.cancel()
                    try? await expected.signOut()
                    self.drop(expected); self.lockMode = try? self.workspaceLock(); self.state = .locked; self.lastError = Self.message(for: error); self.transitioning = false
                    return
                }
            }
        }
    }

    public static func message(for error: Error) -> String {
        switch error {
        case let failure as PasswordVaultStorage.Failure: return failure.message
        case let failure as WorkspaceAuthenticationFailure: return failure.message
        case let failure as SessionFailure: return failure.message
        case CredentialVault.Failure.keychain(let status) where status == errSecUserCanceled || status == errSecAuthFailed:
            return "Keychain access was not allowed. Choose Always Allow when macOS asks, then try again."
        case let failure as TouchIDKeychainFailure: return failure.message
        case CredentialVault.Failure.keychain(errSecUserCanceled): return WorkspaceAuthenticationFailure.cancelled.message
        case CredentialVault.Failure.keychain(errSecAuthFailed): return WorkspaceAuthenticationFailure.denied.message
        case CredentialVault.Failure.keychain: return "Storebench could not read its Keychain item. Unlock your login keychain and try again."
        case CredentialVault.Failure.unreadable: return "The Storebench credentials in Keychain could not be read."
        case let failure as CredentialAccessFailure: return failure.message
        case Workspace.Failure.missingDatabase: return "The encrypted database is missing from the Storebench data folder. Saved data was left untouched."
        case EncryptedDocumentStore.Failure.wrongKey: return "The saved key does not open this database."
        case EncryptedDocumentStore.Failure.notPrivate, Setup.Failure.notPrivate, EncryptedMediaStore.Failure.notPrivate:
            return "The Storebench data folder must be private to your user account."
        case Setup.Failure.alreadyConfigured: return "Storebench is already set up. Try again to open it."
        default: return "Storebench could not open its saved data."
        }
    }
}
