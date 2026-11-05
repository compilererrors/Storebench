import CryptoKit
import Darwin
import Foundation

/// Backup settings exclude the restore passphrase, which stays in the selected credential storage.
public struct BackupSettings: Sendable, Equatable {
    public static let intervals = [1, 6, 12, 24, 168]
    public let revision: String, enabled: Bool, destination: String, intervalHours, retain: Int, hasPassphrase: Bool
    let secretId: String?

    static let fresh = BackupSettings(revision: "initial", enabled: false, destination: "", intervalHours: 24, retain: 7, hasPassphrase: false, secretId: nil)
    var json: JSONText {
        .object([("schemaVersion", .number(1)), ("revision", .string(revision)), ("enabled", .bool(enabled)), ("destination", .string(destination)),
                 ("intervalHours", .number(Double(intervalHours))), ("retain", .number(Double(retain))), ("secretId", secretId.map { .string($0) } ?? .null)])
    }
}

public enum BackupSettingsFailure: Error, Equatable {
    case conflict, invalid(String), storage, folderAccess
    public var message: String {
        switch self {
        case .conflict: "Backup settings changed in another window. Read the latest save and choose which values to keep."
        case .invalid(let text): text
        case .storage: "Backup settings could not be read. Check local storage and retry."
        case .folderAccess: "Choose the backup folder again to restore access, then save the settings and retry."
        }
    }
}

public struct BackupStatus: Sendable, Equatable {
    public enum State: String, Sendable { case due, waiting, locked, running, error, disabled }
    public let state: State, lastVerifiedAt, nextDueAt: String?, generations: Int, error: String?
}

public enum BackupSchedule {
    static let uuid = "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"

    static func vaultKey(root: URL, secretId: String) -> String {
        "backup:" + String(CredentialVault.databaseEntry(root: root).dropFirst("database:".count)) + "_\(secretId)"
    }

    public static func read(root: URL) throws -> BackupSettings {
        try Backups.privateDirectory(root)
        let url = root.appendingPathComponent("backup-settings.json")
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 { if errno == ENOENT { return .fresh }; throw BackupSettingsFailure.storage }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 16_384 else { throw BackupSettingsFailure.storage }
        let value = try boundedJSON(descriptor, limit: 16_384)
        guard case .object(let pairs) = value, Set(pairs.map(\.0)) == ["destination", "enabled", "intervalHours", "retain", "revision", "schemaVersion", "secretId"], value["schemaVersion"] == .number(1),
              let revision = value["revision"]?.text, Backups.matches(revision, uuid), case .bool(let enabled)? = value["enabled"], let destination = value["destination"]?.text,
              destination.utf16.count <= 4096, destination.isEmpty || destination.hasPrefix("/"), case .number(let intervalNumber)? = value["intervalHours"], let interval = Int(exactly: intervalNumber), BackupSettings.intervals.contains(interval),
              case .number(let retainNumber)? = value["retain"], let retain = Int(exactly: retainNumber), (1...100).contains(retain) else { throw BackupSettingsFailure.storage }
        let secret = value["secretId"]?.text
        if let secret { guard Backups.matches(secret, uuid) else { throw BackupSettingsFailure.storage } } else { guard value["secretId"] == .null else { throw BackupSettingsFailure.storage } }
        if enabled && (destination.isEmpty || secret == nil) { throw BackupSettingsFailure.storage }
        return BackupSettings(revision: revision, enabled: enabled, destination: destination, intervalHours: interval, retain: retain, hasPassphrase: secret != nil, secretId: secret)
    }

