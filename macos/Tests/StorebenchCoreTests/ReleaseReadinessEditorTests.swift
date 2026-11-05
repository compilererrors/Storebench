import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct ReleaseReadinessEditorTests {
    init() throws { _ = try TestIsolation.require() }
    private enum Failure: Error { case synthetic }
    @MainActor private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async { await withCheckedContinuation { continuation = $0; entered = true } }
        func release() { continuation?.resume(); continuation = nil }
        func wait() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !entered { guard ContinuousClock.now < deadline else { throw Failure.synthetic }; try await Task.sleep(for: .milliseconds(10)) }
        }
    }
    private func plan() throws -> ReleasePlan {
        try #require(ReleasePlan(.object([("accountId", .string("synthetic-account")), ("appId", .string("1000000001")),
            ("sourceRevisionId", .string("00000000-0000-4000-8000-000000000002")), ("baseVersionId", .string("synthetic-base")), ("platform", .string("IOS")),
            ("targetVersion", .string("2.0")), ("releaseType", .string("MANUAL")), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
    }
    private func owner() async throws -> ReleasePlanEditor {
        let plan = try plan(), model = ReleasePlanEditor(accountId: plan.accountId, appId: plan.appId, initial: .init(date: Date(timeIntervalSince1970: 2_000_000_000)),
            read: { plan }, save: { _, _ in throw Failure.synthetic }, remove: { _ in throw Failure.synthetic })
        await model.load(); return model
    }
    private func snapshot(_ plan: ReleasePlan, scope: RecoveryGuidance.Scope? = nil, state: String? = nil) throws -> ReleaseReadinessSnapshot {
        let value = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/release-readiness.json")))
        guard case .array(let cases)? = value["cases"], let input = cases.first?["input"] else { throw Failure.synthetic }
        let selected = try scope ?? RecoveryGuidance.Scope(accountId: plan.accountId, appId: plan.appId)
        let valid = try RecoveryGuidance.Scope(accountId: plan.accountId, appId: plan.appId)
        return .init(scope: selected, plan: plan, steps: try ReleaseReadiness.steps(input, scope: valid), materialSignature: "synthetic-saved-material", targetVersionId: "synthetic-version", targetState: state)
    }
    @Test func aRememberedStatusShowsAtOnceButIsNotVerifiedUntilReadAgain() async throws {
        let plan = try await owner(), saved = try #require(plan.plan), remembered = try snapshot(saved, state: "WAITING_FOR_REVIEW"), fresh = try snapshot(saved, state: "DEVELOPER_REJECTED")
        let checked = Date(timeIntervalSince1970: 1_900_000_000); var kept: [String?] = []
        let model = ReleaseReadinessEditor(planEditor: plan, read: { _ in fresh }, seed: (remembered, checked), remember: { value, _ in kept.append(value.targetState) })
        #expect(model.snapshot?.targetState == "WAITING_FOR_REVIEW" && model.checkedAt == checked && !model.confirmed && !model.ready)
        #expect(await model.refresh()); #expect(model.snapshot?.targetState == "DEVELOPER_REJECTED" && model.confirmed && model.ready && model.checkedAt != checked && kept == ["DEVELOPER_REJECTED"])
        let other = try snapshot(#require(ReleasePlan(.object([("accountId", .string("synthetic-account")), ("appId", .string("1000000001")),
            ("sourceRevisionId", .string("00000000-0000-4000-8000-000000000002")), ("baseVersionId", .string("synthetic-base")), ("platform", .string("IOS")),
            ("targetVersion", .string("3.0")), ("releaseType", .string("MANUAL")), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))]))))
        #expect(ReleaseReadinessEditor(planEditor: plan, read: { _ in fresh }, seed: (other, checked)).snapshot == nil)
    }
    @Test func syncReadsEverythingOnlyWhenAppleStateChanges() async throws {
        let plan = try await owner(), saved = try #require(plan.plan); var reads = 0, probes = 0, state: String? = "WAITING_FOR_REVIEW", fail = false
        let model = ReleaseReadinessEditor(planEditor: plan, read: { _ in reads += 1; return try self.snapshot(saved, state: state) },
                                           probe: { _ in probes += 1; if fail { throw Failure.synthetic }; return state })
        #expect(await model.sync()); #expect(reads == 1 && probes == 0 && model.nextCheck == .seconds(60))
        let first = try #require(model.checkedAt)
        #expect(await model.sync() == false); #expect(reads == 1 && probes == 1 && model.checkedAt! >= first)
        fail = true; #expect(await model.sync() == false); #expect(reads == 1 && model.failures == 1 && model.nextCheck == .seconds(120) && model.ready)
        fail = false; state = "DEVELOPER_REJECTED"
        #expect(await model.sync()); #expect(reads == 2 && probes == 3 && model.failures == 0 && model.snapshot?.targetState == "DEVELOPER_REJECTED" && model.nextCheck == nil)
        model.noteAppleWrite(); #expect(model.nextCheck == .seconds(10))
        #expect(await model.sync()); #expect(reads == 3 && probes == 3)
        // Once Apple shows the change, the frequent checks after it stop.
        state = "WAITING_FOR_REVIEW"; #expect(await model.refresh()); #expect(model.sinceWrite == nil && model.nextCheck == .seconds(60))
    }
    @Test func duplicateStartsHaveOneReadAndNeverChangeThePlanInputs() async throws {
        let plan = try await owner(), value = try snapshot(#require(plan.plan)), gate = Gate(); var reads = 0
        let model = ReleaseReadinessEditor(planEditor: plan, read: { _ in reads += 1; await gate.hold(); return value })
        let before = plan.inputs, token = plan.expected, task = Task { await model.refresh() }; try await gate.wait(); defer { gate.release() }
        #expect(model.busy); #expect(await model.refresh() == false); #expect(reads == 1 && plan.inputs == before && plan.expected == token)
        gate.release(); #expect(await task.value); #expect(model.snapshot?.materialSignature == value.materialSignature && !model.busy && !plan.dirty)
    }
    @Test func evenRevertedPlanEditsInvalidateAnEarlierStatusRead() async throws {
        let plan = try await owner(), value = try snapshot(#require(plan.plan)), gate = Gate()
        let model = ReleaseReadinessEditor(planEditor: plan, read: { _ in await gate.hold(); return value })
        let task = Task { await model.refresh() }; try await gate.wait(); defer { gate.release() }
        plan.inputs.targetVersion = "3.0"; plan.revert(); #expect(!plan.dirty && model.snapshot == nil)
        gate.release(); #expect(await task.value == false); #expect(model.snapshot == nil && !model.busy && plan.inputs.targetVersion == "2.0")
    }
    @Test func backgroundStatusReadsKeepThePreviousSnapshotAndPlanReadActivityDoesNotInvalidateIt() async throws {
        let plan = try await owner(), value = try snapshot(#require(plan.plan)), gate = Gate(); var reads = 0
        let model = ReleaseReadinessEditor(planEditor: plan, read: { _ in reads += 1; if reads > 1 { await gate.hold() }; return value })
        #expect(await model.refresh()); await plan.readLatest()
        #expect(model.snapshot?.targetVersionId == value.targetVersionId)
        let task = Task { await model.refresh() }; try await gate.wait(); defer { gate.release() }
        #expect(model.busy && model.snapshot?.targetVersionId == value.targetVersionId)
        gate.release(); #expect(await task.value)
    }
    @Test func aFailedBackgroundRefreshKeepsMountedStepDataWithoutOfferingItAsVerified() async throws {
        let plan = try await owner(), value = try snapshot(#require(plan.plan)); var fail = false
        let model = ReleaseReadinessEditor(planEditor: plan, read: { _ in if fail { throw Failure.synthetic }; return value })
        #expect(await model.refresh()); fail = true
        #expect(await model.refresh() == false)
        #expect(model.snapshot?.targetVersionId == value.targetVersionId && model.readFailed && !model.ready)
        fail = false; #expect(await model.refresh()); #expect(model.ready && !model.readFailed)
    }
    @Test func aRetiredOwnerAcknowledgesOnlyItsPhysicalReadCompletion() async throws {
        let plan = try await owner(), value = try snapshot(#require(plan.plan)), gate = Gate()
        let model = ReleaseReadinessEditor(planEditor: plan, read: { _ in await gate.hold(); return value })
        let task = Task { await model.refresh() }; try await gate.wait(); defer { gate.release() }
        model.retire(); #expect(model.busy && !model.active && model.snapshot == nil); #expect(await model.refresh() == false)
        let replacement = ReleaseReadinessEditor(planEditor: plan, read: { _ in value }); #expect(await replacement.refresh())
        gate.release(); #expect(await task.value == false); #expect(!model.busy && replacement.snapshot?.materialSignature == value.materialSignature)
    }
    @Test func failedForeignAndCancelledReadsCannotProvideVerifiedRowsAndCanBeRetried() async throws {
        let plan = try await owner(), value = try snapshot(#require(plan.plan)), foreign = try snapshot(#require(plan.plan), scope: RecoveryGuidance.Scope(accountId: "synthetic-other", appId: "1000000001"))
        var mode = 0
        let model = ReleaseReadinessEditor(planEditor: plan, read: { _ in if mode == 0 { throw Failure.synthetic }; return mode == 1 ? foreign : value })
        #expect(await model.refresh() == false); #expect(model.snapshot == nil && !model.busy)
        mode = 1; #expect(await model.refresh() == false); #expect(model.snapshot == nil)
        mode = 2; #expect(await model.refresh()); #expect(model.snapshot?.scope == value.scope)
        let gate = Gate(), cancelled = ReleaseReadinessEditor(planEditor: plan, read: { _ in await gate.hold(); return value })
        let task = Task { await cancelled.refresh() }; try await gate.wait(); defer { gate.release() }; task.cancel(); gate.release()
        #expect(await task.value == false); #expect(cancelled.snapshot == nil && !cancelled.busy)
    }
    @Test func retirementRemovesOnlyItsOwnObserverAndDirtyPlansDoNotRead() async throws {
        let plan = try await owner(), value = try snapshot(#require(plan.plan)); var notices = 0, reads = 0
        let observer = plan.observe { notices += 1 }, model = ReleaseReadinessEditor(planEditor: plan, read: { _ in reads += 1; return value })
        plan.inputs.targetVersion = "3.0"; #expect(await model.refresh() == false); #expect(reads == 0)
        model.retire(); let before = notices; plan.revert(); #expect(notices > before)
        plan.removeObserver(observer)
    }
    @Test func openingAgainConfirmsARecentStatusWithOneVersionStateRead() async throws {
        let plan = try await owner(), saved = try #require(plan.plan), now = Date(timeIntervalSince1970: 2_000_000_000)
        var reads = 0, probes = 0, state: String? = "PREPARE_FOR_SUBMISSION", material = "synthetic-saved-material"
        func editor(checked: Date) throws -> ReleaseReadinessEditor {
            ReleaseReadinessEditor(planEditor: plan, read: { _ in reads += 1; return try self.snapshot(saved, state: state) }, probe: { _ in probes += 1; return state },
                                   seed: (try snapshot(saved, state: "PREPARE_FOR_SUBMISSION"), checked), materialSignature: { _ in material })
        }
        let recent = try editor(checked: now.addingTimeInterval(-60))
        #expect(await recent.revalidate(now: now)); #expect(reads == 0 && probes == 1 && recent.confirmed && recent.ready && recent.checkedAt == now)
        material = "synthetic-edited-material"
        #expect(await try editor(checked: now.addingTimeInterval(-60)).revalidate(now: now)); #expect(reads == 1 && probes == 1)
        material = "synthetic-saved-material"; state = "WAITING_FOR_REVIEW"
        #expect(await try editor(checked: now.addingTimeInterval(-60)).revalidate(now: now)); #expect(reads == 2 && probes == 2)
        #expect(await try editor(checked: now.addingTimeInterval(-ReleaseStatusSync.rememberedFreshness - 1)).revalidate(now: now)); #expect(reads == 3 && probes == 2)
    }
    /// Saving text leaves the version's state unchanged, so a remembered "only on this Mac" or a save not seen yet is read again in full.
    @Test func openingAgainReadsInFullWhileAppleTextDiffersOrASaveIsUnseen() async throws {
        let plan = try await owner(), saved = try #require(plan.plan), now = Date(timeIntervalSince1970: 2_000_000_000)
        let current = try snapshot(saved, state: "PREPARE_FOR_SUBMISSION"); var reads = 0, probes = 0
        let unsynced = ReleaseReadinessSnapshot(scope: current.scope, plan: current.plan, steps: current.steps.map { step in
            step.id != "apple-text:en-US" ? step : ReleaseReadiness.Step(id: step.id, label: step.label, detail: step.detail, href: step.href, action: step.action, state: .blocked, territories: step.territories, guideHref: step.guideHref)
        }, materialSignature: current.materialSignature, targetVersionId: current.targetVersionId, targetState: current.targetState)
        func editor(_ seed: ReleaseReadinessSnapshot) -> ReleaseReadinessEditor {
            ReleaseReadinessEditor(planEditor: plan, read: { _ in reads += 1; return current }, probe: { _ in probes += 1; return "PREPARE_FOR_SUBMISSION" },
                                   seed: (seed, now.addingTimeInterval(-60)), materialSignature: { _ in "synthetic-saved-material" })
        }
        let stale = editor(unsynced)
        #expect(stale.snapshot?.steps.first { $0.id == "apple-text:en-US" }?.state == .blocked)
        #expect(await stale.revalidate(now: now)); #expect(reads == 1 && probes == 0 && stale.snapshot?.steps.first { $0.id == "apple-text:en-US" }?.state == .ready)
        let written = editor(current); written.noteAppleWrite()
        #expect(await written.revalidate(now: now)); #expect(reads == 2 && probes == 0)
        #expect(await editor(current).revalidate(now: now)); #expect(reads == 2 && probes == 1)
    }
}
