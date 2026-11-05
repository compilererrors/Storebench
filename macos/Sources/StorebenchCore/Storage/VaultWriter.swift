import Darwin
import Foundation
import Security

/// Credential persistence. Native users choose Keychain or a password-encrypted file.
public protocol VaultStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func legacy(_ key: String) throws -> String?
    func removeLegacy(_ key: String) throws
    func retryAccess()
    func validateAccess() throws
    func lockAccess()
}
extension VaultStorage {
    public func legacy(_ key: String) throws -> String? { nil }
    public func removeLegacy(_ key: String) throws {}
    public func retryAccess() {}
    public func validateAccess() throws {}
    public func lockAccess() {}
}

/// The login keychain's "Storebench credentials" item, in its fixed stored format.
public struct KeychainVaultStorage: VaultStorage {
    public init() {}
    var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: CredentialVault.service, kSecAttrAccount as String: CredentialVault.account] }

    private func perform(_ operation: () -> OSStatus) throws -> OSStatus {
        guard !Network.testMode else { throw CredentialVault.Failure.keychain(errSecNotAvailable) }
        return try KeychainAccessSession.shared.perform { interactive in
            // The shared item is in the login keychain. Its legacy Security API has a
            // process-wide interaction switch, so every native call uses this one lock.
            var previous = DarwinBoolean(false)
            let captured = SecKeychainGetUserInteractionAllowed(&previous)
            guard captured == errSecSuccess else { return captured }
            let configured = SecKeychainSetUserInteractionAllowed(interactive)
            guard configured == errSecSuccess else { return configured }
            defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
            return operation()
        }
    }

    public func retryAccess() { KeychainAccessSession.shared.retry() }

    public func load() throws -> Data? {
        // Guarded test runs never read or write the login keychain.
        guard !Network.testMode else { throw CredentialVault.Failure.keychain(errSecNotAvailable) }
        var result: CFTypeRef?, lookup = query
        lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = try perform { SecItemCopyMatching(lookup as CFDictionary, &result) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialVault.Failure.keychain(status) }
        return data
    }

    public func save(_ data: Data) throws {
        guard !Network.testMode else { throw CredentialVault.Failure.keychain(errSecNotAvailable) }
        let updated = try perform { SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) }
        var status = updated
        if updated == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrLabel as String] = "Storebench credentials"
            status = try perform { SecItemAdd(item as CFDictionary, nil) }
        }
        guard status == errSecSuccess else { throw CredentialVault.Failure.keychain(status) }
    }
    private func legacyQuery(_ key: String) throws -> [String: Any] {
        guard !Network.testMode else { throw CredentialVault.Failure.keychain(errSecNotAvailable) }
        let identity = try CredentialVault.legacyIdentity(key)
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: identity.service, kSecAttrAccount as String: identity.account]
    }
    public func legacy(_ key: String) throws -> String? {
        var query = try legacyQuery(key), result: CFTypeRef?
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = try perform { SecItemCopyMatching(query as CFDictionary, &result) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialVault.Failure.keychain(status) }
        guard let data = result as? Data, data.count <= 80_000, let value = String(data: data, encoding: .utf8), !value.isEmpty, value.utf16.count <= 20_000 else { throw CredentialAccessFailure.unreadable }
        return value
    }
    public func removeLegacy(_ key: String) throws {
        let query = try legacyQuery(key)
        let status = try perform { SecItemDelete(query as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialVault.Failure.keychain(status) }
    }
}

/// An in-memory vault for tests and previews.
public final class MemoryVaultStorage: VaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    public init(_ data: Data? = nil) { self.data = data }
    public func load() throws -> Data? { lock.withLock { data } }
    public func save(_ data: Data) throws { lock.withLock { self.data = data } }
}

/// Changes the shared credentials item under `credential-state/vault.mutex`, and rotates
/// `vault.generation` first so other processes never keep using an older copy.
public struct VaultWriter: Sendable {
    public enum Failure: Error, Equatable { case exists, tooLarge, invalid }
    let directory: URL, storage: VaultStorage
    private let protectedKeychain: Bool
    private let readSession = VaultReadSession()

    /// `dataRoot` is the Storebench data folder; its `credential-state` folder holds the vault lock.
    public init(dataRoot: URL, storage: VaultStorage = KeychainVaultStorage(), protectedKeychain: Bool = false) {
        self.directory = dataRoot.appendingPathComponent("credential-state"); self.storage = storage; self.protectedKeychain = protectedKeychain
    }

