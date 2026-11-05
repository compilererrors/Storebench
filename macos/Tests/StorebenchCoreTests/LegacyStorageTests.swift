import CryptoKit
import Darwin
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct LegacyStorageTests {
    init() throws { _ = try TestIsolation.require() }
    struct Fixture {
        let parent: URL, root: URL, workspace: Workspace, storage: SyntheticCredentialStorage, writer: VaultWriter, entry: String, record: String
    }
    func fixture(database: Bool = true, ready: Bool = true, password: String? = nil) throws -> Fixture {
        let base = try TestIsolation.require(), canonical = try #require(Backups.realPath(base))
        let parent = URL(fileURLWithPath: canonical).appendingPathComponent("synthetic-storage-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if database {
            let url = EncryptedDocumentStore.databaseURL(root: root)
            try FileManager.default.copyItem(at: SyntheticFixtures.database(), to: url)
            chmod(url.path, 0o600)
        }
        let storage = SyntheticCredentialStorage(JSONText.object([("version", .number(1)), ("entries", .object([("apple:synthetic-other", .string("synthetic-other-key"))]))]).data)
        let record = try KeyEnvelope.wrap(Data(0..<32), password: password).record(ready: ready)
        let entry = CredentialVault.databaseEntry(root: root)
        return Fixture(parent: parent, root: root, workspace: Workspace(root: root), storage: storage, writer: VaultWriter(dataRoot: root, storage: storage), entry: entry, record: record)
    }
    func digest(_ root: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: EncryptedDocumentStore.databaseURL(root: root)))) }

    @Test func legacyServicesAndLexicalIdentitiesPreserveStoredCredentialNames() throws {
        let services = ["apple": "app.storebench.apple-api-key.v1", "reporter": "app.storebench.reporter-token.v1", "database": "app.storebench.database-key.v1", "backup": "app.storebench.backup-passphrase.v1"]
        for (purpose, service) in services {
            let identity = try CredentialVault.legacyIdentity("\(purpose):synthetic_123")
            #expect(identity.service == service && identity.account == "synthetic_123")
        }
        for key in ["other:synthetic", "database:", "backup:synthetic\n", "database:synthetic/path", "database:" + String(repeating: "a", count: 201)] {
            #expect(throws: VaultWriter.Failure.invalid) { try CredentialVault.legacyIdentity(key) }
        }
        let root = try TestIsolation.require()
        #expect(throws: TestIsolation.Failure.self) { try Setup.privateDirectory(root: root.deletingLastPathComponent()) }
        #expect(CredentialVault.databaseEntry(root: root.appendingPathComponent("unused/../data")) == CredentialVault.databaseEntry(root: root.appendingPathComponent("data")))
        #expect(throws: CredentialVault.Failure.unreadable) { try CredentialVault(json: Data(#"{"version":true,"entries":{}}"#.utf8)) }
        let tooLong = JSONText.object([("version", .number(1)), ("entries", .object([("backup:synthetic", .string(String(repeating: "😀", count: 10_001)))]))]).data
        #expect(throws: CredentialVault.Failure.unreadable) { try CredentialVault(json: tooLong) }
    }

    @Test func legacyDeviceOpenKeepsReportsRevisionsAndOtherCredentials() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        f.storage.legacy(f.entry, value: f.record)
        #expect(try f.workspace.lock(writer: f.writer) == .device)
        let legacyReads = f.storage.counts.legacyReads
        let session = try WorkspaceSession(workspace: f.workspace, credentialWriter: f.writer)
        #expect(try await session.revisions(accountId: "synthetic-account", appId: "1000000001").count == 2)
        #expect(try await session.sales(accountId: "synthetic-account", appId: "1000000001").count == 3)
        #expect(f.storage.counts.writes == 1 && f.storage.counts.legacyReads == legacyReads)
        #expect(f.storage.olderValue(f.entry) == f.record)
        #expect(try f.writer.read().entries["apple:synthetic-other"] == "synthetic-other-key")
    }

    @Test func legacyPasswordRequiresTheOriginalPasswordAndKeepsTheDatabase() async throws {
        let f = try fixture(password: "synthetic-storage-password"); defer { try? FileManager.default.removeItem(at: f.parent) }
        f.storage.legacy(f.entry, value: f.record)
        let before = try digest(f.root)
        #expect(try f.workspace.lock(writer: f.writer) == .password)
        #expect(throws: KeyEnvelope.Failure.incorrectPassword) { try WorkspaceSession(workspace: f.workspace, password: "synthetic-wrong-password", credentialWriter: f.writer) }
        #expect(try digest(f.root) == before)
        let session = try WorkspaceSession(workspace: f.workspace, password: "synthetic-storage-password", credentialWriter: f.writer)
        #expect(try await session.accounts().map(\.id) == ["synthetic-account"])
        #expect(f.storage.olderValue(f.entry) == f.record)
    }

    @Test(arguments: [true, false]) func interruptedLegacySetupCompletesWithoutChangingItsKey(existingDatabase: Bool) async throws {
        let f = try fixture(database: existingDatabase, ready: false); defer { try? FileManager.default.removeItem(at: f.parent) }
        f.storage.legacy(f.entry, value: f.record)
        #expect(try f.workspace.lock(writer: f.writer) == .device)
        #expect(throws: Workspace.Failure.notReady) { try WorkspaceSession(workspace: f.workspace, credentialWriter: f.writer) }
        f.storage.denyDeletion(true)
        #expect(throws: SyntheticCredentialStorage.Failure.self) { try f.workspace.completeSetup(writer: f.writer, password: nil) }
        #expect(try f.writer.value(f.entry) == f.record && f.storage.olderValue(f.entry) == f.record)
        f.storage.denyDeletion(false)
        let session = try f.workspace.completeSetup(writer: f.writer, password: nil)
        let text = try #require(try f.writer.value(f.entry)), record = try DatabaseKeyRecord(json: text)
        #expect(record.ready && record.envelope == .device(key: Data(0..<32)))
        #expect(f.storage.olderValue(f.entry) == nil)
        #expect(try await session.accounts().count == (existingDatabase ? 1 : 0))
    }

    @Test func missingKeyCannotStartFirstRunOverAnExistingDatabase() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        let before = try digest(f.root)
        #expect(throws: Workspace.Failure.notSetUp) { try f.workspace.lock(writer: f.writer) }
        #expect(throws: Setup.Failure.alreadyConfigured) { try f.workspace.createFresh(writer: f.writer, password: nil) }
        #expect(try digest(f.root) == before && f.storage.counts.writes == 0)
    }

    @Test func readyLegacyRecordCannotRecreateAMissingDatabase() throws {
        let f = try fixture(database: false); defer { try? FileManager.default.removeItem(at: f.parent) }
        f.storage.legacy(f.entry, value: f.record)
        #expect(throws: Workspace.Failure.missingDatabase) { try f.workspace.lock(writer: f.writer) }
        #expect(throws: Workspace.Failure.missingDatabase) { try f.workspace.completeSetup(writer: f.writer, password: nil) }
        #expect(throws: Workspace.Failure.missingDatabase) { try WorkspaceSession(workspace: f.workspace, credentialWriter: f.writer) }
        #expect(throws: Setup.Failure.alreadyConfigured) { try f.workspace.createFresh(writer: f.writer, password: nil) }
        #expect(!FileManager.default.fileExists(atPath: EncryptedDocumentStore.databaseURL(root: f.root).path))
        #expect(f.storage.olderValue(f.entry) == f.record)
    }

    @Test func deniedReadsAndCopiesFailWithoutChangingDataAndCanBeRetried() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        f.storage.legacy(f.entry, value: f.record)
        let before = try digest(f.root)
        f.storage.denyLegacy(true)
        #expect(throws: SyntheticCredentialStorage.Failure.self) { try f.workspace.lock(writer: f.writer) }
        f.storage.denyLegacy(false); f.storage.denySave(true)
        #expect(throws: SyntheticCredentialStorage.Failure.self) { try f.workspace.lock(writer: f.writer) }
        #expect(f.storage.counts.writes == 0 && f.storage.olderValue(f.entry) == f.record)
        #expect(try f.writer.read().entries[f.entry] == nil)
        f.storage.denySave(false)
        #expect(try f.workspace.lock(writer: f.writer) == .device)
        #expect(try digest(f.root) == before)
        f.storage.deny(true)
        #expect(throws: SyntheticCredentialStorage.Failure.self) { try WorkspaceSession(workspace: f.workspace, credentialWriter: f.writer) }
    }

    @Test func malformedLegacyRecordDoesNotTurnIntoFirstRun() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        let before = try digest(f.root)
        f.storage.legacy(f.entry, value: #"{"schemaVersion":1,"phase":"ready","envelope":{"version":1,"mode":"device","key":"invalid"}}"#)
        #expect(throws: KeyEnvelope.Failure.invalidEnvelope) { try f.workspace.lock(writer: f.writer) }
        #expect(throws: Setup.Failure.alreadyConfigured) { try f.workspace.createFresh(writer: f.writer, password: nil) }
        #expect(try digest(f.root) == before)
        #expect(f.storage.olderValue(f.entry) != nil)
    }

    @Test func changingProtectionRemovesTheOldEnvelopeOnlyAfterTheDatabaseOpens() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        f.storage.legacy(f.entry, value: f.record)
        f.storage.denyDeletion(true)
        #expect(throws: SyntheticCredentialStorage.Failure.self) { try f.workspace.changeLock(writer: f.writer, currentPassword: nil, newPassword: "synthetic-new-password") }
        #expect(try f.writer.value(f.entry) == f.record && f.storage.olderValue(f.entry) == f.record)
        f.storage.denyDeletion(false)
        try f.workspace.changeLock(writer: f.writer, currentPassword: nil, newPassword: "synthetic-new-password")
        #expect(f.storage.olderValue(f.entry) == nil)
        let recordText = try #require(try f.writer.value(f.entry)), record = try DatabaseKeyRecord(json: recordText)
        #expect(try record.envelope.unwrap(password: "synthetic-new-password") == Data(0..<32))
        let session = try WorkspaceSession(workspace: f.workspace, password: "synthetic-new-password", credentialWriter: f.writer)
        #expect(try await session.revisions(accountId: "synthetic-account", appId: "1000000001").count == 2)
    }

    @Test func concurrentMigrationsAndAdditionsPreserveEveryEntryAndTheMutexInode() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        f.storage.legacy(f.entry, value: f.record)
        let mutex = f.root.appendingPathComponent("credential-state/vault.mutex")
        try FileMutex.withLock(mutex) {}
        let inode = try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask { let value = try f.writer.value(f.entry); #expect(value == f.record) }
                group.addTask { _ = try f.writer.set("backup:synthetic-\(index)", "synthetic-passphrase-\(index)") }
            }
            try await group.waitForAll()
        }
        let entries = try f.writer.read().entries
        #expect(entries.count == 10 && entries[f.entry] == f.record && f.storage.counts.writes == 9)
        #expect(f.storage.olderValue(f.entry) == f.record)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }

    @Test func sharedValueWinsAndLargeValidOlderEntriesSurviveUnrelatedChanges() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        let oldKey = "backup:synthetic-old", value = String(repeating: "😀", count: 9_000)
        f.storage.legacy(oldKey, value: value)
        #expect(try f.writer.value(oldKey) == value)
        _ = try f.writer.set(f.entry, f.record)
        f.storage.legacy(f.entry, value: "synthetic-superseded-record")
        let reads = f.storage.counts.legacyReads
        #expect(try f.writer.value(f.entry) == f.record && f.storage.counts.legacyReads == reads)
        #expect(try f.writer.read().entries[oldKey] == value)
        #expect(throws: CredentialAccessFailure.changed) { try f.writer.replace(f.entry, value: f.record, expected: "synthetic-stale-record") }
        #expect(f.storage.olderValue(f.entry) == "synthetic-superseded-record")
        #expect(throws: VaultWriter.Failure.tooLarge) { try f.writer.set("backup:synthetic-new", value) }
    }

    @Test func addingOrDeletingChecksTheEarlierItemBeforeChangingTheSharedVault() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        let key = "backup:synthetic-secret"
        f.storage.legacy(key, value: "synthetic-old-passphrase")
        #expect(throws: VaultWriter.Failure.exists) { try f.writer.set(key, "synthetic-new-passphrase") }
        #expect(f.storage.counts.writes == 0)
        _ = try f.writer.value(key)
        f.storage.denyDeletion(true)
        #expect(throws: SyntheticCredentialStorage.Failure.self) { try f.writer.remove(key) }
        #expect(try f.writer.value(key) == "synthetic-old-passphrase")
        f.storage.denyDeletion(false)
        _ = try f.writer.remove(key, expected: "synthetic-old-passphrase")
        #expect(try f.writer.read().entries[key] == nil && f.storage.olderValue(key) == nil)
        #expect(try f.writer.value(key) == nil)
    }

    @Test func backupSchedulesMigrateTheirSecretAndKeepOlderGenerationPassphrases() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        _ = try f.writer.set(f.entry, f.record)
        let secret = "00000000-0000-0000-0000-000000000001", key = BackupSchedule.vaultKey(root: f.root, secretId: secret)
        f.storage.legacy(key, value: BackupTests.passphrase)
        let destination = f.parent.appendingPathComponent("backups")
        let settings = BackupSettings(revision: "00000000-0000-0000-0000-000000000002", enabled: true, destination: destination.path, intervalHours: 24, retain: 3, hasPassphrase: true, secretId: secret)
        try BackupSchedule.writeAtomically(settings.json.data, to: f.root.appendingPathComponent("backup-settings.json"))
        let saved = try BackupSchedule.save(root: f.root, writer: f.writer, revision: settings.revision, enabled: true, destination: destination.path, intervalHours: 24, retain: 3, passphrase: nil, confirmation: nil)
        #expect(saved.secretId == secret && f.storage.olderValue(key) == BackupTests.passphrase)
        let session = try WorkspaceSession(workspace: f.workspace, credentialWriter: f.writer)
        let first = try await session.runBackups(writer: f.writer)
        #expect(first.error == nil && first.generations == 1)
        let nextPassphrase = "synthetic replacement passphrase"
        let changed = try BackupSchedule.save(root: f.root, writer: f.writer, revision: saved.revision, enabled: true, destination: destination.path, intervalHours: 24, retain: 3, passphrase: nextPassphrase, confirmation: nextPassphrase)
        #expect(changed.secretId != secret)
        // Simulate a prior generation whose secret still lives only in its earlier item.
        _ = try f.writer.update { $0[key] = nil }
        let second = try await session.runBackups(writer: f.writer, force: true)
        #expect(second.error == nil && second.generations == 2)
        #expect(try f.writer.value(key) == BackupTests.passphrase)
        #expect(f.storage.olderValue(key) == BackupTests.passphrase)
        let newSecret = try #require(changed.secretId)
        #expect(try f.writer.value(BackupSchedule.vaultKey(root: f.root, secretId: newSecret)) == nextPassphrase)
    }

    @Test func restoreRespectsConflictingLegacyKeysAndCanReuseTheIdenticalEnvelope() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        _ = try f.writer.set(f.entry, f.record)
        let session = try WorkspaceSession(workspace: f.workspace, credentialWriter: f.writer)
        let backup = f.parent.appendingPathComponent("backup")
        _ = try await session.createBackup(destination: backup, password: BackupTests.passphrase)
        let record = try Backups.readManifest(backup).envelope.record(ready: true)
        for mode in [0, 1, 2] {
            let conflict = mode == 0, destination = f.parent.appendingPathComponent("restore-case-\(mode)"), entry = CredentialVault.databaseEntry(root: destination)
            let legacy = conflict ? f.record : record
            if mode == 2 {
                _ = try f.writer.set(entry, record)
                f.storage.denySave(true)
            } else { f.storage.legacy(entry, value: legacy) }
            if conflict {
                #expect(throws: BackupFailure.keyConflict) { try Backups.restore(backup, to: destination, password: BackupTests.passphrase, writer: f.writer) }
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                #expect(try f.writer.read().entries[entry] == nil)
            } else {
                _ = try Backups.restore(backup, to: destination, password: BackupTests.passphrase, writer: f.writer)
                let reopened = try WorkspaceSession(workspace: Workspace(root: destination), password: BackupTests.passphrase, credentialWriter: f.writer)
                #expect(try await reopened.accounts().map(\.id) == ["synthetic-account"])
            }
            if mode == 2 {
                #expect(try f.writer.read().entries[entry] == record && f.storage.olderValue(entry) == nil)
                f.storage.denySave(false)
            } else { #expect(f.storage.olderValue(entry) == legacy) }
        }
    }
}

