import Foundation

public enum PeriodFailure: Error, Equatable { case invalid }

public struct PeriodScope: Equatable, Sendable {
    public let accountId, appId: String
    public init(accountId: String, appId: String) throws {
        guard (try? RecoveryGuidance.Scope(accountId: accountId, appId: appId)) != nil else { throw PeriodFailure.invalid }
        self.accountId = accountId; self.appId = appId
    }
}

public enum PeriodKey: String, CaseIterable, Sendable {
    case asoCompare = "aso-progress.compare", asoProgressRange = "aso-progress.range", asoDiffRange = "aso-diff.range"
    case analyticsRange = "analytics.range", salesRange = "sales.range", salesDownload = "sales.download"
    case analyticsDownload = "analytics.download", financePeriods = "finance.periods", noSalesDays = "no-sales.days"
    public var isRange: Bool { [.asoProgressRange, .asoDiffRange, .analyticsRange, .salesRange].contains(self) }
    public var maximum: Int { self == .financePeriods ? 24 : 365 }
}

/// Gregorian UTC reporting dates, including year zero.
public enum PeriodDates {
    public static func number(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }) else { return nil }
        func digits(_ start: Int, _ end: Int) -> Int { bytes[start..<end].reduce(0) { $0 * 10 + Int($1 - 48) } }
        var year = digits(0, 4)
        let month = digits(5, 7), day = digits(8, 10)
        guard (1...12).contains(month) else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        guard (1...([31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1])).contains(day) else { return nil }
        year -= month <= 2 ? 1 : 0
        let era = (year >= 0 ? year : year - 399) / 400, within = year - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        return era * 146097 + within * 365 + within / 4 - within / 100 + dayOfYear - 719468
    }
    public static func date(_ text: String) -> Date? { number(text).map { Date(timeIntervalSince1970: Double($0) * 86_400) } }
    public static func text(_ number: Int) -> String {
        let shifted = number + 719468, era = (shifted >= 0 ? shifted : shifted - 146096) / 146097
        let within = shifted - era * 146097
        let yearWithin = (within - within / 1460 + within / 36524 - within / 146096) / 365
        var year = yearWithin + era * 400
        let dayOfYear = within - (365 * yearWithin + yearWithin / 4 - yearWithin / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1, month = monthIndex + (monthIndex < 10 ? 3 : -9)
        year += month <= 2 ? 1 : 0
        let yearText = (0...9999).contains(year) ? String(format: "%04d", year) : String(format: "%@%06d", year < 0 ? "-" : "+", abs(year))
        return String(format: "%@-%02d-%02d", yearText, month, day)
    }
    public static func text(_ date: Date) -> String { text(Int(floor(date.timeIntervalSince1970 / 86_400))) }
}

public struct PeriodDateRange: Equatable, Sendable {
    public let from, to: String
    public init(from: String, to: String) throws {
        guard PeriodDates.number(from) != nil, PeriodDates.number(to) != nil, from <= to else { throw PeriodFailure.invalid }
        self.from = from; self.to = to
    }
    // The resolver keeps the first ten ISO characters even when a window crosses year zero.
    private init(resolvedFrom: String, to: String) { from = resolvedFrom; self.to = to }
    public func contains(_ begin: String, end: String? = nil) -> Bool { begin >= from && (end ?? begin) <= to }
    public var json: JSONText { .object([("from", .string(from)), ("to", .string(to))]) }
    fileprivate static func latest(_ days: Int, ending: String) throws -> Self {
        guard let day = PeriodDates.number(ending), (1...365).contains(days) else { throw PeriodFailure.invalid }
        return Self(resolvedFrom: String(PeriodDates.text(day - days + 1).prefix(10)), to: ending)
    }
}

public enum PeriodRangeChoice: Equatable, Sendable {
    /// Every saved date, the latest number of days, the calendar year of the newest saved date so far, or fixed dates.
    case all, latest(Int), year, custom(PeriodDateRange)
    public init(_ value: JSONText) throws {
        switch value["kind"]?.text {
        case "all": self = .all
        case "latest": self = .latest(try PeriodValue.days(value["days"], maximum: 365))
        case "year": self = .year
        case "custom": self = .custom(try PeriodDateRange(from: value["from"]?.text ?? "", to: value["to"]?.text ?? ""))
        default: throw PeriodFailure.invalid
        }
    }
    public var json: JSONText {
        switch self {
        case .all: .object([("kind", .string("all"))])
        case .latest(let days): .object([("kind", .string("latest")), ("days", .number(Double(days)))])
        case .year: .object([("kind", .string("year"))])
        case .custom(let range): .object([("kind", .string("custom")), ("from", .string(range.from)), ("to", .string(range.to))])
        }
    }
    public func resolve(latest: String) throws -> PeriodDateRange? {
        guard !latest.isEmpty else { return nil }
        switch self {
        case .all: return nil
        case .custom(let range): return range
        case .latest(let days): return try .latest(days, ending: latest)
        case .year: return try PeriodDateRange(from: String(latest.prefix(4)) + "-01-01", to: latest)
        }
    }
    public static func choice(_ range: PeriodDateRange?, latest: String) -> Self {
        guard let range else { return .all }
        if range.to == latest, let first = PeriodDates.number(range.from), let last = PeriodDates.number(range.to), (1...365).contains(last - first + 1) { return .latest(last - first + 1) }
        return .custom(range)
    }
}

