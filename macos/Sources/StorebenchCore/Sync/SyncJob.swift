import Foundation

public enum SyncFailure: Error, Equatable {
    case status, busy, interrupted, request
    public var code: String { switch self { case .status: "SB-SYNC-STATUS"; case .busy: "SB-SYNC-BUSY"; case .interrupted: "SB-SYNC-INTERRUPTED"; case .request: "SB-REPORT-REQUEST" } }
    public var message: String { ReportingMessages.message(code) }
}

public struct SyncItem: Identifiable, Sendable, Equatable {
    public enum State: String, Sendable { case pending, unchecked, running, synced, partial, attention, waiting, ready, failed }
    public let key: String
    public var title: String { AppSync.sources.first { $0.0 == key }?.1 ?? "Source" }
    public var state: State, detail: String, checkedAt: String?, code: String?, reviewId: String?, revisionId: String?, unavailable: Int?
    var verifiedDetail: Bool
    public var id: String { key }
    public init(key: String, state: State, detail: String, checkedAt: String? = nil, code: String? = nil, reviewId: String? = nil, revisionId: String? = nil, unavailable: Int? = nil) {
        self.key = key; self.state = state; self.detail = detail; self.checkedAt = checkedAt; self.code = code; self.reviewId = reviewId; self.revisionId = revisionId; self.unavailable = unavailable; verifiedDetail = true
    }
    public var json: JSONText {
        var fields: [(String, JSONText)] = [("key", .string(key)), ("state", .string(state.rawValue)), ("detail", .string(detail))]
        if let code { fields.append(("code", .string(code))) }; if let checkedAt { fields.append(("checkedAt", .string(checkedAt))) }
        if let reviewId { fields.append(("reviewId", .string(reviewId))) }; if let revisionId { fields.append(("revisionId", .string(revisionId))) }
        if let unavailable { fields.append(("unavailable", .number(Double(unavailable)))) }; return .object(fields)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }
    public init(json: JSONText) throws {
        guard let key = json["key"]?.text, AppSync.sources.contains(where: { $0.0 == key }), let state = json["state"]?.text.flatMap(State.init(rawValue:)),
              let detail = json["detail"]?.text, detail.utf16.count <= 600,
              json["code"].map({ $0.text.map { ReportingMessages.values[$0] != nil } ?? false }) ?? true,
              json["checkedAt"].map({ $0.text.map(ReportTimestamps.shortValid) ?? false }) ?? true,
              ![.synced, .ready, .waiting].contains(state) || json["checkedAt"] != nil,
              json["reviewId"].map({ key == "finance" && $0.text.map(ReportJobs.uuid) == true }) ?? true,
              json["revisionId"].map({ key == "material" && $0.text.map(ReportJobs.uuid) == true }) ?? true else { throw SyncFailure.status }
        let unavailable: Int?
        if let value = json["unavailable"] {
            guard key == "finance", case .number(let number) = value, let count = Int(exactly: number), (0...FinancialReports.maximumPeriods).contains(count), count == 0 || state != .synced else { throw SyncFailure.status }
            unavailable = count
        } else { unavailable = nil }
        self.init(key: key, state: state, detail: detail, checkedAt: json["checkedAt"]?.text, code: json["code"]?.text, reviewId: json["reviewId"]?.text, revisionId: json["revisionId"]?.text, unavailable: unavailable)
        verifiedDetail = false
    }
    /// Historical free text never supplies diagnostics or navigation in the native view.
    public var displayDetail: String {
        if verifiedDetail { return detail }
        if let code { return ReportingMessages.message(code) }
        switch state {
        case .pending: return detail == AppSync.waitingForSlot ? detail : "Not checked in this sync yet."
        case .unchecked: return "No saved download result for this source yet."
        case .running: return [AppSync.waitingForSource, AppSync.waitingForSlot].contains(detail) ? detail : "Downloading this source. Saved data is kept."
        case .synced: return "Checked and saved locally."
        case .partial: return "Some requested data remains unavailable or incomplete. Missing activity is unknown."
        case .ready: return "Connection is ready. Open this source to download or review reports."
        case .waiting: return "Setup was checked. Wait for Apple to prepare the reports."
        case .attention: return reviewId != nil ? "Downloaded. Open Finance to review the fiscal dates and changes, then save the reports." : "This source needs attention. Open it to review its saved status."
        case .failed: return "This source could not be synced. Saved data is kept."
        }
    }
}

