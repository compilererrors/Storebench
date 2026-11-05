import Darwin
import Foundation

/// The process-shared lock: an exclusive `flock` on a permanent, private, empty `.mutex` file.
/// The file is never removed or replaced. Waiting uses a monotonic clock and gives up after five seconds.
public enum FileMutex {
    public enum Failure: Error, Equatable { case unavailable, timeout }

    public static func withLock<T>(_ url: URL, timeout: Duration = .seconds(5), _ operation: () throws -> T) throws -> T {
        try TestIsolation.check(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_size == 0,
              info.st_mode & 0o077 == 0, info.st_uid == getuid() else { throw Failure.unavailable }
        let clock = ContinuousClock(), deadline = clock.now + timeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, clock.now < deadline else { throw errno == EWOULDBLOCK ? Failure.timeout : Failure.unavailable }
            usleep(25_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

extension FileMutex {
    /// A held lock; closing the descriptor releases it.
    public final class Held: @unchecked Sendable {
        private var descriptor: Int32
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        public func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
        deinit { release() }
    }

    /// One non-blocking attempt; nil when another process holds it.
    public static func tryLock(_ url: URL) throws -> Held? {
        try TestIsolation.check(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_size == 0,
              info.st_mode & 0o077 == 0, info.st_uid == getuid() else { close(descriptor); throw Failure.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(descriptor)
            if busy { return nil }
            throw Failure.unavailable
        }
        return Held(descriptor)
    }
}

/// The job lock: a kernel mutex plus owner and recovery-gate files with protocol 2.
public enum JobLock {
    public enum Failure: Error, Equatable { case unverifiable }
    struct Owner: Decodable { let id: String; let pid: Int32; let `protocol`: Int? }

    static func privateFile(_ url: URL) throws -> String? {
        try TestIsolation.check(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { if errno == ENOENT { return nil }; throw Failure.unverifiable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 32_000,
              info.st_mode & 0o077 == 0, info.st_uid == getuid(), info.st_nlink == 1 else { throw Failure.unverifiable }
        var bytes = [UInt8](repeating: 0, count: 32_001), total = 0
        while total < bytes.count {
            let remaining = bytes.count - total
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: total), remaining) }
            guard count >= 0 else { throw Failure.unverifiable }
            if count == 0 { break }; total += count
        }
        guard total <= 32_000, let raw = String(bytes: bytes.prefix(total), encoding: .utf8) else { throw Failure.unverifiable }
        return raw
    }

    static func owner(_ raw: String?) throws -> Owner? {
        guard let raw else { return nil }
        guard let owner = try? JSONDecoder().decode(Owner.self, from: Data(raw.utf8)), owner.id.range(of: "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", options: .regularExpression) != nil,
              owner.pid > 0, owner.protocol == nil || owner.protocol == 2 else { throw Failure.unverifiable }
        return owner
    }

    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }

    static func exclusive(_ url: URL, _ content: String) throws {
        try TestIsolation.check(url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp")
        defer { unlink(temporary.path) }
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unverifiable }
        let bytes = Array(content.utf8)
        let written = write(descriptor, bytes, bytes.count); close(descriptor)
        guard written == bytes.count, link(temporary.path, url.path) == 0 else { throw Failure.unverifiable }
    }

    /// Acquires `<state-v2>/<name>.lock` for one job, or returns nil while another owner holds it. Nothing is ever expired by time.
    public static func acquire(directory: URL, name: String, id: String, now: Date = Date()) throws -> (() -> Void)? {
        let lock = directory.appendingPathComponent("\(name).lock"), gate = directory.appendingPathComponent("\(name).lock.recovery")
        guard let mutex = try FileMutex.tryLock(directory.appendingPathComponent("\(name).lock.mutex")) else { return nil }
        let content = JSONText.object([("id", .string(id)), ("pid", .number(Double(getpid()))), ("protocol", .number(2)), ("createdAt", .string(CustomerReview.isoString(now)))]).stringify()
        var gateOwned = false, lockOwned = false
        func cleanup() {
            if lockOwned, (try? privateFile(lock)) == content { unlink(lock.path) }
            if gateOwned, (try? privateFile(gate)) == content { unlink(gate.path) }
            mutex.release()
        }
        do {
            if let existing = try owner(try privateFile(gate)) {
                // A legacy gate cannot prove that its owner stopped.
                if existing.protocol != 2 && alive(existing.pid) { mutex.release(); return nil }
                unlink(gate.path)
            } else if try privateFile(gate) != nil { unlink(gate.path) }
            try exclusive(gate, content); gateOwned = true
            if let previous = try owner(try privateFile(lock)) {
                if previous.protocol != 2 && alive(previous.pid) { cleanup(); return nil }
                unlink(lock.path)
            }
            try exclusive(lock, content); lockOwned = true
            return { cleanup() }
        } catch { cleanup(); throw error }
    }
}