public enum PeriodValue: Equatable, Sendable {
    case days(Int), range(PeriodRangeChoice)
    static func days(_ value: JSONText?, maximum: Int) throws -> Int {
        guard case .number(let number)? = value, number.isFinite, number.rounded() == number, number >= 1, number <= Double(maximum) else { throw PeriodFailure.invalid }
        return Int(number)
    }
    public init(key: PeriodKey, value: JSONText) throws {
        self = key.isRange ? .range(try PeriodRangeChoice(value)) : .days(try Self.days(value, maximum: key.maximum))
    }
    public var json: JSONText { switch self { case .days(let days): .number(Double(days)); case .range(let range): range.json } }
}

public struct PeriodPreferences: Equatable, Sendable {
    public let remember: Bool, compareDays: Int, downloadDays: Int, defaultRange: PeriodRangeChoice, syncDays: Int?
    private struct Entry: Equatable, Sendable { let key: PeriodKey, value: PeriodValue }
    private let entries: [Entry]
    private struct Scoped: Equatable, Sendable { let scope: PeriodScope, entries: [Entry] }
    private let scoped: [Scoped]
    public init() { remember = true; compareDays = 7; downloadDays = 7; defaultRange = .all; syncDays = nil; entries = []; scoped = [] }
    public init(_ value: JSONText) throws {
        guard value["schemaVersion"] == .number(1), case .bool(let remember)? = value["remember"],
              let defaults = value["defaults"], case .object(let saved)? = value["remembered"] else { throw PeriodFailure.invalid }
        self.remember = remember
        compareDays = try PeriodValue.days(defaults["compareDays"], maximum: 365)
        downloadDays = try PeriodValue.days(defaults["downloadDays"], maximum: 365)
        syncDays = try defaults["syncDays"].map { try PeriodValue.days($0, maximum: 365) }
        defaultRange = try PeriodRangeChoice(defaults["range"] ?? .null)
        entries = saved.compactMap { name, raw in
            guard let key = PeriodKey(rawValue: name), let entry = try? PeriodValue(key: key, value: raw) else { return nil }
            return Entry(key: key, value: entry)
        }
        if let raw = value["scoped"] {
            guard case .array(let scopes) = raw, scopes.count <= 128 else { throw PeriodFailure.invalid }
            var normalized: [Scoped] = []
            for item in scopes {
                let scope = try PeriodScope(accountId: item["accountId"]?.text ?? "", appId: item["appId"]?.text ?? "")
                guard !normalized.contains(where: { $0.scope == scope }), case .object(let values)? = item["remembered"] else { throw PeriodFailure.invalid }
                let entries = values.compactMap { name, raw -> Entry? in
                    guard let key = PeriodKey(rawValue: name), let value = try? PeriodValue(key: key, value: raw) else { return nil }
                    return Entry(key: key, value: value)
                }
                normalized.append(Scoped(scope: scope, entries: entries))
            }
            scoped = normalized
        } else { scoped = [] }
    }
    public var rememberedCount: Int { entries.count + scoped.reduce(0) { $0 + $1.entries.count } }
    public var syncReach: Int { syncDays ?? 30 }
    public var json: JSONText {
        var defaults: [(String, JSONText)] = [("compareDays", .number(Double(compareDays))), ("downloadDays", .number(Double(downloadDays))), ("range", defaultRange.json)]
        if let syncDays { defaults.append(("syncDays", .number(Double(syncDays)))) }
        var fields: [(String, JSONText)] = [("schemaVersion", .number(1)), ("remember", .bool(remember)), ("defaults", .object(defaults)), ("remembered", .object(entries.map { ($0.key.rawValue, $0.value.json) }))]
        if !scoped.isEmpty { fields.append(("scoped", .array(scoped.map { .object([("accountId", .string($0.scope.accountId)), ("appId", .string($0.scope.appId)), ("remembered", .object($0.entries.map { ($0.key.rawValue, $0.value.json) }))]) }))) }
        return .object(fields)
    }
    public func value(_ key: PeriodKey, scope: PeriodScope? = nil) -> PeriodValue {
        let available = scope.map { scope in scoped.first { $0.scope == scope }?.entries ?? [] } ?? entries
        if remember, let entry = available.last(where: { $0.key == key }) { return entry.value }
        if key.isRange { return .range(defaultRange) }
        return .days(key == .asoCompare ? compareDays : key == .financePeriods ? 1 : key == .noSalesDays ? 30 : downloadDays)
    }
    public func days(_ key: PeriodKey) throws -> Int { guard case .days(let days) = value(key) else { throw PeriodFailure.invalid }; return days }
    public func range(_ key: PeriodKey) throws -> PeriodRangeChoice { guard case .range(let range) = value(key) else { throw PeriodFailure.invalid }; return range }
    public func remembering(_ key: PeriodKey, value: PeriodValue, scope: PeriodScope? = nil) throws -> Self {
        let normalized = try PeriodValue(key: key, value: value.json)
        guard remember else { return self }
        if let scope {
            var next = scoped.filter { $0.scope != scope }
            var values = scoped.first { $0.scope == scope }?.entries.filter { $0.key != key } ?? []
            values.append(Entry(key: key, value: normalized)); next.append(Scoped(scope: scope, entries: values))
            let raw = next.suffix(128).map { item in JSONText.object([("accountId", .string(item.scope.accountId)), ("appId", .string(item.scope.appId)), ("remembered", .object(item.entries.map { ($0.key.rawValue, $0.value.json) }))]) }
            return try Self(json.setting("scoped", .array(raw)))
        }
        return try Self(json.setting("remembered", (json["remembered"] ?? .object([])).setting(key.rawValue, normalized.json)))
    }
    public func changingDefaults(remember: Bool, compareDays: Int, downloadDays: Int, range: PeriodRangeChoice, syncDays: Int? = nil) throws -> Self {
        var defaults: [(String, JSONText)] = [("compareDays", .number(Double(compareDays))), ("downloadDays", .number(Double(downloadDays))), ("range", range.json)]
        if let reach = syncDays ?? self.syncDays { defaults.append(("syncDays", .number(Double(reach)))) }
        return try Self(json.setting("remember", .bool(remember)).setting("defaults", .object(defaults)).setting("remembered", remember ? json["remembered"]! : .object([])).setting("scoped", remember ? json["scoped"] ?? .array([]) : .array([])))
    }
    public func forgetting() throws -> Self { try Self(json.setting("remembered", .object([])).setting("scoped", .array([]))) }
    public func syncing(_ days: Int) throws -> Self { try Self(json.setting("defaults", json["defaults"]!.setting("syncDays", .number(Double(days))))) }
}

