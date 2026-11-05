import Foundation

/// Fixed parent scope and source identity; only its scoped child receipt can be bound.
struct SyncChildBinding {
    let ownership: ReportJobs.Ownership
    let accountId, appId, key: String
    var family: ReportJobs.Family {
        switch key { case "material": .material; case "sales": .sales; case "downloads": .downloads; case "engagement": .engagement; case "finance": .financial; default: .reviews }
    }
    func writes(childId: String, current: (String, String) throws -> EncryptedDocumentStore.Document?) throws -> [EncryptedDocumentStore.Write] {
        try ownership.verify(); try Task.checkCancellation()
        guard let parent = try ReportJobs.parsed(SyncJob.self, current("jobs", ownership.key), family: .sync), parent.id == ownership.id, parent.isActive, parent.accountId == accountId, parent.appId == appId, key != "pricing", AppSync.executionOrder.contains(key),
              parent.items.first(where: { $0.key == key })?.state == .running,
              let document = try current("sync_children", "\(accountId):\(appId)") else { throw SyncFailure.status }
        if let cancel = try current("job_cancels", ownership.key), try JSONText.parse(cancel.payload)["id"] == .string(ownership.id) { throw CancellationError() }
        var children = try SyncChildren(JSONText.parse(document.payload), accountId: accountId, appId: appId)
        guard children.id == ownership.id, !children.entries.contains(where: { $0.key == key }), ReportJobs.uuid(childId) else { throw SyncFailure.status }
        children.entries.append((key, childId))
        return [.put(namespace: "sync_children", key: "\(accountId):\(appId)", json: children.json.data)]
    }
}

extension WorkspaceSession {
    func bindRecoveredSyncChild(_ ownership: ReportJobs.Ownership, account: Account, appId: String, key: String, childId: String) throws {
        let binding = SyncChildBinding(ownership: ownership, accountId: account.id, appId: appId, key: key)
        try storeAccess { store in try store.transaction { current in
            let childKey = try ReportJobs.identity(binding.family, accountId: account.id, appId: appId)
            guard let document = try current("jobs", childKey) else { throw SyncFailure.status }
            let job = try JSONText.parse(document.payload)
            guard job["id"] == .string(childId), job["state"] == .string("complete") else { throw SyncFailure.status }
            return try binding.writes(childId: childId, current: current)
        } }
    }
    func syncChild<Job: PersistentReportJob>(_ type: Job.Type, family: ReportJobs.Family, id: String, account: Account, appId: String) throws -> Job {
        let key = try ReportJobs.identity(family, accountId: account.id, appId: appId)
        guard let job = try storeAccess({ try ReportJobs.parsed(type, $0.document(namespace: "jobs", key: key), family: family) }), job.id == id, !job.isActive else { throw SyncFailure.status }
        return job
    }
    func waitForSyncChild<Value: Sendable>(_ task: Task<Value, Error>?) async throws {
        guard let task else { throw SyncFailure.busy }
        _ = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation()
    }
    func syncReportingSource(account: Account) throws -> ReportingSource {
        try FileMutex.withLock(reportingMutex(accountId: account.id)) {
            _ = try currentAccount(account)
            guard let connection = try salesConnection(accountId: account.id) else { throw SalesFailure.noConnection }
            if connection.reporter != nil { return .reporter }
            guard account.keyType == "team", !connection.vendorNumber.isEmpty else { throw SalesFailure.noConnection }
            return .api
        }
    }

