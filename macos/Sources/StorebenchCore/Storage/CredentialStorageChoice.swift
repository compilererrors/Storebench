import Foundation

public enum CredentialStorageMode: String, Sendable { case keychain, password, touchID }

/// Startup reads only this private preference before the user consents to Keychain access.
enum CredentialStorageChoice {
    struct Preference: Sendable, Equatable {
        let mode: CredentialStorageMode
        var requireDeviceAuthentication = false
    }
    static func url(_ root: URL) -> URL { root.appendingPathComponent("credential-state/storage-choice.json") }
    static func readUnderBootstrap(root: URL) throws -> CredentialStorageMode? {
        try preferenceUnderBootstrap(root: root)?.mode
    }
    static func validateBackendUnderVault(root: URL, protectedKeychain: Bool) throws {
        if try preferenceUnderBootstrap(root: root)?.mode == .touchID, !protectedKeychain { throw CredentialAccessFailure.changed }
    }
    private static func preferenceUnderBootstrap(root: URL) throws -> Preference? {
        guard let data = try PrivateCredentialFile.read(url(root), limit: 512) else { return nil }
        guard let json = try? JSONText.parse(data), case .object(let fields) = json,
              fields.count == 2 || fields.count == 3,
              Set(fields.map(\.0)) == Set(["schemaVersion", "mode"] + (fields.count == 3 ? ["requireDeviceAuthentication"] : [])), json["schemaVersion"] == .number(1),
              let value = json["mode"]?.text, let mode = CredentialStorageMode(rawValue: value) else { throw PasswordVaultStorage.Failure.damaged }
        let required: Bool
        if let value = json["requireDeviceAuthentication"] { guard case .bool(let flag) = value else { throw PasswordVaultStorage.Failure.damaged }; required = flag }
        else { required = false }
        guard mode == .keychain || !required else { throw PasswordVaultStorage.Failure.damaged }
        return Preference(mode: mode, requireDeviceAuthentication: required)
    }
    static func read(root: URL) throws -> CredentialStorageMode? {
        try preference(root: root)?.mode
    }
    static func preference(root: URL) throws -> Preference? {
        try PrivateCredentialFile.prepare(root: root)
        return try FileMutex.withLock(root.appendingPathComponent("state-v2/bootstrap.mutex")) { try preferenceUnderBootstrap(root: root) }
    }
    static func save(_ mode: CredentialStorageMode, root: URL, expected: CredentialStorageMode?) throws {
        try PrivateCredentialFile.prepare(root: root)
        try FileMutex.withLock(root.appendingPathComponent("state-v2/bootstrap.mutex")) {
            guard try readUnderBootstrap(root: root) == expected else { throw CredentialAccessFailure.changed }
            // A committed password vault takes precedence even if setup stopped before saving its preference.
            if mode == .keychain, try PasswordVaultStorage(dataRoot: root).exists() { throw PasswordVaultStorage.Failure.changed }
            let previousRequirement = try preferenceUnderBootstrap(root: root)?.requireDeviceAuthentication ?? false
            let required = mode == .keychain && previousRequirement
            try write(Preference(mode: mode, requireDeviceAuthentication: required), root: root)
        }
    }
    static func saveAuthentication(_ required: Bool, root: URL, expected: Bool) throws {
        try PrivateCredentialFile.prepare(root: root)
        try FileMutex.withLock(root.appendingPathComponent("state-v2/bootstrap.mutex")) {
            guard let current = try preferenceUnderBootstrap(root: root), current.mode == .keychain, current.requireDeviceAuthentication == expected,
                  try !PasswordVaultStorage(dataRoot: root).exists() else { throw CredentialAccessFailure.changed }
            try write(Preference(mode: .keychain, requireDeviceAuthentication: required), root: root)
        }
    }
    /// Both credential backends and the starting preference remain protected by the existing locks.
    /// A failed copy or readback leaves the source and selected backend untouched.
    static func enableTouchID(root: URL, source: VaultWriter, destination: VaultStorage, expectedAuthentication: Bool) throws {
        try PrivateCredentialFile.prepare(root: root)
        try FileMutex.withLock(root.appendingPathComponent("state-v2/bootstrap.mutex")) {
            guard try preferenceUnderBootstrap(root: root) == Preference(mode: .keychain, requireDeviceAuthentication: expectedAuthentication),
                  try !PasswordVaultStorage(dataRoot: root).exists() else { throw CredentialAccessFailure.changed }
            try FileMutex.withLock(root.appendingPathComponent("credential-state/vault.mutex")) {
                let original = try source.readUnlocked()
                let bytes = JSONText.object([("version", .number(1)), ("entries", .object(original.entries.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }))]).data
                if let existing = try destination.load(), try CredentialVault(json: existing).entries != original.entries { throw TouchIDKeychainFailure.differentCopy }
                try destination.save(bytes)
                guard let checked = try destination.load(), try CredentialVault(json: checked).entries == original.entries else { throw TouchIDKeychainFailure.verification }
                try VaultWriter.rotate(root.appendingPathComponent("credential-state/vault.generation"))
                try write(Preference(mode: .touchID), root: root)
                source.discardCachedCredentials()
            }
        }
    }
    private static func write(_ preference: Preference, root: URL) throws {
        let data = JSONText.object([("schemaVersion", .number(1)), ("mode", .string(preference.mode.rawValue)), ("requireDeviceAuthentication", .bool(preference.requireDeviceAuthentication))]).data
        try PrivateCredentialFile.replace(data, at: url(root), limit: 512)
    }
}
