import Foundation

/// Shared encrypted review progress and fixed public guidance, normalized to the status contract.
public struct ReviewsDownloadJob: Identifiable, Equatable, Sendable, PersistentReportJob {
    public enum Phase: String, Sendable { case downloading, saving }
    public let id: String, startedAt: String
    public internal(set) var state: ReportJobState, phase: Phase, pages: Int, reviews: Int, updatedAt: String, result: ReviewChanges?, code: String?
    public var isActive: Bool { state == .running }
    public var error: String? { state == .failed ? ReportingMessages.message(code ?? "SB-REPORT-UNCONFIRMED") : nil }
    public var json: JSONText {
        var fields: [(String, JSONText)] = [("id", .string(id)), ("state", .string(state.rawValue)), ("phase", .string(phase.rawValue)),
            ("pages", .number(Double(pages))), ("reviews", .number(Double(reviews))), ("startedAt", .string(startedAt)), ("updatedAt", .string(updatedAt))]
        if let result { fields.append(("result", result.json)) }
        if state == .failed { fields += [("code", .string(code ?? "SB-REPORT-UNCONFIRMED")), ("error", .string(error!))] }; return .object(fields)
    }
    init(id: String, now: Date) {
        self.id = id; startedAt = CustomerReview.isoString(now); updatedAt = startedAt; state = .running; phase = .downloading; pages = 0; reviews = 0
    }
    static func count(_ value: JSONText?) throws -> Int {
        guard case .number(let raw)? = value, let count = Int(exactly: raw), (0...9_007_199_254_740_991).contains(count) else { throw ReportJobFailure.status }; return count
    }
    public init(json: JSONText) throws {
        guard let id = json["id"]?.text, ReportJobs.uuid(id), let state = json["state"]?.text.flatMap(ReportJobState.init(rawValue:)),
              let phase = json["phase"]?.text.flatMap(Phase.init(rawValue:)), let start = json["startedAt"]?.text, ReportTimestamps.valid(start),
              let update = json["updatedAt"]?.text, ReportTimestamps.valid(update) else { throw ReportJobFailure.status }
        let pages = try Self.count(json["pages"]), reviews = try Self.count(json["reviews"])
        guard reviews / 200 + (reviews % 200 == 0 ? 0 : 1) <= pages else { throw ReportJobFailure.status }
        self.id = id; self.state = state; self.phase = phase; self.pages = pages; self.reviews = reviews; startedAt = start; updatedAt = update
        if state == .complete {
            guard pages > 0, phase == .saving, let value = json["result"], case .bool(let limited)? = value["limited"] else { throw ReportJobFailure.status }
            let added = try Self.count(value["added"]), updated = try Self.count(value["updated"]), unchanged = try Self.count(value["unchanged"]), removed = try Self.count(value["removed"])
            guard added + updated + unchanged == reviews else { throw ReportJobFailure.status }
            result = .init(added: added, updated: updated, unchanged: unchanged, removed: removed, limited: limited)
        }
        if state == .failed { code = ReportingMessages.normalized(json["code"]?.text) }
    }
    func matches(_ family: ReportJobs.Family) -> Bool { family == .reviews }
    mutating func fail(_ error: Error, at: String) { state = .failed; updatedAt = at; result = nil; code = Self.failureCode(error) }
    mutating func complete(_ value: ReviewChanges, at: String) { state = .complete; phase = .saving; updatedAt = at; result = value; code = nil }
    static func failureCode(_ error: Error) -> String {
        switch error {
        case let failure as ReportJobFailure: failure.code
        case is JobLock.Failure, is FileMutex.Failure: "SB-REPORT-LOCK"
        case AppStoreConnectClient.Failure.agreement, AccountFailure.agreement: "SB-APPLE-AGREEMENT"
        case AppStoreConnectClient.Failure.status(401): "SB-APPLE-AUTH"
        case AppStoreConnectClient.Failure.status(403): "SB-REVIEWS-ACCESS"
        case ReviewsFailure.noKey, is CredentialAccessFailure: "SB-APPLE-KEYCHAIN"
        case ReviewsFailure.scope, AccountFailure.stale, AccountFailure.notFound: "SB-REVIEWS-SCOPE"
        case ReviewsFailure.stale, PartitionedReports.Failure.stale: "SB-REVIEWS-STALE"
        case ReviewsFailure.storage, is EncryptedDocumentStore.Failure, is PartitionedReports.Failure: "SB-REVIEWS-STORAGE"
        case ReviewsFailure.integrity, AppStoreConnectClient.Failure.invalidPagination: "SB-REVIEWS-INTEGRITY"
        case ReviewsFailure.format, AppStoreConnectClient.Failure.unreadableResponse: "SB-REVIEWS-FORMAT"
        default: "SB-REVIEWS-DOWNLOAD"
        }
    }
}

