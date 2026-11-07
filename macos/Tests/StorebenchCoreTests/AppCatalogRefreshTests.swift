import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AppCatalogRefreshTests {
    init() throws { _ = try TestIsolation.require() }
    private func client(_ account: Account, host: String, cache: AppStoreReadCache? = nil) throws -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration, readCache: cache)
    }
    private func reply(_ ids: [String], next: String? = nil) -> Data {
        let data = ids.map { ["type": "apps", "id": $0, "attributes": ["name": "Synthetic App " + $0]] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: ["data": data, "links": next.map { ["next": $0] } ?? [:]])
    }

    @Test func discoveryFollowsEveryPageAndNewAppsOpenEveryWorkflowWithoutAnArchive() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "catalog-discovery.appstoreconnect.test"
        let oldId = try #require(account.appIds.first), first = "1000000900", second = "1000000901"
        let firstURL = "https://\(host)/v1/apps?limit=200"
        let nextURL = firstURL + "&cursor=synthetic-next"
        let firstPage = reply([oldId, first], next: nextURL)
        let lastPage = reply([second])
        #expect(try JSONDecoder().decode(AppStoreConnectClient.Page.self, from: lastPage).links?.next == nil)
        StubProtocol.handle(host) { request in
            guard request.httpMethod == "GET" else { return (404, [:], Data()) }
            switch request.url?.absoluteString {
            case firstURL: return (200, [:], firstPage)
            case nextURL: return (200, [:], lastPage)
            default: return (404, [:], Data())
            }
        }
        let discoveryClient = try client(account, host: host)
        #expect(try await discoveryClient.list("/v1/apps?limit=200").map(\.id) == [oldId, first, second])
        let summary = try await session.refreshAppCatalog { _ in discoveryClient }
        try #require(summary.complete, Comment(rawValue: summary.message))
        #expect(summary.refreshedAccounts > 0 && summary.message.contains("first release"))
        let updated = try #require(try await session.accounts().first { $0.id == account.id })
        #expect(updated.appIds == [oldId, first, second])
        for section in LibraryChooser.sections {
            let entries = try await session.libraryChooser(section)
            let entry = try #require(entries.first { $0.row.account.id == account.id && $0.row.app.id == first })
            #expect(entry.row.revisionCount == 0 || entry.row.revisionCount == nil)
            let destination = try entry.destination(section)
            #expect(destination.section == section)
        }
        let plan = try await session.saveReleasePlan(account: updated, appId: first, start: .empty(platform: "MAC_OS", locale: "en-US"),
                                                     sourceRevisionId: nil, baseVersionId: nil, targetVersion: "1.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        #expect(plan.targetVersion == "1.0" && plan.platform == "MAC_OS")
        let requests = StubProtocol.requests(host)
        #expect(requests.compactMap { $0.url?.absoluteString } == [firstURL, nextURL, firstURL, nextURL])
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func explicitDiscoverySkipsAnEarlierCachedAppListAndKeepsSavedHistory() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), oldId = try #require(account.appIds.first)
        let history = try await session.archivedHistory(accountId: account.id, appId: oldId), host = "catalog-fresh.appstoreconnect.test"
        let cache = AppStoreReadCache(), client = try client(account, host: host, cache: cache)
        StubProtocol.handle(host) { _ in (200, [:], reply([oldId])) }
        _ = try await client.list("/v1/apps?limit=200")
        StubProtocol.handle(host) { _ in (200, [:], reply([oldId, "1000000900"])) }
        let updated = try await session.refreshAccountApps(account, client: client)
        #expect(updated.appIds == [oldId, "1000000900"])
        #expect(try await session.archivedHistory(accountId: account.id, appId: oldId).map(\.value) == history.map(\.value))
    }

    @Test func oneRefusedAccountKeepsItsAppsWhileAnotherAccountRefreshes() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try #require(try await session.accounts().first)
        let refused = Account(id: "synthetic-refused", name: "Synthetic Refused Account", keyId: "SYNTHKEY02", keyType: "individual", issuerId: nil, appIds: ["1000000909"], appNames: ["1000000909": "Synthetic Saved App"])
        try await session.storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("accounts.mutex")) {
                try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([original, refused].map(WorkspaceSession.json)).data)] }
            }
        }
        let host = "catalog-partial.appstoreconnect.test"
        StubProtocol.handle(host) { _ in (200, [:], reply(["1000000900"])) }
        let summary = try await session.refreshAppCatalog { account in
            if account.id == refused.id { throw AccountFailure.access }
            return try client(account, host: host)
        }
        #expect(!summary.complete && summary.refreshedAccounts == 1 && summary.issues.first?.reason == .access)
        let current = try await session.accounts()
        #expect(current.first { $0.id == original.id }?.appIds == ["1000000900"])
        #expect(current.first { $0.id == refused.id } == refused)
        #expect(summary.message.contains("still shown"))
    }

    @Test @MainActor func aCancelledRefreshDoesNotReplaceTheSavedSelection() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await session.accounts(), account = try #require(before.first)
        let host = "catalog-cancelled.appstoreconnect.test"
        StubProtocol.handle(host) { _ in (200, [:], reply(["1000000900"])) }
        let client = try client(account, host: host)
        let task = Task {
            return try await session.refreshAccountApps(account, client: client)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled catalog refresh unexpectedly succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(try await session.accounts() == before)
        #expect(StubProtocol.requests(host).isEmpty)
    }
}
