import Foundation

/// Keeps incomplete editor text until an explicit save or preview validates it.
public struct PricingProfileInputs: Equatable, Sendable {
    /// The mix the recipe really uses: none when the method cannot blend, or when the mix names the method itself.
    public var effectiveMixMethod: String {
        guard let main = PricingMethod(rawValue: method), main.mixes, let mixed = PricingMethod(rawValue: mixMethod), mixed.mixes, mixed != main else { return "" }
        return mixMethod
    }
    /// Changes the method and drops a mix the new method cannot use, so no hidden mix stays behind and blocks saving.
    public mutating func choose(method next: String) {
        method = next
        if effectiveMixMethod.isEmpty { mixMethod = "" }
    }

    public struct Override: Equatable, Sendable, Identifiable {
        public let id: String
        public var territory, percentage: String
        public init(id: String = UUID().uuidString, territory: String = "", percentage: String = "100") {
            self.id = id; self.territory = territory; self.percentage = percentage
        }
        public static func == (lhs: Self, rhs: Self) -> Bool {
            TextSemantics.same(lhs.territory, rhs.territory) && TextSemantics.same(lhs.percentage, rhs.percentage)
        }
    }
    public let id: String
    public var name, guideTerritory, method, rounding: String
    public var overrides: [Override]
    /// The mixed-in method, or empty for none, and its share in percent.
    public var mixMethod, mixShare: String
    /// The lowest and highest price in percent of the converted guide price; empty for none.
    public var floor, ceiling: String
    /// Your own index values, one row per country; `percentage` holds the value.
    public var indexRows: [Override]
    public init(_ profile: PricingProfile) {
        id = profile.id; name = profile.name; guideTerritory = profile.guideTerritory
        method = profile.method; rounding = profile.rounding
        overrides = profile.percentages.sorted { $0.key < $1.key }.map { Override(id: $0.key, territory: $0.key, percentage: JSONText.number($0.value)) }
        mixMethod = profile.mix?.method ?? ""; mixShare = profile.mix.map { JSONText.number($0.share) } ?? "50"
        floor = profile.floor.map { JSONText.number($0) } ?? ""; ceiling = profile.ceiling.map { JSONText.number($0) } ?? ""
        indexRows = profile.index.sorted { $0.key < $1.key }.map { Override(id: "index-" + $0.key, territory: $0.key, percentage: JSONText.number($0.value)) }
    }
    public var pricingMethod: PricingMethod? { PricingMethod(rawValue: method) }
    /// True when the recipe uses your own index, as its method or mixed in.
    public var usesOwnIndex: Bool { method == PricingMethod.own.rawValue || effectiveMixMethod == PricingMethod.own.rawValue }
    /// Replaces rows with values read from a CSV file, keeping rows for other countries.
    public static func merge(_ rows: [Override], _ values: [String: String]) -> [Override] {
        rows.filter { values[TextSemantics.trim($0.territory).uppercased()] == nil } + values.sorted { $0.key < $1.key }.map { Override(territory: $0.key, percentage: $0.value) }
    }
    /// The rounding the chosen method really uses.
    public var effectiveRounding: String { PricingMethod(rawValue: method)?.rounding(rounding) ?? rounding }
    public func validated() throws -> PricingProfile {
        guard overrides.count <= 250 else { throw PricingFailure.invalid("A profile can contain at most 250 territory overrides.") }
        var percentages: [String: Double] = [:]
        for row in overrides {
            let territory = TextSemantics.trim(row.territory).uppercased(), text = TextSemantics.trim(row.percentage)
            guard let number = Double(text), !text.isEmpty else { throw PricingFailure.invalid("A territory percentage must be between 0 and 1,000 with at most two decimals.") }
            guard percentages[territory] == nil else { throw PricingFailure.invalid("Each country can appear only once.") }
            percentages[territory] = number
        }
        func number(_ text: String, _ problem: String) throws -> Double? {
            let trimmed = TextSemantics.trim(text)
            if trimmed.isEmpty { return nil }
            guard let value = Double(trimmed) else { throw PricingFailure.invalid(problem) }
            return value
        }
        let mix = try effectiveMixMethod.isEmpty ? nil : PricingMix(method: mixMethod, share: number(mixShare, "Enter the mixed-in share in percent.") ?? 0)
        let limits = PricingMethod(rawValue: method)?.exactOnly == true ? (nil, nil) : (try number(floor, "Enter the lowest price in percent, or leave it empty."), try number(ceiling, "Enter the highest price in percent, or leave it empty."))
        guard indexRows.count <= 250 else { throw PricingFailure.invalid("Your own index can contain at most 250 countries.") }
        var index: [String: Double] = [:]
        if usesOwnIndex {
            for row in indexRows {
                let territory = TextSemantics.trim(row.territory).uppercased()
                guard let value = try number(row.percentage, "Enter a number for each value in your own index.") else { throw PricingFailure.invalid("Enter a number for each value in your own index.") }
                guard index[territory] == nil else { throw PricingFailure.invalid("Each country can appear only once in your own index.") }
                index[territory] = value
            }
        }
        return try PricingProfile(id: id, name: name, guideTerritory: guideTerritory, rounding: rounding, method: method, percentages: percentages,
                                  mix: mix, floor: limits.0, ceiling: limits.1, index: index).validated()
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        TextSemantics.same(lhs.id, rhs.id) && TextSemantics.same(lhs.name, rhs.name) && TextSemantics.same(lhs.guideTerritory, rhs.guideTerritory)
            && lhs.method == rhs.method && lhs.effectiveRounding == rhs.effectiveRounding && lhs.overrides == rhs.overrides
            && lhs.mixMethod == rhs.mixMethod && (lhs.mixMethod.isEmpty || TextSemantics.same(lhs.mixShare, rhs.mixShare))
            && TextSemantics.same(lhs.floor, rhs.floor) && TextSemantics.same(lhs.ceiling, rhs.ceiling) && lhs.indexRows == rhs.indexRows
    }
}
