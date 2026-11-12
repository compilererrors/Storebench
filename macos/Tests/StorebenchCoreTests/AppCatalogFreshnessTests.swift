import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AppCatalogFreshnessTests {
    init() throws { _ = try TestIsolation.require() }
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)
    private func reply(_ ids: [String] = ["1000000001"]) -> Data {
        JSONText.object([("data", .array(ids.map { .object([("type", .string("apps")), ("id", .string($0)), ("attributes", .object([("name", .string("Synthetic Catalog App"))]))]) })), ("links", .object([]))]).data
    }
    private func client(_ account: Account, host: String, gated: Bool = false) throws -> AppStoreConnectClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = gated ? [AnalyticsJobDelayStubProtocol.self] : [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: config)
    }
    private func saveAccounts(_ accounts: [Account], session: WorkspaceSession) async throws {
        try await session.storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("accounts.mutex")) {
                try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array(accounts.map(WorkspaceSession.json)).data)] }
            }
        }
    }

    @Test func successfulDiscoveryIsReusedAcrossSessionsUntilFifteenMinutesPass() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "freshness.appstoreconnect.test", now = instant
        StubProtocol.handle(host) { _ in (200, [:], reply()) }
        #expect(try await session.appCatalogNeedsRefresh(now: now))
        let first = try await session.refreshAppCatalog(onlyIfNeeded: true, now: { now }) { try client($0, host: host) }
        #expect(first.refreshedAccounts == 1)
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        #expect(try await !reopened.appCatalogNeedsRefresh(now: now.addingTimeInterval(899)))
        _ = try await reopened.refreshAppCatalog(onlyIfNeeded: true, now: { now.addingTimeInterval(899) }) { try client($0, host: host) }
        #expect(StubProtocol.requests(host).count == 1)
        _ = try await reopened.refreshAppCatalog(onlyIfNeeded: true, now: { now.addingTimeInterval(900) }) { try client($0, host: host) }
        #expect(StubProtocol.requests(host).count == 2)
        #expect(StubProtocol.requests(host).allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func failedAccountBacksOffWhileOtherAccountsRefreshAndManualRetryBypassesWaiting() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try #require(try await session.accounts().first), now = instant
        let other = Account(id: "synthetic-auto-other", name: "Synthetic Other", keyId: "AUTOREAD02", keyType: "individual", issuerId: nil, appIds: ["1000000002"], appNames: [:])
        try await saveAccounts([original, other], session: session)
        let failed = "backoff.appstoreconnect.test", good = "other-freshness.appstoreconnect.test"
        StubProtocol.handle(failed) { _ in (403, [:], Data()) }
        StubProtocol.handle(good) { _ in (200, [:], reply(["1000000002"])) }
        let first = try await session.refreshAppCatalog(onlyIfNeeded: true, now: { now }) { try client($0, host: $0.id == original.id ? failed : good) }
        #expect(first.refreshedAccounts == 1 && first.issues.count == 1)
        #expect(try await session.accounts().first { $0.id == original.id } == original)
        _ = try await session.refreshAppCatalog(onlyIfNeeded: true, now: { now.addingTimeInterval(59) }) { try client($0, host: $0.id == original.id ? failed : good) }
        #expect(StubProtocol.requests(failed).count == 1 && StubProtocol.requests(good).count == 1)
        _ = try await session.refreshAppCatalog(onlyIfNeeded: true, now: { now.addingTimeInterval(60) }) { try client($0, host: $0.id == original.id ? failed : good) }
        #expect(StubProtocol.requests(failed).count == 2 && StubProtocol.requests(good).count == 1)
        _ = try await session.refreshAppCatalog(onlyIfNeeded: true, now: { now.addingTimeInterval(179) }) { try client($0, host: $0.id == original.id ? failed : good) }
        #expect(StubProtocol.requests(failed).count == 2)
        StubProtocol.handle(failed) { _ in (200, [:], reply()) }
        let manual = try await session.refreshAppCatalog(now: { now.addingTimeInterval(70) }) { try client($0, host: $0.id == original.id ? failed : good) }
        #expect(manual.complete && manual.refreshedAccounts == 2)
        #expect(try await !session.appCatalogNeedsRefresh(now: now.addingTimeInterval(71)))
    }

    @Test func anotherAutomaticOwnerPreventsDuplicateDiscovery() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), now = instant, host = "owned-catalog.appstoreconnect.test"
        let gate = AnalyticsJobDelayStubProtocol.Gate(); defer { gate.release() }
        AnalyticsJobDelayStubProtocol.register(host, gate: gate, bytes: reply())
        let client = try client(account, host: host, gated: true)
        let first = Task { try await session.refreshAppCatalog(onlyIfNeeded: true, now: { now }) { _ in client } }
        let deadline = ContinuousClock.now + .seconds(5)
        while gate.pending == 0 { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let skipped = try await second.refreshAppCatalog(onlyIfNeeded: true, now: { now }) { _ in Issue.record("Another owner must not dispatch a duplicate read"); return client }
        #expect(skipped.refreshedAccounts == 0 && gate.pending == 1)
        gate.release()
        #expect(try await first.value.refreshedAccounts == 1)
        #expect(try await !second.appCatalogNeedsRefresh(now: now))
    }

    @Test func anOlderFailureCannotReplaceANewerSuccessfulReceipt() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "receipt-order.appstoreconnect.test", now = instant
        StubProtocol.handle(host) { _ in (200, [:], reply()) }
        _ = try await session.refreshAppCatalog(now: { now.addingTimeInterval(100) }) { try client($0, host: host) }
        let account = try #require(try await session.accounts().first)
        try await session.recordCatalogFailure(account, started: now, now: now.addingTimeInterval(101))
        #expect(try await !session.appCatalogNeedsRefresh(now: now.addingTimeInterval(102)))
    }

    @Test func changedConnectionsAndBackwardClockChangesRecheckTheCatalog() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "receipt-scope.appstoreconnect.test", now = instant
        StubProtocol.handle(host) { _ in (200, [:], reply()) }
        _ = try await session.refreshAppCatalog(now: { now }) { try client($0, host: host) }
        #expect(try await session.appCatalogNeedsRefresh(now: now.addingTimeInterval(-1)))
        let old = try #require(try await session.accounts().first)
        let changed = Account(id: old.id, name: old.name, keyId: "AUTOREAD03", keyType: old.keyType, issuerId: old.issuerId, appIds: old.appIds, appNames: old.appNames)
        try await saveAccounts([changed], session: session)
        #expect(try await session.appCatalogNeedsRefresh(now: now.addingTimeInterval(1)))
    }

    @Test func backgroundDiscoveryReservesApplesRemainingBudgetForVisibleReads() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(id: "synthetic-reserved", name: "Synthetic Reserved", keyId: "AUTOLOW001", keyType: "individual", issuerId: nil, appIds: ["1000000001"], appNames: [:])
        try await saveAccounts([account], session: session)
        let host = "reserved-catalog.appstoreconnect.test", now = instant
        AppleRequestBudget.record(HTTPURLResponse(url: URL(string: "https://\(host)")!, statusCode: 429, httpVersion: nil, headerFields: nil)!, keyId: account.keyId)
        #expect(try await !session.appCatalogNeedsRefresh(now: now))
        let skipped = try await session.refreshAppCatalog(onlyIfNeeded: true, now: { now }) { _ in Issue.record("Background reads must keep the reserve"); return try client(account, host: host) }
        #expect(skipped.refreshedAccounts == 0)
        StubProtocol.handle(host) { _ in (200, [:], reply()) }
        #expect(try await session.refreshAppCatalog(now: { now }) { try client($0, host: host) }.refreshedAccounts == 1)
    }
}
