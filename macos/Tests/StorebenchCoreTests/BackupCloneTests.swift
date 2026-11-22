import CryptoKit
import Darwin
import Foundation
import Testing
@testable import StorebenchCore

/// A backup keeps one copy of each unchanged file where the disk allows it, and is byte for byte the same either way.
@Suite struct BackupCloneTests {
    init() throws { _ = try TestIsolation.require() }

    func folder() throws -> URL {
        let url = try TestIsolation.require().appendingPathComponent("synthetic-backup-clone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    func file(_ url: URL, _ bytes: Data) throws {
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    @Test func aCloneAndAPlainCopyAreTheSameFileWithTheSameDigest() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }), source = root.appendingPathComponent("source.sbmedia")
        try file(source, bytes)
        let cloned = try Backups.copyPrivateFile(source, root.appendingPathComponent("cloned"))
        let copied = try Backups.copyPrivateFile(source, root.appendingPathComponent("copied"), allowsClone: false)
        #expect(cloned.bytes == bytes.count && cloned.sha256 == sha(bytes) && copied.bytes == cloned.bytes && copied.sha256 == cloned.sha256)
        for name in ["cloned", "copied"] {
            let url = root.appendingPathComponent(name)
            #expect(try Data(contentsOf: url) == bytes)
            var info = stat()
            #expect(lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_mode & 0o077 == 0 && info.st_nlink == 1, "\(name) must be a private file of its own, not a link")
        }
        // Changing the source afterwards never changes a copy.
        try file(source, Data(repeating: 9, count: 10))
        #expect(try Data(contentsOf: root.appendingPathComponent("cloned")) == bytes)
        // An existing destination is never replaced.
        #expect(throws: BackupFailure.self) { try Backups.copyPrivateFile(source, root.appendingPathComponent("copied"), allowsClone: false) }
        #expect(try Data(contentsOf: root.appendingPathComponent("copied")) == bytes)
    }

    @Test func anEarlierBackupsFileIsReusedOnlyWhenItIsStillExactlyTheSame() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 5, count: 70_000), source = root.appendingPathComponent("source.sbmedia")
        try file(source, bytes)
        // An earlier copy of the same size with other content is refused; the result is still the source's bytes.
        let changed = root.appendingPathComponent("earlier-changed"), same = root.appendingPathComponent("earlier-same")
        try file(changed, Data(repeating: 6, count: 70_000)); try file(same, bytes)
        for (index, earlier) in [[changed], [changed, same], [root.appendingPathComponent("missing")]].enumerated() {
            let target = root.appendingPathComponent("target-\(index)")
            let result = try Backups.copyPrivateFile(source, target, earlier: earlier)
            #expect(result.sha256 == sha(bytes) && result.bytes == bytes.count)
            #expect(try Data(contentsOf: target) == bytes)
        }
        // A source that is a link, or readable by others, is never copied.
        let link = root.appendingPathComponent("link")
        #expect(symlink(source.path, link.path) == 0)
        #expect(throws: BackupFailure.self) { try Backups.copyPrivateFile(link, root.appendingPathComponent("from-link")) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        #expect(throws: BackupFailure.notPrivate) { try Backups.copyPrivateFile(source, root.appendingPathComponent("from-shared")) }
    }

    @Test func earlierBackupsAreThePrivateFoldersBesideTheNewOne() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["generation-a", "generation-b", ".storebench-encrypted-backup-staged"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try file(root.appendingPathComponent("schedule.json"), Data("{}".utf8))
        let found = Backups.earlierBackups(beside: root.appendingPathComponent(".storebench-encrypted-backup-staged")).map(\.lastPathComponent)
        #expect(Set(found) == ["generation-a", "generation-b"])
    }
}
