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

    @Test func readsByKeyPrefixThroughTheIndexRange() throws {
        let url = try copiedFixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try EncryptedDocumentStore(url: url, key: Data(0..<32), writable: true)
        let keys = ["a:1", "a:1:x", "a:1:y", "a:1:\u{10FFFF}end", "a:1:é", "a:10:z", "a:2:q", "å:1:é", "A:1:x"]
        try store.transaction { _ in keys.map { .put(namespace: "synthetic-prefix", key: $0, json: Data("{}".utf8)) } }
        #expect(try store.documents(namespace: "synthetic-prefix", prefix: "a:1:").map(\.key) == ["a:1:x", "a:1:y", "a:1:é", "a:1:\u{10FFFF}end"])
        #expect(try store.documents(namespace: "synthetic-prefix", prefix: "a:1").map(\.key) == ["a:1", "a:10:z", "a:1:x", "a:1:y", "a:1:é", "a:1:\u{10FFFF}end"])
        #expect(try store.documents(namespace: "synthetic-prefix", prefix: "å:").map(\.key) == ["å:1:é"])
        #expect(try store.documents(namespace: "synthetic-prefix", prefix: "b").isEmpty)
        #expect(try Set(store.documents(namespace: "synthetic-prefix", prefix: "").map(\.key)) == Set(keys))
        // Another namespace with the same keys is never included.
        #expect(try store.documents(namespace: "synthetic", prefix: "a:1:").isEmpty)
    }

    @Test func aSecondReadOnlyConnectionSeesEachCommittedWrite() throws {
        let url = try copiedFixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try EncryptedDocumentStore(url: url, key: Data(0..<32), writable: true)
        let reader = ReadConnection(try EncryptedDocumentStore(url: url, key: Data(0..<32)))
        #expect(try reader.read { try $0.document(namespace: "synthetic-second", key: "value") } == nil)
        try writer.transaction { _ in [.put(namespace: "synthetic-second", key: "value", json: Data("1".utf8))] }
        #expect(try reader.read { try $0.document(namespace: "synthetic-second", key: "value") }?.payload == Data("1".utf8))
        try writer.transaction { _ in [.put(namespace: "synthetic-second", key: "value", json: Data("2".utf8))] }
        #expect(try reader.read { try $0.document(namespace: "synthetic-second", key: "value") }?.revision == 2)
        reader.close()
        #expect(!reader.isOpen)
        #expect(throws: SessionFailure.closed) { try reader.read { try $0.keys(namespace: "synthetic") } }
    }
}
