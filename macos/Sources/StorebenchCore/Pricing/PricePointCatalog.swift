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
        return try await list("\(path)?filter%5Bterritory%5D=\(codes.joined(separator: "%2C"))&include=territory&fields%5B\(type)%5D=customerPrice%2Cterritory&limit=200").compactMap { point in
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
    static func readAll(_ owner: Owner, territories: [String], client: AppStoreConnectClient,
                        progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
                        completed: @escaping @Sendable ([PricePoint], Set<String>) async throws -> Void = { _, _ in }) async throws -> (points: [PricePoint], failed: Set<String>) {
        let codes = Array(Set(territories)).sorted()
        let batches = stride(from: 0, to: codes.count, by: batchSize).map { Array(codes[$0..<min($0 + batchSize, codes.count)]) }
        return try await withThrowingTaskGroup(of: (Int, [PricePoint], Set<String>).self) { group in
            func add(_ index: Int) {
                group.addTask {
                    try Task.checkCancellation()
                    let batch = batches[index]
                    do {
                        let points = try await read(owner, territories: batch, list: { try await client.list($0) })
                        return (index, points, [])
                    } catch {
                        try Task.checkCancellation()
                        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                        return (index, [], Set(batch))
                    }
                }
            }
            var next = 0, finished = 0, results: [Int: [PricePoint]] = [:], failed = Set<String>()
            // The shared Apple admission queue still governs all requests; at most three batches are active here.
            for _ in 0..<min(3, batches.count) { add(next); next += 1 }
            for try await (index, points, missing) in group {
                try Task.checkCancellation()
                results[index] = points; failed.formUnion(missing); finished += batches[index].count
                try await completed(points, missing)
                await progress(finished, codes.count)
                if next < batches.count { add(next); next += 1 }
            }
            return (batches.indices.flatMap { results[$0] ?? [] }, failed)
        }
    }
}
