import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AppIconsTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001"
    let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 83, 121, 110, 116, 104])
    func rows(_ value: JSONText?) throws -> [JSONText] { guard case .array(let rows)? = value else { throw ConnectedApps.Failure.changed }; return rows }
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/app-icons.json"))) }
    func client(_ suffix: String, account: Account, bytes: Data? = nil, headers: [String: String] = ["Content-Type": "image/png"], status: Int = 200,
                gate: AnalyticsJobDelayStubProtocol.Gate? = nil, missing: Bool = false) throws -> AppStoreConnectClient {
        let host = "icons-\(suffix).appstoreconnect.test", images = "icons-\(suffix).mzstatic.com", payload = bytes ?? png
        StubProtocol.handle(host) { request in
            // Without an App Store icon the newest build's icon is asked for; these synthetic builds have none.
            if request.url?.path == "/v1/builds" {
                #expect(request.url?.query?.removingPercentEncoding == "filter[app]=1000000001&sort=-uploadedDate&limit=1&include=icons")
                return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": [], "included": []]))
            }
            #expect(request.url?.path == "/v1/apps/1000000001" && request.url?.query == "include=appStoreIcon")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            let app: [String: Any] = ["type": "apps", "id": "1000000001", "attributes": [:], "relationships": ["appStoreIcon": ["data": ["type": "buildIcons", "id": "synthetic-icon"]]]]
            let icon: [String: Any] = ["type": "buildIcons", "id": "synthetic-icon", "attributes": ["iconAsset": ["templateUrl": "https://\(images)/synthetic/{w}.{f}"]]]
            return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": app, "included": missing ? [] : [icon], "links": ["next": "https://synthetic.invalid/private-cursor"]]))
        }
        if let gate { AnalyticsJobDelayStubProtocol.register(images, gate: gate, bytes: payload, headers: headers) }
        else { StubProtocol.handle(images) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.url?.path == "/synthetic/128.png")
            return (status, headers, payload)
        } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsJobDelayStubProtocol.self, StubProtocol.self]
        configuration.httpAdditionalHeaders = ["Cookie": "synthetic-cookie"]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation),
                                     origin: URL(string: "https://\(host)")!, configuration: configuration)
    }
    func wait(_ test: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try await test()) { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
    }
    @Test func metadataInitialsAndImageSignaturesMatchTheActualPrimary() throws {
        let fixture = try fixture(), urls = try rows(fixture["urls"]), initials = try rows(fixture["initials"]), images = try rows(fixture["images"])
        #expect(urls.count == 27 && initials.count == 10 && images.count == 20)
        for row in urls {
            let app = try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: #require(row["app"]).data)
            let included = try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: #require(row["included"]).data)
            #expect(AppIcons.assetURL(app: app, included: included)?.absoluteString == row["expected"]?.text)
        }
        for row in initials { #expect(AppIcons.initial(try #require(row["name"]?.text)) == row["expected"]?.text) }
        for row in images {
            let data = Data(try rows(row["bytes"]).map { value -> UInt8 in
                guard case .number(let number) = value, let byte = UInt8(exactly: number) else { throw ConnectedApps.Failure.changed }; return byte
            })
            #expect((AppIcons.Image(data: data, contentType: try #require(row["contentType"]?.text)) != nil) == (row["accepted"] == .bool(true)))
        }
    }
    @Test func cacheUsesBoundedFifoAndIndependentPositiveAndNegativeExpiry() throws {
        var cache = AppIcons.Cache(); let now = ContinuousClock.now, image = try #require(AppIcons.Image(data: png, contentType: "image/png"))
        cache.insert(image, key: "synthetic-positive", now: now); cache.insert(nil, key: "synthetic-negative", now: now)
        #expect(cache.entries["synthetic-positive"]?.expires == now + .seconds(3600))
        #expect(cache.entries["synthetic-negative"]?.expires == now + .seconds(60))
        #expect(cache.cached("synthetic-positive", now: now + .seconds(3599))?.image == image)
        #expect(cache.cached("synthetic-positive", now: now + .seconds(3600)) == nil)
        #expect(cache.cached("synthetic-negative", now: now + .seconds(59)) != nil)
        #expect(cache.cached("synthetic-negative", now: now + .seconds(60)) == nil)
        for index in 0..<100 { cache.insert(image, key: "synthetic-\(index)", now: now) }
        #expect(cache.entries.count == 100 && cache.order.count == 100 && cache.entries["synthetic-positive"] == nil && cache.entries["synthetic-negative"] == nil)
        cache.insert(nil, key: "synthetic-99", now: now + .seconds(1))
        #expect(cache.entries.count == 100 && cache.order.count == 100)
    }
    @Test func simultaneousCardsShareOneDownloadAndCancellationDoesNotConsumeAnotherCardsResult() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), gate = AnalyticsJobDelayStubProtocol.Gate(), client = try client("shared", account: account, gate: gate)
        let cancelled = Task { try await session.appIcon(account: account, appId: appId, client: client) }
        try await wait { gate.pending == 1 }
        let other = Task { try await session.appIcon(account: account, appId: appId, client: client) }
        cancelled.cancel(); gate.release()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await other.value?.data == png)
        #expect(try await session.appIcon(account: account, appId: appId, client: client)?.data == png)
        #expect(StubProtocol.requests("icons-shared.appstoreconnect.test").count == 1)
        #expect(session.lifetime.activeCount == 0)
    }
    @Test func actualByteLimitsMimeAndRedirectsLeaveOnlyTheOrdinaryFallback() async throws {
        for (suffix, bytes, type, length, status) in [
            ("too-large", png + Data(repeating: 0, count: AppIcons.maximumBytes), "image/png", "1", 200),
            ("declared-large", png, "image/png", "2000001", 200),
            ("wrong-type", png, "text/plain", "13", 200),
            ("wrong-signature", Data("Synthetic text".utf8), "image/png", "14", 200),
            ("redirect", png, "image/png", "13", 302)
        ] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first)
            let client = try client(suffix, account: account, bytes: bytes, headers: ["Content-Type": type, "Content-Length": length, "Location": "https://synthetic.invalid/private-image"], status: status)
            #expect(try await session.appIcon(account: account, appId: appId, client: client) == nil)
            #expect(try await session.appIcon(account: account, appId: appId, client: client) == nil)
            #expect(StubProtocol.requests("icons-\(suffix).appstoreconnect.test").count == 1)
            #expect(StubProtocol.requests("synthetic.invalid").isEmpty)
        }
    }
    @Test func missingImagesAreCachedWhileForeignScopeAndChangedAccountCannotReuseThem() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), client = try client("missing", account: account, missing: true)
        #expect(try await session.appIcon(account: account, appId: appId, client: client) == nil)
        #expect(try await session.appIcon(account: account, appId: appId, client: client) == nil)
        await #expect(throws: RevisionHistoryFailure.invalid) { try await session.appIcon(account: account, appId: "1000000999", client: client) }
        // One read of the app and one of its newest build; the missing icon is then kept and not asked for again.
        #expect(StubProtocol.requests("icons-missing.appstoreconnect.test").count == 2)
        try await session.storeAccess { store in
            let changed = Account(id: account.id, name: account.name, keyId: "SYNTHKEY02", keyType: account.keyType, issuerId: account.issuerId, appIds: account.appIds, appNames: account.appNames)
            try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] }
        }
        await #expect(throws: AccountFailure.stale) { try await session.appIcon(account: account, appId: appId, client: client) }
    }
    @Test func savedIconsShowAfterTheMemoryCacheIsGoneWithoutAskingAppleAgain() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), client = try client("saved", account: account)
        #expect(try await session.appIcon(account: account, appId: appId, client: client)?.data == png)
        await session.clearIconMemoryForTesting()
        #expect(try await session.appIcon(account: account, appId: appId, client: client)?.data == png)
        #expect(StubProtocol.requests("icons-saved.appstoreconnect.test").count == 1)
    }
    @Test func protectionChangesAndSignOutStopPendingImageDeliveryAndClearTheCache() async throws {
        for close in [false, true] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), gate = AnalyticsJobDelayStubProtocol.Gate()
            let client = try client(close ? "close" : "generation", account: account, gate: gate)
            let pending = Task { try await session.appIcon(account: account, appId: appId, client: client) }
            try await wait { gate.pending == 1 }
            if close {
                let closing = Task { try await session.signOut() }
                // Cancelling the bounded image reader can drain the session before this observer runs.
                try await wait { session.lifetime.status != .open }
                gate.release()
                _ = try await closing.value
                #expect(session.lifetime.status == .closed)
                await #expect(throws: (any Error).self) { try await pending.value }
            } else {
                try Setup.replaceGeneration(root.appendingPathComponent("state-v2")); gate.release()
                await #expect(throws: SessionFailure.changed) { try await pending.value }
            }
            #expect(await session.iconCache.entries.isEmpty && session.lifetime.activeCount == 0)
        }
    }
    @Test func anAccountChangedDuringTheImageReadCannotDeliverOrCacheItsOlderResult() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), gate = AnalyticsJobDelayStubProtocol.Gate(), client = try client("catalog-change", account: account, gate: gate)
        let pending = Task { try await session.appIcon(account: account, appId: appId, client: client) }
        try await wait { gate.pending == 1 }
        try await session.storeAccess { store in
            let changed = Account(id: account.id, name: "Synthetic changed account", keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: account.appIds, appNames: account.appNames)
            try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] }
        }
        gate.release()
        await #expect(throws: AccountFailure.stale) { try await pending.value }
        #expect(await session.iconCache.entries.isEmpty && session.lifetime.activeCount == 0)
    }
}
