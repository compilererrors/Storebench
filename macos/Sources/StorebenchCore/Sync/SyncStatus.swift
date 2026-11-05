import Foundation

public struct SyncPresentation: Sendable {
    public let status: SyncJob?
    public let activeJobId: String?
}

public struct SyncActivitySummary: Sendable, Equatable {
    public let activeApps: Int
    public let totalApps: Int
    public let sources: SyncSourceSummary
    public let unavailableApps: Int
    public var fractionChecked: Double? { sources.total > 0 ? Double(sources.checked) / Double(sources.total) : nil }
    public var progressLabel: String { "\(sources.checked) of \(sources.total) sources checked" }
    public var text: String {
        guard totalApps > 0 else { return "No apps connected." }
        let appCount = "\(totalApps) \(totalApps == 1 ? "app" : "apps")"
        let apps = activeApps > 0 ? "\(activeApps) of \(appCount) syncing" : appCount
        return apps + " · " + sources.text + (unavailableApps > 0 ? " · \(unavailableApps) \(unavailableApps == 1 ? "app status" : "app statuses") unavailable" : "")
    }
}

/// Interprets each distinct timestamp once within one immutable status projection.
struct SyncDateCache {
    private var values: [String: Date] = [:]
    private let parse: (String) -> Date?
    init(parse: @escaping (String) -> Date? = AppSync.date) { self.parse = parse }
    mutating func date(_ text: String) -> Date? {
        if let value = values[text] { return value }
        guard let value = parse(text) else { return nil }
        values[text] = value; return value
    }
    mutating func newer(_ text: String, than baseline: String) -> Bool {
        guard let value = date(text) else { return false }
        return value >= (date(baseline) ?? .distantFuture)
    }
}

extension AppSync {
    static let waitingForSource = "Waiting for this source's existing download to finish."
    static let waitingForSlot = "Queued until other apps finish syncing."
    static func date(_ value: String) -> Date? { ReportTimestamps.date(value) }
    static func newer(_ value: String, than baseline: String) -> Bool { date(value).map { $0 >= (date(baseline) ?? .distantFuture) } ?? false }
    static let setupCodes: Set<String> = ["SB-SYNC-CONNECTION", "SB-SYNC-FISCAL-PERIOD", "SB-ANALYTICS-SETUP", "SB-ANALYTICS-INACTIVE"]
    static let waitingCodes: Set<String> = ["SB-ANALYTICS-SETUP", "SB-ANALYTICS-INACTIVE", "SB-ANALYTICS-NO-INSTANCES", "SB-ANALYTICS-PERIOD", "SB-ANALYTICS-REPORT-MISSING", "SB-ANALYTICS-SEGMENTS-PENDING", "SB-REPORT-UNAVAILABLE", "SB-SYNC-CONNECTION", "SB-SYNC-BUSY", "SB-SYNC-FISCAL-PERIOD"]
    static func failure(_ error: Error, key: String? = nil, checkedAt: String? = nil) -> SyncItem {
        let code: String
        if (error as? SalesFailure) == .noConnection { code = "SB-SYNC-CONNECTION" }
        else if let failure = error as? SyncFailure { code = failure.code }
        else if let failure = error as? ImportFailure { code = failure == .busy ? "SB-SYNC-BUSY" : failure.code }
        else if key == "sales" { code = SalesDownloadJob.failureCode(error) }
        else if key == "finance" { code = FinancialDownloadJob.failureCode(error) }
        else if key == "reviews" { code = ReviewsDownloadJob.failureCode(error) }
        else if key == "downloads" || key == "engagement" { code = AnalyticsDownloadJob.failureCode(error) }
        else {
            switch error {
            case AppStoreConnectClient.Failure.agreement, AccountFailure.agreement: code = "SB-APPLE-AGREEMENT"
            case AppStoreConnectClient.Failure.status(401): code = "SB-APPLE-AUTH"
            case AppStoreConnectClient.Failure.status(403), AccountFailure.stale, AccountFailure.notFound, ReviewsFailure.scope: code = "SB-APPLE-ACCESS"
            case ReviewsFailure.noKey, is CredentialAccessFailure: code = "SB-APPLE-KEYCHAIN"
            case is FileMutex.Failure, is JobLock.Failure: code = "SB-REPORT-LOCK"
            case let value as ReportJobFailure: code = value.code
            default: code = key == "pricing" ? "SB-SYNC-PRICING" : "SB-SYNC-STATUS"
            }
        }
        return SyncItem(key: key ?? "material", state: waitingCodes.contains(code) ? .attention : .failed, detail: ReportingMessages.message(code), checkedAt: checkedAt, code: code)
    }
    /// Unavailable days stay unknown, including Apple's ordinary publishing delay.
    public static func salesItem(_ result: SalesDownloadJob.Result, checkedAt: String) -> SyncItem {
        let now = date(checkedAt) ?? .distantPast
        let pending = result.unavailableDays.filter { day in
            guard let status = try? SalesCalendar.availability(day, now: now) else { return false }
            return status != .missing
        }
        let missing = result.unavailableDays.count - pending.count, noApp = result.noAppRowsDays.count, quiet = result.noSalesDays.count
        var facts = ["\(result.periods) \(result.periods == 1 ? "day" : "days") with sales"]
        if quiet > 0 { facts.append("\(quiet) without sales") }; if noApp > 0 { facts.append("\(noApp) unattributed") }
        if missing > 0 { facts.append("\(missing) not available") }
        if !pending.isEmpty {
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            facts.append(pending.map { day in months[Int(day.dropFirst(5).prefix(2))! - 1] + " " + String(Int(day.suffix(2))!) }.joined(separator: ", ") + " not published by Apple yet")
        }
        var notes: [String] = []
        if noApp > 0 { notes.append("Some reports could not be matched to this app. Import the app information so in-app purchases can be attributed.") }
        if missing > 0 { notes.append("Apple has not delivered every older report; those days are retried on the next sync.") }
        if !pending.isEmpty && missing == 0 { notes.append("Apple publishes each day's report the next morning, around 05:30–07:30 Pacific Time; the next sync after that downloads it.") }
        return SyncItem(key: "sales", state: result.unavailableDays.isEmpty && noApp == 0 ? .synced : .partial, detail: facts.joined(separator: " · ") + "." + (notes.isEmpty ? "" : " " + notes.joined(separator: " ")), checkedAt: checkedAt,
                        code: missing > 0 ? "SB-REPORT-UNAVAILABLE" : noApp > 0 ? "SB-SYNC-SALES-NO-ROWS" : nil)
    }
    public static func analyticsItem(_ result: AnalyticsSyncResult, checkedAt: String, days: Int) -> SyncItem {
        let unavailable = max(result.unavailableDays.count, days - result.instances), changes = result.changes
        let detail = "\(result.instances) report instances checked · \(changes.added) added · \(changes.replaced) replaced · \(changes.unchanged + changes.older) retained · \(result.reusedInstances) reused · \(result.noAppInstances) without app rows" + (unavailable > 0 ? " · \(unavailable) processing dates not available" : "") + ". Missing activity is not zero."
        return SyncItem(key: "downloads", state: result.noAppInstances > 0 || unavailable > 0 ? .partial : .synced, detail: detail, checkedAt: checkedAt)
    }
}