    fileprivate static func boundedJSON(_ descriptor: Int32, limit: Int) throws -> JSONText {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0 { if errno == EINTR { continue }; throw BackupSettingsFailure.storage }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw BackupSettingsFailure.storage }
        }
        return try JSONText.parse(data)
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.lowercased()).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BackupSettingsFailure.storage }
        defer { unlink(temporary.path) }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, data.count) }
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard written == data.count, synced, rename(temporary.path, url.path) == 0 else { throw BackupSettingsFailure.storage }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if parent >= 0 { fsync(parent); close(parent) }
    }

    /// Checks each path component and creates only a missing last folder, private to this user and separate from the data folder.
    public static func prepareDestination(_ value: String, root: URL) throws -> String {
        guard !value.isEmpty, value.utf16.count <= 4096, value.hasPrefix("/"), !value.contains("\0") else { throw BackupSettingsFailure.invalid("Enter an absolute path to a backup folder.") }
        let destination = URL(fileURLWithPath: LocalPaths.lexical(URL(fileURLWithPath: value)))
        var ancestor = URL(fileURLWithPath: "/")
        let parts = destination.pathComponents.dropFirst()
        for (index, part) in parts.enumerated() {
            ancestor = ancestor.appendingPathComponent(part)
            var info = stat()
            if lstat(ancestor.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw BackupSettingsFailure.invalid("Backup folders cannot use symbolic links.") }
            } else {
                guard errno == ENOENT, index == parts.count - 1 else { throw BackupSettingsFailure.invalid("Enter an absolute path to a backup folder.") }
                var parent = stat()
                guard lstat(ancestor.deletingLastPathComponent().path, &parent) == 0, (parent.st_mode & S_IFMT) == S_IFDIR, parent.st_uid == getuid(), parent.st_mode & 0o022 == 0 else {
                    throw BackupSettingsFailure.invalid("Create the backup folder inside a folder owned by you that other users cannot modify.")
                }
            }
        }
        let source = URL(fileURLWithPath: Backups.realPath(root) ?? root.path)
        guard !Backups.overlaps(source, destination), !Backups.overlaps(destination, source) else { throw BackupSettingsFailure.invalid("Choose a backup folder separate from application data.") }
        if mkdir(destination.path, 0o700) != 0 && errno != EEXIST { throw BackupSettingsFailure.invalid("The backup folder could not be created.") }
        do { try Backups.privateDirectory(destination) } catch { throw BackupSettingsFailure.invalid("Choose a private folder owned by your user, with access restricted to you.") }
        guard Backups.realPath(destination) == destination.path else { throw BackupSettingsFailure.invalid("Backup folders cannot use symbolic links.") }
        return destination.path
    }

    /// Saves settings only onto the revision the editor loaded. A new passphrase gets a new secret; older ones stay for older generations.
    public static func save(root: URL, writer: VaultWriter, revision: String, enabled: Bool, destination: String, intervalHours: Int, retain: Int, passphrase: String?, confirmation: String?, selectedFolder: BackupFolderSelection? = nil, folderAccess: BackupFolderAccess = .system, check: () throws -> Void = {}) throws -> BackupSettings {
        guard BackupSettings.intervals.contains(intervalHours), (1...100).contains(retain) else { throw BackupSettingsFailure.invalid("Choose a supported interval and retain between 1 and 100 backups.") }
        if let passphrase, !passphrase.isEmpty { guard (12...256).contains(passphrase.utf16.count), confirmation.map({ passphrase.utf8.elementsEqual($0.utf8) }) == true else { throw BackupSettingsFailure.invalid("Enter the same restore passphrase twice, between 12 and 256 characters.") } }
        else if let confirmation, !confirmation.isEmpty { throw BackupSettingsFailure.invalid("Enter the same restore passphrase twice, between 12 and 256 characters.") }
        let newPassphrase = passphrase.flatMap { $0.isEmpty ? nil : $0 }
        try Backups.privateDirectory(root)
        return try FileMutex.withLock(root.appendingPathComponent("backup-settings.mutex")) {
            try check()
            let previous = try read(root: root)
            guard revision == previous.revision else { throw BackupSettingsFailure.conflict }
            if let selectedFolder, LocalPaths.lexical(selectedFolder.url) != LocalPaths.lexical(URL(fileURLWithPath: destination)) { throw BackupSettingsFailure.folderAccess }
            let savedBookmark: Data?
            if previous.destination == destination {
                savedBookmark = enabled ? try BackupFolderBookmarks.read(root: root, settings: previous) : try? BackupFolderBookmarks.read(root: root, settings: previous)
            } else { savedBookmark = nil }
            let bookmark = selectedFolder?.bookmark ?? savedBookmark
            // Disabling is always possible, including when a previously selected folder is unavailable.
            let lease = !destination.isEmpty && (enabled || selectedFolder != nil) ? try folderAccess.open(destination: destination, bookmark: bookmark) : nil
            defer { lease?.close() }
            let folder = !enabled && selectedFolder == nil && destination == previous.destination ? previous.destination : destination.isEmpty ? "" : try prepareDestination(destination, root: root)
            try check()
            if enabled && (folder.isEmpty || (newPassphrase == nil && previous.secretId == nil)) { throw BackupSettingsFailure.invalid("Choose a backup folder and set a restore passphrase before enabling backups.") }
            if enabled, newPassphrase == nil, let secret = previous.secretId, try writer.value(vaultKey(root: root, secretId: secret)) == nil {
                throw BackupSettingsFailure.invalid("The saved restore passphrase is unavailable. Enter it again before enabling backups.")
            }
            let secret = newPassphrase != nil ? UUID().uuidString.lowercased() : previous.secretId
            let next = BackupSettings(revision: UUID().uuidString.lowercased(), enabled: enabled, destination: folder, intervalHours: intervalHours, retain: retain, hasPassphrase: secret != nil, secretId: secret)
            try check()
            do {
                // Publish the revision's grant first; a crash cannot replace the grant of the previous settings.
                if let bookmark { try BackupFolderBookmarks.write(bookmark, root: root, settings: next) }
                if let newPassphrase, let secret { _ = try writer.set(vaultKey(root: root, secretId: secret), newPassphrase) }
                try check()
                try writeAtomically(next.json.data, to: root.appendingPathComponent("backup-settings.json"))
            }
            catch {
                if (try? read(root: root))?.revision != next.revision { unlink(BackupFolderBookmarks.file(root: root, revision: next.revision).path) }
                if let newPassphrase, let secret, (try? read(root: root))?.secretId != secret { _ = try? writer.remove(vaultKey(root: root, secretId: secret), expected: newPassphrase) }
                throw error
            }
            if previous.revision != "initial" { unlink(BackupFolderBookmarks.file(root: root, revision: previous.revision).path) }
            return next
        }
    }

    /// The folder holding this data folder's backup generations, scoped to that data folder.
    static func scopedDirectory(_ destination: String, root: URL) -> URL {
        let identity = SHA256.hash(data: Data((Backups.realPath(root) ?? root.path).utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: destination).appendingPathComponent("Storebench-\(identity)")
    }

    static func withDestination<T>(root: URL, access: BackupFolderAccess, check: (BackupSettings) throws -> Void = { _ in }, _ body: (BackupSettings, BackupFolderLease?) throws -> T) throws -> T {
        try Backups.privateDirectory(root)
        let (settings, lease) = try FileMutex.withLock(root.appendingPathComponent("backup-settings.mutex")) {
            let settings = try read(root: root)
            try check(settings)
            guard !settings.destination.isEmpty, settings.secretId != nil else { return (settings, Optional<BackupFolderLease>.none) }
            let bookmark = access.requiresBookmark ? try BackupFolderBookmarks.read(root: root, settings: settings) : nil
            return (settings, try access.open(destination: settings.destination, bookmark: bookmark))
        }
        defer { lease?.close() }
        return try body(settings, lease)
    }
}

