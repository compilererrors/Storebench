import Foundation

public enum PricingCalculation {
    /// One deadline covers the entire preview, including queueing, pagination and retries.
    public static func run<Value: Sendable>(timeout: Duration = .seconds(60), operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout, clock: .continuous)
                throw PricingFailure.invalid("The calculation took too long and was stopped. Try again; saved index data and completed Apple price reads will be reused. No prices were changed.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

extension WorkspaceSession {
    /// Only previews use these complete, dated catalogs. Guarded publishing still checks Apple's current price points again.
    func previewPricePoints(_ owner: PriceOwner, territories: [String], client: AppStoreConnectClient, now: Date = Date(),
                            progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> (points: [PricePoint], failed: Set<String>) {
        let codes = Array(Set(territories)).sorted(), account = client.token.account
        let kind, id: String
        switch owner { case .app(let value): (kind, id) = ("app", value); case .subscription(let value): (kind, id) = ("subscription", value); case .purchase(let value): (kind, id) = ("purchase", value) }
        let scope = JSONText.array([client.origin.absoluteString, account.id, account.keyId, account.issuerId ?? "", account.keyType, kind, id].map { .string($0) }).sha256
        func key(_ code: String) -> String { scope + ":" + code }
        var points: [PricePoint] = [], missing: [String] = []
        try storeAccess { store in
            for code in codes {
                guard let document = try store.document(namespace: "pricing_point_cache", key: key(code)), document.payload.count <= 2_000_000,
                      let value = try? JSONText.parse(document.payload), value["schemaVersion"] == .number(1), value["territory"]?.text == code,
                      case .number(let stamp)? = value["fetchedAt"], stamp <= now.timeIntervalSince1970 + 60, now.timeIntervalSince1970 - stamp < 86_400,
                      case .array(let rows)? = value["points"], !rows.isEmpty, rows.count <= 10_000 else { missing.append(code); continue }
                let loaded = rows.compactMap { row -> PricePoint? in
                    guard let id = row["id"]?.text, !id.isEmpty, id.utf8.count <= 4096,
                          let amount = row["amount"]?.text, PricingMath.decimal(amount).map({ $0 >= 0 }) == true else { return nil }
                    return PricePoint(id: id, territory: code, customerPrice: amount)
                }
                if loaded.count == rows.count { points += loaded } else { missing.append(code) }
            }
        }
        let reused = codes.count - missing.count
        await progress(reused, codes.count)
        guard !missing.isEmpty else { try Task.checkCancellation(); return (points, []) }
        let loaded = try await PricePointCatalog.readAll(owner, territories: missing, client: client, progress: { done, _ in await progress(reused + done, codes.count) },
            completed: { points, failed in try await self.rememberPreviewPoints(points, failed: failed, scope: scope, now: now) })
        try Task.checkCancellation()
        return (points + loaded.points, loaded.failed)
    }

    /// Commit each completed batch so cancellation or a later batch failure never discards useful reads.
    private func rememberPreviewPoints(_ points: [PricePoint], failed: Set<String>, scope: String, now: Date) throws {
        try Task.checkCancellation()
        let grouped = Dictionary(grouping: points, by: \.territory)
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("pricing_point_cache.mutex")) {
                try store.withoutChangeStamp {
                    try store.transaction { current in
                        try grouped.keys.sorted().compactMap { code -> EncryptedDocumentStore.Write? in
                            let key = scope + ":" + code
                            guard !failed.contains(code), let rows = grouped[code], !rows.isEmpty else { return nil }
                            if let document = try current("pricing_point_cache", key), let value = try? JSONText.parse(document.payload),
                               case .number(let stamp)? = value["fetchedAt"], stamp > now.timeIntervalSince1970 { return nil }
                            let value = JSONText.object([("schemaVersion", .number(1)), ("territory", .string(code)), ("fetchedAt", .number(now.timeIntervalSince1970)),
                                ("points", .array(rows.map { .object([("id", .string($0.id)), ("amount", .string($0.customerPrice))]) }))])
                            guard value.data.count <= 2_000_000 else { return nil }
                            return .put(namespace: "pricing_point_cache", key: key, json: value.data)
                        }
                    }
                }
            }
        }
    }
}
