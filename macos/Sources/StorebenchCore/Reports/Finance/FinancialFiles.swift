import Foundation

public enum FinancialFileFailure: Error, Equatable {
    case metadata, changedFiles, missing, storage
    public var message: String {
        switch self {
        case .metadata: "Choose each Apple file's report region and confirm that every file is complete. Storebench JSON carries its own report regions."
        case .changedFiles: "The selected report contents changed after preview. Preview the selected files again before saving."
        case .missing: "The saved financial report is no longer available. Read the saved reports and retry."
        case .storage: "Saved financial reports could not be read or saved locally. Existing indexed history is kept; check local storage and read it before retrying."
        }
    }
}

/// Immutable file bytes and explicit region/completeness choices, rebuilt when the user saves a review.
public struct FinancialFileInput: Sendable {
    public let files: [Data], regions: [String], complete: Bool
    public init(files: [Data], regions: [String] = [], complete: Bool = false) { self.files = files; self.regions = regions; self.complete = complete }
}

public enum FinancialFileFormats {
    public enum Format: Sendable { case historyJson, sourceCsv, sourceTxt, sourceGzip }
    public struct Incoming: Sendable { public let reports: [FinancialReport], noAppFiles: Int, importId: String }

    static func identity(accountId: String, appId: String) throws {
        guard accountId.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil,
              appId.range(of: #"\A[0-9]+\z"#, options: .regularExpression) != nil else { throw FinanceFailure.scope }
    }

    /// Revalidate stored source tables before comparing or exporting a history.
    static func normalize(_ reports: [FinancialReport], appId: String) throws -> [FinancialReport] {
        let records = try reports.map { record in
            guard ReportTables.validDate(record.beginDate), ReportTables.validDate(record.endDate), ReportTimestamps.valid(record.importedAt) else { throw FinanceFailure.format }
            let parsed: FinancialReport
            do { parsed = try FinancialReports.fromTable(record.source, scope: record.region, appId: appId, importedAt: record.importedAt) }
            catch is FinancialReports.NotFound { throw FinanceFailure.scope }
            guard parsed.beginDate == record.beginDate, parsed.endDate == record.endDate, parsed.basis == record.basis,
                  parsed.source.rows.count == record.source.rows.count else { throw FinanceFailure.format }
            return parsed
        }.sorted { $0.key < $1.key }
        try FinancialReports.check(records); return records
    }

    public static func history(accountId: String, appId: String, reports: [FinancialReport], omitImportTime: Bool = false) -> JSONText {
        .object([("schemaVersion", .number(1)), ("accountId", .string(accountId)), ("appId", .string(appId)), ("reports", .array(reports.map { record in
            guard omitImportTime, case .object(let fields) = record.json else { return record.json }
            return .object(fields.map { ($0.0, $0.0 == "importedAt" ? .string("") : $0.1) })
        }))])
    }

    public static func parse(_ input: FinancialFileInput, accountId: String, appId: String, now: Date = Date()) throws -> Incoming {
        try identity(accountId: accountId, appId: appId); try Task.checkCancellation()
        let contents = try ReportFiles.texts(input.files, purpose: .reports), stamp = CustomerReview.isoString(now)
        var reports: [FinancialReport] = [], noApp = 0
        if contents.count == 1, TextSemantics.trim(contents[0]).hasPrefix("{") {
            let value: JSONText
            do { value = try JSONText.parse(Data(contents[0].utf8)) } catch { throw FinanceFailure.format }
            guard value["schemaVersion"] == .number(1), let owner = value["accountId"]?.text, let app = value["appId"]?.text,
                  case .array(let raw)? = value["reports"] else { throw FinanceFailure.format }
            try identity(accountId: owner, appId: app)
            guard owner == accountId, app == appId else { throw FinanceFailure.scope }
            do { reports = try normalize(raw.map { try JSONDecoder().decode(FinancialReport.self, from: $0.data) }, appId: appId) }
            catch let error as FinanceFailure { throw error } catch { throw FinanceFailure.format }
            reports = reports.map { FinancialReport(beginDate: $0.beginDate, endDate: $0.endDate, region: $0.region, basis: $0.basis, importedAt: stamp, source: $0.source) }
        } else {
            guard input.complete, input.regions.count == contents.count else { throw FinancialFileFailure.metadata }
            for (index, content) in contents.enumerated() {
                try Task.checkCancellation()
                do { reports.append(try FinancialReports.fromValidatedTable(ReportTables.parseValidated(content), scope: input.regions[index], appId: appId, importedAt: stamp)) }
                catch is FinancialReports.NotFound { noApp += 1 }
                catch let error as FinanceFailure { throw error } catch { throw FinanceFailure.format }
            }
            guard !reports.isEmpty else { throw FinanceFailure.scope }
            reports.sort { $0.key < $1.key }
            try FinancialReports.check(reports)
        }
        guard !reports.isEmpty, reports.allSatisfy({ $0.endDate < String(stamp.prefix(10)) }) else { throw FinanceFailure.format }
        try Task.checkCancellation()
        return Incoming(reports: reports, noAppFiles: noApp, importId: history(accountId: accountId, appId: appId, reports: reports, omitImportTime: true).sha256)
    }

    public static func source(_ report: FinancialReport, format: Format) throws -> Data {
        guard format != .historyJson else { throw FinanceFailure.format }
        let text = try ReportTables.text(report.source, format: format == .sourceCsv ? .csv : .txt)
        let bytes = Data(text.utf8)
        return format == .sourceGzip ? try ReportFiles.gzip(bytes) : bytes
    }
}

/// The report index revision shown to the user; callers cannot replace it with a newer baseline.
public struct FinancialFileState: Sendable {
    public let reports: [FinancialReport]
    let account: Account, appId: String, revision: PartitionedReports.Revision
}

public struct FinancialFileReview: Sendable {
    public let reports: [FinancialReport], changes: [FinancialReports.Change], noAppFiles: Int, importId: String
    let account: Account, appId: String, revision: PartitionedReports.Revision
}

extension WorkspaceSession {
    func financialFileScope(_ account: Account, appId: String) throws {
        try FinancialFileFormats.identity(accountId: account.id, appId: appId)
        guard try currentAccount(account).appIds.contains(appId) else { throw FinanceFailure.scope }
    }

