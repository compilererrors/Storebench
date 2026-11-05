import Foundation

public enum SalesFileFailure: Error, Equatable {
    case format, scope, missing, source, multiline, storage
    public var message: String {
        switch self {
        case .format: "Choose an Apple Summary Sales Report or a Storebench CSV for this app."
        case .scope: "This report belongs to another app or the app is no longer connected to this account."
        case .missing: "The report period is no longer available. Read the saved periods and retry."
        case .source: "The source report is unavailable. Export the CSV summary, or reimport the Apple report to retain its rows."
        case .multiline: "This report has edited multiline fields. Export full CSV to preserve them."
        case .storage: "Saved sales reports could not be read or saved locally. Check disk space and local storage access."
        }
    }
}

/// Sales file formats shared by Sales and Pricing. Summary CSV never creates Apple's explicit no-sales marker.
public enum SalesFileFormats {
    public enum Format: String, CaseIterable, Sendable { case summary, originalCsv, originalTxt, originalGzip }
    static let columns = ["app_id", "begin_date", "end_date", "territory", "paid_units"]
    static let maximumUnits = 9_007_199_254_740_991

    static func selection(accountId: String, appId: String) throws {
        guard accountId.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil,
              appId.range(of: #"\A[0-9]+\z"#, options: .regularExpression) != nil else { throw SalesFileFailure.scope }
    }

    public static func parse(_ content: String, accountId: String, appId: String, importedAt: String, appSku: String? = nil, productScope: ProductScope? = nil) throws -> [SalesRecord] {
        try selection(accountId: accountId, appId: appId)
        let table = try SalesReports.table(content)
        if table.columns.contains("Apple Identifier") {
            let report = try SalesReports.summary(table, appId: appId, accountId: accountId, importedAt: importedAt, appSku: appSku, scope: productScope)
            try validate([report], accountId: accountId, appId: appId); return [report]
        }
        let rows: [[String: String]]
        do { rows = try Delimited.records(Delimited.Table(columns: table.columns, rows: table.rows), expected: columns) }
        catch { throw SalesFileFailure.format }
        var periods: [String: (begin: String, end: String, units: [String: Int])] = [:], seen = Set<String>()
        for row in rows {
            guard row["app_id"] == appId else { throw SalesFileFailure.scope }
            let begin = row["begin_date"]!, end = row["end_date"]!, territory = row["territory"]!, amount = row["paid_units"]!
            guard amount.range(of: #"\A(0|[1-9][0-9]*)\z"#, options: .regularExpression) != nil, let count = Int(amount), count <= maximumUnits,
                  territory.isEmpty ? amount == "0" : territory.range(of: #"\A[A-Z]{3}\z"#, options: .regularExpression) != nil else { throw SalesFileFailure.format }
            let key = "\(begin):\(end)"
            guard seen.insert("\(key):\(territory)").inserted else { throw SalesFileFailure.format }
            var period = periods[key] ?? (begin, end, [:])
            if !territory.isEmpty { period.units[territory] = count }
            periods[key] = period
        }
        let result = periods.values.map { SalesRecord(accountId: accountId, appId: appId, appSku: nil, productScope: nil, beginDate: $0.begin, endDate: $0.end, importedAt: importedAt, unitsByTerritory: $0.units, source: nil, noSales: nil) }
            .sorted { $0.beginDate < $1.beginDate }
        try validate(result, accountId: accountId, appId: appId); return result
    }

    /// Check stored and incoming histories before a file operation. Never export or merge foreign or damaged rows.
    public static func validate(_ records: [SalesRecord], accountId: String, appId: String) throws {
        try selection(accountId: accountId, appId: appId)
        var total = 0
        let ordered = records.sorted { $0.beginDate < $1.beginDate }
        for (index, record) in ordered.enumerated() {
            guard record.accountId == accountId, record.appId == appId else { throw SalesFileFailure.scope }
            guard ReportTables.validDate(record.beginDate), ReportTables.validDate(record.endDate), record.beginDate <= record.endDate,
                  (try? CustomerReview.isoDate(record.importedAt)) != nil else { throw SalesFileFailure.format }
            if index > 0, ordered[index - 1].endDate >= record.beginDate { throw SalesFailure.conflict }
            for (code, units) in record.unitsByTerritory {
                guard code.range(of: #"\A[A-Z]{3}\z"#, options: .regularExpression) != nil, units >= 0, units <= maximumUnits - total else { throw SalesFileFailure.format }
                total += units
            }
            if let noSales = record.noSales {
                guard noSales, record.beginDate == record.endDate, record.unitsByTerritory.isEmpty, record.source == nil, record.appSku == nil, record.productScope == nil else { throw SalesFileFailure.format }
            }
            if let sku = record.appSku {
                guard record.source != nil, sku.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z"#, options: .regularExpression) != nil else { throw SalesFileFailure.format }
            }
            if let scope = record.productScope {
                guard record.source != nil, scope.ids.count <= 5_000, Set(scope.ids).count == scope.ids.count,
                      scope.ids.allSatisfy({ $0.range(of: #"\A[0-9]{1,30}\z"#, options: .regularExpression) != nil }) else { throw SalesFileFailure.format }
            }
            if let source = record.source {
                guard !source.columns.isEmpty, source.columns.count <= 100, source.rows.count <= 100_000,
                      source.columns.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 200 }), Set(source.columns.map { Array($0.utf16) }).count == source.columns.count,
                      source.rows.allSatisfy({ $0.count == source.columns.count && $0.allSatisfy { !$0.contains("\0") } }),
                      record.json["source"]!.stringify().utf16.count <= 8_000_000 else { throw SalesFileFailure.format }
                let parsed = try SalesReports.summary(source, appId: appId, accountId: accountId, importedAt: record.importedAt, appSku: record.appSku, scope: record.productScope, legacy: record.productScope == nil)
                guard parsed.beginDate == record.beginDate, parsed.endDate == record.endDate, parsed.source?.rows.count == source.rows.count, parsed.unitsByTerritory == record.unitsByTerritory else { throw SalesFileFailure.format }
            }
        }
    }

    public static func summary(_ records: [SalesRecord]) -> String {
        let rows = records.flatMap { record -> [[String]] in
            if record.unitsByTerritory.isEmpty { return [[record.appId, record.beginDate, record.endDate, "", "0"]] }
            return record.unitsByTerritory.sorted { $0.key < $1.key }.map { [record.appId, record.beginDate, record.endDate, $0.key, String($0.value)] }
        }
        return Delimited.write(Delimited.Table(columns: columns, rows: rows))
    }

    public static func original(_ report: SalesRecord, format: Format) throws -> Data {
        guard let table = report.source else { throw SalesFileFailure.source }
        if format == .originalCsv { return Data(Delimited.write(Delimited.Table(columns: table.columns, rows: table.rows)).utf8) }
        guard format == .originalTxt || format == .originalGzip else { throw SalesFileFailure.format }
        guard ([table.columns] + table.rows).allSatisfy({ $0.allSatisfy { !$0.contains("\t") && !$0.contains("\r") && !$0.contains("\n") } }) else { throw SalesFileFailure.multiline }
        let data = Data((([table.columns] + table.rows).map { $0.joined(separator: "\t") }.joined(separator: "\r\n") + "\r\n").utf8)
        return format == .originalGzip ? try ReportFiles.gzip(data) : data
    }
}

extension SalesRecord {
    enum CodingKeys: String, CodingKey { case schemaVersion, accountId, appId, appSku, productScope, beginDate, endDate, importedAt, unitsByTerritory, source, noSales }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw SalesFileFailure.format }
        for key in [CodingKeys.appSku, .productScope, .source, .noSales] where c.contains(key) {
            if try c.decodeNil(forKey: key) { throw SalesFileFailure.format }
        }
        accountId = try c.decode(String.self, forKey: .accountId); appId = try c.decode(String.self, forKey: .appId)
        appSku = try c.decodeIfPresent(String.self, forKey: .appSku); productScope = try c.decodeIfPresent(ProductScope.self, forKey: .productScope)
        beginDate = try c.decode(String.self, forKey: .beginDate); endDate = try c.decode(String.self, forKey: .endDate); importedAt = try c.decode(String.self, forKey: .importedAt)
        unitsByTerritory = try c.decode([String: Int].self, forKey: .unitsByTerritory); source = try c.decodeIfPresent(ReportTable.self, forKey: .source); noSales = try c.decodeIfPresent(Bool.self, forKey: .noSales)
    }
}

extension WorkspaceSession {
    func salesFileScope(_ account: Account, appId: String) throws {
        guard try currentAccount(account).appIds.contains(appId) else { throw SalesFileFailure.scope }
        try SalesFileFormats.selection(accountId: account.id, appId: appId)
    }

    public func salesFileRecords(account: Account, appId: String) throws -> [SalesRecord] {
        try salesFileScope(account, appId: appId)
        let records = try storeAccess { try PartitionedReports.items(SalesRecord.self, family: "sales", legacyKey: "reports", accountId: account.id, appId: appId, store: $0) }
            .sorted { $0.beginDate < $1.beginDate }
        try SalesFileFormats.validate(records, accountId: account.id, appId: appId); return records
    }

    /// Sales imports save locally on explicit import. Catalog reads finish before report locks.
    public func importSalesFile(account: Account, appId: String, data: Data, client: AppStoreConnectClient? = nil, now: Date = Date()) async throws -> SalesReports.Changes {
        try salesFileScope(account, appId: appId)
        let content = try ReportFiles.texts([data], purpose: .sales)[0], table = try SalesReports.table(content)
        let apple = table.columns.contains("Apple Identifier")
        var scope = ProductScope(ids: [], complete: false)
        if apple {
            let catalogClient = client ?? (try? self.client(for: account))
            if let catalogClient {
                _ = try currentAccount(account, client: catalogClient)
                scope = await Self.productScope(appId: appId, client: catalogClient)
            }
        }
        try Task.checkCancellation(); try salesFileScope(account, appId: appId)
        let records = try SalesFileFormats.parse(content, accountId: account.id, appId: appId, importedAt: CustomerReview.isoString(now), appSku: apple ? salesAppSku(accountId: account.id, appId: appId) : nil, productScope: apple ? scope : nil)
        guard !records.isEmpty else { throw SalesFileFailure.format }
        var changes = SalesReports.Changes()
        try storeAccess { store in
            try PartitionedReports.replaceAll(SalesRecord.self, family: "sales", legacyKey: "reports", accountId: account.id, appId: appId, store: store, stateDirectory: store.directory,
                                              bucketOf: { String($0.beginDate.prefix(7)) }, encode: \.json, validate: { try self.salesFileScope(account, appId: appId); try Task.checkCancellation() }) { previous, _ in
                try SalesFileFormats.validate(previous ?? [], accountId: account.id, appId: appId)
                let merged = try SalesReports.merge(previous ?? [], records)
                try SalesFileFormats.validate(merged.records, accountId: account.id, appId: appId)
                changes = merged.changes; return (merged.records, nil)
            }
        }
        return changes
    }

    public func exportSalesFile(account: Account, appId: String, beginDate: String? = nil, endDate: String? = nil, format: SalesFileFormats.Format) throws -> Data {
        var records = try salesFileRecords(account: account, appId: appId)
        guard !records.isEmpty else { throw SalesFileFailure.missing }
        if let beginDate {
            records = records.filter { $0.beginDate == beginDate && $0.endDate == endDate }
            guard records.count == 1 else { throw SalesFileFailure.missing }
        } else if endDate != nil { throw SalesFileFailure.format }
        if format == .summary { return Data(SalesFileFormats.summary(records).utf8) }
        guard beginDate != nil, records.count == 1 else { throw SalesFileFailure.source }
        return try SalesFileFormats.original(records[0], format: format)
    }

    /// Removes exactly one local period under the report mutex, preserving every other month and report family.
    public func removeSalesFilePeriod(account: Account, appId: String, beginDate: String, endDate: String) throws {
        try salesFileScope(account, appId: appId)
        guard ReportTables.validDate(beginDate), ReportTables.validDate(endDate), beginDate <= endDate else { throw SalesFileFailure.format }
        try storeAccess { store in
            try PartitionedReports.replaceAll(SalesRecord.self, family: "sales", legacyKey: "reports", accountId: account.id, appId: appId, store: store, stateDirectory: store.directory,
                                              bucketOf: { String($0.beginDate.prefix(7)) }, encode: \.json, validate: { try self.salesFileScope(account, appId: appId); try Task.checkCancellation() }) { previous, _ in
                let records = previous ?? []; try SalesFileFormats.validate(records, accountId: account.id, appId: appId)
                guard records.contains(where: { $0.beginDate == beginDate && $0.endDate == endDate }) else { throw SalesFileFailure.missing }
                return (records.filter { $0.beginDate != beginDate || $0.endDate != endDate }, nil)
            }
        }
    }
}