/// The backup journal (`schedule.json`, schema 2) and its rules: one pending generation, verification before recording,
/// quarantine of unverified copies, and pruning only after the newest generation verifies.
public struct BackupScheduler {
    struct Generation { var id, createdAt, verifiedAt: String; var files, bytes: Int; var secretId: String? }
    struct Journal { var generations: [Generation] = []; var pending: (id: String, startedAt: String, secretId: String?)?; var lastAttemptAt: String?; var error: String? }

    let directory: URL, intervalSeconds: Double, retain: Int, retrySeconds: Double, secretId: String?
    let now: () -> Date

    public init(directory: URL, intervalHours: Int, retain: Int, secretId: String?, now: @escaping () -> Date = Date.init) {
        self.directory = directory; intervalSeconds = Double(intervalHours) * 3600; self.retain = retain; retrySeconds = min(intervalSeconds, 15 * 60)
        self.secretId = secretId; self.now = now
    }

    static func timestamp(_ value: String?) -> Bool {
        guard let value, value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil, let date = ASO.iso(value) else { return false }
        return CustomerReview.isoString(date) == value
    }

    func readJournal() throws -> Journal {
        let url = directory.appendingPathComponent("schedule.json")
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 { if errno == ENOENT { return Journal() }; throw BackupSettingsFailure.storage }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 64_000 else { throw BackupSettingsFailure.storage }
        let value = try BackupSchedule.boundedJSON(descriptor, limit: 64_000)
        guard case .object(let pairs) = value, Set(pairs.map(\.0)) == ["error", "generations", "lastAttemptAt", "pending", "schemaVersion"], case .number(let schema)? = value["schemaVersion"], [1, 2].contains(schema),
              case .array(let rows)? = value["generations"], rows.count <= 101 else { throw BackupSettingsFailure.storage }
        let legacy = schema == 1
        var journal = Journal()
        journal.lastAttemptAt = value["lastAttemptAt"]?.text; journal.error = value["error"]?.text
        if value["lastAttemptAt"] != .null && !Self.timestamp(journal.lastAttemptAt) { throw BackupSettingsFailure.storage }
        if value["error"] != .null, journal.error.map({ ["SB-BACKUP-CREATE", "SB-BACKUP-VERIFY", "SB-BACKUP-PRUNE", "SB-BACKUP-INTERRUPTED"].contains($0) }) != true { throw BackupSettingsFailure.storage }
        func checkedSecret(_ row: JSONText) throws -> String? {
            if legacy { return secretId }
            if row["secretId"] == .null { return nil }
            guard let value = row["secretId"]?.text, Backups.matches(value, BackupSchedule.uuid) else { throw BackupSettingsFailure.storage }
            return value
        }
        var ids = Set<String>()
        for row in rows {
            guard case .object(let fields) = row, Set(fields.map(\.0)) == (legacy ? ["bytes", "createdAt", "files", "id", "verifiedAt"] : ["bytes", "createdAt", "files", "id", "secretId", "verifiedAt"]),
                  let id = row["id"]?.text, Backups.matches(id, BackupSchedule.uuid), !ids.contains(id), let created = row["createdAt"]?.text, Self.timestamp(created), let verified = row["verifiedAt"]?.text, Self.timestamp(verified),
                  case .number(let filesNumber)? = row["files"], let files = Int(exactly: filesNumber), files >= 1, filesNumber <= 9_007_199_254_740_991,
                  case .number(let bytesNumber)? = row["bytes"], let bytes = Int(exactly: bytesNumber), bytes >= 1, bytesNumber <= 9_007_199_254_740_991 else { throw BackupSettingsFailure.storage }
            ids.insert(id)
            journal.generations.append(Generation(id: id, createdAt: created, verifiedAt: verified, files: files, bytes: bytes, secretId: try checkedSecret(row)))
        }
        if let pending = value["pending"], pending != .null {
            guard case .object(let fields) = pending, Set(fields.map(\.0)) == (legacy ? ["id", "startedAt"] : ["id", "secretId", "startedAt"]),
                  let id = pending["id"]?.text, Backups.matches(id, BackupSchedule.uuid), !ids.contains(id), let started = pending["startedAt"]?.text, Self.timestamp(started) else { throw BackupSettingsFailure.storage }
            journal.pending = (id, started, try checkedSecret(pending))
        }
        return journal
    }

