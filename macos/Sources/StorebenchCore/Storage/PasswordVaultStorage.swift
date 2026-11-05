import CryptoKit
import Darwin
import Foundation

/// Password-only credential persistence. It never delegates to Keychain, including legacy reads.
/// The writer holds the permanent vault mutex across every read, comparison and replacement.
public final class PasswordVaultStorage: VaultStorage, @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case locked, damaged, changed, alreadyExists, passwordRequired
        public var message: String {
            switch self {
            case .locked: "Unlock Storebench to use saved credentials."
            case .damaged: "The encrypted credential file could not be verified. Saved data was left untouched."
            case .changed: "Storage protection changed in another session. Unlock again with the current password."
            case .alreadyExists: "Password storage already exists. Unlock it to continue."
            case .passwordRequired: "Password storage requires a password of 12 to 256 characters."
            }
        }
    }
    let root: URL
    var url: URL { root.appendingPathComponent("credential-state/password-vault.json") }
    private var mutex: URL { root.appendingPathComponent("credential-state/vault.mutex") }
    private let stateLock = NSLock()
    private var master = Data()
    private var activeEnvelope: KeyEnvelope?
    static let keyContext = Data("storebench-password-vault-key-v1".utf8)
    private static let limit = 384 * 1024

    public init(dataRoot: URL) { root = dataRoot }
    deinit { master.resetBytes(in: 0..<master.count) }
    public func lock() { stateLock.withLock { master.resetBytes(in: 0..<master.count); master.removeAll(); activeEnvelope = nil } }

    /// The unencrypted header contains only a password-wrapped random key and authenticated ciphertext.
    public func exists() throws -> Bool {
        try PrivateCredentialFile.prepare(root: root)
        return try FileMutex.withLock(mutex) { try file() != nil }
    }

    public func create(password: String) throws {
        try PrivateCredentialFile.prepare(root: root)
        try FileMutex.withLock(mutex) { try createUnderVaultLock(password: password, data: Data(#"{"version":1,"entries":{}}"#.utf8)) }
    }
    func createUnderVaultLock(password: String, data: Data) throws {
        guard (12...256).contains(password.utf16.count) else { throw Failure.passwordRequired }
        guard try file() == nil else { throw Failure.alreadyExists }
        var key = try Setup.random(32); defer { key.resetBytes(in: 0..<key.count) }
        let envelope = try KeyEnvelope.wrap(key, password: password, context: Self.keyContext)
        let encoded = try sealed(data, key: key, envelope: envelope)
        try VaultWriter.rotate(root.appendingPathComponent("credential-state/vault.generation"))
        try PrivateCredentialFile.replace(encoded, at: url, limit: Self.limit)
        stateLock.withLock { master = key; activeEnvelope = envelope }
    }

    public func unlock(password: String) throws {
        try PrivateCredentialFile.prepare(root: root)
        try FileMutex.withLock(mutex) {
            guard let record = try file() else { throw Failure.damaged }
            var key = try record.envelope.unwrap(password: password, context: Self.keyContext)
            defer { key.resetBytes(in: 0..<key.count) }
            var data = try opened(record, key: key); defer { data.resetBytes(in: 0..<data.count) }
            _ = try CredentialVault(json: data)
            stateLock.withLock { master.resetBytes(in: 0..<master.count); master = key; activeEnvelope = record.envelope }
        }
    }
    public func verify(password: String?) throws {
        guard let password else { throw KeyEnvelope.Failure.passwordRequired }
        try FileMutex.withLock(mutex) {
            guard let record = try file() else { throw Failure.damaged }
            var key = try record.envelope.unwrap(password: password, context: Self.keyContext)
            defer { key.resetBytes(in: 0..<key.count) }
            try stateLock.withLock {
                guard activeEnvelope == record.envelope, master == key else { throw Failure.changed }
                var data = try opened(record, key: key); defer { data.resetBytes(in: 0..<data.count) }
                _ = try CredentialVault(json: data)
            }
        }
    }
    /// Called under the bootstrap mutex after admitted session work has drained.
    func changePassword(current: String?, new: String?, beforeCommit: () throws -> Void) throws {
        guard let new, (12...256).contains(new.utf16.count) else { throw Failure.passwordRequired }
        guard let current else { throw KeyEnvelope.Failure.passwordRequired }
        try FileMutex.withLock(mutex) {
            guard let record = try file() else { throw Failure.damaged }
            var key = try record.envelope.unwrap(password: current, context: Self.keyContext)
            defer { key.resetBytes(in: 0..<key.count) }
            try stateLock.withLock {
                guard activeEnvelope == record.envelope, master == key else { throw Failure.changed }
                var data = try opened(record, key: key); defer { data.resetBytes(in: 0..<data.count) }
                let replacement = try KeyEnvelope.wrap(key, password: new, context: Self.keyContext)
                let encoded = try sealed(data, key: key, envelope: replacement)
                try beforeCommit()
                try VaultWriter.rotate(root.appendingPathComponent("credential-state/vault.generation"))
                try PrivateCredentialFile.replace(encoded, at: url, limit: Self.limit)
                activeEnvelope = replacement
            }
        }
    }

    // VaultStorage methods are called only inside VaultWriter's OS mutex.
    public func validateAccess() throws { if var data = try load() { data.resetBytes(in: 0..<data.count) } }
    public func load() throws -> Data? {
        try stateLock.withLock {
            guard master.count == 32, let envelope = activeEnvelope else { throw Failure.locked }
            guard let record = try file() else { throw Failure.damaged }
            guard record.envelope == envelope else { throw Failure.changed }
            return try opened(record, key: master)
        }
    }
    public func save(_ data: Data) throws {
        try stateLock.withLock {
            guard master.count == 32, let envelope = activeEnvelope else { throw Failure.locked }
            guard let record = try file() else { throw Failure.damaged }
            guard record.envelope == envelope else { throw Failure.changed }
            try PrivateCredentialFile.replace(sealed(data, key: master, envelope: envelope), at: url, limit: Self.limit)
        }
    }

    private struct Record { let envelope: KeyEnvelope, combined: Data }
    private func file() throws -> Record? {
        try PrivateCredentialFile.prepare(root: root)
        guard let raw = try PrivateCredentialFile.read(url, limit: Self.limit) else { return nil }
        guard let value = try? JSONText.parse(raw), case .object(let fields) = value, fields.count == 3,
              Set(fields.map(\.0)) == ["schemaVersion", "envelope", "sealed"], value["schemaVersion"] == .number(1),
              case .object(let envelopeFields)? = value["envelope"], envelopeFields.count == 6,
              let object = try? JSONSerialization.jsonObject(with: value["envelope"]!.data) as? [String: Any],
              let envelope = try? KeyEnvelope(json: object), envelope.requiresPassword,
              let encoded = value["sealed"]?.text, encoded.utf8.count <= Self.limit,
              let combined = try? Base64URL.decode(encoded, length: encoded.utf8.count * 3 / 4), combined.count >= 28,
              combined.count <= 256 * 1024 + 28 else { throw Failure.damaged }
        return Record(envelope: envelope, combined: combined)
    }
    private func context(_ envelope: KeyEnvelope) -> Data {
        Data(("storebench-password-vault-v1\n" + CredentialVault.databaseEntry(root: root) + "\n" + envelope.json.stringify()).utf8)
    }
    private func opened(_ record: Record, key: Data) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: record.combined), using: SymmetricKey(data: key), authenticating: context(record.envelope)) }
        catch { throw Failure.damaged }
    }
    private func sealed(_ data: Data, key: Data, envelope: KeyEnvelope) throws -> Data {
        guard data.count <= 256 * 1024 else { throw VaultWriter.Failure.tooLarge }
        _ = try CredentialVault(json: data)
        guard let combined = try AES.GCM.seal(data, using: SymmetricKey(data: key), authenticating: context(envelope)).combined else { throw Failure.damaged }
        return JSONText.object([("schemaVersion", .number(1)), ("envelope", envelope.json), ("sealed", .string(Base64URL.encode(combined)))]).data
    }
}

