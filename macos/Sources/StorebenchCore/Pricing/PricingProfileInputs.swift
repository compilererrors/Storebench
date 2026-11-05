import Foundation

/// Keeps incomplete editor text until an explicit save or preview validates it.
public struct PricingProfileInputs: Equatable, Sendable {
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
    public init(_ profile: PricingProfile) {
        id = profile.id; name = profile.name; guideTerritory = profile.guideTerritory
        method = profile.method; rounding = profile.rounding
        overrides = profile.percentages.sorted { $0.key < $1.key }.map { Override(id: $0.key, territory: $0.key, percentage: JSONText.number($0.value)) }
    }
    public func validated() throws -> PricingProfile {
        guard overrides.count <= 250 else { throw PricingFailure.invalid("A profile can contain at most 250 territory overrides.") }
        var percentages: [String: Double] = [:]
        for row in overrides {
            let territory = TextSemantics.trim(row.territory).uppercased(), text = TextSemantics.trim(row.percentage)
            guard let number = Double(text), !text.isEmpty else { throw PricingFailure.invalid("A territory percentage must be between 0 and 1,000 with at most two decimals.") }
            guard percentages[territory] == nil else { throw PricingFailure.invalid("Each country can appear only once.") }
            percentages[territory] = number
        }
        return try PricingProfile(id: id, name: name, guideTerritory: guideTerritory, rounding: rounding, method: method, percentages: percentages).validated()
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        TextSemantics.same(lhs.id, rhs.id) && TextSemantics.same(lhs.name, rhs.name) && TextSemantics.same(lhs.guideTerritory, rhs.guideTerritory)
            && lhs.method == rhs.method && (lhs.method == "same" ? "exact" : lhs.rounding) == (rhs.method == "same" ? "exact" : rhs.rounding) && lhs.overrides == rhs.overrides
    }
}