    func financialStoredReports(accountId: String, appId: String, store: EncryptedDocumentStore) throws -> [FinancialReport] {
        do {
            try FinancialFileFormats.identity(accountId: accountId, appId: appId)
            if try store.document(namespace: "financial_index", key: "\(accountId):\(appId)") == nil,
               let legacy = try store.document(namespace: "financial", key: "\(accountId):\(appId)") {
                let value = try JSONText.parse(legacy.payload)
                guard value["schemaVersion"] == .number(1), value["accountId"]?.text == accountId, value["appId"]?.text == appId,
                      case .array? = value["reports"] else { throw FinancialFileFailure.storage }
            }
            return try FinancialFileFormats.normalize(PartitionedReports.items(FinancialReport.self, family: "financial", legacyKey: "reports", accountId: accountId, appId: appId, store: store), appId: appId)
        } catch { throw FinancialFileFailure.storage }
    }

    func financialFileSnapshot(account: Account, appId: String) throws -> FinancialFileState {
        try financialFileScope(account, appId: appId); try Task.checkCancellation()
        return try storeAccess { store in
            let name = "financial-" + JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(32) + ".mutex"
            return try FileMutex.withLock(store.directory.appendingPathComponent(name)) {
                try self.financialFileScope(account, appId: appId); try Task.checkCancellation()
                let revision = try PartitionedReports.revision(family: "financial", accountId: account.id, appId: appId, store: store)
                return FinancialFileState(reports: try self.financialStoredReports(accountId: account.id, appId: appId, store: store), account: account, appId: appId, revision: revision)
            }
        }
    }

