import Foundation

/// The measures chosen for one chart, kept as one comma-separated text so a single saved choice holds several.
public enum ChartMeasures {
    /// A chart draws at most this many series.
    public static let limit = 4
    static let none = "none"
    /// The chosen measures in the order chosen. Text that names no allowed measure means the fallback.
    public static func chosen(_ text: String, allowed: [String], fallback: [String]) -> [String] {
        guard text != none else { return [] }
        var seen = Set<String>()
        let values = text.split(separator: ",").map(String.init).filter { allowed.contains($0) && seen.insert($0).inserted }
        return Array((values.isEmpty ? fallback.filter(allowed.contains) : values).prefix(limit))
    }
    /// The text after adding or removing one measure. A full chart keeps its measures until one is removed.
    public static func toggled(_ key: String, on: Bool, in chosen: [String]) -> String {
        var next = chosen.filter { $0 != key }
        if on, next.count < limit { next.append(key) }
        return next.isEmpty ? none : next.joined(separator: ",")
    }
    /// Whether original report amounts are drawn indexed. Indexing is offered only for proceeds in more than one report currency;
    /// every other measure or a single currency draws reported values, whatever was chosen before.
    public static func indexed(_ chosen: Bool, metric: String, currencies: Int) -> Bool { chosen && scaleOffered(metric: metric, currencies: currencies) }
    public static func scaleOffered(metric: String, currencies: Int) -> Bool { metric == "proceeds" && currencies > 1 }
}
