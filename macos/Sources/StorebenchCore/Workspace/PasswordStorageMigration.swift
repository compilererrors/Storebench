import Foundation

extension Workspace {
    /// Explicitly copies this workspace's existing credentials into password-only storage, including each account's Apple ID session and
    /// saved Apple ID password. Earlier Keychain entries remain available to older installations; subsequent native access uses only the encrypted file.
    public func migrateToPasswordStorage(from source: VaultWriter, to destination: VaultWriter, currentPassword: String?, newPassword: String) throws {
        guard let storage = destination.passwordStorage, source.usesKeychain,
              source.directory == destination.directory else { throw VaultWriter.Failure.invalid }
        guard (12...256).contains(newPassword.utf16.count) else { throw PasswordVaultStorage.Failure.passwordRequired }
        let directory = try Setup.privateDirectory(root: root)
        try PrivateCredentialFile.prepare(root: root)
        try FileMutex.withLock(directory.appendingPathComponent("bootstrap.mutex")) {
            guard try CredentialStorageChoice.readUnderBootstrap(root: root) == .password else { throw CredentialAccessFailure.changed }
            guard try !storage.exists() else { throw PasswordVaultStorage.Failure.alreadyExists }
            try FileMutex.withLock(directory.appendingPathComponent("accounts.mutex")) {
                let databaseEntry = CredentialVault.databaseEntry(root: root)
                guard let text = try source.value(databaseEntry) else { throw Failure.notSetUp }
                let record = try DatabaseKeyRecord(json: text)
                guard record.ready else { throw Failure.notReady }
                var key = try record.envelope.unwrap(password: currentPassword); defer { key.resetBytes(in: 0..<key.count) }
                let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: key)
                defer { store.close() }
                let accounts = try store.document(namespace: "accounts", key: "all").map { try JSONDecoder().decode([Account].self, from: $0.payload) } ?? []
                guard accounts.count <= 1_000, Set(accounts.map(\.id)).count == accounts.count else { throw AccountFailure.invalid }
                let reportingLocks = try accounts.map { account -> URL in
                    guard ReportingConnection.validAccount(account.id) else { throw AccountFailure.invalid }
                    return directory.appendingPathComponent("reporter_" + JSONText.string(account.id).rawSHA256.prefix(32) + ".mutex")
                }.sorted { $0.path < $1.path }
                try withMigrationLocks(reportingLocks[...]) {
                    try FileMutex.withLock(root.appendingPathComponent("backup-settings.mutex")) {
                        var keys = Set(accounts.map { "apple:\($0.id)" }); keys.insert(databaseEntry)
                        for account in accounts {
                            if let document = try store.document(namespace: "sales_connection", key: account.id) {
                                let connection = try ReportingConnection(json: JSONText.parse(document.payload))
                                guard connection.accountId == account.id else { throw ReporterSetupFailure.changed }
                                if let reporter = connection.reporter { keys.insert("reporter:\(reporter.credentialId)") }
                            }
                        }
                        if let secretId = try BackupSchedule.read(root: root).secretId { keys.insert(BackupSchedule.vaultKey(root: root, secretId: secretId)) }
                        // Apple ID entries never had separate Keychain items, so only entries in the shared vault are copied.
                        let appleIDKeys = accounts.flatMap { [WorkspaceSession.appleIDKey($0.id), WorkspaceSession.appleIDPasswordKey($0.id)] }
                        let appleIDLocations = try appleIDKeys.map { try VaultWriter.credentialLocation(root: root, key: $0) }
                        let appleIDLocks = appleIDLocations.map { $0.appendingPathExtension("mutex") }.sorted { $0.path < $1.path }
                        try withMigrationLocks(appleIDLocks[...]) { try FileMutex.withLock(source.directory.appendingPathComponent("vault.mutex")) {
                            // Read the source again inside the complete copy critical section.
                            let vault = try source.readUnlocked()
                            guard vault.entries[databaseEntry] == text else { throw CredentialAccessFailure.changed }
                            var entries: [String: String] = [:]
                            for entry in keys.sorted() {
                                _ = try CredentialVault.legacyIdentity(entry)
                                entries[entry] = try vault.entries[entry] ?? source.storage.legacy(entry)
                            }
                            for entry in appleIDKeys { if let value = vault.entries[entry] { entries[entry] = value } }
                            entries[databaseEntry] = KeyEnvelope.device(key: key).record(ready: true)
                            let data = JSONText.object([("version", .number(1)), ("entries", .object(entries.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }))]).data
                            // Revoke old sessions before committing the durable, authenticated local copy.
                            try Setup.replaceGeneration(directory)
                            // An Apple ID write captured before the copy fails as changed instead of landing in the Keychain copy.
                            for location in appleIDLocations { try VaultWriter.rotate(location.appendingPathExtension("generation")) }
                            try storage.createUnderVaultLock(password: newPassword, data: data)
                            destination.discardCachedCredentials()
                        } }
                    }
                }
            }
        }
    }
    private func withMigrationLocks<T>(_ locks: ArraySlice<URL>, operation: () throws -> T) throws -> T {
        guard let first = locks.first else { return try operation() }
        return try FileMutex.withLock(first) { try withMigrationLocks(locks.dropFirst(), operation: operation) }
    }
}
