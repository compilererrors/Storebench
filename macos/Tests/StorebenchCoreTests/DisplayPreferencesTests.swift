import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct DisplayPreferencesTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/display-preferences.json"))) }

    @Test func currenciesAndNormalizationMatchPrimary() throws {
        let fixture = try fixture()
        #expect(JSONText.array(DisplayPreferences.currencies.map(JSONText.string)) == fixture["currencies"])
        for row in WorkspaceSession.items(fixture["models"]) {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: PricingFailure.self) { try DisplayPreferences(input) } }
            else { #expect(try DisplayPreferences(input).json == row["expected"]) }
        }
    }

    @Test func encryptedReadsAndUpdatesMatchPrimaryAndPreserveInvalidState() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        for row in WorkspaceSession.items(try fixture()["states"]) {
            try store.transaction { _ in
                row["absent"] == .bool(true) ? [.delete(namespace: "display_preferences", key: "current")] : [.put(namespace: "display_preferences", key: "current", json: try #require(row["input"]).data)]
            }
            if row["readRejected"] == .bool(true) { await #expect(throws: PricingFailure.self) { try await session.displayCurrency() } }
            else { #expect(try await session.displayCurrency() == row["read"]?["currency"]?.text) }
            let before = try store.document(namespace: "display_preferences", key: "current")
            if row["writeRejected"] == .bool(true) { await #expect(throws: PricingFailure.self) { try await session.setDisplayCurrency("EUR") } }
            else { try await session.setDisplayCurrency("EUR") }
            let after = try store.document(namespace: "display_preferences", key: "current")
            #expect(try after.map { try JSONText.parse($0.payload) } == row["after"])
            #expect(JSONText.number(Double((after?.revision ?? 0) - (before?.revision ?? 0))) == row["revisionChange"])
            if row["writeRejected"] == .bool(true) { #expect(before == after) }
        }
        let before = try store.document(namespace: "display_preferences", key: "current")
        await #expect(throws: PricingFailure.self) { try await session.setDisplayCurrency("usd") }
        #expect(try store.document(namespace: "display_preferences", key: "current") == before)
        try store.transaction { _ in [.put(namespace: "display_preferences", key: "current", json: Data("synthetic invalid JSON".utf8))] }
        let malformed = try store.document(namespace: "display_preferences", key: "current")
        await #expect(throws: JSONText.ParseFailure.self) { try await session.displayCurrency() }
        await #expect(throws: JSONText.ParseFailure.self) { try await session.setDisplayCurrency("EUR") }
        #expect(try store.document(namespace: "display_preferences", key: "current") == malformed)
    }

    @Test func waitingSaveRechecksTheStateAfterOwnedProcessExit() async throws {
        let root = try TestIsolation.require().appendingPathComponent("display-preferences-save-policy")
        let (session, _) = try DraftTests().session(directory: root)
        let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let mutex = store.directory.appendingPathComponent("display_preferences.mutex")
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        let write = Task { try await session.setDisplayCurrency("SEK") }
        defer { write.cancel(); try? JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(try store.document(namespace: "display_preferences", key: "current") == nil)
        let invalid = JSONText.object([("schemaVersion", .number(2)), ("currency", .string("USD"))])
        try store.transaction { _ in [.put(namespace: "display_preferences", key: "current", json: invalid.data)] }
        let changed = try store.document(namespace: "display_preferences", key: "current")
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        await #expect(throws: PricingFailure.self) { try await write.value }
        #expect(try store.document(namespace: "display_preferences", key: "current") == changed)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        try store.transaction { _ in [.put(namespace: "display_preferences", key: "current", json: try DisplayPreferences().json.data)] }
        try await session.setDisplayCurrency("SEK")
        #expect(try await session.displayCurrency() == "SEK")
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }
}
