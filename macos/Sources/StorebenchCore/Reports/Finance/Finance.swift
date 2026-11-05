import Foundation

public enum FinanceFailure: Error, Equatable {
    case request, access, download, period, format, scope, overlap, stale, expiredReview, size, noConnection

    public var message: String {
        switch self {
        case .request: "Choose an Apple fiscal period and report region. Fiscal periods are not calendar months."
        case .access: "Check Finance reporting permissions and the selected vendor. Use your connected Reporter token, or a Team API key with Finance access."
        case .download: "The financial download could not finish. Retry later. Saved financial history is unchanged."
        case .period: "The returned financial periods are incomplete, in the future or repeated for different requests. Nothing was added to financial history."
        case .format: "Apple returned a financial report Storebench does not support. Saved financial history is unchanged."
        case .scope: "The report has no supported direct app transactions for this app. In-app products and subscriptions need their own verified app mapping."
        case .overlap: "Financial reports overlap in the same dataset. Remove the conflicting report or download the exact period and region again."
        case .stale: "The saved financial reports changed after this review. Read saved reports and explicitly review again before saving."
        case .expiredReview: "This financial download review expired. Download the reports again and compare them before saving."
        case .size: "The financial download exceeds the supported size. Choose fewer fiscal periods."
        case .noConnection: "Connect Sales and Finance in the Storebench app first: a vendor number with a Team API key, or Reporter."
        }
    }
}

/// One saved financial report: a fiscal period for one region, with this app's direct transactions.
public struct FinancialReport: Codable, Equatable, Sendable {
    public let beginDate: String, endDate: String, region: String, basis: String, importedAt: String
    public let source: ReportTable
    public var key: String { "\(beginDate):\(endDate):\(region)" }

    var json: JSONText {
        .object([("beginDate", .string(beginDate)), ("endDate", .string(endDate)), ("region", .string(region)), ("basis", .string(basis)), ("importedAt", .string(importedAt)),
                 ("source", .object([("columns", .array(source.columns.map { .string($0) })), ("rows", .array(source.rows.map { .array($0.map { .string($0) }) }))]))])
    }
}

public struct FiscalPeriod: Equatable, Hashable, Sendable {
    public let year: Int, period: Int
    public init(year: Int, period: Int) { self.year = year; self.period = period }
    public var key: String { "\(year)-\(period < 10 ? "0" : "")\(period)" }
}

