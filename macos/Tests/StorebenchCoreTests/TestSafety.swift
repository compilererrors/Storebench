import Foundation
import Testing
@testable import StorebenchCore

enum SyntheticFixtures {
    static func database() throws -> URL {
        try TestIsolation.require().appendingPathComponent("native-fixtures/storebench-v2.sqlite")
    }
    static func media() throws -> URL {
        try TestIsolation.require().appendingPathComponent("native-fixtures/media/80290ebad2a7031b8764d58564a82d5285d0ae19b230af6244e31f4fdba00fa6.sbmedia")
    }
}

@Suite struct TestSafetyTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func rejectsUnownedStorageAndCredentials() throws {
        let outside = URL(fileURLWithPath: "/storebench-synthetic-unowned/storebench-v2.sqlite")
        #expect(throws: TestIsolation.Failure.outsideRoot) { try TestIsolation.check(outside) }
        #expect(throws: TestIsolation.Failure.outsideRoot) { try EncryptedDocumentStore(url: outside, key: Data(0..<32)) }
        #expect(throws: CredentialVault.Failure.keychain(errSecNotAvailable)) { try CredentialVault.read() }
        #expect(Workspace.defaultRoot == (try TestIsolation.require()).appendingPathComponent("data"))
    }
    @Test func refusesRequestsWithoutASyntheticProtocol() async throws {
        let session = URLSession(configuration: Network.guarded(.ephemeral))
        await #expect(throws: (any Error).self) { try await session.data(from: URL(string: "https://unowned.example.invalid")!) }
    }

    @Test func temporaryAliasesAndMissingChildrenStayScoped() throws {
        let root = try TestIsolation.require()
        let directory = root.appendingPathComponent("synthetic-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = URL(fileURLWithPath: try #require(Backups.realPath(directory)))
        let identityFolder = canonical.appendingPathComponent("restore-target")
        let identity = CredentialVault.databaseEntry(root: identityFolder)
        try FileManager.default.createDirectory(at: identityFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(CredentialVault.databaseEntry(root: identityFolder) == identity)
        let file = canonical.appendingPathComponent("schedule.mutex")
        try TestIsolation.check(file)
        try FileMutex.withLock(file) { }
        try TestIsolation.check(file)
        try TestIsolation.check(canonical.appendingPathComponent("new/child/file"))
        let link = canonical.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/storebench-synthetic-unowned")
        #expect(throws: TestIsolation.Failure.outsideRoot) { try TestIsolation.check(link.appendingPathComponent("new-file")) }
    }
}