    /// A separate download keeps its ownership. The aggregate waits without cancelling it.
    func syncSourceIsActive(_ key: String, account: Account, appId: String) throws -> Bool {
        switch key {
        case "material": return try importJob(account: account, appId: appId)?.isActive == true
        case "sales": return try salesDownloadJob(account: account, appId: appId)?.isActive == true
        case "downloads", "engagement": return try analyticsJobRecords(account: account, appId: appId).contains { $0.isActive }
        case "finance": return try financialDownloadJob(account: account, appId: appId)?.isActive == true
        case "reviews": return try reviewsDownloadJob(account: account, appId: appId)?.isActive == true
        default: return false
        }
    }
    static func syncSourceIsBusy(_ error: Error) -> Bool {
        (error as? ReportJobFailure) == .busy || (error as? ImportFailure) == .busy || (error as? SyncFailure) == .busy
    }
    /// Each source schedules only its own task and commits its identity with the aggregate receipt.
    func runSyncSource(_ key: String, account: Account, appId: String, client: AppStoreConnectClient?, ownership: ReportJobs.Ownership,
        now: Date, mode: SyncJob.Mode) async throws -> SyncItem {
        try reviewsScope(account, appId: appId)
        try storeAccess { try ReportJobs.checkCancellation(SyncJob.self, ownership: ownership, store: $0) }
        switch key {
        case "pricing":
            let snapshot = try await refreshPricing(account: account, appId: appId, client: client ?? self.client(for: account))
            return SyncItem(key: key, state: .synced, detail: "\(snapshot.rows.count) Apple price rows checked. Saved models and overrides are kept.", checkedAt: snapshot.fetchedAt)
        case "material":
            let (job, task) = try await createImport(account: account, appId: appId, client: client, reuseRunning: false, now: Date.init,
                binding: SyncChildBinding(ownership: ownership, accountId: account.id, appId: appId, key: key))
            if let task { try await waitForSyncChild(task) }
            else {
                guard job.state == .complete else { throw SyncFailure.busy }
                try bindRecoveredSyncChild(ownership, account: account, appId: appId, key: key, childId: job.id)
            }
            let saved = try syncChild(ImportJob.self, family: .material, id: job.id, account: account, appId: appId)
            guard saved.state == .complete, let revisionId = saved.revisionId,
                  try storeAccess({ try committedImport(accountId: account.id, appId: appId, revisionId: revisionId, store: $0) }) != nil else { throw SyncFailure.status }
            return SyncItem(key: key, state: .synced, detail: "Downloaded Apple's app details, versions, languages and media into a local snapshot. Local drafts were kept; no local version or edit was sent to Apple.", checkedAt: saved.updatedAt, revisionId: revisionId)
        case "sales":
            let source = try syncReportingSource(account: account), days = try salesSyncDays(accountId: account.id, appId: appId, now: now)
            let selection = try SalesDownloadSelection(source: source, days: days, now: now)
            let (job, task) = try await createSalesDownload(account: account, appId: appId, selection: selection, client: client, reporter: nil, reuseRunning: false, now: now, incremental: mode != .refresh,
                binding: SyncChildBinding(ownership: ownership, accountId: account.id, appId: appId, key: key))
            try await waitForSyncChild(task)
            let saved = try syncChild(SalesDownloadJob.self, family: .sales, id: job.id, account: account, appId: appId)
            guard saved.state == .complete, let result = saved.result else { throw SyncFailure.status }
            return AppSync.salesItem(result, checkedAt: saved.updatedAt)
        case "downloads", "engagement":
            let days = try analyticsSyncDays(accountId: account.id, appId: appId, kind: key, now: now)
            let selection = try AnalyticsDownloadSelection(kind: key, endDate: days.max()!, days: days.count, today: PeriodDates.text(now))
            let (job, task) = try await createAnalyticsDownload(account: account, appId: appId, selection: selection, client: client, reuseRunning: false, now: now, incremental: mode != .refresh,
                binding: SyncChildBinding(ownership: ownership, accountId: account.id, appId: appId, key: key))
            try await waitForSyncChild(task)
            let saved = try syncChild(AnalyticsDownloadJob.self, family: key == "downloads" ? .downloads : .engagement, id: job.id, account: account, appId: appId)
            guard saved.state == .complete, let result = saved.result else { throw SyncFailure.status }
            let item = AppSync.analyticsItem(result, checkedAt: saved.updatedAt, days: saved.selection.days)
            return SyncItem(key: key, state: item.state, detail: item.detail, checkedAt: item.checkedAt)
        case "finance":
            let previous = try financialDownloadJob(account: account, appId: appId, now: now)
            if previous?.isActive == true { throw SyncFailure.busy }
            if let pending = try pendingFinancialDownload(accountId: account.id, appId: appId, now: now), pending.changes.contains(where: { $0.action != "unchanged" }) {
                let status = AppSync.financialStatus(pending)
                return SyncItem(key: key, state: status.state, detail: status.detail, checkedAt: previous?.updatedAt ?? CustomerReview.isoString(Date()), reviewId: pending.id.uuidString.lowercased(), unavailable: pending.unavailable.count)
            }
            let source = try syncReportingSource(account: account), periods = try financialSyncPeriods(now: now)
            let selection = try FinancialDownloadSelection(source: source, periods: periods, region: previous?.selection.region ?? "ZZ")
            let (job, task) = try await createFinancialDownload(account: account, appId: appId, selection: selection, client: client, reporter: nil, reuseRunning: false, now: now,
                binding: SyncChildBinding(ownership: ownership, accountId: account.id, appId: appId, key: key))
            if let task { try await waitForSyncChild(task) }
            else {
                guard job.state == .complete else { throw SyncFailure.busy }
                try bindRecoveredSyncChild(ownership, account: account, appId: appId, key: key, childId: job.id)
            }
            let saved = try syncChild(FinancialDownloadJob.self, family: .financial, id: job.id, account: account, appId: appId)
            guard saved.state == .complete, let item = try syncFinanceItem(account: account, appId: appId, job: saved, now: now) else { throw SyncFailure.status }; return item
        case "reviews":
            let (job, task) = try await createReviewsDownload(account: account, appId: appId, client: client, reuseRunning: false, now: now,
                binding: SyncChildBinding(ownership: ownership, accountId: account.id, appId: appId, key: key))
            try await waitForSyncChild(task)
            let saved = try syncChild(ReviewsDownloadJob.self, family: .reviews, id: job.id, account: account, appId: appId)
            guard saved.state == .complete, let result = saved.result, try savedReviewsFiles(account: account, appId: appId).snapshot != nil else { throw SyncFailure.status }
            return SyncItem(key: key, state: result.limited ? .partial : .synced, detail: result.limited ? "Older reviews may be missing from this download; the next sync reads every page. Saved reviews are kept." : "\(saved.reviews) customer reviews checked and saved.", checkedAt: saved.updatedAt)
        default: throw SyncFailure.request
        }
    }
    func pollSyncCancellation(_ ownership: ReportJobs.Ownership, name: String) {
        guard reportTasks[name]?.id == ownership.id else { return }
        do { try storeAccess { try ReportJobs.checkCancellation(SyncJob.self, ownership: ownership, store: $0) } }
        catch is CancellationError { reportTasks[name]?.cancel() }
        catch { reportTaskFailures.insert(ownership.id); reportTasks[name]?.cancel() }
    }
    func executeSync(account: Account, appId: String, client: AppStoreConnectClient?, job: SyncJob, ownership: ReportJobs.Ownership, now: Date, mode: SyncJob.Mode) async throws -> SyncJob {
        var current = job, slot = false
        let name = try ReportJobs.name(.sync, accountId: account.id, appId: appId)
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self else { return }; await self.pollSyncCancellation(ownership, name: name)
            }
        }
        defer { monitor.cancel(); if reportTasks[name]?.id == job.id { reportTasks[name] = nil }; reportTaskFailures.remove(job.id); ownership.release() }
        func check() throws {
            try reviewsScope(account, appId: appId)
            try storeAccess { try ReportJobs.checkCancellation(SyncJob.self, ownership: ownership, store: $0) }
        }
        do {
            try check()
            if await SyncSlots.shared.status().active >= 2 {
                for index in current.items.indices where current.items[index].state == .pending { current.items[index].detail = AppSync.waitingForSlot }
                try storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
            }
            try await SyncSlots.shared.acquire(); slot = true; try check()
            for key in AppSync.executionOrder {
                try check(); let index = current.items.firstIndex { $0.key == key }!
                if current.items[index].state == .synced { continue }
                current.items[index] = SyncItem(key: key, state: .running, detail: "Downloading this source. Saved data is kept.")
                current.updatedAt = CustomerReview.isoString(Date()); try storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
                do {
                    var waiting = false
                    while true {
                        try check()
                        if try syncSourceIsActive(key, account: account, appId: appId) {
                            if !waiting || current.items[index].detail != AppSync.waitingForSource {
                                current.items[index] = SyncItem(key: key, state: .running, detail: AppSync.waitingForSource)
                                current.updatedAt = CustomerReview.isoString(Date())
                                try storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
                                waiting = true
                            }
                            if slot { slot = false; await SyncSlots.shared.release() }
                            try await Task.sleep(for: .milliseconds(250))
                            continue
                        }
                        if !slot {
                            current.items[index] = SyncItem(key: key, state: .running, detail: AppSync.waitingForSlot)
                            current.updatedAt = CustomerReview.isoString(Date())
                            try storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
                            try await SyncSlots.shared.acquire(); slot = true
                            continue
                        }
                        if waiting, mode != .refresh,
                           let completed = try syncSourceItems(account: account, appId: appId, now: Date()).first(where: { $0.item.key == key })?.item,
                           let reused = try verifiedReusableSyncItem(completed, account: account, appId: appId, mode: mode, now: Date()) {
                            current.items[index] = reused
                            break
                        }
                        do {
                            current.items[index] = SyncItem(key: key, state: .running, detail: "Downloading this source. Saved data is kept.")
                            current.updatedAt = CustomerReview.isoString(Date())
                            try storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
                            current.items[index] = try await runSyncSource(key, account: account, appId: appId, client: client, ownership: ownership, now: now, mode: mode)
                            break
                        } catch where Self.syncSourceIsBusy(error) {
                            current.items[index] = SyncItem(key: key, state: .running, detail: AppSync.waitingForSource)
                            current.updatedAt = CustomerReview.isoString(Date())
                            try storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
                            waiting = true
                            if slot { slot = false; await SyncSlots.shared.release() }
                            try await Task.sleep(for: .milliseconds(250))
                        }
                    }
                }
                catch { try check(); current.items[index] = AppSync.failure(error, key: key, checkedAt: CustomerReview.isoString(Date())) }
                try check(); current.updatedAt = CustomerReview.isoString(Date())
                try storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
            }
            try check(); current.state = .complete; current.updatedAt = CustomerReview.isoString(Date())
            try storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
            if slot { slot = false; await SyncSlots.shared.release() }
            return current
        } catch {
            if slot { slot = false; await SyncSlots.shared.release() }
            let failure: Error = reportTaskFailures.contains(job.id) ? SyncFailure.status : error
            current.fail(failure, at: CustomerReview.isoString(Date()))
            try storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }; throw failure
        }
    }
    func verifiedReusableSyncItem(_ item: SyncItem, account: Account, appId: String, mode: SyncJob.Mode, now: Date) throws -> SyncItem? {
        guard SyncJob.reuse(item, mode: mode, now: now) else { return nil }
        if item.key == "material" {
            guard let id = item.revisionId, try storeAccess({ try committedImport(accountId: account.id, appId: appId, revisionId: id, store: $0) }) != nil else { return nil }
        }
        if item.key == "reviews", try savedReviewsFiles(account: account, appId: appId).snapshot == nil { return nil }
        if item.key == "finance", try savedFinancialFiles(account: account, appId: appId).reports.isEmpty { return nil }
        return item
    }
    func reusableSyncItems(account: Account, appId: String, mode: SyncJob.Mode, now: Date) throws -> [SyncItem] {
        let previous = try syncStatus(account: account, appId: appId, now: now)
        return try AppSync.pending().map { pending in
            guard let item = previous?.items.first(where: { $0.key == pending.key }) else { return pending }
            return try verifiedReusableSyncItem(item, account: account, appId: appId, mode: mode, now: now) ?? pending
        }
    }
    func createSync(account: Account, appId: String, client: AppStoreConnectClient?, mode: SyncJob.Mode, reuseRunning: Bool, now: Date) async throws -> (SyncJob, Task<SyncJob, Error>?) {
        try Task.checkCancellation(); try reviewsScope(account, appId: appId); _ = try currentAccount(account, client: client)
        let id = UUID().uuidString.lowercased(), deadline = ContinuousClock.now + .milliseconds(500)
        var ownership: ReportJobs.Ownership?
        while ownership == nil {
            ownership = try ReportJobs.acquire(.sync, accountId: account.id, appId: appId, directory: try storeAccess { $0.directory }, id: id)
            if ownership == nil {
                if let active = try syncJob(account: account, appId: appId), active.isActive { if reuseRunning { return (active, nil) }; throw SyncFailure.busy }
                guard ContinuousClock.now < deadline else { throw SyncFailure.busy }
                try await Task.sleep(for: .milliseconds(25)); try Task.checkCancellation()
            }
        }
        guard let ownership else { throw SyncFailure.busy }
        do {
            try reviewsScope(account, appId: appId); try Task.checkCancellation()
            _ = try storeAccess { try ReportJobs.recover(SyncJob.self, family: .sync, ownership: ownership, accountId: account.id, appId: appId, store: $0, now: now,
                interrupted: { job, _ in job.fail(SyncFailure.interrupted, at: CustomerReview.isoString(now)) }) }
            let job = SyncJob(id: id, accountId: account.id, appId: appId, items: try reusableSyncItems(account: account, appId: appId, mode: mode, now: now), now: now)
            let children = SyncChildren(id: id, accountId: account.id, appId: appId)
            try storeAccess { try ReportJobs.start(job, ownership: ownership, store: $0, additionalWrites: [.put(namespace: "sync_children", key: "\(account.id):\(appId)", json: children.json.data)]) }
            let task = try ownedReport { try await self.executeSync(account: account, appId: appId, client: client, job: job, ownership: ownership, now: now, mode: mode) }
            reportTasks[try ReportJobs.name(.sync, accountId: account.id, appId: appId)] = (id, { task.cancel() }); return (job, task)
        } catch { ownership.release(); throw error }
    }
    /// Starts or follows the aggregate before reading any Apple or Reporter credential.
    public func startSync(account: Account, appId: String, mode: SyncJob.Mode = .all, client: AppStoreConnectClient? = nil, now: Date = Date()) async throws -> SyncJob {
        try requireOwnWorkspace()
        return try await createSync(account: account, appId: appId, client: client, mode: mode, reuseRunning: true, now: now).0
    }
    public func cancelSync(account: Account, appId: String, id: String) throws -> SyncJob? {
        try reviewsScope(account, appId: appId)
        let requested = try storeAccess { try ReportJobs.cancel(SyncJob.self, family: .sync, accountId: account.id, appId: appId, id: id, store: $0) }
        let name = try ReportJobs.name(.sync, accountId: account.id, appId: appId)
        if requested, reportTasks[name]?.id == id { reportTasks[name]?.cancel() }
        return try syncJob(account: account, appId: appId)
    }
    public func syncResults(accountId: String, appId: String) -> [SyncItem]? {
        guard let account = try? accounts().first(where: { $0.id == accountId }) else { return nil }
        return try? syncStatus(account: account, appId: appId)?.items
    }
    /// Foreground compatibility uses the durable job and cancels only the task this call owns.
    public func syncApp(account: Account, appId: String, client: AppStoreConnectClient? = nil, mode: SyncJob.Mode = .all, now: Date = Date()) async -> [SyncItem] {
        var ownedId: String?
        do {
            let (job, task) = try await createSync(account: account, appId: appId, client: client, mode: mode, reuseRunning: false, now: now)
            ownedId = job.id
            guard let task else { throw SyncFailure.busy }
            return try await withTaskCancellationHandler(operation: { try await task.value.items }, onCancel: { task.cancel() })
        } catch is CancellationError {
            if let id = ownedId, let saved = try? syncJob(account: account, appId: appId), saved.id == id { return saved.items }
            return AppSync.sources.map { SyncItem(key: $0.0, state: .attention, detail: "Sync interrupted. Retry unfinished items; previously saved data is kept.") }
        } catch {
            if let id = ownedId, let saved = try? syncJob(account: account, appId: appId), saved.id == id { return saved.items }
            return AppSync.sources.map { AppSync.failure(error, key: $0.0) }
        }
    }
    public struct SyncBatch: Sendable {
        public struct Entry: Sendable { public let accountId, appId, id: String }
        public let total, started, failed: Int
        public let jobs: [Entry]
    }
    /// Configured app scopes are distinct; each aggregate retains its own account and credentials.
    public func startAllSync(mode: SyncJob.Mode = .all, now: Date = Date()) async throws -> SyncBatch {
        try await startAllSync(mode: mode, now: now, clients: [:])
    }
    func startAllSync(mode: SyncJob.Mode, now: Date, clients: [String: AppStoreConnectClient]) async throws -> SyncBatch {
        let scopes = try accounts().flatMap { account in Set(account.appIds).sorted().map { (account, $0) } }
        var entries: [SyncBatch.Entry] = [], failed = 0
        for offset in stride(from: 0, to: scopes.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(scopes[offset..<min(offset + 4, scopes.count)])
            await withTaskGroup(of: SyncBatch.Entry?.self) { group in
                for (account, appId) in batch {
                    group.addTask {
                        do { let job = try await self.startSync(account: account, appId: appId, mode: mode, client: clients["\(account.id):\(appId)"], now: now); return SyncBatch.Entry(accountId: account.id, appId: appId, id: job.id) }
                        catch { return nil }
                    }
                }
                for await entry in group { if let entry { entries.append(entry) } else { failed += 1 } }
            }
        }
        return SyncBatch(total: scopes.count, started: entries.count, failed: failed, jobs: entries.sorted { ($0.accountId, $0.appId) < ($1.accountId, $1.appId) })
    }
}
