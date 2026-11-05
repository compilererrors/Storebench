import Foundation

public enum AnalyticsFileFailure: Error, Equatable {
    case stale, changedFiles, missing, storage
    public var message: String {
        switch self {
        case .stale: "Saved Analytics reports changed after this review. Read saved reports and explicitly preview again before saving."
        case .changedFiles: "The selected report contents or metadata changed after preview. Preview the selected files again."
        case .missing: "The selected Analytics period is no longer saved. Read saved reports before exporting or removing it."
        case .storage: "Saved Analytics reports could not be read or saved. Existing indexed history is kept; check local storage before retrying."
        }
    }
}

public struct AnalyticsFileInput: Sendable {
    public let files: [Data], metadata: AnalyticsMetadata?, segments: Int, complete: Bool
    public init(files: [Data], metadata: AnalyticsMetadata? = nil, segments: Int = 1, complete: Bool = false) {
        self.files = files; self.metadata = metadata; self.segments = segments; self.complete = complete
    }
}

public enum AnalyticsFileFormats {
    public enum Format: Sendable { case historyJson, sourceCsv, sourceTxt, sourceGzip }
    public struct Incoming: Sendable { public let partitions: [AnalyticsPartition], importId: String }
    public struct Change: Sendable, Identifiable {
        public let key: String, date: String, action: String, beforeRows: Int, afterRows: Int, beforeProcessingDate: String?, processingDate: String, beforeActivity: String, afterActivity: String
        public var id: String { key }
    }

