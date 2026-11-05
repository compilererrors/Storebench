import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct SessionLifecycleTests {
    init() throws { _ = try TestIsolation.require() }
    func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try await condition()) { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await Task.sleep(for: .milliseconds(5)) }
    }
    @Test func closedSessionsDiscardReferencesRevokeCookiesAndRejectOldClients() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = await session.vault, account = try #require(try await session.accounts().first)
        let observer = try WorkspaceSession(workspace: Workspace(root: root), vault: vault)
        let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let previous = try LocalSessionKey.fresh()
        try store.transaction { _ in [.put(namespace: "local_sessions", key: "signing_key", json: previous.json.data)] }
        let revisions = try store.documents(namespace: "revisions")
        let saved = try await session.media.write(Data("Synthetic session image".utf8)), media = await session.media
        let check = await session.sessionRequestCheck()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://session-closed.appstoreconnect.test")!, configuration: configuration, accessCheck: check)
        StubProtocol.handle("session-closed.appstoreconnect.test") { _ in Issue.record("Closed client reached transport"); return (500, [:], Data()) }
        async let first: Void = session.signOut()
        async let duplicate: Void = session.signOut()
        _ = try await (first, duplicate)
        let lifetime = await session.lifetime
        #expect(lifetime.status == .closed && lifetime.activeCount == 0)
        let closedKey = await session.databaseKey, closedVault = await session.vault, closedSnapshot = await session.credentialSnapshot, closedWriter = await session.credentialWriter
        #expect(closedKey.isEmpty && closedVault.entries.isEmpty && closedSnapshot == nil && closedWriter == nil)
        await #expect(throws: SessionFailure.closed) { try await session.accounts() }
        await #expect(throws: SessionFailure.closed) { try await session.setDisplayCurrency("EUR") }
        await #expect(throws: SessionFailure.closed) { try await session.mediaBytes(saved.hash) }
        #expect(throws: SessionFailure.closed) { try media.read(saved.hash) }
        await #expect(throws: SessionFailure.closed) { try await client.get("/v1/apps/1000000001") }
        await #expect(throws: SessionFailure.changed) { try await observer.accounts() }
        let current = try LocalSessionKey(JSONText.parse(#require(try store.document(namespace: "local_sessions", key: "signing_key")).payload))
        #expect(current.key != previous.key)
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: vault)
        #expect(try store.documents(namespace: "revisions") == revisions)
        #expect(try await reopened.revisions(accountId: account.id, appId: "1000000001").count > 0)
        #expect(try await reopened.mediaBytes(saved.hash) == Data("Synthetic session image".utf8))
        try await observer.signOut()
        // Closing an older generation must not revoke the newly opened session.
        #expect(try await reopened.accounts().map(\.id) == [account.id])
    }

    @Test func admissionAndExactLeaseDrainRejectForeignOrExpiredTickets() async throws {
        let lifetime = SessionLifetime(), foreign = SessionLifetime(), lease = try lifetime.admit(.publishing), other = try foreign.admit(.publishing)
        #expect(lifetime.beginClosing() && !lifetime.beginClosing())
        #expect(throws: SessionFailure.closed) { try lifetime.require(nil) }
        #expect(throws: SessionFailure.closed) { try lifetime.require(other) }
        #expect(throws: SessionFailure.closed) { try lifetime.admit(.transfer) }
        try lifetime.require(lease)
        try await Task.sleep(for: .milliseconds(50))
        #expect(lifetime.status == .closing && lifetime.activeCount == 1)
        lease.finish(); lease.finish(); other.finish()
        await lifetime.drained()
        #expect(throws: SessionFailure.closed) { try lifetime.require(lease) }
        lifetime.finishClosing(failure: nil)
        await lifetime.closed()
        #expect(lifetime.status == .closed && lifetime.closeFailure == nil)
    }

    @Test func signingKeyValidationMatchesPrimaryAndMalformedRevocationStillCloses() async throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/local-session-keys.json")))
        for row in WorkspaceSession.items(fixture["models"]) {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: SessionFailure.revocation) { try LocalSessionKey(input) } }
            else { #expect(try LocalSessionKey(input).key == row["key"]?.text) }
        }
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        try store.transaction { _ in [.put(namespace: "local_sessions", key: "signing_key", json: JSONText.null.data)] }
        let before = try store.document(namespace: "local_sessions", key: "signing_key")
        await #expect(throws: SessionFailure.revocation) { try await session.signOut() }
        await #expect(throws: SessionFailure.closed) { try await session.accounts() }
        await #expect(throws: SessionFailure.revocation) { try await session.signOut() }
        #expect(try store.document(namespace: "local_sessions", key: "signing_key") == before)
        #expect(await session.databaseKey.isEmpty)
    }

    @Test func signOutCancelsItsDurableReportAndPreservesAnotherOwnedWorkspace() async throws {
        let helper = try SalesJobTests(), (session, account, root) = try await helper.session(), (other, otherAccount, otherRoot) = try await helper.session()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: otherRoot) }
        let firstGate = AnalyticsJobDelayStubProtocol.Gate(), otherGate = AnalyticsJobDelayStubProtocol.Gate()
        let store = try helper.store(root), key = try ReportJobs.identity(.sales, accountId: account.id, appId: helper.appId)
        let savedSales = try store.documents(namespace: "sales"), savedIndex = try store.document(namespace: "sales_index", key: "\(account.id):\(helper.appId)")
        defer { firstGate.release(); otherGate.release() }
        let job = try await session.startSalesDownload(account: account, appId: helper.appId, selection: helper.selection(), client: helper.transport("session-owned-report.appstoreconnect.test", account: account, gate: firstGate))
        let foreign = try await other.startSalesDownload(account: otherAccount, appId: helper.appId, selection: helper.selection(), client: helper.transport("session-other-report.appstoreconnect.test", account: otherAccount, gate: otherGate))
        try await wait { firstGate.pending == 1 && otherGate.pending == 1 }
        try await session.signOut()
        let terminal = try SalesDownloadJob(json: JSONText.parse(#require(try store.document(namespace: "jobs", key: key)).payload))
        #expect(terminal.id == job.id && terminal.state == .cancelled)
        #expect(try await other.salesDownloadJob(account: otherAccount, appId: helper.appId)?.id == foreign.id)
        #expect(try await other.salesDownloadJob(account: otherAccount, appId: helper.appId)?.state == .running)
        #expect(try store.document(namespace: "sales_index", key: "\(account.id):\(helper.appId)") == savedIndex)
        #expect(try store.documents(namespace: "sales") == savedSales)
        otherGate.release()
        try await wait { try await other.salesDownloadJob(account: otherAccount, appId: helper.appId)?.state == .complete }
        try await other.signOut()
    }

    @Test func signOutWaitsForAdmittedTransferAndDeniesNewSaves() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let lifetime = await session.lifetime, lease = try lifetime.admit(.transfer)
        let closing = Task { try await session.signOut() }
        try await wait { lifetime.status == .closing }
        await #expect(throws: SessionFailure.closed) { try await session.setDisplayCurrency("EUR") }
        try await SessionContext.$lease.withValue(lease) { try await session.setDisplayCurrency("SEK") }
        #expect(lifetime.status == .closing && lifetime.activeCount == 1)
        lease.finish(); try await closing.value
        #expect(lifetime.status == .closed)
        let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32))
        #expect(try DisplayPreferences(JSONText.parse(#require(try store.document(namespace: "display_preferences", key: "current")).payload)).currency == "SEK")
    }

    @Test func signOutDrainsAnApprovedPublishAndKeepsItsSingleUseReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), gate = AnalyticsJobDelayStubProtocol.Gate()
        defer { gate.release() }
        let host = "session-approved-write.appstoreconnect.test", app = "1000000001"
        try SessionPublishStubProtocol.register(host, apple: apple, gate: gate)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SessionPublishStubProtocol.self]
        let check = await session.sessionRequestCheck(), lifetime = await session.lifetime, vault = await session.vault
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration, accessCheck: check)
        let review = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio"), client: client)
        #expect(apple.writes.isEmpty)
        let publishing = Task { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        try await wait { gate.pending == 1 }
        let closing = Task { try await session.signOut() }
        try await wait { lifetime.status == .closing }
        await #expect(throws: SessionFailure.closed) { try await session.setDisplayCurrency("EUR") }
        await #expect(throws: SessionFailure.closed) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(lifetime.activeCount == 1 && apple.writes.isEmpty)
        gate.release()
        #expect(try await publishing.value.state == "complete")
        try await closing.value
        #expect(apple.writes.count == 1 && lifetime.status == .closed)
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: vault)
        #expect(try await reopened.publishReview(accountId: account.id, appId: app, id: review.id).state == "complete")
        await #expect(throws: PublishFailure.used) { try await reopened.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: PublishingTests().client(account, host: host)) }
        #expect(apple.writes.count == 1)
        try await reopened.signOut()
    }

    @Test func signOutWaitsForTheOwnedBackupToCommit() async throws {
        let root = try TestIsolation.require().appendingPathComponent("session-backup-close-policy")
        let (session, _) = try DraftTests().session(directory: root)
        let parent = try TestIsolation.require().appendingPathComponent("synthetic-session-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt"); try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("backup"), lifetime = await session.lifetime
        let backup = Task { try await session.createBackup(destination: destination, password: BackupTests.passphrase) }
        try await wait { try FileManager.default.contentsOfDirectory(atPath: parent.path).contains(where: { $0.hasPrefix(".storebench-encrypted-backup-") }) }
        let closing = Task { try await session.signOut() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(lifetime.status == .open && !FileManager.default.fileExists(atPath: destination.path))
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        let completed = try await backup.value
        try await closing.value
        #expect(try Backups.verify(destination, password: BackupTests.passphrase).files == completed.files)
        #expect(lifetime.status == .closed)
        await #expect(throws: SessionFailure.closed) { try await session.createBackup(destination: parent.appendingPathComponent("late-backup"), password: BackupTests.passphrase) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted() == [".storebench-backup.mutex", "backup"])
    }

    @Test func signOutDrainsCredentialRollbackAndNeverRepopulatesTheClosedVault() async throws {
        let root = try TestIsolation.require().appendingPathComponent("synthetic-session-connection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage()), session = try Workspace(root: root).createFresh(writer: writer, password: nil)
        let before = try writer.read().entries, pem = P256.Signing.PrivateKey().pemRepresentation
        let host = "session-connection-rollback.appstoreconnect.test", gate = AnalyticsJobDelayStubProtocol.Gate(), lifetime = await session.lifetime
        defer { gate.release() }
        AnalyticsJobDelayStubProtocol.register(host, gate: gate, bytes: Data(#"{"data":[],"links":{}}"#.utf8))
        func configuration() -> URLSessionConfiguration { let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [AnalyticsJobDelayStubProtocol.self]; return value }
        let connecting = Task { try await session.connectAccount(name: "Synthetic connection", keyType: "individual", issuerId: nil, keyId: "SYNTHKEY01", privateKeyPEM: pem, writer: writer, origin: URL(string: "https://\(host)")!, configuration: configuration()) }
        try await wait { gate.pending == 1 }
        let closing = Task { try await session.signOut() }
        try await wait { lifetime.status == .closing }
        #expect(try writer.read().entries.count == before.count + 1)
        gate.release()
        await #expect(throws: AccountFailure.empty) { try await connecting.value }
        try await closing.value
        #expect(try writer.read().entries == before)
        #expect(await session.vault.entries.isEmpty)
        await #expect(throws: SessionFailure.closed) { try await session.connectAccount(name: "Synthetic late connection", keyType: "individual", issuerId: nil, keyId: "SYNTHKEY02", privateKeyPEM: pem, writer: writer, origin: URL(string: "https://\(host)")!, configuration: configuration()) }
        #expect(try writer.read().entries == before)
    }

    @Test func aLateReporterDiscoveryCannotSaveOrOfferAChoiceFromAClosedSession() async throws {
        let fixture = try await AccountLifecycleTests().fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try fixture.writer.read().entries, baseline = try await fixture.session.reportingConnection(account: fixture.account, appId: "1000000001")
        let gate = AnalyticsJobDelayStubProtocol.Gate(), host = "session-late-discovery.reporting.test"
        defer { gate.release() }
        AnalyticsJobDelayStubProtocol.register(host, gate: gate, bytes: Data("<Accounts><Account><Name>Synthetic first</Name><Number>1000</Number></Account><Account><Name>Synthetic second</Name><Number>2000</Number></Account></Accounts>".utf8), headers: ["Content-Type": "text/xml"])
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AnalyticsJobDelayStubProtocol.self]
        let discovery = Task { try await fixture.session.connectReporter(account: fixture.account, appId: "1000000001", token: "synthetic-session-reporter-token", baseline: baseline, writer: fixture.writer, origin: URL(string: "https://\(host)")!, configuration: configuration) }
        try await wait { gate.pending == 1 }
        try await fixture.session.signOut()
        gate.release()
        await #expect(throws: SessionFailure.closed) { try await discovery.value }
        #expect(try fixture.writer.read().entries == before)
        #expect(await fixture.session.vault.entries.isEmpty)
    }
}
