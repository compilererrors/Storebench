import Foundation

/// Complete product price material for a scoped reader. This projection never authorizes a price change.
public struct ProductPricePresentation: Sendable {
    public let initialPurchase: Bool
    public let phases: [String: ProductPricing.Phase]
    public let rows: [ProductPrice], territories: [String], shownPoints: [ProductPricePoint]
    public let current, future, other: Int
    public let search: String

    public static func initialPurchase(kind: PriceProduct.Kind?, schedule: ProductPriceSchedule?) -> Bool {
        kind == .purchase && schedule.map { !$0.available && $0.scheduleId?.isEmpty != false && $0.baseTerritory?.isEmpty != false && $0.rows.isEmpty } == true
    }
    public init(kind: PriceProduct.Kind?, schedule: ProductPriceSchedule?, today: String, activeTerritories: [String]?, points: [ProductPricePoint]?, amount: String) {
        initialPurchase = Self.initialPurchase(kind: kind, schedule: schedule)
        phases = ProductPricing.phases(schedule?.rows ?? [], today: today)
        let classified = phases
        rows = (schedule?.rows ?? []).enumerated().filter { classified[$0.element.key] != .past }.sorted { left, right in
            let lhs = (left.element.territory, left.element.startDate ?? "", left.element.source.rawValue)
            let rhs = (right.element.territory, right.element.startDate ?? "", right.element.source.rawValue)
            return lhs == rhs ? left.offset < right.offset : lhs < rhs
        }.map(\.element)
        territories = initialPurchase ? activeTerritories ?? [] : Array(Set(rows.map(\.territory))).sorted()
        var counts = (current: 0, future: 0, other: 0)
        for row in rows {
            switch classified[row.key] ?? .unknown {
            case .current: counts.current += 1
            case .future: counts.future += 1
            case .preserved, .unknown: counts.other += 1
            case .past: break
            }
        }
        current = counts.current; future = counts.future; other = counts.other
        search = amount.range(of: #"^[0-9]{0,12}(?:\.[0-9]{0,4})?$"#, options: .regularExpression) != nil ? amount : ""
        let filter = search
        shownPoints = Array((points ?? []).lazy.filter { filter.isEmpty || $0.customerPrice?.contains(filter) == true }.prefix(50))
    }
    public var json: JSONText {
        .object([("initialPurchase", .bool(initialPurchase)), ("rows", .array(rows.map { .object([("value", $0.json), ("phase", .string((phases[$0.key] ?? .unknown).rawValue))]) })),
            ("territories", .array(territories.map(JSONText.string))), ("current", .number(Double(current))), ("future", .number(Double(future))), ("other", .number(Double(other))),
            ("search", .string(search)), ("shownPoints", .array(shownPoints.map(\.json)))])
    }
}
