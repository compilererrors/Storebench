import Foundation

/// Pricing's in-memory reads for one open session. The session keeps one value on its actor and replaces it when it closes;
/// only Pricing reads or changes it. A cached read never substitutes for a write revision.
struct PricingCaches {
    private var territories: [String: (expires: Date, value: [Territory])] = [:]
    private var screenStamp: String?
    private var screens = BoundedMemoryCache<String, PricingScreen>(CachePolicy.standardBudget.pricingScreens)

    mutating func resize(_ limit: CachePolicy.Limit) { screens.resize(limit) }
    var retainedBytes: Int { screens.cost }
    /// Frees remembered screens; territories are small and stay.
    mutating func trim() { screens.removeAll() }

    /// Apple's territories for an account, kept for one day.
    func territories(account: String, now: Date) -> [Territory]? {
        territories[account].flatMap { $0.expires > now ? $0.value : nil }
    }

    mutating func rememberTerritories(_ value: [Territory], account: String, now: Date) {
        territories[account] = (now.addingTimeInterval(86_400), value)
    }

    /// A pricing screen read at this store change stamp; any other stamp drops every remembered screen.
    mutating func screen(_ key: String, stamp: String) -> PricingScreen? {
        if stamp != screenStamp { screens.removeAll(); screenStamp = stamp }
        return screens.value(for: key)
    }

    mutating func rememberScreen(_ value: PricingScreen, key: String) {
        screens.insert(value, for: key, cost: value.estimatedBytes)
    }
}
