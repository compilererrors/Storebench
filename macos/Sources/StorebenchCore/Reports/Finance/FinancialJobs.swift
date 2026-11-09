import Foundation

/// Finance progress uses the shared job contract; report history still requires explicit local review.
public struct FinancialDownloadJob: Identifiable, Equatable, Sendable, PersistentReportJob {
    public enum Phase: String, Sendable { case downloading, preparing }
    public struct Result: Equatable, Sendable {
        public let reviewId: String?, reports: Int, noApp: [String], unavailable: [String]
        var json: JSONText { .object([("reviewId", reviewId.map(JSONText.string) ?? .null), ("reports", .number(Double(reports))),
            ("noApp", .array(noApp.map(JSONText.string))), ("unavailable", .array(unavailable.map(JSONText.string)))]) }
        init(reviewId: String?, reports: Int, noApp: [String], unavailable: [String]) {
            self.reviewId = reviewId; self.reports = reports; self.noApp = noApp; self.unavailable = unavailable
        }
        init(json: JSONText, selection: FinancialDownloadSelection) throws {
            guard case .number(let raw)? = json["reports"], let reports = Int(exactly: raw), (0...selection.periods).contains(reports),
                  case .array(let missing)? = json["noApp"], case .array(let waiting)? = json["unavailable"] else { throw ReportJobFailure.status }
            func keys(_ values: [JSONText]) throws -> [String] {
                try values.map { guard let key = $0.text, selection.keys.contains(key) else { throw ReportJobFailure.status }; return key }
            }
            let noApp = try keys(missing), unavailable = try keys(waiting)
            guard Set(noApp + unavailable).count == noApp.count + unavailable.count, reports + noApp.count + unavailable.count == selection.periods else { throw ReportJobFailure.status }
            let reviewId = json["reviewId"]?.text
            guard reports > 0 ? reviewId.map(ReportJobs.uuid) == true : json["reviewId"] == .null else { throw ReportJobFailure.status }
            self.init(reviewId: reviewId, reports: reports, noApp: noApp, unavailable: unavailable)
        }
    }
    public let id: String, startedAt: String, selection: FinancialDownloadSelection
    public internal(set) var state: ReportJobState, phase: Phase, completed: Int, bytes: Int, updatedAt: String, result: Result?, code: String?
    public var total: Int { selection.periods }
    public var isActive: Bool { state == .running }
    public var error: String? { code.map(ReportingMessages.message) }
    public var json: JSONText {
        var fields: [(String, JSONText)] = [("id", .string(id)), ("state", .string(state.rawValue)), ("phase", .string(phase.rawValue)),
            ("completed", .number(Double(completed))), ("total", .number(Double(total))), ("bytes", .number(Double(bytes))),
            ("selection", selection.json), ("startedAt", .string(startedAt)), ("updatedAt", .string(updatedAt))]
        if let result { fields.append(("result", result.json)) }
        if let code { fields += [("code", .string(code)), ("error", .string(ReportingMessages.message(code)))] }; return .object(fields)
    }
    init(id: String, selection: FinancialDownloadSelection, now: Date) {
        self.id = id; self.selection = selection; startedAt = CustomerReview.isoString(now); updatedAt = startedAt
        state = .running; phase = .downloading; completed = 0; bytes = 0; result = nil; code = nil
    }
    public init(json: JSONText) throws {
        guard let id = json["id"]?.text, ReportJobs.uuid(id), let state = json["state"]?.text.flatMap(ReportJobState.init(rawValue:)),
              let phase = json["phase"]?.text.flatMap(Phase.init(rawValue:)), let start = json["startedAt"]?.text, ReportTimestamps.valid(start),
              let update = json["updatedAt"]?.text, ReportTimestamps.valid(update), let selected = json["selection"],
              case .number(let rawCompleted)? = json["completed"], let completed = Int(exactly: rawCompleted),
              case .number(let rawTotal)? = json["total"], let total = Int(exactly: rawTotal),
              case .number(let rawBytes)? = json["bytes"], let bytes = Int(exactly: rawBytes) else { throw ReportJobFailure.status }
        let selection: FinancialDownloadSelection
        do { selection = try FinancialDownloadSelection(json: selected) } catch { throw ReportJobFailure.status }
        guard total == selection.periods, (0...total).contains(completed), (0...(Int(ceil(Double(total) / 12)) * 10_000_000)).contains(bytes) else { throw ReportJobFailure.status }
        self.id = id; self.selection = selection; self.state = state; self.phase = phase; self.completed = completed; self.bytes = bytes; startedAt = start; updatedAt = update
        if state == .complete {
            guard completed == total, phase == .preparing, let value = json["result"] else { throw ReportJobFailure.status }
            result = try Result(json: value, selection: selection)
        } else { result = nil }
        code = state == .failed ? ReportingMessages.normalized(json["code"]?.text) : nil
    }
    func matches(_ family: ReportJobs.Family) -> Bool { family == .financial }
    mutating func fail(_ error: Error, at: String) { state = .failed; updatedAt = at; result = nil; code = Self.failureCode(error) }
    static func failureCode(_ error: Error) -> String {
        if error is URLError { return "SB-FINANCE-NETWORK" }
        return switch error {
        case AppStoreConnectClient.Failure.status(429): "SB-FINANCE-SERVICE"
        case AppStoreConnectClient.Failure.status(let status) where status >= 500: "SB-FINANCE-SERVICE"
        case ReporterClient.Failure.serviceUnavailable: "SB-FINANCE-SERVICE"
        case ReporterClient.Failure.access: "SB-FINANCE-ACCESS"
        case ReporterClient.Failure.wrongAccount: "SB-REPORTER-CHANGED"
        case ReporterClient.Failure.unsupported: "SB-FINANCE-RESPONSE"
        case ReporterClient.Failure.invalidToken: "SB-REPORTER-SETUP"
        case ReporterClient.Failure.size: "SB-REPORT-SIZE"
        case let failure as ReportJobFailure: failure.code
        case is FileMutex.Failure, is JobLock.Failure: "SB-REPORT-LOCK"
        case AppStoreConnectClient.Failure.agreement, AccountFailure.agreement: "SB-APPLE-AGREEMENT"
        case AppStoreConnectClient.Failure.status(401): "SB-APPLE-AUTH"
        case AppStoreConnectClient.Failure.status(403): "SB-APPLE-ACCESS"
        case ReviewsFailure.noKey, is CredentialAccessFailure: "SB-APPLE-KEYCHAIN"
        case ReporterClient.Failure.expiredToken: "SB-REPORTER-SETUP"
        case let failure as FinanceFailure:
            switch failure {
            case .request: "SB-FINANCE-REQUEST"; case .access: "SB-FINANCE-ACCESS"; case .download: "SB-FINANCE-DOWNLOAD";
            case .period: "SB-FINANCE-PERIOD"; case .format: "SB-FINANCE-FORMAT"; case .scope: "SB-FINANCE-SCOPE";
            case .overlap: "SB-FINANCE-OVERLAP"; case .stale: "SB-FINANCE-STALE"; case .expiredReview: "SB-FINANCE-REVIEW";
            case .size: "SB-REPORT-SIZE"; case .noConnection: "SB-FINANCE-CONNECTION"
            }
        case FinancialFileFailure.changedFiles, PartitionedReports.Failure.stale: "SB-FINANCE-STALE"
        case is FinancialFileFailure, is EncryptedDocumentStore.Failure, is PartitionedReports.Failure: "SB-FINANCE-STORAGE"
        default: "SB-FINANCE-DOWNLOAD"
        }
    }
}

