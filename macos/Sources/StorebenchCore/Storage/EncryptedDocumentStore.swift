import Darwin
import Foundation
import SQLCipher

/// SQLCipher documents indexed by namespace and key. Connections default to read-only access.
public final class EncryptedDocumentStore {
    public struct Document: Equatable, Sendable { public let key: String; public let revision: Int; public let payload: Data }
    public enum Failure: Error, Equatable { case cannotOpen, wrongKey, encryptionInactive, notPrivate, query(String) }

    private var db: OpaquePointer?

    public static func databaseURL(root: URL) -> URL { root.appendingPathComponent("state-v2/storebench-v2.sqlite") }

    public enum Write: Sendable { case put(namespace: String, key: String, json: Data), delete(namespace: String, key: String) }
    public let writable: Bool
    /// The `state-v2` folder holding the database and its process-shared `.mutex` files.
    public var directory: URL { url.deletingLastPathComponent() }
    private let url: URL

    public init(url: URL, key: Data, writable: Bool = false, create: Bool = false) throws {
        try TestIsolation.check(url)
        self.writable = writable || create; self.url = url
        guard key.count == 32 else { throw Failure.wrongKey }
        // The database must be a private regular file owned by this user, never a symlink.
        let descriptor = Darwin.open(url.path, (create ? O_CREAT : 0) | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.cannotOpen }
        var info = stat()
        let privateFile = fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() && info.st_mode & 0o077 == 0
        Darwin.close(descriptor)
        guard privateFile else { throw Failure.notPrivate }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | (create ? SQLITE_OPEN_CREATE : 0), nil) == SQLITE_OK else { close(); throw Failure.cannotOpen }
        do {
            let hex = key.map { String(format: "%02x", $0) }.joined()
            try execute("PRAGMA key = \"x'\(hex)'\"")
            try execute("PRAGMA cipher_memory_security = ON; PRAGMA temp_store = MEMORY; PRAGMA trusted_schema = OFF; PRAGMA foreign_keys = ON")
            // A checkpoint moves committed pages into the database file. It waits for the disk to really hold them, which an ordinary
            // sync on macOS does not promise, so a power loss cannot leave the file itself half written. Commits keep the ordinary sync.
            try execute(self.writable ? "PRAGMA synchronous = FULL; PRAGMA checkpoint_fullfsync = ON; PRAGMA busy_timeout = 5000" : "PRAGMA query_only = ON; PRAGMA busy_timeout = 5000")
            guard try scalar("PRAGMA cipher_status") == "1" else { throw Failure.encryptionInactive }
            guard (try? scalar("SELECT count(*) FROM sqlite_master")) != nil else { throw Failure.wrongKey }
            // Decrypted pages stay in memory between reads, and the write-ahead log is cut back after a large write.
            try execute("PRAGMA cache_size = -8192")
            if self.writable { _ = try scalar("PRAGMA journal_size_limit = 67108864") }
            if create {
                guard let version = try scalar("PRAGMA user_version"), version == "0" || version == "1" else { throw Failure.query("Unsupported database schema version.") }
                try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL")
                try execute("CREATE TABLE IF NOT EXISTS documents (namespace TEXT NOT NULL, document_key TEXT NOT NULL, revision INTEGER NOT NULL CHECK (revision > 0), payload BLOB NOT NULL, PRIMARY KEY (namespace, document_key)) STRICT")
                if version == "0" { try execute("PRAGMA user_version = 1") }
            }
        } catch { close(); throw error }
    }

    deinit { close() }

    /// Writes an encrypted copy of the whole database with the same key.
    func exportSnapshot(to target: URL, key: Data) throws {
        try TestIsolation.check(target)
        guard key.count == 32, target.lastPathComponent == "storebench-v2.sqlite" else { throw Failure.query("Invalid encrypted snapshot destination.") }
        let descriptor = Darwin.open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.cannotOpen }
        Darwin.close(descriptor)
        let hex = key.map { String(format: "%02x", $0) }.joined()
        try execute("ATTACH DATABASE '\(target.path.replacingOccurrences(of: "'", with: "''"))' AS backup KEY \"x'\(hex)'\"")
        defer { try? execute("DETACH DATABASE backup") }
        _ = try scalar("SELECT sqlcipher_export('backup')")
        try execute("PRAGMA backup.user_version = 1")
    }

    /// Opens a snapshot read-only and checks its encryption and integrity.
    static func verifySnapshot(_ url: URL, key: Data) throws {
        let store = try EncryptedDocumentStore(url: url, key: key)
        guard try store.scalar("PRAGMA integrity_check") == "ok" else { throw Failure.query("The encrypted snapshot is damaged.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(store.db, "PRAGMA cipher_integrity_check", -1, &statement, nil) == SQLITE_OK else { throw Failure.query("The encrypted snapshot is damaged.") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.query("The encrypted snapshot failed authentication.") }
    }

    public func document(namespace: String, key: String) throws -> Document? {
        try rows("SELECT document_key, revision, payload FROM documents WHERE namespace = ? AND document_key = ?", [namespace, key]).first
    }

    /// Other connections change data_version; this connection changes total_changes, including delete/reinsert.
    func changeStamp() throws -> String {
        guard let external = try scalar("PRAGMA data_version"), let local = try scalar("SELECT total_changes()").flatMap(Int.init) else { throw Failure.cannotOpen }
        return external + ":" + String(local - unstampedChanges)
    }
    /// How much of the database file holds no data, in bytes, and the file's whole size.
    func unusedRoom() throws -> (unused: Int, total: Int) {
        guard let free = try scalar("PRAGMA freelist_count").flatMap(Int.init), let pages = try scalar("PRAGMA page_count").flatMap(Int.init),
              let size = try scalar("PRAGMA page_size").flatMap(Int.init) else { throw Failure.cannotOpen }
        return (free * size, pages * size)
    }
    /// Rewrites the database without its unused pages. The file is replaced only when the whole rewrite succeeded.
    func compact() throws {
        guard writable else { throw Failure.query("The store is read-only.") }
        try execute("VACUUM")
    }
    /// Changes when another connection commits to this database; this connection's own writes leave it unchanged.
    func externalStamp() throws -> String {
        guard let external = try scalar("PRAGMA data_version") else { throw Failure.cannotOpen }
        return external
    }
    /// How many times this connection wrote or removed a document in each namespace, counted when the write is asked for.
    private var namespaceWrites: [String: Int] = [:]
    /// Changes when a document in `namespace` may have been written or removed: by this connection in that namespace, or by any
    /// other connection anywhere in the database. While it stays the same, every document in the namespace is exactly as it was,
    /// also after a delete and a new insert under the same key.
    func namespaceStamp(_ namespace: String) throws -> String {
        try externalStamp() + ":" + String(namespaceWrites[namespace, default: 0])
    }
    /// A document's revision without reading its payload, or nil when the key is free.
    public func revision(namespace: String, key: String) throws -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT revision FROM documents WHERE namespace = ? AND document_key = ?", -1, &statement, nil) == SQLITE_OK else { throw Failure.query(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, namespace, -1, transient); sqlite3_bind_text(statement, 2, key, -1, transient)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw Failure.query(String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_column_int64(statement, 0))
    }
    /// Rows this connection changed in writes that no cached screen data depends on, such as saved screen reads.
    private var unstampedChanges = 0
    /// Runs writes that cached library and pricing data do not depend on, so they leave `changeStamp` unchanged.
    /// Writes from other connections still change it.
    func withoutChangeStamp<T>(_ body: () throws -> T) rethrows -> T {
        let before = (try? scalar("SELECT total_changes()")).flatMap { $0.flatMap(Int.init) }
        defer { if let before, let after = (try? scalar("SELECT total_changes()")).flatMap({ $0.flatMap(Int.init) }) { unstampedChanges += after - before } }
        return try body()
    }

    public func documents(namespace: String) throws -> [Document] {
        try rows("SELECT document_key, revision, payload FROM documents WHERE namespace = ? ORDER BY document_key", [namespace])
    }

    /// The keys in one namespace, without reading their payloads.
    public func keys(namespace: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT document_key FROM documents WHERE namespace = ? ORDER BY document_key", -1, &statement, nil) == SQLITE_OK else { throw Failure.query(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, namespace, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var result: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure.query(String(cString: sqlite3_errmsg(db))) }
            result.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return result
    }

    /// Documents whose key starts with `prefix`, such as every saved revision of one app.
    /// The key range lets the index find them without visiting the namespace's other keys: no stored key has the byte 0xFF,
    /// which UTF-8 never uses, so every key with the prefix sorts before the prefix followed by that byte.
    public func documents(namespace: String, prefix: String) throws -> [Document] {
        try rows("SELECT document_key, revision, payload FROM documents WHERE namespace = ? AND document_key >= ? AND document_key < ? AND substr(document_key, 1, length(?)) = ? ORDER BY document_key",
                 [.text(namespace), .text(prefix), .textBytes(Array(prefix.utf8) + [0xFF]), .text(prefix), .text(prefix)])
    }

    /// Inserts a document only when its key is free, as content-addressed bucket writes require.
    public func insertIfAbsent(namespace: String, key: String, json: Data) throws {
        namespaceWrites[namespace, default: 0] += 1
        try run("INSERT OR IGNORE INTO documents (namespace, document_key, revision, payload) VALUES (?, ?, 1, ?)", [.text(namespace), .text(key), .blob(json)])
    }

    public func delete(namespace: String, key: String) throws {
        namespaceWrites[namespace, default: 0] += 1
        try run("DELETE FROM documents WHERE namespace = ? AND document_key = ?", [.text(namespace), .text(key)])
    }

    /// One IMMEDIATE transaction: `change` sees the current documents and returns the writes, or throws to roll back.
    /// Each written document's revision increases by one.
    public func transaction(_ change: (_ current: (String, String) throws -> Document?) throws -> [Write]) throws {
        guard writable else { throw Failure.query("The store is read-only.") }
        try execute("BEGIN IMMEDIATE")
        do {
            for write in try change({ try self.document(namespace: $0, key: $1) }) {
                switch write {
                case .put(let namespace, let key, let json):
                    namespaceWrites[namespace, default: 0] += 1
                    // One statement inserts the document at revision 1 or replaces its payload and adds one to its revision,
                    // without reading the payload it replaces.
                    try run("INSERT INTO documents (namespace, document_key, revision, payload) VALUES (?, ?, 1, ?) ON CONFLICT (namespace, document_key) DO UPDATE SET revision = revision + 1, payload = excluded.payload",
                            [.text(namespace), .text(key), .blob(json)])
                case .delete(let namespace, let key): try delete(namespace: namespace, key: key)
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    enum Value {
        case text(String), blob(Data)
        /// Text given as bytes, for a bound that is not itself valid UTF-8.
        case textBytes([UInt8])
    }

    private func run(_ sql: String, _ arguments: [Value]) throws {
        guard writable else { throw Failure.query("The store is read-only.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.query(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            switch argument {
            case .text(let value): sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            case .blob(let value): _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(index + 1), $0.baseAddress, Int32(value.count), transient) }
            case .textBytes(let value): _ = value.withUnsafeBytes { sqlite3_bind_text(statement, Int32(index + 1), $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(value.count), transient) }
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.query(String(cString: sqlite3_errmsg(db))) }
    }

    func close() { if let db { sqlite3_close_v2(db) }; db = nil }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.query(String(cString: sqlite3_errmsg(db))) }
    }

    private func scalar(_ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.query(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func rows(_ sql: String, _ arguments: [String]) throws -> [Document] { try rows(sql, arguments.map(Value.text)) }
    private func rows(_ sql: String, _ arguments: [Value]) throws -> [Document] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.query(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            switch argument {
            case .text(let value): sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            case .blob(let value): _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(index + 1), $0.baseAddress, Int32(value.count), transient) }
            case .textBytes(let value): _ = value.withUnsafeBytes { sqlite3_bind_text(statement, Int32(index + 1), $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(value.count), transient) }
            }
        }
        var result: [Document] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure.query(String(cString: sqlite3_errmsg(db))) }
            let key = String(cString: sqlite3_column_text(statement, 0)), revision = Int(sqlite3_column_int64(statement, 1))
            let bytes = sqlite3_column_bytes(statement, 2)
            let payload = bytes > 0 ? Data(bytes: sqlite3_column_blob(statement, 2), count: Int(bytes)) : Data()
            result.append(Document(key: key, revision: revision, payload: payload))
        }
        return result
    }
}