    func writeJournal(_ journal: Journal) throws {
        func optional(_ text: String?) -> JSONText { text.map { .string($0) } ?? .null }
        let value = JSONText.object([("schemaVersion", .number(2)),
            ("generations", .array(journal.generations.map { .object([("id", .string($0.id)), ("createdAt", .string($0.createdAt)), ("files", .number(Double($0.files))), ("bytes", .number(Double($0.bytes))),
                                                                         ("verifiedAt", .string($0.verifiedAt)), ("secretId", optional($0.secretId))]) })),
            ("pending", journal.pending.map { .object([("id", .string($0.id)), ("startedAt", .string($0.startedAt)), ("secretId", optional($0.secretId))]) } ?? .null),
            ("lastAttemptAt", optional(journal.lastAttemptAt)), ("error", optional(journal.error))])
        try BackupSchedule.writeAtomically(value.data, to: directory.appendingPathComponent("schedule.json"))
    }

    func nextDue(_ journal: Journal) -> Date? {
        if journal.error != nil, let attempt = journal.lastAttemptAt.flatMap(ASO.iso) { return attempt.addingTimeInterval(retrySeconds) }
        return journal.generations.last.flatMap { ASO.iso($0.verifiedAt) }.map { $0.addingTimeInterval(intervalSeconds) }
    }

