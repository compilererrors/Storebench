import Foundation

extension AsoProgress {
    /// Prepare saved daily lookups once for all comparison rows. Date-range display filters never trim this evidence.
    public struct Reports: Sendable {
        private let values: [String: [Int: Double]]
        public init(_ points: [String: [AsoPoint]]) {
            values = points.mapValues { points in
                var days: [Int: Double] = [:]
                for point in points { if let day = PeriodDates.number(point.date) { days[day] = point.value } }
                return days
            }
        }
        func coverage(_ metric: String, date: String, days: Int) -> (before: [Double?], after: [Double?])? {
            guard (1...365).contains(days), let anchor = PeriodDates.number(date) else { return nil }
            let saved = values[metric] ?? [:]
            return ((0..<days).map { saved[anchor - days + $0] }, (0..<days).map { saved[anchor + 1 + $0] })
        }
        public func impact(_ metric: String, date: String, days: Int, today: String) -> AsoImpact {
            let future = (1...365).contains(days) && PeriodDates.number(date).map { PeriodDates.text($0 + days) >= today } == true
            guard let coverage = coverage(metric, date: date, days: days) else { return AsoImpact(days: days, basis: .missing, before: nil, after: nil, change: nil, percent: nil, beforeDays: 0, afterDays: 0, future: future) }
            let before = coverage.before.compactMap { $0 }, after = coverage.after.compactMap { $0 }, needed = max(1, (days + 1) / 2)
            let basis: AsoImpact.Basis = before.count == days && after.count == days ? .total : before.count >= needed && after.count >= needed ? .daily : .missing
            func value(_ list: [Double]) -> Double? { basis == .total ? list.reduce(0, +) : basis == .daily ? list.reduce(0, +) / Double(list.count) : nil }
            let first = value(before), second = value(after), change = first.flatMap { a in second.map { $0 - a } }
            return AsoImpact(days: days, basis: basis, before: first, after: second, change: change, percent: change.flatMap { c in first.flatMap { $0 == 0 ? nil : c / $0 * 100 } }, beforeDays: before.count, afterDays: after.count, future: future)
        }
        public func comparison(_ metric: String, row: AsoProgressRow, days: Int, today: String) -> AsoImpact? {
            guard row.dateKnown, !row.baseline else { return nil }
            return impact(metric, date: row.date, days: days, today: today)
        }
        public func rate(_ numerator: String, _ denominator: String, date: String, days: Int) -> AsoRateImpact {
            guard let top = coverage(numerator, date: date, days: days), let bottom = coverage(denominator, date: date, days: days) else { return AsoRateImpact(before: nil, after: nil) }
            let needed = max(1, (days + 1) / 2)
            func ratio(_ a: [Double?], _ b: [Double?]) -> Double? {
                let pairs = zip(a, b).compactMap { x, y in x.flatMap { x in y.map { (x, $0) } } }
                let shown = pairs.reduce(0) { $0 + $1.1 }
                return pairs.count >= needed && shown != 0 ? pairs.reduce(0) { $0 + $1.0 } / shown * 100 : nil
            }
            return AsoRateImpact(before: ratio(top.before, bottom.before), after: ratio(top.after, bottom.after))
        }
    }
}
