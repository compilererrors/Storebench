import Foundation

public enum ReportJobState: String, Sendable { case running, complete, failed, cancelled }
public enum ReportJobFailure: Error, Equatable {
    case status, busy, request
    public var code: String { switch self { case .status: "SB-REPORT-JOB"; case .busy: "SB-SYNC-BUSY"; case .request: "SB-REPORT-REQUEST" } }
    public var message: String { ReportingMessages.message(code) }
}

protocol PersistentReportJob: Sendable {
    var id: String { get }
    var isActive: Bool { get }
    var updatedAt: String { get set }
    var json: JSONText { get }
    init(json: JSONText) throws
    func matches(_ family: ReportJobs.Family) -> Bool
    func matches(_ family: ReportJobs.Family, key: String) -> Bool
    mutating func fail(_ error: Error, at: String)
}
extension PersistentReportJob {
    func matches(_ family: ReportJobs.Family, key: String) -> Bool { matches(family) }
}

/// Encrypted job records with exact cancellation IDs and permanent process mutexes.
enum ReportJobs {
    private static let accountPattern = try! NSRegularExpression(pattern: #"\A[A-Za-z0-9_-]{1,128}\z"#)
    private static let appPattern = try! NSRegularExpression(pattern: #"\A[0-9]{1,20}\z"#)
    private static let uuidPattern = try! NSRegularExpression(pattern: #"\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\z"#)
    enum Family: String, Sendable {
        case material = "import", analytics, downloads = "analytics_downloads", engagement = "analytics_engagement", sync, sales, financial, reviews
        var lockFamily: String { switch self { case .analytics, .downloads, .engagement: "analytics"; default: rawValue } }
    }
    static func identity(_ family: Family, accountId: String, appId: String) throws -> String {
        guard accountPattern.firstMatch(in: accountId, range: NSRange(accountId.startIndex..., in: accountId)) != nil,
              appPattern.firstMatch(in: appId, range: NSRange(appId.startIndex..., in: appId)) != nil else { throw ReportJobFailure.request }
        return "\(family.rawValue):\(accountId):\(appId)"
    }
    static func name(_ family: Family, accountId: String, appId: String) throws -> String {
        _ = try identity(family, accountId: accountId, appId: appId)
        let material = family == .material
        return (material ? "import_" : "report_") + JSONText.string(material ? "\(accountId)\u{0}\(appId)" : "\(family.lockFamily)\u{0}\(accountId)\u{0}\(appId)").rawSHA256.prefix(48)
    }
    static func uuid(_ value: String) -> Bool { uuidPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil }
    static func parsed<Job: PersistentReportJob>(_ type: Job.Type, _ document: EncryptedDocumentStore.Document?, family: Family) throws -> Job? {
        guard let document else { return nil }
        do {
            let job = try Job(json: JSONText.parse(document.payload))
            guard uuid(job.id), job.matches(family, key: document.key) else { throw ReportJobFailure.status }; return job
        } catch { throw ReportJobFailure.status }
    }

    final class Ownership: @unchecked Sendable {
        let family: Family, key: String, id: String, lock: URL
        private let mutex = NSLock(), cleanup: () -> Void
        private var released = false
        fileprivate init(family: Family, key: String, id: String, lock: URL, cleanup: @escaping () -> Void) {
            self.family = family; self.key = key; self.id = id; self.lock = lock; self.cleanup = cleanup
        }
        func verify() throws {
            try mutex.withLock {
                guard !released, let owner = try JobLock.owner(JobLock.privateFile(lock)), owner.id == id, owner.protocol == 2 else { throw ReportJobFailure.status }
            }
        }
        func release() { mutex.withLock { if !released { released = true; cleanup() } } }
        deinit { release() }
    }
    static func acquire(_ family: Family, accountId: String, appId: String, directory: URL, id: String) throws -> Ownership? {
        guard uuid(id) else { throw ReportJobFailure.request }
        let key = try identity(family, accountId: accountId, appId: appId), name = try name(family, accountId: accountId, appId: appId)
        guard let release = try JobLock.acquire(directory: directory, name: name, id: id) else { return nil }
        return Ownership(family: family, key: key, id: id, lock: directory.appendingPathComponent("\(name).lock"), cleanup: release)
    }

    static func read<Job: PersistentReportJob>(_ type: Job.Type, family: Family, accountId: String, appId: String, store: EncryptedDocumentStore, now: Date = Date(),
        owned: ((Job?, String, Date) throws -> Job)? = nil, interrupted: ((inout Job, EncryptedDocumentStore) throws -> Void)? = nil) throws -> Job? {
        let key = try identity(family, accountId: accountId, appId: appId)
        // A validated snapshot with no active work needs no ownership recovery.
        // Owner projections still inspect the mutex even before a receipt exists.
        if owned == nil {
            let saved = try parsed(type, store.document(namespace: "jobs", key: key), family: family)
            guard saved?.isActive == true else { return saved }
        }
        let name = try name(family, accountId: accountId, appId: appId)
        let lock = store.directory.appendingPathComponent("\(name).lock"), probe = try FileMutex.tryLock(store.directory.appendingPathComponent("\(name).lock.mutex"))
        defer { probe?.release() }
        let record = try parsed(type, store.document(namespace: "jobs", key: key), family: family)
        if let owned, let owner = try JobLock.owner(JobLock.privateFile(lock)),
           probe == nil && owner.protocol == 2 || owner.protocol != 2 && JobLock.alive(owner.pid) {
            let display = try Job(json: owned(record, owner.id, now).json)
            guard display.id == owner.id, display.matches(family) else { throw ReportJobFailure.status }; return display
        }
        guard let saved = record else { return nil }
        guard saved.isActive else { return saved }
        let owner = try JobLock.owner(JobLock.privateFile(lock))
        if probe == nil {
            return try activeObservation(saved, ownerId: owner?.id) {
                try parsed(type, store.document(namespace: "jobs", key: key), family: family)
            }
        }
        if let owner, owner.protocol != 2, JobLock.alive(owner.pid) { return saved }
        // Holding the OS mutex proves that a protocol-2 owner released it. Timestamps never prove death.
        var recovered = saved
        try store.transaction { current in
            guard let previous = try parsed(type, current("jobs", key), family: family), previous.id == saved.id else { throw ReportJobFailure.status }
            if !previous.isActive { recovered = previous; return [] }
            recovered = previous
            if let interrupted { try interrupted(&recovered, store) } else { recovered.fail(ReportJobFailure.status, at: CustomerReview.isoString(now)) }
            guard recovered.id == previous.id, !recovered.isActive, recovered.matches(family) else { throw ReportJobFailure.status }
            return [.put(namespace: "jobs", key: key, json: try Job(json: recovered.json).json.data)]
        }
        return recovered
    }
    /// The owner may finish between the busy-mutex probe, receipt read and owner-file read.
    /// Accept only that exact job's validated terminal receipt; never infer interruption or replace a newer job.
    static func activeObservation<Job: PersistentReportJob>(_ saved: Job, ownerId: String?, latest: () throws -> Job?) throws -> Job {
        if ownerId == saved.id { return saved }
        guard let current = try latest(), current.id == saved.id, !current.isActive else { throw ReportJobFailure.status }
        return current
    }

    static func start<Job: PersistentReportJob>(_ job: Job, ownership: Ownership, store: EncryptedDocumentStore,
        additionalWrites: [EncryptedDocumentStore.Write] = [], binding: SyncChildBinding? = nil) throws {
        try ownership.verify()
        guard job.id == ownership.id, job.isActive, job.matches(ownership.family, key: ownership.key) else { throw ReportJobFailure.status }
        let valid = try Job(json: job.json)
        try store.transaction { current in
            try ownership.verify()
            if let previous = try parsed(Job.self, current("jobs", ownership.key), family: ownership.family), previous.isActive { throw ReportJobFailure.status }
            var extra: [EncryptedDocumentStore.Write] = []
            if let binding {
                guard ownership.family == binding.family, ownership.key == (try identity(binding.family, accountId: binding.accountId, appId: binding.appId)) else { throw ReportJobFailure.status }
                extra = try binding.writes(childId: job.id, current: current)
            }
            return [.put(namespace: "jobs", key: ownership.key, json: valid.json.data), .delete(namespace: "job_cancels", key: ownership.key)] + extra + additionalWrites
        }
    }
    @discardableResult static func recover<Job: PersistentReportJob>(_ type: Job.Type, family: Family, ownership: Ownership, accountId: String, appId: String, store: EncryptedDocumentStore, now: Date = Date(),
        interrupted: ((inout Job, EncryptedDocumentStore) throws -> Void)? = nil) throws -> Job? {
        try ownership.verify()
        guard family.lockFamily == ownership.family.lockFamily else { throw ReportJobFailure.status }
        guard try name(family, accountId: accountId, appId: appId) + ".lock" == ownership.lock.lastPathComponent else { throw ReportJobFailure.status }
        let key = try identity(family, accountId: accountId, appId: appId)
        var recovered: Job?
        try store.transaction { current in
            try ownership.verify()
            guard var previous = try parsed(type, current("jobs", key), family: family), previous.isActive else { return [] }
            guard previous.id != ownership.id else { throw ReportJobFailure.status }
            let originalId = previous.id
            if let interrupted { try interrupted(&previous, store) } else { previous.fail(ReportJobFailure.status, at: CustomerReview.isoString(now)) }
            guard previous.id == originalId, !previous.isActive, previous.matches(family) else { throw ReportJobFailure.status }
            recovered = previous
            return [.put(namespace: "jobs", key: key, json: try Job(json: previous.json).json.data)]
        }
        return recovered
    }
    static func update<Job: PersistentReportJob>(_ job: Job, ownership: Ownership, store: EncryptedDocumentStore) throws {
        try ownership.verify()
        guard job.id == ownership.id, job.matches(ownership.family) else { throw ReportJobFailure.status }
        let valid = try Job(json: job.json)
        try store.transaction { current in
            try ownership.verify()
            guard let previous = try parsed(Job.self, current("jobs", ownership.key), family: ownership.family), previous.id == job.id else { throw ReportJobFailure.status }
            if !previous.isActive {
                guard previous.json == valid.json else { throw ReportJobFailure.status }; return []
            }
            return [.put(namespace: "jobs", key: ownership.key, json: valid.json.data)]
        }
    }
    /// Appends a terminal receipt to the caller's existing SQL transaction alongside its report writes.
    static func terminalWrites<Job: PersistentReportJob>(_ job: Job, ownership: Ownership, current: (String, String) throws -> EncryptedDocumentStore.Document?) throws -> [EncryptedDocumentStore.Write] {
        try ownership.verify()
        guard !job.isActive, job.id == ownership.id, job.matches(ownership.family) else { throw ReportJobFailure.status }
        let valid = try Job(json: job.json)
        guard let previous = try parsed(Job.self, current("jobs", ownership.key), family: ownership.family), previous.id == job.id else { throw ReportJobFailure.status }
        if !previous.isActive { guard previous.json == valid.json else { throw ReportJobFailure.status }; return [] }
        return [.put(namespace: "jobs", key: ownership.key, json: valid.json.data)]
    }
    static func checkCancellation<Job: PersistentReportJob>(_ type: Job.Type, ownership: Ownership, store: EncryptedDocumentStore) throws {
        try Task.checkCancellation(); try ownership.verify()
        guard let job = try parsed(type, store.document(namespace: "jobs", key: ownership.key), family: ownership.family), job.id == ownership.id, job.isActive else { throw ReportJobFailure.status }
        if let document = try store.document(namespace: "job_cancels", key: ownership.key) {
            guard let id = try JSONText.parse(document.payload)["id"]?.text, uuid(id) else { throw ReportJobFailure.status }
            if id == ownership.id { throw CancellationError() }
        }
    }
    static func cancel<Job: PersistentReportJob>(_ type: Job.Type, family: Family, accountId: String, appId: String, id: String, store: EncryptedDocumentStore) throws -> Bool {
        guard uuid(id) else { throw ReportJobFailure.request }
        let key = try identity(family, accountId: accountId, appId: appId), name = try name(family, accountId: accountId, appId: appId)
        var requested = false
        try store.transaction { current in
            guard let job = try parsed(type, current("jobs", key), family: family), job.id == id, job.isActive else { return [] }
            guard let owner = try JobLock.owner(JobLock.privateFile(store.directory.appendingPathComponent("\(name).lock"))), owner.id == id else { throw ReportJobFailure.status }
            requested = true
            return [.put(namespace: "job_cancels", key: key, json: JSONText.object([("id", .string(id))]).data)]
        }
        return requested
    }
}

/// Jobs are saved, and read back with all their checks, as the same JSON the job store keeps.
extension ImportJob: Codable {
    public init(from decoder: Decoder) throws { try self.init(json: JSONText.parse(Data(try decoder.singleValueContainer().decode(String.self).utf8))) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(json.stringify()) }
}
extension SyncJob: Codable {
    public init(from decoder: Decoder) throws { try self.init(json: JSONText.parse(Data(try decoder.singleValueContainer().decode(String.self).utf8))) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(json.stringify()) }
}
/// A plan is saved as its stored JSON, its token, and checked again when read back.
extension ReleasePlan: Codable {
    public init(from decoder: Decoder) throws {
        let token = try decoder.singleValueContainer().decode(String.self)
        guard let plan = ReleasePlan(try JSONText.parse(Data(token.utf8))) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid release plan.")) }
        self = plan
    }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(token) }
}
