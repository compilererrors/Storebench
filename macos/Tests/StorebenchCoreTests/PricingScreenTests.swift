import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct PricingScreenTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func memoryIsBoundedByCountAndBytesAndRecentlyReadEntriesSurvive() {
        var cache = BoundedMemoryCache<String, String>(capacity: 2, byteLimit: 10)
        cache.insert("one", for: "a", cost: 4); cache.insert("two", for: "b", cost: 4)
        #expect(cache.value(for: "a") == "one")
        cache.insert("three", for: "c", cost: 4)
        #expect(cache.value(for: "b") == nil && cache.cost == 8 && cache.count == 2)
        cache.insert("replacement", for: "a", cost: 11)
        #expect(cache.value(for: "a") == nil && cache.cost == 4)
        cache.removeAll(); #expect(cache.cost == 0 && cache.count == 0)
    }
    @Test func cacheRevalidatesSameProcessWritesOtherConnectionsDeletionAndClosedAccess() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), appId = "1000000001"
        let price = PriceRow(id: "synthetic-price", territory: "USA", currency: "USD", customerPrice: "3.99", proceeds: "2.00", startDate: nil, endDate: nil, source: "manual")
        let snapshot = PricingSnapshot(baseTerritory: "USA", baseCurrency: "USD", fetchedAt: "2026-01-02T00:00:00.000Z", rows: [price])
        try await session.savePricing(accountId: account.id, appId: appId, checkedAt: snapshot.fetchedAt, snapshot: snapshot, code: nil)
        for _ in 0..<20 { #expect(try await session.pricingScreen(account: account, appId: appId).countries.first?.price.customerPrice == "3.99") }
        let other = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let document = try #require(try other.document(namespace: "apple_prices", key: account.id + ":" + appId))
        let replacement = Data(String(decoding: document.payload, as: UTF8.self).replacingOccurrences(of: "3.99", with: "7.99").utf8)
        try other.transaction { _ in [.put(namespace: "apple_prices", key: account.id + ":" + appId, json: replacement)] }
        #expect(try await session.pricingScreen(account: account, appId: appId).countries.first?.price.customerPrice == "7.99")
        try other.transaction { _ in [.delete(namespace: "apple_prices", key: account.id + ":" + appId)] }
        #expect(try await session.pricingScreen(account: account, appId: appId).saved == nil)
        try await session.savePricing(accountId: account.id, appId: appId, checkedAt: snapshot.fetchedAt, snapshot: snapshot, code: nil)
        #expect(try await session.pricingScreen(account: account, appId: appId).countries.count == 1)
        #expect(try await session.pricingScreen(account: account, appId: appId).paidUnits == nil)
        await #expect(throws: (any Error).self) { try await session.pricingScreen(account: account, appId: "1000000999") }
        try await session.signOut()
        await #expect(throws: (any Error).self) { try await session.pricingScreen(account: account, appId: appId) }
    }
    @Test func scheduledPricesAreResolvedOnceWithDeterministicCountrySorting() {
        let rows = [
            PriceRow(id: "future", territory: "USA", currency: "USD", customerPrice: "9.99", proceeds: "7", startDate: "2026-02-01", endDate: nil, source: "manual"),
            PriceRow(id: "current", territory: "USA", currency: "USD", customerPrice: "3.99", proceeds: "2", startDate: nil, endDate: "2026-02-01", source: "manual")
        ]
        #expect(PricingScreen.countries(rows, today: "2026-01-20").map(\.id) == ["current"])
        #expect(PricingScreen.countries(rows, today: "2026-02-02").map(\.id) == ["future"])
    }
}
