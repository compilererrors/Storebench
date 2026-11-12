import Foundation

/// Country schedules are read through once per app, then shared by open pricing views. A publication invalidates the
/// persisted observation before sending anything, so an older read cannot become the new saved baseline.
struct PricingReadToken: Equatable, Sendable {
    let invalidation: Data?
    let needsRefresh: Bool
    var confirmed: Data? {
        guard let invalidation, let value = try? JSONText.parse(invalidation), let generation = value["generation"] else { return nil }
        return JSONText.object([("generation", generation), ("pending", .bool(false))]).data
    }
}
struct PricingReadJob: Sendable { let id: UUID; let task: Task<Void, Error> }
public enum PricingReadEvent: Sendable { case pricesRead, publicationFinished }
struct PricingReadObserver: Sendable { let key: String; let continuation: AsyncStream<PricingReadEvent>.Continuation }

enum PricingScheduleRead {
    enum Failure: Error, Equatable { case timeout }
    /// A deadline for the complete schedule, including queueing, retries and every page.
    static func run(timeout: Duration = .seconds(30), operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: timeout, clock: .continuous); throw Failure.timeout }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

extension PublishRequest {
    var changesCountryPrices: Bool {
        scope == .pricing || (scope == .pricingSetup && (pricingSetup?.action == .appPrice || pricingSetup?.action == .temporaryAppPrice))
    }
}

extension WorkspaceSession {
    func pricingReadToken(accountId: String, appId: String) throws -> PricingReadToken {
        try storeAccess { store in
            guard let document = try store.document(namespace: "pricing_refresh", key: accountId + ":" + appId) else { return PricingReadToken(invalidation: nil, needsRefresh: false) }
            let value = try JSONText.parse(document.payload)
            guard let generation = value["generation"]?.text, UUID(uuidString: generation) != nil, case .bool(let pending)? = value["pending"] else { throw PricingFailure.read }
            return PricingReadToken(invalidation: document.payload, needsRefresh: pending)
        }
    }

    /// The generation stays after confirmation, so a pre-publication read cannot match again after the refresh completes.
    func invalidatePricing(accountId: String, appId: String) throws {
        let key = accountId + ":" + appId
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("pricing_readback.mutex")) {
                try store.transaction { _ in [.put(namespace: "pricing_refresh", key: key, json: JSONText.object([("generation", .string(UUID().uuidString)), ("pending", .bool(true))]).data)] }
            }
        }
        pricingReadJobs.removeValue(forKey: key)?.task.cancel()
    }

    /// Reads missing or older schedules automatically. Explicit refresh and post-publication reads bypass freshness and
    /// failure backoff. The session owns the read, so navigating away does not discard data needed by the next view.
    public func refreshCountryPrices(account: Account, appId: String, client: AppStoreConnectClient, force: Bool = false, now: Date = Date()) async throws {
        _ = try currentAccount(account, client: client); try reviewsScope(account, appId: appId); try Task.checkCancellation()
        let key = account.id + ":" + appId
        let job: PricingReadJob
        if let running = pricingReadJobs[key] { job = running }
        else {
            if !force {
                let saved = try savedPricing(accountId: account.id, appId: appId)
                if let saved, let checked = ReportTimestamps.date(saved.checkedAt), saved.code != nil,
                   (0..<30).contains(now.timeIntervalSince(checked)) { return }
                if try !pricingReadToken(accountId: account.id, appId: appId).needsRefresh,
                   let saved, saved.code == nil, let snapshot = saved.snapshot, let fetched = ReportTimestamps.date(snapshot.fetchedAt),
                   (0..<300).contains(now.timeIntervalSince(fetched)) { return }
            }
            let id = UUID()
            let task = Task { [self] in
                let token = try pricingReadToken(accountId: account.id, appId: appId)
                do {
                    try await PricingScheduleRead.run { [self] in
                        try await ScreenReads.reading(fresh: true) {
                            _ = try await refreshPricing(account: account, appId: appId, client: client, now: now)
                        }
                    }
                } catch PricingScheduleRead.Failure.timeout {
                    try? savePricing(accountId: account.id, appId: appId, checkedAt: CustomerReview.isoString(now), snapshot: nil, code: "SB-SYNC-PRICING", readToken: token)
                    throw PricingScheduleRead.Failure.timeout
                }
            }
            job = PricingReadJob(id: id, task: task); pricingReadJobs[key] = job
        }
        defer { if pricingReadJobs[key]?.id == job.id { pricingReadJobs.removeValue(forKey: key) } }
        try await job.task.value
        try Task.checkCancellation()
    }

    /// Runs after the publishing lock has been released, for completed and partially applied price reviews alike.
    /// Read failure never changes the result of an approved write and never retries a write.
    func readPricingAfterPublishing(account: Account, appId: String, client: AppStoreConnectClient) async {
        defer { pricingDidChange(accountId: account.id, appId: appId, event: .publicationFinished) }
        do {
            try invalidatePricing(accountId: account.id, appId: appId)
            try await refreshCountryPrices(account: account, appId: appId, client: client, force: true)
        } catch { }
    }

    /// Open views reread local state without replacing editors or their search, selection and scroll positions.
    public func pricingChanges(account: Account, appId: String) throws -> AsyncStream<PricingReadEvent> {
        _ = try currentAccount(account); try reviewsScope(account, appId: appId)
        let id = UUID(), pair = AsyncStream<PricingReadEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pricingReadObservers[id] = PricingReadObserver(key: account.id + ":" + appId, continuation: pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removePricingObserver(id) } }
        return pair.stream
    }

    private func removePricingObserver(_ id: UUID) { pricingReadObservers.removeValue(forKey: id) }
    func pricingDidChange(accountId: String, appId: String, event: PricingReadEvent = .pricesRead) {
        for observer in pricingReadObservers.values where observer.key == accountId + ":" + appId { observer.continuation.yield(event) }
    }

    func cancelPricingReads() {
        for job in pricingReadJobs.values { job.task.cancel() }
        for observer in pricingReadObservers.values { observer.continuation.finish() }
        pricingReadJobs.removeAll(); pricingReadObservers.removeAll()
    }
}
