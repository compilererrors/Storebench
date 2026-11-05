import CryptoKit
import Foundation

public enum AnalyticsFailure: Error, Equatable {
    case setup, inactive, reportMissing, period, noInstances, access, segmentsPending, download, integrity, limit, format, segments, scope

    public var message: String {
        switch self {
        case .setup: "Analytics report generation has not been requested for this app. Set up ongoing reports in App Store changes in the Storebench app; Apple normally prepares the first reports within 1–2 days."
        case .inactive: "The checked Analytics requests stopped generating reports after inactivity. Set up ongoing reports in App Store changes to resume generation. Previously saved reports remain available."
        case .reportMissing: "The request exists, but Apple has not listed this report yet. New generation normally takes 1–2 days; existing requests do not need to be recreated."
        case .period: "Reports exist, but their processing dates fall outside the synced period. Processing dates can differ from the activity dates inside a report."
        case .noInstances: "Apple lists this report but has not returned any instances yet. First generation normally takes 1–2 days. Missing reports are not zero activity."
        case .access: "Check the selected app and Analytics API permissions. Admin, Sales and Reports, or Finance can download available reports."
        case .segmentsPending: "Apple lists a report instance but has not returned its files yet. Retry later. Complete report instances downloaded before it were saved."
        case .download: "The Analytics download could not finish. Retry later. Any completed save is kept."
        case .integrity: "Analytics report parts could not be verified. Checksum, size, complete segments and download locations must all match before reports are saved."
        case .limit: "This Analytics download exceeds the supported batch size."
        case .format: "Apple returned an Analytics report Storebench does not support. Saved reports are unchanged."
        case .segments: "An Analytics report instance has duplicate or mismatched segments. Saved reports are unchanged."
        case .scope: "The Analytics report has no rows for this app. Missing rows are not zero activity."
        }
    }
}

/// Apple report tables, read and ordered in a fixed, documented way.
public enum ReportTables {
    static func controlInName(_ text: String) -> Bool { text.utf8.contains { $0 < 32 || $0 == 127 } }
    static func controlInCell(_ text: String) -> Bool { text.utf8.contains { $0 == 127 || ($0 < 32 && $0 != 9 && $0 != 10 && $0 != 13) } }
    static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool { expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }

