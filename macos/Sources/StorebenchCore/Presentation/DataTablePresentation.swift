import Foundation

/// Stable ordering of source values. Missing facts stay last in either direction;
/// amounts in different currencies are grouped, never compared as equivalent money.
public enum DataTablePresentation {
    public static let headerHeight = StorebenchDesign.shared.dimension("tableHeader")
    public static let rowHeight = StorebenchDesign.shared.dimension("tableRow")
    public static func compactText(_ value: String) -> String {
        value.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    public static func resizedWidth(_ value: Double, minimum: Double = 64) -> Double {
        value.isFinite ? min(800, max(minimum, value)) : minimum
    }
    public enum Value: Sendable {
        case text(String), number(Double), money(Decimal, currency: String), unknown
        fileprivate var missing: Bool { if case .unknown = self { return true }; if case .number(let value) = self { return !value.isFinite }; return false }
    }
    public static func sorted<Row>(_ rows: [Row], descending: Bool, value: (Row) -> Value) -> [Row] {
        rows.enumerated().map { (index: $0.offset, row: $0.element, value: value($0.element)) }.sorted { a, b in
            if a.value.missing != b.value.missing { return !a.value.missing }
            let result: ComparisonResult
            switch (a.value, b.value) {
            case (.text(let x), .text(let y)): result = x.compare(y, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            case (.number(let x), .number(let y)) where x.isFinite && y.isFinite: result = x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            case (.money(let x, let xc), .money(let y, let yc)):
                if xc != yc { return xc < yc }
                result = x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            default: result = .orderedSame
            }
            if result == .orderedSame { return a.index < b.index }
            return descending ? result == .orderedDescending : result == .orderedAscending
        }.map(\.row)
    }
    public static func widths(available: Double, minimum: [Double], weights: [Double] = []) -> [Double] {
        let base = minimum.map { $0.isFinite ? max(0, $0) : 0 }
        let extra = max(0, (available.isFinite ? available : 0) - base.reduce(0, +))
        let shares = base.indices.map { weights.indices.contains($0) && weights[$0].isFinite ? max(0, weights[$0]) : 1 }
        let total = shares.reduce(0, +)
        return base.indices.map { base[$0] + (total > 0 ? extra * shares[$0] / total : 0) }
    }
}
