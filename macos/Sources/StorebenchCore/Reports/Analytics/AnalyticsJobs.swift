import Foundation

public struct AnalyticsDownloadSelection: Equatable, Sendable {
    public let kind: String, level: String, granularity: String, endDate: String
    public let days: Int, requestId: String?
    public var processingDays: [String] {
        guard let end = PeriodDates.number(endDate) else { return [] }
        return (0..<days).reversed().map { PeriodDates.text(end - $0) }
    }
    public var json: JSONText {
        .object([("kind", .string(kind)), ("level", .string(level)), ("granularity", .string(granularity)), ("days", .number(Double(days))), ("endDate", .string(endDate))]
                + (requestId.map { [("requestId", JSONText.string($0))] } ?? []))
    }
    public init(kind: String, level: String = "standard", granularity: String = "DAILY", endDate: String, days: Int, requestId: String? = nil, today: String = PeriodDates.text(Date())) throws {
        guard ["downloads", "engagement"].contains(kind), ["standard", "detailed"].contains(level), ["DAILY", "WEEKLY", "MONTHLY"].contains(granularity),
              !(kind == "downloads" && level == "standard" && granularity != "DAILY"), PeriodDates.number(endDate) != nil, (1...365).contains(days),
              endDate <= today, requestId.map(AnalyticsCatalog.id) ?? true else { throw ReportJobFailure.request }
        self.kind = kind; self.level = level; self.granularity = granularity; self.endDate = endDate; self.days = days; self.requestId = requestId
    }
    public init(json: JSONText, today: String = "9999-12-31") throws {
        guard let kind = json["kind"]?.text, let level = json["level"]?.text, let unit = json["granularity"]?.text, let end = json["endDate"]?.text,
              case .number(let raw)? = json["days"], let days = Int(exactly: raw), json["requestId"] == nil || json["requestId"]?.text != nil else { throw ReportJobFailure.request }
        try self.init(kind: kind, level: level, granularity: unit, endDate: end, days: days, requestId: json["requestId"]?.text, today: today)
    }
}

extension WorkspaceSession {
    static let analyticsJobFamilies: [ReportJobs.Family] = [.analytics, .downloads, .engagement]
    func analyticsJobRecords(account: Account, appId: String, now: Date = Date()) throws -> [AnalyticsDownloadJob] {
        try analyticsFileScope(account, appId: appId)
        var jobs = try storeAccess { store in try Self.analyticsJobFamilies.compactMap {
            try ReportJobs.read(AnalyticsDownloadJob.self, family: $0, accountId: account.id, appId: appId, store: store, now: now)
        } }
        // Move a terminal legacy record only while the shared job mutex proves that no download owns it.
        if let legacy = jobs.first(where: { $0.state != .running }),
           let legacyDocument = try storeAccess({ try $0.document(namespace: "jobs", key: "analytics:\(account.id):\(appId)") }),
           (try? AnalyticsDownloadJob(json: JSONText.parse(legacyDocument.payload)))?.id == legacy.id {
            let name = try ReportJobs.name(.analytics, accountId: account.id, appId: appId)
            if let probe = try FileMutex.tryLock(try storeAccess { $0.directory.appendingPathComponent("\(name).lock.mutex") }) {
                defer { probe.release() }
                let owner = try JobLock.owner(JobLock.privateFile(try storeAccess { $0.directory.appendingPathComponent("\(name).lock") }))
                if owner == nil || owner?.protocol == 2 || !JobLock.alive(owner!.pid) {
                    let target: ReportJobs.Family = legacy.selection.kind == "downloads" ? .downloads : .engagement
                    let key = try ReportJobs.identity(target, accountId: account.id, appId: appId)
                    try storeAccess { store in try store.transaction { current in
                        try self.analyticsFileScope(account, appId: appId)
                        guard let source = try current("jobs", legacyDocument.key), source == legacyDocument,
                              let parsed = try ReportJobs.parsed(AnalyticsDownloadJob.self, source, family: .analytics), parsed.state != .running else { return [] }
                        let previous = try ReportJobs.parsed(AnalyticsDownloadJob.self, current("jobs", key), family: target)
                        guard previous?.state != .running else { return [] }
                        var writes: [EncryptedDocumentStore.Write] = [.delete(namespace: "jobs", key: legacyDocument.key)]
                        if previous == nil || parsed.updatedAt > previous!.updatedAt { writes.insert(.put(namespace: "jobs", key: key, json: parsed.json.data), at: 0) }
                        return writes
                    } }
                    jobs = try storeAccess { store in try Self.analyticsJobFamilies.filter { $0 != .analytics }.compactMap { family -> AnalyticsDownloadJob? in
                        try ReportJobs.parsed(AnalyticsDownloadJob.self, store.document(namespace: "jobs", key: ReportJobs.identity(family, accountId: account.id, appId: appId)), family: family)
                    } }
                }
            }
        }
        return jobs.sorted { a, b in a.state == .running && b.state != .running || (a.state == .running) == (b.state == .running) && a.updatedAt > b.updatedAt }
    }
    public func analyticsDownloadJob(account: Account, appId: String, kind: String? = nil) throws -> AnalyticsDownloadJob? {
        if let kind { guard ["downloads", "engagement"].contains(kind) else { throw ReportJobFailure.request } }
        return try analyticsJobRecords(account: account, appId: appId).first { kind == nil || $0.selection.kind == kind }
    }

