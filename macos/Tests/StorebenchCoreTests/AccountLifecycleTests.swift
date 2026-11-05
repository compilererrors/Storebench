import CryptoKit
import Darwin
import Foundation
import Testing
@testable import StorebenchCore

final class SyntheticCredentialStorage: VaultStorage, @unchecked Sendable {
    enum Failure: Error { case denied }
    private let lock = NSLock()
    private var data: Data?
    private var reads = 0, writes = 0, legacyReads = 0
    private var denied = false, deleteDenied = false, saveDenied = false, legacyDenied = false
    private var older: [String: String] = [:]
    private var saveHook: (@Sendable () -> Void)?
    init(_ data: Data) { self.data = data }
    func load() throws -> Data? { try lock.withLock { reads += 1; if denied { throw Failure.denied }; return data } }
    func save(_ data: Data) throws {
        let hook = try lock.withLock { if denied || saveDenied { throw Failure.denied }; writes += 1; self.data = data; return saveHook }
        hook?()
    }
    func onSave(_ hook: (@Sendable () -> Void)?) { lock.withLock { saveHook = hook } }
    func legacy(_ key: String) throws -> String? { try lock.withLock { legacyReads += 1; if legacyDenied { throw Failure.denied }; return older[key] } }
    func removeLegacy(_ key: String) throws { try lock.withLock { if deleteDenied { throw Failure.denied }; older[key] = nil } }
    func deny(_ value: Bool) { lock.withLock { denied = value } }
    func denyDeletion(_ value: Bool) { lock.withLock { deleteDenied = value } }
    func denySave(_ value: Bool) { lock.withLock { saveDenied = value } }
    func denyLegacy(_ value: Bool) { lock.withLock { legacyDenied = value } }
    func legacy(_ key: String, value: String) { lock.withLock { older[key] = value } }
    var counts: (reads: Int, writes: Int, legacyReads: Int) { lock.withLock { (reads, writes, legacyReads) } }
    func olderValue(_ key: String) -> String? { lock.withLock { older[key] } }
}

