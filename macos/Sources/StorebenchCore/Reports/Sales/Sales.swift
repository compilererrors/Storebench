import Foundation
import zlib

/// Fixed validation messages from the Summary Sales parser; never values from a report.
public enum SalesFailure: Error, Equatable {
    case validation(String), conflict, appNotFound(begin: String, end: String, verifiedScope: Bool), decode, period, size, unavailable, noConnection, changedConnection
    public var message: String {
        switch self {
        case .validation(let text): text
        case .conflict: "This report overlaps an imported period. Remove the overlapping period or import that exact period again to replace it."
        case .appNotFound: "No rows for this app were found. Choose a full report covering this app and period."
        case .decode: "The downloaded report could not be unpacked or read. Retry this day."
        case .period: "Apple returned a report for a different period than the requested day. Retry this day. Existing reports are unchanged."
        case .size: "The downloaded report exceeds 8 MB."
        case .unavailable: "Apple has no report for the requested days yet. Missing reports are not zero sales."
        case .noConnection: "Connect Sales in the Storebench app first: a vendor number with a Team API key, or Reporter."
        case .changedConnection: "The reporting account or vendor changed after credentials were captured. Read the current connection and explicitly retry the download."
        }
    }
}

public struct ReportTable: Codable, Equatable, Sendable { public let columns: [String]; public let rows: [[String]] }
public struct ProductScope: Codable, Equatable, Sendable { public let ids: [String]; public let complete: Bool }

/// One saved Summary Sales period with everything that is kept, encoded in a fixed field order.
public struct SalesRecord: Decodable, Sendable {
    public let accountId: String, appId: String
    public let appSku: String?
    public let productScope: ProductScope?
    public let beginDate: String, endDate: String, importedAt: String
    public let unitsByTerritory: [String: Int]
    public let source: ReportTable?
    public let noSales: Bool?

    var json: JSONText {
        var fields: [(String, JSONText)] = [("schemaVersion", .number(1)), ("accountId", .string(accountId)), ("appId", .string(appId))]
        if let appSku { fields.append(("appSku", .string(appSku))) }
        if let productScope { fields.append(("productScope", .object([("ids", .array(productScope.ids.map { .string($0) })), ("complete", .bool(productScope.complete))]))) }
        fields += [("beginDate", .string(beginDate)), ("endDate", .string(endDate)), ("importedAt", .string(importedAt)),
                   ("unitsByTerritory", .object(unitsByTerritory.sorted { $0.key < $1.key }.map { ($0.key, .number(Double($0.value))) }))]
        if let source { fields.append(("source", .object([("columns", .array(source.columns.map { .string($0) })), ("rows", .array(source.rows.map { .array($0.map { .string($0) }) }))]))) }
        if noSales == true { fields.append(("noSales", .bool(true))) }
        return .object(fields)
    }
    var period: String { "\(beginDate):\(endDate)" }

    /// Apple confirmed that this app had no sales on the day; no report rows are invented.
    static func noSalesDay(accountId: String, appId: String, day: String, importedAt: String) -> SalesRecord {
        SalesRecord(accountId: accountId, appId: appId, appSku: nil, productScope: nil, beginDate: day, endDate: day, importedAt: importedAt, unitsByTerritory: [:], source: nil, noSales: true)
    }
}

public enum SalesReports {
    static let appPurchaseTypes: Set<String> = ["1", "1E", "1EP", "1EU", "1F", "1T", "F1"]
    static let inAppTypes: Set<String> = ["FI1", "IA1", "IA1-M", "IA9", "IA9-M", "IAY", "IAY-M", "IA3", "IAC", "IAC-M"]

