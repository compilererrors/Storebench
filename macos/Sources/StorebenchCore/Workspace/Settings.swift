import Foundation

extension WorkspaceSession {
    /// The currency Storebench converts proceeds to, validated against the shared display catalog.
    public func displayCurrency() throws -> String {
        try storeAccess { store in try DisplayPreferences.stored(store.document(namespace: "display_preferences", key: "current")).currency }
    }

    public func setDisplayCurrency(_ code: String) throws {
        let preferences = try DisplayPreferences(currency: code)
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("display_preferences.mutex")) {
                try store.transaction { current in
                    _ = try DisplayPreferences.stored(current("display_preferences", "current"))
                    return [.put(namespace: "display_preferences", key: "current", json: preferences.json.data)]
                }
            }
        }
    }


}

extension Workspace {
    /// Changes how the database key is protected: the current lock must open the database first,
    /// the key itself never changes, and open sessions are signed out by a new access generation.
    public func changeLock(writer: VaultWriter, currentPassword: String?, newPassword: String?) throws {
        if let newPassword, !(12...256).contains(newPassword.utf16.count) { throw Setup.Failure.invalidPassword }
        let directory = try Setup.privateDirectory(root: root)
        try FileMutex.withLock(directory.appendingPathComponent("bootstrap.mutex")) {
            if writer.usesPasswordFile { _ = try verifyLockUnderBootstrap(writer: writer, password: currentPassword) }
            try changeLockUnderBootstrap(writer: writer, currentPassword: currentPassword, newPassword: newPassword)
        }
    }
    func verifyLockUnderBootstrap(writer: VaultWriter, password: String?) throws -> String {
        if let storage = writer.passwordStorage { try storage.verify(password: password) }
        let entry = CredentialVault.databaseEntry(root: root), url = EncryptedDocumentStore.databaseURL(root: root)
        guard let text = try writer.value(entry) else { throw Failure.notSetUp }
        let record = try DatabaseKeyRecord(json: text)
        guard record.ready, FileManager.default.fileExists(atPath: url.path) else { throw Failure.notReady }
        var key = try record.envelope.unwrap(password: password); defer { key.resetBytes(in: 0..<key.count) }
        _ = try EncryptedDocumentStore(url: url, key: key, writable: true)
        return text
    }
    func changeLockUnderBootstrap(writer: VaultWriter, currentPassword: String?, newPassword: String?) throws {
        if let storage = writer.passwordStorage {
            guard newPassword != nil else { throw PasswordVaultStorage.Failure.passwordRequired }
            try storage.changePassword(current: currentPassword, new: newPassword) {
                try Setup.replaceGeneration(EncryptedDocumentStore.databaseURL(root: root).deletingLastPathComponent())
            }
            writer.discardCachedCredentials()
            return
        }
        let text = try verifyLockUnderBootstrap(writer: writer, password: currentPassword)
        var key = try DatabaseKeyRecord(json: text).envelope.unwrap(password: currentPassword); defer { key.resetBytes(in: 0..<key.count) }
        let envelope = try KeyEnvelope.wrap(key, password: newPassword)
        try Setup.replaceGeneration(EncryptedDocumentStore.databaseURL(root: root).deletingLastPathComponent())
        _ = try writer.replace(CredentialVault.databaseEntry(root: root), value: envelope.record(ready: true), expected: text)
    }
}