    func status(_ journal: Journal, _ state: BackupStatus.State? = nil) -> BackupStatus {
        let due = nextDue(journal)
        return BackupStatus(state: state ?? (journal.error != nil ? .error : due == nil || due! <= now() ? .due : .waiting), lastVerifiedAt: journal.generations.last?.verifiedAt,
                            nextDueAt: due.map(CustomerReview.isoString), generations: journal.generations.count, error: journal.error)
    }

    func generation(_ id: String) -> URL { directory.appendingPathComponent(id) }

    public func readStatus() -> BackupStatus {
        guard (try? Backups.privateDirectory(directory)) != nil else { return status(Journal()) }
        guard let lock = try? FileMutex.tryLock(directory.appendingPathComponent("schedule.mutex")) else { return status(Journal(), .running) }
        defer { lock.release() }
        do { return status(try readJournal()) } catch { return BackupStatus(state: .error, lastVerifiedAt: nil, nextDueAt: nil, generations: 0, error: "SB-BACKUP-STORAGE") }
    }

    /// One poll under the schedule mutex: finishes an interrupted generation, prunes, and creates a new one when due (or when forced).
    public func tick(force: Bool = false, create: (URL, String?) throws -> Void, verify: (URL, String?) throws -> BackupResult) -> BackupStatus {
        var journal = Journal()
        do {
            if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw BackupSettingsFailure.storage }
            try Backups.privateDirectory(directory)
            guard let lock = try FileMutex.tryLock(directory.appendingPathComponent("schedule.mutex")) else { return status(journal, .running) }
            defer { lock.release() }
            journal = try readJournal()
            if !force, journal.error != nil, let due = nextDue(journal), due > now() { return status(journal) }
            func record(_ result: BackupResult) throws {
                guard let pending = journal.pending else { throw BackupSettingsFailure.storage }
                journal.generations.append(Generation(id: pending.id, createdAt: result.createdAt, verifiedAt: CustomerReview.isoString(now()), files: result.files, bytes: result.bytes, secretId: pending.secretId))
                journal.pending = nil; journal.error = nil; try writeJournal(journal)
            }
            func quarantine() throws {
                guard let pending = journal.pending else { throw BackupSettingsFailure.storage }
                let target = directory.appendingPathComponent(".unverified-\(pending.id)")
                guard !Backups.exists(target), rename(generation(pending.id).path, target.path) == 0 else { throw BackupSettingsFailure.storage }
                journal.pending = nil; journal.error = "SB-BACKUP-VERIFY"; try writeJournal(journal)
            }
            func prune() throws {
                while journal.generations.count > retain {
                    let oldest = generation(journal.generations[0].id)
                    if Backups.exists(oldest) { try Backups.privateDirectory(oldest); try FileManager.default.removeItem(at: oldest) }
                    journal.generations.removeFirst(); try writeJournal(journal)
                }
            }
            if let pending = journal.pending {
                if Backups.exists(generation(pending.id)) {
                    do { try record(try verify(generation(pending.id), pending.secretId)) } catch { try quarantine(); return status(journal, .error) }
                } else { journal.pending = nil; journal.error = "SB-BACKUP-INTERRUPTED"; try writeJournal(journal) }
            }
            if journal.generations.count > retain {
                do { let latest = journal.generations.last!; _ = try verify(generation(latest.id), latest.secretId); try prune(); journal.error = nil; try writeJournal(journal) }
                catch { journal.error = "SB-BACKUP-PRUNE"; try writeJournal(journal); return status(journal, .error) }
            }
            if !force, let due = nextDue(journal), due > now() { return status(journal) }
            let id = UUID().uuidString.lowercased(), started = CustomerReview.isoString(now())
            journal.pending = (id, started, secretId); journal.lastAttemptAt = started; journal.error = nil
            try writeJournal(journal)
            do { try create(generation(id), secretId) } catch { journal.error = "SB-BACKUP-CREATE"; try writeJournal(journal); return status(journal, .error) }
            do { try Backups.privateDirectory(generation(id)); try record(try verify(generation(id), secretId)) } catch { try quarantine(); return status(journal, .error) }
            do { try prune() } catch { journal.error = "SB-BACKUP-PRUNE"; try writeJournal(journal); return status(journal, .error) }
            return status(journal)
        } catch { return BackupStatus(state: .error, lastVerifiedAt: journal.generations.last?.verifiedAt, nextDueAt: nil, generations: journal.generations.count, error: "SB-BACKUP-STORAGE") }
    }
}

