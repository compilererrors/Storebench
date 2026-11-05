import Foundation
import Testing
@testable import StorebenchCore

// The fixture was written by a reference SQLCipher writer with a synthetic key (bytes 0...31) and synthetic documents.
@Suite struct EncryptedDocumentStoreTests {
    init() throws { _ = try TestIsolation.require() }
    func copiedFixture() throws -> URL {
        let source = try SyntheticFixtures.database()
        let directory = (try TestIsolation.require()).appendingPathComponent("storebench-swift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("storebench-v2.sqlite")
        try FileManager.default.copyItem(at: source, to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        return copy
    }

    @Test func readsSyntheticEncryptedDocuments() throws {
        let url = try copiedFixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try EncryptedDocumentStore(url: url, key: Data(0..<32))
        let greeting = try #require(try store.document(namespace: "synthetic", key: "greeting"))
        #expect(greeting.revision == 2)
        let object = try #require(try JSONSerialization.jsonObject(with: greeting.payload) as? [String: String])
        #expect(object["message"] == "Synthetic Storebench document")
        #expect(try store.documents(namespace: "synthetic").map(\.key) == ["greeting", "second"])
        #expect(try store.document(namespace: "synthetic", key: "missing") == nil)
    }

    @Test func refusesAWrongKey() throws {
        let url = try copiedFixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: EncryptedDocumentStore.Failure.wrongKey) { try EncryptedDocumentStore(url: url, key: Data(repeating: 7, count: 32)) }
    }
}
