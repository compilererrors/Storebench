import Darwin
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct PasswordStorageTests {
    static let password = "synthetic-password-storage", next = "synthetic-replacement-password"
    init() throws { _ = try TestIsolation.require() }
    func root() throws -> URL { try TestIsolation.require().appendingPathComponent("synthetic-password-vault-\(UUID().uuidString)") }
    private func controller(_ root: URL, _ keychain: CountingCredentialStorage) -> WorkspaceController {
        WorkspaceController(workspace: Workspace(root: root), keychainStorage: keychain, backupDelay: .seconds(3600), availabilityDelay: .seconds(3600))
    }

    @Test func firstScreenDoesNotProbeKeychainAndExplicitChoiceIsRemembered() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let keychain = CountingCredentialStorage(), model = controller(root, keychain)
        #expect(try model.workspaceLock() == nil)
        #expect(keychain.calls == 0)
        await model.start(); #expect(model.state == .chooseStorage && keychain.calls == 0)
        #expect(try model.workspaceLock() == nil)
        await model.setUp(password: nil); await model.unlock(password: Self.password)
        #expect(model.state == .chooseStorage && keychain.calls == 0)
        await withTaskGroup(of: Void.self) { group in for _ in 0..<12 { group.addTask { await model.start() } } }
        #expect(model.state == .chooseStorage && keychain.calls == 0)
        await model.selectStorage(.password)
        #expect(model.state == .notSetUp && keychain.calls == 0 && model.writer.usesPasswordFile)
        #expect(try CredentialStorageChoice.read(root: root) == .password)
        let next = controller(root, keychain); await next.start()
        #expect(next.state == .notSetUp && next.storageMode == .password && keychain.calls == 0)
    }

    @Test func keychainIsOnlyReadAfterAnExplicitKeychainChoice() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let keychain = CountingCredentialStorage(), model = controller(root, keychain)
        await model.start(); #expect(keychain.calls == 0)
        await model.selectStorage(.keychain)
        #expect(model.state == .notSetUp && model.storageMode == .keychain && keychain.calls > 0)
    }

    @Test func setupCredentialsRestartSignOutAndPasswordChangesNeverUseKeychain() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let keychain = CountingCredentialStorage(), model = controller(root, keychain)
        await model.start(); await model.selectStorage(.password); await model.setUp(password: Self.password)
        #expect(model.state == .unlocked([]) && model.lockMode == .password && keychain.calls == 0)
        let initial = try #require(model.session)
        try await initial.setDisplayCurrency("SEK")
        let values = ["apple:synthetic": "synthetic-api-secret", "reporter:synthetic": "synthetic-report-secret", "backup:synthetic": "synthetic-backup-secret"]
        _ = try model.writer.update { for (key, value) in values { $0[key] = value } }
        let storage = try #require(model.writer.passwordStorage)
        let raw = try Data(contentsOf: storage.url)
        for value in values.values { #expect(!String(decoding: raw, as: UTF8.self).contains(value)) }
        #expect(!String(decoding: raw, as: UTF8.self).contains(Self.password))
        let stale = PasswordVaultStorage(dataRoot: root), staleWriter = VaultWriter(dataRoot: root, storage: stale)
        try stale.unlock(password: Self.password); _ = try staleWriter.read()
        await #expect(throws: KeyEnvelope.Failure.incorrectPassword) { try await model.changeLock(currentPassword: Self.next, newPassword: Self.next) }
        #expect(model.session === initial)
        #expect(try await initial.displayCurrency() == "SEK")
        await #expect(throws: PasswordVaultStorage.Failure.passwordRequired) { try await model.changeLock(currentPassword: Self.password, newPassword: nil) }
        #expect(model.session === initial)
        try await model.changeLock(currentPassword: Self.password, newPassword: Self.next)
        #expect(model.state == .locked && model.session == nil)
        #expect(throws: PasswordVaultStorage.Failure.locked) { try model.writer.read() }
        #expect(throws: PasswordVaultStorage.Failure.changed) { try staleWriter.read() }
        #expect(throws: PasswordVaultStorage.Failure.changed) { try staleWriter.capture("apple:synthetic", root: root, cached: nil) }
        await model.unlock(password: Self.password); #expect(model.state == .locked)
        await model.unlock(password: Self.next)
        #expect(try await #require(model.session).displayCurrency() == "SEK")
        for (key, value) in values { #expect(try model.writer.read().entries[key] == value) }
        await model.signOut(); #expect(model.session == nil && model.state == .locked)
        #expect(throws: PasswordVaultStorage.Failure.locked) { try model.writer.read() }
        let restarted = controller(root, keychain); await restarted.start()
        #expect(restarted.state == .locked && keychain.calls == 0)
        await restarted.unlock(password: Self.next)
        #expect(try await #require(restarted.session).displayCurrency() == "SEK")
        #expect(try restarted.writer.read().entries["reporter:synthetic"] == values["reporter:synthetic"])
        #expect(keychain.calls == 0)
        await restarted.signOut()
    }

    @Test func independentWritersKeepEveryConcurrentUpdate() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let a = PasswordVaultStorage(dataRoot: root), b = PasswordVaultStorage(dataRoot: root)
        try a.create(password: Self.password); try b.unlock(password: Self.password)
        let writers = [VaultWriter(dataRoot: root, storage: a), VaultWriter(dataRoot: root, storage: b)]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                let writer = writers[index % 2]
                group.addTask { _ = try writer.set("apple:synthetic_\(index)", "synthetic-value-\(index)") }
            }
            try await group.waitForAll()
        }
        #expect(try writers[0].read().entries.count == 24)
        for index in 0..<24 { #expect(try writers[1].read().entries["apple:synthetic_\(index)"] == "synthetic-value-\(index)") }
        a.lock(); b.lock()
        #expect(throws: PasswordVaultStorage.Failure.locked) { try writers[0].read() }
    }

    @Test func corruptChoicesNeverFallBackToKeychainAndCommittedVaultWinsAfterAnInterruptedPreferenceSave() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try PrivateCredentialFile.prepare(root: root)
        try PrivateCredentialFile.replace(Data("invalid".utf8), at: CredentialStorageChoice.url(root), limit: 512)
        let keychain = CountingCredentialStorage(), failed = controller(root, keychain)
        await failed.start()
        guard case .failed = failed.state else { Issue.record("A corrupt preference must fail closed."); return }
        #expect(keychain.calls == 0)
        try FileManager.default.removeItem(at: CredentialStorageChoice.url(root))
        let storage = PasswordVaultStorage(dataRoot: root); try storage.create(password: Self.password); storage.lock()
        let restarted = controller(root, keychain); await restarted.start()
        #expect(restarted.state == .locked && keychain.calls == 0)
        #expect(throws: PasswordVaultStorage.Failure.changed) { try CredentialStorageChoice.save(.keychain, root: root, expected: nil) }
        await restarted.unlock(password: Self.password)
        #expect(restarted.state == .notSetUp && keychain.calls == 0)
        await restarted.setUp(password: Self.password)
        #expect(restarted.state == .unlocked([]) && keychain.calls == 0)
        await restarted.signOut()
    }

    @Test func unsafeFilesAndAuthenticatedCiphertextTamperingAreRejected() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = PasswordVaultStorage(dataRoot: root); try storage.create(password: Self.password)
        let original = try Data(contentsOf: storage.url), writer = VaultWriter(dataRoot: root, storage: storage)
        var json = try JSONText.parse(original)
        guard case .object(var fields) = json, let index = fields.firstIndex(where: { $0.0 == "sealed" }), let encoded = fields[index].1.text else { throw PasswordVaultStorage.Failure.damaged }
        var bytes = try Base64URL.decode(encoded, length: encoded.count * 3 / 4); bytes[bytes.count - 1] ^= 1
        fields[index].1 = .string(Base64URL.encode(bytes)); json = .object(fields)
        try PrivateCredentialFile.replace(json.data, at: storage.url, limit: 384 * 1024)
        #expect(throws: PasswordVaultStorage.Failure.damaged) { try writer.read() }
        try PrivateCredentialFile.replace(original, at: storage.url, limit: 384 * 1024)
        let outside = root.appendingPathComponent("synthetic-target")
        try PrivateCredentialFile.replace(original, at: outside, limit: 384 * 1024)
        try FileManager.default.removeItem(at: storage.url)
        #expect(symlink(outside.path, storage.url.path) == 0)
        #expect(throws: PasswordVaultStorage.Failure.damaged) { try storage.exists() }
        #expect(throws: PasswordVaultStorage.Failure.damaged) { try writer.set("apple:synthetic", "synthetic-value") }
        #expect(try Data(contentsOf: outside) == original)
        try FileManager.default.removeItem(at: storage.url)
        #expect(link(outside.path, storage.url.path) == 0)
        #expect(throws: PasswordVaultStorage.Failure.damaged) { try storage.exists() }
        try FileManager.default.removeItem(at: storage.url)
        #expect(mkfifo(storage.url.path, 0o600) == 0)
        #expect(throws: PasswordVaultStorage.Failure.damaged) { try storage.exists() }
    }

    @Test func explicitMigrationKeepsDataCopiesOnlyThisWorkspaceAndStopsAllLaterKeychainAccess() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let keychain = CountingCredentialStorage(), source = VaultWriter(dataRoot: root, storage: keychain)
        let old = try Workspace(root: root).createFresh(writer: source, password: Self.password)
        try await old.setDisplayCurrency("SEK")
        let account = Account(id: "synthetic", name: "Synthetic account", keyId: "SYNTHETIC1", keyType: "individual", issuerId: nil, appIds: ["100000001"], appNames: ["100000001": "Synthetic app"])
        try await old.seedPasswordMigrationAccount(account)
        _ = try source.set("apple:synthetic", "synthetic-migrated-api-secret")
        _ = try source.set("reporter:00000000-0000-4000-8000-000000000001", "synthetic-migrated-report-secret")
        _ = try source.set("apple:unrelated", "synthetic-unrelated-secret")
        _ = try source.set("appleid:synthetic", #"{"synthetic":"migrated-apple-id-session"}"#)
        _ = try source.set("appleidpassword:synthetic", #"{"appleId":"tester@example.com","password":"synthetic migrated password"}"#)
        _ = try source.set("appleid:unrelated", "synthetic-unrelated-session")
        let staleSession = try await old.credentialCapture("appleid:synthetic", writer: source, allowMissing: true)
        let staleVersion = await old.credentialVersions["appleid:synthetic"]
        try await old.signOut()
        let model = controller(root, keychain), before = keychain.calls
        await model.start(); #expect(model.state == .chooseStorage && keychain.calls == before)
        await model.selectStorage(.password); #expect(model.state == .migrateStorage && keychain.calls == before)
        await model.migrateStorage(currentPassword: Self.next, newPassword: Self.next)
        #expect(model.state == .migrateStorage)
        #expect(try PasswordVaultStorage(dataRoot: root).exists() == false)
        await model.migrateStorage(currentPassword: Self.password, newPassword: Self.next)
        guard case .unlocked(let accounts) = model.state else { Issue.record("Expected migrated storage to open."); return }
        #expect(accounts == [account])
        #expect(try await #require(model.session).displayCurrency() == "SEK")
        #expect(try model.writer.read().entries["apple:synthetic"] == "synthetic-migrated-api-secret")
        #expect(try model.writer.read().entries["reporter:00000000-0000-4000-8000-000000000001"] == "synthetic-migrated-report-secret")
        #expect(try model.writer.read().entries["apple:unrelated"] == nil)
        // The Apple ID session and saved password follow the account; another account's session does not.
        #expect(try model.writer.read().entries["appleid:synthetic"] == #"{"synthetic":"migrated-apple-id-session"}"#)
        #expect(try model.writer.read().entries["appleidpassword:synthetic"]?.contains("synthetic migrated password") == true)
        #expect(try model.writer.read().entries["appleid:unrelated"] == nil)
        let raw = String(decoding: try Data(contentsOf: try #require(model.writer.passwordStorage).url), as: UTF8.self)
        #expect(!raw.contains("migrated-apple-id-session") && !raw.contains("synthetic migrated password"))
        // A write captured before the copy cannot land in the Keychain copy afterwards.
        #expect(throws: CredentialAccessFailure.changed) {
            try source.writeCredential("appleid:synthetic", root: root, value: "synthetic-late-session", expected: staleSession, expectedVersion: staleVersion)
        }
        #expect(try source.read().entries["appleid:synthetic"] == #"{"synthetic":"migrated-apple-id-session"}"#)
        let after = keychain.calls
        await model.signOut()
        let restarted = controller(root, keychain); await restarted.start(); await restarted.unlock(password: Self.next)
        #expect(keychain.calls == after && restarted.state == .unlocked([account]))
        await restarted.signOut()
    }

    @Test func securitySettingsCanSwitchAnOpenKeychainWorkspaceWithoutLosingEdits() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let keychain = CountingCredentialStorage(), model = controller(root, keychain)
        await model.start(); await model.selectStorage(.keychain); await model.setUp(password: nil)
        let old = try #require(model.session)
        try await old.setDisplayCurrency("SEK")
        await model.choosePasswordStorage()
        #expect(model.state == .migrateStorage && model.session == nil && model.storageMode == .password)
        #expect(await old.lifetime.status == .closed)
        await model.migrateStorage(currentPassword: nil, newPassword: Self.password)
        #expect(try await #require(model.session).displayCurrency() == "SEK")
        let before = keychain.calls
        await model.signOut(); await model.unlock(password: Self.password)
        #expect(keychain.calls == before)
        await model.signOut()
    }

    @Test func migrationRejectsAnotherAccountsReportingConnection() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let keychain = CountingCredentialStorage(), writer = VaultWriter(dataRoot: root, storage: keychain)
        let old = try Workspace(root: root).createFresh(writer: writer, password: nil)
        let account = Account(id: "synthetic", name: "Synthetic account", keyId: "SYNTHETIC1", keyType: "individual", issuerId: nil, appIds: ["100000001"], appNames: nil)
        try await old.seedPasswordMigrationAccount(account, reportingAccountId: "synthetic-other")
        let before = try writer.read().entries
        try await old.signOut()
        let model = controller(root, keychain); await model.start(); await model.selectStorage(.password)
        await model.migrateStorage(currentPassword: nil, newPassword: Self.password)
        #expect(model.state == .migrateStorage && model.session == nil)
        #expect(try PasswordVaultStorage(dataRoot: root).exists() == false)
        #expect(try writer.read().entries == before)
    }

    @Test func passwordOnlyBackupsRestoreIntoOnboardingAndKeepMutexesAndMedia() async throws {
        let sourceRoot = try root(), restoredRoot = try root(), parent = try root()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { for url in [sourceRoot, restoredRoot, parent] { try? FileManager.default.removeItem(at: url) } }
        let keychain = CountingCredentialStorage(), source = controller(sourceRoot, keychain)
        await source.start(); await source.selectStorage(.password); await source.setUp(password: Self.password)
        let session = try #require(source.session)
        try await session.setDisplayCurrency("SEK")
        let image = try await session.media.write(Data("Synthetic restored image".utf8))
        let backup = parent.appendingPathComponent("synthetic-backup")
        _ = try await session.createBackup(destination: backup, password: Self.next)
        let restored = controller(restoredRoot, keychain)
        await restored.start(); await restored.selectStorage(.password)
        let mutex = restoredRoot.appendingPathComponent("state-v2/bootstrap.mutex")
        let inode = try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber
        await restored.restore(backup: backup, password: Self.password)
        #expect(restored.state == .notSetUp && keychain.calls == 0)
        await restored.restore(backup: backup, password: Self.next)
        let opened = try #require(restored.session)
        #expect(try await opened.displayCurrency() == "SEK")
        #expect(try await opened.media.read(image.hash) == Data("Synthetic restored image".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        #expect(!Backups.exists(restoredRoot.appendingPathComponent("pending-restore")) && keychain.calls == 0)
        await restored.signOut(); await restored.unlock(password: Self.next)
        #expect(try await #require(restored.session).displayCurrency() == "SEK")
        await restored.signOut(); await source.signOut()
    }

    @Test func interruptedRestoreRecoversItsStageAndNeverReplaysOverLaterEdits() async throws {
        let sourceRoot = try root(), destination = try root(), parent = try root()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { for url in [sourceRoot, destination, parent] { try? FileManager.default.removeItem(at: url) } }
        let sourceWriter = VaultWriter(dataRoot: sourceRoot, storage: MemoryVaultStorage())
        let source = try Workspace(root: sourceRoot).createFresh(writer: sourceWriter, password: nil)
        try await source.setDisplayCurrency("SEK")
        let backup = parent.appendingPathComponent("synthetic-backup")
        _ = try await source.createBackup(destination: backup, password: Self.password)
        let keychain = CountingCredentialStorage(), model = controller(destination, keychain)
        await model.start(); await model.selectStorage(.password)
        let storage = try #require(model.writer.passwordStorage); try storage.create(password: Self.password)
        // Synthetic crash fixture: complete stage was committed, but no database key record was saved yet.
        let pending = destination.appendingPathComponent("pending-restore")
        try FileManager.default.copyItem(at: backup, to: pending)
        storage.lock()
        let restarted = controller(destination, keychain); await restarted.start(); await restarted.unlock(password: Self.password)
        let current = try #require(restarted.session)
        #expect(try await current.displayCurrency() == "SEK")
        #expect(!Backups.exists(pending) && keychain.calls == 0)
        try await current.setDisplayCurrency("EUR")
        try FileManager.default.copyItem(at: backup, to: pending)
        // Synthetic crash fixture: the ready record committed before stage cleanup stopped.
        try Workspace(root: destination).resumePendingRestore(writer: restarted.writer, password: Self.password)
        #expect(try await current.displayCurrency() == "EUR")
        #expect(!Backups.exists(pending) && keychain.calls == 0)
        await restarted.signOut(); try await source.signOut()
    }
}

private extension WorkspaceSession {
    func seedPasswordMigrationAccount(_ account: Account, reportingAccountId: String? = nil) throws {
        try storeAccess { store in
            let reporter = ReportingConnection.Reporter(accountNumber: "10000001", vendorNumber: "10000001", connectedAt: "2026-01-01T00:00:00.000Z", credentialId: "00000000-0000-4000-8000-000000000001")
            let connection = ReportingConnection(accountId: reportingAccountId ?? account.id, vendorNumber: "10000001", reporter: reporter)
            try store.transaction { _ in [
                .put(namespace: "accounts", key: "all", json: JSONText.array([Self.json(account)]).data),
                .put(namespace: "sales_connection", key: account.id, json: connection.json.data),
            ] }
        }
    }
}

final class CountingCredentialStorage: VaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let memory = MemoryVaultStorage()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    private func called() { lock.withLock { count += 1 } }
    func load() throws -> Data? { called(); return try memory.load() }
    func save(_ data: Data) throws { called(); try memory.save(data) }
    func legacy(_ key: String) throws -> String? { called(); return nil }
    func removeLegacy(_ key: String) throws { called() }
    func retryAccess() { called() }
}
