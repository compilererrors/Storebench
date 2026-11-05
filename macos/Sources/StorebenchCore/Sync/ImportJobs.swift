import Foundation

/// The shared import receipt. Legacy diagnostics remain wire-compatible but never supply display text.
public struct ImportJob: Identifiable, Equatable, Sendable, PersistentReportJob {
    public enum State: String, Sendable { case running, cancelling, complete, failed, cancelled }
    public let id: String, startedAt: String
    public internal(set) var state: State, phase: String, completed: Int, updatedAt: String, revisionId: String?, code: String?
    private var legacyError: String?
    public var isActive: Bool { state == .running || state == .cancelling }
    public var displayPhase: String {
        ["Starting", "Reading app information", "Reading versions", "Downloading screenshots", "Saving revision", "Revision saved", "No changes since the last import", "Cancelling", "Cancelled", "Failed", "Interrupted"].contains(phase) ? phase : "App material import"
    }
    public var error: String? { code.map(ReportingMessages.message) ?? (state == .failed || legacyError != nil ? ImportFailure.status.message : nil) }
    public var json: JSONText {
        var fields: [(String, JSONText)] = [("id", .string(id)), ("state", .string(state.rawValue)), ("phase", .string(phase)), ("completed", .number(Double(completed))),
            ("startedAt", .string(startedAt)), ("updatedAt", .string(updatedAt))]
        if let revisionId { fields.append(("revisionId", .string(revisionId))) }
        if let code { fields += [("code", .string(code)), ("error", .string(ReportingMessages.message(code)))] }
        else if let legacyError, !legacyError.isEmpty { fields.append(("error", .string(legacyError))) }
        return .object(fields)
    }
    init(id: String, now: Date) {
        self.id = id; startedAt = CustomerReview.isoString(now); updatedAt = startedAt; state = .running; phase = "Starting"; completed = 0; revisionId = id; code = nil; legacyError = nil
    }
    public init(json: JSONText) throws {
        guard let id = json["id"]?.text, ReportJobs.uuid(id), let state = json["state"]?.text.flatMap(State.init(rawValue:)),
              let phase = json["phase"]?.text, phase.utf16.count <= 100, case .number(let number)? = json["completed"], let completed = Int(exactly: number),
              (0...9_007_199_254_740_991).contains(completed), let start = json["startedAt"]?.text, start.utf16.count <= 40, ReportTimestamps.valid(start),
              let update = json["updatedAt"]?.text, update.utf16.count <= 40, ReportTimestamps.valid(update) else { throw ImportFailure.status }
        if let revision = json["revisionId"] { guard let text = revision.text, ReportJobs.uuid(text) else { throw ImportFailure.status } }
        if let code = json["code"] { guard let text = code.text, ImportFailure.allCases.contains(where: { $0.code == text }) else { throw ImportFailure.status } }
        if let error = json["error"] { guard let text = error.text, text.utf16.count <= 600 else { throw ImportFailure.status } }
        self.id = id; self.state = state; self.phase = phase; self.completed = completed; startedAt = start; updatedAt = update
        revisionId = json["revisionId"]?.text; code = json["code"]?.text; legacyError = code == nil ? json["error"]?.text : nil
    }
    func matches(_ family: ReportJobs.Family) -> Bool { family == .material }
    mutating func fail(_ error: Error, at: String) {
        let failure = ImportFailure(error); state = .failed; phase = failure == .interrupted ? "Interrupted" : "Failed"; updatedAt = at; code = failure.code; legacyError = nil
    }
    mutating func complete(revision: String, phase: String, at: String) {
        state = .complete; self.phase = phase; updatedAt = at; revisionId = revision; code = nil; legacyError = nil
    }
    mutating func cancelled(at: String) { state = .cancelled; phase = "Cancelled"; updatedAt = at; code = nil; legacyError = nil }
}

