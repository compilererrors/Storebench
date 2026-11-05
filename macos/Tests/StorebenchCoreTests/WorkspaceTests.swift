import Foundation
import Testing
@testable import StorebenchCore

// The whole unlock path with a synthetic Keychain item and data folder; the real Keychain is never read.
@Suite struct WorkspaceTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func opensASyntheticWorkspaceAndListsItsApps() async throws {
        let root = (try TestIsolation.require()).appendingPathComponent("storebench-workspace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fixture = try SyntheticFixtures.database()
        try FileManager.default.copyItem(at: fixture, to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)

        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = #"{\"schemaVersion\":1,\"phase\":\"ready\",\"envelope\":{\"version\":1,\"mode\":\"device\",\"key\":\"\#(key)\"}}"#
        let vault = try CredentialVault(json: Data(#"{"version":1,"entries":{"\#(CredentialVault.databaseEntry(root: root))":"\#(record)"}}"#.utf8))

        let workspace = Workspace(root: root)
        #expect(try workspace.lock(in: vault) == .device)
        let accounts = try Workspace.accounts(in: try workspace.open(vault: vault))
        #expect(accounts.map(\.name) == ["Example Studio"])
        // Saved revisions from the synthetic fixture builder, newest first.
        let session = try WorkspaceSession(workspace: workspace, vault: vault)
        let revisions = try await session.revisions(accountId: "synthetic-account", appId: "1000000001")
        #expect(revisions.map(\.app.name) == ["Sample App Updated", "Sample App"])
        let version = try #require(revisions.first?.versions.first)
        #expect(version.title == "iOS 1.0")
        #expect(version.state == "Ready for Distribution")
        #expect(version.localizations.first?.fields["description"]?.text == "Second synthetic description")
        #expect(try await session.revisions(accountId: "synthetic-account", appId: "1000000002").isEmpty)
        // Partitioned Sales buckets in month order, and a history saved in the older single-document layout.
        let sales = try await session.sales(accountId: "synthetic-account", appId: "1000000001")
        #expect(sales.map(\.beginDate) == ["2026-01-30", "2026-01-31", "2026-02-01"])
        #expect(sales.map(\.paidUnits) == [5, 8, 5])
        #expect(try await session.sales(accountId: "synthetic-account", appId: "1000000002").map(\.unitsByTerritory) == [["GB": 3]])
        // Prepared Analytics views from the fixtures, and reviews newest first.
        let analytics = try await session.analytics(accountId: "synthetic-account", appId: "1000000001")
        #expect(analytics.map(\.date) == ["2026-01-03"])
        #expect(analytics[0].total("first") == 60)
        #expect(try await session.reviews(accountId: "synthetic-account", appId: "1000000001").map(\.rating) == [3, 5])
        #expect(accounts[0].apps.map(\.name) == ["Sample App", "App 1000000002"])
        #expect(throws: Workspace.Failure.notSetUp) { try Workspace(root: root.appendingPathComponent("other")).lock(in: vault) }
    }
}