    public func savedFinancialFiles(account: Account, appId: String) throws -> FinancialFileState { try financialFileSnapshot(account: account, appId: appId) }

    /// No report documents change during preview. The revision and prior reports are read together under the report mutex.
    public func previewFinancialFiles(account: Account, appId: String, input: FinancialFileInput, now: Date = Date()) throws -> FinancialFileReview {
        try financialFileScope(account, appId: appId)
        let incoming = try FinancialFileFormats.parse(input, accountId: account.id, appId: appId, now: now)
        let saved = try financialFileSnapshot(account: account, appId: appId)
        let merged = try FinancialReports.merge(saved.reports, incoming.reports)
        return FinancialFileReview(reports: incoming.reports, changes: merged.changes, noAppFiles: incoming.noAppFiles, importId: incoming.importId, account: account, appId: appId, revision: saved.revision)
    }

    /// Re-reading the selected files prevents a different file or region choice from being saved through an older review.
    public func saveFinancialFiles(_ review: FinancialFileReview, input: FinancialFileInput, now: Date = Date()) throws -> [FinancialReports.Change] {
        try financialFileScope(review.account, appId: review.appId)
        let incoming = try FinancialFileFormats.parse(input, accountId: review.account.id, appId: review.appId, now: now)
        guard incoming.importId == review.importId else { throw FinancialFileFailure.changedFiles }
        var changes: [FinancialReports.Change] = []
        do {
            try storeAccess { store in
                try PartitionedReports.replaceAll(FinancialReport.self, family: "financial", legacyKey: "reports", accountId: review.account.id, appId: review.appId, store: store,
                                                  stateDirectory: store.directory, bucketOf: { String($0.beginDate.prefix(4)) }, encode: \.json, expected: review.revision,
                                                  validate: { try self.financialFileScope(review.account, appId: review.appId); try Task.checkCancellation() }) { previous, _ in
                    let normalized = try FinancialFileFormats.normalize(previous ?? [], appId: review.appId)
                    let merged = try FinancialReports.merge(normalized, incoming.reports)
                    changes = merged.changes; return (merged.reports, nil)
                }
            }
        } catch PartitionedReports.Failure.stale { throw FinanceFailure.stale }
        return changes
    }

    public func exportFinancialFile(account: Account, appId: String, key: String? = nil, format: FinancialFileFormats.Format) throws -> Data {
        let saved = try financialFileSnapshot(account: account, appId: appId)
        guard saved.revision.index != nil || saved.revision.legacy != nil else { throw FinancialFileFailure.missing }
        if format == .historyJson { return FinancialFileFormats.history(accountId: account.id, appId: appId, reports: saved.reports).data }
        guard let key, let report = saved.reports.first(where: { $0.key == key }) else { throw FinancialFileFailure.missing }
        return try FinancialFileFormats.source(report, format: format)
    }

    public func removeFinancialFilePeriod(_ saved: FinancialFileState, key: String) throws {
        try financialFileScope(saved.account, appId: saved.appId); try Task.checkCancellation()
        do {
            try storeAccess { store in
                try PartitionedReports.replaceAll(FinancialReport.self, family: "financial", legacyKey: "reports", accountId: saved.account.id, appId: saved.appId, store: store,
                                                  stateDirectory: store.directory, bucketOf: { String($0.beginDate.prefix(4)) }, encode: \.json, expected: saved.revision,
                                                  validate: { try self.financialFileScope(saved.account, appId: saved.appId); try Task.checkCancellation() }) { previous, _ in
                    let records = try FinancialFileFormats.normalize(previous ?? [], appId: saved.appId)
                    guard records.contains(where: { $0.key == key }) else { throw FinanceFailure.stale }
                    return (records.filter { $0.key != key }, nil)
                }
            }
        } catch PartitionedReports.Failure.stale { throw FinanceFailure.stale }
    }
}
