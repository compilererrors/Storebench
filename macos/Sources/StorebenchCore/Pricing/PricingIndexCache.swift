import Foundation

/// Published observations stay in the encrypted database, independently of any app or chosen guide country.
/// A calculation can reuse them immediately; the delayed background read cycle refreshes them once a week.
struct PricingIndexData: Sendable {
    static let freshness: TimeInterval = 7 * 86_400
    static let maximumAge: TimeInterval = 366 * 86_400
    let method: PricingMethod, data: Data, metadata: Data, fetched: Date

    func snapshot(catalog: [Territory], cached: Bool) throws -> IndexSnapshot {
        let currencies = Dictionary(catalog.map { ($0.code, $0.currency) }, uniquingKeysWith: { first, _ in first })
        var value: IndexSnapshot
        if method == .bigmac {
            guard let csv = String(data: data, encoding: .utf8) else { throw PricingFailure.unavailable }
            value = try PricingModels.bigMac(csv, currencies: currencies)
        } else { value = try PricingModels.worldBank(data: data, metadata: metadata, currencies: currencies) }
        value.fetchedAt = CustomerReview.isoString(fetched); value.cached = cached
        return value
    }

    var json: JSONText {
        .object([("schemaVersion", .number(1)), ("method", .string(method.rawValue)), ("fetchedAt", .number(fetched.timeIntervalSince1970)),
                 ("data", .string(data.base64EncodedString())), ("metadata", .string(metadata.base64EncodedString()))])
    }
    init(method: PricingMethod, data: Data, metadata: Data, fetched: Date) {
        self.method = method; self.data = data; self.metadata = metadata; self.fetched = fetched
    }
    init?(_ document: EncryptedDocumentStore.Document?, method: PricingMethod, now: Date) {
        guard let document, document.payload.count <= 12_000_000, let value = try? JSONText.parse(document.payload),
              value["schemaVersion"] == .number(1), value["method"]?.text == method.rawValue,
              case .number(let stamp)? = value["fetchedAt"], stamp.isFinite,
              stamp <= now.timeIntervalSince1970 + 60, now.timeIntervalSince1970 - stamp <= Self.maximumAge,
              let text = value["data"]?.text, let data = Data(base64Encoded: text), data.count <= 8_000_000,
              let meta = value["metadata"]?.text, let metadata = Data(base64Encoded: meta), metadata.count <= 256_000 else { return nil }
        self.init(method: method, data: data, metadata: metadata, fetched: Date(timeIntervalSince1970: stamp))
    }
}

extension WorkspaceSession {
    private func savedIndex(_ method: PricingMethod, now: Date) throws -> PricingIndexData? {
        try storeAccess { PricingIndexData(try $0.document(namespace: "pricing_index_cache", key: method.rawValue), method: method, now: now) }
    }

    public func pricingIndex(method: PricingMethod, catalog: [Territory], sources: PricingSources = PricingSources(), now: Date = Date()) async throws -> IndexSnapshot {
        guard method.usesIndex else { throw PricingFailure.invalid("Choose a published pricing index.") }
        try Task.checkCancellation()
        if let saved = try savedIndex(method, now: now), let value = try? saved.snapshot(catalog: catalog, cached: true) { return value }
        do { return try await refreshPricingIndex(method, catalog: catalog, sources: sources, now: now) }
        catch let failure as PricingFailure {
            try Task.checkCancellation()
            guard sources.builtIn, var value = try? BuiltInPricingIndexes.data(method)?.snapshot(catalog: catalog, cached: true) else { throw failure }
            value.builtIn = true
            return value
        }
    }