    public func cancelAnalyticsDownload(account: Account, appId: String, id: String) throws -> AnalyticsDownloadJob? {
        let records = try analyticsJobRecords(account: account, appId: appId)
        guard let current = records.first(where: { $0.id == id }), current.state == .running else { return records.first }
        let family: ReportJobs.Family = current.selection.kind == "downloads" ? .downloads : .engagement
        let saved = try storeAccess { try ReportJobs.parsed(AnalyticsDownloadJob.self, $0.document(namespace: "jobs", key: ReportJobs.identity(family, accountId: account.id, appId: appId)), family: family) }
        let actual: ReportJobs.Family = saved?.id == id ? family : .analytics
        let requested = try storeAccess { try ReportJobs.cancel(AnalyticsDownloadJob.self, family: actual, accountId: account.id, appId: appId, id: id, store: $0) }
        let name = try ReportJobs.name(actual, accountId: account.id, appId: appId)
        if requested, reportTasks[name]?.id == id { reportTasks[name]?.cancel() }
        return current
    }

    func pollAnalyticsCancellation(_ ownership: ReportJobs.Ownership, name: String) {
        guard reportTasks[name]?.id == ownership.id else { return }
        do { try storeAccess { try ReportJobs.checkCancellation(AnalyticsDownloadJob.self, ownership: ownership, store: $0) } }
        catch is CancellationError { reportTasks[name]?.cancel() }
        catch { reportTaskFailures.insert(ownership.id); reportTasks[name]?.cancel() }
    }