public enum FinancialReports {
    public static let regions = ["US", "AU", "BR", "BG", "CA", "CL", "CN", "CO", "CZ", "HR", "DK", "EG", "HK", "HU", "IN", "ID", "IL", "JP", "KZ", "KR", "MY", "MX", "NZ", "NG", "NO", "PK", "PE", "PH", "PL", "QA", "RO", "RU", "SA", "SG", "ZA", "SE", "CH", "TW", "TH", "TR", "AE", "GB", "TZ", "VN", "EU", "LL", "AP", "WW"]
    public static let downloadRegions = ["ZZ", "Z1"] + regions
    static let appTypes: Set<String> = ["1", "1E", "1EP", "1EU", "1F", "1T", "F1", "3", "3F", "7", "7F", "7T", "F7"]
    static let purchases: Set<String> = ["1", "1E", "1EP", "1EU", "1F", "1T", "F1"]
    static let required = ["Start Date", "End Date", "Quantity", "Partner Share", "Extended Partner Share", "Partner Share Currency", "Apple Identifier", "Product Type Identifier", "Country of Sale", "Customer Price", "Customer Currency"]
    public static let maximumPeriods = 24
    private static let amountPattern = try! NSRegularExpression(pattern: #"^-?(?:\d{1,15}(?:\.\d{1,6})?|\.\d{1,6})$"#)
    private static let quantityPattern = try! NSRegularExpression(pattern: #"^-?\d{1,12}$"#)
    private static let currencyPattern = try! NSRegularExpression(pattern: "^[A-Z]{3}$")

    public static func regionName(_ region: String) -> String {
        let special = ["ALL": "All countries or regions (summary / detailed)", "ZZ": "All countries · summary", "Z1": "All countries · detailed", "EU": "Euro-Zone", "LL": "Latin America and the Caribbean", "AP": "South Asia and Pacific", "WW": "Rest of World"]
        return special[region] ?? Locale(identifier: "en_US").localizedString(forRegionCode: region) ?? region
    }

    static func money(_ text: String) -> Decimal? {
        guard ReportTables.matches(amountPattern, text) else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    struct NotFound: Error {}

    /// This app's direct transactions from one Apple financial report, validated before it is used.
    public static func fromTable(_ table: ReportTable, scope: String, appId: String, importedAt: String) throws -> FinancialReport {
        let validated: ReportTables.Validated
        do { validated = try ReportTables.validated(table) } catch { throw FinanceFailure.format }
        return try fromValidatedTable(validated, scope: scope, appId: appId, importedAt: importedAt)
    }

    static func fromValidatedTable(_ validated: ReportTables.Validated, scope: String, appId: String, importedAt: String) throws -> FinancialReport {
        let table = validated.table
        do {
            guard appId.range(of: #"\A[0-9]+\z"#, options: .regularExpression) != nil, ReportTimestamps.valid(importedAt), !table.rows.isEmpty, required.allSatisfy(table.columns.contains) else { throw FinanceFailure.format }
            let detailed = table.columns.contains("Settlement Date") || table.columns.contains("Transaction Date")
            let region = scope == "ALL" ? (detailed ? "Z1" : "ZZ") : scope
            if detailed { guard region == "Z1", table.columns.contains("Settlement Date"), table.columns.contains("Transaction Date") else { throw FinanceFailure.format } }
            else { guard region == "ZZ" || regions.contains(region) else { throw FinanceFailure.format } }
            guard table.columns.contains("Sale or Return") else { throw FinanceFailure.format }
            let col = { (name: String) in table.columns.firstIndex(of: name)! }
            let positions = (start: col("Start Date"), end: col("End Date"), product: col("Apple Identifier"), type: col("Product Type Identifier"),
                             quantity: col("Quantity"), share: col("Partner Share"), amount: col("Extended Partner Share"),
                             currency: col("Partner Share Currency"), price: col("Customer Price"), customerCurrency: col("Customer Currency"),
                             country: col("Country of Sale"), sale: col("Sale or Return"))
            let settlementIndex = detailed ? col("Settlement Date") : 0, transactionIndex = detailed ? col("Transaction Date") : 0
            var beginDate = "", endDate = "", firstBegin = "", firstEnd = "", units = 0, rows: [[String]] = []
            let dayFormat = ReportTables.dayFormat
            for row in table.rows {
                if beginDate.isEmpty {
                    firstBegin = row[positions.start]; firstEnd = row[positions.end]
                    beginDate = try SalesReports.reportDate(firstBegin); endDate = try SalesReports.reportDate(firstEnd)
                    guard beginDate <= endDate, let first = dayFormat.date(from: beginDate), let last = dayFormat.date(from: endDate),
                          last.timeIntervalSince(first) <= 40 * 86_400 else { throw FinanceFailure.format }
                } else {
                    guard row[positions.start].utf8.elementsEqual(firstBegin.utf8), row[positions.end].utf8.elementsEqual(firstEnd.utf8) else { throw FinanceFailure.format }
                }
                let begin = beginDate, end = endDate
                let product = row[positions.product]
                guard !product.isEmpty, product.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw FinanceFailure.format }
                guard product == appId else { continue }
                // Child product IDs are not proof of parent-app ownership; never attribute them by name.
                guard appTypes.contains(row[positions.type]) else { throw FinanceFailure.scope }
                let quantityText = row[positions.quantity]
                guard ReportTables.matches(quantityPattern, quantityText), let quantity = Int(quantityText),
                      let share = money(row[positions.share]), let amount = money(row[positions.amount]), money(row[positions.price]) != nil, share >= 0,
                      ReportTables.matches(currencyPattern, row[positions.currency]),
                      ReportTables.matches(currencyPattern, row[positions.customerCurrency]), Territories.alpha3[row[positions.country]] != nil else { throw FinanceFailure.format }
                // Preserve Apple's reported amount. A rounded per-unit share is not a replacement for it.
                let product_ = share * Decimal(quantity), difference = amount - product_
                let tolerance = Decimal(abs(quantity)) * Decimal(string: "0.01")! + Decimal(string: "0.01")!
                guard !(quantity > 0 && amount < 0), !(quantity < 0 && amount > 0), !(quantity == 0 && amount != 0), (difference < 0 ? -difference : difference) <= tolerance else { throw FinanceFailure.format }
                let sale = row[positions.sale]
                guard sale == "S" || sale == "R", !(sale == "S" && quantity < 0), !(sale == "R" && quantity > 0) else { throw FinanceFailure.format }
                if detailed {
                    let settlement = try SalesReports.reportDate(row[settlementIndex]), transaction = row[transactionIndex]
                    guard settlement >= begin, settlement <= end else { throw FinanceFailure.format }
                    if !transaction.isEmpty { guard try SalesReports.reportDate(transaction) <= settlement else { throw FinanceFailure.format } }
                }
                units += abs(quantity)
                guard units <= 9_007_199_254_740_991 else { throw FinanceFailure.format }
                rows.append(row)
            }
            guard !rows.isEmpty else { throw NotFound() }
            let source = ReportTables.canonical(ReportTable(columns: table.columns, rows: rows))
            // Exact duplicated source rows would otherwise silently inflate amounts.
            guard !zip(source.rows, source.rows.dropFirst()).contains(where: { a, b in zip(a, b).allSatisfy { $0.utf8.elementsEqual($1.utf8) } }) else { throw FinanceFailure.overlap }
            return FinancialReport(beginDate: beginDate, endDate: endDate, region: region, basis: region == "ZZ" ? "consolidated" : region == "Z1" ? "detailed" : "regional", importedAt: importedAt, source: source)
        } catch let error as FinanceFailure where error == .scope || error == .overlap { throw error }
        catch let error as NotFound { throw error }
        catch { throw FinanceFailure.format }
    }

    /// Full reports cannot overlap each other. Regional files may share dates, but never the same country and currency.
    static func check(_ reports: [FinancialReport]) throws {
        var scopes: [String: [(String, String)]] = [:]
        var units = 0
        for report in reports {
            let col = { (name: String) in report.source.columns.firstIndex(of: name)! }
            for row in report.source.rows {
                guard let count = Int(row[col("Quantity")]), count != Int.min, abs(count) <= 9_007_199_254_740_991 - units else { throw FinanceFailure.format }
                units += abs(count)
            }
            let pairs = Set(report.source.rows.map { "\($0[col("Country of Sale")]):\($0[col("Partner Share Currency")])" })
            let keys = report.basis == "regional" ? pairs.sorted().map { "regional:\($0)" } + ["region:\(report.region)"] : [report.basis]
            for key in keys {
                if scopes[key, default: []].contains(where: { $0.0 <= report.endDate && report.beginDate <= $0.1 }) { throw FinanceFailure.overlap }
                scopes[key, default: []].append((report.beginDate, report.endDate))
            }
        }
    }

    public struct Change: Equatable, Sendable, Identifiable { public let key: String, label: String, action: String, before: String, after: String; public var id: String { key } }

    static func decimalText(_ value: Decimal) -> String {
        var text = NSDecimalNumber(decimal: value).stringValue
        let places = text.split(separator: ".").dropFirst().first?.count ?? 0
        if places == 0 { text += "." }
        return text + String(repeating: "0", count: max(0, 2 - places))
    }

    static func summary(_ report: FinancialReport) -> String {
        let col = { (name: String) in report.source.columns.firstIndex(of: name)! }
        var sold = 0, returned = 0, amounts: [String: Decimal] = [:]
        for row in report.source.rows {
            let units = Int(row[col("Quantity")]) ?? 0
            if units > 0 { sold += units } else { returned -= units }
            amounts[row[col("Partner Share Currency")], default: 0] += money(row[col("Extended Partner Share")]) ?? 0
        }
        return "\(sold.formatted(.number.locale(Locale(identifier: "en_US")))) sale units · \(returned.formatted(.number.locale(Locale(identifier: "en_US")))) returned units\n"
            + amounts.sorted { $0.key < $1.key }.map { "\(decimalText($0.value)) \($0.key)" }.joined(separator: " · ")
    }

    /// Adds new periods and replaces changed ones; the whole history is checked for overlap.
    static func merge(_ previous: [FinancialReport], _ incoming: [FinancialReport]) throws -> (reports: [FinancialReport], changes: [Change]) {
        try check(incoming.sorted { $0.key < $1.key })
        var reports = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last }), changes: [Change] = []
        for report in incoming.sorted(by: { $0.key < $1.key }) {
            let current = reports[report.key], action = current == nil ? "added" : ReportTables.literalEqual(current!.source, report.source) ? "unchanged" : "replaced"
            changes.append(Change(key: report.key, label: "\(report.beginDate) – \(report.endDate) · \(regionName(report.region))", action: action,
                                  before: current.map(summary) ?? "No saved report", after: summary(report)))
            if action != "unchanged" { reports[report.key] = report }
        }
        let merged = reports.values.sorted { $0.key < $1.key }
        try check(merged)
        return (merged, changes)
    }

    /// Apple's most recent fiscal period whose report is likely published: the period of the month that ended about five weeks ago.
    public static func latestClosedPeriod(now: Date = Date()) -> FiscalPeriod {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: now.addingTimeInterval(-35 * 86_400))
        return parts.month! >= 10 ? FiscalPeriod(year: parts.year! + 1, period: parts.month! - 9) : FiscalPeriod(year: parts.year!, period: parts.month! + 3)
    }