extension WorkspaceSession {
    public func reviewsDownloadJob(account: Account, appId: String, now: Date = Date()) throws -> ReviewsDownloadJob? {
        try reviewsScope(account, appId: appId)
        return try storeAccess { try ReportJobs.read(ReviewsDownloadJob.self, family: .reviews, accountId: account.id, appId: appId, store: $0, now: now) }
    }
    public func cancelReviewsDownload(account: Account, appId: String, id: String) throws -> ReviewsDownloadJob? {
        guard ReportJobs.uuid(id) else { throw ReportJobFailure.request }
        guard let current = try reviewsDownloadJob(account: account, appId: appId), current.id == id, current.isActive else { return try reviewsDownloadJob(account: account, appId: appId) }
        let requested = try storeAccess { try ReportJobs.cancel(ReviewsDownloadJob.self, family: .reviews, accountId: account.id, appId: appId, id: id, store: $0) }
        let name = try ReportJobs.name(.reviews, accountId: account.id, appId: appId)
        if requested, reportTasks[name]?.id == id { reportTasks[name]?.cancel() }; return current
    }
    func pollReviewsCancellation(_ ownership: ReportJobs.Ownership, name: String, deadline: ContinuousClock.Instant) {
        guard reportTasks[name]?.id == ownership.id else { return }
        if ContinuousClock.now >= deadline { reportTasks[name]?.cancel(); return }
        do { try storeAccess { try ReportJobs.checkCancellation(ReviewsDownloadJob.self, ownership: ownership, store: $0) } }
        catch is CancellationError { reportTasks[name]?.cancel() }
        catch { reportTaskFailures.insert(ownership.id); reportTasks[name]?.cancel() }
    }
    func executeReviewsDownload(account: Account, appId: String, client: AppStoreConnectClient?, job: ReviewsDownloadJob,
                                ownership: ReportJobs.Ownership, now: Date) async throws -> ReviewChanges {
        var current = job
        let name = try ReportJobs.name(.reviews, accountId: account.id, appId: appId), deadline = ContinuousClock.now + .seconds(3600)
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self else { return }; await self.pollReviewsCancellation(ownership, name: name, deadline: deadline)
            }
        }
        defer { monitor.cancel(); if reportTasks[name]?.id == job.id { reportTasks[name] = nil }; reportTaskFailures.remove(job.id); ownership.release() }
        func check() throws {
            guard ContinuousClock.now < deadline else { throw ReviewsFailure.timeout }
            try self.reviewsScope(account, appId: appId)
            try self.storeAccess { try ReportJobs.checkCancellation(ReviewsDownloadJob.self, ownership: ownership, store: $0) }
        }
        do {
            try check(); let client = try client ?? self.client(for: account)
            return try await downloadReviewsBody(account: account, appId: appId, client: client, now: now, check: check,
                progress: { phase, pages, count in
                    try self.reviewsScope(account, appId: appId); try check()
                    current.phase = phase; current.pages = pages; current.reviews = count; current.updatedAt = CustomerReview.isoString(Date())
                    try self.storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
                }, completion: { result, store in
                    try self.reviewsScope(account, appId: appId); try check(); current.complete(result, at: CustomerReview.isoString(Date()))
                    return try ReportJobs.terminalWrites(current, ownership: ownership, current: { try store.document(namespace: $0, key: $1) })
                })
        } catch {
            if ContinuousClock.now >= deadline { current.fail(ReviewsFailure.timeout, at: CustomerReview.isoString(Date())) }
            else if reportTaskFailures.contains(job.id) { current.fail(ReportJobFailure.status, at: CustomerReview.isoString(Date())) }
            else if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { current.state = .cancelled; current.result = nil; current.code = nil; current.updatedAt = CustomerReview.isoString(Date()) }
            else { current.fail(error, at: CustomerReview.isoString(Date())) }
            try? storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }; throw error
        }
    }
    func createReviewsDownload(account: Account, appId: String, client: AppStoreConnectClient?, reuseRunning: Bool, now: Date,
        binding: SyncChildBinding? = nil) async throws -> (ReviewsDownloadJob, Task<ReviewChanges, Error>?) {
        try Task.checkCancellation(); try reviewsScope(account, appId: appId)
        let id = UUID().uuidString.lowercased(), deadline = ContinuousClock.now + .milliseconds(500)
        var ownership: ReportJobs.Ownership?
        while ownership == nil {
            ownership = try ReportJobs.acquire(.reviews, accountId: account.id, appId: appId, directory: try storeAccess { $0.directory }, id: id)
            if ownership == nil {
                if let current = try reviewsDownloadJob(account: account, appId: appId), current.isActive { if reuseRunning { return (current, nil) }; throw ReportJobFailure.busy }
                guard ContinuousClock.now < deadline else { throw ReportJobFailure.busy }
                try await Task.sleep(for: .milliseconds(25)); try Task.checkCancellation()
            }
        }
        guard let ownership else { throw ReportJobFailure.busy }
        do {
            try reviewsScope(account, appId: appId); try Task.checkCancellation()
            _ = try storeAccess { try ReportJobs.recover(ReviewsDownloadJob.self, family: .reviews, ownership: ownership, accountId: account.id, appId: appId, store: $0) }
            let job = ReviewsDownloadJob(id: id, now: Date()); try storeAccess { try ReportJobs.start(job, ownership: ownership, store: $0, binding: binding) }
            let task = try ownedReport { try await self.executeReviewsDownload(account: account, appId: appId, client: client, job: job, ownership: ownership, now: now) }
            let name = try ReportJobs.name(.reviews, accountId: account.id, appId: appId); reportTasks[name] = (id, { task.cancel() }); return (job, task)
        } catch { ownership.release(); throw error }
    }
    /// Starts or follows the shared download before reading credentials; navigation leaves the job running.
    public func startReviewsDownload(account: Account, appId: String, client: AppStoreConnectClient? = nil, now: Date = Date()) async throws -> ReviewsDownloadJob {
        try await createReviewsDownload(account: account, appId: appId, client: client, reuseRunning: true, now: now).0
    }
    public func downloadReviews(account: Account, appId: String, client: AppStoreConnectClient? = nil, now: Date = Date()) async throws -> ReviewChanges {
        let (_, task) = try await createReviewsDownload(account: account, appId: appId, client: client, reuseRunning: false, now: now)
        guard let task else { throw ReportJobFailure.busy }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
