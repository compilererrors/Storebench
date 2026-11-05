import Foundation

public struct PricingCountry: Sendable, Identifiable, Codable {
    public let price: PriceRow, name: String, search: String
    public var id: String { price.id }
}
public struct PricingScreen: Sendable, Codable {
    public let saved: SavedPricing?, protection: [PriceProtection], drafts: [PricingDraft]
    public let countries: [PricingCountry], paidUnits: [String: Int]?
    public static func countries(_ prices: [PriceRow], today: String) -> [PricingCountry] {
        PricingMath.current(prices, today: today).values.map { price in
            let name = Territories.name(price.territory)
            return PricingCountry(price: price, name: name, search: "\(name) \(price.territory) \(price.currency)")
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.compare($1.name, locale: Locale(identifier: "en")) == .orderedAscending }
    }
    var estimatedBytes: Int { (saved?.snapshot?.rows.count ?? 0) * 1024 + drafts.count * 1024 + protection.count * 512 + countries.count * 512 + (paidUnits?.count ?? 0) * 128 }
}

extension WorkspaceSession {
    /// All parsing and aggregation runs on the storage actor. Cache never substitutes for write revisions.
    public func pricingScreen(account: Account, appId: String, today: String = PeriodDates.text(Date())) throws -> PricingScreen {
        try salesFileScope(account, appId: appId); try Task.checkCancellation()
        let stamp = try storeAccess { try $0.changeStamp() }
        let key = JSONText.array([.string(account.id), .string(appId), .string(today)]).stringify()
        if let cached = pricingCaches.screen(key, stamp: stamp) { return cached }
        let saved = try savedPricing(accountId: account.id, appId: appId)
        let protection = try priceProtection(accountId: account.id, appId: appId)
        let drafts = try pricingDrafts(accountId: account.id, appId: appId)
        // Report failure remains unknown; it must not prevent reading saved prices.
        let analysis = (try? salesPresentation(account: account, appId: appId)).flatMap { try? SalesPresentation.analyze($0) }
        let complete = analysis.map { $0.coverage?.hasGaps == false && $0.productsComplete && $0.coverage?.periods.allSatisfy(\.detailsComplete) == true } ?? false
        let units = complete ? Dictionary(uniqueKeysWithValues: (analysis?.rows ?? []).map { ($0.code, $0.paid) }) : nil
        let value = PricingScreen(saved: saved, protection: protection, drafts: drafts, countries: PricingScreen.countries(saved?.snapshot?.rows ?? [], today: today), paidUnits: units)
        try Task.checkCancellation(); try salesFileScope(account, appId: appId)
        guard try storeAccess({ try $0.changeStamp() }) == stamp else { throw PricingFailure.read }
        pricingCaches.rememberScreen(value, key: key)
        return value
    }
}
