import Foundation

public struct SalesDownloadSelection: Equatable, Sendable {
    public let source: ReportingSource, beginDate: String, endDate: String, total: Int
    public var days: [String] { (0..<total).map { PeriodDates.text(PeriodDates.number(beginDate)! + $0) } }
    public init(source: ReportingSource, endDate: String, days: Int, latestCompletedDay: String = SalesReports.latestCompletedDay()) throws {
        guard let end = PeriodDates.number(endDate), (1...365).contains(days), endDate <= latestCompletedDay else { throw ReportJobFailure.request }
        let beginDate = PeriodDates.text(end - days + 1)
        guard PeriodDates.number(beginDate) != nil else { throw ReportJobFailure.request }
        self.source = source; self.beginDate = beginDate; self.endDate = endDate; total = days
    }
    init(source: ReportingSource, days: [String], now: Date) throws {
        guard let end = days.max(), Set(days).count == days.count else { throw ReportJobFailure.request }
        try self.init(source: source, endDate: end, days: days.count, latestCompletedDay: SalesReports.latestCompletedDay(now: now))
        guard self.days == days.sorted() else { throw ReportJobFailure.request }
    }
}

/// The shared Sales status; untrusted legacy diagnostics remain wire-compatible but never supply display text.
public struct SalesDownloadJob: Identifiable, Equatable, Sendable, PersistentReportJob {
    public enum Phase: String, Sendable { case downloading, saving }
    public struct Result: Equatable, Sendable {
        public let saved: Bool, periods: Int, unavailableDays: [String], noAppRowsDays: [String], noSalesDays: [String], connectionSaved: Bool?, changes: SalesReports.Changes?
        public var syncResult: SalesSyncResult { SalesSyncResult(changes: changes ?? .init(), unavailableDays: unavailableDays, noAppRowsDays: noAppRowsDays, noSalesDays: noSalesDays) }
        var json: JSONText {
            if !saved { return .object([("saved", .bool(false)), ("status", .string("no-app-rows")), ("periods", .number(0)),
                ("unavailableDates", .array(unavailableDays.map(JSONText.string))), ("noAppRowsDates", .array(noAppRowsDays.map(JSONText.string)))]) }
            var fields: [(String, JSONText)] = [("saved", .bool(true)), ("periods", .number(Double(periods))), ("unavailableDates", .array(unavailableDays.map(JSONText.string)))]
            if !noAppRowsDays.isEmpty { fields.append(("noAppRowsDates", .array(noAppRowsDays.map(JSONText.string)))) }
            if !noSalesDays.isEmpty { fields.append(("noSalesDates", .array(noSalesDays.map(JSONText.string)))) }
            fields.append(("connectionSaved", .bool(connectionSaved!)))
            if let changes { fields.append(("changes", .object([("added", .number(Double(changes.added))), ("updated", .number(Double(changes.updated))), ("unchanged", .number(Double(changes.unchanged)))]))) }
            return .object(fields)
        }
        init(value: SalesSyncResult, periods: Int) {
            saved = periods + value.noSalesDays.count > 0; self.periods = periods; unavailableDays = value.unavailableDays; noAppRowsDays = value.noAppRowsDays; noSalesDays = value.noSalesDays
            connectionSaved = saved ? true : nil; changes = saved ? value.changes : nil
        }
        init(json: JSONText) throws {
            guard json["error"] == nil, case .bool(let saved)? = json["saved"] else { throw ReportJobFailure.status }
            let periods = try SalesDownloadJob.count(json["periods"], maximum: 365)
            let unavailable = try SalesDownloadJob.dates(json["unavailableDates"]), noApp = try SalesDownloadJob.dates(json["noAppRowsDates"], optional: true), quiet = try SalesDownloadJob.dates(json["noSalesDates"], optional: true)
            guard Set(unavailable + noApp + quiet).count == unavailable.count + noApp.count + quiet.count, periods + unavailable.count + noApp.count + quiet.count <= 365 else { throw ReportJobFailure.status }
            let changes: SalesReports.Changes?
            if let value = json["changes"] {
                changes = try .init(added: SalesDownloadJob.count(value["added"], maximum: 500), updated: SalesDownloadJob.count(value["updated"], maximum: 500), unchanged: SalesDownloadJob.count(value["unchanged"], maximum: 500))
            } else { changes = nil }
            let connection: Bool?
            if saved {
                guard json["status"] == nil, periods + quiet.count > 0, case .bool(let connected)? = json["connectionSaved"],
                      changes.map({ $0.added + $0.updated + $0.unchanged == periods + quiet.count }) ?? true else { throw ReportJobFailure.status }; connection = connected
            } else {
                guard json["status"]?.text == "no-app-rows", periods == 0, !noApp.isEmpty, quiet.isEmpty, changes == nil, json["connectionSaved"] == nil else { throw ReportJobFailure.status }; connection = nil
            }
            self.saved = saved; self.periods = periods; unavailableDays = unavailable; noAppRowsDays = noApp; noSalesDays = quiet; self.changes = changes; connectionSaved = connection
        }
    }
    public let id: String, startedAt: String, selection: SalesDownloadSelection
    public internal(set) var state: ReportJobState, phase: Phase, checked: Int, withApp: Int, withoutApp: Int, unavailable: Int, noSales: Int, updatedAt: String, result: Result?, code: String?
    private var legacyError: String?
    public var total: Int { selection.total }
    public var isActive: Bool { state == .running }
    public var error: String? { state == .failed ? ReportingMessages.message(code ?? "SB-REPORT-JOB") : nil }
    public var json: JSONText {
        var fields: [(String, JSONText)] = [("id", .string(id)), ("state", .string(state.rawValue)), ("phase", .string(phase.rawValue)), ("total", .number(Double(total))),
            ("checked", .number(Double(checked))), ("withApp", .number(Double(withApp))), ("withoutApp", .number(Double(withoutApp))), ("unavailable", .number(Double(unavailable)))]
        if noSales > 0 { fields.append(("noSales", .number(Double(noSales)))) }
        fields += [("startedAt", .string(startedAt)), ("updatedAt", .string(updatedAt)), ("beginDate", .string(selection.beginDate)), ("endDate", .string(selection.endDate)), ("source", .string(selection.source.rawValue))]
        if let result { fields.append(("result", result.json)) }
        if state == .failed { fields += [("error", .string(legacyError ?? error!)), ("code", .string(code ?? "SB-REPORT-JOB"))] }; return .object(fields)
    }
    init(id: String, selection: SalesDownloadSelection, now: Date) {
        self.id = id; self.selection = selection; startedAt = CustomerReview.isoString(now); updatedAt = startedAt; state = .running; phase = .downloading
        checked = 0; withApp = 0; withoutApp = 0; unavailable = 0; noSales = 0; result = nil; code = nil; legacyError = nil
    }
    static func count(_ value: JSONText?, maximum: Int = 365) throws -> Int {
        guard case .number(let raw)? = value, let number = Int(exactly: raw), (0...maximum).contains(number) else { throw ReportJobFailure.status }; return number
    }
    static func dates(_ value: JSONText?, optional: Bool = false) throws -> [String] {
        if value == nil && optional { return [] }
        guard case .array(let values)? = value, values.count <= 365 else { throw ReportJobFailure.status }
        let dates = try values.map { guard let day = $0.text, PeriodDates.number(day) != nil else { throw ReportJobFailure.status }; return day }
        guard Set(dates).count == dates.count else { throw ReportJobFailure.status }; return dates
    }
    public init(json: JSONText) throws {
        guard let id = json["id"]?.text, ReportJobs.uuid(id), let state = json["state"]?.text.flatMap(ReportJobState.init(rawValue:)), let phase = json["phase"]?.text.flatMap(Phase.init(rawValue:)),
              let source = json["source"]?.text.flatMap(ReportingSource.init(rawValue:)), let begin = json["beginDate"]?.text, let end = json["endDate"]?.text,
              let start = json["startedAt"]?.text, ReportTimestamps.valid(start), let update = json["updatedAt"]?.text, ReportTimestamps.valid(update) else { throw ReportJobFailure.status }
        let total = try Self.count(json["total"]), selection: SalesDownloadSelection
        do { selection = try .init(source: source, endDate: end, days: total, latestCompletedDay: "9999-12-31") } catch { throw ReportJobFailure.status }
        guard selection.beginDate == begin else { throw ReportJobFailure.status }
        let checked = try Self.count(json["checked"], maximum: total), withApp = try Self.count(json["withApp"], maximum: total), without = try Self.count(json["withoutApp"], maximum: total), unavailable = try Self.count(json["unavailable"], maximum: total)
        let quiet = try Self.count(json["noSales"] == nil || json["noSales"] == .null ? .number(0) : json["noSales"], maximum: total)
        guard checked == withApp + without + unavailable + quiet else { throw ReportJobFailure.status }
        self.id = id; self.selection = selection; self.state = state; self.phase = phase; self.checked = checked; self.withApp = withApp; withoutApp = without; self.unavailable = unavailable; noSales = quiet; startedAt = start; updatedAt = update
        if state == .complete {
            guard checked == total, let value = json["result"] else { throw ReportJobFailure.status }
            let result = try Result(json: value)
            guard result.periods == withApp, result.unavailableDays.count == unavailable, result.noAppRowsDays.count == without, result.noSalesDays.count == quiet,
                  (result.unavailableDays + result.noAppRowsDays + result.noSalesDays).allSatisfy({ $0 >= begin && $0 <= end }) else { throw ReportJobFailure.status }; self.result = result
        } else { result = nil }
        if state == .failed {
            guard let text = json["error"]?.text, text.utf16.count <= 500 else { throw ReportJobFailure.status }
            legacyError = text; code = ReportingMessages.normalized(json["code"]?.text)
        } else { legacyError = nil; code = nil }
    }
    func matches(_ family: ReportJobs.Family) -> Bool { family == .sales }
    mutating func fail(_ error: Error, at: String) { state = .failed; updatedAt = at; result = nil; legacyError = nil; code = Self.failureCode(error) }
    mutating func complete(_ value: SalesSyncResult, at: String) { state = .complete; checked = total; updatedAt = at; result = .init(value: value, periods: withApp); code = nil; legacyError = nil }
    static func failureCode(_ error: Error) -> String {
        if error is URLError { return "SB-REPORT-NETWORK" }
        return switch error {
        case AppStoreConnectClient.Failure.status(429): "SB-REPORT-SERVICE"
        case AppStoreConnectClient.Failure.status(let status) where status >= 500: "SB-REPORT-SERVICE"
        case ReporterClient.Failure.serviceUnavailable: "SB-REPORT-SERVICE"
        case ReporterClient.Failure.access: "SB-REPORT-ACCESS"
        case ReporterClient.Failure.wrongAccount: "SB-REPORTER-CHANGED"
        case ReporterClient.Failure.unsupported: "SB-REPORTER-RESPONSE"
        case ReporterClient.Failure.invalidToken: "SB-REPORTER-SETUP"
        case ReporterClient.Failure.size: "SB-REPORT-SIZE"
        case let failure as ReportJobFailure: failure.code
        case is JobLock.Failure, is FileMutex.Failure: "SB-REPORT-LOCK"
        case AppStoreConnectClient.Failure.agreement, AccountFailure.agreement: "SB-APPLE-AGREEMENT"
        case AppStoreConnectClient.Failure.status(401): "SB-APPLE-AUTH"
        case AppStoreConnectClient.Failure.status(403), SalesFileFailure.scope: "SB-REPORT-ACCESS"
        case ReviewsFailure.noKey, is CredentialAccessFailure: "SB-APPLE-KEYCHAIN"
        case AccountFailure.stale, AccountFailure.notFound: "SB-REPORT-ACCESS"
        case ReporterClient.Failure.expiredToken: "SB-REPORTER-SETUP"
        case let failure as SalesFailure:
            switch failure {
            case .conflict: "SB-REPORT-OVERLAP"; case .period: "SB-REPORT-PERIOD"; case .size: "SB-REPORT-SIZE"; case .unavailable: "SB-REPORT-UNAVAILABLE";
            case .changedConnection: "SB-REPORTER-CHANGED"; case .noConnection: "SB-SYNC-CONNECTION"; default: "SB-REPORT-FORMAT"
            }
        case is SalesFileFailure, is EncryptedDocumentStore.Failure, is PartitionedReports.Failure: "SB-REPORT-STORAGE"
        default: "SB-REPORT-DOWNLOAD"
        }
    }
}

