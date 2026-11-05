import Darwin
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct BackupFolderAccessTests {
    init() throws { _ = try TestIsolation.require() }

    private final class Scope: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0, starts = 0, stops = 0
        func start() -> Bool { lock.lock(); defer { lock.unlock() }; starts += 1; active += 1; return true }
        func stop() { lock.lock(); defer { lock.unlock() }; stops += 1; active -= 1 }
        var counts: (Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (active, starts, stops) }
        func access(_ folder: URL, stale: Bool = false, denied: Bool = false) -> BackupFolderAccess {
            BackupFolderAccess(requiresBookmark: true, create: { _ in Data("synthetic folder grant".utf8) },
                               resolve: { _ in .init(url: folder, stale: stale) },
                               start: { _ in denied ? false : self.start() }, stop: { _ in self.stop() })
        }
    }

    private struct Fixture {
        let parent, root, folder: URL
        let session: WorkspaceSession
        let writer: VaultWriter
        init() throws {
            parent = URL(fileURLWithPath: try #require(Backups.realPath(TestIsolation.require())))
                .appendingPathComponent("synthetic-folder-access-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            root = parent.appendingPathComponent("data"); folder = parent.appendingPathComponent("backups")
            let opened = try DraftTests().session(directory: root); session = opened.0
            writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage())
        }
        func save(_ settings: BackupSettings, access: BackupFolderAccess, selection: BackupFolderSelection? = nil, enabled: Bool = true, passphrase: String? = nil) throws -> BackupSettings {
            try BackupSchedule.save(root: root, writer: writer, revision: settings.revision, enabled: enabled, destination: folder.path,
                                    intervalHours: 24, retain: 2, passphrase: passphrase, confirmation: passphrase, selectedFolder: selection, folderAccess: access)
        }
        func firstSave(_ access: BackupFolderAccess) throws -> BackupSettings {
            // Open panels select an existing private directory.
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return try save(BackupSchedule.read(root: root), access: access, selection: access.capture(folder), passphrase: BackupTests.passphrase)
        }
        func remove() { try? FileManager.default.removeItem(at: parent) }
    }

    @Test func restartUsesTheSavedGrantThroughCreationVerificationAndStatus() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let firstScope = Scope(), access = firstScope.access(fixture.folder)
        let saved = try fixture.firstSave(access)
        #expect(firstScope.counts.0 == 0 && firstScope.counts.1 == firstScope.counts.2)
        let value = try JSONText.parse(Data(contentsOf: fixture.root.appendingPathComponent("backup-settings.json")))
        guard case .object(let fields) = value else { Issue.record("Expected shared settings"); return }
        #expect(Set(fields.map(\.0)) == ["schemaVersion", "revision", "enabled", "destination", "intervalHours", "retain", "secretId"])
        let grant = BackupFolderBookmarks.file(root: fixture.root, revision: saved.revision)
        #expect((try FileManager.default.attributesOfItem(atPath: grant.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        // No in-memory selection survives: a new adapter must load the persisted revision's grant.
        let reopenedScope = Scope(), reopened = reopenedScope.access(fixture.folder)
        let result = try await fixture.session.runBackups(writer: fixture.writer, folderAccess: reopened)
        #expect(result.state == .waiting && result.generations == 1 && result.error == nil)
        #expect(try await fixture.session.backupStatus(folderAccess: reopened).generations == 1)
        #expect(reopenedScope.counts.0 == 0 && reopenedScope.counts.1 == 2 && reopenedScope.counts.2 == 2)
        let next = try fixture.save(saved, access: reopened)
        #expect(next.revision != saved.revision)
        #expect(!FileManager.default.fileExists(atPath: grant.path))
        #expect(try BackupFolderBookmarks.read(root: fixture.root, settings: next) != nil)
    }

    @Test func staleMovedMissingAndDeniedGrantsNeverEnterTheBackupOperation() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let scope = Scope(), saved = try fixture.firstSave(scope.access(fixture.folder))
        let initialCounts = scope.counts
        let moved = fixture.parent.appendingPathComponent("different-folder")
        for access in [scope.access(fixture.folder, stale: true), scope.access(moved), scope.access(fixture.folder, denied: true)] {
            #expect(throws: BackupSettingsFailure.folderAccess) {
                try BackupSchedule.withDestination(root: fixture.root, access: access) { _, _ in Issue.record("Unusable grant entered the operation") }
            }
            #expect(throws: BackupSettingsFailure.folderAccess) { try fixture.save(saved, access: access) }
        }
        #expect(scope.counts.0 == 0 && scope.counts.1 == initialCounts.1 && scope.counts.2 == initialCounts.2)
        try FileManager.default.removeItem(at: BackupFolderBookmarks.file(root: fixture.root, revision: saved.revision))
        #expect(throws: BackupSettingsFailure.folderAccess) {
            try BackupSchedule.withDestination(root: fixture.root, access: scope.access(fixture.folder)) { _, _ in Issue.record("Missing grant entered the operation") }
        }
        #expect(try BackupSchedule.read(root: fixture.root) == saved)
    }

    @Test func aNewConfigurationCannotRevokeAnAlreadyOpenedOperationOrAcceptAStaleEditor() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let scope = Scope(), access = scope.access(fixture.folder)
        let saved = try fixture.firstSave(access)
        var next: BackupSettings?
        try BackupSchedule.withDestination(root: fixture.root, access: access) { snapshot, lease in
            #expect(snapshot == saved && lease?.url.path == fixture.folder.path && scope.counts.0 == 1)
            next = try fixture.save(saved, access: access)
            #expect(scope.counts.0 == 1)
            #expect(!FileManager.default.fileExists(atPath: BackupFolderBookmarks.file(root: fixture.root, revision: saved.revision).path))
        }
        #expect(scope.counts.0 == 0 && scope.counts.1 == scope.counts.2)
        let latest = try #require(next), selection = try access.capture(fixture.folder), before = scope.counts
        #expect(throws: BackupSettingsFailure.conflict) { try fixture.save(saved, access: access, selection: selection) }
        #expect(scope.counts.1 == before.1 && scope.counts.2 == before.2)
        #expect(try BackupSchedule.read(root: fixture.root) == latest)
        #expect(try BackupFolderBookmarks.read(root: fixture.root, settings: latest) == selection.bookmark)
        enum SyntheticFailure: Error { case interrupted }
        #expect(throws: SyntheticFailure.interrupted) {
            try BackupSchedule.withDestination(root: fixture.root, access: access) { _, _ in throw SyntheticFailure.interrupted }
        }
        #expect(scope.counts.0 == 0 && scope.counts.1 == scope.counts.2)
    }

    @Test func privateGrantReadersRejectLinksOversizedFilesAndWrongRevisionBeforeOpeningAccess() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let scope = Scope(), access = scope.access(fixture.folder), saved = try fixture.firstSave(access)
        let grant = BackupFolderBookmarks.file(root: fixture.root, revision: saved.revision), original = try Data(contentsOf: grant)
        let starts = scope.counts.1
        func rejected() {
            #expect(throws: BackupSettingsFailure.folderAccess) {
                try BackupSchedule.withDestination(root: fixture.root, access: access) { _, _ in Issue.record("Invalid grant entered the operation") }
            }
            #expect(scope.counts.1 == starts)
        }
        chmod(grant.path, 0o644); rejected(); chmod(grant.path, 0o600)
        try Data(repeating: 0, count: 100_001).write(to: grant); rejected()
        try Data("{}".utf8).write(to: grant); rejected()
        let wrong = BackupSettings(revision: UUID().uuidString.lowercased(), enabled: saved.enabled, destination: saved.destination,
                                   intervalHours: saved.intervalHours, retain: saved.retain, hasPassphrase: saved.hasPassphrase, secretId: saved.secretId)
        try BackupFolderBookmarks.write(Data("synthetic folder grant".utf8), root: fixture.root, settings: wrong)
        try FileManager.default.removeItem(at: grant)
        try FileManager.default.createSymbolicLink(at: grant, withDestinationURL: BackupFolderBookmarks.file(root: fixture.root, revision: wrong.revision)); rejected()
        try FileManager.default.removeItem(at: grant)
        try original.write(to: grant); chmod(grant.path, 0o600)
        // A regular file carrying another revision is also rejected.
        let other = try Data(contentsOf: BackupFolderBookmarks.file(root: fixture.root, revision: wrong.revision))
        try other.write(to: grant); rejected()
    }

    @Test func lostAccessCanBeDisabledAndExplicitlyReselectedWithoutLosingTheRestoreSecret() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let scope = Scope(), access = scope.access(fixture.folder), saved = try fixture.firstSave(access)
        try FileManager.default.removeItem(at: BackupFolderBookmarks.file(root: fixture.root, revision: saved.revision))
        let disabled = try fixture.save(saved, access: access, enabled: false)
        #expect(!disabled.enabled && disabled.secretId == saved.secretId)
        #expect(throws: BackupSettingsFailure.folderAccess) { try fixture.save(disabled, access: access) }
        let restored = try fixture.save(disabled, access: access, selection: access.capture(fixture.folder))
        #expect(restored.enabled && restored.secretId == saved.secretId)
        #expect(scope.counts.0 == 0 && scope.counts.1 == scope.counts.2)
    }
}
