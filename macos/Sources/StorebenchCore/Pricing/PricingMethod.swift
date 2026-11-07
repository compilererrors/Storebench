import Foundation

/// How a guide price becomes the price in each country or region. Profiles, every Price Strategy, the No-sales guide and the
/// calculations read their methods, names, explanations and data needs from here, so a method means the same thing everywhere.
/// Profiles store the raw value.
public enum PricingMethod: String, CaseIterable, Sendable, Identifiable {
    case ppp, bigmac, fx, same, custom, own
    public var id: String { rawValue }

    /// The methods that work from a guide price alone, in the order price forms offer them. Your country percentages and Your own
    /// index also need values per country, so only a saved profile uses them.
    public static let builtIn: [PricingMethod] = [.ppp, .bigmac, .fx, .same]

    public var name: String {
        switch self {
        case .ppp: "World Bank purchasing power (PPP)"
        case .bigmac: "Big Mac Index"
        case .fx: "Currency conversion"
        case .same: "Same for all"
        case .custom: "Your country percentages"
        case .own: "Your own index"
        }
    }

    /// What the method does with the guide price, in one plain sentence.
    public var explanation: String {
        switch self {
        case .ppp: "Scales the guide price by the World Bank's purchasing power data, so countries with lower price levels pay less."
        case .bigmac: "Scales the guide price by the local price of a Big Mac from The Economist's Big Mac Index, so prices follow what things cost locally."
        case .fx: "Converts the guide price with current exchange rates, so the price is about the same everywhere in your own currency."
        case .same: "Uses the same number in every currency, without converting it, such as 4.99 everywhere."
        case .custom: "Converts the guide price with current exchange rates, then scales each country by the percentage you set for it in the profile."
        case .own: "Scales the guide price by a value you import for each country in its own currency, such as the local price of a product everyone buys."
        }
    }

    /// Needs current exchange rates from the guide currency.
    public var usesExchangeRates: Bool { self == .fx || self == .custom }
    /// Needs a published price-level index that Storebench downloads: World Bank purchasing power or the Big Mac Index.
    public var usesIndex: Bool { self == .ppp || self == .bigmac }
    /// Scales by the ratio of a country's index value to the guide country's: a published index or your own.
    public var scalesByIndex: Bool { usesIndex || self == .own }
    /// Prices only the guide country and the countries given a percentage.
    public var usesCountryPercentages: Bool { self == .custom }
    /// Can be one of the two methods in a mix. Same for all keeps one number in every currency, and Your country percentages is
    /// already Currency conversion with percentages, so neither mixes.
    public var mixes: Bool { self != .same && self != .custom }
    /// Same for all keeps the typed number, so only an exact Apple price fits.
    public var exactOnly: Bool { self == .same }
    /// The rounding the method really uses for a chosen rounding.
    public func rounding(_ chosen: String) -> String { exactOnly ? PricingRounding.exact.rawValue : chosen }

    /// The method's name for a stored key, or the key itself when it is not a known method.
    public static func name(_ key: String) -> String { PricingMethod(rawValue: key)?.name ?? key }
}

/// How a calculated price is matched to one of Apple's price points. Profiles store the raw value.
public enum PricingRounding: String, CaseIterable, Sendable, Identifiable {
    case nearest, up, down, exact
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .nearest: "Nearest Apple price"
        case .up: "Round up"
        case .down: "Round down"
        case .exact: "Exact amount only"
        }
    }
}

/// The price strategies that are not a pricing method: Apple's own comparable prices and typed prices.
public enum PricingStrategyText {
    public static let appleName = "Apple's comparable prices"
    public static let appleExplanation = "Apple sets every other country's price from the one price you choose in the Base Country or Region, with exchange rates and local taxes, and keeps them updated."
    public static let manualName = "Enter Prices Manually"
    public static let manualExplanation = "You type the price for each country or region in its own currency. Each is rounded to the nearest Apple price there."
}
