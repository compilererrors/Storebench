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
        let (path, type) = try endpoint(owner)
        return try await list("\(path)?filter%5Bterritory%5D=\(codes.joined(separator: "%2C"))&include=territory&fields%5B\(type)%5D=customerPrice%2Cterritory&limit=200").compactMap { point($0, type: type, codes: codes) }
    }

    /// One country's or region's price points, page by page. With `through`, reading stops once Apple's pages, checked to rise in
    /// price, reach that amount: every price point below it and the first one at or above it are read, so nearest, up and down
    /// rounding choose exactly as from the complete list. Pages that do not rise are read to the end.
    static func ladder(_ owner: Owner, territory: String, through need: Decimal?,
                       page: (String, String?) async throws -> (resources: [AppStoreConnectClient.Resource], next: String?)) async throws -> (points: [PricePoint], complete: Bool) {
        guard territory.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { throw PricingFailure.invalid("Invalid territory selection.") }
        let (path, type) = try endpoint(owner)
        let first = "\(path)?filter%5Bterritory%5D=\(territory)&include=territory&fields%5B\(type)%5D=customerPrice%2Cterritory&limit=200"
        var points: [PricePoint] = [], rising = true, previous: Decimal?, cursor: String?, pages = 0
        while true {
            pages += 1
            guard pages <= 60 else { throw PricingFailure.invalid("Apple returned too many price point pages.") }
            guard var components = URLComponents(string: first) else { throw PricingFailure.invalid("Invalid territory selection.") }
            if let cursor { let items = components.queryItems ?? []; components.queryItems = items + [URLQueryItem(name: "cursor", value: cursor)] }
            guard let current = components.string else { throw PricingFailure.invalid("Invalid territory selection.") }
            let read = try await page(current, cursor)
            for resource in read.resources {
                guard let point = Self.point(resource, type: type, codes: [territory]) else { continue }
                if let amount = PricingMath.decimal(point.customerPrice) {
                    if let previous, amount < previous { rising = false }
                    previous = amount
                }
                points.append(point)
            }
            guard let next = read.next else { return (points, true) }
            if rising, let need, let highest = previous, highest >= need { return (points, false) }
            cursor = next
        }
    }

    static func endpoint(_ owner: Owner) throws -> (path: String, type: String) {
        switch owner {
        case .app(let id): return ("/v1/apps/\(id)/appPricePoints", "appPricePoints")
        case .subscription(let id):
            guard ProductPricing.opaque(id) else { throw PricingFailure.invalid("Invalid subscription.") }
            return ("/v1/subscriptions/\(id)/pricePoints", "subscriptionPricePoints")
        case .purchase(let id):
            guard ProductPricing.opaque(id) else { throw PricingFailure.invalid("Invalid in-app purchase.") }
            return ("/v2/inAppPurchases/\(id)/pricePoints", "inAppPurchasePricePoints")
        }
    }

    static func point(_ resource: AppStoreConnectClient.Resource, type: String, codes: [String]) -> PricePoint? {
        guard resource.type == type, let territory = WorkspaceSession.linked(resource, "territory"), codes.contains(territory) else { return nil }
        switch resource.attributes?["customerPrice"] {
        case .string(let price)?: return PricePoint(id: resource.id, territory: territory, customerPrice: price)
        case .number(let price)?: return PricePoint(id: resource.id, territory: territory, customerPrice: JSONText.number(price))
        default: return nil
        }
    }

    /// Each country's or region's price points up to the amount it needs, six countries at a time under the shared Apple queue.
    /// `completed` receives every finished country with whether its list is complete; a country Apple did not answer is reported
    /// as failed, never filled in. Cancellation stops the read and is thrown as cancellation.
    static func readNeeded(_ owner: Owner, needs: [String: Decimal?], client: AppStoreConnectClient,
                           completed: @escaping @Sendable (_ territory: String, _ points: [PricePoint], _ complete: Bool, _ failed: Bool) async throws -> Void) async throws {
        let codes = needs.keys.sorted()
        guard codes.allSatisfy({ $0.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil }) else { throw PricingFailure.invalid("Invalid territory selection.") }
        try await withThrowingTaskGroup(of: (String, [PricePoint], Bool, Bool).self) { group in
            func add(_ code: String) {
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let read = try await ladder(owner, territory: code, through: needs[code] ?? nil, page: { try await client.page($0, currentCursor: $1) })
                        return (code, read.points, read.complete, false)
                    } catch {
                        try Task.checkCancellation()
                        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                        return (code, [], false, true)
                    }
                }
            }
            var next = 0
            for _ in 0..<min(6, codes.count) { add(codes[next]); next += 1 }
            for try await (code, points, complete, failed) in group {
                try Task.checkCancellation()
                try await completed(code, points, complete, failed)
                if next < codes.count { add(codes[next]); next += 1 }
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
