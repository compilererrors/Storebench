import Foundation

public struct SalesSyncResult: Equatable, Sendable {
    public var changes = SalesReports.Changes()
    public var unavailableDays: [String] = [], noAppRowsDays: [String] = [], noSalesDays: [String] = []
}

private enum SalesByteAnswer: Error { case noSales, unavailable }

extension WorkspaceSession {
    typealias SalesConnection = ReportingConnection

    func salesConnection(accountId: String) throws -> SalesConnection? {
        try readReportingState(accountId: accountId).connection
    }
    /// Capture and validate the reporting choice under its connection lock; downloads use this captured choice after release.
    func capturedSalesConnection(accountId: String, reporter: ReporterClient?, source: ReportingSource? = nil, requireReporterCredential: Bool = true) throws -> SalesConnection? {
        return try FileMutex.withLock(reportingMutex(accountId: accountId)) {
            guard let connection = try salesConnection(accountId: accountId) else { return nil }
            if source == .api { return ReportingConnection(accountId: accountId, vendorNumber: connection.vendorNumber, reporter: nil) }
            if source == .reporter, connection.reporter == nil { throw SalesFailure.noConnection }
            if let selected = connection.reporter, requireReporterCredential || reporter != nil {
                guard reporter?.selection?.matches(accountId: accountId, connection: selected) == true else { throw SalesFailure.changedConnection }
            } else if connection.reporter == nil && reporter != nil { throw SalesFailure.changedConnection }
            return connection
        }
    }