extension WorkspaceSession {
    func importScope(_ account: Account, appId: String, client: AppStoreConnectClient? = nil) throws {
        do { _ = try ReportJobs.identity(.material, accountId: account.id, appId: appId) } catch { throw ImportFailure.request }
        guard try currentAccount(account, client: client).appIds.contains(appId) else { throw ImportFailure.request }
    }
    /// Reads the exact assigned revision, never a newer pointer or an unrelated local draft.
    func committedImport(accountId: String, appId: String, revisionId: String, store: EncryptedDocumentStore) throws -> Revision? {
        guard ReportJobs.uuid(revisionId) else { throw ImportFailure.status }
        guard let record = try store.document(namespace: "revisions", key: "\(accountId):\(appId):\(revisionId)") else { return nil }
        do {
            let value = try JSONText.parse(record.payload), revision = try JSONDecoder().decode(Revision.self, from: record.payload)
            guard revision.schemaVersion == 1, revision.id == revisionId, revision.app.id == appId, value["account"]?["id"]?.text == accountId,
                  ReportTimestamps.valid(revision.importedAt) else { throw ImportFailure.status }
            for version in revision.versions { for locale in version.localizations { for set in locale.screenshotSets { for image in set.screenshots {
                guard image.sha256.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
                      image.contentType == "image/png" || image.contentType == "image/jpeg" else { throw ImportFailure.status }
            } } } }
            return revision.isLocalDraft ? nil : revision
        } catch { throw ImportFailure.status }
    }
    func recoverImport(_ job: inout ImportJob, account: Account, appId: String, store: EncryptedDocumentStore, now: Date) throws {
        try importScope(account, appId: appId)
        if let revisionId = job.revisionId, try committedImport(accountId: account.id, appId: appId, revisionId: revisionId, store: store) != nil {
            job.complete(revision: revisionId, phase: "Revision saved", at: CustomerReview.isoString(now))
        } else { job.fail(ImportFailure.interrupted, at: CustomerReview.isoString(now)) }
    }
    public func importJob(account: Account, appId: String, now: Date = Date()) throws -> ImportJob? {
        try importScope(account, appId: appId)
        do {
            return try storeAccess { store in try ReportJobs.read(ImportJob.self, family: .material, accountId: account.id, appId: appId, store: store, now: now,
                owned: { previous, id, now in
                    guard var job = previous, job.id == id else { return ImportJob(id: id, now: now) }
                    var cancelled = job.state == .cancelled
                    if job.isActive, let document = try store.document(namespace: "job_cancels", key: ReportJobs.identity(.material, accountId: account.id, appId: appId)) {
                        guard let requested = try JSONText.parse(document.payload)["id"]?.text, ReportJobs.uuid(requested) else { throw ImportFailure.status }
                        cancelled = requested == id
                    }
                    if cancelled { job.state = .cancelling; job.phase = "Cancelling" }; return job
                }, interrupted: { job, store in try self.recoverImport(&job, account: account, appId: appId, store: store, now: now) }) }
        } catch { throw ImportFailure(error) }
    }
    public func cancelImport(account: Account, appId: String, id: String) throws -> ImportJob? {
        guard ReportJobs.uuid(id) else { throw ImportFailure.request }
        guard let current = try importJob(account: account, appId: appId), current.id == id, current.isActive else { return try importJob(account: account, appId: appId) }
        do {
            let requested = try storeAccess { try ReportJobs.cancel(ImportJob.self, family: .material, accountId: account.id, appId: appId, id: id, store: $0) }
            let name = try ReportJobs.name(.material, accountId: account.id, appId: appId)
            if requested, reportTasks[name]?.id == id { reportTasks[name]?.cancel() }
            return try importJob(account: account, appId: appId)
        } catch { throw ImportFailure(error) }
    }
    func pollImportCancellation(_ ownership: ReportJobs.Ownership, name: String) {
        guard reportTasks[name]?.id == ownership.id else { return }
        do { try storeAccess { try ReportJobs.checkCancellation(ImportJob.self, ownership: ownership, store: $0) } }
        catch is CancellationError { reportTasks[name]?.cancel() }
        catch { reportTaskFailures.insert(ownership.id); reportTasks[name]?.cancel() }
    }
    func executeImport(account: Account, appId: String, client: AppStoreConnectClient, job: ImportJob, ownership: ReportJobs.Ownership, now: @escaping @Sendable () -> Date) async throws -> ImportResult {
        var current = job
        let name = try ReportJobs.name(.material, accountId: account.id, appId: appId)
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self else { return }; await self.pollImportCancellation(ownership, name: name)
            }
        }
        defer { monitor.cancel(); if reportTasks[name]?.id == job.id { reportTasks[name] = nil }; reportTaskFailures.remove(job.id); ownership.release() }
        func check() throws {
            try self.importScope(account, appId: appId, client: client)
            try self.storeAccess { try ReportJobs.checkCancellation(ImportJob.self, ownership: ownership, store: $0) }
        }
        do {
            try check()
            let result = try await importRevision(account: account, appId: appId, revisionId: job.id, client: client, now: now, check: check,
                progress: { phase, completed in
                    try check(); current.phase = phase; current.completed = completed; current.updatedAt = CustomerReview.isoString(now())
                    try self.storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }
                })
            // Once the revision is committed, a late stop cannot turn its receipt into a failed import.
            try importScope(account, appId: appId, client: client)
            current.completed = result.screenshots
            current.complete(revision: result.revisionId, phase: result.changed ? "Revision saved" : "No changes since the last import", at: CustomerReview.isoString(now()))
            try storeAccess { try ReportJobs.update(current, ownership: ownership, store: $0) }; return result
        } catch {
            if reportTaskFailures.contains(job.id) { current.fail(ImportFailure.status, at: CustomerReview.isoString(now())) }
            else if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { current.cancelled(at: CustomerReview.isoString(now())) }
            else { current.fail(error, at: CustomerReview.isoString(now())) }
            // A storage failure after committing is resolved by exact-revision recovery on the next read.
            try? storeAccess { store in
                if let revisionId = current.revisionId, try committedImport(accountId: account.id, appId: appId, revisionId: revisionId, store: store) != nil {
                    current.complete(revision: revisionId, phase: "Revision saved", at: CustomerReview.isoString(now()))
                }
                try ReportJobs.update(current, ownership: ownership, store: store)
            }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            throw ImportFailure(error)
        }
    }
    func createImport(account: Account, appId: String, client: AppStoreConnectClient?, reuseRunning: Bool, now: @escaping @Sendable () -> Date,
        binding: SyncChildBinding? = nil) async throws -> (ImportJob, Task<ImportResult, Error>?) {
        try Task.checkCancellation(); try importScope(account, appId: appId, client: client)
        let id = UUID().uuidString.lowercased(), clock = ContinuousClock(), deadline = clock.now + .milliseconds(500)
        var ownership: ReportJobs.Ownership?
        while ownership == nil {
            do { ownership = try ReportJobs.acquire(.material, accountId: account.id, appId: appId, directory: try storeAccess { $0.directory }, id: id) }
            catch { throw ImportFailure(error) }
            if ownership == nil {
                if let current = try importJob(account: account, appId: appId), current.isActive { if reuseRunning { return (current, nil) }; throw ImportFailure.busy }
                guard clock.now < deadline else { throw ImportFailure.busy }
                try await Task.sleep(for: .milliseconds(25)); try Task.checkCancellation()
            }
        }
        guard let ownership else { throw ImportFailure.busy }
        do {
            try importScope(account, appId: appId, client: client); try Task.checkCancellation()
            let recovered = try storeAccess { store in try ReportJobs.recover(ImportJob.self, family: .material, ownership: ownership, accountId: account.id, appId: appId, store: store,
                interrupted: { job, store in try self.recoverImport(&job, account: account, appId: appId, store: store, now: now()) }) }
            if let recovered, recovered.state == .complete { ownership.release(); return (recovered, nil) }
            let client = try client ?? self.client(for: account)
            let job = ImportJob(id: id, now: now()); try storeAccess { try ReportJobs.start(job, ownership: ownership, store: $0, binding: binding) }
            let task = try ownedReport { try await self.executeImport(account: account, appId: appId, client: client, job: job, ownership: ownership, now: now) }
            let name = try ReportJobs.name(.material, accountId: account.id, appId: appId); reportTasks[name] = (id, { task.cancel() }); return (job, task)
        } catch { ownership.release(); if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }; throw ImportFailure(error) }
    }
    public func startImport(account: Account, appId: String, client: AppStoreConnectClient? = nil, now: @escaping @Sendable () -> Date = Date.init) async throws -> ImportJob {
        try Task.checkCancellation(); try importScope(account, appId: appId)
        return try await createImport(account: account, appId: appId, client: client, reuseRunning: true, now: now).0
    }
    /// Waits for the same durable job that Overview follows.
    public func importApp(account: Account, appId: String, client: AppStoreConnectClient, now: @escaping @Sendable () -> Date = Date.init) async throws -> ImportResult {
        let (job, task) = try await createImport(account: account, appId: appId, client: client, reuseRunning: false, now: now)
        if let task { return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() }) }
        guard job.state == .complete, let id = job.revisionId,
              let revision = try storeAccess({ try committedImport(accountId: account.id, appId: appId, revisionId: id, store: $0) }) else { throw ImportFailure.status }
        let images = revision.versions.flatMap(\.localizations).flatMap(\.screenshotSets).flatMap(\.screenshots).count
        return ImportResult(revisionId: id, changed: true, screenshots: images)
    }
}