extension WorkspaceSession {
    /// Recovery reads one SQL snapshot while holding the job mutex. It does not nest a review mutex inside SQL.
    func recoverFinancialJob(_ job: inout FinancialDownloadJob, account: Account, appId: String, store: EncryptedDocumentStore, now: Date) throws {
        try financialFileScope(account, appId: appId)
        let key = "\(account.id):\(appId)"
        if job.phase == .preparing, job.completed == job.total, let pending = try store.document(namespace: "financial_pending", key: key) {
            let pointer = try JSONText.parse(pending.payload)
            guard let id = pointer["id"]?.text, ReportJobs.uuid(id) else { throw ReportJobFailure.status }
            if id == job.id {
                let records = try FinancialDownloadRecord.cache(store.document(namespace: "financial_reviews", key: key)?.payload, accountId: account.id, appId: appId, now: now)
                if let record = records.first(where: { $0.id == job.id && $0.selection == job.selection && $0.expiresAt > now }) {
                    let result = try FinancialDownloadJob.Result(json: .object([("reviewId", .string(id)), ("reports", .number(Double(record.reports.count))),
                        ("noApp", pointer["noApp"] ?? .null), ("unavailable", pointer["unavailable"] ?? .null)]), selection: job.selection)
                    job.state = .complete; job.result = result; job.code = nil; job.updatedAt = CustomerReview.isoString(now); return
                }
            }
        }
        job.fail(ReportJobFailure.status, at: CustomerReview.isoString(now))
    }
    public func financialDownloadJob(account: Account, appId: String, now: Date = Date()) throws -> FinancialDownloadJob? {
        try financialFileScope(account, appId: appId)
        return try storeAccess { store in try ReportJobs.read(FinancialDownloadJob.self, family: .financial, accountId: account.id, appId: appId, store: store, now: now,
            interrupted: { job, store in try self.recoverFinancialJob(&job, account: account, appId: appId, store: store, now: now) }) }
    }
    public func cancelFinancialDownload(account: Account, appId: String, id: String) throws -> FinancialDownloadJob? {
        guard ReportJobs.uuid(id) else { throw ReportJobFailure.request }
        guard let current = try financialDownloadJob(account: account, appId: appId), current.id == id, current.isActive else { return try financialDownloadJob(account: account, appId: appId) }
        let requested = try storeAccess { try ReportJobs.cancel(FinancialDownloadJob.self, family: .financial, accountId: account.id, appId: appId, id: id, store: $0) }
        let name = try ReportJobs.name(.financial, accountId: account.id, appId: appId)
        if requested, reportTasks[name]?.id == id { reportTasks[name]?.cancel() }; return current
    }
    func pollFinancialCancellation(_ ownership: ReportJobs.Ownership, name: String) {
        guard reportTasks[name]?.id == ownership.id else { return }
        do { try storeAccess { try ReportJobs.checkCancellation(FinancialDownloadJob.self, ownership: ownership, store: $0) } }
        catch is CancellationError { reportTasks[name]?.cancel() }
        catch { reportTaskFailures.insert(ownership.id); reportTasks[name]?.cancel() }
    }
    func executeFinancialDownload(account: Account, appId: String, client: AppStoreConnectClient?, reporter: ReporterClient?, job: FinancialDownloadJob,
                                  ownership: ReportJobs.Ownership, now: Date) async throws -> FinancialDownload {
        var current = job
        var connection: SalesConnection?
        let name = try ReportJobs.name(.financial, accountId: account.id, appId: appId)
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self else { return }; await self.pollFinancialCancellation(ownership, name: name)
            }
        }
        defer { monitor.cancel(); if reportTasks[name]?.id == job.id { reportTasks[name] = nil }; reportTaskFailures.remove(job.id); ownership.release() }
        func check() throws {
            try self.financialFileScope(account, appId: appId)
            try self.storeAccess { try ReportJobs.checkCancellation(FinancialDownloadJob.self, ownership: ownership, store: $0) }
            if let connection {
                let current = try self.salesConnection(accountId: account.id)
                let selected = job.selection.source == .api ? current.map { ReportingConnection(accountId: $0.accountId, vendorNumber: $0.vendorNumber, reporter: nil) } : current
                guard selected == connection else { throw FinanceFailure.access }
            }
        }
        do {
            try check()
            let selection = job.selection
            let client = try selection.source == .api ? client ?? self.client(for: account) : client
            let reporter = try selection.source == .reporter ? reporter ?? self.reporterClient(accountId: account.id) : nil
            do { connection = try capturedSalesConnection(accountId: account.id, reporter: reporter, source: selection.source) }
            catch SalesFailure.changedConnection { throw FinanceFailure.access }
            var review = try await downloadFinancialBody(account: account, appId: appId, region: selection.region,
                periods: FinancialReports.periods(ending: FiscalPeriod(year: selection.year, period: selection.period), count: selection.periods), client: client,
                reporter: reporter, source: selection.source, now: now, reviewId: UUID(uuidString: job.id)!, check: check,
                progress: { phase, completed, bytes in
                    try check(); current.phase = phase; current.completed = completed; current.bytes = bytes; current.updatedAt = CustomerReview.isoString(Date())
                    try self.storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
                })
            try check()
            if !review.reports.isEmpty {
                try retainFinancialDownload(review, now: Date(), check: check)
                guard let retained = try pendingFinancialDownload(accountId: account.id, appId: appId) else { throw FinanceFailure.expiredReview }
                review = retained
                guard review.id.uuidString.lowercased() == job.id else { throw FinanceFailure.stale }
            }
            // A retained review is the exact durable result, even if a stop arrives after its commit.
            try financialFileScope(account, appId: appId)
            current.state = .complete; current.phase = .preparing; current.completed = current.total; current.updatedAt = CustomerReview.isoString(Date())
            current.result = .init(reviewId: review.reports.isEmpty ? nil : job.id, reports: review.reports.count, noApp: review.noApp, unavailable: review.unavailable)
            try storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }; return review
        } catch {
            if reportTaskFailures.contains(job.id) { current.fail(ReportJobFailure.status, at: CustomerReview.isoString(Date())) }
            else if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { current.state = .cancelled; current.result = nil; current.code = nil; current.updatedAt = CustomerReview.isoString(Date()) }
            else { current.fail(error, at: CustomerReview.isoString(Date())) }
            try? storeAccess { store in
                try store.transaction { read in
                    try ownership.verify()
                    guard let previous = try ReportJobs.parsed(FinancialDownloadJob.self, read("jobs", ownership.key), family: .financial), previous.id == job.id else { throw ReportJobFailure.status }
                    guard previous.isActive else { return [] }
                    var recovered = previous
                    do {
                        try self.recoverFinancialJob(&recovered, account: account, appId: appId, store: store, now: Date())
                        if recovered.state == .complete { current = recovered }
                    } catch { if current.state != .cancelled { current.fail(error, at: CustomerReview.isoString(Date())) } }
                    return [.put(namespace: "jobs", key: ownership.key, json: try FinancialDownloadJob(json: current.json).json.data)]
                }
            }
            throw error
        }
    }
    func createFinancialDownload(account: Account, appId: String, selection: FinancialDownloadSelection, client: AppStoreConnectClient?, reporter: ReporterClient?,
                                 reuseRunning: Bool, now: Date, binding: SyncChildBinding? = nil) async throws -> (FinancialDownloadJob, Task<FinancialDownload, Error>?) {
        try Task.checkCancellation(); try financialFileScope(account, appId: appId)
        guard let year = Int(PeriodDates.text(now).prefix(4)), selection.year <= year + 1 else { throw FinanceFailure.request }
        let id = UUID().uuidString.lowercased(), clock = ContinuousClock(), deadline = clock.now + .milliseconds(500)
        var ownership: ReportJobs.Ownership?
        while ownership == nil {
            ownership = try ReportJobs.acquire(.financial, accountId: account.id, appId: appId, directory: try storeAccess { $0.directory }, id: id)
            if ownership == nil {
                if let current = try financialDownloadJob(account: account, appId: appId), current.isActive { if reuseRunning { return (current, nil) }; throw ReportJobFailure.busy }
                guard clock.now < deadline else { throw ReportJobFailure.busy }
                try await Task.sleep(for: .milliseconds(25)); try Task.checkCancellation()
            }
        }
        guard let ownership else { throw ReportJobFailure.busy }
        do {
            try financialFileScope(account, appId: appId); try Task.checkCancellation()
            let recovered = try storeAccess { store in try ReportJobs.recover(FinancialDownloadJob.self, family: .financial, ownership: ownership, accountId: account.id, appId: appId, store: store,
                interrupted: { job, store in try self.recoverFinancialJob(&job, account: account, appId: appId, store: store, now: Date()) }) }
            if let recovered, recovered.state == .complete { ownership.release(); return (recovered, nil) }
            let job = FinancialDownloadJob(id: id, selection: selection, now: Date()); try storeAccess { try ReportJobs.start(job, ownership: ownership, store: $0, binding: binding) }
            let task = try ownedReport { try await self.executeFinancialDownload(account: account, appId: appId, client: client, reporter: reporter, job: job, ownership: ownership, now: now) }
            let name = try ReportJobs.name(.financial, accountId: account.id, appId: appId); reportTasks[name] = (id, { task.cancel() }); return (job, task)
        } catch { ownership.release(); throw error }
    }
    /// Starts or follows one Finance job without reading credentials for an already running download.
    public func startFinancialDownload(account: Account, appId: String, selection: FinancialDownloadSelection, client: AppStoreConnectClient? = nil,
                                       reporter: ReporterClient? = nil, now: Date = Date()) async throws -> FinancialDownloadJob {
        try await createFinancialDownload(account: account, appId: appId, selection: selection, client: client, reporter: reporter, reuseRunning: true, now: now).0
    }
    /// Foreground callers await the same durable job. Cancellation identifies only their owned task.
    public func downloadFinancial(account: Account, appId: String, region: String, periods: [FiscalPeriod], client: AppStoreConnectClient? = nil,
                                  reporter: ReporterClient? = nil, source: ReportingSource? = nil, now: Date = Date()) async throws -> FinancialDownload {
        try Task.checkCancellation(); try financialFileScope(account, appId: appId)
        let selectedSource = try source ?? (salesConnection(accountId: account.id)?.reporter == nil ? .api : .reporter)
        let selection = try FinancialDownloadSelection(source: selectedSource, periods: periods, region: region)
        let (job, task) = try await createFinancialDownload(account: account, appId: appId, selection: selection, client: client, reporter: reporter, reuseRunning: false, now: now)
        if let task { return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() }) }
        guard let review = try pendingFinancialDownload(accountId: account.id, appId: appId), review.id.uuidString.lowercased() == job.result?.reviewId else { throw FinanceFailure.expiredReview }; return review
    }
}
