import Foundation

public struct AsoRateImpact: Sendable, Equatable {
    public let before, after: Double?
    public var change: Double? { before.flatMap { first in after.map { $0 - first } } }
    public var json: JSONText { .object([("before", before.map(JSONText.number) ?? .null), ("after", after.map(JSONText.number) ?? .null), ("change", change.map(JSONText.number) ?? .null)]) }
}

extension AsoPoint { public var json: JSONText { .object([("date", .string(date)), ("value", .number(value))]) } }
extension AsoImpact {
    public var json: JSONText { .object([("days", .number(Double(days))), ("basis", .string(basis.rawValue)), ("before", before.map(JSONText.number) ?? .null), ("after", after.map(JSONText.number) ?? .null), ("change", change.map(JSONText.number) ?? .null), ("percent", percent.map(JSONText.number) ?? .null), ("beforeDays", .number(Double(beforeDays))), ("afterDays", .number(Double(afterDays))), ("future", .bool(future))]) }
}
extension AsoFieldChange {
    public var json: JSONText { .object([("key", .string(key)), ("section", .string(section)), ("field", .string(field)), ("locale", .string(locale)), ("kind", .string(kind.rawValue)), ("added", .array(added.map(JSONText.string))), ("removed", .array(removed.map(JSONText.string))), ("segments", .array(segments.map { .object([("kind", .string($0.kind.rawValue)), ("text", .string($0.text))]) }))]) }
}
extension AsoProgressRow {
    public var json: JSONText { .object([("id", .string(id)), ("at", .string(at)), ("date", .string(date)), ("version", .string(version)), ("platform", .string(platform)), ("previousVersion", previousVersion.map(JSONText.string) ?? .null), ("kind", .string(isUpdate ? "update" : "version")), ("dateKnown", .bool(dateKnown)), ("dateSource", .string("snapshot-saved")), ("baseline", .bool(baseline)), ("changes", .array(changes.map(\.json)))]) }
}

