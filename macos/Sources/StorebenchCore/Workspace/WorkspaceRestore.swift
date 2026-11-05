import Darwin
import Foundation

extension Workspace {
    private var pendingRestore: URL { root.appendingPathComponent("pending-restore") }

    /// Restores into the empty workspace already created by native onboarding, retaining permanent mutex files.
    public func restoreIntoEmptyWorkspace(backup: URL, password: String, writer: VaultWriter) throws {
        _ = try Backups.verify(backup, password: password)
        guard !Backups.overlaps(root, backup), !Backups.overlaps(backup, root) else { throw BackupFailure.overlaps }
        let directory = try Setup.privateDirectory(root: root)
        try PrivateCredentialFile.prepare(root: root)
        try FileMutex.withLock(directory.appendingPathComponent("bootstrap.mutex")) {
            guard !Backups.exists(EncryptedDocumentStore.databaseURL(root: root)), !Backups.exists(pendingRestore) else { throw BackupFailure.exists }
            if let storage = writer.passwordStorage {
                if try storage.exists() { try storage.unlock(password: password) }
                else { try storage.create(password: password) }
            }
            guard try writer.value(CredentialVault.databaseEntry(root: root)) == nil else { throw BackupFailure.exists }
            let manifest = try Backups.readManifest(backup)
            let stage = root.appendingPathComponent(".restore-stage-\(UUID().uuidString.lowercased())")
            guard mkdir(stage.path, 0o700) == 0 else { throw BackupFailure.notPrivate }
            defer { try? FileManager.default.removeItem(at: stage) }
            for entry in manifest.files {
                let target = try Backups.entryURL(stage, entry.name)
                try restoreParents(target.deletingLastPathComponent(), within: stage)
                let copied = try Backups.copyPrivateFile(try Backups.entryURL(backup, entry.name), target)
                guard copied.bytes == entry.bytes, copied.sha256 == entry.sha256 else { throw BackupFailure.damaged }
            }
            _ = try Backups.copyPrivateFile(backup.appendingPathComponent("manifest.json"), stage.appendingPathComponent("manifest.json"))
            guard rename(stage.path, pendingRestore.path) == 0 else { throw BackupFailure.exists }
            try finishRestoreUnderBootstrap(writer: writer, password: password)
        }
    }

    /// Recovery verifies the exact staged backup and never replays it against newer saved edits.
    public func resumePendingRestore(writer: VaultWriter, password: String?) throws {
        let directory = try Setup.privateDirectory(root: root)
        try FileMutex.withLock(directory.appendingPathComponent("bootstrap.mutex")) {
            if Backups.exists(pendingRestore) { try finishRestoreUnderBootstrap(writer: writer, password: password) }
        }
    }

    func finishRestoreUnderBootstrap(writer: VaultWriter, password: String?) throws {
        try TestIsolation.check(pendingRestore)
        let manifest = try Backups.readManifest(pendingRestore), entry = CredentialVault.databaseEntry(root: root)
        let saved = try writer.value(entry), record = try saved.map { try DatabaseKeyRecord(json: $0) }
        var key = try record?.envelope.unwrap(password: password) ?? manifest.envelope.unwrap(password: password)
        defer { key.resetBytes(in: 0..<key.count) }
        guard Backups.mac(manifest.body, key: key) == manifest.mac else { throw BackupFailure.authentication }
        for file in manifest.files {
            guard try Backups.digest(Backups.entryURL(pendingRestore, file.name), bytes: file.bytes) == file.sha256 else { throw BackupFailure.damaged }
        }
        let database = EncryptedDocumentStore.databaseURL(root: root)
        // A ready record proves this stage committed before cleanup stopped. Do not replay it.
        if record?.ready == true {
            guard Backups.exists(database) else { throw Workspace.Failure.missingDatabase }
            let verified = try EncryptedDocumentStore(url: database, key: key); verified.close()
            try FileManager.default.removeItem(at: pendingRestore)
            return
        }
        if saved == nil, Backups.exists(database) { throw BackupFailure.exists }
        let envelope = writer.usesPasswordFile ? KeyEnvelope.device(key: key) : manifest.envelope
        let preparing = saved ?? envelope.record(ready: false)
        if saved == nil { _ = try writer.set(entry, preparing) }
        let state = database.deletingLastPathComponent()
        for file in manifest.files.sorted(by: { ($0.name == Backups.databaseName ? 1 : 0, $0.name) < ($1.name == Backups.databaseName ? 1 : 0, $1.name) }) {
            let target = try Backups.entryURL(state, file.name)
            try restoreParents(target.deletingLastPathComponent(), within: state)
            if Backups.exists(target) {
                guard try Backups.digest(target, bytes: file.bytes) == file.sha256 else { throw BackupFailure.damaged }
                continue
            }
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".restore-file-\(UUID().uuidString.lowercased()).tmp")
            defer { unlink(temporary.path) }
            let copied = try Backups.copyPrivateFile(try Backups.entryURL(pendingRestore, file.name), temporary)
            guard copied.bytes == file.bytes, copied.sha256 == file.sha256, rename(temporary.path, target.path) == 0 else { throw BackupFailure.damaged }
        }
        let verified = try EncryptedDocumentStore(url: database, key: key); verified.close()
        try Setup.replaceGeneration(state)
        _ = try writer.replace(entry, value: envelope.record(ready: true), expected: preparing)
        try FileManager.default.removeItem(at: pendingRestore)
    }

    private func restoreParents(_ url: URL, within base: URL) throws {
        guard url.path == base.path || url.path.hasPrefix(base.path + "/") else { throw BackupFailure.invalid }
        if url.path != base.path { try restoreParents(url.deletingLastPathComponent(), within: base) }
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw BackupFailure.notPrivate }
        try Backups.privateDirectory(url)
    }
}
