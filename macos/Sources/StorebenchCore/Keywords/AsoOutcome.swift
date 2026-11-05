import Foundation

/// Journal-anchored reported activity, retaining the selected revisions and missing dates as decision evidence.
public enum AsoOutcome {
    public enum Failure: Error, Equatable {
        case malformed, overflow
        public var message: String { "Saved outcome evidence could not be validated. Read the journal and reports again before interpreting it." }
    }
    public static let metrics: [(key: String, title: String)] = [("impressions", "Impressions"), ("views", "Product page views"), ("get", "Get / Buy / Pre-order taps"), ("first", "First-time downloads"), ("paid", "Paid app purchases")]
    public struct Daily: Sendable {
        public let date: String, value: Int, revision: String
        var json: JSONText { .object([("date", .string(date)), ("value", .number(Double(value))), ("revision", .string(revision))]) }
    }
    public struct Window: Sendable {
        public let start, end: String, covered: Int, total: Int?, missing, revisions: [String], daily: [Daily]
        var json: JSONText { .object([("start", .string(start)), ("end", .string(end)), ("covered", .number(Double(covered))), ("total", total.map { .number(Double($0)) } ?? .null), ("missing", .strings(missing)), ("revisions", .strings(revisions)), ("daily", .array(daily.map(\.json)))]) }
    }
    public struct Measure: Sendable {
        public let before, after: Window, difference: Int?
        var json: JSONText { .object([("before", before.json), ("after", after.json), ("difference", difference.map { .number(Double($0)) } ?? .null)]) }
    }
    public struct Anchor: Sendable {
        public let at, date, kind, timeZone: String
        var json: JSONText { .object([("at", .string(at)), ("date", .string(date)), ("kind", .string(kind)), ("timeZone", .string(timeZone))]) }
    }
    public struct Source: Sendable {
        public let name, url, definition, timeZone: String
        var json: JSONText { .object([("name", .string(name)), ("url", .string(url)), ("definition", .string(definition)), ("timeZone", .string(timeZone))]) }
    }
    public struct OtherEvent: Sendable, Identifiable {
        public let id, title, at, scope: String
        var json: JSONText { .object([("id", .string(id)), ("title", .string(title)), ("at", .string(at)), ("scope", .string(scope))]) }
    }
    public struct Review: Sendable {
        public let metric: String, days: Int, territory, comparisonTerritory: String, anchor: Anchor?, primary, comparison: Measure?
        public let otherEvents: [OtherEvent], otherEventsTotal: Int, otherEventsDigest: String, source: Source, canDescribeDifference: Bool, reasons: [String]
        var json: JSONText { .object([("metric", .string(metric)), ("days", .number(Double(days))), ("territory", .string(territory)), ("comparisonTerritory", .string(comparisonTerritory)), ("anchor", anchor?.json ?? .null), ("primary", primary?.json ?? .null), ("comparison", comparison?.json ?? .null), ("otherEvents", .array(otherEvents.map(\.json))), ("otherEventsTotal", .number(Double(otherEventsTotal))), ("otherEventsDigest", .string(otherEventsDigest)), ("source", source.json), ("canDescribeDifference", .bool(canDescribeDifference)), ("reasons", .strings(reasons))]) }
        public func evidenceFingerprint(for event: JournalEvent) -> String {
            JSONText.array([.string(event.id), .string(event.basis), .string(metric), .number(Double(days)), .string(territory), .string(comparisonTerritory), anchor?.json ?? .null, source.json, primary?.json ?? .null, comparison?.json ?? .null, .number(Double(otherEventsTotal)), .string(otherEventsDigest)]).rawSHA256
        }
    }
    static func total(_ values: [Double]) throws -> Int {
        var sum = 0.0
        for value in values {
            guard value.isFinite, value >= 0, value.rounded() == value, value <= 9_007_199_254_740_991 - sum else { throw Failure.overflow }
            sum += value
        }
        return Int(sum)
    }
    private static func source(_ metric: String) -> Source {
        let engagement = "App Store Connect Analytics · App Store engagement", definitions = "https://developer.apple.com/help/app-store-connect-analytics/reference/metrics-definitions"
        switch metric {
        case "impressions": return Source(name: engagement, url: definitions, definition: "Reported App Store impression event counts. The saved report counts events, not unique people or sales.", timeZone: "UTC")
        case "get": return Source(name: engagement, url: "https://developer.apple.com/documentation/analytics-reports/app-store-discovery-and-engagement", definition: "Reported Get engagement type: taps on Get, Buy, or Pre-order buttons. A tap does not prove a completed download.", timeZone: "UTC")
        case "first": return Source(name: "App Store Connect Analytics · App Downloads", url: definitions, definition: "Reported first-time download event counts, separate from redownloads, updates and restores.", timeZone: "UTC")
        case "paid": return Source(name: "Sales and Trends · Summary Sales", url: "https://developer.apple.com/help/app-store-connect/reference/reporting/summary-sales-report", definition: "Paid app purchase units in saved daily Summary Sales reports, excluding in-app purchases and subscriptions. Refunds are not subtracted here.", timeZone: "America/Los_Angeles")
        default: return Source(name: engagement, url: definitions, definition: "Reported product page view event counts. Repeated views can be counted more than once.", timeZone: "UTC")
        }
    }
    private static func date(_ at: String, zone: String) throws -> String {
        if zone == "UTC" { return String(at.prefix(10)) }
        guard let instant = ASO.iso(at) else { throw Failure.malformed }
        let offset = TimeZone(identifier: "America/Los_Angeles")!.secondsFromGMT(for: instant)
        let day = Int(floor((instant.timeIntervalSince1970 + Double(offset)) / 86_400))
        let result = PeriodDates.text(day)
        guard PeriodDates.number(result) != nil else { throw Failure.malformed }; return result
    }
    private static func points(_ metric: String, territory: String, analytics: [AnalyticsPeriod], sales: [SalesPresentation.Period]) throws -> [String: Daily] {
        var result: [String: Daily] = [:]
        if metric == "paid" {
            var selected: [String: SalesPresentation.Period] = [:]
            for period in sales where period.beginDate == period.endDate && (period.hasSource || period.noSales) {
                if let prior = selected[period.beginDate], prior.importedAt >= period.importedAt { continue }; selected[period.beginDate] = period
            }
            for period in selected.values {
                let relevant = territory.isEmpty ? period.rows : period.rows.filter { $0.code == territory }
                guard !relevant.isEmpty || period.noSales else { continue }
                result[period.beginDate] = Daily(date: period.beginDate, value: try total(relevant.map { Double($0.paid) }), revision: "Summary Sales \(period.beginDate) · imported \(period.importedAt)")
            }
        } else {
            var selected: [String: AnalyticsPeriod] = [:]
            for period in analytics where period.kind == (metric == "first" ? "downloads" : "engagement") && period.granularity == "DAILY" && period.date == period.endDate {
                if let prior = selected[period.date], prior.level == "standard" && period.level != "standard" || prior.level == period.level && prior.processingDate >= period.processingDate { continue }
                selected[period.date] = period
            }
            for period in selected.values {
                let relevant = period.facts.filter { $0.metric == metric && (territory.isEmpty || $0.territory == territory) }
                guard !relevant.isEmpty else { continue }
                result[period.date] = Daily(date: period.date, value: try total(relevant.map(\.count)), revision: "\(period.key) · processed \(period.processingDate)")
            }
        }
        return result
    }
    public static func territories(_ metric: String, analytics: [AnalyticsPeriod], sales: [SalesPresentation.Period]) -> [String] {
        let codes = metric == "paid" ? sales.filter { $0.hasSource && $0.beginDate == $0.endDate }.flatMap { $0.rows.map(\.code) }
            : analytics.filter { $0.kind == (metric == "first" ? "downloads" : "engagement") && $0.granularity == "DAILY" }.flatMap { $0.facts.filter { $0.metric == metric }.map(\.territory) }
        return Array(Set(codes.filter { $0.utf8.count == 3 && $0.utf8.allSatisfy { (65...90).contains($0) } })).sorted()
    }
    private static func window(_ points: [String: Daily], anchor: Int, from: Int, through: Int) throws -> Window {
        let dates = (from...through).map { PeriodDates.text(anchor + $0) }
        guard dates.allSatisfy({ PeriodDates.number($0) != nil }) else { throw Failure.malformed }
        let found = dates.compactMap { points[$0] }, missing = dates.filter { points[$0] == nil }
        return Window(start: dates[0], end: dates.last!, covered: found.count, total: missing.isEmpty ? try total(found.map { Double($0.value) }) : nil, missing: missing, revisions: Array(Set(found.map(\.revision))).sorted(), daily: found)
    }
    private static func measure(_ metric: String, territory: String, analytics: [AnalyticsPeriod], sales: [SalesPresentation.Period], anchor: Int, days: Int) throws -> Measure {
        let points = try Self.points(metric, territory: territory, analytics: analytics, sales: sales)
        let before = try window(points, anchor: anchor, from: -days, through: -1), after = try window(points, anchor: anchor, from: 1, through: days)
        return Measure(before: before, after: after, difference: before.total.flatMap { a in after.total.map { $0 - a } })
    }
    private static func timestamp(_ value: String) -> String { ASO.iso(value).map { String(CustomerReview.isoString($0).prefix(16)).replacingOccurrences(of: "T", with: " ") + " UTC" } ?? "Unknown time" }
    private static func present(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
    public static func analyze(_ event: JournalEvent, events: [JournalEvent], analytics: [AnalyticsPeriod], sales: [SalesPresentation.Period], metric requestedMetric: String = "views", days requestedDays: Int = 7, territory requestedTerritory: String = "", comparison requestedComparison: String = "") throws -> Review {
        let metric = metrics.contains { $0.key == requestedMetric } ? requestedMetric : "views", days = (1...90).contains(requestedDays) ? requestedDays : 7
        let choices = territories(metric, analytics: analytics, sales: sales), territory = choices.contains(requestedTerritory) ? requestedTerritory : ""
        let comparisonTerritory = !territory.isEmpty && territory != requestedComparison && choices.contains(requestedComparison) ? requestedComparison : ""
        let source = Self.source(metric), verified = present(event.publicVerifiedAt), observed = present(event.observedAt), sent = present(event.sentAt)
        let at = verified ?? observed ?? sent, kind = verified != nil ? "public-observation" : observed != nil ? "import-observation" : "apple-send"
        var anchor: Anchor?
        if let at, !at.isEmpty { let day = try date(at, zone: source.timeZone); if PeriodDates.number(day) != nil { anchor = Anchor(at: at, date: day, kind: kind, timeZone: source.timeZone) } }
        let index = anchor.flatMap { PeriodDates.number($0.date) }
        let primary = try index.map { try measure(metric, territory: territory, analytics: analytics, sales: sales, anchor: $0, days: days) }
        let comparison = try !comparisonTerritory.isEmpty ? index.map { try measure(metric, territory: comparisonTerritory, analytics: analytics, sales: sales, anchor: $0, days: days) } : nil
        var overlapping: [(Int, OtherEvent)] = []
        if let index {
            let first = PeriodDates.text(index - days), last = PeriodDates.text(index + days)
            for (order, item) in events.enumerated() {
                guard item.id != event.id, let at = present(item.observedAt) ?? present(item.sentAt), !(item.source == "import" && present(item.occurrenceAfter) == nil) else { continue }
                let day = try date(at, zone: source.timeZone)
                if day >= first && day <= last { overlapping.append((order, OtherEvent(id: item.id, title: item.title, at: at, scope: present(item.reviewScope) ?? item.source))) }
            }
        }
        overlapping.sort { $0.1.at == $1.1.at ? $0.0 < $1.0 : $0.1.at < $1.1.at }
        let all = overlapping.map(\.1), digest = JSONText.array(all.map(\.json)).rawSHA256
        var reasons: [String] = []
        if !requestedTerritory.isEmpty && territory.isEmpty { reasons.append("The selected market has no saved daily rows for this measure. Showing all reported territories instead.") }
        if !requestedComparison.isEmpty && comparisonTerritory.isEmpty { reasons.append(territory.isEmpty ? "Choose a primary market before selecting a comparison market." : requestedComparison == territory ? "Choose a different comparison market." : "The comparison market has no saved daily rows for this measure.") }
        if anchor == nil { reasons.append("This record has no Apple send or import observation to anchor report dates.") }
        else {
            reasons.append(verified == nil ? "Public availability for this change is not verified. The anchor is not its publication time." : "The app was verified public at the recorded time; that observation does not establish when this exact listing change became public.")
            if let after = present(event.occurrenceAfter) { reasons.append("The changed listing was observed between \(timestamp(after)) and \(timestamp(event.observedAt ?? "")); report days inside that interval cannot be assigned to one listing state.") }
            if event.source == "import" && present(event.occurrenceAfter) == nil { reasons.append("This is the first saved listing observation; there is no earlier listing baseline for this version.") }
            if sent != nil && observed == nil { reasons.append("A successful Apple send or review submission does not prove a public release.") }
            if let primary, !primary.before.missing.isEmpty || !primary.after.missing.isEmpty { reasons.append("At least one report day is missing. A missing report or territory row is unknown, not zero.") }
            if !all.isEmpty { reasons.append("Other sent or observed changes fall inside the selected report window.") }
            if !comparisonTerritory.isEmpty { reasons.append("The comparison market is descriptive. Listing-language equivalence and independent exposure are not verified.") }
        }
        return Review(metric: metric, days: days, territory: territory, comparisonTerritory: comparisonTerritory, anchor: anchor, primary: primary, comparison: comparison, otherEvents: Array(all.prefix(50)), otherEventsTotal: all.count, otherEventsDigest: digest, source: source, canDescribeDifference: primary?.difference != nil && event.source == "import" && present(event.occurrenceAfter) != nil && all.isEmpty, reasons: reasons)
    }
}

private extension JSONText {
    static func strings(_ values: [String]) -> JSONText { .array(values.map { .string($0) }) }
}
