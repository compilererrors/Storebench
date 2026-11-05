import Foundation
import Observation

public struct ReleasePlanInputs: Sendable, Equatable {
    public var start: ReleaseStart
    public var sourceRevisionId: String?
    public var baseVersionId: String?
    public var targetVersion: String
    public var releaseType: String
    public var date: Date

    public init(start: ReleaseStart = .copy, sourceRevisionId: String? = nil, baseVersionId: String? = nil,
                targetVersion: String = "", releaseType: String = "MANUAL", date: Date) {
        self.start = start; self.sourceRevisionId = sourceRevisionId; self.baseVersionId = baseVersionId
        self.targetVersion = targetVersion; self.releaseType = releaseType; self.date = date
    }
    public init(_ plan: ReleasePlan, fallbackDate: Date) {
        self.init(start: .reuse, sourceRevisionId: plan.sourceRevisionId, baseVersionId: plan.baseVersionId,
                  targetVersion: plan.targetVersion, releaseType: plan.releaseType ?? "MANUAL",
                  date: plan.earliestReleaseDate.flatMap(Releases.parsedDate) ?? fallbackDate)
    }
    public var signature: String {
        let mode: JSONText
        switch start {
        case .reuse: mode = .string("reuse")
        case .copy: mode = .string("copy")
        case .empty(let platform, let locale): mode = .array([.string("empty"), .string(platform), .string(locale)])
        }
        let seconds = date.timeIntervalSince1970
        return JSONText.array([mode, sourceRevisionId.map(JSONText.string) ?? .null, baseVersionId.map(JSONText.string) ?? .null,
                              .string(targetVersion), .string(releaseType), seconds.isFinite ? .number(seconds) : .string("invalid-date")]).stringify()
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.signature.utf8.elementsEqual(rhs.signature.utf8) }

    /// Preserve fields changed by this editor; accept the saved plan's immutable source.
    func keepingEdits(from previous: Self, on saved: Self, hasPlan: Bool) -> Self {
        var next = saved
        if !hasPlan {
            if start != previous.start { next.start = start }
            if sourceRevisionId != previous.sourceRevisionId { next.sourceRevisionId = sourceRevisionId }
            if baseVersionId != previous.baseVersionId { next.baseVersionId = baseVersionId }
        }
        if !targetVersion.utf8.elementsEqual(previous.targetVersion.utf8) { next.targetVersion = targetVersion }
        if !releaseType.utf8.elementsEqual(previous.releaseType.utf8) { next.releaseType = releaseType }
        if date != previous.date { next.date = date }
        return next
    }
}

/// Owns a confirmed plan token independently of parent view refreshes.
@MainActor @Observable public final class ReleasePlanEditor {
    public let accountId: String, appId: String
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    public private(set) var plan: ReleasePlan?
    public private(set) var loaded = false { didSet { notifyChange() } }
    public private(set) var baseline: ReleasePlanInputs
    public var inputs: ReleasePlanInputs { didSet { latestRead = false; latest = nil; notifyChange() } }
    public private(set) var latest: ReleasePlan?
    public private(set) var latestRead = false
    public private(set) var needsComparison = false { didSet { notifyChange() } }
    public private(set) var status = ""
    public private(set) var busy = false { didSet { notifyChange() } }
    public private(set) var active = true
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var initial: ReleasePlanInputs
    @ObservationIgnored private let read: @MainActor () async throws -> ReleasePlan?
    @ObservationIgnored private let write: @MainActor (ReleasePlanInputs, String) async throws -> ReleasePlan
    @ObservationIgnored private let delete: @MainActor (String) async throws -> Void
    public var dirty: Bool { inputs != baseline }
    public var ready: Bool { active && loaded && !busy && !needsComparison }
    public var expected: String? { loaded ? plan?.token ?? "null" : nil }
    public var latestInputs: ReleasePlanInputs? {
        latestRead ? latest.map { .init($0, fallbackDate: initial.date) } ?? initial : nil
    }

