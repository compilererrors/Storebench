import Foundation
import Observation

/// Owns one status read without adopting a plan baseline or changing any listing editor.
/// The last confirmed snapshot stays visible while a newer read runs, and one remembered from an earlier visit is shown until the first read confirms it.
@MainActor @Observable public final class ReleaseReadinessEditor {
    public let planEditor: ReleasePlanEditor
    public private(set) var snapshot: ReleaseReadinessSnapshot?
    public private(set) var busy = false
    public private(set) var active = true
    public private(set) var readFailed = false
    public private(set) var status = ""
    /// When this snapshot was last confirmed against App Store Connect.
    public private(set) var checkedAt: Date?
    /// The snapshot was confirmed by a read in this editor, not only remembered from an earlier visit.
    public private(set) var confirmed = false
    /// Consecutive failed checks, which lengthen the wait before the next automatic one.
    public private(set) var failures = 0
    /// The parts read since the last check started; the rest of the snapshot is carried from earlier reads or Unknown.
    public private(set) var checkedParts: ReleaseReadiness.Parts = []
    /// The parts the open step does not show are being read in the background.
    public private(set) var filling = false
    /// The parts the open step shows. A check reads these first and the rest in the background.
    @ObservationIgnored public var focus: ReleaseReadiness.Parts = .all
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    @ObservationIgnored private let read: @MainActor (ReleasePlan, ReleaseReadiness.Parts) async throws -> ReleaseReadinessSnapshot
    @ObservationIgnored private let probe: (@MainActor (ReleasePlan) async throws -> String?)?
    @ObservationIgnored private let remember: @MainActor (ReleaseReadinessSnapshot, Date) -> Void
    @ObservationIgnored private let materialSignature: (@MainActor (ReleasePlan) async throws -> String)?
    @ObservationIgnored private var writtenAt: ContinuousClock.Instant?
    /// The known step states when the change was approved; once Apple shows a different status the change has arrived.
    @ObservationIgnored private var writtenStatus: [String]?
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var observedPlan = ""
    @ObservationIgnored private var fill: Task<Void, Never>?
    @ObservationIgnored private var fillTicket: UUID?
    @ObservationIgnored private var fillStarted: ReleaseReadiness.Parts = []
    @ObservationIgnored private var fillWorkers = 0
    @ObservationIgnored private var fillComplete = true
    /// Background part reads at once.
    static let fillWidth = 2
    public var ready: Bool { active && !busy && !readFailed && confirmed && planEditor.ready && !planEditor.dirty && planEditor.plan != nil }
    /// Time since an Apple change approved in this release flow, while Apple may still be applying it.
    /// Nil again as soon as a read shows a status other than the one at approval.
    public var sinceWrite: Duration? {
        guard let writtenAt, knownStatus == writtenStatus else { return nil }
        return ContinuousClock.now - writtenAt
    }
    private var knownStatus: [String] {
        [snapshot?.targetState ?? ""] + (snapshot?.steps ?? []).filter { $0.state != .unknown }.map { $0.id + "=" + $0.state.rawValue }
    }
    /// `probe` reads only the target version's Apple state; without it every check is a full read.
    /// `seed` is a snapshot remembered for the same saved plan, shown until the first read replaces or confirms it.
    /// `read` fetches only the parts it is given and returns them over the saved local material.
    public init(planEditor: ReleasePlanEditor, readParts read: @escaping @MainActor (ReleasePlan, ReleaseReadiness.Parts) async throws -> ReleaseReadinessSnapshot,
                probe: (@MainActor (ReleasePlan) async throws -> String?)? = nil, seed: (snapshot: ReleaseReadinessSnapshot, checkedAt: Date)? = nil,
                materialSignature: (@MainActor (ReleasePlan) async throws -> String)? = nil,
                remember: @escaping @MainActor (ReleaseReadinessSnapshot, Date) -> Void = { _, _ in }) {
        self.planEditor = planEditor; self.read = read; self.probe = probe; self.remember = remember; self.materialSignature = materialSignature
        if let seed, let plan = planEditor.plan, planEditor.ready, !planEditor.dirty, TextSemantics.same(seed.snapshot.plan.token, plan.token),
           seed.snapshot.scope.accountId == planEditor.accountId, seed.snapshot.scope.appId == planEditor.appId {
            snapshot = seed.snapshot; checkedAt = seed.checkedAt
        }
        observedPlan = planSignature
        observer = planEditor.observe { [weak self] in
            guard let self, self.active else { return }
            let signature = self.planSignature
            guard signature != self.observedPlan else { return }; self.observedPlan = signature
            self.generation &+= 1; self.stopFill(); self.snapshot = nil; self.checkedAt = nil; self.confirmed = false; self.checkedParts = []
            self.status = "The version plan changed. Save or compare it, then refresh the status of its saved material."
            self.didChange()
        }
    }
    /// Every check reads all parts at once.
    public convenience init(planEditor: ReleasePlanEditor, read: @escaping @MainActor (ReleasePlan) async throws -> ReleaseReadinessSnapshot,
                            probe: (@MainActor (ReleasePlan) async throws -> String?)? = nil, seed: (snapshot: ReleaseReadinessSnapshot, checkedAt: Date)? = nil,
                            materialSignature: (@MainActor (ReleasePlan) async throws -> String)? = nil,
                            remember: @escaping @MainActor (ReleaseReadinessSnapshot, Date) -> Void = { _, _ in }) {
        self.init(planEditor: planEditor, readParts: { plan, _ in try await read(plan) }, probe: probe, seed: seed, materialSignature: materialSignature, remember: remember)
    }
    private var planSignature: String { JSONText.array([.string(planEditor.inputs.signature), .string(planEditor.expected ?? ""), .bool(planEditor.needsComparison), .bool(planEditor.active)]).stringify() }
    public convenience init(planEditor: ReleasePlanEditor, account: Account, session: WorkspaceSession, seed: (snapshot: ReleaseReadinessSnapshot, checkedAt: Date)? = nil) {
        self.init(planEditor: planEditor, readParts: { plan, parts in
            let client: AppStoreConnectClient?
            do { client = try await session.readClient(for: account) } catch { try Task.checkCancellation(); client = nil }
            return try await session.releaseReadiness(account: account, appId: plan.appId, revisionId: plan.sourceRevisionId, planToken: plan.token, client: client, parts: parts)
        }, probe: { plan in try await session.releaseVersionState(account: account, plan: plan) }, seed: seed,
           materialSignature: { plan in try await session.releaseMaterialSignature(accountId: account.id, appId: plan.appId, revisionId: plan.sourceRevisionId, planToken: plan.token) },
           remember: { value, date in Task { await session.rememberReleaseReadiness(value, checkedAt: date) } })
    }
    /// An approved Apple change from this flow: check often until Apple shows its result.
    public func noteAppleWrite() { writtenAt = .now; writtenStatus = knownStatus }
    /// The wait before the next automatic check, or nil when none is due.
    public var nextCheck: Duration? {
        guard active, planEditor.plan != nil else { return nil }
        return ReleaseStatusSync.delay(appleState: snapshot?.targetState, sinceWrite: sinceWrite, failures: failures)
    }
    /// A cheap check of the target version's Apple state. A changed or unreadable state, a remembered snapshot or a failed earlier read
    /// leads to a full read; an unchanged state only confirms the time. Returns true when a full read replaced the snapshot.
    @discardableResult public func sync() async -> Bool {
        guard active, !busy, planEditor.ready, !planEditor.dirty, let plan = planEditor.plan, !Task.isCancelled else { return false }
        guard let probe, let current = snapshot, confirmed, !readFailed, sinceWrite.map({ $0 >= ReleaseStatusSync.settleWindow }) ?? true else { return await refresh() }
        let ticket = UUID(), starting = generation; operation = ticket
        let state: String?
        do { state = try await probe(plan); try Task.checkCancellation() }
        catch {
            if operation == ticket { operation = nil }
            guard active, starting == generation, !Task.isCancelled else { return false }
            failures += 1; didChange(); return false
        }
        guard active, operation == ticket, starting == generation, planEditor.ready, !planEditor.dirty, TextSemantics.same(planEditor.expected, plan.token) else { return false }
        operation = nil
        guard state != current.targetState else {
            failures = 0
            if !filling { checkedAt = Date(); remember(current, checkedAt!) }
            didChange(); return false
        }
        return await refresh()
    }
    /// Opening or moving between steps: a snapshot younger than `fresh`, remembered or confirmed here, for saved material that has not changed since, is confirmed
    /// by one cheap read of the version's Apple state. Anything else, or a changed state, is read in full. Returns true when the snapshot is current.
    @discardableResult public func revalidate(fresh: TimeInterval = ReleaseStatusSync.rememberedFreshness, now: Date = Date()) async -> Bool {
        guard active, !busy, planEditor.ready, !planEditor.dirty, let plan = planEditor.plan, !Task.isCancelled else { return false }
        guard let probe, let materialSignature, let current = snapshot, let checked = checkedAt, now.timeIntervalSince(checked) < fresh, !readFailed, sinceWrite == nil,
              !current.steps.contains(where: Self.comparesWithApple) else { return await refresh() }
        let ticket = UUID(), starting = generation; operation = ticket; busy = true; didChange()
        defer { if operation == ticket { operation = nil; busy = false; didChange() } }
        guard let signature = try? await materialSignature(plan), TextSemantics.same(signature, current.materialSignature), operation == ticket, starting == generation else {
            if operation == ticket { operation = nil; busy = false }; return await refresh()
        }
        let state: String?
        do { state = try await probe(plan) } catch { state = "unreadable" }
        guard active, !Task.isCancelled, operation == ticket, starting == generation, planEditor.ready, !planEditor.dirty, TextSemantics.same(planEditor.expected, plan.token) else { return false }
        guard state == current.targetState else { operation = nil; busy = false; return await refresh() }
        confirmed = true; failures = 0
        status = "Checked against App Store Connect. Edits you haven't saved yet are not included."
        // While the background reads still run, the step just opened is read before the rest.
        if filling {
            let missing = focus.subtracting(checkedParts)
            guard !missing.isEmpty else { return true }
            operation = nil; busy = false; return await check(missing, restart: false)
        }
        checkedParts = .all; checkedAt = now; remember(current, now)
        return true
    }
    /// A difference between saved material and Apple's copy that a save clears without changing the version's state, so the state read cannot confirm it.
    static func comparesWithApple(_ step: ReleaseReadiness.Step) -> Bool {
        step.state == .blocked && ["apple-text:", "apple-info:", "media:"].contains(where: step.id.hasPrefix)
    }
    public func retire() {
        guard active else { return }; active = false; generation &+= 1; stopFill(); snapshot = nil; checkedAt = nil; confirmed = false; checkedParts = []
        if let observer { planEditor.removeObserver(observer); self.observer = nil }
        didChange()
    }
    /// Reads the open step's parts, then the rest in the background. Each part is merged into the snapshot as it arrives.
    @discardableResult public func refresh() async -> Bool { await check(focus, restart: true) }
    /// `restart` starts a new check in which every part is read again; otherwise only `parts` are read ahead of the background reads still due.
    private func check(_ parts: ReleaseReadiness.Parts, restart: Bool) async -> Bool {
        guard active, !busy, planEditor.ready, !planEditor.dirty, let plan = planEditor.plan, !Task.isCancelled else { return false }
        let wanted = parts.intersection(.all).isEmpty ? ReleaseReadiness.Parts.all : parts.intersection(.all)
        stopFill()
        let ticket = UUID(), starting = generation; operation = ticket; busy = true; status = "Reading saved material and current Apple status…"; didChange()
        if restart { checkedParts = [] }
        defer { if operation == ticket { operation = nil; busy = false; didChange() } }
        do {
            let value = try await read(plan, wanted); try Task.checkCancellation()
            guard active, operation == ticket, starting == generation, planEditor.ready, !planEditor.dirty,
                  TextSemantics.same(planEditor.expected, plan.token) else { return false }
            try accept(value, plan: plan)
            let now = Date(); snapshot = value.merging(snapshot); checkedParts.formUnion(wanted); readFailed = false; confirmed = true; failures = 0
            if restart || checkedAt == nil { checkedAt = now }
            status = "Checked against App Store Connect. Edits you haven't saved yet are not included."
            if checkedParts.isSuperset(of: .all) { remember(snapshot!, checkedAt!) } else { startFill(plan: plan) }
            didChange(); return true
        } catch {
            guard active, operation == ticket, starting == generation else { return false }
            readFailed = true; if !Task.isCancelled { failures += 1 }
            status = Task.isCancelled ? "The status read stopped. Refresh when ready." : "The saved release material could not be confirmed. Compare the version plan if needed, then refresh; existing inputs are kept."
            didChange(); return false
        }
    }
    private func accept(_ value: ReleaseReadinessSnapshot, plan: ReleasePlan) throws {
        guard value.scope.accountId == planEditor.accountId, value.scope.appId == planEditor.appId,
              TextSemantics.same(value.plan.token, plan.token) else { throw ReleaseReadiness.Failure.invalid }
    }
    private func stopFill() {
        fill?.cancel(); fill = nil; fillTicket = nil; fillStarted = []
        if filling { filling = false }
    }
    /// Reads the parts not checked yet in small batches by `fillWidth` workers, the open step's parts first and then cheapest first.
    /// The check's time and the remembered status change only once every part has been read.
    private func startFill(plan: ReleasePlan) {
        let ticket = UUID(), starting = generation; fillTicket = ticket; filling = true; fillWorkers = Self.fillWidth; fillComplete = true
        let workers = (0..<Self.fillWidth).map { _ in Task { [weak self] in await self?.fillWorker(plan: plan, ticket: ticket, starting: starting) } }
        fill = Task { for worker in workers { await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() } } }
    }
    private func fillWorker(plan: ReleasePlan, ticket: UUID, starting: UInt64) async {
        defer { fillWorkerDone(ticket: ticket, starting: starting) }
        while fillTicket == ticket, starting == generation, active, !Task.isCancelled {
            let due = ReleaseReadiness.Parts.all.subtracting(checkedParts).subtracting(fillStarted)
            guard let next = ReleaseReadiness.Parts.batches(due, first: focus).first else { return }
            fillStarted.formUnion(next)
            let value = try? await read(plan, next)
            guard fillTicket == ticket, starting == generation, active else { return }
            guard let value, (try? accept(value, plan: plan)) != nil, planEditor.ready, !planEditor.dirty, TextSemantics.same(planEditor.expected, plan.token) else { fillComplete = false; continue }
            snapshot = value.merging(snapshot); checkedParts.formUnion(next); didChange()
        }
    }
    private func fillWorkerDone(ticket: UUID, starting: UInt64) {
        guard fillTicket == ticket else { return }
        fillWorkers -= 1
        guard fillWorkers == 0 else { return }
        fill = nil; fillTicket = nil; filling = false; fillStarted = []
        if fillComplete, starting == generation, active, let snapshot, let checkedAt { remember(snapshot, checkedAt) }
        didChange()
    }
}