extension WorkspaceSession {
    /// Backup status for the saved settings without creating anything.
    public func backupStatus(folderAccess: BackupFolderAccess = .system) throws -> BackupStatus {
        try requireSessionAccess()
        return try BackupSchedule.withDestination(root: root, access: folderAccess, check: { _ in try self.requireSessionAccess(); try Task.checkCancellation() }) { settings, lease in
            guard lease != nil else { return BackupStatus(state: .disabled, lastVerifiedAt: nil, nextDueAt: nil, generations: 0, error: nil) }
            let scheduler = BackupScheduler(directory: BackupSchedule.scopedDirectory(settings.destination, root: root), intervalHours: settings.intervalHours, retain: settings.retain, secretId: settings.secretId)
            let status = scheduler.readStatus()
            return settings.enabled ? status : BackupStatus(state: .disabled, lastVerifiedAt: status.lastVerifiedAt, nextDueAt: nil, generations: status.generations, error: status.error)
        }
    }

    /// One scheduled backup poll; `force` creates a backup now even when none is due. Disabled backups run only when forced.
    public func runBackups(writer: VaultWriter, force: Bool = false, folderAccess: BackupFolderAccess = .system, expectedRevision: String? = nil) throws -> BackupStatus {
        try requireSessionAccess()
        let root = self.root
        func passphrase(_ secret: String?) throws -> String {
            guard let secret, let value = try writer.value(BackupSchedule.vaultKey(root: root, secretId: secret)) else { throw BackupFailure.authentication }
            return value
        }
        return try BackupSchedule.withDestination(root: root, access: folderAccess, check: { settings in
            try self.requireSessionAccess(); try Task.checkCancellation()
            if let expectedRevision { guard settings.revision == expectedRevision, settings.enabled else { throw BackupSettingsFailure.conflict } }
        }) { settings, lease in
            guard lease != nil else { return BackupStatus(state: .disabled, lastVerifiedAt: nil, nextDueAt: nil, generations: 0, error: nil) }
            let scheduler = BackupScheduler(directory: BackupSchedule.scopedDirectory(settings.destination, root: root), intervalHours: settings.intervalHours, retain: settings.retain, secretId: settings.secretId)
            guard settings.enabled || force else {
                let status = scheduler.readStatus()
                return BackupStatus(state: .disabled, lastVerifiedAt: status.lastVerifiedAt, nextDueAt: nil, generations: status.generations, error: status.error)
            }
            return scheduler.tick(force: force, create: { url, secret in _ = try createBackup(destination: url, password: try passphrase(secret)) },
                                  verify: { url, secret in try Backups.verify(url, password: try passphrase(secret)) })
        }
    }
}
