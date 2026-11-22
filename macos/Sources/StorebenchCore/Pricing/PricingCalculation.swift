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
    /// Only previews use these dated price lists. Guarded publishing still checks Apple's current price points again.
    /// `needs` names the highest amount a country's rounding can use; its list is read only that far, and a saved list is reused
    /// when it is complete or reaches that amount. A country without a need reads its complete list. `loaded` receives each
    /// country's points as they are read, so a preview can fill in country by country.
    func previewPricePoints(_ owner: PriceOwner, territories: [String], needs: [String: Decimal] = [:], client: AppStoreConnectClient, now: Date = Date(),
                            progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
                            loaded: @escaping @Sendable ([PricePoint]) async -> Void = { _ in }) async throws -> (points: [PricePoint], failed: Set<String>) {
        let codes = Array(Set(territories)).sorted(), account = client.token.account
        let kind, id: String
        switch owner { case .app(let value): (kind, id) = ("app", value); case .subscription(let value): (kind, id) = ("subscription", value); case .purchase(let value): (kind, id) = ("purchase", value) }
        let scope = JSONText.array([client.origin.absoluteString, account.id, account.keyId, account.issuerId ?? "", account.keyType, kind, id].map { .string($0) }).sha256
        func key(_ code: String) -> String { scope + ":" + code }
        var points: [PricePoint] = [], missing: [String] = []
        try storeAccess { store in
            for code in codes {
                guard let document = try store.document(namespace: "pricing_point_cache", key: key(code)), document.payload.count <= 2_000_000,
                      let value = try? JSONText.parse(document.payload), let saved = Self.savedPricePoints(value, territory: code, now: now),
                      saved.through.map({ through in needs[code].map { through >= $0 } ?? false }) ?? true else { missing.append(code); continue }
                points += saved.points
            }
        }
        if !points.isEmpty { await loaded(points) }
        let reused = codes.count - missing.count
        await progress(reused, codes.count)
        guard !missing.isEmpty else { try Task.checkCancellation(); return (points, []) }
        final class Collected: @unchecked Sendable {
            let lock = NSLock(); var points: [PricePoint] = [], failed = Set<String>(), done = 0
        }
        let collected = Collected()
        let wanted = Dictionary(uniqueKeysWithValues: missing.map { ($0, needs[$0]) })
        try await PricePointCatalog.readNeeded(owner, needs: wanted, client: client) { code, read, complete, failed in
            let done = collected.lock.withLock {
                if failed { collected.failed.insert(code) } else { collected.points += read }
                collected.done += 1; return collected.done
            }
            if !failed { try await self.rememberPreviewPoints(read, territory: code, through: complete ? nil : read.compactMap { PricingMath.decimal($0.customerPrice) }.max(), scope: scope, now: now) }
            if !failed, !read.isEmpty { await loaded(read) }
            await progress(reused + done, codes.count)
        }
        try Task.checkCancellation()
        return collected.lock.withLock { (points + collected.points, collected.failed) }
    }

    /// A saved price list that is under a day old: its points, and the highest amount read when the list stopped early.
    /// Lists saved before partial reads existed are complete.
    static func savedPricePoints(_ value: JSONText, territory code: String, now: Date) -> (points: [PricePoint], through: Decimal?)? {
        guard value["schemaVersion"] == .number(1) || value["schemaVersion"] == .number(2), value["territory"]?.text == code,
              case .number(let stamp)? = value["fetchedAt"], stamp <= now.timeIntervalSince1970 + 60, now.timeIntervalSince1970 - stamp < 86_400,
              case .array(let rows)? = value["points"], !rows.isEmpty, rows.count <= 10_000 else { return nil }
        var through: Decimal?
        if let text = value["through"]?.text {
            guard value["schemaVersion"] == .number(2), let amount = PricingMath.decimal(text) else { return nil }
            through = amount
        }
        let loaded = rows.compactMap { row -> PricePoint? in
            guard let id = row["id"]?.text, !id.isEmpty, id.utf8.count <= 4096,
                  let amount = row["amount"]?.text, PricingMath.decimal(amount).map({ $0 >= 0 }) == true else { return nil }
            return PricePoint(id: id, territory: code, customerPrice: amount)
        }
        return loaded.count == rows.count ? (loaded, through) : nil
    }

    /// Saves each country as soon as it is read, so cancellation or a later failure never discards useful reads. A newer list
    /// is never replaced by an older one.
    private func rememberPreviewPoints(_ rows: [PricePoint], territory code: String, through: Decimal?, scope: String, now: Date) throws {
        try Task.checkCancellation()
        guard !rows.isEmpty else { return }
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("pricing_point_cache.mutex")) {
                try store.withoutChangeStamp {
                    try store.transaction { current in
                        let key = scope + ":" + code
                        if let document = try current("pricing_point_cache", key), let value = try? JSONText.parse(document.payload),
                           case .number(let stamp)? = value["fetchedAt"], stamp > now.timeIntervalSince1970 { return [] }
                        var fields: [(String, JSONText)] = [("schemaVersion", .number(2)), ("territory", .string(code)), ("fetchedAt", .number(now.timeIntervalSince1970))]
                        if let through { fields.append(("through", .string(PricingMath.text(through)))) }
                        fields.append(("points", .array(rows.map { .object([("id", .string($0.id)), ("amount", .string($0.customerPrice))]) })))
                        let value = JSONText.object(fields)
                        guard value.data.count <= 2_000_000 else { return [] }
                        return [.put(namespace: "pricing_point_cache", key: key, json: value.data)]
                    }
                }
            }
        }
    }
}
