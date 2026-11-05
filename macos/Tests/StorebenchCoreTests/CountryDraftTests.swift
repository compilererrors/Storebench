import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct CountryDraftTests {
    init() throws { _ = try TestIsolation.require() }

    let app = "1000000001", today = "2026-03-01"
    let basis = [
        PriceRow(id: "price-swe", territory: "SWE", currency: "SEK", customerPrice: "55", proceeds: "33.6", startDate: nil, endDate: nil, source: "automatic"),
        PriceRow(id: "price-usa", territory: "USA", currency: "USD", customerPrice: "4.99", proceeds: "3.49", startDate: nil, endDate: nil, source: "manual"),
        PriceRow(id: "price-gbr", territory: "GBR", currency: "GBP", customerPrice: "4.49", proceeds: "3.14", startDate: nil, endDate: "2026-03-31", source: "manual"),
        PriceRow(id: "price-gbr-later", territory: "GBR", currency: "GBP", customerPrice: "3.99", proceeds: "2.79", startDate: "2026-04-01", endDate: nil, source: "manual"),
    ]

    func pointsPage(status: Int = 200) -> (Int, [String: String], Data) {
        let points = [("a", "45"), ("b", "49")].map { ["type": "appPricePoints", "id": $0.0, "attributes": ["customerPrice": $0.1], "relationships": ["territory": ["data": ["type": "territories", "id": "SWE"]]]] as [String: Any] }
        return (status, [:], try! JSONSerialization.data(withJSONObject: ["data": status == 200 ? points : [], "included": [], "links": [:]]))
    }

    @Test func planChecksTheReviewedPricesAndRoundsToApplePoints() throws {
        let plan = CountryDraftPlan(basis: basis, today: today)
        #expect(throws: PricingFailure.selection) { try plan.check(CountryDraftRequest(territories: ["NOR"], change: .exact("9"), period: nil)) }
        #expect(throws: PricingFailure.scheduled) { try plan.check(CountryDraftRequest(territories: ["GBR"], change: .exact("3.49"), period: .init(start: "2026-04-05", end: "2026-04-10"))) }
        #expect(plan.needsPricePoints(CountryDraftRequest(territories: ["SWE"], change: .percent("85", rounding: "nearest"), period: nil)))
        #expect(!plan.needsPricePoints(CountryDraftRequest(territories: ["SWE"], change: .percent("85", rounding: "exact"), period: nil)))
        #expect(!plan.needsPricePoints(CountryDraftRequest(territories: ["USA"], change: .exact("3.99"), period: nil)))
        #expect(try plan.amounts(CountryDraftRequest(territories: ["USA"], change: .exact("3.990"), period: nil), points: []).map(\.amount) == ["3.99"])
        let points = [PricePoint(id: "a", territory: "SWE", customerPrice: "45"), PricePoint(id: "b", territory: "SWE", customerPrice: "49")]
        let rounded = try plan.amounts(CountryDraftRequest(territories: ["SWE"], change: .percent("85", rounding: "nearest"), period: nil), points: points)
        #expect(rounded.map(\.territory) == ["SWE"] && rounded.map(\.currency) == ["SEK"] && rounded.map(\.amount) == ["45"])
    }

    @Test func serviceReadsPricePointsAndRefusesUnansweredBatches() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        for (host, status) in [("drafts-points.appstoreconnect.test", 200), ("drafts-points-failed.appstoreconnect.test", 500)] {
            StubProtocol.handle(host) { request in
                guard request.url!.path == "/v1/apps/1000000001/appPricePoints" else { Issue.record("Unexpected \(request.url!.path)"); return (404, [:], Data()) }
                return pointsPage(status: status)
            }
            let client = try PricingTests().stubbedClient(host, account)
            let service = PricingService(store: session, account: account, appId: app) { _ in client }
            let request = CountryDraftRequest(territories: ["SWE"], change: .percent("85", rounding: "nearest"), period: nil)
            if status == 200 {
                #expect(try await service.saveDrafts(request, basis: basis, today: today).map(\.amount) == ["45"])
                #expect(StubProtocol.requests(host).count == 1)
            } else {
                // The client retries a server error before the batch counts as unanswered.
                await #expect(throws: PricingFailure.points) { try await service.saveDrafts(request, basis: basis, today: today) }
                #expect(!StubProtocol.requests(host).isEmpty)
            }
        }
        #expect(try await session.pricingDrafts(accountId: account.id, appId: app).map(\.amount) == ["45"])
    }

    @Test func protectedPricesAreRefusedWithoutWritingDrafts() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let service = PricingService(store: session, account: account, appId: app) { _ in Issue.record("Exact drafts read no price points."); throw PricingFailure.points }
        try await session.protectPrices(accountId: account.id, appId: app, prices: [("USA", "4.99", "USD")])
        await #expect(throws: PricingFailure.selection) {
            try await service.saveDrafts(CountryDraftRequest(territories: ["SWE", "USA"], change: .exact("3.99"), period: nil), basis: basis, today: today)
        }
        #expect(try await session.pricingDrafts(accountId: account.id, appId: app).isEmpty)
    }

    @Test func concurrentSessionsKeepEveryDraftAndThePermanentMutex() async throws {
        let (first, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await first.accounts().first)
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await first.vault)
        func save(_ session: WorkspaceSession, _ territory: String, _ amount: String) async throws -> [PricingDraft] {
            try await PricingService(store: session, account: account, appId: app) { _ in throw PricingFailure.points }
                .saveDrafts(CountryDraftRequest(territories: [territory], change: .exact(amount), period: nil), basis: basis, today: today)
        }
        _ = try await save(first, "SWE", "49")
        let mutex = root.appendingPathComponent("state-v2/pricing_drafts.mutex"), before = try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber
        for round in 1...5 {
            async let a = save(first, "SWE", "4\(round)"), b = save(second, "USA", "3.\(round)9")
            _ = try await (a, b)
            let saved = try await second.pricingDrafts(accountId: account.id, appId: app)
            #expect(Set(saved.map { "\($0.territory) \($0.amount)" }) == ["SWE 4\(round)", "USA 3.\(round)9"])
        }
        let after = try FileManager.default.attributesOfItem(atPath: mutex.path)
        #expect(before != nil && after[.systemFileNumber] as? NSNumber == before && after[.size] as? NSNumber == 0)
    }

    @Test func closedSessionsRefuseDraftsAndKeepNothing() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), vault = await session.vault
        try await session.signOut()
        await #expect(throws: SessionFailure.closed) {
            try await PricingService(store: session, account: account, appId: app) { _ in throw PricingFailure.points }
                .saveDrafts(CountryDraftRequest(territories: ["USA"], change: .exact("3.99"), period: nil), basis: basis, today: today)
        }
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: vault)
        #expect(try await reopened.pricingDrafts(accountId: account.id, appId: app).isEmpty)
    }

    @Test func refreshTurnsAppleRefusalIntoPricingAccess() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "drafts-refused.appstoreconnect.test"
        StubProtocol.handle(host) { _ in (403, [:], Data("{}".utf8)) }
        let client = try PricingTests().stubbedClient(host, account)
        await #expect(throws: PricingFailure.access) { try await PricingService(store: session, account: account, appId: app) { _ in client }.refresh() }
    }

    @Test func protectionSavedWhilePricePointsAreReadRefusesTheDrafts() async throws {
        let (first, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await first.accounts().first), host = "drafts-protected-meanwhile.appstoreconnect.test"
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await first.vault)
        // Another session protects the country while Apple's answer is still on its way.
        StubProtocol.handle(host) { _ in
            let protected = DispatchSemaphore(value: 0)
            Task { try? await second.protectPrices(accountId: account.id, appId: "1000000001", prices: [("SWE", "55", "SEK")]); protected.signal() }
            _ = protected.wait(timeout: .now() + 10)
            return pointsPage()
        }
        let client = try PricingTests().stubbedClient(host, account)
        let service = PricingService(store: first, account: account, appId: app) { _ in client }
        await #expect(throws: PricingFailure.selection) {
            try await service.saveDrafts(CountryDraftRequest(territories: ["SWE"], change: .percent("85", rounding: "nearest"), period: nil), basis: basis, today: today)
        }
        #expect(try await first.priceProtection(accountId: account.id, appId: app).map(\.territory) == ["SWE"])
        #expect(try await first.pricingDrafts(accountId: account.id, appId: app).isEmpty)
    }

    @Test func cancellingWhilePricePointsAreReadStaysCancellation() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "drafts-cancelled.appstoreconnect.test"
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        StubProtocol.handle(host) { _ in started.signal(); _ = release.wait(timeout: .now() + 10); return pointsPage() }
        let client = try PricingTests().stubbedClient(host, account), basis = basis, today = today
        let service = PricingService(store: session, account: account, appId: app) { _ in client }
        let saving = Task { try await service.saveDrafts(CountryDraftRequest(territories: ["SWE"], change: .percent("85", rounding: "nearest"), period: nil), basis: basis, today: today) }
        await withCheckedContinuation { (reading: CheckedContinuation<Void, Never>) in DispatchQueue.global().async { _ = started.wait(timeout: .now() + 10); reading.resume() } }
        saving.cancel(); release.signal()
        guard case .failure(let error) = await saving.result else { Issue.record("A cancelled save must not save drafts."); return }
        #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        #expect(try await session.pricingDrafts(accountId: account.id, appId: app).isEmpty)
    }
}