/// Presentation counts keep pending and unavailable sources distinct from successful downloads.
public struct SyncSourceSummary: Sendable, Equatable {
    public private(set) var total = 0, synced = 0, attention = 0, waiting = 0, notChecked = 0, ready = 0, running = 0
    init() {}
    public init(job: SyncJob?) {
        for item in job?.items ?? AppSync.pending() {
            total += 1
            if job?.statusOnly == true, [.synced, .partial].contains(item.state) { notChecked += 1; continue }
            switch item.state {
            case .synced: synced += 1
            case .partial, .attention, .failed: attention += 1
            case .waiting: waiting += 1
            case .pending, .unchecked: notChecked += 1
            case .ready: ready += 1
            case .running: running += 1
            }
        }
    }
    mutating func include(_ other: Self) {
        total += other.total; synced += other.synced; attention += other.attention; waiting += other.waiting
        notChecked += other.notChecked; ready += other.ready; running += other.running
    }
    public var checked: Int { synced + attention + waiting }
    public var details: String {
        var parts = ["\(attention) need attention"]
        if waiting > 0 { parts.append("\(waiting) waiting for reports") }
        if notChecked > 0 { parts.append("\(notChecked) not checked") }
        if ready > 0 { parts.append("\(ready) ready to sync") }
        if running > 0 { parts.append("\(running) syncing") }
        return parts.joined(separator: " · ")
    }
    public var text: String { "\(synced) of \(total) sources synced · " + details }
}