extension WorkspaceSession {
    public func periodPreferences() throws -> PeriodPreferences {
        try storeAccess { store in try store.document(namespace: "period_preferences", key: "current").map { try PeriodPreferences(JSONText.parse($0.payload)) } ?? PeriodPreferences() }
    }
    private func updatePeriods(_ change: (PeriodPreferences) throws -> PeriodPreferences) throws -> PeriodPreferences {
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("period_preferences.mutex")) {
                var result = PeriodPreferences()
                try store.transaction { current in
                    let previous = try current("period_preferences", "current").map { try PeriodPreferences(JSONText.parse($0.payload)) } ?? PeriodPreferences()
                    result = try change(previous)
                    return [.put(namespace: "period_preferences", key: "current", json: result.json.data)]
                }
                return result
            }
        }
    }
    @discardableResult public func rememberPeriod(_ key: PeriodKey, value: PeriodValue, scope: PeriodScope? = nil) throws -> PeriodPreferences {
        _ = try PeriodValue(key: key, value: value.json)
        return try updatePeriods { try $0.remembering(key, value: value, scope: scope) }
    }
    @discardableResult public func savePeriodDefaults(remember: Bool, compareDays: Int, downloadDays: Int, range: PeriodRangeChoice, syncDays: Int? = nil) throws -> PeriodPreferences {
        _ = try PeriodPreferences().changingDefaults(remember: remember, compareDays: compareDays, downloadDays: downloadDays, range: range, syncDays: syncDays)
        return try updatePeriods { try $0.changingDefaults(remember: remember, compareDays: compareDays, downloadDays: downloadDays, range: range, syncDays: syncDays) }
    }
    @discardableResult public func forgetPeriods() throws -> PeriodPreferences { try updatePeriods { try $0.forgetting() } }
    public func syncDays() throws -> Int? { try periodPreferences().syncDays }
    public func setSyncDays(_ days: Int) throws { _ = try updatePeriods { try $0.syncing(days) } }
}