extension WorkspaceSession {
    public func salesDownloadJob(account: Account, appId: String, now: Date = Date()) throws -> SalesDownloadJob? {
        try salesFileScope(account, appId: appId)
        return try storeAccess { try ReportJobs.read(SalesDownloadJob.self, family: .sales, accountId: account.id, appId: appId, store: $0, now: now) }
    }
    public func cancelSalesDownload(account: Account, appId: String, id: String) throws -> SalesDownloadJob? {
        guard ReportJobs.uuid(id) else { throw ReportJobFailure.request }
        guard let current = try salesDownloadJob(account: account, appId: appId), current.id == id, current.isActive else { return try salesDownloadJob(account: account, appId: appId) }
        let requested = try storeAccess { try ReportJobs.cancel(SalesDownloadJob.self, family: .sales, accountId: account.id, appId: appId, id: id, store: $0) }
        let name = try ReportJobs.name(.sales, accountId: account.id, appId: appId)
        if requested, reportTasks[name]?.id == id { reportTasks[name]?.cancel() }; return current
    }
    func pollSalesCancellation(_ ownership: ReportJobs.Ownership, name: String) {
        guard reportTasks[name]?.id == ownership.id else { return }
        do { try storeAccess { try ReportJobs.checkCancellation(SalesDownloadJob.self, ownership: ownership, store: $0) } }
        catch is CancellationError { reportTasks[name]?.cancel() }
        catch { reportTaskFailures.insert(ownership.id); reportTasks[name]?.cancel() }
    }
    func executeSalesDownload(account: Account, appId: String, client: AppStoreConnectClient?, reporter: ReporterClient?, job: SalesDownloadJob,
                              ownership: ReportJobs.Ownership, now: Date, incremental: Bool, sharedBytes: SharedReportBytes) async throws -> SalesSyncResult {
        var current = job
        let name = try ReportJobs.name(.sales, accountId: account.id, appId: appId)
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self else { return }; await self.pollSalesCancellation(ownership, name: name)
            }
        }
        defer { monitor.cancel(); if reportTasks[name]?.id == job.id { reportTasks[name] = nil }; reportTaskFailures.remove(job.id); ownership.release() }
        func check() throws {
            try self.salesFileScope(account, appId: appId)
            try self.storeAccess { try ReportJobs.checkCancellation(SalesDownloadJob.self, ownership: ownership, store: $0) }
        }
        do {
            try check()
            let api: AppStoreConnectClient?
            if let client { api = client }
            else {
                do { api = try self.client(for: account) }
                catch { try check(); api = nil }
            }
            return try await downloadSalesBody(account: account, appId: appId, days: job.selection.days, client: api, reporter: reporter, source: job.selection.source, now: now, incremental: incremental, sharedBytes: sharedBytes,
                check: check, progress: { phase, checked, withApp, without, unavailable, noSales in
                    try check(); current.phase = phase; current.checked = checked; current.withApp = withApp; current.withoutApp = without; current.unavailable = unavailable; current.noSales = noSales
                    current.updatedAt = CustomerReview.isoString(Date())
                    try self.storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
                }, completion: { result, store in
                    try self.salesFileScope(account, appId: appId)
                    try check(); current.complete(result, at: CustomerReview.isoString(Date()))
                    return try ReportJobs.terminalWrites(current, ownership: ownership, current: { try store.document(namespace: $0, key: $1) })
                })
        } catch {
            if reportTaskFailures.contains(job.id) { current.fail(ReportJobFailure.status, at: CustomerReview.isoString(Date())) }
            else if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { current.state = .cancelled; current.result = nil; current.code = nil; current.updatedAt = CustomerReview.isoString(Date()) }
            else { current.fail(error, at: CustomerReview.isoString(Date())) }
            // A committed terminal receipt is immutable, including after a late cancellation or storage error.
            try? storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }; throw error
        }
    }
    func createSalesDownload(account: Account, appId: String, selection: SalesDownloadSelection, client: AppStoreConnectClient?, reporter: ReporterClient?, reuseRunning: Bool,
                             now: Date, incremental: Bool = false, sharedBytes: SharedReportBytes = .shared, binding: SyncChildBinding? = nil) async throws -> (SalesDownloadJob, Task<SalesSyncResult, Error>?) {
        try Task.checkCancellation(); try salesFileScope(account, appId: appId)
        _ = try SalesDownloadSelection(source: selection.source, endDate: selection.endDate, days: selection.total, latestCompletedDay: SalesReports.latestCompletedDay(now: now))
        let id = UUID().uuidString.lowercased(), clock = ContinuousClock(), deadline = clock.now + .milliseconds(500)
        var ownership: ReportJobs.Ownership?
        while ownership == nil {
            ownership = try ReportJobs.acquire(.sales, accountId: account.id, appId: appId, directory: try storeAccess { $0.directory }, id: id)
            if ownership == nil {
                if let current = try salesDownloadJob(account: account, appId: appId), current.isActive { if reuseRunning { return (current, nil) }; throw ReportJobFailure.busy }
                guard clock.now < deadline else { throw ReportJobFailure.busy }
                try await Task.sleep(for: .milliseconds(25)); try Task.checkCancellation()
            }
        }
        guard let ownership else { throw ReportJobFailure.busy }
        do {
            try salesFileScope(account, appId: appId); try Task.checkCancellation()
            _ = try storeAccess { try ReportJobs.recover(SalesDownloadJob.self, family: .sales, ownership: ownership, accountId: account.id, appId: appId, store: $0) }
            let job = SalesDownloadJob(id: id, selection: selection, now: Date()); try storeAccess { try ReportJobs.start(job, ownership: ownership, store: $0, binding: binding) }
            let task = try ownedReport { try await self.executeSalesDownload(account: account, appId: appId, client: client, reporter: reporter, job: job, ownership: ownership, now: now, incremental: incremental, sharedBytes: sharedBytes) }
            let name = try ReportJobs.name(.sales, accountId: account.id, appId: appId); reportTasks[name] = (id, { task.cancel() }); return (job, task)
        } catch { ownership.release(); throw error }
    }
    /// Starts or follows the shared Sales job; leaving a view does not cancel its owned download.
    public func startSalesDownload(account: Account, appId: String, selection: SalesDownloadSelection, client: AppStoreConnectClient? = nil,
                                  reporter: ReporterClient? = nil, now: Date = Date()) async throws -> SalesDownloadJob {
        try await createSalesDownload(account: account, appId: appId, selection: selection, client: client, reporter: reporter, reuseRunning: true, now: now).0
    }
    /// Foreground callers await the same durable job and can cancel only their owned task.
    public func downloadSales(account: Account, appId: String, days: [String], client: AppStoreConnectClient? = nil, reporter: ReporterClient? = nil,
                              source: ReportingSource? = nil, now: Date = Date()) async throws -> SalesSyncResult {
        try Task.checkCancellation(); try salesFileScope(account, appId: appId)
        let source = try source ?? (salesConnection(accountId: account.id)?.reporter == nil ? .api : .reporter)
        let selection = try SalesDownloadSelection(source: source, days: days, now: now)
        let (_, task) = try await createSalesDownload(account: account, appId: appId, selection: selection, client: client, reporter: reporter, reuseRunning: false, now: now)
        guard let task else { throw ReportJobFailure.busy }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
