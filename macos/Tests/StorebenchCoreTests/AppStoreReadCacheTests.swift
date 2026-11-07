import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AppStoreReadCacheTests {
    init() throws { _ = try TestIsolation.require() }
    private enum Failure: Error { case synthetic }
    private func syntheticClient(_ source: AppStoreConnectClient, host: String) -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: source.token, origin: URL(string: "https://" + host)!, configuration: configuration,
            readCache: source.readCache, readCacheScope: source.readCacheScope, accessCheck: source.accessCheck)
    }
    @Test func differentViewsShareTheSessionsResponsesAndSignOutRevokesCachedClients() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let host = "shared-screen-reads.synthetic.test"
        StubProtocol.handle(host) { _ in (200, ["Content-Type": "application/json"], Data(#"{"data":[],"links":{}}"#.utf8)) }
        let overview = try await f.session.readClient(for: f.account), release = try await f.session.readClient(for: f.account)
        #expect(overview.readCache != nil && overview.readCache === release.readCache)
        let first = syntheticClient(overview, host: host), second = syntheticClient(release, host: host)
        _ = try await first.list("/v1/apps/1000000001/appStoreVersions?limit=200")
        _ = try await second.list("/v1/apps/1000000001/appStoreVersions?limit=200")
        #expect(StubProtocol.requests(host).count == 1)
        await f.session.invalidateAppleReads()
        _ = try await second.list("/v1/apps/1000000001/appStoreVersions?limit=200")
        #expect(StubProtocol.requests(host).count == 2)
        let fresh = try await f.session.client(for: f.account); #expect(fresh.readCache == nil)
        try await f.session.signOut()
        await #expect(throws: SessionFailure.closed) { try await first.list("/v1/apps/1000000001/appStoreVersions?limit=200") }
        #expect(StubProtocol.requests(host).count == 2)
    }
    @Test func replacingACredentialCannotReuseThePreviousConnectionsResponses() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let host = "shared-screen-credential.synthetic.test"
        StubProtocol.handle(host) { _ in (200, ["Content-Type": "application/json"], Data(#"{"data":[],"links":{}}"#.utf8)) }
        let old = try await f.session.readClient(for: f.account)
        _ = try await syntheticClient(old, host: host).get("/v1/apps/1000000001")
        _ = try f.writer.writeCredential("apple:" + f.account.id, root: f.root, value: P256.Signing.PrivateKey().pemRepresentation, expected: f.key.pemRepresentation)
        let replacement = try await f.session.readClient(for: f.account)
        #expect(old.readCache === replacement.readCache && old.readCacheScope != replacement.readCacheScope)
        _ = try await syntheticClient(replacement, host: host).get("/v1/apps/1000000001")
        #expect(StubProtocol.requests(host).count == 2)
        try await f.session.signOut()
    }
    @Test(arguments: [false, true]) func publishingInvalidatesSharedObservationsIncludingFailedWrites(denyWrite: Bool) async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let host = "shared-screen-publish-\(denyWrite).synthetic.test", apple = SyntheticApple()
        StubProtocol.handle(host) { request in
            if denyWrite && request.httpMethod != "GET" { return (403, ["Content-Type": "application/json"], Data(#"{"errors":[]}"#.utf8)) }
            return apple.handle(request)
        }
        let shared = try await f.session.readClient(for: f.account), cache = try #require(shared.readCache)
        _ = try await cache.read("synthetic-observation") { Data("before".utf8) }
        let fresh = syntheticClient(try await f.session.client(for: f.account), host: host)
        let review = try await f.session.preparePublishing(account: f.account, request: .init(accountId: f.account.id, appId: "1000000001", scope: .versionCopyright,
            versionId: "version-1", copyright: "2026 Synthetic Studio"), client: fresh)
        let result = try await f.session.approvePublishing(account: f.account, appId: "1000000001", id: review.id, fingerprint: review.fingerprint, client: fresh)
        #expect(result.state == (denyWrite ? "failed" : "complete"))
        #expect(try await cache.read("synthetic-observation") { Data("after".utf8) } == Data("after".utf8))
        try await f.session.signOut()
    }
    private actor Reader {
        var calls = 0
        func load() async throws -> Data { calls += 1; try await Task.sleep(for: .milliseconds(30)); return Data("synthetic response".utf8) }
    }
    private actor Gate {
        var entered = false
        private var continuation: CheckedContinuation<Data, Never>?
        func load() async -> Data { await withCheckedContinuation { continuation = $0; entered = true } }
        func release() { continuation?.resume(returning: Data("old synthetic response".utf8)); continuation = nil }
        /// The first read waits for `release`; later reads answer at once with the newer response.
        var calls = 0
        func next() async -> Data { calls += 1; return calls == 1 ? await load() : Data("new synthetic response".utf8) }
    }
    @Test func invalidationRereadsInsteadOfReturningOrFailingAnOlderInFlightRead() async throws {
        let cache = AppStoreReadCache(), gate = Gate()
        let task = Task { try await cache.read("synthetic") { await gate.next() } }
        let deadline = ContinuousClock.now + .seconds(5)
        while await !gate.entered {
            guard ContinuousClock.now < deadline else { throw Failure.synthetic }; try await Task.sleep(for: .milliseconds(10))
        }
        await cache.invalidate(); await gate.release()
        #expect(try await task.value == Data("new synthetic response".utf8))
        #expect(await gate.calls == 2)
        #expect(try await cache.read("synthetic") { Data("unused synthetic response".utf8) } == Data("new synthetic response".utf8))
    }
    @Test func aReaderCancelledItselfStillStops() async throws {
        let cache = AppStoreReadCache(), gate = Gate()
        let task = Task { try await cache.read("synthetic") { await gate.next() } }
        let deadline = ContinuousClock.now + .seconds(5)
        while await !gate.entered {
            guard ContinuousClock.now < deadline else { throw Failure.synthetic }; try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel(); await cache.invalidate(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await gate.calls == 1)
    }
    /// A synthetic request that answers when released and records whether it was stopped.
    private actor Held {
        var calls = 0, stopped = false
        private var waiting: CheckedContinuation<Void, Error>?
        func load() async throws -> Data {
            calls += 1
            do {
                try await withTaskCancellationHandler { try await withCheckedThrowingContinuation { waiting = $0 } } onCancel: { Task { await self.stop() } }
            } catch { stopped = true; throw error }
            return Data("held synthetic response".utf8)
        }
        func stop() { waiting?.resume(throwing: CancellationError()); waiting = nil }
        func release() { waiting?.resume(); waiting = nil }
        var open: Bool { waiting != nil }
    }
    @Test func aReaderThatLeavesStopsAtOnceWithoutStoppingTheSharedReadOthersStillNeed() async throws {
        let cache = AppStoreReadCache(), held = Held()
        let leaving = Task { try await cache.read("synthetic") { try await held.load() } }
        let staying = Task { try await cache.read("synthetic") { try await held.load() } }
        let deadline = ContinuousClock.now + .seconds(5)
        func ready() async -> Bool { let open = await held.open, count = await cache.readers("synthetic"); return open && count == 2 }
        while await !ready() { guard ContinuousClock.now < deadline else { throw Failure.synthetic }; try await Task.sleep(for: .milliseconds(5)) }
        leaving.cancel()
        // The leaving reader stops while the request is still open; the other reader keeps waiting for it.
        await #expect(throws: CancellationError.self) { try await leaving.value }
        let open = await held.open, remaining = await cache.readers("synthetic")
        #expect(open && remaining == 1)
        await held.release()
        #expect(try await staying.value == Data("held synthetic response".utf8))
        let calls = await held.calls, stopped = await held.stopped
        #expect(calls == 1 && !stopped)
        #expect(try await cache.read("synthetic") { Data("unused".utf8) } == Data("held synthetic response".utf8))
    }
    @Test func aSharedReadStopsWhenEveryReaderLeaves() async throws {
        let cache = AppStoreReadCache(), held = Held()
        let readers = (0..<2).map { _ in Task { try await cache.read("synthetic") { try await held.load() } } }
        let deadline = ContinuousClock.now + .seconds(5)
        func ready() async -> Bool { let open = await held.open, count = await cache.readers("synthetic"); return open && count == 2 }
        while await !ready() { guard ContinuousClock.now < deadline else { throw Failure.synthetic }; try await Task.sleep(for: .milliseconds(5)) }
        for reader in readers { reader.cancel() }
        for reader in readers { await #expect(throws: CancellationError.self) { try await reader.value } }
        while await !held.stopped { guard ContinuousClock.now < deadline else { throw Failure.synthetic }; try await Task.sleep(for: .milliseconds(5)) }
        // Nothing was kept, so the next reader asks again.
        #expect(try await cache.read("synthetic") { Data("fresh synthetic response".utf8) } == Data("fresh synthetic response".utf8))
    }
    @Test func aRefreshReadsItsOwnScreenAgainAndKeepsWhatOtherScreensRead() async throws {
        let cache = AppStoreReadCache(), reader = Reader()
        _ = try await cache.read("synthetic/builds") { try await reader.load() }
        _ = try await cache.read("synthetic/pricing") { try await reader.load() }
        #expect(await reader.calls == 2)
        // Refreshing the builds reads them again and keeps the new answer; pricing is still served from the earlier read.
        let fresh = try await AppStoreReadCache.refreshing { try await cache.read("synthetic/builds") { Data("refreshed builds".utf8) } }
        #expect(fresh == Data("refreshed builds".utf8))
        _ = try await cache.read("synthetic/pricing") { try await reader.load() }
        #expect(await reader.calls == 2)
        #expect(try await cache.read("synthetic/builds") { Data("unused".utf8) } == Data("refreshed builds".utf8))
    }
    @Test func aRefreshDoesNotJoinAnOlderRequestAndThatRequestsAnswerIsNotKept() async throws {
        let cache = AppStoreReadCache(), held = Held()
        let older = Task { try await cache.read("synthetic") { try await held.load() } }
        let deadline = ContinuousClock.now + .seconds(5)
        func ready() async -> Bool { let open = await held.open, count = await cache.readers("synthetic"); return open && count == 1 }
        while await !ready() { guard ContinuousClock.now < deadline else { throw Failure.synthetic }; try await Task.sleep(for: .milliseconds(5)) }
        let fresh = try await AppStoreReadCache.refreshing { try await cache.read("synthetic") { Data("refreshed synthetic response".utf8) } }
        #expect(fresh == Data("refreshed synthetic response".utf8))
        // The earlier reader still gets its own answer, but the newer one stays kept.
        await held.release()
        #expect(try await older.value == Data("held synthetic response".utf8))
        #expect(try await cache.read("synthetic") { Data("unused".utf8) } == Data("refreshed synthetic response".utf8))
    }
    @Test func simultaneousReadersShareOneRequestAndInvalidationForcesANewRead() async throws {
        let cache = AppStoreReadCache(), reader = Reader()
        async let first = cache.read("synthetic") { try await reader.load() }
        async let second = cache.read("synthetic") { try await reader.load() }
        let (a, b) = try await (first, second)
        #expect(a == b && a == Data("synthetic response".utf8)); #expect(await reader.calls == 1)
        _ = try await cache.read("synthetic") { try await reader.load() }; #expect(await reader.calls == 1)
        await cache.invalidate()
        _ = try await cache.read("synthetic") { try await reader.load() }; #expect(await reader.calls == 2)
    }
    @Test func expiredAndFailedReadsAreNeverReused() async throws {
        let cache = AppStoreReadCache(lifetime: .zero), reader = Reader()
        for _ in 0..<2 { _ = try await cache.read("synthetic") { try await reader.load() } }
        #expect(await reader.calls == 2)
        await #expect(throws: Failure.synthetic) { try await cache.read("failure") { throw Failure.synthetic } }
        #expect(try await cache.read("failure") { Data("recovered".utf8) } == Data("recovered".utf8))
    }
    @Test func openingAScreenChecksRemoteOnceAndNestedStepsReuseThatAnswer() async throws {
        let cache = AppStoreReadCache(), reader = Reader()
        _ = try await cache.read("synthetic/screen") { try await reader.load() }
        _ = try await cache.read("synthetic/other") { try await reader.load() }
        try await ScreenReads.reading(fresh: false) {
            _ = try await cache.read("synthetic/screen") { try await reader.load() }
            try await ScreenReads.reading(fresh: false) {
                _ = try await cache.read("synthetic/screen") { try await reader.load() }
            }
        }
        #expect(await reader.calls == 3)
        _ = try await cache.read("synthetic/other") { try await reader.load() }
        #expect(await reader.calls == 3)
        // A later opening validates again. Reading ahead retains the configured cache lifetime.
        try await ScreenReads.reading(fresh: false) { _ = try await cache.read("synthetic/screen") { try await reader.load() } }
        try await ScreenReads.ahead {
            try await ScreenReads.reading(fresh: false) { _ = try await cache.read("synthetic/screen") { try await reader.load() } }
        }
        #expect(await reader.calls == 4)
    }
    @Test func openingScreensJoinTheSameRemoteReadInsteadOfReplacingIt() async throws {
        let cache = AppStoreReadCache(), held = Held()
        let first = Task { try await ScreenReads.reading(fresh: false) { try await cache.read("synthetic/screen") { try await held.load() } } }
        let deadline = ContinuousClock.now + .seconds(5)
        while await !held.open { guard ContinuousClock.now < deadline else { throw Failure.synthetic }; try await Task.sleep(for: .milliseconds(5)) }
        let second = Task { try await ScreenReads.reading(fresh: false) { try await cache.read("synthetic/screen") { try await held.load() } } }
        while await cache.readers("synthetic/screen") < 2 { guard ContinuousClock.now < deadline else { throw Failure.synthetic }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await held.calls == 1)
        await held.release()
        #expect(try await first.value == second.value)
        #expect(await held.calls == 1)
    }
    @Test func cachedClientsSeparateAccountsAndFreshClientsAlwaysReadApple() async throws {
        let host = "release-read-cache.synthetic.test", cache = AppStoreReadCache()
        StubProtocol.handle(host) { _ in
            (200, ["Content-Type": "application/json"], Data(#"{"data":{"type":"apps","id":"1000000001","attributes":{"name":"Synthetic App"}}}"#.utf8))
        }
        func client(_ id: String, cached: Bool = true) throws -> AppStoreConnectClient {
            let account = Account(id: id, name: "Synthetic Account", keyId: "SYNTHETIC1", keyType: "individual", issuerId: nil, appIds: ["1000000001"], appNames: nil)
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
            return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation),
                origin: URL(string: "https://" + host)!, configuration: configuration, readCache: cached ? cache : nil)
        }
        let first = try client("synthetic-one"), second = try client("synthetic-two"), fresh = try client("synthetic-one", cached: false)
        _ = try await first.get("/v1/apps/1000000001"); _ = try await first.get("/v1/apps/1000000001")
        #expect(StubProtocol.requests(host).count == 1)
        _ = try await second.get("/v1/apps/1000000001"); #expect(StubProtocol.requests(host).count == 2)
        _ = try await fresh.get("/v1/apps/1000000001"); _ = try await fresh.get("/v1/apps/1000000001")
        #expect(StubProtocol.requests(host).count == 4)
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        await #expect(throws: PublishFailure.self) {
            try await session.publishPlan(account: account, request: .init(accountId: account.id, appId: "1000000001", scope: .release), client: first)
        }
        #expect(StubProtocol.requests(host).count == 4)
    }
}
