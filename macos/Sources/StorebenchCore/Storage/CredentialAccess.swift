import Darwin
import Foundation

public enum CredentialAccessFailure: Error, Equatable {
    case paused, changed, unreadable
    public var message: String {
        switch self {
        case .paused: "Saved credential access is paused. Unlock Storebench again, or retry Keychain access if your workspace uses Keychain."
        case .changed: "The saved key changed during verification. Read the current connection and reconnect explicitly. The newer key was kept."
        case .unreadable: "Saved credential access state could not be verified. Check your encrypted storage and unlock Storebench again."
        }
    }
}

extension VaultWriter {
    struct Snapshot { let vault: CredentialVault, version: String }
    struct Capture { let snapshot: Snapshot, credentialVersion: String }
    static func markerVersion(_ url: URL) throws -> String {
        try TestIsolation.check(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 { if errno == ENOENT { return "initial" }; throw CredentialAccessFailure.unreadable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size == 36,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CredentialAccessFailure.unreadable }
        var bytes = [UInt8](repeating: 0, count: 37)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, 37) }
        // Every session read checks this marker, so its 36 characters (a-f, 0-9 and -) are checked byte by byte.
        guard count == 36, bytes.prefix(36).allSatisfy({ (97...102).contains($0) || (48...57).contains($0) || $0 == 45 }),
              let value = String(bytes: bytes.prefix(36), encoding: .utf8) else { throw CredentialAccessFailure.unreadable }
        return value
    }
    static func credentialLocation(root: URL, key: String) throws -> URL {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["apple", "reporter", "appleid", "appleidpassword"].contains(parts[0]), parts[1].range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw VaultWriter.Failure.invalid }
        return root.appendingPathComponent("credential-state/\(JSONText.string("\(LocalPaths.lexical(root))\u{0}\(parts[0])\u{0}\(parts[1])").rawSHA256)")
    }
    func snapshot(migrating key: String? = nil) throws -> Snapshot {
        if let key {
            _ = try CredentialVault.legacyIdentity(key)
            guard key.hasPrefix("database:") || key.hasPrefix("backup:") else { throw VaultWriter.Failure.invalid }
        }
        return try FileMutex.withLock(directory.appendingPathComponent("vault.mutex")) {
            var vault = try readUnlocked()
            if let key, vault.entries[key] == nil, let legacy = try storage.legacy(key) {
                var entries = vault.entries; entries[key] = legacy
                vault = try replaceUnlocked(entries)
            }
            return Snapshot(vault: vault, version: try Self.markerVersion(directory.appendingPathComponent("vault.generation")))
        }
    }
    /// Per-credential protection precedes the shared vault lock.
    func capture(_ key: String, root: URL, cached: Snapshot?) throws -> Capture {
        let location = try Self.credentialLocation(root: root, key: key)
        return try FileMutex.withLock(location.appendingPathExtension("mutex")) {
            let credentialVersion = try Self.markerVersion(location.appendingPathExtension("generation"))
            return try FileMutex.withLock(directory.appendingPathComponent("vault.mutex")) {
                try storage.validateAccess()
                var version = try Self.markerVersion(directory.appendingPathComponent("vault.generation"))
                var vault = cached?.version == version ? cached!.vault : try readUnlocked()
                if vault.entries[key] == nil, let legacy = try storage.legacy(key) {
                    var entries = vault.entries; entries[key] = legacy
                    vault = try replaceUnlocked(entries); version = try Self.markerVersion(directory.appendingPathComponent("vault.generation"))
                    // Keep the original item until replacement/deletion, avoiding a second permission prompt.
                }
                return Capture(snapshot: Snapshot(vault: vault, version: version), credentialVersion: credentialVersion)
            }
        }
    }
    /// The exact captured value is compared under both process-shared locks before a replacement.
    func writeCredential(_ key: String, root: URL, value: String, expected: String?, expectedVersion: String? = nil, adding: Bool = false) throws -> Capture {
        let location = try Self.credentialLocation(root: root, key: key)
        return try FileMutex.withLock(location.appendingPathExtension("mutex")) {
            try FileMutex.withLock(directory.appendingPathComponent("vault.mutex")) {
                var entries = try readUnlocked().entries
                guard entries[key] == expected else { throw CredentialAccessFailure.changed }
                if let expectedVersion, try Self.markerVersion(location.appendingPathExtension("generation")) != expectedVersion { throw CredentialAccessFailure.changed }
                if adding {
                    guard entries[key] == nil else { throw VaultWriter.Failure.exists }
                    guard try storage.legacy(key) == nil else { throw VaultWriter.Failure.exists }
                }
                guard !value.isEmpty, value.utf8.count <= 10 * 1024 else { throw VaultWriter.Failure.tooLarge }
                try Self.rotate(location.appendingPathExtension("generation"))
                if !adding { try storage.removeLegacy(key) }
                entries[key] = value
                let vault = try replaceUnlocked(entries)
                return Capture(snapshot: Snapshot(vault: vault, version: try Self.markerVersion(directory.appendingPathComponent("vault.generation"))), credentialVersion: try Self.markerVersion(location.appendingPathExtension("generation")))
            }
        }
    }
    func removeCredential(_ key: String, root: URL, expected: String?, expectedVersion: String? = nil) throws -> Capture {
        let location = try Self.credentialLocation(root: root, key: key)
        return try FileMutex.withLock(location.appendingPathExtension("mutex")) {
            try FileMutex.withLock(directory.appendingPathComponent("vault.mutex")) {
                var entries = try readUnlocked().entries
                guard entries[key] == expected else { throw CredentialAccessFailure.changed }
                if let expectedVersion, try Self.markerVersion(location.appendingPathExtension("generation")) != expectedVersion { throw CredentialAccessFailure.changed }
                try Self.rotate(location.appendingPathExtension("generation")); try storage.removeLegacy(key); entries[key] = nil
                let vault = try replaceUnlocked(entries)
                return Capture(snapshot: Snapshot(vault: vault, version: try Self.markerVersion(directory.appendingPathComponent("vault.generation"))), credentialVersion: try Self.markerVersion(location.appendingPathExtension("generation")))
            }
        }
    }
}
