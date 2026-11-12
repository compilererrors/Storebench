import Foundation

/// Encrypted discovery receipts survive reopening. A failed read never makes an older app list fresh.
struct AppCatalogFreshness: Codable, Sendable {
    static let lifetime: TimeInterval = 15 * 60
    let connection: String
    var checkedAt: Date?, failedAt: Date?, failures: Int

    static func connection(_ account: Account) -> String {
        JSONText.array([account.id, account.keyId, account.keyType, account.issuerId ?? ""].map(JSONText.string)).sha256
    }
    static func success(_ account: Account, at: Date) -> Self {
        .init(connection: connection(account), checkedAt: at, failedAt: nil, failures: 0)
    }
    func isDue(_ account: Account, at: Date) -> Bool {
        guard connection == Self.connection(account) else { return true }
        if let failedAt {
            let elapsed = at.timeIntervalSince(failedAt), delay = min(3600, 60 * pow(2, Double(max(0, min(6, failures - 1)))))
            return elapsed < 0 || elapsed >= delay
        }
        guard let checkedAt else { return true }
        let elapsed = at.timeIntervalSince(checkedAt)
        return elapsed < 0 || elapsed >= Self.lifetime
    }
    static func read(_ document: EncryptedDocumentStore.Document?) throws -> Self? {
        try document.map {
            let value = try JSONDecoder().decode(Self.self, from: $0.payload)
            guard (0...7).contains(value.failures) else { throw AccountFailure.invalid }
            return value
        }
    }
    func write(account: Account) throws -> EncryptedDocumentStore.Write {
        .put(namespace: "app_catalog_reads", key: account.id, json: try JSONEncoder().encode(self))
    }
}

extension WorkspaceSession {
    func appCatalogNeedsRefresh(now: Date = Date()) throws -> Bool {
        try accounts().contains { account in
            guard AppleRequestBudget.allowsReadingAhead(keyId: account.keyId) else { return false }
            return try catalogIsDue(account, now: now)
        }
    }
    func catalogIsDue(_ account: Account, now: Date) throws -> Bool {
        try storeAccess { store in
            try AppCatalogFreshness.read(store.document(namespace: "app_catalog_reads", key: account.id))?.isDue(account, at: now) ?? true
        }
    }
    func recordCatalogFailure(_ account: Account, started: Date, now: Date) throws {
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("accounts.mutex")) {
                try store.transaction { read in
                    _ = try currentAccount(account, exact: true)
                    let saved = try AppCatalogFreshness.read(read("app_catalog_reads", account.id))
                    // An older failure cannot replace a newer successful read or another connection's receipt.
                    if let saved, saved.connection == AppCatalogFreshness.connection(account),
                       max(saved.checkedAt ?? .distantPast, saved.failedAt ?? .distantPast) > started { return [] }
                    var stamp = saved.flatMap { $0.connection == AppCatalogFreshness.connection(account) ? $0 : nil }
                        ?? AppCatalogFreshness(connection: AppCatalogFreshness.connection(account), checkedAt: nil, failedAt: nil, failures: 0)
                    stamp.failedAt = now; stamp.failures = min(7, stamp.failures + 1)
                    return [try stamp.write(account: account)]
                }
            }
        }
    }
}
