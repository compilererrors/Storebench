import Foundation

/// Whose Apple prices are set: the app's, one subscription's or one in-app purchase's. Every price strategy works the same way for each.
public enum PriceOwner: Sendable, Equatable { case app(String), subscription(String), purchase(String) }

/// Apple's price points for an app or one subscription, read in Apple's batches of up to 25 territories. A batch Apple did not answer is
/// reported, never filled in.
enum PricePointCatalog {
    static let batchSize = 25
    typealias Owner = PriceOwner

    /// One batch of up to 25 territories.
    static func read(appId: String, territories: [String], client: AppStoreConnectClient) async throws -> [PricePoint] {
        try await read(.app(appId), territories: territories, list: { try await client.list($0) })
    }
    static func read(_ owner: Owner, territories: [String], list: (String) async throws -> [AppStoreConnectClient.Resource]) async throws -> [PricePoint] {
        let codes = Array(Set(territories)).sorted()
        guard !codes.isEmpty else { return [] }
        guard codes.count <= batchSize, codes.allSatisfy({ $0.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil }) else { throw PricingFailure.invalid("Invalid territory selection.") }
        let (path, type): (String, String)
        switch owner {
        case .app(let id): (path, type) = ("/v1/apps/\(id)/appPricePoints", "appPricePoints")
        case .subscription(let id):
            guard ProductPricing.opaque(id) else { throw PricingFailure.invalid("Invalid subscription.") }
            (path, type) = ("/v1/subscriptions/\(id)/pricePoints", "subscriptionPricePoints")
        case .purchase(let id):
            guard ProductPricing.opaque(id) else { throw PricingFailure.invalid("Invalid in-app purchase.") }
            (path, type) = ("/v2/inAppPurchases/\(id)/pricePoints", "inAppPurchasePricePoints")
        }
        return try await list("\(path)?filter%5Bterritory%5D=\(codes.joined(separator: "%2C"))&limit=200").compactMap { point in
            guard point.type == type, let territory = WorkspaceSession.linked(point, "territory"), codes.contains(territory) else { return nil }
            switch point.attributes?["customerPrice"] {
            case .string(let price)?: return PricePoint(id: point.id, territory: territory, customerPrice: price)
            case .number(let price)?: return PricePoint(id: point.id, territory: territory, customerPrice: JSONText.number(price))
            default: return nil
            }
        }
    }

    /// Any number of territories in batches; the territories of each failed batch are returned for the caller to refuse or report.
    /// Cancellation stops the read and is thrown as cancellation.
    static func readAll(appId: String, territories: [String], client: AppStoreConnectClient) async throws -> (points: [PricePoint], failed: Set<String>) {
        try await readAll(.app(appId), territories: territories, client: client)
    }
    static func readAll(_ owner: Owner, territories: [String], client: AppStoreConnectClient) async throws -> (points: [PricePoint], failed: Set<String>) {
        var points: [PricePoint] = [], failed = Set<String>()
        for start in stride(from: 0, to: territories.count, by: batchSize) {
            let batch = Array(territories[start..<min(start + batchSize, territories.count)])
            do { points += try await read(owner, territories: batch, list: { try await client.list($0) }) }
            catch let error as CancellationError { throw error }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch { failed.formUnion(batch) }
            try Task.checkCancellation()
        }
        return (points, failed)
    }
}
