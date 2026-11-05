import CryptoKit
import Darwin
import Foundation

public struct BackupResult: Sendable, Equatable { public let files, bytes: Int; public let createdAt: String }

public enum BackupFailure: Error, Equatable {
    case notPrivate, exists, overlaps, invalid, damaged, authentication, keyConflict
    public var message: String {
        switch self {
        case .notPrivate: "Use a private folder owned by your user, with access restricted to you."
        case .exists: "The destination already exists."
        case .overlaps: "The backup and data folders must be separate."
        case .invalid: "This is not a valid Storebench encrypted backup."
        case .damaged: "A file in the backup is damaged or changed."
        case .authentication: "The backup could not be authenticated. Check the restore passphrase."
        case .keyConflict: "The restore destination already has a different encryption key."
        }
    }
}

/// Encrypted backups (manifest schema 2): an SQLCipher snapshot, encrypted media and staged build packages,
/// each listed with its size and SHA-256, the database key wrapped with the restore passphrase, and an HMAC over the manifest.
public enum Backups {
    static let databaseName = "storebench-v2.sqlite"
    static let mediaPattern = "^[a-f0-9]{64}\\.sbmedia$"
    static let packagePattern = "^build-packages/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/[a-f0-9]{64}\\.sbmedia$"

    struct Entry { let name: String; let bytes: Int; let sha256: String; var json: JSONText { .object([("name", .string(name)), ("bytes", .number(Double(bytes))), ("sha256", .string(sha256))]) } }

    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    static func privateDirectory(_ url: URL) throws {
        var info = stat()
        guard url.path.hasPrefix("/"), lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw BackupFailure.notPrivate }
    }

    static func overlaps(_ a: URL, _ b: URL) -> Bool {
        guard let x = LocalPaths.canonical(a), let y = LocalPaths.canonical(b) else { return true }
        return x == y || y.hasPrefix(x.hasSuffix("/") ? x : x + "/")
    }

    /// The canonical path with every link resolved, like `realpath(3)`.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }

    static func entryURL(_ root: URL, _ name: String) throws -> URL {
        guard name == databaseName || matches(name, "^media/[a-f0-9]{64}\\.sbmedia$") || matches(name, packagePattern) else { throw BackupFailure.invalid }
        return name.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// Copies one private file without following links and returns its size and digest.
    static func copyPrivateFile(_ source: URL, _ target: URL) throws -> (bytes: Int, sha256: String) {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw BackupFailure.damaged }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size > 0 else { throw BackupFailure.notPrivate }
        let output = open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw BackupFailure.exists }
        defer { close(output) }
        var hash = SHA256(), total = 0, buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = read(input, &buffer, buffer.count)
            guard count >= 0 else { throw BackupFailure.damaged }
            if count == 0 { break }
            total += count
            guard total <= Int(info.st_size) else { throw BackupFailure.damaged }
            hash.update(data: Data(buffer[0..<count]))
            var written = 0
            while written < count { let result = buffer.withUnsafeBytes { write(output, $0.baseAddress! + written, count - written) }; guard result > 0 else { throw BackupFailure.damaged }; written += result }
        }
        guard total == Int(info.st_size), fsync(output) == 0 else { throw BackupFailure.damaged }
        return (total, Data(hash.finalize()).map { String(format: "%02x", $0) }.joined())
    }

    static func digest(_ url: URL, bytes: Int) throws -> String {
        let input = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw BackupFailure.damaged }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) == bytes, info.st_mode & 0o077 == 0 else { throw BackupFailure.damaged }
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = read(input, &buffer, buffer.count)
            guard count >= 0 else { throw BackupFailure.damaged }
            if count == 0 { break }
            hash.update(data: Data(buffer[0..<count]))
        }
        return Data(hash.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    static func mac(_ body: JSONText, key: Data) -> String {
        var data = Data("storebench-encrypted-backup-v2\0".utf8); data.append(Data(body.stringify().utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))).map { String(format: "%02x", $0) }.joined()
    }

    struct Manifest { let body: JSONText; let mac: String; let envelope: KeyEnvelope; let createdAt: String; let files: [Entry] }

    static func readManifest(_ directory: URL) throws -> Manifest {
        try privateDirectory(directory)
        let url = directory.appendingPathComponent("manifest.json")
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 10_000_000, info.st_mode & 0o077 == 0 else { throw BackupFailure.invalid }
        let value = try JSONText.parse(try Data(contentsOf: url))
        guard value["schemaVersion"] == .number(2), let created = value["createdAt"]?.text, ASO.iso(created) != nil, case .array(let rows)? = value["files"], (1...50_000).contains(rows.count),
              let mac = value["mac"]?.text, matches(mac, "^[a-f0-9]{64}$"), let envelopeJSON = value["envelope"],
              let object = try JSONSerialization.jsonObject(with: envelopeJSON.data) as? [String: Any] else { throw BackupFailure.invalid }
        let envelope = try KeyEnvelope(json: object)
        guard envelope.requiresPassword else { throw BackupFailure.invalid }
        var seen = Set<String>()
        let files = try rows.map { row -> Entry in
            guard let name = row["name"]?.text, case .number(let bytes)? = row["bytes"], bytes >= 1, bytes == bytes.rounded(), bytes <= 9_007_199_254_740_991, let sha = row["sha256"]?.text,
                  matches(sha, "^[a-f0-9]{64}$"), !seen.contains(name) else { throw BackupFailure.invalid }
            _ = try entryURL(directory, name); seen.insert(name)
            return Entry(name: name, bytes: Int(bytes), sha256: sha)
        }
        guard seen.contains(databaseName), case .object(let pairs) = value else { throw BackupFailure.invalid }
        return Manifest(body: .object(pairs.filter { $0.0 != "mac" }), mac: mac, envelope: envelope, createdAt: created, files: files)
    }

    /// Checks every file's size and digest, the manifest's authentication, the database and every encrypted media file.
    public static func verify(_ directory: URL, password: String) throws -> BackupResult {
        let manifest = try readManifest(directory)
        var key: Data
        do { key = try manifest.envelope.unwrap(password: password) } catch { throw BackupFailure.authentication }
        defer { key.resetBytes(in: 0..<key.count) }
        guard mac(manifest.body, key: key) == manifest.mac else { throw BackupFailure.authentication }
        var bytes = 0
        for entry in manifest.files {
            let url = try entryURL(directory, entry.name)
            if entry.name.hasPrefix("media/") { try privateDirectory(url.deletingLastPathComponent()) }
            if matches(entry.name, packagePattern) { try privateDirectory(url.deletingLastPathComponent().deletingLastPathComponent()); try privateDirectory(url.deletingLastPathComponent()) }
            guard try digest(url, bytes: entry.bytes) == entry.sha256 else { throw BackupFailure.damaged }
            bytes += entry.bytes
        }
        do { try EncryptedDocumentStore.verifySnapshot(directory.appendingPathComponent(databaseName), key: key) } catch { throw BackupFailure.damaged }
        var stores: [String: EncryptedMediaStore] = [:]
        for entry in manifest.files where entry.name != databaseName {
            let url = try entryURL(directory, entry.name), parent = url.deletingLastPathComponent()
            let store = try stores[parent.path] ?? EncryptedMediaStore(directory: parent, key: key, maximumBytes: matches(entry.name, packagePattern) ? 16 * 1024 * 1024 * 1024 : 500 * 1024 * 1024)
            stores[parent.path] = store
            do { try store.verifyFile(named: url.lastPathComponent) } catch { throw BackupFailure.damaged }
        }
        return BackupResult(files: manifest.files.count, bytes: bytes, createdAt: manifest.createdAt)
    }

    struct StagedPackage { let id, sha256: String; let size: Int }

    static func stagedPackages(_ store: EncryptedDocumentStore) throws -> [StagedPackage] {
        let documents = try store.documents(namespace: "build_packages")
        guard documents.count < 5000 else { throw BackupFailure.invalid }
        var ids = Set<String>()
        return try documents.map { document in
            let value = try JSONText.parse(document.payload)
            guard let id = value["id"]?.text, matches(id, "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"), let sha = value["sha256"]?.text, matches(sha, "^[a-f0-9]{64}$"),
                  case .number(let size)? = value["size"], size >= 1, !ids.contains(id) else { throw BackupFailure.invalid }
            ids.insert(id)
            return StagedPackage(id: id, sha256: sha, size: Int(size))
        }
    }

    /// Restores a verified backup into a new data folder and stores its key record in the shared Keychain item.
    public static func restore(_ backup: URL, to destination: URL, password: String, writer: VaultWriter) throws -> BackupResult {
        let result = try verify(backup, password: password)
        guard destination.path.hasPrefix("/") else { throw BackupFailure.invalid }
        guard !overlaps(backup, destination), !overlaps(destination, backup) else { throw BackupFailure.overlaps }
        try privateDirectory(destination.deletingLastPathComponent())
        guard !exists(destination) else { throw BackupFailure.exists }
        let manifest = try readManifest(backup)
        let record = manifest.envelope.record(ready: true)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".storebench-encrypted-restore-\(UUID().uuidString.lowercased())")
        guard mkdir(stage.path, 0o700) == 0 else { throw BackupFailure.notPrivate }
        do {
            let state = stage.appendingPathComponent("state-v2")
            guard mkdir(state.path, 0o700) == 0, mkdir(state.appendingPathComponent("media").path, 0o700) == 0 else { throw BackupFailure.notPrivate }
            for entry in manifest.files {
                let target = try entryURL(state, entry.name)
                if matches(entry.name, packagePattern) {
                    let parent = target.deletingLastPathComponent()
                    _ = mkdir(parent.deletingLastPathComponent().path, 0o700); guard mkdir(parent.path, 0o700) == 0 else { throw BackupFailure.notPrivate }
                }
                let copied = try copyPrivateFile(try entryURL(backup, entry.name), target)
                guard copied.bytes == entry.bytes, copied.sha256 == entry.sha256 else { throw BackupFailure.damaged }
            }
            var key = try manifest.envelope.unwrap(password: password)
            defer { key.resetBytes(in: 0..<key.count) }
            let database = try EncryptedDocumentStore(url: state.appendingPathComponent(databaseName), key: key)
            for item in try stagedPackages(database) {
                let media = try EncryptedMediaStore(directory: state.appendingPathComponent("build-packages/\(item.id)"), key: key, maximumBytes: 16 * 1024 * 1024 * 1024)
                guard (try? media.metadata(item.sha256)) == item.size else { throw BackupFailure.damaged }
            }
            try FileMutex.withLock(destination.deletingLastPathComponent().appendingPathComponent(".storebench-restore.mutex")) {
                guard !exists(destination) else { throw BackupFailure.exists }
                let entry = CredentialVault.databaseEntry(root: destination)
                let created = try writer.ensureForRestore(entry, value: record)
                guard rename(stage.path, destination.path) == 0 else {
                    if created { _ = try? writer.remove(entry, expected: record) }
                    throw BackupFailure.exists
                }
            }
            return result
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }
}

