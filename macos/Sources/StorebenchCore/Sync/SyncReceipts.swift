import CryptoKit
import Foundation

/// Disposable content checks in a bounded encrypted cache.
public struct SyncReceipt: Sendable, Equatable {
    public enum Outcome: String, Sendable { case withApp = "with-app", noApp = "no-app", noSales = "no-sales", unavailable }
    public let key, remote, local, checkedAt: String
    public let outcome: Outcome
    public init(key: String, remote: String, local: String, checkedAt: String, outcome: Outcome) {
        self.key = key; self.remote = remote; self.local = local; self.checkedAt = checkedAt; self.outcome = outcome
    }
    public var json: JSONText { .object([("key", .string(key)), ("remote", .string(remote)), ("local", .string(local)), ("checkedAt", .string(checkedAt)), ("outcome", .string(outcome.rawValue))]) }
    static func hash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    public init(json: JSONText) throws {
        guard let key = json["key"]?.text, Self.hash(key), let remote = json["remote"]?.text, Self.hash(remote), let local = json["local"]?.text, Self.hash(local),
              let checked = json["checkedAt"]?.text, ReportTimestamps.valid(checked), let outcome = json["outcome"]?.text.flatMap(Outcome.init(rawValue:)) else { throw SyncFailure.status }
        self.init(key: key, remote: remote, local: local, checkedAt: checked, outcome: outcome)
    }
    public func binding(local: String) -> Self { Self(key: key, remote: remote, local: local, checkedAt: checkedAt, outcome: outcome) }
    public func freshSales(local: String, day: String, now: Date) -> Bool {
        guard self.local == local, let checked = ReportTimestamps.date(checkedAt), let date = ReportTimestamps.date(day + "T00:00:00Z") else { return false }
        let recent = now.timeIntervalSince(date) < 4 * 86_400
        let ttl: Double = outcome == .unavailable ? (recent ? 900 : 21_600) : (recent ? 3_600 : 86_400)
        let age = now.timeIntervalSince(checked); return age >= 0 && age < ttl
    }
    public static func bytesFingerprint(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    public static func salesKey(vendor: String, reporterAccount: String?, sku: String?, scope: ProductScope, day: String) -> String {
        JSONText.array([.string("sales-v3"), .string(vendor), .string(reporterAccount ?? "api"), .string(sku ?? ""),
                        .object([("ids", .array(scope.ids.map(JSONText.string))), ("complete", .bool(scope.complete))]), .string(day)]).sha256
    }
    public static func analyticsKey(kind: String, level: String, granularity: String, instance: String, processingDate: String) -> String {
        JSONText.array([.string("analytics-v1"), .string(kind), .string(level), .string(granularity), .string(instance), .string(processingDate)]).sha256
    }
    public static func analyticsLocal(_ buckets: [(String, String)], kind: String, level: String, granularity: String) -> String {
        let prefix = "\(kind):\(level):\(granularity):"
        return JSONText.array(buckets.filter { $0.0.hasPrefix(prefix) }.sorted { $0.0 < $1.0 }.map { .array([.string($0.0), .string($0.1)]) }).sha256
    }
}

public struct SyncReceipts: Sendable, Equatable {
    public let accountId, appId: String
    public let entries: [SyncReceipt]
    public init(accountId: String, appId: String, entries: [SyncReceipt]) { self.accountId = accountId; self.appId = appId; self.entries = entries }
    public var json: JSONText { .object([("schemaVersion", .number(1)), ("accountId", .string(accountId)), ("appId", .string(appId)), ("entries", .array(entries.map(\.json)))]) }
    public init(json: JSONText) throws {
        guard json["schemaVersion"] == .number(1), let account = json["accountId"]?.text, let app = json["appId"]?.text, case .array(let values)? = json["entries"], values.count <= 1000 else { throw SyncFailure.status }
        let entries = try values.map(SyncReceipt.init)
        guard Set(entries.map(\.key)).count == entries.count else { throw SyncFailure.status }
        self.init(accountId: account, appId: app, entries: entries)
    }
    public func merging(_ incoming: [SyncReceipt]) throws -> Self {
        let valid = try Self(json: Self(accountId: accountId, appId: appId, entries: incoming).json), replaced = Set(valid.entries.map(\.key))
        let values = (entries.filter { !replaced.contains($0.key) } + valid.entries).enumerated().sorted {
            let comparison = $0.element.checkedAt.compare($1.element.checkedAt, locale: Locale(identifier: "en_US"))
            return comparison == .orderedSame ? $0.offset < $1.offset : comparison == .orderedDescending
        }.prefix(1000).map(\.element)
        return try Self(json: Self(accountId: accountId, appId: appId, entries: values).json)
    }
}

extension WorkspaceSession {
    func syncReceiptMutex(accountId: String, appId: String) throws -> URL {
        _ = try ReportJobs.identity(.sync, accountId: accountId, appId: appId)
        return try storeAccess { $0.directory.appendingPathComponent("sync_receipts_\(JSONText.string("\(accountId)\u{0}\(appId)").rawSHA256.prefix(32)).mutex") }
    }
    public func syncReceipts(accountId: String, appId: String) -> SyncReceipts? {
        do {
            _ = try ReportJobs.identity(.sync, accountId: accountId, appId: appId)
            guard let saved = try storeAccess({ try $0.document(namespace: "sync_receipts", key: "\(accountId):\(appId)") }) else { return nil }
            let value = try SyncReceipts(json: JSONText.parse(saved.payload))
            return value.accountId == accountId && value.appId == appId ? value : nil
        } catch { return nil }
    }
    /// Cache writes are optional; immutable report content and its completed receipt remain authoritative.
    func rememberSyncReceipts(account: Account, appId: String, entries: [SyncReceipt]) {
        guard !entries.isEmpty else { return }
        do {
            try reviewsScope(account, appId: appId); try Task.checkCancellation()
            let incoming = try SyncReceipts(json: SyncReceipts(accountId: account.id, appId: appId, entries: entries).json)
            try FileMutex.withLock(syncReceiptMutex(accountId: account.id, appId: appId)) {
                try reviewsScope(account, appId: appId); try Task.checkCancellation()
                try storeAccess { store in try store.transaction { current in
                    try reviewsScope(account, appId: appId); try Task.checkCancellation()
                    let key = "\(account.id):\(appId)", previous = try current("sync_receipts", key).map { try SyncReceipts(json: JSONText.parse($0.payload)) }
                    guard previous == nil || previous?.accountId == account.id && previous?.appId == appId else { throw SyncFailure.status }
                    let next = try (previous ?? SyncReceipts(accountId: account.id, appId: appId, entries: [])).merging(incoming.entries)
                    return [.put(namespace: "sync_receipts", key: key, json: next.json.data)]
                } }
            }
        } catch { /* A disposable cache failure cannot invalidate a completed report save. */ }
    }
}