/// Bounded private files; callers retain their shared OS mutex until atomic replacement finishes.
enum PrivateCredentialFile {
    static func prepare(root: URL) throws {
        _ = try Setup.privateDirectory(root: root)
        let directory = root.appendingPathComponent("credential-state")
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw Setup.Failure.notPrivate }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Setup.Failure.notPrivate }
    }
    static func read(_ url: URL, limit: Int) throws -> Data? {
        try TestIsolation.check(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { if errno == ENOENT { return nil }; throw PasswordVaultStorage.Failure.damaged }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= limit else { throw PasswordVaultStorage.Failure.damaged }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0 { if errno == EINTR { continue }; throw PasswordVaultStorage.Failure.damaged }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw PasswordVaultStorage.Failure.damaged }
        }
    }
    static func replace(_ data: Data, at url: URL, limit: Int) throws {
        guard data.count <= limit else { throw PasswordVaultStorage.Failure.damaged }
        _ = try read(url, limit: limit)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".credential-\(UUID().uuidString.lowercased()).tmp")
        try TestIsolation.check(temporary)
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Setup.Failure.notPrivate }
        defer { close(descriptor); unlink(temporary.path) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Setup.Failure.notPrivate }; offset += count
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw Setup.Failure.notPrivate }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Setup.Failure.notPrivate }; defer { close(parent) }
        guard fsync(parent) == 0 else { throw Setup.Failure.notPrivate }
    }
}