@Suite(.serialized) struct AccountLifecycleTests {
    init() throws { _ = try TestIsolation.require() }
    struct Fixture {
        let root: URL, writer: VaultWriter, storage: SyntheticCredentialStorage, session: WorkspaceSession, account: Account, key: P256.Signing.PrivateKey
    }
    func fixture(withKey: Bool = true) async throws -> Fixture {
        let (initial, root) = try DraftTests().session()
        let account = try #require(try await initial.accounts().first), key = P256.Signing.PrivateKey()
        var entries = await initial.vault.entries
        if withKey { entries["apple:\(account.id)"] = key.pemRepresentation }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": entries])
        let storage = SyntheticCredentialStorage(data), writer = VaultWriter(dataRoot: root, storage: storage)
        let session = try WorkspaceSession(workspace: Workspace(root: root), vault: CredentialVault(json: data), credentialWriter: writer)
        return Fixture(root: root, writer: writer, storage: storage, session: session, account: account, key: key)
    }
    func configuration() -> URLSessionConfiguration { let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [StubProtocol.self]; return value }
    func page(_ ids: [String], name: String = "Synthetic app") -> Data {
        try! JSONSerialization.data(withJSONObject: ["data": ids.map { ["type": "apps", "id": $0, "attributes": ["name": name]] }, "links": [:]])
    }
    func client(_ f: Fixture, host: String, account: Account? = nil) throws -> AppStoreConnectClient {
        AppStoreConnectClient(token: try AppleToken(account: account ?? f.account, privateKeyPEM: f.key.pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration())
    }
    func signedBy(_ client: AppStoreConnectClient, key: P256.Signing.PrivateKey) throws -> Bool {
        let parts = try client.token.signed().split(separator: ".").map(String.init)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Base64URL.decode(parts[2], length: 64))
        return key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8))
    }
    @Test func accountInputsMatchTheWebAndBoundBytesBeforeParsing() throws {
        let root = try TestIsolation.require(), golden = try JSONText.parse(Data(contentsOf: root.appendingPathComponent("native-fixtures/account-inputs.json")))
        guard case .array(let filenames)? = golden["filenames"], case .array(let ids)? = golden["ids"] else { Issue.record("Missing synthetic account fixtures"); return }
        for value in filenames { #expect(AppleAccountInputs.keyId(filename: value["filename"]!.text!) == value["keyId"]?.text) }
        for value in ids { #expect(JSONText.bool(AppleAccountInputs.validKeyId(value["value"]!.text!)) == value["valid"]) }
        let pem = P256.Signing.PrivateKey().pemRepresentation, url = root.appendingPathComponent("synthetic-key-\(UUID().uuidString).p8")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(pem.utf8).write(to: url); #expect(try AppleAccountInputs.privateKeyFile(url) == pem)
        try Data(repeating: 65, count: 10_001).write(to: url)
        #expect(throws: AccountFailure.keyContent) { try AppleAccountInputs.privateKeyFile(url) }
        #expect(throws: AccountFailure.invalid) { try AppleAccountInputs.privateKeyFile(root) }
        #expect(throws: AccountFailure.keyContent) { try AppleAccountInputs.validatePrivateKey(P384.Signing.PrivateKey().pemRepresentation) }
        #expect(throws: AccountFailure.invalid) { try AppleAccountInputs.account(name: String(repeating: "🔑", count: 41), keyType: "individual", issuerId: nil, keyId: "SYNTH01", pem: pem) }
        let account = try AppleAccountInputs.account(name: "\u{feff} Synthetic \u{feff}", keyType: "individual", issuerId: nil, keyId: "\u{feff}SYNTH01\u{feff}", pem: pem)
        #expect(account.name == "Synthetic" && account.keyId == "SYNTH01" && account.issuerId == nil)
    }
    @Test func emptySuccessfulTestDoesNotChangeAppsAndEmptyRefreshPreservesHistory() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let host = "account-empty.appstoreconnect.test", client = try client(f, host: host)
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "GET")
            let lock = try! FileMutex.tryLock(f.root.appendingPathComponent("state-v2/accounts.mutex")); #expect(lock != nil); lock?.release()
            return (200, [:], page([]))
        }
        let before = try await f.session.storeAccess { try $0.documents(namespace: "revisions") }
        let saved = try await f.session.storeAccess { try $0.document(namespace: "accounts", key: "all") }
        try await f.session.testAccountConnection(f.account, client: client)
        #expect(try await f.session.storeAccess { try $0.document(namespace: "accounts", key: "all") } == saved)
        let refreshed = try await f.session.refreshAccountApps(f.account, client: client)
        #expect(refreshed.appIds.isEmpty && refreshed.appNames == [:])
        #expect(try await f.session.storeAccess { try $0.documents(namespace: "revisions") } == before)
        #expect(try f.writer.read().entries["apple:\(f.account.id)"] == f.key.pemRepresentation)
    }
    @Test func foreignClientAndLateAccountChangesDoNotOverwriteTheStoredSelection() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let foreign = Account(id: "synthetic-other", name: "Other", keyId: "OTHER", keyType: "individual", issuerId: nil, appIds: f.account.appIds, appNames: nil)
        await #expect(throws: AccountFailure.stale) { try await f.session.testAccountConnection(f.account, client: client(f, host: "account-foreign.appstoreconnect.test", account: foreign)) }
        let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: f.root), key: Data(0..<32), writable: true)
        let changed = Account(id: f.account.id, name: "Synthetic newer connection", keyId: "NEWKEY", keyType: f.account.keyType, issuerId: f.account.issuerId, appIds: ["1000000009"], appNames: nil)
        let host = "account-late.appstoreconnect.test"
        StubProtocol.handle(host) { _ in
            try! FileMutex.withLock(store.directory.appendingPathComponent("accounts.mutex")) { try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] } }
            return (200, [:], page(["1000000008"]))
        }
        await #expect(throws: AccountFailure.stale) { try await f.session.refreshAccountApps(f.account, client: client(f, host: host)) }
        #expect(try await f.session.accounts() == [changed])
        await #expect(throws: AccountFailure.stale) { try await f.session.client(for: f.account) }
    }
    @Test func refreshRejectsAnInvalidAppIdAndOverlongUtf16NameWithoutSaving() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let host = "account-invalid.appstoreconnect.test", client = try client(f, host: host)
        for (id, name) in [("invalid", "Synthetic"), ("1000000001", String(repeating: "🔑", count: 101))] {
            StubProtocol.handle(host) { _ in (200, [:], page([id], name: name)) }
            await #expect(throws: AccountFailure.invalid) { try await f.session.refreshAccountApps(f.account, client: client) }
        }
        #expect(try await f.session.accounts().first == f.account)
    }
    @Test func reconnectPreservesDocumentsAndOtherSessionsReadTheReplacement() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let second = try WorkspaceSession(workspace: Workspace(root: f.root), vault: f.writer.read(), credentialWriter: f.writer)
        _ = try await second.client(for: f.account)
        let namespaces = ["accounts", "revisions", "drafts", "sales", "sales_reports", "analytics", "release_plans"]
        let before = try await f.session.storeAccess { store in try namespaces.map { try store.documents(namespace: $0) } }
        let newKey = P256.Signing.PrivateKey(), host = "account-reconnect.appstoreconnect.test"
        StubProtocol.handle(host) { _ in (200, [:], page([f.account.appIds[0], "1000000009"])) }
        try await f.session.reconnectAccount(f.account, privateKeyPEM: newKey.pemRepresentation, writer: f.writer, origin: URL(string: "https://\(host)")!, configuration: configuration())
        #expect(try await f.session.storeAccess { store in try namespaces.map { try store.documents(namespace: $0) } } == before)
        let updatedClient = try await second.client(for: f.account)
        #expect(try signedBy(updatedClient, key: newKey)); #expect(try !signedBy(updatedClient, key: f.key))
    }
    @Test func reconnectRejectsForeignOrEmptyAppsAndAppleAuthFailureKeepsTheKey() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let host = "account-mismatch.appstoreconnect.test", origin = URL(string: "https://\(host)")!, newKey = P256.Signing.PrivateKey().pemRepresentation
        for ids in [[], ["1000000099"]] {
            StubProtocol.handle(host) { _ in (200, [:], page(ids)) }
            await #expect(throws: AccountFailure.mismatch) { try await f.session.reconnectAccount(f.account, privateKeyPEM: newKey, writer: f.writer, origin: origin, configuration: configuration()) }
        }
        StubProtocol.handle(host) { _ in (401, [:], Data()) }
        await #expect(throws: AccountFailure.auth) { try await f.session.reconnectAccount(f.account, privateKeyPEM: newKey, writer: f.writer, origin: origin, configuration: configuration()) }
        #expect(try f.writer.read().entries["apple:\(f.account.id)"] == f.key.pemRepresentation)
    }
    @Test func reconnectDoesNotReplaceAKeyChangedDuringAppleVerificationEvenWithTheSameValue() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let key = "apple:\(f.account.id)", candidate = P256.Signing.PrivateKey().pemRepresentation
        let host = "account-key-race.appstoreconnect.test", origin = URL(string: "https://\(host)")!
        for replacement in [P256.Signing.PrivateKey().pemRepresentation, f.key.pemRepresentation] {
            let old = try #require(try f.writer.read().entries[key])
            StubProtocol.handle(host) { _ in
                _ = try! f.writer.writeCredential(key, root: f.root, value: replacement, expected: old)
                return (200, [:], page(f.account.appIds))
            }
            await #expect(throws: CredentialAccessFailure.changed) { try await f.session.reconnectAccount(f.account, privateKeyPEM: candidate, writer: f.writer, origin: origin, configuration: configuration()) }
            #expect(try f.writer.read().entries[key] == replacement)
        }
    }
    @Test func failedCredentialReadIsPausedUntilAnExplicitAccountRetryWithoutNativeAccess() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let key = "apple:\(f.account.id)", oldReads = f.storage.counts.reads
        _ = try await f.session.client(for: f.account); _ = try await f.session.client(for: f.account)
        #expect(f.storage.counts.reads == oldReads)
        _ = try f.writer.writeCredential(key, root: f.root, value: f.key.pemRepresentation, expected: f.key.pemRepresentation)
        f.storage.deny(true)
        await #expect(throws: SyntheticCredentialStorage.Failure.self) { try await f.session.client(for: f.account) }
        let deniedReads = f.storage.counts.reads
        await #expect(throws: CredentialAccessFailure.paused) { try await f.session.client(for: f.account) }
        f.storage.deny(false)
        await #expect(throws: CredentialAccessFailure.paused) { try await f.session.client(for: f.account) }
        try await f.session.retryKeychainAccess(accountId: f.account.id, writer: f.writer)
        #expect(f.storage.counts.reads == deniedReads)
        _ = try await f.session.client(for: f.account); #expect(f.storage.counts.reads == deniedReads + 1)
    }
    @Test func missingKeyCanBeRestoredAfterExplicitRetryAndLegacyAccessIsMigratedOnce() async throws {
        let f = try await fixture(withKey: false); defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: ReviewsFailure.noKey) { try await f.session.client(for: f.account) }
        await #expect(throws: CredentialAccessFailure.paused) { try await f.session.client(for: f.account) }
        try await f.session.retryKeychainAccess(accountId: f.account.id, writer: f.writer)
        let key = "apple:\(f.account.id)", host = "account-restore.appstoreconnect.test"
        f.storage.legacy(key, value: f.key.pemRepresentation)
        let first = try await f.session.client(for: f.account), legacyReads = f.storage.counts.legacyReads
        #expect(try signedBy(first, key: f.key))
        _ = try await f.session.client(for: f.account)
        #expect(f.storage.counts.legacyReads == legacyReads && f.storage.olderValue(key) == f.key.pemRepresentation)
        let newKey = P256.Signing.PrivateKey()
        StubProtocol.handle(host) { _ in (200, [:], page(f.account.appIds)) }
        try await f.session.reconnectAccount(f.account, privateKeyPEM: newKey.pemRepresentation, writer: f.writer, origin: URL(string: "https://\(host)")!, configuration: configuration())
        #expect(f.storage.olderValue(key) == nil)
        let current = try await f.session.client(for: f.account); #expect(try signedBy(current, key: newKey))
    }
    @Test func missingSharedKeyIsReconnectedAndRetryClearsOnlyTheCurrentAccountsReporterChoice() async throws {
        let f = try await fixture(withKey: false); defer { try? FileManager.default.removeItem(at: f.root) }
        let current = "00000000-0000-4000-8000-000000000097", previous = "00000000-0000-4000-8000-000000000098", other = "00000000-0000-4000-8000-000000000099"
        try await f.session.storeAccess { store in try store.transaction { _ in [.put(namespace: "sales_connection", key: f.account.id, json: JSONText.object([("schemaVersion", .number(1)), ("accountId", .string(f.account.id)), ("vendorNumber", .string("000000001")), ("reporter", .object([("accountNumber", .string("000000001")), ("vendorNumber", .string("000000001")), ("credentialId", .string(current)), ("connectedAt", .string("2026-01-01T00:00:00.000Z"))]))]).data)] } }
        for id in [current, previous, other] { await #expect(throws: ReviewsFailure.noKey) { try await f.session.credentialCapture("reporter:\(id)") } }
        let reads = f.storage.counts.reads
        try await f.session.retryKeychainAccess(accountId: f.account.id, writer: f.writer)
        #expect(f.storage.counts.reads == reads)
        await #expect(throws: ReviewsFailure.noKey) { try await f.session.credentialCapture("reporter:\(current)") }
        for id in [previous, other] { await #expect(throws: CredentialAccessFailure.paused) { try await f.session.credentialCapture("reporter:\(id)") } }
        let host = "account-missing-reconnect.appstoreconnect.test", newKey = P256.Signing.PrivateKey()
        StubProtocol.handle(host) { _ in (200, [:], page(f.account.appIds)) }
        try await f.session.reconnectAccount(f.account, privateKeyPEM: newKey.pemRepresentation, writer: f.writer, origin: URL(string: "https://\(host)")!, configuration: configuration())
        #expect(try f.writer.read().entries["apple:\(f.account.id)"] == newKey.pemRepresentation)
        #expect(try await f.session.accounts().first == f.account)
    }
    @Test func legacyDeletionFailureKeepsTheSharedKeyAndPausesRepeatedWrites() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let key = "apple:\(f.account.id)", host = "account-legacy-denied.appstoreconnect.test"
        f.storage.legacy(key, value: f.key.pemRepresentation); f.storage.denyDeletion(true)
        StubProtocol.handle(host) { _ in (200, [:], page(f.account.appIds)) }
        await #expect(throws: AccountFailure.keychain) { try await f.session.reconnectAccount(f.account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation, writer: f.writer, origin: URL(string: "https://\(host)")!, configuration: configuration()) }
        #expect(try f.writer.read().entries[key] == f.key.pemRepresentation)
        await #expect(throws: CredentialAccessFailure.paused) { try await f.session.client(for: f.account) }
    }
    @Test func credentialMarkersRejectSymlinksMalformedTextAndPublicPermissionsBeforeReadingKeychain() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let location = try VaultWriter.credentialLocation(root: f.root, key: "apple:\(f.account.id)"), marker = location.appendingPathExtension("generation")
        _ = try await f.session.client(for: f.account)
        let before = f.storage.counts.reads
        for mode in [0, 1, 2] {
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            if mode == 0 { try JobLock.exclusive(marker, "invalid") }
            if mode == 1 { try JobLock.exclusive(marker, UUID().uuidString.lowercased()); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path) }
            if mode == 2 { try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: EncryptedDocumentStore.databaseURL(root: f.root)) }
            try await f.session.retryKeychainAccess(accountId: f.account.id, writer: f.writer)
            await #expect(throws: CredentialAccessFailure.unreadable) { try await f.session.client(for: f.account) }
        }
        #expect(f.storage.counts.reads == before)
    }
    @Test func aFailedNewConnectionCannotDeleteAnotherWritersReplacementOfTheSameKey() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let pem = P256.Signing.PrivateKey().pemRepresentation, host = "account-connect-rollback.appstoreconnect.test"
        StubProtocol.handle(host) { _ in
            let entries = try! f.writer.read().entries
            let key = entries.keys.first { $0.hasPrefix("apple:") && $0 != "apple:\(f.account.id)" }!
            _ = try! f.writer.writeCredential(key, root: f.root, value: pem, expected: pem)
            return (401, [:], Data())
        }
        await #expect(throws: AccountFailure.auth) { try await f.session.connectAccount(name: "Synthetic replacement", keyType: "individual", issuerId: nil, keyId: "SYNTH02", privateKeyPEM: pem, writer: f.writer, origin: URL(string: "https://\(host)")!, configuration: configuration()) }
        #expect(try f.writer.read().entries.filter { $0.key.hasPrefix("apple:") }.count == 2)
        #expect(try await f.session.accounts() == [f.account])
    }
}