    /// Expands a gzip download (at most `limit` bytes, 8 MB for sales) or returns plain bytes.
    static func gunzip(_ data: Data, limit: Int = 8_000_000) throws -> Data {
        guard data.count > 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return data }
        var stream = z_stream(), output = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw SalesFailure.decode }
        defer { inflateEnd(&stream) }
        var input = [UInt8](data)
        let status: Int32 = input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress; stream.avail_in = uInt(source.count)
            var result = Z_OK
            while result == Z_OK {
                result = buffer.withUnsafeMutableBufferPointer { target in
                    stream.next_out = target.baseAddress; stream.avail_out = uInt(target.count)
                    let code = inflate(&stream, Z_NO_FLUSH)
                    output.append(target.baseAddress!, count: target.count - Int(stream.avail_out))
                    return code
                }
                if output.count > limit { return Z_BUF_ERROR }
            }
            return result
        }
        guard status == Z_STREAM_END else { throw output.count > limit ? SalesFailure.size : SalesFailure.decode }
        return output
    }

    static func reportDate(_ text: String) throws -> String {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 2, parts[1].count == 2, parts[2].count == 4, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let month = Int(parts[0]), let day = Int(parts[1]), let year = Int(parts[2]),
              let date = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: year, month: month, day: day)),
              Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).day == day
        else { throw SalesFailure.validation("The sales report has an invalid date. Apple Summary Sales dates must use MM/DD/YYYY.") }
        return "\(parts[2])-\(parts[0])-\(parts[1])"
    }

    /// Reads raw Apple TXT or CSV, preserving quotation marks and whitespace inside report cells.
    static func table(_ text: String) throws -> ReportTable {
        if !(text.components(separatedBy: "\n").first ?? "").contains("\t") {
            do { let parsed = try Delimited.parse(text); return ReportTable(columns: parsed.columns, rows: parsed.rows) }
            catch { throw SalesFailure.validation("The sales report contains a malformed CSV row or header. Use an unedited Summary Sales Report from Apple.") }
        }
        var body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        while body.hasSuffix("\r") || body.hasSuffix("\n") { body.removeLast() }
        var lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let columns = lines.removeFirst().components(separatedBy: "\t")
        // A row may end with empty cells beyond the header; only those are trimmed, so no value moves column.
        let rows = lines.filter { !TextSemantics.trim($0).isEmpty }.map { line -> [String] in
            var cells = line.components(separatedBy: "\t")
            while cells.count > columns.count, cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
            return cells
        }
        guard text.utf16.count <= 8_000_000, !text.contains("\0"), rows.count <= 100_000, columns.count <= 100, columns.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 200 }),
              Set(columns.map { Array($0.utf16) }).count == columns.count, rows.allSatisfy({ $0.count == columns.count }) else {
            throw SalesFailure.validation("The sales report contains a malformed row or header. Use an unedited Summary Sales Report from Apple.")
        }
        return ReportTable(columns: columns, rows: rows)
    }

    /// The summary rules: only this app's purchases and its verified in-app products count.
    static func summary(_ table: ReportTable, appId: String, accountId: String, importedAt: String, appSku: String?, scope: ProductScope?, legacy: Bool = false) throws -> SalesRecord {
        guard !table.rows.isEmpty else { throw SalesFailure.validation("The downloaded report has no data rows. Retry when Apple has made the Summary Sales Report available.") }
        let names = ["Apple Identifier", "Product Type Identifier", "Units", "Country Code", "Customer Price", "Begin Date", "End Date"]
        let positions = names.map { table.columns.firstIndex(of: $0) }
        guard positions.allSatisfy({ $0 != nil }) else { throw SalesFailure.validation("This file is not an Apple Summary Sales Report with the required columns.") }
        let p = positions.map { $0! }, (appCol, typeCol, unitsCol, countryCol, priceCol, beginCol, endCol) = (p[0], p[1], p[2], p[3], p[4], p[5], p[6])
        let parentCol = table.columns.firstIndex(of: "Parent Identifier"), owned = Set(scope?.ids ?? [])
        var period: String?, rows: [[String]] = [], units: [String: Int] = [:], complete = scope?.complete
        for cells in table.rows {
            let dates = "\(try reportDate(cells[beginCol])):\(try reportDate(cells[endCol]))"
            if let period, period != dates { throw SalesFailure.validation("The report contains mixed dates. Import one report period at a time.") }
            period = dates
            let type = cells[typeCol], inApp = inAppTypes.contains(type), product = cells[appCol]
            let parentMatches = appSku != nil && parentCol != nil && cells[parentCol!] == appSku, known = owned.contains(product)
            if known && !inApp { throw SalesFailure.validation("An app product uses an unrecognized product type. Review this report before including its proceeds.") }
            if known, appSku != nil, let parentCol, !cells[parentCol].isEmpty, !parentMatches { throw SalesFailure.validation("An app product has a different parent SKU. Verify the app information and reporting account before retrying.") }
            let ownedInApp = inApp && (known || legacy && parentMatches)
            if scope != nil, parentMatches, !known, product != appId { complete = false }
            if product != appId && !ownedInApp { continue }
            if inApp && !ownedInApp { throw SalesFailure.validation("An in-app purchase has no verified app-owned product ID. Refresh the app's product catalog and retry.") }
            guard product.allSatisfy(\.isNumber), !product.isEmpty else { throw SalesFailure.validation("The sales report has an invalid Apple identifier.") }
            rows.append(cells)
            let priceText = cells[priceCol], unitsText = cells[unitsCol]
            guard priceText.range(of: #"^-?(?:\d+(?:\.\d+)?|\.\d+)$"#, options: .regularExpression) != nil, let price = Double(priceText), price.isFinite else { throw SalesFailure.validation("The sales report has an invalid customer price.") }
            guard unitsText.range(of: #"^-?\d+(?:\.0{1,2})?$"#, options: .regularExpression) != nil, let count = Double(unitsText), abs(count) <= 9_007_199_254_740_991, let whole = Int(exactly: count) else {
                throw SalesFailure.validation("The sales report has an invalid or fractional unit count. Whole app units are required; no values were rounded.")
            }
            if price <= 0 || whole <= 0 { continue }
            if !appPurchaseTypes.contains(type) && !inApp { throw SalesFailure.validation("A paid transaction uses an unrecognized product type. Review this report before filtering countries.") }
            guard let code = Territories.alpha3[cells[countryCol]] else { throw SalesFailure.validation("A paid transaction has an unknown country code. Review this report before filtering countries.") }
            if inApp { continue }
            let total = units[code, default: 0] + whole
            guard total <= 9_007_199_254_740_991 else { throw SalesFailure.validation("The sales report has too many units for one country.") }
            units[code] = total
        }
        guard let period else { throw SalesFailure.validation("The report contains no reporting period.") }
        let dates = period.split(separator: ":").map(String.init)
        guard dates[0] <= dates[1] else { throw SalesFailure.validation("The report period is invalid.") }
        guard !rows.isEmpty else { throw SalesFailure.appNotFound(begin: dates[0], end: dates[1], verifiedScope: complete == true) }
        let normalizedScope = scope.map { ProductScope(ids: $0.ids.sorted(), complete: complete ?? $0.complete) }
        return SalesRecord(accountId: accountId, appId: appId, appSku: appSku, productScope: normalizedScope, beginDate: dates[0], endDate: dates[1], importedAt: importedAt,
                           unitsByTerritory: units, source: ReportTable(columns: table.columns, rows: rows), noSales: nil)
    }

    /// A daily download: a report for exactly that day, Apple's verified "no sales", or nil when no row can be attributed.
    public static func parseDay(_ bytes: Data, appId: String, accountId: String, day: String, importedAt: String, appSku: String?, scope: ProductScope?) throws -> SalesRecord? {
        // Reports arrive gzip compressed; Apple can also send the same text uncompressed.
        let raw: Data
        do { raw = ReporterClient.isGzip(bytes) ? try gunzip(bytes) : bytes }
        catch SalesFailure.decode { ReplyDiagnostics.record(.salesReport, "gzip data that could not be decompressed"); throw SalesFailure.decode }
        guard raw.count <= 8_000_000 else { throw SalesFailure.size }
        guard let text = String(data: raw, encoding: .utf8) else { ReplyDiagnostics.record(.salesReport, "report text that is not UTF-8"); throw SalesFailure.decode }
        do { return try parsedDay(text, appId: appId, accountId: accountId, day: day, importedAt: importedAt, appSku: appSku, scope: scope) }
        catch SalesFailure.validation(let rule) { ReplyDiagnostics.record(.salesReport, rule); throw SalesFailure.validation(rule) }
    }

    private static func parsedDay(_ text: String, appId: String, accountId: String, day: String, importedAt: String, appSku: String?, scope: ProductScope?) throws -> SalesRecord? {
        do {
            let record = try summary(try table(text), appId: appId, accountId: accountId, importedAt: importedAt, appSku: appSku, scope: scope)
            guard record.beginDate == day, record.endDate == day else { throw SalesFailure.period }
            return record
        } catch SalesFailure.appNotFound(let begin, let end, let verified) {
            guard begin == day, end == day else { throw SalesFailure.period }
            return verified ? .noSalesDay(accountId: accountId, appId: appId, day: day, importedAt: importedAt) : nil
        }
    }

    /// Row and column order do not change a report; a richer saved report is kept when the content matches.
    static func same(_ previous: SalesRecord, _ incoming: SalesRecord) -> Bool {
        guard previous.accountId == incoming.accountId, previous.appId == incoming.appId, previous.period == incoming.period, previous.unitsByTerritory == incoming.unitsByTerritory else { return false }
        guard let source = incoming.source else { return true }
        if let sku = incoming.appSku, previous.appSku != sku { return false }
        if let scope = incoming.productScope, previous.productScope.map({ ProductScope(ids: $0.ids.sorted(), complete: $0.complete) }) != ProductScope(ids: scope.ids.sorted(), complete: scope.complete) { return false }
        guard let saved = previous.source else { return false }
        func canonical(_ table: ReportTable) -> [String] {
            let order = table.columns.enumerated().sorted { $0.element.compare($1.element, locale: Locale(identifier: "en")) == .orderedAscending }
            let rows = table.rows.map { row in JSONText.array(order.map { .string(row[$0.offset]) }).stringify() }
                .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return [JSONText.array(order.map { .string($0.element) }).stringify()] + rows
        }
        return canonical(saved).map { Array($0.utf16) } == canonical(source).map { Array($0.utf16) }
    }

    public struct Changes: Equatable, Sendable { public var added = 0, updated = 0, unchanged = 0 }

    /// Adds new periods and replaces changed ones. "No sales" never replaces saved sales, and overlapping periods are refused.
    static func merge(_ existing: [SalesRecord], _ incoming: [SalesRecord]) throws -> (records: [SalesRecord], changes: Changes) {
        var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.period, $0) }), changes = Changes()
        for report in incoming {
            let previous = merged[report.period]
            if report.noSales == true, let previous, previous.noSales != true { changes.unchanged += 1; continue }
            if let previous, let source = previous.source, !same(previous, report) {
                let owned = Set(previous.productScope?.ids ?? []), incomingIds = Set(report.productScope?.ids ?? [])
                let typeCol = source.columns.firstIndex(of: "Product Type Identifier"), idCol = source.columns.firstIndex(of: "Apple Identifier")
                if let typeCol, let idCol, source.rows.contains(where: { owned.contains($0[idCol]) && inAppTypes.contains($0[typeCol]) && (report.productScope?.complete != true || !incomingIds.contains($0[idCol])) }) {
                    throw SalesFailure.validation("The product catalog is incomplete. Previously verified in-app purchase reports are kept. Restore product access and download this period again.")
                }
            }
            if previous == nil { changes.added += 1; merged[report.period] = report }
            else if same(previous!, report) { changes.unchanged += 1 }
            else { changes.updated += 1; merged[report.period] = report }
        }
        let combined = merged.values.sorted { $0.beginDate < $1.beginDate }
        for index in combined.indices.dropFirst() where combined[index - 1].endDate >= combined[index].beginDate { throw SalesFailure.conflict }
        return (combined, changes)
    }

    /// The latest day Apple can have completed, as a calendar label in Pacific Time.
    public static func latestCompletedDay(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let label = utc.date(from: today)!.addingTimeInterval(-86_400)
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"; format.timeZone = TimeZone(identifier: "UTC")
        return format.string(from: label)
    }

    public static func days(ending end: String, count: Int) -> [String] {
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"; format.timeZone = TimeZone(identifier: "UTC")
        guard let last = format.date(from: end), (1...365).contains(count) else { return [] }
        return (0..<count).reversed().map { format.string(from: last.addingTimeInterval(-Double($0) * 86_400)) }
    }
}