    public var usesPasswordFile: Bool { storage is PasswordVaultStorage }
    public var usesKeychain: Bool { !usesPasswordFile }
    var passwordStorage: PasswordVaultStorage? { storage as? PasswordVaultStorage }
    public func lockCredentials() { readSession.discard(); passwordStorage?.lock(); storage.lockAccess() }

    public func read() throws -> CredentialVault {
        try FileMutex.withLock(directory.appendingPathComponent("vault.mutex")) { try readUnlocked() }
    }

    func readUnlocked() throws -> CredentialVault {
        try storage.validateAccess()
        let version = try Self.markerVersion(directory.appendingPathComponent("vault.generation"))
        return try readSession.read(version: version) {
            // Backend transitions rotate this generation under the same OS mutex.
            try CredentialStorageChoice.validateBackendUnderVault(root: directory.deletingLastPathComponent(), protectedKeychain: protectedKeychain)
            return try CredentialVault(json: try storage.load() ?? Data(#"{"version":1,"entries":{}}"#.utf8))
        }
    }

    public func retryKeychainAccess() { readSession.discard(); storage.retryAccess() }
    public func discardCachedCredentials() { readSession.discard() }

    @discardableResult
    public func update(_ change: (inout [String: String]) throws -> Void) throws -> CredentialVault {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try FileMutex.withLock(directory.appendingPathComponent("vault.mutex")) {
            var entries = try readUnlocked().entries
            try change(&entries)
            return try replaceUnlocked(entries)
        }
    }

    func replaceUnlocked(_ entries: [String: String]) throws -> CredentialVault {
        let text = JSONText.object([("version", .number(1)), ("entries", .object(entries.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }))]).stringify()
        guard text.utf8.count <= 256 * 1024 else { throw Failure.tooLarge }
        let vault = try CredentialVault(json: Data(text.utf8))
        let marker = directory.appendingPathComponent("vault.generation")
        try Self.rotate(marker)
        readSession.discard()
        try storage.save(Data(text.utf8))
        return vault
    }

    /// Adds an entry that must not exist yet.
    public func set(_ key: String, _ value: String) throws -> CredentialVault {
        _ = try CredentialVault.legacyIdentity(key)
        guard !value.isEmpty, value.utf8.count <= 10 * 1024 else { throw Failure.tooLarge }
        return try update { entries in
            guard entries[key] == nil, try storage.legacy(key) == nil else { throw Failure.exists }
            entries[key] = value
        }
    }

    /// Database and backup entries migrate while the shared OS mutex protects the complete read and copy.
    public func value(_ key: String) throws -> String? { try snapshot(migrating: key).vault.entries[key] }

    /// Callers protect database changes with the bootstrap mutex before taking the vault mutex.
    public func replace(_ key: String, value: String, expected: String) throws -> CredentialVault {
        _ = try CredentialVault.legacyIdentity(key)
        guard !value.isEmpty, value.utf8.count <= 10 * 1024 else { throw Failure.tooLarge }
        return try update { entries in
            guard entries[key] == expected else { throw CredentialAccessFailure.changed }
            try storage.removeLegacy(key)
            entries[key] = value
        }
    }

    public func remove(_ key: String, expected: String? = nil) throws -> CredentialVault {
        _ = try CredentialVault.legacyIdentity(key)
        return try update { entries in
            if let expected, entries[key] != expected { throw CredentialAccessFailure.changed }
            try storage.removeLegacy(key)
            entries[key] = nil
        }
    }

    /// Restoring into an absent folder may reuse its identical saved envelope, including an earlier item.
    func ensureForRestore(_ key: String, value: String) throws -> Bool {
        _ = try CredentialVault.legacyIdentity(key)
        guard !value.isEmpty, value.utf8.count <= 10 * 1024 else { throw Failure.tooLarge }
        return try FileMutex.withLock(directory.appendingPathComponent("vault.mutex")) {
            var entries = try readUnlocked().entries
            if let existing = entries[key] {
                guard existing == value else { throw BackupFailure.keyConflict }
                return false
            }
            let legacy = try storage.legacy(key)
            if let legacy, legacy != value { throw BackupFailure.keyConflict }
            entries[key] = value
            _ = try replaceUnlocked(entries)
            return legacy == nil
        }
    }

    static func rotate(_ marker: URL) throws {
        let version = UUID().uuidString.lowercased(), temporary = marker.deletingLastPathComponent().appendingPathComponent("\(marker.lastPathComponent).\(version).tmp")
        defer { unlink(temporary.path) }
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.invalid }
        let bytes = Array(version.utf8), written = write(descriptor, bytes, bytes.count); close(descriptor)
        guard written == bytes.count, rename(temporary.path, marker.path) == 0 else { throw Failure.invalid }
    }
}