    func executeAnalyticsDownload(account: Account, appId: String, client: AppStoreConnectClient?, job: AnalyticsDownloadJob, ownership: ReportJobs.Ownership, now: Date, incremental: Bool) async throws -> AnalyticsSyncResult {
        var current = job
        let name = try ReportJobs.name(ownership.family, accountId: account.id, appId: appId)
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self else { return }; await self.pollAnalyticsCancellation(ownership, name: name)
            }
        }
        defer {
            monitor.cancel()
            if reportTasks[name]?.id == job.id { reportTasks[name] = nil }
            reportTaskFailures.remove(job.id); ownership.release()
        }
        do {
            try analyticsFileScope(account, appId: appId)
            try storeAccess { try ReportJobs.checkCancellation(AnalyticsDownloadJob.self, ownership: ownership, store: $0) }
            let selection = job.selection
            let client = try client ?? self.client(for: account)
            let value = try await downloadAnalyticsBody(account: account, appId: appId, kind: selection.kind, processingDays: selection.processingDays,
                client: client, now: now, level: selection.level, granularity: selection.granularity, requestId: selection.requestId, incremental: incremental,
                check: { try self.storeAccess { try ReportJobs.checkCancellation(AnalyticsDownloadJob.self, ownership: ownership, store: $0) } },
                progress: { phase, total, completed, segments, bytes in
                    try self.storeAccess { try ReportJobs.checkCancellation(AnalyticsDownloadJob.self, ownership: ownership, store: $0) }
                    current.phase = phase; current.total = total; current.completed = completed; current.segments = segments; current.bytes = bytes
                    current.updatedAt = CustomerReview.isoString(Date())
                    try self.storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
                })
            try analyticsFileScope(account, appId: appId)
            try storeAccess { try ReportJobs.checkCancellation(AnalyticsDownloadJob.self, ownership: ownership, store: $0) }
            current.state = .complete; current.result = value; current.updatedAt = CustomerReview.isoString(Date())
            try storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
            return value
        } catch {
            if reportTaskFailures.contains(job.id) { current.fail(ReportJobFailure.status, at: CustomerReview.isoString(Date())) }
            else if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                current.state = .cancelled; current.result = nil; current.code = nil; current.updatedAt = CustomerReview.isoString(Date())
            } else { current.fail(error, at: CustomerReview.isoString(Date())) }
            try? storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
            throw error
        }
    }

    func createAnalyticsDownload(account: Account, appId: String, selection: AnalyticsDownloadSelection, client: AppStoreConnectClient?,
                                 reuseRunning: Bool, now: Date, incremental: Bool = false, binding: SyncChildBinding? = nil) async throws -> (AnalyticsDownloadJob, Task<AnalyticsSyncResult, Error>?) {
        try Task.checkCancellation(); try analyticsFileScope(account, appId: appId); _ = try currentAccount(account, client: client)
        _ = try AnalyticsDownloadSelection(json: selection.json, today: PeriodDates.text(now))
        let family: ReportJobs.Family = selection.kind == "downloads" ? .downloads : .engagement
        let id = UUID().uuidString.lowercased(), clock = ContinuousClock(), deadline = clock.now + .milliseconds(500)
        var ownership: ReportJobs.Ownership?
        while ownership == nil {
            let records = try analyticsJobRecords(account: account, appId: appId)
            if let active = records.first(where: { $0.state == .running }) {
                if reuseRunning { return (active, nil) }; throw ReportJobFailure.busy
            }
            ownership = try ReportJobs.acquire(family, accountId: account.id, appId: appId, directory: try storeAccess { $0.directory }, id: id)
            if ownership == nil {
                guard clock.now < deadline else { throw ReportJobFailure.busy }
                try await Task.sleep(for: .milliseconds(25)); try Task.checkCancellation()
            }
        }
        guard let ownership else { throw ReportJobFailure.busy }
        do {
            try analyticsFileScope(account, appId: appId); try Task.checkCancellation()
            for other in Self.analyticsJobFamilies { _ = try storeAccess { try ReportJobs.recover(AnalyticsDownloadJob.self, family: other, ownership: ownership, accountId: account.id, appId: appId, store: $0, now: now) } }
            let job = AnalyticsDownloadJob(id: id, selection: selection, now: now)
            try storeAccess { try ReportJobs.start(job, ownership: ownership, store: $0, binding: binding) }
            let task = try ownedReport { try await self.executeAnalyticsDownload(account: account, appId: appId, client: client, job: job, ownership: ownership, now: now, incremental: incremental) }
            let name = try ReportJobs.name(family, accountId: account.id, appId: appId)
            reportTasks[name] = (id, { task.cancel() })
            return (job, task)
        } catch { ownership.release(); throw error }
    }

    /// Starts or follows the one owned Analytics job for this app. Navigation does not cancel the download.
    public func startAnalyticsDownload(account: Account, appId: String, selection: AnalyticsDownloadSelection, client: AppStoreConnectClient? = nil, now: Date = Date()) async throws -> AnalyticsDownloadJob {
        try Task.checkCancellation(); try analyticsFileScope(account, appId: appId)
        if let active = try analyticsJobRecords(account: account, appId: appId).first(where: { $0.state == .running }) { return active }
        return try await createAnalyticsDownload(account: account, appId: appId, selection: selection, client: client, reuseRunning: true, now: now).0
    }
    /// Waits for an owned download using the same durable status and shared job mutex as the background view.
    public func downloadAnalytics(account: Account, appId: String, kind: String, processingDays: [String], client: AppStoreConnectClient,
                                  now: Date = Date(), level: String = "standard", granularity: String = "DAILY", requestId: String? = nil) async throws -> AnalyticsSyncResult {
        try Task.checkCancellation(); try analyticsFileScope(account, appId: appId)
        guard let end = processingDays.max(), let first = processingDays.min(), let endNumber = PeriodDates.number(end), let firstNumber = PeriodDates.number(first),
              !processingDays.isEmpty, Set(processingDays).count == processingDays.count, processingDays.allSatisfy({ PeriodDates.number($0) != nil }),
              endNumber - firstNumber + 1 == processingDays.count else { throw AnalyticsFailure.access }
        let selection = try AnalyticsDownloadSelection(kind: kind, level: level, granularity: granularity, endDate: end, days: processingDays.count, requestId: requestId, today: PeriodDates.text(now))
        let (_, task) = try await createAnalyticsDownload(account: account, appId: appId, selection: selection, client: client, reuseRunning: false, now: now)
        guard let task else { throw ReportJobFailure.busy }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

public struct AnalyticsDownloadJob: Identifiable, Equatable, Sendable, PersistentReportJob {
    public enum Phase: String, Sendable { case discovering, downloading, saving }
    public let id: String, startedAt: String, selection: AnalyticsDownloadSelection
    public internal(set) var state: ReportJobState, phase: Phase, updatedAt: String
    public internal(set) var completed: Int, total: Int, segments: Int, bytes: Int
    public internal(set) var result: AnalyticsSyncResult?, code: String?
    var isActive: Bool { state == .running }
    public var error: String? { code.map(ReportingMessages.message) }
    public var json: JSONText {
        var fields: [(String, JSONText)] = [("id", .string(id)), ("state", .string(state.rawValue)), ("phase", .string(phase.rawValue)), ("completed", .number(Double(completed))),
            ("total", .number(Double(total))), ("segments", .number(Double(segments))), ("bytes", .number(Double(bytes))), ("startedAt", .string(startedAt)), ("updatedAt", .string(updatedAt)), ("selection", selection.json)]
        if let result {
            let changes = result.changes
            fields.append(("result", .object([("saved", .bool(changes.added + changes.replaced + changes.unchanged + changes.older + result.reusedInstances > 0)), ("instances", .number(Double(result.instances))),
                ("noAppInstances", .number(Double(result.noAppInstances))), ("added", .number(Double(changes.added))), ("replaced", .number(Double(changes.replaced))),
                ("unchanged", .number(Double(changes.unchanged))), ("older", .number(Double(changes.older)))]
                + (result.reusedInstances > 0 ? [("reusedInstances", JSONText.number(Double(result.reusedInstances)))] : [])
                + (result.unavailableDays.isEmpty ? [] : [("unavailableProcessingDates", JSONText.array(result.unavailableDays.map(JSONText.string)))]))))
        }
        if let code { fields += [("code", .string(code)), ("error", .string(ReportingMessages.message(code)))] }
        return .object(fields)
    }
    init(id: String, selection: AnalyticsDownloadSelection, now: Date) {
        self.id = id; self.selection = selection; startedAt = CustomerReview.isoString(now); updatedAt = startedAt
        state = .running; phase = .discovering; completed = 0; total = 0; segments = 0; bytes = 0; result = nil; code = nil
    }
    public init(json: JSONText) throws {
        func number(_ value: JSONText?) throws -> Int {
            guard case .number(let raw)? = value, let n = Int(exactly: raw), (0...9_007_199_254_740_991).contains(n) else { throw ReportJobFailure.status }; return n
        }
        guard let id = json["id"]?.text, ReportJobs.uuid(id), let state = json["state"]?.text.flatMap(ReportJobState.init(rawValue:)),
              let phase = json["phase"]?.text.flatMap(Phase.init(rawValue:)), let start = json["startedAt"]?.text, ReportTimestamps.valid(start),
              let update = json["updatedAt"]?.text, ReportTimestamps.valid(update), let selected = json["selection"] else { throw ReportJobFailure.status }
        self.id = id; self.state = state; self.phase = phase; startedAt = start; updatedAt = update; selection = try AnalyticsDownloadSelection(json: selected)
        completed = try number(json["completed"]); total = try number(json["total"]); segments = try number(json["segments"]); bytes = try number(json["bytes"])
        guard completed <= total, total <= 365 else { throw ReportJobFailure.status }
        if state == .complete {
            guard let data = json["result"], case .bool(let saved)? = data["saved"] else { throw ReportJobFailure.status }
            let instances = try number(data["instances"]), noApp = try number(data["noAppInstances"]), added = try number(data["added"]), replaced = try number(data["replaced"]),
                unchanged = try number(data["unchanged"]), older = try number(data["older"]), reused = try data["reusedInstances"].map { try number($0) } ?? 0
            guard [instances, noApp, added, replaced, unchanged, older].allSatisfy({ $0 <= 2000 }), instances == total, completed == total, noApp <= instances,
                  reused <= instances - noApp, saved == (added + replaced + unchanged + older + reused > 0) else { throw ReportJobFailure.status }
            var value = AnalyticsSyncResult(instances: instances, noAppInstances: noApp)
            value.changes = AnalyticsReports.Changes(added: added, replaced: replaced, unchanged: unchanged, older: older)
            if let raw = data["unavailableProcessingDates"] {
                guard case .array(let days) = raw, days.count + instances <= selection.days else { throw ReportJobFailure.status }
                let wanted = Set(selection.processingDays)
                value.unavailableDays = try days.map { day in guard let text = day.text, wanted.contains(text) else { throw ReportJobFailure.status }; return text }
                guard Set(value.unavailableDays).count == value.unavailableDays.count else { throw ReportJobFailure.status }
            }
            value.reusedInstances = reused; result = value
        } else { result = nil }
        code = state == .failed ? ReportingMessages.normalized(json["code"]?.text) : nil
    }
    func matches(_ family: ReportJobs.Family) -> Bool {
        switch family { case .analytics: true; case .downloads: selection.kind == "downloads"; case .engagement: selection.kind == "engagement"; default: false }
    }
    mutating func fail(_ error: Error, at: String) {
        state = .failed; updatedAt = at; result = nil; code = Self.failureCode(error)
    }
    static func failureCode(_ error: Error) -> String {
        switch error {
        case let failure as ReportJobFailure: failure.code
        case is JobLock.Failure, is FileMutex.Failure: "SB-REPORT-LOCK"
        case AppStoreConnectClient.Failure.agreement, AccountFailure.agreement: "SB-APPLE-AGREEMENT"
        case AppStoreConnectClient.Failure.status(401): "SB-APPLE-AUTH"
        case AppStoreConnectClient.Failure.status(403): "SB-APPLE-ACCESS"
        case ReviewsFailure.noKey, is CredentialAccessFailure: "SB-APPLE-KEYCHAIN"
        case let failure as AnalyticsFailure:
            switch failure {
            case .setup: "SB-ANALYTICS-SETUP"; case .inactive: "SB-ANALYTICS-INACTIVE"; case .reportMissing: "SB-ANALYTICS-REPORT-MISSING"; case .period: "SB-ANALYTICS-PERIOD";
            case .noInstances: "SB-ANALYTICS-NO-INSTANCES"; case .access: "SB-ANALYTICS-ACCESS"; case .segmentsPending: "SB-ANALYTICS-SEGMENTS-PENDING";
            case .download: "SB-ANALYTICS-DOWNLOAD"; case .integrity: "SB-ANALYTICS-INTEGRITY"; case .limit: "SB-ANALYTICS-LIMIT";
            case .format: "SB-ANALYTICS-FORMAT"; case .segments: "SB-ANALYTICS-SEGMENTS"; case .scope: "SB-ANALYTICS-SCOPE"
            }
        case AnalyticsFileFailure.stale, PartitionedReports.Failure.stale: "SB-ANALYTICS-STALE"
        case is AnalyticsFileFailure, is EncryptedDocumentStore.Failure, is PartitionedReports.Failure: "SB-ANALYTICS-STORAGE"
        default: "SB-ANALYTICS-DOWNLOAD"
        }
    }
}