extension AsoProgress {
    public enum Granularity: String, CaseIterable, Sendable { case day, week, month }
    public enum FieldFilter: String, CaseIterable, Sendable {
        case all, keywords, names, description, promotionalText, screenshots
        public var title: String { switch self { case .all: "All search and listing fields"; case .keywords: "Keywords"; case .names: "Name and subtitle"; case .description: "Description"; case .promotionalText: "Promotional text"; case .screenshots: "Screenshots" } }
        public var fields: [String] { switch self { case .all: []; case .names: ["name", "subtitle"]; default: [rawValue] } }
    }
    public struct Group: Sendable {
        public let key, title, description: String, metrics: [String]
    }
    public static let groups = [Group(key: "search", title: "Search", description: "People who found the app by searching the App Store.", metrics: ["searchImpressions", "searchViews", "searchFirst"]),
                                Group(key: "discovery", title: "Discovery", description: "All App Store impressions, product page views and Get taps.", metrics: ["impressions", "views", "get"]),
                                Group(key: "outcome", title: "Downloads and sales", description: "First-time downloads from Analytics and purchases from Sales reports.", metrics: ["first", "paid", "free"])]
    public static func rateGroup(_ key: String) -> String { key == "searchViewRate" ? "search" : "discovery" }
    public static func initialMeasures(_ points: [String: [AsoPoint]]) -> [String] { Array(["searchImpressions", "impressions", "views", "first", "paid"].filter { !(points[$0] ?? []).isEmpty }.prefix(4)) }
    public static func initialLocale(_ locales: [String], primary: String) -> String { locales.contains(primary) ? primary : locales.first ?? "" }
    public static func filteredRows(_ rows: [AsoProgressRow], locale: String, fields: [String]) -> [AsoProgressRow] {
        rows.map { row in
            AsoProgressRow(id: row.id, at: row.at, date: row.date, version: row.version, platform: row.platform, previousVersion: row.previousVersion, isUpdate: row.isUpdate, dateKnown: row.dateKnown, baseline: row.baseline,
                           changes: row.changes.filter { change in (locale.isEmpty || change.locale == locale) && (fields.isEmpty || fields.contains(change.field) || fields.contains(where: { name in change.field.hasPrefix(name + " ·") })) })
        }
    }
    public static func changedRows(_ rows: [AsoProgressRow], range: PeriodDateRange?) -> [AsoProgressRow] {
        rows.filter { !$0.baseline && !$0.changes.isEmpty && (!$0.dateKnown || (range?.contains($0.date) ?? true)) }.reversed()
    }
    public static func comparison(_ points: [AsoPoint], row: AsoProgressRow, days: Int, today: String) -> AsoImpact? {
        guard row.dateKnown, !row.baseline else { return nil }
        return impact(points, date: row.date, days: days, today: today)
    }
    public static func overlaps(_ row: AsoProgressRow, newer: AsoProgressRow?, days: Int) -> Bool {
        guard let newer, let first = PeriodDates.number(row.date), let second = PeriodDates.number(newer.date) else { return false }
        return second - first <= days
    }
    public struct Bucket: Sendable, Equatable {
        public let start, end: String, value: Double, days: Int
        public var json: JSONText { .object([("start", .string(start)), ("end", .string(end)), ("value", .number(value)), ("days", .number(Double(days)))]) }
    }
    /// Weekly and monthly values average the reported days, retaining gaps between report periods.
    public static func buckets(_ points: [AsoPoint], granularity: Granularity) -> [Bucket] {
        if granularity == .day { return points.map { Bucket(start: $0.date, end: $0.date, value: $0.value, days: 1) } }
        var result: [String: (end: String, total: Double, days: Int)] = [:]
        for point in points {
            guard let index = PeriodDates.number(point.date) else { continue }
            let start: String, end: String
            if granularity == .week {
                let first = index - ((index + 3) % 7 + 7) % 7
                start = PeriodDates.text(first); end = PeriodDates.text(first + 6)
            } else {
                start = String(point.date.prefix(7)) + "-01"
                let year = Int(point.date.prefix(4))!, month = Int(point.date.dropFirst(5).prefix(2))!
                // Stored month boundaries map years 0...99 to 1900...1999.
                let next = String(format: "%04d-%02d-01", (year < 100 ? year + 1900 : year) + (month == 12 ? 1 : 0), month == 12 ? 1 : month + 1)
                end = PeriodDates.text(PeriodDates.number(next)! - 1)
            }
            let prior = result[start] ?? (end, 0, 0)
            result[start] = (end, prior.total + point.value, prior.days + 1)
        }
        return result.keys.sorted().map { key in let item = result[key]!; return Bucket(start: key, end: item.end, value: item.total / Double(item.days), days: item.days) }
    }
    public static func indexed(_ values: [Double]) -> [Double] {
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        return values.map { average == 0 ? 0 : $0 / average * 100 }
    }
    public static func count(_ value: Double) -> String { value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...3))) }
    public static func fixed(_ value: Double, digits: Int) -> String {
        let literal = String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
        return (ReportDecimal(literal) ?? ReportDecimal.scientific(literal))?.fixed(digits) ?? "0"
    }
    public static func signed(_ value: Double, digits: Int = 0) -> String {
        (value > 0 ? "+" : value < 0 ? "−" : "±") + count(Double(fixed(abs(value), digits: digits)) ?? 0)
    }
    public struct Description: Sendable {
        public let value, title: String, detail: String?
        public var json: JSONText {
            var fields: [(String, JSONText)] = [("value", .string(value))]
            if let detail { fields.append(("detail", .string(detail))) }
            fields.append(("title", .string(title))); return .object(fields)
        }
    }
    /// Status and explanations shared by the comparison table and individual measure cards.
    public static func describe(_ impact: AsoImpact, label: String = "") -> Description {
        let window = "\(impact.days) \(impact.days == 1 ? "day" : "days")"
        func of(_ count: Int) -> String { "\(count) of \(window)" }
        let reported = "Before: \(of(impact.beforeDays))\nAfter: \(of(impact.afterDays))", coverage = "reports for \(of(impact.beforeDays)) before and \(of(impact.afterDays)) after"
        if impact.basis == .missing {
            let value = impact.future && impact.afterDays < impact.days ? "Waiting for data" : impact.beforeDays == 0 ? "No reports before" : impact.afterDays == 0 ? "No reports after" : "Too few reports"
            let reason = value == "Waiting for data" ? "the \(window) after this change are not over yet, or Apple has not delivered their reports" : value == "No reports before" ? "no reports are saved for the \(window) before this change, so there is nothing to compare with" : value == "No reports after" ? "no reports are saved for the \(window) after this change" : "fewer than half of the days on one side have a saved report"
            return Description(value: value, title: "\(label): \(reason) (\(coverage)). Missing reports are not zero.", detail: reported)
        }
        let percent = impact.percent.map { signed($0, digits: 1) + "%" } ?? ""
        if impact.basis == .total {
            let value = signed(impact.change!)
            return Description(value: value, title: "\(label): \(value) in the \(window) after the change compared with the \(window) before\(percent.isEmpty ? "" : " (\(percent))").", detail: percent.isEmpty ? nil : percent)
        }
        let value = signed(impact.change!, digits: 1) + "/day", detail = [percent, "\(min(impact.beforeDays, impact.afterDays)) of \(window)"].filter { !$0.isEmpty }.joined(separator: " · ")
        return Description(value: value, title: "\(label): \(value) on average per reported day\(percent.isEmpty ? "" : " (\(percent))"); \(coverage).", detail: detail)
    }
}
