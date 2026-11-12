import Foundation

/// The pricing reads screens make, with the account's shared read client. A read that a refresh elsewhere cancelled is read again.
/// Prepared requests read with an uncached client, as publishing requires. Nothing here changes App Store Connect.
extension WorkspaceSession {
    private func sharedRead<T>(_ account: Account, _ read: (AppStoreConnectClient) async throws -> T) async throws -> T {
        let client = try readClient(for: account)
        return try await AppStoreReadCache.rereadingAfterInvalidation { try await read(client) }
    }

    /// Apple's territories with their currencies.
    public func territories(account: Account) async throws -> [Territory] {
        try await sharedRead(account) { try await territories(account: account, client: $0) }
    }
    /// Apple's app price levels in one country or region.
    public func appPriceLevels(account: Account, appId: String, territory: String) async throws -> [ProductPricePoint] {
        try await sharedRead(account) { try await appPriceLevels(account: account, appId: appId, territory: territory, client: $0) }
    }
    /// Apple's price points for an in-app purchase or subscription in one country or region.
    public func productPricePoints(product: PriceProduct, territory: String, account: Account) async throws -> [ProductPricePoint] {
        try await sharedRead(account) { try await productPricePoints(product: product, territory: territory, client: $0) }
    }
    /// Apple's comparable prices in the other countries and regions for one subscription price point.
    public func comparableSubscriptionPrices(pricePointId: String, account: Account) async throws -> [ProductPricePoint] {
        try await sharedRead(account) { try await comparableSubscriptionPrices(pricePointId: pricePointId, client: $0) }
    }
    /// Typed prices, each rounded to the nearest of the owner's own Apple price points.
    public func manualPrices(_ owner: PriceOwner, amounts: [String: String], countries: [Territory], account: Account, progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> (rows: [ModelPrice], warnings: [String], points: [String: String]) {
        try await sharedRead(account) { try await manualPrices(owner, amounts: amounts, countries: countries, client: $0, progress: progress) }
    }
    /// A model's prices for the owner, rounded to its own Apple price points.
    public func modelPrices(_ owner: PriceOwner, profile: PricingProfile, base: String, countries: [Territory], guideCurrency: String, account: Account, progress: @escaping @Sendable (String) async -> Void = { _ in },
                            estimated: @escaping @Sendable ([ModelPrice]) async -> Void = { _ in }) async throws -> (rows: [ModelPrice], warnings: [String], points: [String: String]) {
        try await sharedRead(account) { try await modelPrices(owner, profile: profile, base: base, countries: countries, guideCurrency: guideCurrency, client: $0, progress: progress, estimated: estimated) }
    }
    /// The first price of a purchase created in an earlier review, read without the shared cache.
    public func firstPurchasePriceRequest(account: Account, appId: String, productId: String, territory: String, amount: String) async throws -> PublishRequest? {
        try await firstPurchasePriceRequest(account: account, appId: appId, productId: productId, territory: territory, amount: amount, client: client(for: account))
    }
}
