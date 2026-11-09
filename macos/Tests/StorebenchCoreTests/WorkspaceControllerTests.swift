import Foundation
import Security
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct WorkspaceControllerTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture() throws -> (WorkspaceController, Workspace, VaultWriter, URL) {
        let root = try TestIsolation.require().appendingPathComponent("synthetic-controller-\(UUID().uuidString)")
        let workspace = Workspace(root: root), writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage())
        return (WorkspaceController(workspace: workspace, writer: writer, backupDelay: .milliseconds(50), availabilityDelay: .milliseconds(20)), workspace, writer, root)
    }
    func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(try await condition()) { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
    }

    private actor CatalogProbe {
        var calls = 0
        private var entered = false, released = false
        private var continuations: [CheckedContinuation<Void, Never>] = []
        func run() async -> AppCatalogRefresh {
            calls += 1; entered = true
            if !released { await withCheckedContinuation { continuations.append($0) } }
            return AppCatalogRefresh(accounts: 0, refreshedAccounts: 0, appCount: 0, issues: [], sample: false)
        }
        func immediate() -> AppCatalogRefresh {
            calls += 1
            return AppCatalogRefresh(accounts: 0, refreshedAccounts: 0, appCount: 0, issues: [], sample: false)
        }
        func release() { released = true; let waiting = continuations; continuations = []; for continuation in waiting { continuation.resume() } }
        func wait() async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !entered { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
        }
    }

    @Test func appRefreshStaysBusyAndSharesTheWholeOperation() async throws {
        let (controller, _, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await controller.start(); await controller.setUp(password: nil)
        let probe = CatalogProbe()
        let first = Task { try await controller.refreshApps(using: { _ in await probe.run() }) }
        try await probe.wait()
        #expect(controller.refreshingApps && controller.appRefreshMessage.contains("Reading apps"))
        var joined = false
        let second = Task { joined = true; return try await controller.refreshApps(using: { _ in await probe.run() }) }
        try await wait { joined }
        let calls = await probe.calls
        #expect(calls == 1 && controller.refreshingApps)
        await probe.release()
        let result = try await first.value
        #expect(try await second.value == result)
        #expect(!controller.refreshingApps && controller.appRefreshMessage == result.message && !controller.appRefreshFailed)
        await controller.signOut()
    }

    @Test func quittingDrainsTheOwnedTransferBeforeDroppingTheSession() async throws {
        let (controller, _, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await controller.start(); await controller.setUp(password: nil)
        let session = try #require(controller.session), lifetime = await session.lifetime
        let lease = try lifetime.admit(.transfer)
        let closing = Task { await controller.prepareToTerminate() }
        try await wait { lifetime.status == .closing }
        #expect(controller.isTerminating && controller.state == .closing && controller.session === session && lifetime.activeCount == 1)
        await #expect(throws: SessionFailure.closed) { try await session.setDisplayCurrency("EUR") }
        lease.finish(); await closing.value
        #expect(controller.session == nil && controller.state == .closing && lifetime.status == .closed)
    }

    @Test func quittingDuringSignOutJoinsTheExistingDrain() async throws {
        let (controller, _, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await controller.start(); await controller.setUp(password: nil)
        let session = try #require(controller.session), lifetime = await session.lifetime
        let lease = try lifetime.admit(.transfer)
        let signOut = Task { await controller.signOut() }
        try await wait { lifetime.status == .closing }
        let quit = Task { await controller.prepareToTerminate() }
        #expect(controller.session === session)
        lease.finish(); await signOut.value; await quit.value
        #expect(controller.session == nil && controller.state == .closing && lifetime.status == .closed)
    }

    @Test func quittingSampleDataDoesNotReopenAnotherWorkspace() async throws {
        let (controller, workspace, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await controller.start(); await controller.openSampleData()
        #expect(controller.showingSampleData)
        let session = try #require(controller.session), lifetime = await session.lifetime
        await controller.prepareToTerminate()
        #expect(!controller.showingSampleData && controller.session == nil && controller.state == .closing)
        #expect(lifetime.status == .closed)
        #expect(!FileManager.default.fileExists(atPath: EncryptedDocumentStore.databaseURL(root: workspace.root).path))
    }

    @Test func quittingWhileSampleDataSignsOutPreventsItsAutomaticReopen() async throws {
        let (controller, workspace, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await controller.start(); await controller.openSampleData()
        let session = try #require(controller.session), lifetime = await session.lifetime
        let lease = try lifetime.admit(.transfer)
        let closingSample = Task { await controller.signOut() }
        try await wait { lifetime.status == .closing }
        let quitting = Task { await controller.prepareToTerminate() }
        try await wait { controller.isTerminating }
        lease.finish(); await closingSample.value; await quitting.value
        #expect(controller.session == nil && controller.state == .closing && !controller.showingSampleData)
        #expect(!FileManager.default.fileExists(atPath: EncryptedDocumentStore.databaseURL(root: workspace.root).path))
    }

    @Test func aRefreshCompletingAfterSignOutCannotRestoreTheOldAccountState() async throws {
        let (controller, _, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await controller.start(); await controller.setUp(password: nil)
        let probe = CatalogProbe()
        let pending = Task { try await controller.refreshApps(using: { _ in await probe.run() }) }
        try await probe.wait(); await controller.signOut(); await probe.release()
        do { _ = try await pending.value; Issue.record("An old catalog refresh unexpectedly succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(controller.session == nil && controller.state == .locked && !controller.refreshingApps && controller.appRefreshMessage.isEmpty)
    }

    @Test func sampleAppRefreshNeverUsesTheAppleCatalogService() async throws {
        let (controller, _, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await controller.start(); await controller.setUp(password: nil); await controller.openSampleData()
        let probe = CatalogProbe()
        let result = try await controller.refreshApps(using: { _ in await probe.immediate() })
        #expect(result.sample && result.appCount > 0 && controller.appRefreshMessage.contains("Sample"))
        #expect(await probe.calls == 0)
        await controller.closeSampleData(); await controller.signOut()
    }

    @Test func failedAutomaticStartsNeverRearmKeychainButExplicitRetryCan() async throws {
        let root = try TestIsolation.require().appendingPathComponent("synthetic-start-permission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CancelledPermissionStorage(), writer = VaultWriter(dataRoot: root, storage: storage)
        let controller = WorkspaceController(workspace: Workspace(root: root), writer: writer)
        await controller.start()
        guard case .failed = controller.state else { Issue.record("Expected a cancelled synthetic permission to stop startup."); return }
        #expect(storage.counts == [1, 1, 0])
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { await controller.start() } }
        }
        #expect(storage.counts == [1, 1, 0] && controller.session == nil)
        await controller.retryStart()
        #expect(storage.counts == [2, 2, 1] && controller.session == nil)
        await controller.start()
        #expect(storage.counts == [2, 2, 1])
    }
    @Test func firstSetupStartsRealSyntheticBackupsAndSignOutStopsNewTicks() async throws {
        let (controller, _, writer, root) = try fixture()
        let parent = URL(fileURLWithPath: try #require(Backups.realPath(TestIsolation.require()))).appendingPathComponent("synthetic-controller-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: parent) }
        await controller.start(); #expect(controller.state == .notSetUp)
        await controller.setUp(password: nil); #expect(controller.state == .unlocked([]))
        let original = try #require(controller.session)
        try await original.setDisplayCurrency("SEK")
        _ = try BackupSchedule.save(root: root, writer: writer, revision: "initial", enabled: true, destination: parent.appendingPathComponent("backups").path,
                                   intervalHours: 1, retain: 1, passphrase: BackupTests.passphrase, confirmation: BackupTests.passphrase)
        try await wait { try await original.backupStatus().generations == 1 }
        let settings = try BackupSchedule.read(root: root)
        let scheduler = BackupScheduler(directory: BackupSchedule.scopedDirectory(settings.destination, root: root), intervalHours: settings.intervalHours, retain: settings.retain, secretId: settings.secretId)
        let before = try scheduler.readJournal()
        #expect(before.pending == nil && before.generations.count == 1)
        let generation = before.generations[0]
        #expect(try Backups.verify(scheduler.generation(generation.id), password: BackupTests.passphrase).files == generation.files)
        await controller.signOut()
        #expect(controller.session == nil && controller.editingPreferences == nil && controller.state == .locked)
        #expect(await original.databaseKey.isEmpty)
        try await Task.sleep(for: .milliseconds(120))
        #expect(try scheduler.readJournal().generations.map(\.id) == [generation.id])
        await controller.unlock(password: "")
        let reopened = try #require(controller.session)
        #expect(reopened !== original && controller.state == .unlocked([]))
        #expect(try await reopened.displayCurrency() == "SEK")
        await controller.signOut()
    }

    @Test func passwordChangesPreserveDataAndWrongPasswordsKeepTheCurrentSession() async throws {
        let (controller, _, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await controller.start(); await controller.setUp(password: "synthetic-controller-password")
        let original = try #require(controller.session)
        try await original.setDisplayCurrency("SEK")
        await #expect(throws: KeyEnvelope.Failure.incorrectPassword) { try await controller.changeLock(currentPassword: "synthetic-incorrect-password", newPassword: nil) }
        #expect(controller.session === original && controller.state == .unlocked([]))
        #expect(try await original.displayCurrency() == "SEK")
        try await controller.changeLock(currentPassword: "synthetic-controller-password", newPassword: "synthetic-controller-new-password")
        #expect(controller.state == .locked && controller.session == nil)
        await #expect(throws: SessionFailure.closed) { try await original.displayCurrency() }
        await controller.unlock(password: "synthetic-controller-password")
        #expect(controller.state == .locked && controller.session == nil)
        await controller.unlock(password: "synthetic-controller-new-password")
        let current = try #require(controller.session)
        #expect(try await current.displayCurrency() == "SEK")
        try await controller.changeLock(currentPassword: "synthetic-controller-new-password", newPassword: nil)
        #expect(controller.lockMode == .device && controller.session !== current)
        #expect(try await #require(controller.session).displayCurrency() == "SEK")
        await controller.signOut()
    }

    @Test func anotherProtectionGenerationClosesTheOldControllerWithoutRevokingTheNewOne() async throws {
        let (controller, workspace, writer, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await controller.start(); await controller.setUp(password: nil)
        let previous = try #require(controller.session)
        try workspace.changeLock(writer: writer, currentPassword: nil, newPassword: "synthetic-other-protection")
        let current = try WorkspaceSession(workspace: workspace, password: "synthetic-other-protection", credentialWriter: writer)
        try await current.setDisplayCurrency("EUR")
        try await wait { controller.state == .locked }
        #expect(controller.session == nil && controller.lockMode == .password && controller.lastError == SessionFailure.changed.message)
        await #expect(throws: SessionFailure.closed) { try await previous.accounts() }
        #expect(try await current.displayCurrency() == "EUR")
        await controller.unlock(password: "synthetic-other-protection")
        #expect(try await #require(controller.session).displayCurrency() == "EUR")
        await controller.signOut(); try await current.signOut()
    }

    @Test func protectionChangedDuringDrainRequiresTheActualNewBaseline() async throws {
        let (controller, workspace, writer, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await controller.start(); await controller.setUp(password: nil)
        let previous = try #require(controller.session), lifetime = await previous.lifetime, lease = try lifetime.admit(.transfer)
        defer { lease.finish() }
        let changing = Task { try await controller.changeLock(currentPassword: nil, newPassword: "synthetic-stale-protection") }
        try await wait { lifetime.status == .closing }
        try workspace.changeLock(writer: writer, currentPassword: nil, newPassword: "synthetic-current-protection")
        let currentRecord = try writer.value(CredentialVault.databaseEntry(root: root))
        lease.finish()
        await #expect(throws: SessionFailure.changed) { try await changing.value }
        #expect(try writer.value(CredentialVault.databaseEntry(root: root)) == currentRecord)
        #expect(controller.state == .locked && controller.session == nil && controller.lockMode == .password)
        await #expect(throws: SessionFailure.changed) { try await previous.signOut() }
        await controller.unlock(password: "synthetic-current-protection")
        #expect(controller.session != nil && controller.state == .unlocked([]))
        await controller.signOut()
    }
}

private final class CancelledPermissionStorage: VaultStorage, @unchecked Sendable {
    private let lock = NSLock(), access = KeychainAccessSession()
    private var reads = 0, prompts = 0, retries = 0
    var counts: [Int] { lock.withLock { [reads, prompts, retries] } }
    func load() throws -> Data? {
        try lock.withLock {
            reads += 1
            let status = try access.perform { interactive in
                if interactive { prompts += 1; return errSecUserCanceled }
                return errSecInteractionNotAllowed
            }
            throw CredentialVault.Failure.keychain(status)
        }
    }
    func save(_ data: Data) throws { throw CredentialAccessFailure.paused }
    func retryAccess() { lock.withLock { retries += 1; access.retry() } }
}
