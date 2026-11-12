import Foundation

/// The saved pricing state Pricing reads and writes in an open workspace. `WorkspaceSession` provides it on its single
/// database connection, under its lifetime and access checks and the pricing locks.
protocol PricingStore: Sendable {
    func pricingScreen(account: Account, appId: String, today: String) async throws -> PricingScreen
    func refreshPricing(account: Account, appId: String, client: AppStoreConnectClient, now: Date) async throws -> PricingSnapshot
    func refreshCountryPrices(account: Account, appId: String, client: AppStoreConnectClient, force: Bool, now: Date) async throws
    func protectPrices(accountId: String, appId: String, prices: [(territory: String, customerPrice: String, currency: String)], now: Date) async throws
    func unprotectPrice(accountId: String, appId: String, territory: String) async throws
    func removePricingDraft(accountId: String, appId: String, id: String) async throws
    func saveCountryDrafts(accountId: String, appId: String, amounts: [(territory: String, currency: String, amount: String)], startDate: String?, endDate: String?, now: Date) async throws -> [PricingDraft]
}

extension WorkspaceSession: PricingStore {}

extension PricingStore {
    func refreshCountryPrices(account: Account, appId: String, client: AppStoreConnectClient, force: Bool, now: Date) async throws {
        _ = try await refreshPricing(account: account, appId: appId, client: client, now: now)
    }
}