/// How many recent days a sync downloads, from the catch-up window and the days already saved.
public enum SyncFreshness {
    static var dayFormat: DateFormatter { let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"; format.timeZone = TimeZone(identifier: "UTC"); format.locale = Locale(identifier: "en_US_POSIX"); return format }

    public static func catchUpDays(saved: Set<String>, end: String, minimum: Int = 7, first: Int = 30, maximum: Int = 90) -> Int {
        guard let earliest = saved.min() else { return first }
        guard let endDate = dayFormat.date(from: end) else { return minimum }
        guard maximum - 1 >= minimum else { return minimum }
        for back in stride(from: maximum - 1, through: minimum, by: -1) {
            let day = dayFormat.string(from: endDate.addingTimeInterval(-Double(back) * 86_400))
            if day > earliest && !saved.contains(day) { return back + 1 }
        }
        return minimum
    }

    /// Days covered by saved reports, limited to 400 days before `end`; the earliest saved day is always kept.
    public static func savedSalesDays(_ reports: [(beginDate: String, endDate: String)], end: String) -> Set<String> {
        guard let endDate = dayFormat.date(from: end) else { return [] }
        let floor = endDate.addingTimeInterval(-400 * 86_400)
        var days = Set<String>()
        for report in reports {
            guard let begin = dayFormat.date(from: report.beginDate), let last = dayFormat.date(from: report.endDate) else { continue }
            days.insert(report.beginDate)
            var time = max(begin, floor)
            while time <= last { days.insert(dayFormat.string(from: time)); time = time.addingTimeInterval(86_400) }
        }
        return days
    }
}
