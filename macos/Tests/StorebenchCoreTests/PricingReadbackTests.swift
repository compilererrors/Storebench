import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct PricingReadbackTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    let now = Date(timeIntervalSince1970: 1_780_272_000)

    private func pricedApple() -> SyntheticPricingApple {
        let apple = SyntheticPricingApple()
        apple.manual = [("price-existing", nil, nil, "app-pp-usa-099")]
        return apple
    }
    private func change(_ account: Account) -> PublishRequest {
        var request = PublishRequest(accountId: account.id, appId: app, scope: .pricingSetup)
        var setup = PricingSetupChange(action: .appPrice); setup.territory = "USA"; setup.pricePointId = "app-pp-usa-499"
        request.pricingSetup = setup; return request
    }
    private func observed(_ stream: AsyncStream<PricingReadEvent>) async throws {
        try await PricingScheduleRead.run(timeout: .seconds(3)) {
            var iterator = stream.makeAsyncIterator()
            #expect(await iterator.next() != nil)
        }
    }

    @Test func firstVisitLoadsCountriesConcurrentViewsJoinAndRecentSchedulesAreReused() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = pricedApple(), host = "first-prices.appstoreconnect.test"
        StubProtocol.handle(host) { #expect($0.httpMethod == "GET"); return apple.handle($0) }
        let client = try PricingTests().stubbedClient(host, account), app = app, now = now
        let changes = try await session.pricingChanges(account: account, appId: app)
        #expect(try await session.pricingScreen(account: account, appId: app).countries.isEmpty)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await session.refreshCountryPrices(account: account, appId: app, client: client, now: now) } }
            try await group.waitForAll()
        }
        try await observed(changes)
        #expect(StubProtocol.requests(host).count == 4)
        #expect(try await session.pricingScreen(account: account, appId: app).countries.first?.price.customerPrice == "0.99")
        try await session.refreshCountryPrices(account: account, appId: app, client: client, now: now.addingTimeInterval(299))
        #expect(StubProtocol.requests(host).count == 4)
        apple.lock.withLock { apple.manual = [("price-new", nil, nil, "app-pp-usa-499")] }
        try await session.refreshCountryPrices(account: account, appId: app, client: client, now: now.addingTimeInterval(301))
        #expect(StubProtocol.requests(host).count == 8)
        #expect(try await session.pricingScreen(account: account, appId: app).countries.first?.price.customerPrice == "4.99")
        #expect(apple.writes.isEmpty)
    }

    @Test func failedRefreshKeepsCountriesBacksOffAndExplicitRefreshRetries() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = pricedApple(), host = "retained-prices.appstoreconnect.test"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try PricingTests().stubbedClient(host, account)
        try await session.refreshCountryPrices(account: account, appId: app, client: client, now: now)
        StubProtocol.handle(host) { _ in (403, [:], Data()) }
        await #expect(throws: (any Error).self) { try await session.refreshCountryPrices(account: account, appId: app, client: client, force: true, now: now.addingTimeInterval(1)) }
        let failed = try await session.pricingScreen(account: account, appId: app)
        #expect(failed.countries.count == 1 && failed.saved?.code == "SB-APPLE-ACCESS")
        let count = StubProtocol.requests(host).count
        try await session.refreshCountryPrices(account: account, appId: app, client: client, now: now.addingTimeInterval(10))
        #expect(StubProtocol.requests(host).count == count)
        StubProtocol.handle(host) { apple.handle($0) }
        try await session.refreshCountryPrices(account: account, appId: app, client: client, force: true, now: now.addingTimeInterval(11))
        #expect(StubProtocol.requests(host).count == 4)
        #expect(try await session.pricingScreen(account: account, appId: app).saved?.code == nil)
    }

    @Test func invalidationSurvivesReopeningAndAReadStartedBeforeItCannotReplacePrices() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = pricedApple(), host = "invalidated-prices.appstoreconnect.test"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try PricingTests().stubbedClient(host, account)
        try await session.refreshCountryPrices(account: account, appId: app, client: client, now: now)
        let oldToken = try await session.pricingReadToken(accountId: account.id, appId: app)
        let old = try #require(try await session.savedPricing(accountId: account.id, appId: app)?.snapshot)
        try await session.invalidatePricing(accountId: account.id, appId: app)
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        apple.lock.withLock { apple.manual = [("price-new", nil, nil, "app-pp-usa-499")] }
        try await second.refreshCountryPrices(account: account, appId: app, client: client, now: now.addingTimeInterval(1))
        #expect(StubProtocol.requests(host).count == 8, "A persisted publication invalidation overrides an otherwise fresh observation")
        // Even after confirmation, a late pre-publication response cannot match the new baseline again.
        await #expect(throws: PricingFailure.stale) {
            try await session.savePricing(accountId: account.id, appId: app, checkedAt: CustomerReview.isoString(now.addingTimeInterval(2)), snapshot: old, code: nil, readToken: oldToken)
        }
        #expect(try await second.pricingScreen(account: account, appId: app).countries.first?.price.customerPrice == "4.99")
        #expect(try await second.pricingReadToken(accountId: account.id, appId: app).needsRefresh == false)
    }

    @Test func approvedPriceChangeReadsBackUpdatesObserversAndKeepsLocalDrafts() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = pricedApple(), host = "published-prices.appstoreconnect.test"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try PricingTests().stubbedClient(host, account)
        try await session.refreshCountryPrices(account: account, appId: app, client: client)
        _ = try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("USA", "USD", "0.99")], startDate: nil, endDate: nil)
        let before = try await session.pricingScreen(account: account, appId: app)
        let changes = try await session.pricingChanges(account: account, appId: app)
        let prepared = try await session.preparePublishing(account: account, request: change(account), client: client)
        #expect(apple.writes.isEmpty, "Reading and preparing never writes to Apple")
        let completed = try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client)
        #expect(completed.state == "complete")
        try await observed(changes)
        let after = try await session.pricingScreen(account: account, appId: app)
        #expect(after.countries.first?.price.customerPrice == "4.99")
        #expect(after.drafts == before.drafts && after.protection == before.protection)
        #expect(try await session.pricingReadToken(accountId: account.id, appId: app).needsRefresh == false)
        #expect(apple.writes.count == 1)
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client) }
        #expect(apple.writes.count == 1)
    }

    @Test func lostWriteResponseStillReadsAppliedPricesAndNeverReplaysTheWrite() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = pricedApple(), host = "lost-price-answer.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            let reply = apple.handle(request)
            return request.httpMethod == "POST" ? (-1005, [:], Data()) : reply
        }
        let client = try PricingTests().stubbedClient(host, account)
        let prepared = try await session.preparePublishing(account: account, request: change(account), client: client)
        let stopped = try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client)
        #expect(stopped.state == "failed")
        #expect(try await session.pricingScreen(account: account, appId: app).countries.first?.price.customerPrice == "4.99")
        #expect(apple.writes.count == 1)
    }

    @Test func readbackFailurePreservesSuccessfulPublicationAndLeavesRetryNeeded() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = pricedApple(), host = "readback-failure.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            if request.httpMethod == "GET", apple.lock.withLock({ !apple.writes.isEmpty }) { return (403, [:], Data()) }
            return apple.handle(request)
        }
        let client = try PricingTests().stubbedClient(host, account)
        try await session.refreshCountryPrices(account: account, appId: app, client: client)
        let prepared = try await session.preparePublishing(account: account, request: change(account), client: client)
        let completed = try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client)
        #expect(completed.state == "complete" && apple.writes.count == 1)
        let kept = try await session.pricingScreen(account: account, appId: app)
        #expect(kept.countries.first?.price.customerPrice == "0.99" && kept.saved?.code == "SB-APPLE-ACCESS")
        #expect(try await session.pricingReadToken(accountId: account.id, appId: app).needsRefresh)
    }

    @Test func completeScheduleHasADeadlineAndClosedSessionsRefuseNewReaders() async throws {
        await #expect(throws: PricingScheduleRead.Failure.timeout) {
            try await PricingScheduleRead.run(timeout: .milliseconds(20)) { try await Task.sleep(for: .seconds(60)) }
        }
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), client = try PricingTests().stubbedClient("closed-prices.appstoreconnect.test", account)
        try await session.signOut()
        await #expect(throws: (any Error).self) { try await session.pricingChanges(account: account, appId: app) }
        await #expect(throws: (any Error).self) { try await session.refreshCountryPrices(account: account, appId: app, client: client) }
        #expect(StubProtocol.requests("closed-prices.appstoreconnect.test").isEmpty)
    }
}