    static func validate(_ table: ReportTable, rowLimit: Int = 100_000) throws {
        guard !table.columns.isEmpty, table.columns.count <= 100, Set(table.columns.map { Array($0.utf16) }).count == table.columns.count,
              table.columns.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 200 && !controlInName($0) }), table.rows.count <= rowLimit,
              table.rows.allSatisfy({ $0.count == table.columns.count && $0.allSatisfy { $0.utf16.count <= 10_000 && !controlInCell($0) } })
        else { throw AnalyticsFailure.format }
    }

    /// Immutable proof of shape and text validation; only this parser can construct it.
    struct Validated { let table: ReportTable; fileprivate init(_ table: ReportTable) { self.table = table } }
    static func validated(_ table: ReportTable) throws -> Validated { try validate(table); return Validated(table) }
    static func validatedAnalyticsSource(_ table: ReportTable, metadata: AnalyticsMetadata) throws -> Validated {
        try AnalyticsReports.validate(table, metadata)
        return Validated(table)
    }
    static func parseValidated(_ text: String) throws -> Validated { Validated(try parse(text)) }

    /// Apple TXT uses raw tabs, including literal quotation marks inside names; anything else is CSV.
    public static func parse(_ raw: String) throws -> ReportTable { try parse(raw, byteLimit: 8_000_000, rowLimit: 100_000) }
    static func parse(_ raw: String, byteLimit: Int, rowLimit: Int) throws -> ReportTable {
        guard !raw.isEmpty, raw.utf16.count <= byteLimit, !raw.contains("\0") else { throw AnalyticsFailure.format }
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        let firstLine = text.unicodeScalars.prefix { $0 != "\n" }
        let table: ReportTable
        if firstLine.contains("\t") {
            var body = text.replacingOccurrences(of: "\r\n", with: "\n")
            while body.hasSuffix("\n") { body.removeLast() }
            let lines = body.components(separatedBy: "\n")
            guard lines.count <= rowLimit + 1 else { throw AnalyticsFailure.format }
            table = ReportTable(columns: lines[0].components(separatedBy: "\t"), rows: lines.dropFirst().map { $0.components(separatedBy: "\t") })
        } else {
            let parsed = try delimited(text)
            table = ReportTable(columns: parsed.columns.map(unspreadsheet), rows: parsed.rows.map { $0.map(unspreadsheet) })
        }
        try validate(table, rowLimit: rowLimit)
        return table
    }

    /// An Analytics segment: blank lines and empty cells after the last column carry no data and are dropped first.
    static func parseSegment(_ raw: String) throws -> ReportTable {
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        // The same 32 MB bound as an unpacked segment, so a report Apple splits into large segments still reads.
        let (bytes, rows) = (32_000_000, 1_000_000)
        guard text.unicodeScalars.prefix(while: { $0 != "\n" }).contains("\t") else { return try parse(text, byteLimit: bytes, rowLimit: rows) }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { throw AnalyticsFailure.format }
        let width = header.components(separatedBy: "\t").count
        lines = lines.map { line in
            var cells = line.components(separatedBy: "\t")
            while cells.count > width, cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
            return cells.joined(separator: "\t")
        }
        return try parse(lines.joined(separator: "\n"), byteLimit: bytes, rowLimit: rows)
    }

    /// RFC 4180 CSV with doubled quotes.
    static func delimited(_ text: String) throws -> ReportTable {
        do { let table = try Delimited.parse(text); return ReportTable(columns: table.columns, rows: table.rows) }
        catch { throw AnalyticsFailure.format }
    }

    static func spreadsheetFormula(_ value: String) -> Bool { TextSemantics.trim(value).unicodeScalars.first.map { "=+@-".unicodeScalars.contains($0) } ?? false }
    static func spreadsheetCell(_ value: String) -> String { value.hasPrefix("'") || spreadsheetFormula(value) ? "'" + value : value }
    static func unspreadsheet(_ value: String) -> String {
        guard value.hasPrefix("'") else { return value }
        let rest = String(value.dropFirst())
        return rest.hasPrefix("'") || spreadsheetFormula(rest) ? rest : value
    }

    static func literalEqual(_ lhs: ReportTable, _ rhs: ReportTable) -> Bool {
        guard lhs.columns.count == rhs.columns.count, lhs.rows.count == rhs.rows.count else { return false }
        return zip(lhs.columns, rhs.columns).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
            && zip(lhs.rows, rhs.rows).allSatisfy { a, b in a.count == b.count && zip(a, b).allSatisfy { $0.utf8.elementsEqual($1.utf8) } }
    }

    public enum ExportFailure: Error, Equatable { case multiline
        public var message: String { "Use full CSV to preserve the report's multiline or tab-separated fields." }
    }
    public enum TextFormat: Sendable { case csv, txt }
    public static func text(_ table: ReportTable, format: TextFormat) throws -> String {
        try text(validated(table), format: format)
    }
    static func text(_ validated: Validated, format: TextFormat) throws -> String {
        let table = validated.table
        if format == .csv {
            return Delimited.write(Delimited.Table(columns: table.columns.map(spreadsheetCell), rows: table.rows.map { $0.map(spreadsheetCell) }))
        }
        guard table.rows.allSatisfy({ $0.allSatisfy { !$0.contains("\r") && !$0.contains("\n") && !$0.contains("\t") } }) else { throw ExportFailure.multiline }
        return ([table.columns] + table.rows).map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    /// Columns in English collation order, rows by their JSON text in UTF-16 order, like `canonicalReportTable`.
    public static func canonical(_ table: ReportTable) -> ReportTable {
        let english = Locale(identifier: "en")
        let order = table.columns.indices.sorted { table.columns[$0].compare(table.columns[$1], locale: english) == .orderedAscending }
        let rows = table.rows.map { row -> (row: [String], key: [UInt16]) in
            let ordered = order.map { row[$0] }
            return (ordered, Array(JSONText.array(ordered.map { .string($0) }).stringify().utf16))
        }.sorted { $0.key.lexicographicallyPrecedes($1.key) }
        return ReportTable(columns: order.map { table.columns[$0] }, rows: rows.map(\.row))
    }

    static var dayFormat: DateFormatter { let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"; format.timeZone = TimeZone(identifier: "UTC"); format.locale = Locale(identifier: "en_US_POSIX"); return format }

    public static func validDate(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, let date = dayFormat.date(from: value) else { return false }
        return dayFormat.string(from: date) == value
    }
}

public struct AnalyticsMetadata: Equatable, Sendable {
    public let kind: String, level: String, granularity: String, processingDate: String
    public init(kind: String, level: String, granularity: String, processingDate: String) throws {
        guard ["downloads", "engagement"].contains(kind), ["standard", "detailed"].contains(level), ["DAILY", "WEEKLY", "MONTHLY"].contains(granularity),
              ReportTables.validDate(processingDate), !(kind == "downloads" && level == "standard" && granularity != "DAILY") else { throw AnalyticsFailure.format }
        self.kind = kind; self.level = level; self.granularity = granularity; self.processingDate = processingDate
    }
}

/// One saved Analytics report period with its raw rows, stored in `analytics_part` buckets.
public struct AnalyticsPartition: Codable, Equatable, Sendable {
    public let kind: String, level: String, granularity: String, processingDate: String, date: String, importedAt: String
    public let segments: Int
    public let source: ReportTable

    public var key: String { "\(kind):\(level):\(granularity):\(date)" }
    /// One bucket per report type and calendar month of the activity date.
    public var bucket: String { "\(kind):\(level):\(granularity):\(date.prefix(7))" }

    var json: JSONText {
        .object([("kind", .string(kind)), ("level", .string(level)), ("granularity", .string(granularity)), ("processingDate", .string(processingDate)),
                 ("date", .string(date)), ("importedAt", .string(importedAt)), ("segments", .number(Double(segments))),
                 ("source", .object([("columns", .array(source.columns.map { .string($0) })), ("rows", .array(source.rows.map { .array($0.map { .string($0) }) }))]))])
    }
}

public enum AnalyticsReports {
    // The documented columns and values. Files a person imports must match them exactly;
    // live downloads accept new columns and values so a change on Apple's side never stops a sync.
    static let baseColumns = ["Date", "App Name", "App Apple Identifier", "Device", "Platform Version", "Source Type", "Page Type", "Territory", "Counts"]
    static let downloadColumns = ["Download Type", "App Version", "Pre-Order"], engagementColumns = ["Event", "Engagement Type", "Unique Counts"]
    static let detailedColumns = ["Source Info", "Page Title"]
    static let downloadTypes: Set<String> = ["First-time Download", "Redownload", "Manual update", "Auto-update", "Restore"], events: Set<String> = ["Impression", "Page view", "Tap"]
    public static let rowLimit = 5_000_000, segmentLimit = 200

    public static func periodEnd(_ date: String, granularity: String) -> String {
        guard let start = ReportTables.dayFormat.date(from: date) else { return date }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        switch granularity {
        case "WEEKLY": return ReportTables.dayFormat.string(from: start.addingTimeInterval(6 * 86_400))
        case "MONTHLY":
            let next = calendar.date(byAdding: .month, value: 1, to: calendar.date(from: calendar.dateComponents([.year, .month], from: start))!)!
            return ReportTables.dayFormat.string(from: next.addingTimeInterval(-86_400))
        default: return date
        }
    }

    static func count(_ value: String) -> Int? {
        guard (1...15).contains(value.utf8.count), value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(value)
    }
    static func validCount(_ value: String) -> Bool { count(value) != nil }

    /// The columns a report needs to be counted. Apple adds and renames descriptive columns over time;
    /// those are kept when present and never required, so a new report layout still imports.
    static func requiredColumns(kind: String) -> [String] { ["Date", "App Apple Identifier", "Counts", kind == "downloads" ? "Download Type" : "Event"] }

    static func validate(_ table: ReportTable, _ meta: AnalyticsMetadata, strict: Bool = false) throws {
        // Each rejection records the rule it broke, never a value, so the failure can say what was wrong.
        func broken(_ rule: String) -> AnalyticsFailure { ReplyDiagnostics.record(.analytics, rule); return .format }
        guard table.columns.count <= 100, table.rows.count <= rowLimit, Set(table.columns.map { Array($0.utf16) }).count == table.columns.count,
              table.columns.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 200 && !ReportTables.controlInName($0) }) else { throw broken("report header has empty, repeated or too many columns") }
        let missing = requiredColumns(kind: meta.kind).filter { !table.columns.contains($0) }
        guard missing.isEmpty else { throw broken("report has no “\(missing.joined(separator: "”, “"))” column") }
        guard !table.columns.contains(meta.kind == "downloads" ? "Event" : "Download Type") else { throw broken("report columns belong to a different report type") }
        if strict {
            let documented = baseColumns + (meta.kind == "downloads" ? downloadColumns : engagementColumns) + (meta.level == "detailed" ? detailedColumns : [])
            guard documented.allSatisfy(table.columns.contains), !(meta.level == "standard" && (detailedColumns + ["Campaign"]).contains(where: table.columns.contains)) else {
                throw broken("imported file does not have the documented columns for this report")
            }
        }
        let col = { (name: String) in table.columns.firstIndex(of: name)! }
        let date = col("Date"), app = col("App Apple Identifier"), counts = col("Counts")
        let type = meta.kind == "downloads" ? col("Download Type") : col("Event"), unique = meta.kind == "engagement" ? table.columns.firstIndex(of: "Unique Counts") : nil
        var checkedDates = Set<String>()
        let dayFormat = ReportTables.dayFormat
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        for row in table.rows {
            guard row.count == table.columns.count else { throw broken("a row has \(row.count) cells for \(table.columns.count) columns") }
            guard row.allSatisfy({ $0.utf16.count <= 10_000 && !ReportTables.controlInCell($0) }) else { throw broken("a cell is too long or has control characters") }
            let day = row[date]
            if checkedDates.insert(day).inserted {
                guard ReportTables.validDate(day) else { throw broken("a row has a date that is not YYYY-MM-DD") }
                guard day <= meta.processingDate, periodEnd(day, granularity: meta.granularity) <= meta.processingDate else { throw broken("a row is dated after the report's processing date") }
                if meta.granularity == "WEEKLY" { guard calendar.component(.weekday, from: dayFormat.date(from: day)!) == 2 else { throw broken("a weekly row does not start on a Monday") } }
                if meta.granularity == "MONTHLY", !day.hasSuffix("-01") { throw broken("a monthly row does not start on the first day of a month") }
            }
            guard !row[app].isEmpty, row[app].utf8.allSatisfy({ (48...57).contains($0) }) else { throw broken("a row has an App Apple Identifier that is not a number") }
            guard validCount(row[counts]) else { throw broken("a row has a Counts value that is not a whole number") }
            // Known and new download types or events are accepted; values outside the known set count as "other".
            guard !row[type].trimmingCharacters(in: .whitespaces).isEmpty, row[type].utf16.count <= 200 else { throw broken("a row has no \(meta.kind == "downloads" ? "Download Type" : "Event")") }
            if let unique { guard row[unique].isEmpty || validCount(row[unique]) else { throw broken("a row has a Unique Counts value that is not a whole number") } }
            if strict {
                if meta.kind == "downloads" { guard downloadTypes.contains(row[type]) else { throw broken("imported file has an undocumented Download Type") } }
                else { guard events.contains(row[type]), let unique, validCount(row[unique]) else { throw broken("imported file has an undocumented Event or no Unique Counts") } }
            }
        }
    }

    /// All segments of one report instance become one partition per activity date, holding only this app's rows.
    public static func importSegments(_ tables: [ReportTable], meta: AnalyticsMetadata, accountId: String, appId: String, importedAt: String, strict: Bool = false) throws -> [AnalyticsPartition] {
        guard accountId.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil, appId.range(of: #"\A[0-9]+\z"#, options: .regularExpression) != nil,
              ReportTimestamps.valid(importedAt) else { throw AnalyticsFailure.format }
        guard !tables.isEmpty, tables.count <= segmentLimit else { throw AnalyticsFailure.segments }
        var seenTables: [ReportTable] = [], rows: [[String]] = [], columns: [String] = [], total = 0
        for input in tables {
            try validate(input, meta, strict: strict)
            total += input.rows.count
            guard total <= rowLimit else { throw AnalyticsFailure.format }
            let table = ReportTables.canonical(input)
            guard !seenTables.contains(where: { ReportTables.literalEqual($0, table) }) else { throw AnalyticsFailure.segments }
            seenTables.append(table)
            guard columns.isEmpty || (columns.count == table.columns.count && zip(columns, table.columns).allSatisfy { $0.utf8.elementsEqual($1.utf8) }) else { throw AnalyticsFailure.segments }
            columns = table.columns
            let appColumn = columns.firstIndex(of: "App Apple Identifier")!
            rows += table.rows.filter { $0[appColumn] == appId }
        }
        guard !rows.isEmpty else { throw AnalyticsFailure.scope }
        // A dimension tuple is unique within an instance, even across its segments.
        let dimensions = columns.indices.filter { !["Counts", "Unique Counts"].contains(columns[$0]) }, dateColumn = columns.firstIndex(of: "Date")!
        var seen = Set<[Data]>(), dates: [String: [[String]]] = [:]
        for row in rows {
            guard seen.insert(dimensions.map { Data(row[$0].utf8) }).inserted else { throw AnalyticsFailure.segments }
            dates[row[dateColumn], default: []].append(row)
        }
        return dates.keys.sorted().map { date in
            AnalyticsPartition(kind: meta.kind, level: meta.level, granularity: meta.granularity, processingDate: meta.processingDate, date: date,
                               importedAt: importedAt, segments: tables.count, source: tables.count == 1 ? ReportTable(columns: columns, rows: dates[date]!) : ReportTables.canonical(ReportTable(columns: columns, rows: dates[date]!)))
        }
    }

    public struct Changes: Equatable, Sendable { public var added = 0, replaced = 0, unchanged = 0, older = 0 }

    /// A newer processing date replaces a saved period; an older one never does.
    static func merge(_ previous: [AnalyticsPartition], _ incoming: [AnalyticsPartition]) -> (partitions: [AnalyticsPartition], changes: Changes) {
        var partitions = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last }), changes = Changes()
        for item in incoming {
            guard let current = partitions[item.key] else { changes.added += 1; partitions[item.key] = item; continue }
            if item.processingDate < current.processingDate { changes.older += 1 }
            else if item.processingDate == current.processingDate && ReportTables.literalEqual(item.source, current.source) { changes.unchanged += 1 }
            else { changes.replaced += 1; partitions[item.key] = item }
        }
        return (partitions.values.sorted { $0.key < $1.key }, changes)
    }

    static let alpha3Codes = Set(Territories.alpha3.values)

    /// The derived facts kept in `analytics_view`, in a fixed order.
    static func view(_ partitions: [AnalyticsPartition]) throws -> JSONText {
        .array(try partitions.sorted { $0.key < $1.key }.map { item in
            let col = { (name: String) in item.source.columns.firstIndex(of: name) }
            let typeColumn = col("Download Type"), eventColumn = col("Event"), pageColumn = col("Page Type"), engagementColumn = col("Engagement Type")
            let territoryColumn = col("Territory"), sourceColumn = col("Source Type"), deviceColumn = col("Device")
            guard let countColumn = col("Counts"), item.source.rows.allSatisfy({ $0.count == item.source.columns.count }) else { throw AnalyticsFailure.format }
            var order: [(labels: [String], identity: [Data])] = [], counts: [[Data]: Int] = [:]
            for row in item.source.rows {
                let metric: String
                if item.kind == "downloads" {
                    let type = typeColumn.map { row[$0].lowercased() }
                    metric = type == "first-time download" ? "first" : type == "redownload" ? "redownload" : type == "restore" ? "restores"
                        : type == "manual update" || type == "auto-update" ? "updates" : "other"
                } else {
                    let event = eventColumn.map { row[$0] }, page = pageColumn.map { row[$0] }, engagement = engagementColumn.map { row[$0] }
                    let e = event?.lowercased(), p = page?.lowercased(), g = engagement?.lowercased()
                    metric = e == "impression" ? "impressions" : e == "page view" && p == "product page" ? "views" : e == "tap" && g == "get" ? "get" : "other"
                }
                let raw = territoryColumn.map { row[$0] } ?? ""
                let territory = Territories.alpha3[raw] ?? (alpha3Codes.contains(raw) ? raw : "UNKNOWN")
                let source = sourceColumn.map { row[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? "Unavailable"
                let device = deviceColumn.map { row[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? "Unspecified device"
                let key = [territory, source, device, metric]
                let literal = key.map { Data($0.utf8) }
                if counts[literal] == nil { order.append((key, literal)) }
                guard let quantity = Self.count(row[countColumn]) else { throw AnalyticsFailure.format }
                let (sum, overflow) = (counts[literal] ?? 0).addingReportingOverflow(quantity)
                guard !overflow, sum <= 9_007_199_254_740_991 else { throw AnalyticsFailure.format }
                counts[literal] = sum
            }
            let facts = order.map { item in JSONText.object([("territory", .string(item.labels[0])), ("source", .string(item.labels[1])), ("device", .string(item.labels[2])), ("metric", .string(item.labels[3])), ("count", .number(Double(counts[item.identity]!)))]) }
            return .object([("kind", .string(item.kind)), ("level", .string(item.level)), ("granularity", .string(item.granularity)), ("processingDate", .string(item.processingDate)),
                            ("key", .string(item.key)), ("date", .string(item.date)), ("endDate", .string(periodEnd(item.date, granularity: item.granularity))),
                            ("rows", .number(Double(item.source.rows.count))), ("segments", .number(Double(item.segments))), ("facts", .array(facts))])
        })
    }

    /// The report names Apple lists for a kind and detail level; aliases are matched exactly, never by substring.
    static func reportNames(kind: String, level: String) -> [String] {
        let bases = kind == "downloads" ? ["App Downloads", "App Store Downloads"] : ["App Store Discovery and Engagement"]
        return bases.flatMap { level == "detailed" ? ["\($0) Detailed"] : [$0, "\($0) Standard"] }
    }

    /// Apple returns short-lived S3 links for report files. They never receive the Apple bearer token.
    static func segmentURL(_ value: String?) throws -> URL {
        guard let value, value.utf16.count <= 16_000, let url = URLComponents(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil, let host = url.host, host.range(of: #"^[a-z0-9][a-z0-9.-]*\.s3(?:[.-][a-z0-9-]+)?\.amazonaws\.com$"#, options: .regularExpression) != nil,
              url.path.hasPrefix("/reports/"), let result = url.url else { throw AnalyticsFailure.integrity }
        return result
    }
}

extension AppStoreConnectClient {
    /// One Analytics report file from Apple's storage, verified by size and MD5 checksum, without the API token.
    public func segment(_ url: URL, size: Int, checksum: String) async throws -> Data {
        _ = try AnalyticsReports.segmentURL(url.absoluteString)
        guard (1...500_000_000).contains(size), checksum.range(of: #"\A[a-fA-F0-9]{32}\z"#, options: .regularExpression) != nil else { throw AnalyticsFailure.integrity }
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpShouldHandleCookies = false
        let configuration = session.configuration
        configuration.httpAdditionalHeaders = [:]; configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let data: Data
        do {
            data = try await BoundedResponse.read(request, configuration: configuration, maximumBytes: size) { http in
                guard http.statusCode == 200 else { throw AnalyticsFailure.download }
                if let length = http.value(forHTTPHeaderField: "Content-Length"), Int(length) != size { throw AnalyticsFailure.integrity }
            }.data
        } catch BoundedResponse.Failure.tooLarge { throw AnalyticsFailure.integrity }
        guard data.count == size, Insecure.MD5.hash(data: data).map({ String(format: "%02x", $0) }).joined() == checksum.lowercased() else { throw AnalyticsFailure.integrity }
        return data
    }
}

public struct AnalyticsSyncResult: Equatable, Sendable {
    public var instances = 0, noAppInstances = 0
    public var reusedInstances = 0
    public var unavailableDays: [String] = []
    public var changes = AnalyticsReports.Changes()
}

extension WorkspaceSession {
    static func analyticsId(_ value: String) -> Bool { AnalyticsCatalog.id(value) }

    /// A list whose IDs are unique and safe, and bounded in size.
    static func analyticsList(_ client: AppStoreConnectClient, _ path: String, limit: Int) async throws -> [AppStoreConnectClient.Resource] {
        let rows: [AppStoreConnectClient.Resource]
        do { rows = try await client.list(path) } catch AppStoreConnectClient.Failure.invalidPagination { throw AnalyticsFailure.integrity }
        catch AppStoreConnectClient.Failure.paginationLimit { throw AnalyticsFailure.limit }
        guard rows.allSatisfy({ analyticsId($0.id) }), Set(rows.map(\.id)).count == rows.count else { throw AnalyticsFailure.integrity }
        guard rows.count <= limit else { throw AnalyticsFailure.limit }
        return rows
    }

    /// The processing days a sync asks for: the chosen reach first, then back to the oldest gap after saved reports.
    public func analyticsSyncDays(accountId: String, appId: String, kind: String, now: Date = Date()) throws -> [String] {
        let reach = try periodPreferences().syncReach
        let end = ReportTables.dayFormat.string(from: now)
        let processed = Set(try analytics(accountId: accountId, appId: appId).filter { $0.kind == kind && $0.level == "standard" && $0.granularity == "DAILY" }.map(\.processingDate))
        return SalesReports.days(ending: end, count: SyncFreshness.catchUpDays(saved: processed, end: end, first: reach, maximum: max(7, reach)))
    }

    /// Downloads the selected existing Analytics report instances, newest first, and saves complete instances.
    func downloadAnalyticsBody(account: Account, appId: String, kind: String, processingDays: [String], client: AppStoreConnectClient, now: Date,
                               level: String, granularity: String, requestId: String?, incremental: Bool = false, check: @escaping () throws -> Void,
                               progress: (AnalyticsDownloadJob.Phase, Int, Int, Int, Int) throws -> Void) async throws -> AnalyticsSyncResult {
        try check()
        var revision = try storeAccess { try PartitionedReports.revision(family: "analytics", accountId: account.id, appId: appId, store: $0) }
        let before = try storeAccess { try PartitionedReports.fingerprints(AnalyticsPartition.self, family: "analytics", legacyKey: "partitions", accountId: account.id, appId: appId, store: $0, bucketOf: \.bucket, encode: \.json) }
        let previousLocal = SyncReceipt.analyticsLocal(before, kind: kind, level: level, granularity: granularity)
        var latestLocal = previousLocal, fresh: [SyncReceipt] = [], checkedKeys: Set<String> = []
        let receipts = incremental ? syncReceipts(accountId: account.id, appId: appId)?.entries : nil
        let (catalog, instances) = try await analyticsDiscovery(account: account, appId: appId, kind: kind, processingDays: processingDays,
            client: client, level: level, granularity: granularity, requestId: requestId, now: now)
        if let failure = catalog.availability.failure { throw failure }
        let availableDays = Set(instances.map(\.processingDate))
        var result = AnalyticsSyncResult(instances: instances.count,
            unavailableDays: processingDays.filter { !availableDays.contains($0) }.sorted()), pending: [AnalyticsPartition] = [], expanded = 0
        let importedAt = CustomerReview.isoString(now)
        var completed = 0, segments = 0, downloaded = 0
        try check(); try progress(.downloading, instances.count, 0, 0, 0)
        // Complete instances are saved in portions, so a long download never holds everything in memory and keeps what finished.
        func flush() throws {
            guard !pending.isEmpty else { return }
            let incoming = pending; pending = []
            var changes = AnalyticsReports.Changes()
            try storeAccess { store in
                try PartitionedReports.replaceAll(AnalyticsPartition.self, family: "analytics", legacyKey: "partitions", accountId: account.id, appId: appId, store: store,
                                                  stateDirectory: store.directory, bucketOf: \.bucket, encode: \.json,
                                                  view: (1, { try AnalyticsReports.view($0) }), expected: revision,
                                                  validate: { try self.analyticsFileScope(account, appId: appId); try check() }, committed: { revision = $0 },
                                                  committedBuckets: { latestLocal = SyncReceipt.analyticsLocal($0, kind: kind, level: level, granularity: granularity) }) { previous, _ in
                    try check(); try self.analyticsFileScope(account, appId: appId)
                    try self.analyticsLegacyScope(accountId: account.id, appId: appId, store: store)
                    let old = try AnalyticsFileFormats.normalize(previous ?? [], accountId: account.id, appId: appId)
                    let merged = AnalyticsReports.merge(old, incoming)
                    try AnalyticsFileFormats.check(merged.partitions)
                    changes = merged.changes
                    return (merged.partitions, nil)
                }
            }
            result.changes.added += changes.added; result.changes.replaced += changes.replaced; result.changes.unchanged += changes.unchanged; result.changes.older += changes.older
        }
        do {
            for instance in instances.sorted(by: { $0.processingDate > $1.processingDate }) {
                try check()
                let resources = try await analyticsCheckedList(account: account, appId: appId, client: client, path: "/v1/analyticsReportInstances/\(instance.id)/segments?limit=200", limit: 200)
                guard !resources.isEmpty else { throw AnalyticsFailure.segmentsPending }
                let manifest = try resources.map { item -> (id: String, url: URL, size: Int, checksum: String) in
                    guard item.type == "analyticsReportSegments", case .number(let raw)? = item.attributes?["sizeInBytes"], let size = Int(exactly: raw), (1...500_000_000).contains(size),
                          let checksum = item.attributes?["checksum"]?.string, checksum.range(of: #"\A[a-fA-F0-9]{32}\z"#, options: .regularExpression) != nil else { throw AnalyticsFailure.integrity }
                    return (item.id, try AnalyticsReports.segmentURL(item.attributes?["url"]?.string), size, checksum.lowercased())
                }
                let key = SyncReceipt.analyticsKey(kind: kind, level: level, granularity: granularity, instance: instance.id, processingDate: instance.processingDate)
                let remote = JSONText.array(manifest.sorted { $0.id.compare($1.id, locale: Locale(identifier: "en_US")) == .orderedAscending }.map { .array([.string($0.id), .number(Double($0.size)), .string($0.checksum)]) }).sha256
                checkedKeys.insert(key)
                if let receipt = receipts?.first(where: { $0.key == key }), receipt.remote == remote, receipt.local == previousLocal, receipt.outcome != .unavailable {
                    if receipt.outcome == .noApp { result.noAppInstances += 1 } else { result.reusedInstances += 1 }
                    completed += 1; segments += manifest.count
                    try progress(.downloading, instances.count, completed, segments, downloaded); continue
                }
                var tables: [ReportTable] = []
                for (_, url, size, checksum) in manifest {
                    try check(); try analyticsFileScope(account, appId: appId)
                    let bytes = try await client.segment(url, size: size, checksum: checksum)
                    try check(); try analyticsFileScope(account, appId: appId)
                    downloaded += bytes.count; segments += 1
                    try progress(.downloading, instances.count, completed, segments, downloaded)
                    guard bytes.count > 2, bytes[bytes.startIndex] == 0x1f, bytes[bytes.startIndex + 1] == 0x8b else { throw AnalyticsFailure.integrity }
                    let decoded: Data
                    do { decoded = try ReportFiles.unpack(bytes, limit: 32_000_000) }
                    catch ReportFiles.Failure.size { throw AnalyticsFailure.limit }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw AnalyticsFailure.integrity }
                    expanded += decoded.count
                    let text: String
                    do { text = try ReportFiles.utf8(decoded, stripBom: true) } catch { throw AnalyticsFailure.integrity }
                    do { tables.append(try ReportTables.parseSegment(text)) }
                    catch AnalyticsFailure.format { ReplyDiagnostics.record(.analytics, "report segment is not a readable tab-separated table"); throw AnalyticsFailure.format }
                }
                let meta = try AnalyticsMetadata(kind: kind, level: level, granularity: granularity, processingDate: instance.processingDate)
                // An activity day in several instances keeps the newest processing date, as the saved merge does.
                let noAppBefore = result.noAppInstances
                do { pending = AnalyticsReports.merge(pending, try AnalyticsReports.importSegments(tables, meta: meta, accountId: account.id, appId: appId, importedAt: importedAt)).partitions }
                catch AnalyticsFailure.scope { result.noAppInstances += 1 }
                fresh.append(SyncReceipt(key: key, remote: remote, local: previousLocal, checkedAt: CustomerReview.isoString(Date()), outcome: result.noAppInstances > noAppBefore ? .noApp : .withApp))
                completed += 1; try progress(.downloading, instances.count, completed, segments, downloaded)
                if expanded >= 64_000_000 { try flush(); expanded = 0 }
            }
        } catch {
            try? flush()
            throw error
        }
        try progress(.saving, instances.count, completed, segments, downloaded); try check(); try flush()
        try check(); try analyticsFileScope(account, appId: appId)
        guard try storeAccess({ try PartitionedReports.revision(family: "analytics", accountId: account.id, appId: appId, store: $0) }) == revision else { throw AnalyticsFileFailure.stale }
        let freshKeys = Set(fresh.map(\.key)), retained = (receipts ?? []).filter { checkedKeys.contains($0.key) && $0.local == previousLocal && !freshKeys.contains($0.key) }
        rememberSyncReceipts(account: account, appId: appId, entries: (retained + fresh).map { $0.binding(local: latestLocal) })
        return result
    }
}