extension WorkspaceSession {
    /// Writes a new encrypted backup folder at `destination`, verifies it, then moves it into place.
    public func createBackup(destination: URL, password: String) throws -> BackupResult {
        try requireSessionAccess()
        try Backups.privateDirectory(root)
        guard destination.path.hasPrefix("/") else { throw BackupFailure.invalid }
        guard !Backups.overlaps(root, destination), !Backups.overlaps(destination, root) else { throw BackupFailure.overlaps }
        let parent = destination.deletingLastPathComponent()
        try Backups.privateDirectory(parent)
        guard !Backups.exists(destination) else { throw BackupFailure.exists }
        let stage = parent.appendingPathComponent(".storebench-encrypted-backup-\(UUID().uuidString.lowercased())")
        guard mkdir(stage.path, 0o700) == 0 else { throw BackupFailure.notPrivate }
        do {
            var files: [Backups.Entry] = []
            let state = root.appendingPathComponent("state-v2"), key = databaseKey
            try storeAccess { store in
                try FileMutex.withLock(store.directory.appendingPathComponent("backup_media.mutex")) {
                    try store.exportSnapshot(to: stage.appendingPathComponent(Backups.databaseName), key: key)
                    let snapshot = try EncryptedDocumentStore(url: stage.appendingPathComponent(Backups.databaseName), key: key)
                    let packages = try Backups.stagedPackages(snapshot)
                    if !packages.isEmpty { guard mkdir(stage.appendingPathComponent("build-packages").path, 0o700) == 0 else { throw BackupFailure.notPrivate } }
                    for item in packages {
                        let source = state.appendingPathComponent("build-packages/\(item.id)")
                        try Backups.privateDirectory(source.deletingLastPathComponent()); try Backups.privateDirectory(source)
                        let names = try FileManager.default.contentsOfDirectory(atPath: source.path)
                        guard names.count == 1, Backups.matches(names[0], Backups.mediaPattern) else { throw BackupFailure.damaged }
                        let target = stage.appendingPathComponent("build-packages/\(item.id)")
                        guard mkdir(target.path, 0o700) == 0 else { throw BackupFailure.notPrivate }
                        let copied = try Backups.copyPrivateFile(source.appendingPathComponent(names[0]), target.appendingPathComponent(names[0]))
                        let media = try EncryptedMediaStore(directory: source, key: key, maximumBytes: 16 * 1024 * 1024 * 1024)
                        guard try media.metadata(item.sha256) == item.size else { throw BackupFailure.damaged }
                        files.append(Backups.Entry(name: "build-packages/\(item.id)/\(names[0])", bytes: copied.bytes, sha256: copied.sha256))
                    }
                }
            }
            let snapshot = stage.appendingPathComponent(Backups.databaseName)
            let size = (try FileManager.default.attributesOfItem(atPath: snapshot.path)[.size] as? NSNumber)?.intValue ?? 0
            files.insert(Backups.Entry(name: Backups.databaseName, bytes: size, sha256: try Backups.digest(snapshot, bytes: size)), at: 0)
            let sourceMedia = state.appendingPathComponent("media")
            try Backups.privateDirectory(sourceMedia)
            guard mkdir(stage.appendingPathComponent("media").path, 0o700) == 0 else { throw BackupFailure.notPrivate }
            for name in try FileManager.default.contentsOfDirectory(atPath: sourceMedia.path).filter({ Backups.matches($0, Backups.mediaPattern) }).sorted() {
                let copied = try Backups.copyPrivateFile(sourceMedia.appendingPathComponent(name), stage.appendingPathComponent("media/\(name)"))
                files.append(Backups.Entry(name: "media/\(name)", bytes: copied.bytes, sha256: copied.sha256))
            }
            let body = JSONText.object([("schemaVersion", .number(2)), ("createdAt", .string(CustomerReview.isoString(Date()))), ("envelope", try KeyEnvelope.wrap(key, password: password).json), ("files", .array(files.map(\.json)))])
            guard case .object(var pairs) = body else { throw BackupFailure.invalid }
            pairs.append(("mac", .string(Backups.mac(body, key: key))))
            let manifest = stage.appendingPathComponent("manifest.json")
            let descriptor = open(manifest.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw BackupFailure.exists }
            let data = JSONText.object(pairs).data
            let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, data.count) }
            fsync(descriptor); close(descriptor)
            guard written == data.count else { throw BackupFailure.damaged }
            let result = try Backups.verify(stage, password: password)
            try FileMutex.withLock(parent.appendingPathComponent(".storebench-backup.mutex")) {
                guard !Backups.exists(destination) else { throw BackupFailure.exists }
                guard rename(stage.path, destination.path) == 0 else { throw BackupFailure.exists }
            }
            return result
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }
}