/// Exact child identities are committed before the corresponding owned child task is scheduled.
struct SyncChildren {
    let id, accountId, appId: String
    var entries: [(key: String, id: String)]
    var json: JSONText { .object([("schemaVersion", .number(1)), ("id", .string(id)), ("accountId", .string(accountId)), ("appId", .string(appId)), ("entries", .array(entries.map { .object([("key", .string($0.key)), ("id", .string($0.id))]) }))]) }
    init(id: String, accountId: String, appId: String) { self.id = id; self.accountId = accountId; self.appId = appId; entries = [] }
    init(_ value: JSONText, accountId: String, appId: String) throws {
        guard value["schemaVersion"] == .number(1), let id = value["id"]?.text, ReportJobs.uuid(id), value["accountId"] == .string(accountId), value["appId"] == .string(appId), case .array(let rows)? = value["entries"], rows.count <= 6 else { throw SyncFailure.status }
        self.init(id: id, accountId: accountId, appId: appId)
        for row in rows {
            guard let key = row["key"]?.text, key != "pricing", AppSync.executionOrder.contains(key), let id = row["id"]?.text, ReportJobs.uuid(id), !entries.contains(where: { $0.key == key }) else { throw SyncFailure.status }
            entries.append((key, id))
        }
    }
}

extension WorkspaceSession {
    /// The immutable aggregate receipt; projection below reads newer source results without rewriting it.
    public func syncJob(account: Account, appId: String, now: Date = Date()) throws -> SyncJob? {
        try reviewsScope(account, appId: appId)
        return try storeAccess { try ReportJobs.read(SyncJob.self, family: .sync, accountId: account.id, appId: appId, store: $0, now: now,
            interrupted: { job, _ in job.fail(SyncFailure.interrupted, at: CustomerReview.isoString(now)) }) }
    }
    func syncFinanceItem(account: Account, appId: String, job: FinancialDownloadJob?, now: Date) throws -> SyncItem? {
        if let pending = try pendingFinancialDownload(accountId: account.id, appId: appId, now: now), job == nil || pending.id.uuidString.lowercased() == job?.result?.reviewId {
            let status = AppSync.financialStatus(pending)
            return SyncItem(key: "finance", state: status.state, detail: status.detail, checkedAt: job?.updatedAt ?? CustomerReview.isoString(pending.expiresAt.addingTimeInterval(-86_400)), reviewId: pending.id.uuidString.lowercased(), unavailable: pending.unavailable.count)
        }
        guard let job else { return nil }
        if let reviewId = job.result?.reviewId {
            let record = try storeAccess { store in try FinancialDownloadRecord.cache(store.document(namespace: "financial_reviews", key: "\(account.id):\(appId)")?.payload, accountId: account.id, appId: appId, now: now).first { $0.id == reviewId } }
            if let record {
                let history = try savedFinancialFiles(account: account, appId: appId)
                let changes = try FinancialReports.merge(history.reports, record.reports).changes
                if changes.allSatisfy({ $0.action == "unchanged" }) {
                    let missing = job.result!.unavailable, noApp = job.result!.noApp
                    return SyncItem(key: "finance", state: missing.isEmpty && noApp.isEmpty ? .synced : .partial, detail: "The downloaded financial reports match saved history." + (missing.isEmpty ? "" : " \(missing.count) fiscal periods remain unavailable and unknown.") + (noApp.isEmpty ? "" : " \(noApp.count) fiscal periods could not be attributed to this app and remain unknown."), checkedAt: job.updatedAt, reviewId: reviewId, unavailable: missing.count)
                }
            }
            return SyncItem(key: "finance", state: .attention, detail: ReportingMessages.message("SB-FINANCE-REVIEW"), checkedAt: job.updatedAt, code: "SB-FINANCE-REVIEW", reviewId: reviewId, unavailable: job.result?.unavailable.count)
        }
        guard let result = job.result else { return nil }
        return SyncItem(key: "finance", state: .partial, detail: "\(result.unavailable.count) fiscal periods unavailable · \(result.noApp.count) without app rows. Existing reports are kept.", checkedAt: job.updatedAt, code: result.unavailable.isEmpty ? nil : "SB-REPORT-UNAVAILABLE", unavailable: result.unavailable.count)
    }
    func syncSourceItems(account: Account, appId: String, now: Date) throws -> [(item: SyncItem, startedAt: String)] {
        var results: [(SyncItem, String)] = []
        if let prices = try savedPricing(accountId: account.id, appId: appId) {
            let item = prices.code.map { SyncItem(key: "pricing", state: .failed, detail: ReportingMessages.message($0), checkedAt: prices.checkedAt, code: $0) }
                ?? SyncItem(key: "pricing", state: .synced, detail: "\(prices.snapshot!.rows.count) Apple price rows checked. Saved models and overrides are kept.", checkedAt: prices.checkedAt)
            results.append((item, prices.checkedAt))
        }
        func other(_ key: String, id: String, state: String, started: String, updated: String, code: String?) -> Bool {
            let item: SyncItem?
            switch state {
            case "running", "cancelling": item = SyncItem(key: key, state: .running, detail: "Downloading this source. Saved data is kept.", checkedAt: updated)
            case "failed": let code = code ?? "SB-SYNC-STATUS"; item = SyncItem(key: key, state: AppSync.waitingCodes.contains(code) ? .attention : .failed, detail: ReportingMessages.message(code), checkedAt: updated, code: code)
            case "cancelled": item = SyncItem(key: key, state: .attention, detail: "Download cancelled. Previously saved data is kept.", checkedAt: updated)
            default: item = nil
            }
            if let item { results.append((item, started)); return true }; return false
        }
        if let job = try importJob(account: account, appId: appId, now: now), !other("material", id: job.id, state: job.state.rawValue, started: job.startedAt, updated: job.updatedAt, code: job.code), let id = job.revisionId,
           try storeAccess({ try committedImport(accountId: account.id, appId: appId, revisionId: id, store: $0) }) != nil {
            results.append((SyncItem(key: "material", state: .synced, detail: "Downloaded Apple's app details, versions, languages and media into a local snapshot. Local drafts were kept; no local version or edit was sent to Apple.", checkedAt: job.updatedAt, revisionId: id), job.startedAt))
        }
        if let job = try salesDownloadJob(account: account, appId: appId, now: now), !other("sales", id: job.id, state: job.state.rawValue, started: job.startedAt, updated: job.updatedAt, code: job.code), let result = job.result {
            results.append((AppSync.salesItem(result, checkedAt: job.updatedAt), job.startedAt))
        }
        let analyticsJobs = try analyticsJobRecords(account: account, appId: appId)
        for kind in ["downloads", "engagement"] {
            if let job = analyticsJobs.first(where: { $0.selection.kind == kind }), !other(kind, id: job.id, state: job.state.rawValue, started: job.startedAt, updated: job.updatedAt, code: job.code), let result = job.result {
                var item = AppSync.analyticsItem(result, checkedAt: job.updatedAt, days: job.selection.days); item = SyncItem(key: kind, state: item.state, detail: item.detail, checkedAt: item.checkedAt); results.append((item, job.startedAt))
            }
        }
        let finance = try financialDownloadJob(account: account, appId: appId, now: now)
        if finance.map({ !other("finance", id: $0.id, state: $0.state.rawValue, started: $0.startedAt, updated: $0.updatedAt, code: $0.code) }) ?? true,
           let item = try syncFinanceItem(account: account, appId: appId, job: finance, now: now) { results.append((item, finance?.startedAt ?? item.checkedAt!)) }
        if let job = try reviewsDownloadJob(account: account, appId: appId, now: now), !other("reviews", id: job.id, state: job.state.rawValue, started: job.startedAt, updated: job.updatedAt, code: job.code), let result = job.result,
           try savedReviewsFiles(account: account, appId: appId).snapshot != nil {
            results.append((SyncItem(key: "reviews", state: result.limited ? .partial : .synced, detail: result.limited ? "Older reviews may be missing from this download; the next sync reads every page. Saved reviews are kept." : "\(job.reviews) customer reviews checked and saved.", checkedAt: job.updatedAt), job.startedAt))
        }
        return results
    }
    /// Overview reads saved per-source results, including work started outside the aggregate sync.
    public func syncStatus(account: Account, appId: String, now: Date = Date()) throws -> SyncJob? {
        try syncPresentation(account: account, appId: appId, now: now).status
    }
    /// Keep the owned aggregate identity separate from projected standalone downloads.
    public func syncPresentation(account: Account, appId: String, now: Date = Date()) throws -> SyncPresentation {
        let original = try syncJob(account: account, appId: appId, now: now)
        let status = try syncStatus(account: account, appId: appId, original: original, now: now)
        return SyncPresentation(status: status, activeJobId: original?.isActive == true ? original?.id : nil)
    }
    /// Reads the same source projection as the app cards. Polling never starts a download.
    public func syncActivitySummary() throws -> SyncActivitySummary {
        try requireSessionAccess(); try Task.checkCancellation()
        let configured = try accounts()
        guard Set(configured.map(\.id)).count == configured.count else { throw ConnectedApps.Failure.changed }
        var active = 0, total = 0, unavailable = 0, sources = SyncSourceSummary()
        for account in configured {
            _ = try currentAccount(account, exact: true)
            for appId in Set(account.appIds) {
                try Task.checkCancellation(); total += 1
                do {
                    let presentation = try syncPresentation(account: account, appId: appId)
                    if presentation.activeJobId != nil || presentation.status?.isActive == true { active += 1 }
                    sources.include(.init(job: presentation.status))
                } catch {
                    try requireSessionAccess(); try Task.checkCancellation(); _ = try currentAccount(account, exact: true)
                    unavailable += 1; sources.include(.init(job: nil))
                }
            }
        }
        for account in configured { _ = try currentAccount(account, exact: true) }
        guard try accounts().map(\.id) == configured.map(\.id) else { throw ConnectedApps.Failure.changed }
        try requireSessionAccess(); try Task.checkCancellation()
        return SyncActivitySummary(activeApps: active, totalApps: total, sources: sources, unavailableApps: unavailable)
    }
    private func syncStatus(account: Account, appId: String, original: SyncJob?, now: Date) throws -> SyncJob? {
        try reviewsScope(account, appId: appId)
        let sources = try syncSourceItems(account: account, appId: appId, now: now)
        var dates = SyncDateCache()
        var job: SyncJob?
        if let original { job = original }
        else if let last = sources.max(by: { (dates.date($0.item.checkedAt!) ?? .distantPast) < (dates.date($1.item.checkedAt!) ?? .distantPast) }) {
            var value = SyncJob(id: "00000000-0000-4000-8000-000000000001", accountId: account.id, appId: appId, items: AppSync.pending().map { SyncItem(key: $0.key, state: .unchecked, detail: "No saved download result for this source yet.") }, now: dates.date(last.startedAt) ?? now)
            value.state = .complete; value.projection = true; job = value
        }
        if var value = job {
            for source in sources {
                guard let index = value.items.firstIndex(where: { $0.key == source.item.key }) else { continue }
                let prior = value.items[index], threshold = prior.checkedAt ?? value.startedAt
                if original?.isActive == true, prior.state == .running, [AppSync.waitingForSource, AppSync.waitingForSlot].contains(prior.detail) { continue }
                if original == nil || dates.newer(source.item.checkedAt!, than: threshold) || prior.state == .running && dates.newer(source.startedAt, than: value.startedAt) { value.items[index] = source.item }
            }
            var latest = dates.date(value.updatedAt) ?? .distantFuture
            for item in value.items {
                guard let timestamp = item.checkedAt, let date = dates.date(timestamp), date >= latest else { continue }
                value.updatedAt = timestamp; latest = date
            }
            value.projection = true
            if value.items.contains(where: { $0.state == .running }) { value.state = .running }
            else if value.state != .running { value.state = .complete }
            if value.state == .running || value.items.contains(where: { [.synced, .partial].contains($0.state) }) { value.statusOnly = false }
            job = value
        }
        let merged = try mergeSyncSetup(job, account: account, appId: appId, now: now)
        try reviewsScope(account, appId: appId); return merged
    }
    func mergeSyncSetup(_ job: SyncJob?, account: Account, appId: String, now: Date) throws -> SyncJob? {
        guard job?.state != .running else { return job }
        let snapshot = try storeAccess { try $0.document(namespace: "sync_setup", key: "\(account.id):\(appId)").map { try JSONText.parse($0.payload) } }
        var value = job
        if let snapshot {
            guard snapshot["schemaVersion"] == .number(1), snapshot["accountId"] == .string(account.id), snapshot["appId"] == .string(appId), let id = snapshot["id"]?.text, ReportJobs.uuid(id),
                  let checked = snapshot["checkedAt"]?.text, ReportTimestamps.shortValid(checked), AppSync.date(checked) != nil, case .array(let rows)? = snapshot["items"], rows.count <= 4 else { throw SyncFailure.status }
            let setup = try rows.map { raw -> SyncItem in
                let item = try SyncItem(json: raw)
                guard ["sales", "downloads", "engagement", "finance"].contains(item.key), [.attention, .waiting, .ready].contains(item.state), item.checkedAt != nil,
                      item.state == .attention ? AppSync.setupCodes.contains(item.code ?? "") : item.code == nil else { throw SyncFailure.status }; return item
            }
            guard Set(setup.map(\.key)).count == setup.count else { throw SyncFailure.status }
            if value == nil {
                var initial = SyncJob(id: id, accountId: account.id, appId: appId, items: AppSync.pending().map { SyncItem(key: $0.key, state: .unchecked, detail: "Not checked by Sync. Existing saved data is unchanged.") }, now: AppSync.date(checked) ?? now)
                initial.state = .complete; initial.statusOnly = true; value = initial
            }
            for next in setup {
                let index = value!.items.firstIndex { $0.key == next.key }!, current = value!.items[index]
                if [.synced, .partial].contains(current.state) || current.state == .failed && !AppSync.setupCodes.contains(current.code ?? "") || current.state == .attention && current.code != nil && !AppSync.setupCodes.contains(current.code!) { continue }
                if let time = current.checkedAt, !AppSync.newer(next.checkedAt!, than: time) { continue }
                if current.checkedAt == nil, job != nil, !AppSync.newer(next.checkedAt!, than: value!.startedAt) { continue }
                value!.items[index] = next
            }
            value!.setupCheckedAt = checked
        }
        if var merged = value {
            let connected = try FileMutex.withLock(reportingMutex(accountId: account.id)) { try salesConnection(accountId: account.id).map { $0.reporter != nil || account.keyType == "team" && !$0.vendorNumber.isEmpty } ?? false }
            for index in merged.items.indices where ["sales", "finance"].contains(merged.items[index].key) {
                let old = merged.items[index]
                if connected && old.code == "SB-SYNC-CONNECTION" { merged.items[index] = SyncItem(key: old.key, state: .ready, detail: "Reporting connection is set up. Open the report view to download or review reports. Saved report data is unchanged.", checkedAt: CustomerReview.isoString(now)) }
                else if !connected && old.state == .ready { merged.items[index] = SyncItem(key: old.key, state: .attention, detail: "Connect reporting before downloading reports. Previously saved reports are kept.", checkedAt: CustomerReview.isoString(now), code: "SB-SYNC-CONNECTION") }
            }
            return merged
        }
        return nil
    }
}
