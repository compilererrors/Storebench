import Darwin
import Foundation

/// A folder explicitly selected by the user. Its bookmark stays in private local storage.
public struct BackupFolderSelection: Sendable {
    public let url: URL
    let bookmark: Data?
}

/// Keeps security-scoped access balanced for the entire backup operation.
final class BackupFolderLease: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var release: (@Sendable () -> Void)?
    init(url: URL, release: @escaping @Sendable () -> Void = {}) { self.url = url; self.release = release }
    func close() { lock.lock(); let action = release; release = nil; lock.unlock(); action?() }
    deinit { close() }
}

/// The system adapter is disabled in guarded runs; tests inject synthetic bookmark operations.
public struct BackupFolderAccess: Sendable {
    struct Resolution: Sendable { let url: URL; let stale: Bool }
    let requiresBookmark: Bool
    let create: @Sendable (URL) throws -> Data
    let resolve: @Sendable (Data) throws -> Resolution
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void

    public static var system: Self {
        Self(requiresBookmark: Bundle.main.object(forInfoDictionaryKey: "StorebenchDistribution") as? String == "app-store",
             create: { url in
                 guard !Network.testMode else { throw TestIsolation.Failure.unguarded }
                 return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
             }, resolve: { data in
                 guard !Network.testMode else { throw TestIsolation.Failure.unguarded }
                 var stale = false
                 let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                 return Resolution(url: url, stale: stale)
             }, start: { !Network.testMode && $0.startAccessingSecurityScopedResource() }, stop: { if !Network.testMode { $0.stopAccessingSecurityScopedResource() } })
    }

    public func capture(_ url: URL) throws -> BackupFolderSelection {
        try TestIsolation.check(url)
        guard url.isFileURL else { throw BackupSettingsFailure.folderAccess }
        guard requiresBookmark else { return BackupFolderSelection(url: url, bookmark: nil) }
        guard start(url) else { throw BackupSettingsFailure.folderAccess }
        defer { stop(url) }
        do {
            let data = try create(url)
            guard !data.isEmpty, data.count <= 64_000 else { throw BackupSettingsFailure.folderAccess }
            return BackupFolderSelection(url: url, bookmark: data)
        } catch { throw BackupSettingsFailure.folderAccess }
    }

    func open(destination: String, bookmark: Data?) throws -> BackupFolderLease {
        let expected = URL(fileURLWithPath: destination, isDirectory: true)
        try TestIsolation.check(expected)
        guard requiresBookmark else { return BackupFolderLease(url: expected) }
        guard let bookmark, !bookmark.isEmpty, bookmark.count <= 64_000 else { throw BackupSettingsFailure.folderAccess }
        let resolved: Resolution
        do { resolved = try resolve(bookmark) } catch { throw BackupSettingsFailure.folderAccess }
        // A moved or stale bookmark requires an explicit new selection, rather than silently changing destinations.
        guard !resolved.stale, resolved.url.isFileURL, LocalPaths.lexical(resolved.url) == LocalPaths.lexical(expected) else { throw BackupSettingsFailure.folderAccess }
        try TestIsolation.check(resolved.url)
        guard start(resolved.url) else { throw BackupSettingsFailure.folderAccess }
        return BackupFolderLease(url: resolved.url, release: { stop(resolved.url) })
    }
}

enum BackupFolderBookmarks {
    static func file(root: URL, revision: String) -> URL {
        root.appendingPathComponent("native-backup-access-\(revision).json")
    }

    /// Call while holding the shared backup settings mutex. Each configuration revision has its own grant.
    static func read(root: URL, settings: BackupSettings) throws -> Data? {
        guard settings.revision != "initial" else { return nil }
        let url = file(root: root, revision: settings.revision)
        try TestIsolation.check(url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 { if errno == ENOENT { return nil }; throw BackupSettingsFailure.folderAccess }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size <= 100_000 else { throw BackupSettingsFailure.folderAccess }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw BackupSettingsFailure.folderAccess }
            if count == 0 { break }
            guard data.count + count <= 100_000 else { throw BackupSettingsFailure.folderAccess }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let value = try? JSONText.parse(data), case .object(let pairs) = value,
              Set(pairs.map(\.0)) == ["schemaVersion", "revision", "destination", "bookmark"], value["schemaVersion"] == .number(1),
              value["revision"]?.text == settings.revision, value["destination"]?.text == settings.destination,
              let encoded = value["bookmark"]?.text, let bookmark = Data(base64Encoded: encoded), !bookmark.isEmpty, bookmark.count <= 64_000 else { throw BackupSettingsFailure.folderAccess }
        return bookmark
    }

    static func write(_ bookmark: Data, root: URL, settings: BackupSettings) throws {
        guard !bookmark.isEmpty, bookmark.count <= 64_000 else { throw BackupSettingsFailure.folderAccess }
        let url = file(root: root, revision: settings.revision)
        try TestIsolation.check(url)
        let value = JSONText.object([("schemaVersion", .number(1)), ("revision", .string(settings.revision)),
                                     ("destination", .string(settings.destination)), ("bookmark", .string(bookmark.base64EncodedString()))])
        try BackupSchedule.writeAtomically(value.data, to: url)
    }
}
