import Foundation

/// Saved-version comparison uses its own report selection contract, independently of journal outcome evidence.
public enum AsoComparison {
    public static func snapshots(_ revisions: [Revision]) -> [AsoSnapshot] { ASO.versionSnapshots(revisions, releasedOnly: true).map(AsoSnapshot.init) }
    /// The journal retains drafts and sends; statistics require a released observation or verified public availability.
    public static func statisticsEvents(_ events: [JournalEvent], snapshots: [AsoSnapshot]) -> [JournalEvent] {
        events.filter { event in
            if event.publicVerifiedAt?.isEmpty == false { return true }
            guard event.source == "import", let revision = event.sourceRevisionId, let platform = event.platform, let version = event.version else { return false }
            let label = "\(Releases.platformName(platform)) \(version)"
            return snapshots.contains { $0.revisionId == revision && $0.version == label }
        }
    }

    public static func graphMetric(analytics: [AnalyticsPeriod], sales: [SalesPresentation.Period]) -> String {
        let choices = AsoOutcome.metrics.map { ($0.key, points($0.key, analytics: analytics, sales: sales).count) }
        return choices.first { $0.1 >= 2 }?.0 ?? choices.first { $0.1 > 0 }?.0 ?? "impressions"
    }
    public struct Pair: Sendable, Equatable {
        public let leftId, rightId: String
        public init(leftId: String, rightId: String) { self.leftId = leftId; self.rightId = rightId }
        public var json: JSONText { .object([("leftId", .string(leftId)), ("rightId", .string(rightId))]) }
    }
    public static func sameState(_ a: AsoSnapshot, _ b: AsoSnapshot) -> Bool {
        TextSemantics.same(a.version, b.version) && a.fields.count == b.fields.count && a.fields.allSatisfy { field in TextSemantics.same(b.fields.first { $0.key == field.key }?.value, field.value) }
    }
    public static func initialPair(_ snapshots: [AsoSnapshot]) -> Pair {
        guard let right = snapshots.last else { return Pair(leftId: "", rightId: "") }
        let earlier = snapshots.dropLast(), left = earlier.last { !sameState($0, right) } ?? earlier.last ?? right
        return Pair(leftId: left.id, rightId: right.id)
    }
    public static func choose(_ pair: Pair, side: String, id: String) -> Pair {
        side == "left" ? Pair(leftId: id, rightId: id == pair.rightId ? pair.leftId : pair.rightId) : Pair(leftId: id == pair.leftId ? pair.rightId : pair.leftId, rightId: id)
    }
    public static func points(_ metric: String, analytics: [AnalyticsPeriod], sales: [SalesPresentation.Period]) -> [AsoPoint] {
        if metric == "paid" { return sales.filter { $0.beginDate == $0.endDate }.map { AsoPoint(date: $0.beginDate, value: $0.rows.reduce(0) { $0 + Double($1.paid) }) }.sorted { $0.date < $1.date } }
        var chosen: [String: AnalyticsPeriod] = [:]
        for period in analytics where period.kind == (metric == "first" ? "downloads" : "engagement") && period.granularity == "DAILY" && period.date == period.endDate {
            if let prior = chosen[period.date], prior.level == "standard" || period.level != "standard" { continue }
            chosen[period.date] = period
        }
        return chosen.values.map { period in AsoPoint(date: period.date, value: period.facts.filter { $0.metric == metric }.reduce(0) { $0 + $1.count }) }.sorted { $0.date < $1.date }
    }
    public struct Side: Sendable {
        public let saved: Int, total: Double?
        public var json: JSONText { .object([("saved", .number(Double(saved))), ("total", total.map(JSONText.number) ?? .null)]) }
    }
    public static func side(_ points: [AsoPoint], date: String, days: Int) -> Side {
        guard (1...14).contains(days), let anchor = PeriodDates.number(date) else { return Side(saved: 0, total: nil) }
        let values = Dictionary(points.map { ($0.date, $0.value) }, uniquingKeysWith: { _, last in last })
        let found = (1...days).compactMap { values[PeriodDates.text(anchor + $0)] }
        return Side(saved: found.count, total: found.count == days ? found.reduce(0, +) : nil)
    }
    public static func initialDays(_ left: AsoSnapshot?, _ right: AsoSnapshot?, analytics: [AnalyticsPeriod], sales: [SalesPresentation.Period]) -> Int {
        guard let left, let right else { return 7 }
        let metricPoints = AsoOutcome.metrics.map { points($0.key, analytics: analytics, sales: sales) }
        let options = [7, 3, 1, 14].map { days in (days, metricPoints.map { [side($0, date: String(left.at.prefix(10)), days: days).saved == days, side($0, date: String(right.at.prefix(10)), days: days).saved == days] }) }
        return options.first { $0.1.contains { $0.allSatisfy { $0 } } }?.0 ?? options.first { $0.1.contains { $0.contains(true) } }?.0 ?? 7
    }
    public struct Activity: Sendable, Identifiable {
        public let metric, label: String, reportDates: Int, left, right: Side, difference: Double?, percent: String?
        public var id: String { metric }
        public var json: JSONText { .object([("metric", .string(metric)), ("label", .string(label)), ("reportDates", .number(Double(reportDates))), ("left", left.json), ("right", right.json), ("difference", difference.map(JSONText.number) ?? .null), ("percent", percent.map(JSONText.string) ?? .null)]) }
    }
    public static func activity(leftDate: String, rightDate: String, days: Int, analytics: [AnalyticsPeriod], sales: [SalesPresentation.Period]) -> [Activity] {
        let independent = leftDate != rightDate && PeriodDates.number(leftDate).flatMap { left in PeriodDates.number(rightDate).map { abs($0 - left) >= days } } == true
        return AsoOutcome.metrics.map { metric in
            let points = Self.points(metric.key, analytics: analytics, sales: sales), left = side(points, date: leftDate, days: days), right = side(points, date: rightDate, days: days)
            let difference = independent ? left.total.flatMap { a in right.total.map { $0 - a } } : nil
            let percent = difference.flatMap { change in left.total.flatMap { total -> String? in
                guard total != 0 else { return nil }
                let value = change / total * 100, literal = String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
                guard let decimal = ReportDecimal(literal) ?? ReportDecimal.scientific(literal) else { return nil }
                return (change > 0 ? "+" : "") + decimal.fixed(1) + "%"
            } }
            return Activity(metric: metric.key, label: metric.title, reportDates: points.count, left: left, right: right, difference: difference, percent: percent)
        }
    }
    public static func fieldName(_ field: String) -> String {
        if field.hasPrefix("screenshots") { return field.replacingOccurrences(of: "screenshots · ", with: "Screenshots · ").replacingOccurrences(of: "_", with: " ") }
        let spaced = field.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression)
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
    public static func fieldValue(_ value: String?, image: Bool, counterpart: String? = nil) -> String {
        guard let value, !value.isEmpty else { return "No saved value" }
        guard image else { return value }
        let count = value.components(separatedBy: ",").count
        let changed = counterpart.map { !$0.isEmpty && !TextSemantics.same($0, value) && $0.components(separatedBy: ",").count == count } ?? false
        return "\(count) image\(count == 1 ? "" : "s")\(changed ? " · image set or order changed" : "")"
    }
    private static func context(_ field: AsoSnapshot.Field) -> String {
        let parts = field.key.components(separatedBy: ":")
        return parts[0] == "info" ? "App-wide information at import · \(parts[1])" : "\(Releases.platformName(parts[1])) · \(parts[2])"
    }
    private static func priority(_ field: String) -> Int { ["name": 0, "subtitle": 1, "keywords": 2, "promotionalText": 3, "description": 4, "whatsNew": 5][field] ?? (field.hasPrefix("screenshots") ? 6 : 7) }
    public struct Field: Sendable, Identifiable {
        public let key, context, label: String, image, changed: Bool, before, after: String?, beforeDisplay, afterDisplay: String
        public var id: String { key }
        public var json: JSONText { .object([("key", .string(key)), ("context", .string(context)), ("label", .string(label)), ("image", .bool(image)), ("changed", .bool(changed)), ("before", before.map(JSONText.string) ?? .null), ("after", after.map(JSONText.string) ?? .null), ("beforeDisplay", .string(beforeDisplay)), ("afterDisplay", .string(afterDisplay))]) }
    }
    public static func fields(_ left: AsoSnapshot?, _ right: AsoSnapshot?, primary: String) -> [Field] {
        let before = Dictionary((left?.fields ?? []).map { ($0.key, $0) }, uniquingKeysWith: { _, last in last }), after = Dictionary((right?.fields ?? []).map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        var keys: [String] = []; for field in (left?.fields ?? []) + (right?.fields ?? []) where !keys.contains(field.key) { keys.append(field.key) }
        keys.sort { a, b in
            let x = after[a] ?? before[a]!, y = after[b] ?? before[b]!, first = x.key.components(separatedBy: ":").contains(primary) ? 0 : 1, second = y.key.components(separatedBy: ":").contains(primary) ? 0 : 1
            if first != second { return first < second }
            let order = context(x).compare(context(y), locale: Locale(identifier: "en_US")); if order != .orderedSame { return order == .orderedAscending }
            if priority(x.field) != priority(y.field) { return priority(x.field) < priority(y.field) }
            return x.field.compare(y.field, locale: Locale(identifier: "en_US")) == .orderedAscending
        }
        return keys.map { key in
            let a = before[key], b = after[key], field = b ?? a!, image = field.field.hasPrefix("screenshots")
            return Field(key: key, context: context(field), label: fieldName(field.field), image: image, changed: !TextSemantics.same(a?.value, b?.value), before: a?.value, after: b?.value, beforeDisplay: fieldValue(a?.value, image: image, counterpart: b?.value), afterDisplay: fieldValue(b?.value, image: image, counterpart: a?.value))
        }
    }
    /// Disjoint daily runs prevent a chart from joining activity across an unreported date.
    public static func runs(_ points: [AsoPoint]) -> [[AsoPoint]] {
        var result: [[AsoPoint]] = []
        for point in points {
            guard let day = PeriodDates.number(point.date) else { continue }
            if let prior = result.last?.last, PeriodDates.number(prior.date) == day - 1 { result[result.count - 1].append(point) }
            else { result.append([point]) }
        }
        return result
    }
}
