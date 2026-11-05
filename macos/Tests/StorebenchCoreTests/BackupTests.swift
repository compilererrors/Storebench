import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct BackupTests {
    init() throws { _ = try TestIsolation.require() }
    static let passphrase = "synthetic backup passphrase"

    @Test func backupsVerifyRestoreAndRefuseDamage() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        chmod(root.path, 0o700)
        let media = try await session.media.write(Data("synthetic screenshot bytes".utf8))
        let parent = (try TestIsolation.require()).appendingPathComponent("storebench-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let backup = parent.appendingPathComponent("first")

        let created = try await session.createBackup(destination: backup, password: Self.passphrase)
        #expect(created.files == 2)
        #expect(try Backups.verify(backup, password: Self.passphrase) == created)
        #expect(throws: BackupFailure.authentication) { try Backups.verify(backup, password: "a different passphrase") }
        await #expect(throws: BackupFailure.exists) { try await session.createBackup(destination: backup, password: Self.passphrase) }
        await #expect(throws: BackupFailure.overlaps) { try await session.createBackup(destination: root.appendingPathComponent("inside"), password: Self.passphrase) }

        // Restore into a new folder: the key record is added to the vault and the store opens with the restore passphrase.
        let writer = VaultWriter(dataRoot: parent, storage: MemoryVaultStorage())
        let restored = parent.appendingPathComponent("restored")
        #expect(try Backups.restore(backup, to: restored, password: Self.passphrase, writer: writer) == created)
        let vault = try writer.read()
        let reopened = try WorkspaceSession(workspace: Workspace(root: restored), vault: vault, password: Self.passphrase)
        #expect(try await reopened.accounts().map(\.id) == session.accounts().map(\.id))
        #expect(try await reopened.media.read(media.hash) == Data("synthetic screenshot bytes".utf8))
        #expect(throws: BackupFailure.exists) { try Backups.restore(backup, to: restored, password: Self.passphrase, writer: writer) }

        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: backup.appendingPathComponent("media").path).first)
        let file = backup.appendingPathComponent("media/\(name)")
        let handle = try FileHandle(forUpdating: file)
        try handle.seek(toOffset: 100); let byte = try #require(try handle.read(upToCount: 1)); try handle.seek(toOffset: 100); try handle.write(contentsOf: Data([byte[0] ^ 0xff])); try handle.close()
        #expect(throws: BackupFailure.damaged) { try Backups.verify(backup, password: Self.passphrase) }
    }
}

@Suite(.serialized) struct BackupScheduleTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func journalWritesStayInsideTheOwnedDirectory() throws {
        let directory = try TestIsolation.require().appendingPathComponent("synthetic-scheduler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = BackupScheduler(directory: directory, intervalHours: 24, retain: 1, secretId: nil)
        try scheduler.writeJournal(BackupScheduler.Journal())
        #expect(try scheduler.readJournal().generations.isEmpty)
        let result = scheduler.tick(create: { url, _ in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }, verify: { _, _ in BackupResult(files: 1, bytes: 1, createdAt: CustomerReview.isoString(Date())) })
        #expect(result.error == nil)
        #expect(result.generations == 1)
    }
    @Test func settingsAndGenerationsFollowTheWebRules() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        chmod(root.path, 0o700)
        let parent = URL(fileURLWithPath: try #require(Backups.realPath((try TestIsolation.require())))).appendingPathComponent("storebench-schedule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage())
        let fresh = try BackupSchedule.read(root: root)
        #expect(fresh.revision == "initial" && !fresh.enabled)
        #expect(throws: BackupSettingsFailure.invalid("Enter the same restore passphrase twice, between 12 and 256 characters.")) {
            try BackupSchedule.save(root: root, writer: writer, revision: fresh.revision, enabled: true, destination: parent.appendingPathComponent("backups").path, intervalHours: 24, retain: 1, passphrase: "short", confirmation: "short")
        }
        #expect(throws: BackupSettingsFailure.self) {
            try BackupSchedule.save(root: root, writer: writer, revision: fresh.revision, enabled: false, destination: root.appendingPathComponent("inside").path, intervalHours: 24, retain: 1, passphrase: nil, confirmation: nil)
        }
        let saved = try BackupSchedule.save(root: root, writer: writer, revision: fresh.revision, enabled: true, destination: parent.appendingPathComponent("backups").path, intervalHours: 24, retain: 1,
                                            passphrase: BackupTests.passphrase, confirmation: BackupTests.passphrase)
        #expect(saved.hasPassphrase && saved.enabled)
        #expect(try BackupSchedule.read(root: root) == saved)
        #expect(throws: BackupSettingsFailure.conflict) {
            try BackupSchedule.save(root: root, writer: writer, revision: fresh.revision, enabled: false, destination: "", intervalHours: 24, retain: 1, passphrase: nil, confirmation: nil)
        }

        let first = try await session.runBackups(writer: writer)
        #expect(first.error == nil)
        #expect(first.state == .waiting && first.generations == 1)
        // Not due again yet: nothing new is created unless forced; forcing keeps only the newest generation.
        #expect(try await session.runBackups(writer: writer).generations == 1)
        let second = try await session.runBackups(writer: writer, force: true)
        #expect(second.generations == 1 && second.lastVerifiedAt != first.lastVerifiedAt)
        let scoped = BackupSchedule.scopedDirectory(saved.destination, root: root)
        let folders = try FileManager.default.contentsOfDirectory(atPath: scoped.path).filter { !$0.hasPrefix(".") && !$0.hasSuffix(".json") && !$0.hasSuffix(".mutex") }
        #expect(folders.count == 1)
        let folder = try #require(folders.first)
        #expect(try Backups.verify(scoped.appendingPathComponent(folder), password: BackupTests.passphrase).files >= 1)
    }
}
