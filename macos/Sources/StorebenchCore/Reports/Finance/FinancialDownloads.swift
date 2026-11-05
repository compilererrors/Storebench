import Foundation

public struct FinancialDownloadSelection: Equatable, Sendable {
    public let source: ReportingSource, year: Int, period: Int, periods: Int, region: String
    public var json: JSONText { .object([("source", .string(source.rawValue)), ("year", .number(Double(year))), ("period", .number(Double(period))), ("periods", .number(Double(periods))), ("region", .string(region))]) }
    public init(json: JSONText) throws {
        guard let source = json["source"]?.text.flatMap(ReportingSource.init(rawValue:)), case .number(let y)? = json["year"], let year = Int(exactly: y), (2001...9999).contains(year),
              case .number(let p)? = json["period"], let period = Int(exactly: p), (1...12).contains(period),
              case .number(let n)? = json["periods"], let periods = Int(exactly: n), (1...FinancialReports.maximumPeriods).contains(periods),
              let region = json["region"]?.text, FinancialReports.downloadRegions.contains(region) else { throw FinanceFailure.request }
        self.source = source; self.year = year; self.period = period; self.periods = periods; self.region = region
    }
    init(source: ReportingSource, periods: [FiscalPeriod], region: String) throws {
        guard let last = periods.last, FinancialReports.periods(ending: last, count: periods.count) == periods else { throw FinanceFailure.request }
        try self.init(json: .object([("source", .string(source.rawValue)), ("year", .number(Double(last.year))), ("period", .number(Double(last.period))), ("periods", .number(Double(periods.count))), ("region", .string(region))]))
    }
    var keys: Set<String> { Set(FinancialReports.periods(ending: FiscalPeriod(year: year, period: period), count: periods).map(\.key)) }
}

/// One normalized entry in the bounded encrypted financial review cache.
public struct FinancialDownloadRecord: Sendable {
    public let id: String, createdAt: String, selection: FinancialDownloadSelection, reports: [FinancialReport]
    let expiresAt: Date, accountId: String, appId: String
    public var value: JSONText { .object([("schemaVersion", .number(1)), ("createdAt", .string(createdAt)), ("selection", selection.json),
        ("history", FinancialFileFormats.history(accountId: accountId, appId: appId, reports: reports))]) }
    public var json: JSONText { .object([("id", .string(id)), ("value", value)]) }
    public init(json: JSONText, accountId: String, appId: String, now: Date = Date()) throws {
        try FinancialFileFormats.identity(accountId: accountId, appId: appId)
        guard let id = json["id"]?.text, ReportJobs.uuid(id), let value = json["value"], value["schemaVersion"] == .number(1),
              value.data.count <= 10_000_000, let stamp = value["createdAt"]?.text, ReportTimestamps.valid(stamp),
              let selectionJSON = value["selection"], let history = value["history"], history["schemaVersion"] == .number(1),
              history["accountId"]?.text == accountId, history["appId"]?.text == appId, case .array(let values)? = history["reports"] else { throw FinanceFailure.expiredReview }
        // Parse at millisecond precision; retain the original timestamp for its fingerprint.
        var parsedStamp = stamp
        if let dot = stamp.firstIndex(of: ".") {
            let start = stamp.index(after: dot), digits = stamp[start...].prefix { $0.isNumber }
            parsedStamp = String(stamp[...dot]) + String(digits.prefix(3)) + stamp[stamp.index(start, offsetBy: digits.count)...]
        }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var time = parser.date(from: parsedStamp)
        if time == nil { parser.formatOptions = [.withInternetDateTime]; time = parser.date(from: parsedStamp) }
        // Foundation can decode the same millisecond a fraction of a microsecond after its original Date.
        // Compare whole milliseconds to avoid rejecting an equal timestamp as future-dated.
        guard let time, (time.timeIntervalSince1970 * 1000).rounded() <= floor(now.timeIntervalSince1970 * 1000) else { throw FinanceFailure.expiredReview }
        let selection = try FinancialDownloadSelection(json: selectionJSON)
        let reports = try FinancialFileFormats.normalize(values.map { try JSONDecoder().decode(FinancialReport.self, from: $0.data) }, appId: appId)
        guard !reports.isEmpty, reports.count <= selection.periods, reports.allSatisfy({ $0.region == selection.region }) else { throw FinanceFailure.expiredReview }
        self.id = id; createdAt = stamp; self.selection = selection; self.reports = reports; self.accountId = accountId; self.appId = appId; expiresAt = time.addingTimeInterval(86_400)
    }
    static func cache(_ payload: Data?, accountId: String, appId: String, now: Date) throws -> [Self] {
        guard let payload else { return [] }
        guard payload.count <= 30_000_000, case .array(let values) = try JSONText.parse(payload), values.count <= 3 else { throw FinancialFileFailure.storage }
        let records = try values.map { try Self(json: $0, accountId: accountId, appId: appId, now: now) }
        guard Set(records.map(\.id)).count == records.count else { throw FinancialFileFailure.storage }; return records
    }
}