    public static func periods(ending end: FiscalPeriod, count: Int) -> [FiscalPeriod] {
        (0..<count).map { index in
            let value = end.year * 12 + end.period - count + index
            return FiscalPeriod(year: value / 12, period: value % 12 + 1)
        }
    }

    /// Paid, returned and other units with reported proceeds per country.
    public struct Fact: Sendable, Identifiable { public let territory: String; public var paid = 0, returned = 0, other = 0; public var proceeds: [String: Decimal] = [:]; public var id: String { territory }; public init(territory: String) { self.territory = territory } }

    public static func facts(_ report: FinancialReport) -> [Fact] {
        let col = { (name: String) in report.source.columns.firstIndex(of: name)! }
        var order: [String] = [], groups: [String: Fact] = [:]
        for row in report.source.rows {
            let territory = Territories.alpha3[row[col("Country of Sale")]] ?? "UNKNOWN"
            if groups[territory] == nil { order.append(territory); groups[territory] = Fact(territory: territory) }
            let quantity = Int(row[col("Quantity")]) ?? 0, price = money(row[col("Customer Price")]) ?? 0
            if purchases.contains(row[col("Product Type Identifier")]) && price != 0 { if quantity > 0 { groups[territory]!.paid += quantity } else { groups[territory]!.returned -= quantity } }
            else { groups[territory]!.other += quantity }
            groups[territory]!.proceeds[row[col("Partner Share Currency")], default: 0] += money(row[col("Extended Partner Share")]) ?? 0
        }
        return order.map { groups[$0]! }
    }
}