/// The seven-source aggregate receipt stored in encrypted jobs.
public struct SyncJob: Identifiable, Sendable, Equatable, PersistentReportJob {
    public let id, accountId, appId, startedAt: String
    public internal(set) var state: ReportJobState, updatedAt: String, items: [SyncItem], code: String?, statusOnly: Bool, setupCheckedAt: String?, projection: Bool
    public var isActive: Bool { state == .running }
    public var json: JSONText {
        var fields: [(String, JSONText)] = [("id", .string(id)), ("accountId", .string(accountId)), ("appId", .string(appId)), ("state", .string(state.rawValue)),
                                          ("startedAt", .string(startedAt)), ("updatedAt", .string(updatedAt)), ("items", .array(items.map(\.json)))]
        if let code { fields.append(("code", .string(code))) }; if statusOnly { fields.append(("statusOnly", .bool(true))) }
        if let setupCheckedAt { fields.append(("setupCheckedAt", .string(setupCheckedAt))) }; if projection { fields.append(("projection", .bool(true))) }; return .object(fields)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }
    public init(json: JSONText) throws {
        guard let id = json["id"]?.text, ReportJobs.uuid(id), let account = json["accountId"]?.text, account.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil,
              let app = json["appId"]?.text, app.range(of: #"\A[0-9]+\z"#, options: .regularExpression) != nil, let state = json["state"]?.text.flatMap(ReportJobState.init(rawValue:)),
              let start = json["startedAt"]?.text, ReportTimestamps.shortValid(start), let update = json["updatedAt"]?.text, ReportTimestamps.shortValid(update),
              case .array(let rows)? = json["items"], rows.count == AppSync.sources.count,
              json["code"].map({ $0.text.map { ReportingMessages.values[$0] != nil } ?? false }) ?? true,
              json["statusOnly"] == nil || json["statusOnly"] == .bool(true), json["projection"] == nil || json["projection"] == .bool(true),
              json["setupCheckedAt"].map({ $0.text.map(ReportTimestamps.shortValid) ?? false }) ?? true,
              json["statusOnly"] == nil || state == .complete else { throw SyncFailure.status }
        let projected = json["projection"] == .bool(true), only = json["statusOnly"] == .bool(true)
        self.id = id; accountId = account; appId = app; self.state = state; startedAt = start; updatedAt = update
        code = json["code"]?.text; statusOnly = only; setupCheckedAt = json["setupCheckedAt"]?.text; projection = projected
        items = try rows.enumerated().map { index, row in
            var item = try SyncItem(json: row)
            guard item.key == AppSync.sources[index].0, state != .complete || item.state != .running && (item.state != .pending || projected),
                  item.state != .unchecked || only || projected else { throw SyncFailure.status }
            if !projected && state != .running && [.pending, .running].contains(item.state) {
                item.state = .attention; item.detail = "Sync interrupted. Retry unfinished items; previously saved data is kept."
            }
            return item
        }
    }
    init(id: String, accountId: String, appId: String, items: [SyncItem], now: Date) {
        self.id = id; self.accountId = accountId; self.appId = appId; self.items = items; startedAt = CustomerReview.isoString(now); updatedAt = startedAt
        state = .running; code = nil; statusOnly = false; setupCheckedAt = nil; projection = false
    }
    func matches(_ family: ReportJobs.Family) -> Bool { family == .sync && (try? ReportJobs.identity(.sync, accountId: accountId, appId: appId)) != nil }
    func matches(_ family: ReportJobs.Family, key: String) -> Bool { matches(family) && key == "sync:\(accountId):\(appId)" }
    mutating func fail(_ error: Error, at: String) {
        state = error is CancellationError ? .cancelled : .failed; updatedAt = at; code = state == .cancelled ? nil : (error as? SyncFailure)?.code ?? "SB-SYNC-INTERRUPTED"
        for index in items.indices where [.pending, .running].contains(items[index].state) {
            items[index].state = .attention; items[index].detail = "Sync interrupted. Retry unfinished items; previously saved data is kept."
        }
    }
    public var counts: (total: Int, synced: Int, checked: Int, attention: Int) {
        (items.count, items.filter { $0.state == .synced }.count, items.filter { ![.pending, .unchecked, .running].contains($0.state) }.count,
         items.filter { [.partial, .attention, .failed].contains($0.state) }.count)
    }
    public var needsRetry: Bool { !isActive && !statusOnly && items.contains { [.failed, .attention].contains($0.state) && $0.code == "SB-SYNC-STATUS" } }
    public var canRetry: Bool { !isActive && counts.synced != counts.total }
    public enum Mode: String, Sendable, CaseIterable {
        case all, retry, refresh
        public var title: String {
            switch self { case .all: "Sync New Data"; case .retry: "Retry Unfinished"; case .refresh: "Download All Again" }
        }
        public var help: String {
            switch self {
            case .all: "Download missing or updated app data. Reuse recent successful checks and saved report files. Keeps local edits and does not publish changes."
            case .retry: "Retry sources that did not finish. Recent successful sources are kept; older results are checked again. Does not publish changes."
            case .refresh: "Check every source again and download report files again, including previously saved periods. Keeps local edits and does not publish changes."
            }
        }
    }
    public static func reuse(_ item: SyncItem, mode: Mode, now: Date) -> Bool {
        guard mode != .refresh, item.state == .synced, let checked = item.checkedAt.flatMap(ReportTimestamps.date) else { return false }
        let age = now.timeIntervalSince(checked); guard age >= 0, age < 300 else { return false }
        return mode == .retry ? PeriodDates.text(now) == String(item.checkedAt!.prefix(10)) : ["material", "reviews", "finance"].contains(item.key)
    }
}

/// Process-wide download slots; each queued job retains its own durable ownership.
actor SyncSlots {
    static let shared = SyncSlots()
    let limit: Int
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(limit: Int = 2) { self.limit = limit }
    func acquire() async throws {
        let id = UUID(); try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if active < limit { active += 1; continuation.resume() }
                else { waiting.append((id, continuation)) }
            }
        }, onCancel: { Task { await self.cancel(id) } })
        do { try Task.checkCancellation() } catch { release(); throw error }
    }
    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.0 == id }) { let entry = waiting.remove(at: index); entry.1.resume(throwing: CancellationError()) }
    }
    func release() { if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().1.resume() } }
    func status() -> (active: Int, queued: Int) { (active, waiting.count) }
}
