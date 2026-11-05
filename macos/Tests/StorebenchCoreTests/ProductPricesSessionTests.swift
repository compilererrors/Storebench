import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ProductPricesSessionTests {
    init() throws { _ = try TestIsolation.require() }
    private enum Failure: Error { case synthetic }
    private final class ReadGate: @unchecked Sendable {
        private let lock = NSLock(), released = DispatchSemaphore(value: 0)
        private var entered = false
        func hold() { lock.withLock { entered = true }; _ = released.wait(timeout: .now() + 10) }
        func release() { released.signal() }
        func wait() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !lock.withLock({ entered }) { guard ContinuousClock.now < deadline else { throw Failure.synthetic }; try await Task.sleep(for: .milliseconds(10)) }
        }
    }
    @Test func familyScopedScheduleReadsResolveAnEqualResourceIdWithoutAmbiguityAndNeverWrite() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "product-family-scope.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { request in
            if request.url?.path == "/v1/subscriptionGroups/sg-1/subscriptions" {
                return apple.page([["type": "subscriptions", "id": "iap-1", "attributes": ["productId": "example.synthetic.monthly", "name": "Synthetic monthly", "state": "APPROVED", "subscriptionPeriod": "ONE_MONTH"], "relationships": ["group": ["data": ["type": "subscriptionGroups", "id": "sg-1"]]]]])
            }
            if request.url?.path == "/v1/subscriptions/iap-1/prices" { return apple.page([]) }
            return apple.handle(request)
        }
        let client = try PublishingTests().client(account, host: host)
        await #expect(throws: PublishFailure.self) { try await session.productPriceSchedule(appId: app, productId: "iap-1", client: client) }
        let purchase = try await session.productPriceSchedule(appId: app, productId: "iap-1", kind: .purchase, client: client)
        let subscription = try await session.productPriceSchedule(appId: app, productId: "iap-1", kind: .subscription, client: client)
        #expect(purchase.product.kind == .purchase && subscription.product.kind == .subscription)
        let material = try await session.scopedProductPriceMaterial(account: account, appId: app, selected: purchase.product, client: client)
        #expect(material.scope.accountId == account.id && material.scope.appId == app && material.activeTerritories?.contains("USA") == true)
        let points = try await session.scopedProductPricePoints(account: account, appId: app, selected: purchase.product, territory: "USA", client: client)
        #expect(!points.isEmpty && points.allSatisfy { $0.territory == "USA" })
        await #expect(throws: PublishFailure.self) { try await session.scopedProductPricePoints(account: account, appId: app, selected: subscription.product, territory: "USA", client: client) }
        await #expect(throws: PublishFailure.self) { try await session.scopedPriceProducts(account: account, appId: "1000000099", client: client) }
        #expect(apple.writes.isEmpty)
        #expect(try await session.storeAccess { try $0.documents(namespace: "publish_reviews").isEmpty })
    }
    @Test func changedAccountAfterAReadStartsCannotReturnTheOldProductCatalog() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "product-account-change.appstoreconnect.test", gate = ReadGate()
        StubProtocol.handle(host) { request in
            if request.url?.path == "/v1/apps/1000000001/inAppPurchasesV2" { gate.hold() }
            return apple.handle(request)
        }
        let client = try PublishingTests().client(account, host: host)
        let task = Task { try await session.scopedPriceProducts(account: account, appId: "1000000001", client: client) }
        try await gate.wait(); defer { gate.release() }
        try await session.storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("accounts.mutex")) {
                try store.transaction { current in
                    let existing = try current("accounts", "all")
                    _ = try #require(existing)
                    return [.put(namespace: "accounts", key: "all", json: JSONText.array([]).data)]
                }
            }
        }
        gate.release()
        await #expect(throws: PublishFailure.self) { try await task.value }
        #expect(apple.writes.isEmpty)
    }
}