@Suite struct LegacyStorageProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func databaseSetupWaitsForTheOwnedBootstrapProcessAndRecoversItsInterruptedLock() async throws {
        let root = try TestIsolation.require().appendingPathComponent("storage-lock-policy")
        let mutex = root.appendingPathComponent("state-v2/bootstrap.mutex")
        let storage = SyntheticCredentialStorage(Data(#"{"version":1,"entries":{}}"#.utf8)), writer = VaultWriter(dataRoot: root, storage: storage), workspace = Workspace(root: root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path))
        #expect(try FileMutex.tryLock(mutex) == nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: mutex.path), inode = try #require(attributes[.systemFileNumber] as? NSNumber)
        let pending = Task.detached { try workspace.createFresh(writer: writer, password: nil) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(storage.counts.reads == 0 && storage.counts.writes == 0)
        #expect(!FileManager.default.fileExists(atPath: EncryptedDocumentStore.databaseURL(root: root).path))
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        let session = try await pending.value
        #expect(try await session.accounts().isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        #expect(try workspace.lock(writer: writer) == .device)
        #expect(throws: Setup.Failure.alreadyConfigured) { try workspace.createFresh(writer: writer, password: nil) }
    }

    @Test func migrationWaitsForTheOwnedVaultProcessAndDoesNotReplaceItsOldMutex() async throws {
        let root = try TestIsolation.require().appendingPathComponent("vault-lock-policy"), mutex = root.appendingPathComponent("credential-state/vault.mutex")
        let storage = SyntheticCredentialStorage(Data(#"{"version":1,"entries":{}}"#.utf8)), writer = VaultWriter(dataRoot: root, storage: storage)
        let entry = CredentialVault.databaseEntry(root: root), record = try KeyEnvelope.wrap(Data(0..<32), password: nil).record(ready: true)
        storage.legacy(entry, value: record)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path))
        #expect(try FileMutex.tryLock(mutex) == nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: mutex.path), inode = try #require(attributes[.systemFileNumber] as? NSNumber)
        let pending = Task.detached { try writer.value(entry) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(storage.counts.reads == 0 && storage.counts.legacyReads == 0 && storage.counts.writes == 0)
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        #expect(try await pending.value == record)
        #expect(storage.counts.writes == 1 && storage.olderValue(entry) == record)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        #expect(try writer.value(entry) == record && storage.counts.writes == 1)
    }
}