    /// The SKU of the latest Apple import; local drafts cannot establish ownership of purchases.
    func salesAppSku(accountId: String, appId: String) throws -> String? {
        let sku = try revisions(accountId: accountId, appId: appId).first { !$0.isLocalDraft }?.app.sku
        return sku.flatMap { $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$", options: .regularExpression) != nil ? $0 : nil }
    }

    /// The app's in-app purchase and subscription IDs. A catalog that cannot be read is incomplete, never empty.
    static func productScope(appId: String, client: AppStoreConnectClient) async -> ProductScope {
        var ids: [String] = [], complete = true
        do { ids += try await client.list("/v1/apps/\(appId)/inAppPurchasesV2?limit=200&fields%5BinAppPurchases%5D=productId").filter { $0.type == "inAppPurchases" }.map(\.id) } catch { complete = false }
        do {
            for group in try await client.list("/v1/apps/\(appId)/subscriptionGroups?limit=200") where group.type == "subscriptionGroups" {
                ids += try await client.list("/v1/subscriptionGroups/\(group.id)/subscriptions?limit=200&fields%5Bsubscriptions%5D=productId,group").map(\.id)
            }
        } catch { complete = false }
        let valid = ids.filter { $0.range(of: #"^\d{1,30}$"#, options: .regularExpression) != nil }
        return ProductScope(ids: Array(Set(valid)).sorted(), complete: complete && valid.count == ids.count && Set(ids).count == ids.count)
    }

    /// Downloads one Summary Sales report per day, newest first, and saves them in the months they touch.
    func downloadSalesBody(account: Account, appId: String, days: [String], client: AppStoreConnectClient?, reporter: ReporterClient?, source: ReportingSource, now: Date,
                           incremental: Bool = false, sharedBytes: SharedReportBytes = .shared,
                           check: @escaping () throws -> Void, progress: (SalesDownloadJob.Phase, Int, Int, Int, Int, Int) throws -> Void,
                           completion: (SalesSyncResult, EncryptedDocumentStore) throws -> [EncryptedDocumentStore.Write]) async throws -> SalesSyncResult {
        try Task.checkCancellation(); try salesFileScope(account, appId: appId); try check()
        _ = try currentAccount(account, client: client)
        guard account.appIds.contains(appId), let connection = try capturedSalesConnection(accountId: account.id, reporter: reporter, source: source, requireReporterCredential: false),
              connection.reporter != nil || account.keyType == "team" else { throw SalesFailure.noConnection }
        func context() throws {
            try Task.checkCancellation(); try self.salesFileScope(account, appId: appId); try check()
            let current = try self.salesConnection(accountId: account.id)
            let selected = source == .api ? current.map { ReportingConnection(accountId: $0.accountId, vendorNumber: $0.vendorNumber, reporter: nil) } : current
            guard selected == connection else { throw SalesFailure.changedConnection }
        }
        let appSku = try salesAppSku(accountId: account.id, appId: appId), scope: ProductScope
        if let client { scope = await Self.productScope(appId: appId, client: client) } else { scope = ProductScope(ids: [], complete: false) }
        try context()
        let history = incremental ? try salesFileRecords(account: account, appId: appId) : []
        let receipts = incremental ? syncReceipts(accountId: account.id, appId: appId)?.entries : nil
        let plannedAt = now, importedAt = CustomerReview.isoString(now)
        func keyFor(_ day: String) -> String { SyncReceipt.salesKey(vendor: connection.vendorNumber, reporterAccount: connection.reporter?.accountNumber, sku: appSku, scope: scope, day: day) }
        func savedFor(_ day: String, in records: [SalesRecord]) -> SalesRecord? { records.first { $0.beginDate == day && $0.endDate == day } }
        func fingerprint(_ record: SalesRecord?) -> String { (record?.json ?? .null).sha256 }
        func content(_ record: SalesRecord) -> String {
            guard case .object(let fields) = record.json else { return "" }
            return JSONText.object(fields.map { $0.0 == "importedAt" ? ($0.0, .string("")) : $0 }).sha256
        }
        var result = SalesSyncResult(), records: [SalesRecord] = [], reused: [SalesRecord] = [], fresh: [(day: String, receipt: SyncReceipt)] = []
        var failures = 0, totalBytes = 0, lastFailure: Error?
        var capturedReporter: ReporterClient?, capturedAPI: AppStoreConnectClient?
        for (index, day) in days.sorted(by: >).enumerated() {
            try context()
            let key = keyFor(day), existing = savedFor(day, in: history), local = fingerprint(existing)
            let receipt = receipts?.first { $0.key == key }
            var didReuse = false
            if let receipt, receipt.freshSales(local: local, day: day, now: plannedAt) {
                switch receipt.outcome {
                case .withApp: if let existing, existing.noSales != true { reused.append(existing); didReuse = true }
                case .noSales: if existing?.noSales == true { result.noSalesDays.append(day); didReuse = true }
                case .noApp: result.noAppRowsDays.append(day); didReuse = true
                case .unavailable: result.unavailableDays.append(day); didReuse = true
                }
            }
            if didReuse {
                try progress(.downloading, index + 1, records.count + reused.count, result.noAppRowsDays.count, result.unavailableDays.count, result.noSalesDays.count)
                continue
            }
            var bytes: Data?, temporaryFailure = false
            let loader: @Sendable () async throws -> Data
            if let reporterConnection = connection.reporter {
                if capturedReporter == nil {
                    capturedReporter = try reporter ?? self.reporterClient(accountId: account.id)
                    guard capturedReporter?.selection?.matches(accountId: account.id, connection: reporterConnection) == true else { throw SalesFailure.changedConnection }
                }
                guard let owned = capturedReporter else { throw SalesFailure.noConnection }
                loader = {
                    switch try await owned.dailySales(account: reporterConnection.accountNumber, vendor: reporterConnection.vendorNumber, day: day) {
                    case .report(let data): return data
                    case .noSales: throw SalesByteAnswer.noSales
                    case .unavailable: throw SalesByteAnswer.unavailable
                    }
                }
            } else {
                if capturedAPI == nil { capturedAPI = try client ?? self.client(for: account) }
                guard let owned = capturedAPI else { throw ReviewsFailure.noKey }
                let query = "filter%5BvendorNumber%5D=\(connection.vendorNumber)&filter%5BreportDate%5D=\(day)&filter%5Bfrequency%5D=DAILY&filter%5BreportType%5D=SALES&filter%5BreportSubType%5D=SUMMARY"
                loader = { try await owned.download("/v1/salesReports?\(query)") }
            }
            do {
                if incremental {
                    let parts = connection.reporter.map { ["reporter", $0.accountNumber, connection.vendorNumber, day] } ?? ["api", connection.vendorNumber, day]
                    let sharedKey = JSONText.array((["sales-bytes", account.id] + parts).map(JSONText.string)).sha256
                    bytes = try await sharedBytes.load(key: sharedKey, download: loader)
                } else { bytes = try await loader() }
            } catch SalesByteAnswer.noSales { result.noSalesDays.append(day) }
            catch SalesByteAnswer.unavailable { result.unavailableDays.append(day) }
            catch AppStoreConnectClient.Failure.status(404) { result.unavailableDays.append(day) }
            catch let error where (error as? URLError)?.code != .cancelled && (error is URLError || error as? AppStoreConnectClient.Failure == .status(500) || error as? AppStoreConnectClient.Failure == .status(503)) && failures < 5 {
                failures += 1; lastFailure = error; result.unavailableDays.append(day); temporaryFailure = true
            }
            try context()
            if let bytes {
                if let record = try SalesReports.parseDay(bytes, appId: appId, accountId: account.id, day: day, importedAt: importedAt, appSku: appSku, scope: scope) {
                    if record.noSales == true { result.noSalesDays.append(day) }
                    else { totalBytes += record.json.data.count; guard totalBytes <= 8_000_000 else { throw SalesFailure.size }; records.append(record) }
                } else { result.noAppRowsDays.append(day) }
            }
            if !temporaryFailure {
                let outcome: SyncReceipt.Outcome = result.unavailableDays.contains(day) ? .unavailable : result.noSalesDays.contains(day) ? .noSales : result.noAppRowsDays.contains(day) ? .noApp : .withApp
                fresh.append((day, SyncReceipt(key: key, remote: bytes.map(SyncReceipt.bytesFingerprint) ?? JSONText.null.sha256, local: local, checkedAt: CustomerReview.isoString(now), outcome: outcome)))
            }
            try progress(.downloading, index + 1, records.count + reused.count, result.noAppRowsDays.count, result.unavailableDays.count, result.noSalesDays.count)
        }
        if let lastFailure, records.isEmpty, reused.isEmpty, result.noSalesDays.isEmpty, result.noAppRowsDays.isEmpty { throw lastFailure }
        result.unavailableDays.sort(); result.noAppRowsDays.sort(); result.noSalesDays.sort()
        let quiet = result.noSalesDays.map { SalesRecord.noSalesDay(accountId: account.id, appId: appId, day: $0, importedAt: importedAt) }, saving = records + quiet
        var committed = history, changes = SalesReports.Changes()
        func remember() {
            let entries = fresh.compactMap { entry -> SyncReceipt? in
                let saved = savedFor(entry.day, in: committed), incoming = savedFor(entry.day, in: saving)
                // A retained richer record or saved sales cannot establish a newly downloaded no-sales answer.
                if let incoming, saved.map({ content($0) }) != content(incoming) { return nil }
                return entry.receipt.binding(local: fingerprint(saved))
            }
            self.rememberSyncReceipts(account: account, appId: appId, entries: entries)
        }
        let months = Set(days.map { String($0.prefix(7)) })
        guard !saving.isEmpty else {
            if reused.isEmpty && result.noAppRowsDays.isEmpty { remember(); throw SalesFailure.unavailable }
            try context()
            try storeAccess { store in
                let name = "sales-" + JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(32)
                try FileMutex.withLock(store.directory.appendingPathComponent("\(name).mutex")) {
                    committed = try self.salesFileRecords(account: account, appId: appId)
                    for record in reused { guard fingerprint(savedFor(record.beginDate, in: committed)) == fingerprint(record) else { throw PartitionedReports.Failure.stale } }
                    result.changes.unchanged = reused.count
                    try store.transaction { _ in try context(); return try completion(result, store) }
                }
            }
            remember(); return result
        }
        try context(); try progress(.saving, days.count, records.count + reused.count, result.noAppRowsDays.count, result.unavailableDays.count, result.noSalesDays.count)
        let downloaded = result
        try storeAccess { store in
            try PartitionedReports.replaceAll(SalesRecord.self, family: "sales", legacyKey: "reports", accountId: account.id, appId: appId, store: store,
                stateDirectory: store.directory, onlyBuckets: months, bucketOf: { String($0.beginDate.prefix(7)) }, encode: \.json,
                validate: context, additionalWrites: {
                    try context(); var completed = downloaded; completed.changes = changes; completed.changes.unchanged += reused.count
                    return try completion(completed, store)
                }) { previous, _ in
                    try context(); try SalesFileFormats.validate(previous ?? [], accountId: account.id, appId: appId)
                    for record in reused { guard fingerprint(savedFor(record.beginDate, in: previous ?? [])) == fingerprint(record) else { throw PartitionedReports.Failure.stale } }
                    let merged = try SalesReports.merge(previous ?? [], saving)
                    try SalesFileFormats.validate(merged.records, accountId: account.id, appId: appId); changes = merged.changes; committed = merged.records
                    return (merged.records, nil)
                }
        }
        result.changes = changes; result.changes.unchanged += reused.count; remember(); return result
    }

    /// The days a sync downloads: the person's chosen reach on the first sync, then back to the oldest gap after saved reports.
    public func salesSyncDays(accountId: String, appId: String, now: Date = Date()) throws -> [String] {
        let reach = try periodPreferences().syncReach
        let end = SalesReports.latestCompletedDay(now: now)
        let saved = SyncFreshness.savedSalesDays(try sales(accountId: accountId, appId: appId).map { ($0.beginDate, $0.endDate) }, end: end)
        return SalesReports.days(ending: end, count: SyncFreshness.catchUpDays(saved: saved, end: end, first: reach, maximum: max(7, reach)))
    }

    /// The Reporter client for an account's saved Reporter connection, with its token from the shared Keychain item.
    public func reporterClient(accountId: String) throws -> ReporterClient? {
        return try FileMutex.withLock(reportingMutex(accountId: accountId)) {
            guard let reporter = try salesConnection(accountId: accountId)?.reporter else { return nil }
            guard let token = try vaultEntry("reporter:\(reporter.credentialId)") else { throw SalesFailure.noConnection }
            return try ReporterClient(token: token, selection: ReporterClient.Selection(accountId: accountId, accountNumber: reporter.accountNumber, vendorNumber: reporter.vendorNumber, credentialId: reporter.credentialId), accessCheck: sessionRequestCheck())
        }
    }
}
