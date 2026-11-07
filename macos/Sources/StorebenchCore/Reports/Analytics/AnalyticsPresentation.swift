import Foundation

/// Derived Analytics facts for the selected report stream; source rows remain in encrypted storage.
public enum AnalyticsPresentation {
    public static let metrics = ["first", "redownload", "updates", "restores", "impressions", "views", "get", "other"]
    public struct Activity: Sendable, Identifiable {
        public let key: String, count: Double
        let order: Int
        public var id: String { Data(key.utf8).base64EncodedString() }
    }
    public struct Summary: Sendable {
        public let totals: [String: Double], territories: [Activity], sources: [Activity], devices: [Activity]
    }
    public struct LeadingTerritory: Sendable {
        public let code, name, share: String
        public let count, total: Int
    }
    public static func leadingTerritory(_ summary: Summary, metric: String) -> LeadingTerritory? {
        guard metric == "first", let total = summary.totals["first"], total > 0, let first = summary.territories.first(where: { $0.key != "UNKNOWN" }), first.count >= 20 else { return nil }
        return LeadingTerritory(code: first.key, name: territoryName(first.key), share: SalesPresentation.shareLabel(Int(first.count), total: Int(total)), count: Int(first.count), total: Int(total))
    }
    public struct Point: Sendable, Identifiable {
        public let key: String, metric: String, start: String, end: String, run: String, position: Date, value: Double
        public var id: String { "\(metric):\(key)" }
    }
    public enum Dimension: String, Sendable { case territory, source, device, period }
    public enum Order: String, Sendable { case countDescending = "count-desc", countAscending = "count-asc", nameAscending = "name-asc", nameDescending = "name-desc" }
    public struct Row: Sendable, Identifiable {
        public let key: String, name: String, count: Double, share: Double?
        public var id: String { Data(key.utf8).base64EncodedString() }
    }
    /// The activity days with a saved report against the days a date range asks for. Days without one stay unknown.
    public struct Coverage: Sendable, Equatable {
        public let from, to: String, savedDays, requestedDays: Int
        public var complete: Bool { savedDays == requestedDays }
    }
    /// Coverage of the chosen range, or of the first through the last saved activity day when no range is chosen.
    public static func coverage(_ periods: [AnalyticsPeriod], range: PeriodDateRange? = nil) -> Coverage? {
        var days = Set<Int>()
        for period in periods {
            guard let first = PeriodDates.number(period.date), let last = PeriodDates.number(period.endDate), last >= first, last - first < 400 else { continue }
            days.formUnion(first...last)
        }
        guard let earliest = days.min(), let latest = days.max() else { return nil }
        let from = range.flatMap { PeriodDates.number($0.from) } ?? earliest, to = range.flatMap { PeriodDates.number($0.to) } ?? latest
        guard to >= from else { return nil }
        return Coverage(from: PeriodDates.text(from), to: PeriodDates.text(to), savedDays: days.filter { $0 >= from && $0 <= to }.count, requestedDays: to - from + 1)
    }
    public static func territoryName(_ key: String) -> String { Territories.alpha3.values.contains(key) ? Territories.name(key) : "Unspecified territory" }
    static func add(_ left: Double, _ right: Double) throws -> Double {
        guard right.isFinite, right >= 0, right.rounded() == right, right <= 9_007_199_254_740_991 - left else { throw AnalyticsFailure.format }
        return left + right
    }
    static func validate(_ periods: [AnalyticsPeriod]) throws {
        var keys = Set<String>(), total = 0.0
        for period in periods {
            _ = try AnalyticsMetadata(kind: period.kind, level: period.level, granularity: period.granularity, processingDate: period.processingDate)
            guard ReportTables.validDate(period.date), period.endDate == AnalyticsReports.periodEnd(period.date, granularity: period.granularity),
                  period.endDate <= period.processingDate, period.key == "\(period.kind):\(period.level):\(period.granularity):\(period.date)", keys.insert(period.key).inserted else { throw AnalyticsFailure.format }
            if period.granularity == "MONTHLY", !period.date.hasSuffix("-01") { throw AnalyticsFailure.format }
            if period.granularity == "WEEKLY" {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                guard calendar.component(.weekday, from: ReportTables.dayFormat.date(from: period.date)!) == 2 else { throw AnalyticsFailure.format }
            }
            for fact in period.facts {
                let supported = period.kind == "downloads" ? metrics.prefix(4) : metrics.suffix(4)
                guard supported.contains(fact.metric), [fact.territory, fact.source, fact.device].allSatisfy({ $0.utf16.count <= 10_000 && !ReportTables.controlInCell($0) }) else { throw AnalyticsFailure.format }
                total = try add(total, fact.count)
            }
        }
    }
    /// Literal UTF-8 dimension keys keep canonically equivalent Unicode labels separate.
    public static func summary(_ periods: [AnalyticsPeriod], metric: String) throws -> Summary {
        guard metrics.contains(metric) else { throw AnalyticsFailure.format }; try validate(periods)
        var totals = Dictionary(uniqueKeysWithValues: metrics.map { ($0, 0.0) })
        var territories: [Data: Activity] = [:], sources: [Data: Activity] = [:], devices: [Data: Activity] = [:]
        func append(_ key: String, _ count: Double, to values: inout [Data: Activity]) throws {
            let identity = Data(key.utf8); values[identity] = Activity(key: key, count: try add(values[identity]?.count ?? 0, count), order: values[identity]?.order ?? values.count)
        }
        for period in periods { for fact in period.facts {
            totals[fact.metric] = try add(totals[fact.metric]!, fact.count)
            if fact.metric == metric {
                try append(fact.territory, fact.count, to: &territories); try append(fact.source, fact.count, to: &sources); try append(fact.device, fact.count, to: &devices)
            }
        } }
        func sorted(_ values: [Data: Activity]) -> [Activity] {
            values.values.sorted {
                guard $0.count == $1.count else { return $0.count > $1.count }
                let compared = $0.key.compare($1.key, locale: Locale(identifier: "en"))
                return compared == .orderedSame ? $0.order < $1.order : compared == .orderedAscending
            }
        }
        return Summary(totals: totals, territories: sorted(territories), sources: sorted(sources), devices: sorted(devices))
    }
    public static func periodActivity(_ periods: [AnalyticsPeriod], metric: String) throws -> [Activity] {
        guard metrics.contains(metric) else { throw AnalyticsFailure.format }; try validate(periods)
        return periods.enumerated().map { Activity(key: $0.element.key, count: $0.element.total(metric), order: $0.offset) }
    }
    /// Query matching uses the stored whitespace rules and literal lowercased text, without Unicode normalization.
    public static func breakdown(_ periods: [AnalyticsPeriod], summary: Summary, metric: String, dimension: Dimension, query: String, order: Order) throws -> [Row] {
        guard metrics.contains(metric) else { throw AnalyticsFailure.format }; try validate(periods)
        let values: [Activity]
        switch dimension { case .territory: values = summary.territories; case .source: values = summary.sources; case .device: values = summary.devices; case .period: values = try periodActivity(periods, metric: metric) }
        let names = Dictionary(uniqueKeysWithValues: periods.map { ($0.key, $0.date == $0.endDate ? $0.date : "\($0.date) – \($0.endDate)") })
        let total = summary.totals[metric] ?? 0, search = TextSemantics.trim(query).lowercased()
        return values.map { item in
            let name = dimension == .territory ? territoryName(item.key) : dimension == .period ? names[item.key]! : item.key
            return Row(key: item.key, name: name, count: item.count, share: total > 0 ? item.count / total : nil)
        }.filter { search.isEmpty || ($0.key + " " + $0.name).lowercased().range(of: search, options: .literal) != nil }.sorted {
            let compared = $0.name.compare($1.name, locale: Locale(identifier: "en"))
            switch order {
            case .nameAscending: return compared == .orderedAscending
            case .nameDescending: return compared == .orderedDescending
            case .countAscending: return $0.count == $1.count ? compared == .orderedAscending : $0.count < $1.count
            case .countDescending: return $0.count == $1.count ? compared == .orderedAscending : $0.count > $1.count
            }
        }
    }
    public static func indexed(_ values: [Double]) -> [Double] {
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        return values.map { average == 0 ? 0 : $0 / average * 100 }
    }
    /// One line per selected measure; missing activity intervals break its run and are never filled with zero.
    public static func points(_ periods: [AnalyticsPeriod], metrics chosen: [String], indexed scale: Bool) throws -> [Point] {
        guard !chosen.isEmpty, chosen.count <= 4, Set(chosen).count == chosen.count, chosen.allSatisfy(metrics.contains) else { throw AnalyticsFailure.format }
        try validate(periods)
        guard Set(periods.map { "\($0.kind):\($0.level):\($0.granularity)" }).count <= 1 else { throw AnalyticsFailure.format }
        let ordered = periods.sorted { $0.date < $1.date }, formatter = ReportTables.dayFormat
        var runs: [String] = [], positions: [Date] = [], run = "", last: Date?
        for period in ordered {
            let start = formatter.date(from: period.date)!, end = formatter.date(from: period.endDate)!.addingTimeInterval(86_400)
            if last != start { run = period.key }
            runs.append(run); positions.append(Date(timeIntervalSince1970: (start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2)); last = end
        }
        return chosen.flatMap { metric in
            let values = ordered.map { $0.total(metric) }, scaled = scale ? indexed(values) : values
            return ordered.enumerated().map { index, period in Point(key: period.key, metric: metric, start: period.date, end: period.endDate, run: "\(metric):\(runs[index])", position: positions[index], value: scaled[index]) }
        }
    }
}
