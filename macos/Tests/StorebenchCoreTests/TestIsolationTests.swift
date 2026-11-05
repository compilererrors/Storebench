import Foundation
import Testing
@testable import StorebenchCore

@Suite struct TestIsolationTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func freshOwnedPathsResolveButEscapedAndDanglingLinksFailClosed() throws {
        let root = try TestIsolation.require(), directory = root.appendingPathComponent("isolation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try TestIsolation.check(directory)
        try TestIsolation.check(directory.appendingPathComponent("new/nested/file"))
        let ownedLink = directory.appendingPathComponent("owned-link"), escaped = directory.appendingPathComponent("escaped-link"), dangling = directory.appendingPathComponent("dangling-link")
        try FileManager.default.createSymbolicLink(at: ownedLink, withDestinationURL: directory)
        try TestIsolation.check(ownedLink.appendingPathComponent("new-file"))
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: root.deletingLastPathComponent())
        #expect(throws: TestIsolation.Failure.outsideRoot) { try TestIsolation.check(escaped.appendingPathComponent("new-file")) }
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: directory.appendingPathComponent("missing-target"))
        #expect(throws: TestIsolation.Failure.outsideRoot) { try TestIsolation.check(dangling.appendingPathComponent("file")) }
        #expect(throws: TestIsolation.Failure.outsideRoot) { try TestIsolation.check(root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-sibling/file")) }
    }
}
