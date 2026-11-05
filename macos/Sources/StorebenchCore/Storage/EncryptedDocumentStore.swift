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
            try execute(self.writable ? "PRAGMA synchronous = FULL; PRAGMA busy_timeout = 5000" : "PRAGMA query_only = ON")
            guard try scalar("PRAGMA cipher_status") == "1" else { throw Failure.encryptionInactive }
            guard (try? scalar("SELECT count(*) FROM sqlite_master")) != nil else { throw Failure.wrongKey }
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
        guard let external = try scalar("PRAGMA data_version"), let local = try scalar("SELECT total_changes()") else { throw Failure.cannotOpen }
        return external + ":" + local
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
    public func documents(namespace: String, prefix: String) throws -> [Document] {
        try rows("SELECT document_key, revision, payload FROM documents WHERE namespace = ? AND substr(document_key, 1, length(?)) = ? ORDER BY document_key", [namespace, prefix, prefix])
    }

    /// Inserts a document only when its key is free, as content-addressed bucket writes require.
    public func insertIfAbsent(namespace: String, key: String, json: Data) throws {
        try run("INSERT OR IGNORE INTO documents (namespace, document_key, revision, payload) VALUES (?, ?, 1, ?)", [.text(namespace), .text(key), .blob(json)])
    }

    public func delete(namespace: String, key: String) throws {
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
                    if try document(namespace: namespace, key: key) != nil {
                        try run("UPDATE documents SET revision = revision + 1, payload = ? WHERE namespace = ? AND document_key = ?", [.blob(json), .text(namespace), .text(key)])
                    } else {
                        try run("INSERT INTO documents (namespace, document_key, revision, payload) VALUES (?, ?, 1, ?)", [.text(namespace), .text(key), .blob(json)])
                    }
                case .delete(let namespace, let key): try delete(namespace: namespace, key: key)
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    enum Value { case text(String), blob(Data) }

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

    private func rows(_ sql: String, _ arguments: [String]) throws -> [Document] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.query(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient) }
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
