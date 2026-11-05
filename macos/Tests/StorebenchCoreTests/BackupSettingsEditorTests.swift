import Darwin
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct BackupSettingsEditorTests {
    init() throws { _ = try TestIsolation.require() }
    private func settings(_ value: JSONText) throws -> BackupSettings {
        guard case .bool(let enabled)? = value["enabled"], case .bool(let hasPassphrase)? = value["hasPassphrase"],
              case .number(let interval)? = value["intervalHours"], case .number(let retain)? = value["retain"] else { throw BackupSettingsFailure.storage }
        return .init(revision: try #require(value["revision"]?.text), enabled: enabled, destination: try #require(value["destination"]?.text),
                     intervalHours: Int(interval), retain: Int(retain), hasPassphrase: hasPassphrase,
                     secretId: hasPassphrase ? "33333333-3333-4333-8333-333333333333" : nil)
    }
    @Test func comparisonsAndExplicitBaselineChoicesMatchTheActualPrimaryEditor() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/backup-editor.json")))
        guard case .array(let cases)? = fixture["cases"] else { throw BackupSettingsFailure.storage }
        #expect(cases.count == 720)
        for row in cases {
            let input = try settings(#require(row["inputs"])), latest = try settings(#require(row["latest"]))
            var editor = BackupSettingsEditor(); editor.load(input); editor.passphrase = row["passphrase"]?.text ?? ""; editor.confirmation = editor.passphrase
            try editor.readLatest(latest)
            #expect(editor.saved?.revision == input.revision && editor.inputs.matches(input))
            let changes = editor.changes?.map { JSONText.object([("id", .string($0.id)), ("label", .string($0.label)), ("before", .string($0.saved)), ("after", .string($0.edited))]) }
            #expect(changes.map(JSONText.array) == row["changes"])
            var kept = editor; kept.chooseLatest(keepEdits: true)
            let keep = try settings(#require(row["keep"]))
            #expect(kept.saved == latest && kept.inputs.matches(keep) && kept.passphrase == editor.passphrase && kept.confirmation == editor.confirmation)
            #expect(kept.dirty == (row["dirty"] == .bool(true) || !editor.passphrase.isEmpty))
            editor.chooseLatest(keepEdits: false)
            let use = try settings(#require(row["use"]))
            #expect(editor.saved == latest && editor.inputs.matches(use) && !editor.dirty && editor.latest == nil && editor.passphrase.isEmpty && editor.confirmation.isEmpty)
        }
    }
    @Test func unknownStatusRefreshAndRepeatedInitialReadsNeverSelectANewerBaseline() throws {
        var editor = BackupSettingsEditor()
        #expect(!editor.ready && !editor.canRun && !editor.canSave && editor.status == nil)
        #expect(throws: BackupSettingsFailure.self) { try editor.readLatest(.fresh) }
        editor.load(.fresh); editor.inputs.retain = 9; editor.passphrase = BackupTests.passphrase; editor.confirmation = editor.passphrase
        let latest = BackupSettings(revision: "11111111-1111-4111-8111-111111111111", enabled: true, destination: "/synthetic/backups", intervalHours: 6, retain: 3, hasPassphrase: true, secretId: "33333333-3333-4333-8333-333333333333")
        editor.load(latest)
        editor.receiveStatus(.init(state: .waiting, lastVerifiedAt: "2026-01-01T00:00:00.000Z", nextDueAt: "2026-01-01T06:00:00.000Z", generations: 2, error: nil))
        #expect(editor.saved?.revision == "initial" && editor.inputs.retain == 9 && editor.passphrase == BackupTests.passphrase && editor.dirty)
        try editor.readLatest(latest)
        #expect(try editor.saveIntent().revision == "initial")
        editor.chooseLatest(keepEdits: true)
        #expect(try editor.saveIntent().revision == latest.revision && editor.inputs.retain == 9 && !editor.canRun)
        editor.acknowledgeSave(latest)
        #expect(editor.canRun && !editor.dirty && editor.latest == nil && editor.passphrase.isEmpty && editor.confirmation.isEmpty)
        editor.inputs.retain += 1; #expect(!editor.canRun)
    }
    @Test func selectedFolderAndHiddenPassphraseSurviveKeepButAreClearedByUseSaved() throws {
        let folder = try TestIsolation.require().appendingPathComponent("synthetic-editor-selection")
        let access = BackupFolderAccess(requiresBookmark: true, create: { _ in Data("synthetic grant".utf8) }, resolve: { _ in .init(url: folder, stale: false) }, start: { _ in true }, stop: { _ in })
        var editor = BackupSettingsEditor(); editor.load(.fresh); editor.chooseFolder(try access.capture(folder))
        editor.passphrase = BackupTests.passphrase; editor.confirmation = editor.passphrase
        let latest = BackupSettings(revision: "11111111-1111-4111-8111-111111111111", enabled: false, destination: "", intervalHours: 6, retain: 3, hasPassphrase: false, secretId: nil)
        try editor.readLatest(latest); editor.chooseLatest(keepEdits: true)
        let intent = try editor.saveIntent()
        #expect(intent.revision == latest.revision && intent.selectedFolder?.bookmark == Data("synthetic grant".utf8) && intent.inputs.destination == folder.path && intent.passphrase == BackupTests.passphrase)
        try editor.readLatest(latest)
        #expect(editor.changes?.last?.edited == "New passphrase entered (hidden)")
        #expect(editor.changes?.allSatisfy { !$0.saved.contains(BackupTests.passphrase) && !$0.edited.contains(BackupTests.passphrase) } == true)
        editor.chooseLatest(keepEdits: false)
        #expect(editor.selectedFolder == nil && editor.passphrase.isEmpty && editor.confirmation.isEmpty && !editor.dirty)
    }
    @Test func validationUsesPrimaryUTF16LimitsAndExactPasswordBytes() throws {
        var editor = BackupSettingsEditor(); editor.load(.fresh)
        for interval in BackupSettings.intervals { editor.inputs.intervalHours = interval; #expect(editor.canSave) }
        editor.inputs.intervalHours = 2; #expect(!editor.canSave); editor.inputs.intervalHours = 24
        for retain in [0, 101, Int.max] { editor.inputs.retain = retain; #expect(!editor.canSave) }; editor.inputs.retain = 7
        for destination in ["relative", "/synthetic/\0", "/" + String(repeating: "x", count: 4096)] { editor.inputs.destination = destination; #expect(!editor.canSave) }
        editor.inputs.destination = "/" + String(repeating: "x", count: 4095); #expect(editor.canSave)
        editor.inputs.destination = "/synthetic/backups"; editor.inputs.enabled = true; #expect(!editor.canSave)
        for phrase in ["short", String(repeating: "😀", count: 129)] { editor.passphrase = phrase; editor.confirmation = phrase; #expect(!editor.canSave) }
        for phrase in [String(repeating: "😀", count: 6), String(repeating: "😀", count: 128)] { editor.passphrase = phrase; editor.confirmation = phrase; #expect(editor.canSave) }
        editor.passphrase = "synthetic é phrase"; editor.confirmation = "synthetic e\u{0301} phrase"; #expect(!editor.canSave)
        editor.passphrase = ""; editor.confirmation = BackupTests.passphrase; #expect(editor.dirty && !editor.canSave)
    }
    private final class Scope: @unchecked Sendable {
        private let lock = NSLock()
        private var starts = 0, stops = 0
        var counts: (Int, Int) { lock.withLock { (starts, stops) } }
        func access(_ folder: URL) -> BackupFolderAccess {
            .init(requiresBookmark: true, create: { _ in Data("synthetic grant".utf8) }, resolve: { _ in .init(url: folder, stale: false) },
                  start: { _ in self.lock.withLock { self.starts += 1 }; return true }, stop: { _ in self.lock.withLock { self.stops += 1 } })
        }
    }
    private final class Storage: VaultStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?, loads = 0
        var loadCount: Int { lock.withLock { loads } }
        func load() throws -> Data? { lock.withLock { loads += 1; return data } }
        func save(_ value: Data) throws { lock.withLock { data = value } }
    }
    @Test func staleSaveAndRunFailBeforePermissionAndSecretsAndRefreshNeverCreatesBackups() async throws {
        let parent = URL(fileURLWithPath: try #require(Backups.realPath(TestIsolation.require()))).appendingPathComponent("synthetic-backup-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("data"), folder = parent.appendingPathComponent("backups")
        let (session, _) = try DraftTests().session(directory: root), storage = Storage(), writer = VaultWriter(dataRoot: root, storage: storage), scope = Scope(), access = scope.access(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var editor = BackupSettingsEditor(); editor.load(try await session.backupSettings())
        editor.chooseFolder(try access.capture(folder)); editor.inputs.enabled = true; editor.passphrase = BackupTests.passphrase; editor.confirmation = editor.passphrase
        let firstIntent = try editor.saveIntent(), first = try await session.saveBackupSettings(firstIntent, writer: writer, folderAccess: access)
        let mutex = root.appendingPathComponent("backup-settings.mutex"), inode = try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber
        editor.acknowledgeSave(first); editor.inputs.retain = 3
        let stale = try editor.saveIntent()
        let next = try BackupSchedule.save(root: root, writer: writer, revision: first.revision, enabled: true, destination: folder.path, intervalHours: 6, retain: 2, passphrase: nil, confirmation: nil, folderAccess: access)
        let starts = scope.counts.0, vault = try writer.read().entries
        let loads = storage.loadCount
        await #expect(throws: BackupSettingsFailure.conflict) { try await session.saveBackupSettings(stale, writer: writer, folderAccess: access) }
        await #expect(throws: BackupSettingsFailure.conflict) { try await session.runBackups(writer: writer, force: true, folderAccess: access, expectedRevision: first.revision) }
        #expect(scope.counts.0 == starts)
        #expect(storage.loadCount == loads)
        #expect(try writer.read().entries == vault)
        let status = try await session.backupStatus(folderAccess: access)
        editor.receiveStatus(status)
        #expect(status.generations == 0 && editor.saved == first && editor.inputs.retain == 3 && editor.dirty)
        #expect(!FileManager.default.fileExists(atPath: BackupSchedule.scopedDirectory(folder.path, root: root).path))
        try editor.readLatest(try await session.backupSettings()); #expect(try editor.saveIntent().revision == first.revision)
        editor.chooseLatest(keepEdits: true)
        let saved = try await session.saveBackupSettings(editor.saveIntent(), writer: writer, folderAccess: access); editor.acknowledgeSave(saved)
        #expect(saved.revision != next.revision && saved.retain == 3 && saved.intervalHours == 24 && editor.canRun)
        let result = try await session.runBackups(writer: writer, force: true, folderAccess: access, expectedRevision: saved.revision)
        #expect(result.state == .waiting && result.generations == 1 && result.error == nil)
        editor.inputs.enabled = false
        let disabled = try await session.saveBackupSettings(editor.saveIntent(), writer: writer, folderAccess: access); editor.acknowledgeSave(disabled)
        let disabledStarts = scope.counts.0
        await #expect(throws: BackupSettingsFailure.conflict) { try await session.runBackups(writer: writer, force: true, folderAccess: access, expectedRevision: disabled.revision) }
        #expect(!editor.canRun && scope.counts.0 == disabledStarts && scope.counts.0 == scope.counts.1)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }
    @Test func scopeChangedDuringFolderAccessStopsSecretReadsAndInterruptedCommitRemovesOnlyItsNewSecret() async throws {
        let parent = URL(fileURLWithPath: try #require(Backups.realPath(TestIsolation.require()))).appendingPathComponent("synthetic-backup-interrupted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("data"), folder = parent.appendingPathComponent("backups")
        let (session, _) = try DraftTests().session(directory: root), storage = Storage(), writer = VaultWriter(dataRoot: root, storage: storage), scope = Scope(), access = scope.access(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var editor = BackupSettingsEditor(); editor.load(try await session.backupSettings()); editor.chooseFolder(try access.capture(folder))
        editor.inputs.enabled = true; editor.passphrase = BackupTests.passphrase; editor.confirmation = editor.passphrase
        let saved = try await session.saveBackupSettings(editor.saveIntent(), writer: writer, folderAccess: access); editor.acknowledgeSave(saved)
        let originalEntries = try writer.read().entries, originalGrant = try BackupFolderBookmarks.read(root: root, settings: saved)
        var checks = 0
        #expect(throws: CancellationError.self) {
            try BackupSchedule.save(root: root, writer: writer, revision: saved.revision, enabled: true, destination: folder.path, intervalHours: 6, retain: 2,
                passphrase: "synthetic new restore phrase", confirmation: "synthetic new restore phrase", folderAccess: access, check: {
                    checks += 1; if checks == 4 { throw CancellationError() }
                })
        }
        #expect(checks == 4)
        #expect(try BackupSchedule.read(root: root) == saved)
        #expect(try writer.read().entries == originalEntries)
        #expect(try BackupFolderBookmarks.read(root: root, settings: saved) == originalGrant)
        let loads = storage.loadCount
        let changedAccess = BackupFolderAccess(requiresBookmark: true, create: { _ in Data("synthetic grant".utf8) }, resolve: { _ in .init(url: folder, stale: false) },
            start: { _ in try? Setup.replaceGeneration(root.appendingPathComponent("state-v2")); return true }, stop: { _ in })
        editor.inputs.retain = 3
        await #expect(throws: SessionFailure.changed) { try await session.saveBackupSettings(editor.saveIntent(), writer: writer, folderAccess: changedAccess) }
        #expect(storage.loadCount == loads)
        #expect(try BackupSchedule.read(root: root) == saved)
    }
    @Test func closedChangedCanceledAndForeignSessionsCannotWriteBackupSettings() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage())
        var editor = BackupSettingsEditor(); editor.load(try await session.backupSettings()); editor.inputs.retain = 9
        let intent = try editor.saveIntent(), foreign = VaultWriter(dataRoot: root.appendingPathComponent("foreign"), storage: MemoryVaultStorage())
        await #expect(throws: BackupSettingsFailure.storage) { try await session.saveBackupSettings(intent, writer: foreign) }
        let canceled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await session.saveBackupSettings(intent, writer: writer) }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(try BackupSchedule.read(root: root) == .fresh)
        #expect(try writer.read().entries.isEmpty)
        try Setup.replaceGeneration(root.appendingPathComponent("state-v2"))
        await #expect(throws: SessionFailure.changed) { try await session.backupSettings() }
        await #expect(throws: SessionFailure.changed) { try await session.saveBackupSettings(intent, writer: writer) }
        #expect(try BackupSchedule.read(root: root) == .fresh)
        #expect(try writer.read().entries.isEmpty)
        _ = session.lifetime.beginClosing()
        await #expect(throws: SessionFailure.closed) { try await session.saveBackupSettings(intent, writer: writer) }
    }
    @Test func malformedNumericConfigurationsAreRejectedWithoutOverflowOrTruncation() throws {
        let (session, root) = try DraftTests().session(); _ = session; defer { try? FileManager.default.removeItem(at: root) }
        let writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage())
        let saved = try BackupSchedule.save(root: root, writer: writer, revision: "initial", enabled: false, destination: "", intervalHours: 24, retain: 7, passphrase: nil, confirmation: nil)
        let file = root.appendingPathComponent("backup-settings.json")
        for (key, number) in [("intervalHours", 6.5), ("intervalHours", 1e300), ("retain", 1.5), ("retain", 1e300)] {
            guard case .object(let pairs) = saved.json else { throw BackupSettingsFailure.storage }
            try BackupSchedule.writeAtomically(JSONText.object(pairs.map { ($0.0, $0.0 == key ? .number(number) : $0.1) }).data, to: file)
            #expect(throws: BackupSettingsFailure.storage) { try BackupSchedule.read(root: root) }
        }
        try BackupSchedule.writeAtomically(Data(repeating: 32, count: 16_385), to: file)
        #expect(throws: BackupSettingsFailure.storage) { try BackupSchedule.read(root: root) }
        try BackupSchedule.writeAtomically(saved.json.data, to: file); #expect(try BackupSchedule.read(root: root) == saved)
    }
    @Test func backupJournalStatusMatchesPrimaryAndRejectsMalformedCountsDatesAndSecrets() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/backup-editor.json")))
        guard case .array(let cases)? = fixture["journals"], case .number(let clock)? = fixture["now"] else { throw BackupSettingsFailure.storage }
        #expect(cases.count == 31)
        let directory = try TestIsolation.require().appendingPathComponent("synthetic-backup-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        for row in cases {
            try BackupSchedule.writeAtomically(#require(row["document"]).data, to: directory.appendingPathComponent("schedule.json"))
            let scheduler = BackupScheduler(directory: directory, intervalHours: 24, retain: 7, secretId: nil, now: { Date(timeIntervalSince1970: clock / 1000) })
            let status = scheduler.readStatus()
            let actual = JSONText.object([("state", .string(status.state.rawValue)), ("lastVerifiedAt", status.lastVerifiedAt.map(JSONText.string) ?? .null),
                ("nextDueAt", status.nextDueAt.map(JSONText.string) ?? .null), ("generations", .number(Double(status.generations))), ("error", status.error.map(JSONText.string) ?? .null)])
            #expect(actual == row["expected"])
        }
        try BackupSchedule.writeAtomically(Data(repeating: 32, count: 64_001), to: directory.appendingPathComponent("schedule.json"))
        #expect(BackupScheduler(directory: directory, intervalHours: 24, retain: 7, secretId: nil).readStatus().error == "SB-BACKUP-STORAGE")
    }
}