    public init(accountId: String, appId: String, initial: ReleasePlanInputs,
                read: @escaping @MainActor () async throws -> ReleasePlan?,
                save: @escaping @MainActor (ReleasePlanInputs, String) async throws -> ReleasePlan,
                remove: @escaping @MainActor (String) async throws -> Void) {
        self.accountId = accountId; self.appId = appId; self.initial = initial; inputs = initial; baseline = initial
        self.read = read; write = save; delete = remove
    }
    public convenience init(account: Account, appId: String, initial: ReleasePlanInputs, session: WorkspaceSession) {
        self.init(accountId: account.id, appId: appId, initial: initial,
                  read: { try await session.releasePlan(accountId: account.id, appId: appId) },
                  save: { input, expected in
            let saved = try await session.saveReleasePlan(account: account, appId: appId, start: input.start,
                sourceRevisionId: input.sourceRevisionId, baseVersionId: input.baseVersionId, targetVersion: input.targetVersion,
                releaseType: input.releaseType, earliestReleaseDate: input.releaseType == "SCHEDULED" ? input.date : nil, expected: expected)
            // The app's next version starts with the option saved here. The plan is saved even if this preference cannot be.
            try? await session.saveReleasePreference(accountId: account.id, appId: appId, releaseType: saved.releaseType ?? "MANUAL")
            return saved
        }, remove: { try await session.removeReleasePlan(accountId: account.id, appId: appId, expected: $0) })
    }
    public func retire() { active = false; operation = nil; busy = false; notifyChange() }
    @discardableResult public func observe(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); observers[id] = observer; return id
    }
    public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func notifyChange() { didChange(); for observer in Array(observers.values) { observer() } }
    public func problem(now: Date = Date()) -> String? {
        do {
            try Releases.validateVersion(inputs.targetVersion.trimmingCharacters(in: .whitespacesAndNewlines))
            _ = try Releases.settings(type: inputs.releaseType, date: inputs.releaseType == "SCHEDULED" ? inputs.date : nil, now: now)
            if case .empty(let platform, let locale) = inputs.start {
                guard Releases.platforms.contains(where: { $0.0 == platform }), StoreLocales.codes.contains(locale) else { throw ReleaseFailure.sourceUnavailable }
            } else if inputs.sourceRevisionId?.isEmpty != false || inputs.baseVersionId?.isEmpty != false { throw ReleaseFailure.sourceUnavailable }
            return nil
        } catch { return Self.message(error) }
    }
    public func load() async {
        guard active, !loaded, !busy, !Task.isCancelled else { return }
        let ticket = begin(); defer { finish(ticket) }
        do {
            let saved = try await read(); try Task.checkCancellation(); try validateScope(saved)
            guard owns(ticket) else { return }
            let next = saved.map { ReleasePlanInputs($0, fallbackDate: initial.date) } ?? initial
            let edited = inputs.keepingEdits(from: baseline, on: next, hasPlan: saved != nil)
            plan = saved; baseline = next; inputs = edited; loaded = true; needsComparison = false; status = ""
        } catch { if owns(ticket) { status = "The saved version plan could not be read. Compare the latest save before continuing." } }
    }
    @discardableResult public func save(now: Date = Date()) async -> Bool {
        guard ready, !Task.isCancelled, let expected else { return false }
        if plan != nil && !dirty { return true }
        if let problem = problem(now: now) { status = problem; return false }
        let snapshot = inputs, ticket = begin(); var receiptReturned = false; defer { finish(ticket) }
        do {
            let saved = try await write(snapshot, expected); receiptReturned = true; try validateScope(saved)
            guard matches(saved, snapshot: snapshot) else { throw ReleaseFailure.invalid("The save receipt does not match this version plan. Compare the latest save before continuing.") }
            // A completed physical write is acknowledged even after its view has retired.
            guard owns(ticket) else { return true }
            let confirmed = ReleasePlanInputs(saved, fallbackDate: snapshot.date)
            let edited = inputs.keepingEdits(from: snapshot, on: confirmed, hasPlan: true)
            plan = saved; baseline = confirmed; inputs = edited
            status = dirty ? "Earlier version settings saved. Newer edits are waiting to save." : "Version saved on this Mac."
            return true
        } catch {
            guard owns(ticket) else { return false }
            if receiptReturned { needsComparison = true }
            if case ReleaseFailure.conflict = error { needsComparison = true }
            status = Self.message(error); return false
        }
    }
    @discardableResult public func remove() async -> Bool {
        guard ready, let plan, !Task.isCancelled else { return false }
        let snapshot = inputs, ticket = begin(); defer { finish(ticket) }
        do {
            try await delete(plan.token)
            guard owns(ticket) else { return true }
            self.plan = nil; baseline = initial; inputs = inputs.keepingEdits(from: snapshot, on: initial, hasPlan: false)
            status = "The version plan was removed. Its local draft stays saved."; return true
        } catch {
            guard owns(ticket) else { return false }
            if case ReleaseFailure.conflict = error { needsComparison = true }
            status = Self.message(error); return false
        }
    }
    /// A newer starting suggestion, such as from an import that finished after the editor opened, while no plan is saved and nothing was edited.
    /// Returns true when it replaced the inputs.
    @discardableResult public func suggest(_ next: ReleasePlanInputs) -> Bool {
        guard active, loaded, !busy, plan == nil, !dirty, !needsComparison else { return false }
        guard next != inputs else { return false }
        initial = next; baseline = next; inputs = next; return true
    }
    public func revert() {
        guard active, !busy, loaded else { return }
        inputs = baseline; status = "Inputs restored to this editor's confirmed save."
    }
    public func readLatest() async {
        guard active, !busy, !Task.isCancelled else { return }
        let ticket = begin(); latestRead = false; latest = nil; defer { finish(ticket) }
        do {
            let saved = try await read(); try Task.checkCancellation(); try validateScope(saved)
            guard owns(ticket) else { return }
            latest = saved; latestRead = true; status = "Latest plan read. Choose a baseline explicitly; nothing was saved."
        } catch { if owns(ticket) { status = "The latest version plan could not be read. Your inputs are kept." } }
    }
    public func acceptLatest(keepEdits: Bool) {
        guard active, !busy, let next = latestInputs else { return }
        let saved = latest, edited = keepEdits ? inputs.keepingEdits(from: baseline, on: next, hasPlan: saved != nil) : next
        plan = saved; baseline = next; inputs = edited; loaded = true; needsComparison = false
        status = keepEdits ? "Latest plan compared. Choose Save Version Plan to save your edits." : "Saved values loaded. Nothing was saved by the comparison."
    }
    private func begin() -> UUID { let ticket = UUID(); operation = ticket; busy = true; return ticket }
    private func owns(_ ticket: UUID) -> Bool { active && operation == ticket }
    private func finish(_ ticket: UUID) { if owns(ticket) { operation = nil; busy = false } }
    private func validateScope(_ plan: ReleasePlan?) throws {
        guard let plan else { return }
        guard accountId.utf8.elementsEqual(plan.accountId.utf8), appId.utf8.elementsEqual(plan.appId.utf8) else { throw ReleaseFailure.sourceUnavailable }
    }
    private func matches(_ saved: ReleasePlan, snapshot: ReleasePlanInputs) -> Bool {
        guard saved.targetVersion.utf8.elementsEqual(snapshot.targetVersion.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
              (saved.releaseType ?? "MANUAL").utf8.elementsEqual(snapshot.releaseType.utf8) else { return false }
        if snapshot.releaseType == "SCHEDULED" {
            let whole = Date(timeIntervalSince1970: (snapshot.date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
            guard saved.earliestReleaseDate.flatMap(Releases.parsedDate) == whole else { return false }
        } else if saved.earliestReleaseDate != nil { return false }
        switch snapshot.start {
        case .reuse: return saved.sourceRevisionId == snapshot.sourceRevisionId && saved.baseVersionId == snapshot.baseVersionId
        case .empty(let platform, _): return saved.platform == platform
        case .copy: return !saved.sourceRevisionId.isEmpty && !saved.baseVersionId.isEmpty
        }
    }
    private static func message(_ error: any Error) -> String {
        if let error = error as? ReleaseFailure { return error.message }
        if let error = error as? DraftFailure { return error.message }
        if let error = error as? ScreenshotFailure { return error.message }
        return "The version plan could not be saved. Your inputs are kept."
    }
}