    static func identity(accountId: String, appId: String) throws {
        guard accountId.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil,
              appId.range(of: #"\A[0-9]+\z"#, options: .regularExpression) != nil else { throw AnalyticsFailure.scope }
    }

    static func check(_ partitions: [AnalyticsPartition], keys: inout Set<String>, counts: inout Int) throws {
        for item in partitions {
            guard keys.insert(item.key).inserted, let column = item.source.columns.firstIndex(of: "Counts") else { throw AnalyticsFailure.format }
            for row in item.source.rows {
                guard let value = AnalyticsReports.count(row[column]), value <= 9_007_199_254_740_991 - counts else { throw AnalyticsFailure.format }
                counts += value
            }
        }
    }
    static func check(_ partitions: [AnalyticsPartition]) throws { var keys = Set<String>(), counts = 0; try check(partitions, keys: &keys, counts: &counts) }

    static func normalize(_ partitions: [AnalyticsPartition], accountId: String, appId: String) throws -> [AnalyticsPartition] {
        try identity(accountId: accountId, appId: appId)
        let result = try partitions.map { item in
            guard (1...AnalyticsReports.segmentLimit).contains(item.segments), ReportTimestamps.valid(item.importedAt) else { throw AnalyticsFailure.format }
            let meta = try AnalyticsMetadata(kind: item.kind, level: item.level, granularity: item.granularity, processingDate: item.processingDate)
            let parsed = try AnalyticsReports.importSegments([item.source], meta: meta, accountId: accountId, appId: appId, importedAt: item.importedAt)
            guard parsed.count == 1, parsed[0].date == item.date, parsed[0].source.rows.count == item.source.rows.count else { throw AnalyticsFailure.format }
            let report = parsed[0]
            return AnalyticsPartition(kind: report.kind, level: report.level, granularity: report.granularity, processingDate: report.processingDate, date: report.date,
                                      importedAt: report.importedAt, segments: item.segments, source: report.source)
        }.sorted { $0.key < $1.key }
        try check(result); return result
    }
    public static func history(accountId: String, appId: String, partitions: [AnalyticsPartition], omitImportTime: Bool = false) -> JSONText {
        .object([("schemaVersion", .number(1)), ("accountId", .string(accountId)), ("appId", .string(appId)), ("partitions", .array(partitions.map { item in
            guard omitImportTime, case .object(let fields) = item.json else { return item.json }
            return .object(fields.map { ($0.0, $0.0 == "importedAt" ? .string("") : $0.1) })
        }))])
    }
    public static func parse(_ input: AnalyticsFileInput, accountId: String, appId: String, now: Date = Date()) throws -> Incoming {
        try identity(accountId: accountId, appId: appId); try Task.checkCancellation()
        let contents = try ReportFiles.texts(input.files, purpose: .reports), stamp = CustomerReview.isoString(now)
        let partitions: [AnalyticsPartition]
        if contents.count == 1, TextSemantics.trim(contents[0]).hasPrefix("{") {
            let value: JSONText
            do { value = try JSONText.parse(Data(contents[0].utf8)) } catch { throw AnalyticsFailure.format }
            guard value["schemaVersion"] == .number(1), let owner = value["accountId"]?.text, let app = value["appId"]?.text,
                  case .array(let raw)? = value["partitions"] else { throw AnalyticsFailure.format }
            guard owner == accountId, app == appId else { throw AnalyticsFailure.scope }
            let original: [AnalyticsPartition]
            do { original = try normalize(raw.map { try JSONDecoder().decode(AnalyticsPartition.self, from: $0.data) }, accountId: accountId, appId: appId) }
            catch let failure as AnalyticsFailure { throw failure } catch { throw AnalyticsFailure.format }
            partitions = original.map { AnalyticsPartition(kind: $0.kind, level: $0.level, granularity: $0.granularity, processingDate: $0.processingDate, date: $0.date, importedAt: stamp, segments: $0.segments, source: $0.source) }
        } else {
            guard input.complete, (1...20).contains(input.segments), input.segments == contents.count, let metadata = input.metadata else { throw AnalyticsFailure.segments }
            partitions = try AnalyticsReports.importSegments(contents.map(ReportTables.parse), meta: metadata, accountId: accountId, appId: appId, importedAt: stamp, strict: true)
            try check(partitions)
        }
        guard !partitions.isEmpty, partitions.allSatisfy({ $0.processingDate <= String(stamp.prefix(10)) }) else { throw AnalyticsFailure.format }
        try Task.checkCancellation()
        return Incoming(partitions: partitions, importId: history(accountId: accountId, appId: appId, partitions: partitions, omitImportTime: true).sha256)
    }
    static func summary(_ item: AnalyticsPartition) -> String {
        let type = item.source.columns.firstIndex(of: item.kind == "downloads" ? "Download Type" : "Event")!, count = item.source.columns.firstIndex(of: "Counts")!
        var totals: [String: Int] = [:]
        for row in item.source.rows { totals[row[type], default: 0] += AnalyticsReports.count(row[count])! }
        return totals.sorted { $0.key.compare($1.key, locale: Locale(identifier: "en")) == .orderedAscending }
            .map { "\($0.key): \($0.value.formatted(.number.locale(Locale(identifier: "en_US"))))" }.joined(separator: " · ")
    }
    static func review(_ previous: [AnalyticsPartition], _ incoming: [AnalyticsPartition]) throws -> (partitions: [AnalyticsPartition], changes: [Change]) {
        var old = Dictionary(uniqueKeysWithValues: previous.map { ($0.key, $0) })
        let changes = incoming.sorted { $0.key < $1.key }.map { item in
            let current = old[item.key]
            let action = current == nil ? "added" : item.processingDate < current!.processingDate ? "older" : item.processingDate == current!.processingDate && ReportTables.literalEqual(item.source, current!.source) ? "unchanged" : "replaced"
            let kept = action == "older" || action == "unchanged" ? current! : item
            let before = current.map(summary) ?? "", after = action == "older" || action == "unchanged" ? before : summary(item)
            if action == "added" || action == "replaced" { old[item.key] = item }
            return Change(key: item.key, date: item.date, action: action, beforeRows: current?.source.rows.count ?? 0, afterRows: kept.source.rows.count,
                          beforeProcessingDate: current?.processingDate, processingDate: item.processingDate, beforeActivity: before, afterActivity: after)
        }
        let merged = old.values.sorted { $0.key < $1.key }
        try check(merged); return (merged, changes)
    }
    public static func source(_ partition: AnalyticsPartition, format: Format) throws -> Data {
        guard format != .historyJson else { throw AnalyticsFailure.format }
        let metadata = try AnalyticsMetadata(kind: partition.kind, level: partition.level, granularity: partition.granularity, processingDate: partition.processingDate)
        let source = try ReportTables.validatedAnalyticsSource(partition.source, metadata: metadata)
        let bytes = Data(try ReportTables.text(source, format: format == .sourceCsv ? .csv : .txt).utf8)
        return format == .sourceGzip ? try ReportFiles.gzip(bytes) : bytes
    }
}

public struct AnalyticsFileState: Sendable {
    public let partitions: [AnalyticsPartition]
    let account: Account, appId: String, revision: PartitionedReports.Revision
}
public struct AnalyticsFileReview: Sendable {
    public let partitions: [AnalyticsPartition], changes: [AnalyticsFileFormats.Change], importId: String
    let account: Account, appId: String, revision: PartitionedReports.Revision
}

extension WorkspaceSession {
    func analyticsFileScope(_ account: Account, appId: String) throws {
        try AnalyticsFileFormats.identity(accountId: account.id, appId: appId)
        guard try currentAccount(account).appIds.contains(appId) else { throw AnalyticsFailure.scope }
    }
    func analyticsLegacyScope(accountId: String, appId: String, store: EncryptedDocumentStore) throws {
        guard try store.document(namespace: "analytics_index", key: "\(accountId):\(appId)") == nil,
              let legacy = try store.document(namespace: "analytics", key: "\(accountId):\(appId)") else { return }
        let value = try JSONText.parse(legacy.payload)
        guard value["schemaVersion"] == .number(1), value["accountId"]?.text == accountId, value["appId"]?.text == appId,
              case .array? = value["partitions"] else { throw AnalyticsFileFailure.storage }
    }
    /// Visit one stored month at a time, validating source ownership and complete-history counts as we go.
    func visitAnalyticsFiles(accountId: String, appId: String, store: EncryptedDocumentStore, visit: ([AnalyticsPartition]) throws -> Void) throws {
        do {
            try AnalyticsFileFormats.identity(accountId: accountId, appId: appId)
            let scope = "\(accountId):\(appId)"; var keys = Set<String>(), counts = 0
            if let document = try store.document(namespace: "analytics_index", key: scope) {
                let index = try JSONDecoder().decode(PartitionedReports.Index.self, from: document.payload)
                guard index.schemaVersion == 1, index.accountId == accountId, index.appId == appId else { throw AnalyticsFileFailure.storage }
                for (bucket, entry) in index.buckets.sorted(by: { $0.key < $1.key }) {
                    try Task.checkCancellation()
                    guard entry.fingerprint.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
                          let part = try store.document(namespace: "analytics_part", key: "\(scope):\(bucket):\(entry.fingerprint.prefix(32))") else { throw AnalyticsFileFailure.storage }
                    let saved = try JSONDecoder().decode(PartitionedReports.Bucket<AnalyticsPartition>.self, from: part.payload)
                    guard saved.schemaVersion == 1, saved.accountId == accountId, saved.appId == appId, saved.bucket == bucket, saved.items.count == entry.items,
                          saved.items.allSatisfy({ $0.bucket == bucket }), JSONText.array(saved.items.map(\.json)).sha256 == entry.fingerprint else { throw AnalyticsFileFailure.storage }
                    let items = try AnalyticsFileFormats.normalize(saved.items, accountId: accountId, appId: appId)
                    try AnalyticsFileFormats.check(items, keys: &keys, counts: &counts)
                    try visit(items)
                }
            } else if let legacy = try store.document(namespace: "analytics", key: scope) {
                let value = try JSONText.parse(legacy.payload)
                guard value["schemaVersion"] == .number(1), value["accountId"]?.text == accountId, value["appId"]?.text == appId,
                      case .array(let raw)? = value["partitions"] else { throw AnalyticsFileFailure.storage }
                let items = try AnalyticsFileFormats.normalize(raw.map { try JSONDecoder().decode(AnalyticsPartition.self, from: $0.data) }, accountId: accountId, appId: appId)
                try AnalyticsFileFormats.check(items, keys: &keys, counts: &counts); try visit(items)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as ReportFiles.Failure { throw failure }
        catch let failure as ReportTables.ExportFailure { throw failure }
        catch { throw AnalyticsFileFailure.storage }
    }
    func analyticsFileSnapshot(account: Account, appId: String) throws -> AnalyticsFileState {
        try analyticsFileScope(account, appId: appId); try Task.checkCancellation()
        return try storeAccess { store in
            let mutex = store.directory.appendingPathComponent("analytics-\(JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(32)).mutex")
            return try FileMutex.withLock(mutex) {
                try self.analyticsFileScope(account, appId: appId); try Task.checkCancellation()
                let revision = try PartitionedReports.revision(family: "analytics", accountId: account.id, appId: appId, store: store)
                var partitions: [AnalyticsPartition] = []
                try self.visitAnalyticsFiles(accountId: account.id, appId: appId, store: store) { partitions += $0 }
                return AnalyticsFileState(partitions: partitions.sorted { $0.key < $1.key }, account: account, appId: appId, revision: revision)
            }
        }
    }
    public func savedAnalyticsFiles(account: Account, appId: String) throws -> AnalyticsFileState { try analyticsFileSnapshot(account: account, appId: appId) }
    public func previewAnalyticsFiles(account: Account, appId: String, input: AnalyticsFileInput, now: Date = Date()) throws -> AnalyticsFileReview {
        try analyticsFileScope(account, appId: appId)
        let incoming = try AnalyticsFileFormats.parse(input, accountId: account.id, appId: appId, now: now), saved = try analyticsFileSnapshot(account: account, appId: appId)
        let review = try AnalyticsFileFormats.review(saved.partitions, incoming.partitions)
        return AnalyticsFileReview(partitions: incoming.partitions, changes: review.changes, importId: incoming.importId, account: account, appId: appId, revision: saved.revision)
    }
    public func saveAnalyticsFiles(_ review: AnalyticsFileReview, input: AnalyticsFileInput, now: Date = Date()) throws -> [AnalyticsFileFormats.Change] {
        try analyticsFileScope(review.account, appId: review.appId)
        let incoming = try AnalyticsFileFormats.parse(input, accountId: review.account.id, appId: review.appId, now: now)
        guard incoming.importId == review.importId else { throw AnalyticsFileFailure.changedFiles }
        var changes: [AnalyticsFileFormats.Change] = []
        do {
            try storeAccess { store in
                try PartitionedReports.replaceAll(AnalyticsPartition.self, family: "analytics", legacyKey: "partitions", accountId: review.account.id, appId: review.appId, store: store,
                                                  stateDirectory: store.directory, bucketOf: \.bucket, encode: \.json, view: (1, { try AnalyticsReports.view($0) }), expected: review.revision,
                                                  validate: { try self.analyticsFileScope(review.account, appId: review.appId); try Task.checkCancellation() }) { previous, _ in
                    try self.analyticsLegacyScope(accountId: review.account.id, appId: review.appId, store: store)
                    let old = try AnalyticsFileFormats.normalize(previous ?? [], accountId: review.account.id, appId: review.appId)
                    let merged = try AnalyticsFileFormats.review(old, incoming.partitions); changes = merged.changes; return (merged.partitions, nil)
                }
            }
        } catch PartitionedReports.Failure.stale { throw AnalyticsFileFailure.stale }
        return changes
    }
    public func removeAnalyticsFilePeriod(_ saved: AnalyticsFileState, key: String) throws {
        try analyticsFileScope(saved.account, appId: saved.appId); try Task.checkCancellation()
        do {
            try storeAccess { store in
                try PartitionedReports.replaceAll(AnalyticsPartition.self, family: "analytics", legacyKey: "partitions", accountId: saved.account.id, appId: saved.appId, store: store,
                                                  stateDirectory: store.directory, bucketOf: \.bucket, encode: \.json, view: (1, { try AnalyticsReports.view($0) }), expected: saved.revision,
                                                  validate: { try self.analyticsFileScope(saved.account, appId: saved.appId); try Task.checkCancellation() }) { previous, _ in
                    try self.analyticsLegacyScope(accountId: saved.account.id, appId: saved.appId, store: store)
                    let old = try AnalyticsFileFormats.normalize(previous ?? [], accountId: saved.account.id, appId: saved.appId)
                    guard old.contains(where: { $0.key == key }) else { throw AnalyticsFileFailure.stale }
                    return (old.filter { $0.key != key }, nil)
                }
            }
        } catch PartitionedReports.Failure.stale { throw AnalyticsFileFailure.stale }
    }
    /// Full JSON export keeps only one validated month in memory and publishes the output file atomically.
    public func writeAnalyticsFile(account: Account, appId: String, key: String? = nil, format: AnalyticsFileFormats.Format, to url: URL) throws {
        try analyticsFileScope(account, appId: appId); try Task.checkCancellation(); try TestIsolation.check(url)
        try storeAccess { store in
            let mutex = store.directory.appendingPathComponent("analytics-\(JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(32)).mutex")
            try FileMutex.withLock(mutex) {
                try self.analyticsFileScope(account, appId: appId); try Task.checkCancellation()
                let revision = try PartitionedReports.revision(family: "analytics", accountId: account.id, appId: appId, store: store)
                guard revision.index != nil || revision.legacy != nil else { throw AnalyticsFileFailure.missing }
                try ReportFiles.atomicStream(to: url) { append in
                    var first = true, found = false
                    if format == .historyJson {
                        let header = String(JSONText.object([("schemaVersion", .number(1)), ("accountId", .string(account.id)), ("appId", .string(appId))]).stringify().dropLast())
                        try append(Data((header + ",\"partitions\":[").utf8))
                    }
                    try self.visitAnalyticsFiles(accountId: account.id, appId: appId, store: store) { items in
                        for item in items {
                            try Task.checkCancellation()
                            if format == .historyJson { if !first { try append(Data([44])) }; try append(item.json.data); first = false }
                            else if item.key == key { try append(AnalyticsFileFormats.source(item, format: format)); found = true }
                        }
                    }
                    if format == .historyJson { try append(Data("]}".utf8)) } else if !found { throw AnalyticsFileFailure.missing }
                    try self.analyticsFileScope(account, appId: appId); try Task.checkCancellation()
                }
            }
        }
    }
}