    /// A failed refresh preserves the last validated observations. Only the exact job owner downloads or records its result.
    func refreshPricingIndex(_ method: PricingMethod, catalog: [Territory] = [], sources: PricingSources = PricingSources(), now: Date = Date()) async throws -> IndexSnapshot {
        let clock = ContinuousClock(), deadline = clock.now + .seconds(14)
        var ownership: (() -> Void)?
        while ownership == nil {
            try Task.checkCancellation()
            ownership = try storeAccess { try JobLock.acquire(directory: $0.directory, name: "pricing_index_" + method.rawValue, id: UUID().uuidString.lowercased()) }
            if ownership == nil {
                if let saved = try savedIndex(method, now: now), let value = try? saved.snapshot(catalog: catalog, cached: true) { return value }
                guard clock.now < deadline else { throw PricingFailure.invalid("The index is still being refreshed. Cancel or try again in a moment.") }
                try await Task.sleep(for: .milliseconds(50), clock: clock)
            }
        }
        defer { ownership?() }
        // Another process may have finished between the first cache read and ownership acquisition.
        if let saved = try savedIndex(method, now: now), now.timeIntervalSince(saved.fetched) < PricingIndexData.freshness,
           let value = try? saved.snapshot(catalog: catalog, cached: true) { return value }
        do {
            let data, metadata: Data
            if method == .bigmac {
                data = try await sources.fetch(sources.bigMac, limit: 8_000_000, timeout: 6); metadata = Data()
            } else {
                async let observations = sources.fetch(sources.worldBank, limit: 2_000_000, timeout: 6)
                async let units = sources.fetch(sources.worldBankCurrencies, limit: 256_000, timeout: 6)
                (data, metadata) = try await (observations, units)
            }
            try Task.checkCancellation()
            let downloaded = PricingIndexData(method: method, data: data, metadata: metadata, fetched: now)
            let value = try downloaded.snapshot(catalog: catalog, cached: false)
            // Validate the full dataset too, rather than retaining data that only happened to match one country.
            _ = try downloaded.snapshot(catalog: [], cached: false)
            try storeAccess { store in
                try FileMutex.withLock(store.directory.appendingPathComponent("pricing_index_cache.mutex")) {
                    try store.withoutChangeStamp {
                        try store.transaction { current in
                            let old = PricingIndexData(try current("pricing_index_cache", method.rawValue), method: method, now: now)
                            if let old, old.fetched > now { return [] }
                            return [.put(namespace: "pricing_index_cache", key: method.rawValue, json: downloaded.json.data)]
                        }
                    }
                }
            }
            return value
        } catch {
            try Task.checkCancellation()
            if let saved = try savedIndex(method, now: now), let value = try? saved.snapshot(catalog: catalog, cached: true) { return value }
            throw PricingFailure.invalid("\(method.name) could not be read within the time limit or returned unusable data. Try again. No prices were changed.")
        }
    }

    /// Runs after the existing app/read pipelines, with retry backoff across windows, processes and restarts.
    public func preparePricingIndexes(sources: PricingSources = PricingSources(), now: Date = Date()) async {
        for method in [PricingMethod.ppp, .bigmac] {
            guard !Task.isCancelled else { return }
            if let saved = try? savedIndex(method, now: now), now.timeIntervalSince(saved.fetched) < PricingIndexData.freshness,
               (try? saved.snapshot(catalog: [], cached: true)) != nil { continue }
            do {
                let due = try storeAccess { store in
                    try FileMutex.withLock(store.directory.appendingPathComponent("pricing_index_schedule.mutex")) {
                        var due = false
                        try store.withoutChangeStamp {
                            try store.transaction { current in
                                if let document = try current("pricing_index_schedule", method.rawValue), let value = try? JSONText.parse(document.payload),
                                   case .number(let last)? = value["attemptedAt"], last <= now.timeIntervalSince1970 + 60, now.timeIntervalSince1970 - last < 15 * 60 { return [] }
                                due = true
                                return [.put(namespace: "pricing_index_schedule", key: method.rawValue, json: JSONText.object([("attemptedAt", .number(now.timeIntervalSince1970))]).data)]
                            }
                        }
                        return due
                    }
                }
                if due { _ = try await refreshPricingIndex(method, sources: sources, now: now) }
            } catch { if Task.isCancelled { return } }
        }
    }
}
