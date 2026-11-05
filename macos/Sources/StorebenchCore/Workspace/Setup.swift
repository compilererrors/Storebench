import CryptoKit
import Darwin
import Foundation
import Security

extension KeyEnvelope {
    /// Wraps a database key: the raw key for Mac Keychain, or scrypt and AES-256-GCM for a password.
    public static func wrap(_ key: Data, password: String?) throws -> KeyEnvelope {
        try wrap(key, password: password, context: Self.context)
    }

    static func wrap(_ key: Data, password: String?, context: Data) throws -> KeyEnvelope {
        guard key.count == 32 else { throw Failure.invalidEnvelope }
        guard let password else { return .device(key: key) }
        guard (12...256).contains(password.utf16.count) else { throw Failure.incorrectPassword }
        let salt = try Setup.random(16), nonce = try Setup.random(12)
        var wrapping = try Scrypt.derive(password: Data(password.utf8), salt: salt, n: 1 << 17, r: 8, p: 1, length: 32)
        defer { wrapping.resetBytes(in: 0..<wrapping.count) }
        let sealed = try AES.GCM.seal(key, using: SymmetricKey(data: wrapping), nonce: AES.GCM.Nonce(data: nonce), authenticating: context)
        return .password(salt: salt, nonce: nonce, ciphertext: sealed.ciphertext, tag: sealed.tag)
    }

    var json: JSONText {
        switch self {
        case .device(let key): .object([("version", .number(1)), ("mode", .string("device")), ("key", .string(Base64URL.encode(key)))])
        case .password(let salt, let nonce, let ciphertext, let tag):
            .object([("version", .number(1)), ("mode", .string("password")), ("salt", .string(Base64URL.encode(salt))), ("nonce", .string(Base64URL.encode(nonce))),
                     ("ciphertext", .string(Base64URL.encode(ciphertext))), ("tag", .string(Base64URL.encode(tag)))])
        }
    }

    func record(ready: Bool) -> String {
        JSONText.object([("schemaVersion", .number(1)), ("phase", .string(ready ? "ready" : "preparing")), ("envelope", json)]).stringify()
    }
}

public enum Setup {
    public enum Failure: Error, Equatable { case notPrivate, alreadyConfigured, invalidPassword }

    static func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }) == errSecSuccess else { throw Failure.notPrivate }
        return bytes
    }

    /// The private `state-v2` folder inside a private data folder owned by this user, created when missing.
    static func privateDirectory(root: URL) throws -> URL {
        try TestIsolation.check(root)
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw Failure.notPrivate }
        let uid = getuid()
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == uid, info.st_mode & 0o077 == 0 else { throw Failure.notPrivate }
        let directory = root.appendingPathComponent("state-v2")
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw Failure.notPrivate }
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == uid, info.st_mode & 0o077 == 0 else { throw Failure.notPrivate }
        return directory
    }

    /// Replaced before any key change, so open sessions must sign in again.
    static func replaceGeneration(_ directory: URL) throws {
        let value = UUID().uuidString.lowercased(), temporary = directory.appendingPathComponent(".access-generation-\(UUID().uuidString.lowercased()).tmp")
        defer { unlink(temporary.path) }
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.notPrivate }
        let bytes = Array(value.utf8), written = write(descriptor, bytes, bytes.count); close(descriptor)
        guard written == bytes.count, rename(temporary.path, directory.appendingPathComponent("access-generation").path) == 0 else { throw Failure.notPrivate }
    }
}

extension Workspace {
    /// First run: a new random key is wrapped for Mac Keychain or a password,
    /// saved as "preparing", the encrypted database is created, then the record becomes "ready".
    public func createFresh(writer: VaultWriter, password: String?) throws -> WorkspaceSession {
        if let password, !(12...256).contains(password.utf16.count) { throw Setup.Failure.invalidPassword }
        let directory = try Setup.privateDirectory(root: root)
        return try FileMutex.withLock(directory.appendingPathComponent("bootstrap.mutex")) {
            if Backups.exists(root.appendingPathComponent("pending-restore")) { throw Failure.notReady }
            let entry = CredentialVault.databaseEntry(root: root), url = EncryptedDocumentStore.databaseURL(root: root)
            guard !FileManager.default.fileExists(atPath: url.path), try writer.value(entry) == nil else { throw Setup.Failure.alreadyConfigured }
            var key = try Setup.random(32)
            defer { key.resetBytes(in: 0..<key.count) }
            let envelope = try KeyEnvelope.wrap(key, password: writer.usesPasswordFile ? nil : password)
            try Setup.replaceGeneration(directory)
            let preparing = envelope.record(ready: false)
            _ = try writer.set(entry, preparing)
            _ = try EncryptedDocumentStore(url: url, key: key, create: true)
            _ = try writer.replace(entry, value: envelope.record(ready: true), expected: preparing)
            return try WorkspaceSession(unlocked: self, snapshot: writer.snapshot(), password: password, writer: writer)
        }
    }

    /// Finishes a setup that stopped after saving its "preparing" key record, as opening the data folder does.
    public func completeSetup(writer: VaultWriter, password: String?) throws -> WorkspaceSession {
        let directory = try Setup.privateDirectory(root: root)
        return try FileMutex.withLock(directory.appendingPathComponent("bootstrap.mutex")) {
            if Backups.exists(root.appendingPathComponent("pending-restore")) { try finishRestoreUnderBootstrap(writer: writer, password: password) }
            let entry = CredentialVault.databaseEntry(root: root)
            guard let text = try writer.value(entry) else { throw Failure.notSetUp }
            let record = try DatabaseKeyRecord(json: text)
            var key = try record.envelope.unwrap(password: password)
            defer { key.resetBytes(in: 0..<key.count) }
            let url = EncryptedDocumentStore.databaseURL(root: root)
            if record.ready, !FileManager.default.fileExists(atPath: url.path) { throw Failure.missingDatabase }
            _ = try EncryptedDocumentStore(url: url, key: key, create: !record.ready)
            if !record.ready { _ = try writer.replace(entry, value: record.envelope.record(ready: true), expected: text) }
            return try WorkspaceSession(unlocked: self, snapshot: writer.snapshot(), password: password, writer: writer)
        }
    }

    /// Whether the saved key record needs a password, before any unlock.
    public func lock(writer: VaultWriter) throws -> Lock? {
        let directory = try Setup.privateDirectory(root: root)
        return try FileMutex.withLock(directory.appendingPathComponent("bootstrap.mutex")) {
            let url = EncryptedDocumentStore.databaseURL(root: root)
            guard let text = try writer.value(CredentialVault.databaseEntry(root: root)) else {
                if FileManager.default.fileExists(atPath: url.path) { throw Failure.notSetUp }
                return nil
            }
            let record = try DatabaseKeyRecord(json: text)
            if record.ready, !FileManager.default.fileExists(atPath: url.path) { throw Failure.missingDatabase }
            return writer.usesPasswordFile || record.envelope.requiresPassword ? .password : .device
        }
    }
}

extension Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