/// A download held for the explicit local review before anything is saved.
public struct FinancialDownload: Sendable {
    public let id: UUID
    public let accountId: String, appId: String, region: String
    public let reports: [FinancialReport]
    public let noApp: [String], unavailable: [String]
    public let changes: [FinancialReports.Change]
    let revision: PartitionedReports.Revision
    let account: Account
    let expiresAt: Date
    var selection: FinancialDownloadSelection? = nil
    var retainedFingerprint: String? = nil
}

extension WorkspaceSession {
    public func financialReports(accountId: String, appId: String) throws -> [FinancialReport] {
        try storeAccess { try financialStoredReports(accountId: accountId, appId: appId, store: $0) }
    }

    /// Downloads fiscal periods for one region and prepares the review. Nothing is saved until `saveFinancial`.
    func downloadFinancialBody(account: Account, appId: String, region: String, periods: [FiscalPeriod], client: AppStoreConnectClient?, reporter: ReporterClient?, source: ReportingSource, now: Date,
                               reviewId: UUID, check: () throws -> Void, progress: (FinancialDownloadJob.Phase, Int, Int) throws -> Void) async throws -> FinancialDownload {
        guard account.appIds.contains(appId), FinancialReports.downloadRegions.contains(region), (1...FinancialReports.maximumPeriods).contains(periods.count),
              periods.allSatisfy({ (1...12).contains($0.period) && (2001...9999).contains($0.year) }) else { throw FinanceFailure.request }
        try check(); _ = try currentAccount(account, client: client)
        let captured: SalesConnection?
        do { captured = try capturedSalesConnection(accountId: account.id, reporter: reporter, source: source) }
        catch SalesFailure.changedConnection { throw FinanceFailure.access }
        guard let connection = captured else { throw FinanceFailure.noConnection }
        let selection = try FinancialDownloadSelection(source: connection.reporter == nil ? .api : .reporter, periods: periods, region: region)
        let byteLimit = Int((Double(periods.count) / 12).rounded(.up)) * 10_000_000
        let today = ReportTables.dayFormat.string(from: now), importedAt = CustomerReview.isoString(now)
        var reports: [FinancialReport] = [], noApp: [String] = [], unavailable: [String] = [], bytes = 0, expanded = 0

        let download: (FiscalPeriod) async throws -> Data?
        if let reporterConnection = connection.reporter {
            guard let reporter else { throw FinanceFailure.noConnection }
            let vendor = reporterConnection.vendorNumber
            // ZZ is Apple's consolidated option and may not be listed beside each regional report.
            guard let access = try await reporter.financeVendors(account: reporterConnection.accountNumber).first(where: { $0.number == vendor }), !access.regions.isEmpty,
                  region == "ZZ" || access.regions.contains(region) else { throw FinanceFailure.access }
            download = { period in
                switch try await reporter.financialReport(account: reporterConnection.accountNumber, vendor: vendor, region: region, year: period.year, period: period.period) {
                case .report(let data): return data
                case .noSales, .unavailable: return nil
                }
            }
        } else {
            guard let client, account.keyType == "team", connection.vendorNumber.range(of: #"^\d{6,20}$"#, options: .regularExpression) != nil else { throw FinanceFailure.access }
            download = { period in
                let query = "filter%5BvendorNumber%5D=\(connection.vendorNumber)&filter%5BregionCode%5D=\(region)&filter%5BreportType%5D=\(region == "Z1" ? "FINANCE_DETAIL" : "FINANCIAL")&filter%5BreportDate%5D=\(period.key)"
                do { return try await client.download("/v1/financeReports?\(query)", maxBytes: byteLimit) } catch AppStoreConnectClient.Failure.status(404) { return nil }
            }
        }
        for (index, period) in periods.enumerated() {
            try Task.checkCancellation(); try check()
            guard let data = try await download(period) else {
                try check(); unavailable.append(period.key); try progress(.downloading, index + 1, bytes); continue
            }
            try check()
            bytes += data.count
            guard bytes <= byteLimit else { throw FinanceFailure.size }
            // Gzip and plain tab-separated reports are both unpacked; the parser validates the columns.
            guard data.count > 2 else { throw FinanceFailure.format }
            let decoded: Data
            do { decoded = try ReportFiles.unpack(data, limit: byteLimit) }
            catch ReportFiles.Failure.size { throw FinanceFailure.size }
            catch is CancellationError { throw CancellationError() }
            catch { throw FinanceFailure.format }
            expanded += decoded.count
            guard expanded <= byteLimit else { throw FinanceFailure.size }
            let text: String
            do { text = try ReportFiles.utf8(decoded, stripBom: true) } catch { throw FinanceFailure.format }
            let table: ReportTables.Validated
            do { table = try ReportTables.parseValidated(text) } catch { throw FinanceFailure.format }
            do {
                let report = try FinancialReports.fromValidatedTable(table, scope: region, appId: appId, importedAt: importedAt)
                guard report.endDate < today, !reports.contains(where: { $0.beginDate == report.beginDate && $0.endDate == report.endDate }) else { throw FinanceFailure.period }
                reports.append(report)
            } catch is FinancialReports.NotFound { noApp.append(period.key) }
            try progress(.downloading, index + 1, bytes)
        }
        try check(); try progress(.preparing, periods.count, bytes)
        let saved = try financialFileSnapshot(account: account, appId: appId)
        let changes = reports.isEmpty ? [] : try FinancialReports.merge(saved.reports, reports).changes
        try check()
        return FinancialDownload(id: reviewId, accountId: account.id, appId: appId, region: region, reports: reports, noApp: noApp, unavailable: unavailable, changes: changes, revision: saved.revision, account: account, expiresAt: Date().addingTimeInterval(24 * 3600), selection: selection)
    }

    /// Saves a reviewed download onto exactly the history it was reviewed against.
    public func saveFinancial(_ download: FinancialDownload) throws -> [FinancialReports.Change] {
        try financialFileScope(download.account, appId: download.appId); try Task.checkCancellation()
        guard download.expiresAt > Date() else { throw FinanceFailure.expiredReview }
        guard !download.reports.isEmpty else { return [] }
        var changes: [FinancialReports.Change] = []
        do {
            try FileMutex.withLock(financialReviewMutex(accountId: download.accountId, appId: download.appId)) {
                try storeAccess { store in
                    try PartitionedReports.replaceAll(FinancialReport.self, family: "financial", legacyKey: "reports", accountId: download.accountId, appId: download.appId, store: store,
                                                      stateDirectory: store.directory, bucketOf: { String($0.beginDate.prefix(4)) }, encode: \.json, expected: download.revision,
                                                      validate: {
                                                          try self.financialFileScope(download.account, appId: download.appId); try Task.checkCancellation()
                                                          guard download.expiresAt > Date() else { throw FinanceFailure.expiredReview }
                                                          if download.retainedFingerprint != nil { _ = try self.retainedFinancialRecord(download, store: store) }
                                                      }, additionalWrites: {
                                                          let key = "\(download.accountId):\(download.appId)"
                                                          guard let pending = try store.document(namespace: "financial_pending", key: key) else { return [] }
                                                          guard let id = try JSONText.parse(pending.payload)["id"]?.text, ReportJobs.uuid(id) else { throw FinancialFileFailure.storage }
                                                          return id == download.id.uuidString.lowercased() ? [.delete(namespace: "financial_pending", key: key)] : []
                                                      }) { previous, _ in
                        let old = try FinancialFileFormats.normalize(previous ?? [], appId: download.appId)
                        let incoming = try FinancialFileFormats.normalize(download.reports, appId: download.appId)
                        let merged = try FinancialReports.merge(old, incoming)
                        changes = merged.changes
                        return (merged.reports, nil)
                    }
                }
            }
        } catch PartitionedReports.Failure.stale { throw FinanceFailure.stale }
        return changes
    }

    /// The fiscal periods a sync downloads: Apple's latest likely published periods covering the chosen sync reach.
    public func financialSyncPeriods(now: Date = Date()) throws -> [FiscalPeriod] {
        let reach = try periodPreferences().syncReach
        return FinancialReports.periods(ending: FinancialReports.latestClosedPeriod(now: now), count: min(FinancialReports.maximumPeriods, max(1, Int((Double(reach) / 30).rounded(.up)))))
    }
}