extension WorkspaceSession {
    func financialReviewMutex(accountId: String, appId: String) throws -> URL {
        try FinancialFileFormats.identity(accountId: accountId, appId: appId)
        return try storeAccess { $0.directory.appendingPathComponent("financial_reviews_\(JSONText.string("\(accountId)\u{0}\(appId)").rawSHA256.prefix(32)).mutex") }
    }
    func retainedFinancialRecord(_ review: FinancialDownload, store: EncryptedDocumentStore, now: Date = Date()) throws -> FinancialDownloadRecord {
        let cache = try FinancialDownloadRecord.cache(store.document(namespace: "financial_reviews", key: "\(review.accountId):\(review.appId)")?.payload, accountId: review.accountId, appId: review.appId, now: now)
        guard let record = cache.first(where: { $0.id == review.id.uuidString.lowercased() }), record.expiresAt > now else { throw FinanceFailure.expiredReview }
        guard record.value.sha256 == review.retainedFingerprint else { throw FinanceFailure.stale }; return record
    }
    /// Retains a sync download for explicit review without changing saved financial history.
    public func retainPendingFinancialDownload(_ review: FinancialDownload, now: Date = Date()) throws {
        try retainFinancialDownload(review, now: now, check: {})
    }
    func retainFinancialDownload(_ review: FinancialDownload, now: Date, check: () throws -> Void) throws {
        try financialFileScope(review.account, appId: review.appId); try Task.checkCancellation()
        try check()
        guard review.expiresAt > now, let selection = review.selection, !review.reports.isEmpty else { throw FinanceFailure.expiredReview }
        let id = review.id.uuidString.lowercased(), key = "\(review.accountId):\(review.appId)"
        // Truncate milliseconds so a fresh receipt cannot round into the future.
        let createdAt = Date(timeIntervalSince1970: floor(review.expiresAt.addingTimeInterval(-86_400).timeIntervalSince1970 * 1000) / 1000)
        let value = JSONText.object([("schemaVersion", .number(1)), ("createdAt", .string(CustomerReview.isoString(createdAt))),
            ("selection", selection.json), ("history", FinancialFileFormats.history(accountId: review.accountId, appId: review.appId, reports: review.reports))])
        guard value.data.count <= 10_000_000 else { throw FinanceFailure.size }
        let record = try FinancialDownloadRecord(json: .object([("id", .string(id)), ("value", value)]), accountId: review.accountId, appId: review.appId, now: now)
        guard Set(review.noApp + review.unavailable).isSubset(of: selection.keys), Set(review.noApp + review.unavailable).count == review.noApp.count + review.unavailable.count,
              review.reports.count + review.noApp.count + review.unavailable.count == selection.periods else { throw FinanceFailure.period }
        let pending = JSONText.object([("id", .string(id)), ("noApp", .array(review.noApp.map(JSONText.string))), ("unavailable", .array(review.unavailable.map(JSONText.string)))])
        try FileMutex.withLock(financialReviewMutex(accountId: review.accountId, appId: review.appId)) {
            try storeAccess { store in try store.transaction { current in
                try self.financialFileScope(review.account, appId: review.appId); try Task.checkCancellation()
                try check()
                let cache = try FinancialDownloadRecord.cache(current("financial_reviews", key)?.payload, accountId: review.accountId, appId: review.appId, now: now)
                let next = [record] + Array(cache.filter { $0.id != id && $0.expiresAt > now }.prefix(2))
                return [.put(namespace: "financial_reviews", key: key, json: JSONText.array(next.map(\.json)).data), .put(namespace: "financial_pending", key: key, json: pending.data)]
            } }
        }
    }
    /// Reading a waiting download prepares a new comparison; an already open editor keeps its original baseline.
    public func pendingFinancialDownload(accountId: String, appId: String, now: Date = Date()) throws -> FinancialDownload? {
        try FinancialFileFormats.identity(accountId: accountId, appId: appId)
        guard let account = try accounts().first(where: { $0.id == accountId }), account.appIds.contains(appId) else { return nil }
        return try FileMutex.withLock(financialReviewMutex(accountId: accountId, appId: appId)) {
            try storeAccess { store in
                let key = "\(accountId):\(appId)"
                guard let document = try store.document(namespace: "financial_pending", key: key) else { return nil }
                let pending = try JSONText.parse(document.payload)
                guard let id = pending["id"]?.text, ReportJobs.uuid(id) else { throw FinancialFileFailure.storage }
                let cache = try FinancialDownloadRecord.cache(store.document(namespace: "financial_reviews", key: key)?.payload, accountId: accountId, appId: appId, now: now)
                guard let record = cache.first(where: { $0.id == id }), record.expiresAt > now else { return nil }
                func keys(_ name: String) throws -> [String] {
                    guard case .array(let values)? = pending[name] else { throw FinancialFileFailure.storage }
                    return try values.map { guard let key = $0.text, record.selection.keys.contains(key) else { throw FinancialFileFailure.storage }; return key }
                }
                let noApp = try keys("noApp"), unavailable = try keys("unavailable")
                guard Set(noApp + unavailable).count == noApp.count + unavailable.count, record.reports.count + noApp.count + unavailable.count == record.selection.periods else { throw FinancialFileFailure.storage }
                let saved = try self.financialFileSnapshot(account: account, appId: appId)
                let changes = try FinancialReports.merge(saved.reports, record.reports).changes
                return FinancialDownload(id: UUID(uuidString: id)!, accountId: accountId, appId: appId, region: record.selection.region, reports: record.reports, noApp: noApp,
                    unavailable: unavailable, changes: changes, revision: saved.revision, account: account, expiresAt: record.expiresAt, selection: record.selection, retainedFingerprint: record.value.sha256)
            }
        }
    }
    /// Removes only this pending pointer; bounded cached reports remain available to an explicit review.
    public func clearPendingFinancialDownload(_ review: FinancialDownload) throws {
        let key = "\(review.accountId):\(review.appId)", id = review.id.uuidString.lowercased()
        try FileMutex.withLock(financialReviewMutex(accountId: review.accountId, appId: review.appId)) {
            try storeAccess { store in try store.transaction { current in
                try self.financialFileScope(review.account, appId: review.appId); try Task.checkCancellation()
                guard let pending = try current("financial_pending", key) else { return [] }
                guard let saved = try JSONText.parse(pending.payload)["id"]?.text, ReportJobs.uuid(saved) else { throw FinancialFileFailure.storage }
                return saved == id ? [.delete(namespace: "financial_pending", key: key)] : []
            } }
        }
    }
}
