import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AccountTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func repeatedCatalogReadsObserveExternalChangesDeletionCorruptionAndRevocation() async throws {
        let (session, root) = try DraftTests().session()
        defer { try? FileManager.default.removeItem(at: root) }
        let starting = try await session.accounts(), original = try #require(starting.first)
        let peer = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        func replace(_ data: Data?, reset: Bool = false) throws {
            try FileMutex.withLock(peer.directory.appendingPathComponent("accounts.mutex")) {
                try peer.transaction { _ in
                    var writes: [EncryptedDocumentStore.Write] = []
                    if reset || data == nil { writes.append(.delete(namespace: "accounts", key: "all")) }
                    if let data { writes.append(.put(namespace: "accounts", key: "all", json: data)) }
                    return writes
                }
            }
        }
        let initialRevision = try #require(try peer.document(namespace: "accounts", key: "all")).revision
        #expect(initialRevision == 1)
        for _ in 0..<20 { #expect(try await session.accounts() == starting) }
        for index in 0..<20 {
            let account = Account(id: original.id, name: "Synthetic catalog \(index)", keyId: original.keyId, keyType: original.keyType, issuerId: original.issuerId,
                                  appIds: [String(1_000_000_100 + index)], appNames: nil)
            try replace(JSONText.array([WorkspaceSession.json(account)]).data, reset: index == 0)
            if index == 0 { #expect(try peer.document(namespace: "accounts", key: "all")?.revision == initialRevision) }
            for _ in 0..<3 { #expect(try await session.accounts() == [account]) }
            await #expect(throws: AccountFailure.stale) { try await session.currentAccount(original, exact: true) }
        }
        try replace(nil)
        #expect(try await session.accounts().isEmpty)
        await #expect(throws: AccountFailure.notFound) { try await session.currentAccount(original) }
        try replace(Data("{}".utf8))
        await #expect(throws: DecodingError.self) { try await session.accounts() }
        try replace(JSONText.array(starting.map(WorkspaceSession.json)).data)
        #expect(try await session.accounts() == starting)
        try Setup.replaceGeneration(root.appendingPathComponent("state-v2"))
        await #expect(throws: SessionFailure.changed) { try await session.accounts() }
    }
    @Test func connectingSavesTheKeyAndAppsAndRollsBackWhenAppleRefuses() async throws {
        let root = (try TestIsolation.require()).appendingPathComponent("storebench-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: try SyntheticFixtures.database(), to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = #"{\"schemaVersion\":1,\"phase\":\"ready\",\"envelope\":{\"version\":1,\"mode\":\"device\",\"key\":\"\#(key)\"}}"#
        let storage = MemoryVaultStorage(Data(#"{"version":1,"entries":{"\#(CredentialVault.databaseEntry(root: root))":"\#(record)"}}"#.utf8))
        let writer = VaultWriter(dataRoot: root, storage: storage)
        let session = try WorkspaceSession(workspace: Workspace(root: root), vault: try writer.read())
        let pem = P256.Signing.PrivateKey().pemRepresentation, host = "accounts.appstoreconnect.test"
        let origin = URL(string: "https://\(host)")!
        func stubbed() -> URLSessionConfiguration { let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]; return configuration }
        StubProtocol.handle(host) { request in
            #expect(request.url!.path == "/v1/apps")
            return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": [["type": "apps", "id": "1000000007", "attributes": ["name": "Synthetic New App"]], ["type": "apps", "id": "1000000007", "attributes": ["name": "Duplicate"]]], "links": [:]]))
        }
        let account = try await session.connectAccount(name: " Synthetic Studio ", keyType: "team", issuerId: "00000000-0000-4000-8000-000000000009", keyId: "SYNTHKEY01", privateKeyPEM: pem, writer: writer, origin: origin, configuration: stubbed())
        #expect(account.name == "Synthetic Studio" && account.appIds == ["1000000007"] && account.appNames == ["1000000007": "Duplicate"])
        #expect(try writer.read().entries["apple:\(account.id)"] == pem)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("credential-state/vault.generation").path))
        let accounts = try await session.accounts()
        #expect(accounts.count == 2 && accounts.last == account)
        _ = try await session.client(for: account)

        StubProtocol.handle(host) { _ in (401, [:], Data()) }
        await #expect(throws: AccountFailure.auth) {
            try await session.connectAccount(name: "Refused", keyType: "individual", issuerId: nil, keyId: "SYNTHKEY02", privateKeyPEM: pem, writer: writer, origin: origin, configuration: stubbed())
        }
        #expect(try writer.read().entries.keys.filter { $0.hasPrefix("apple:") } == ["apple:\(account.id)"])
        #expect(try await session.accounts().count == 2)
        await #expect(throws: AccountFailure.issuerRequired) {
            try await session.connectAccount(name: "No issuer", keyType: "team", issuerId: nil, keyId: "SYNTHKEY03", privateKeyPEM: pem, writer: writer, origin: origin, configuration: stubbed())
        }

        StubProtocol.handle(host) { _ in (200, [:], try! JSONSerialization.data(withJSONObject: ["data": [["type": "apps", "id": "1000000008", "attributes": ["name": "Synthetic Second"]]], "links": [:]])) }
        let refreshed = try await session.refreshAccountApps(account, client: AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: pem), origin: origin, configuration: stubbed()))
        #expect(refreshed.appIds == ["1000000008"])
        let saved = try await session.storeAccess { try $0.document(namespace: "accounts", key: "all") }.map { try JSONText.parse($0.payload) }
        guard case .array(let items)? = saved else { Issue.record("No accounts"); return }
        #expect(items.last?.stringify() == #"{"id":"\#(account.id)","name":"Synthetic Studio","keyId":"SYNTHKEY01","appIds":["1000000008"],"appNames":{"1000000008":"Synthetic Second"},"keyType":"team","issuerId":"00000000-0000-4000-8000-000000000009","credentialSource":"keychain"}"#)
    }
}
