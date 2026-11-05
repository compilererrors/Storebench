import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct ReleasePlanEditorTests {
    init() throws { _ = try TestIsolation.require() }
    private let account = "synthetic-account", app = "1000000001"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private enum SyntheticFailure: Error { case read, timeout }
    @MainActor private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async { await withCheckedContinuation { continuation = $0; entered = true } }
        func release() { continuation?.resume(); continuation = nil }
        func wait() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !entered { guard ContinuousClock.now < deadline else { throw SyntheticFailure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
        }
    }
    private func plan(_ version: String = "2.0", type: String = "MANUAL", source: String = "synthetic-source") throws -> ReleasePlan {
        try #require(ReleasePlan(.object([("accountId", .string(account)), ("appId", .string(app)), ("sourceRevisionId", .string(source)),
            ("baseVersionId", .string("synthetic-version")), ("platform", .string("IOS")), ("targetVersion", .string(version)),
            ("releaseType", .string(type)), ("updatedAt", .string("2027-01-15T08:00:00.000Z"))])))
    }
    private func initial() -> ReleasePlanInputs { .init(start: .empty(platform: "IOS", locale: "en-US"), date: now.addingTimeInterval(86_400)) }
    private func model(read: @escaping @MainActor () async throws -> ReleasePlan?,
                       save: @escaping @MainActor (ReleasePlanInputs, String) async throws -> ReleasePlan,
                       remove: @escaping @MainActor (String) async throws -> Void = { _ in }) -> ReleasePlanEditor {
        .init(accountId: account, appId: app, initial: initial(), read: read, save: save, remove: remove)
    }

    @Test func unreadAndMissingPlansAreDifferentBaselines() async throws {
        var fail = true, writes = 0
        let saved = try plan()
        let owner = model(read: { if fail { throw SyntheticFailure.read }; return nil }, save: { _, expected in
            #expect(expected == "null"); writes += 1; return saved
        })
        owner.inputs.targetVersion = "2.0"; await owner.load()
        #expect(!owner.loaded && owner.expected == nil && !owner.ready && owner.inputs.targetVersion == "2.0")
        #expect(!(await owner.save(now: now))); #expect(writes == 0)
        fail = false; await owner.load(); #expect(owner.loaded && owner.expected == "null" && owner.dirty)
        #expect(await owner.save(now: now)); #expect(owner.plan == saved && !owner.dirty && writes == 1)
        await owner.load(); #expect(owner.plan == saved)
    }
    @Test func lateInputsRemainAfterSaveAndTheConfirmedSourceIsRetained() async throws {
        let gate = Gate(), saved = try plan(), later = try plan("2.1")
        var writes = 0, tokens: [String] = []
        let owner = model(read: { nil }, save: { _, expected in
            tokens.append(expected); writes += 1
            if writes == 1 { await gate.hold(); return saved }; return later
        })
        await owner.load(); owner.inputs.targetVersion = "2.0"
        let task = Task { await owner.save(now: now) }; try await gate.wait(); defer { gate.release() }
        owner.inputs.targetVersion = "2.1"; gate.release(); #expect(await task.value)
        #expect(owner.dirty && owner.inputs.targetVersion == "2.1" && owner.baseline.targetVersion == "2.0")
        #expect(owner.inputs.start == .reuse && owner.inputs.sourceRevisionId == saved.sourceRevisionId)
        #expect(await owner.save(now: now)); #expect(tokens == ["null", saved.token] && !owner.dirty)
    }
    @Test func stalePlanNeedsExplicitComparisonWithoutAutomaticallySaving() async throws {
        let first = try plan(), remote = try plan("2.0", type: "AFTER_APPROVAL"), kept = try plan("2.1", type: "AFTER_APPROVAL")
        var current = first, writes = 0, reads = 0
        let owner = model(read: { reads += 1; return current }, save: { _, expected in
            writes += 1
            guard expected == current.token else { throw ReleaseFailure.conflict("Synthetic concurrent plan change") }
            current = kept; return kept
        })
        await owner.load(); owner.inputs.targetVersion = "2.1"; current = remote
        #expect(!(await owner.save(now: now))); #expect(owner.needsComparison && owner.expected == first.token && owner.dirty)
        await owner.load(); #expect(reads == 1 && owner.expected == first.token)
        await owner.readLatest(); #expect(owner.expected == first.token && owner.inputs.releaseType == "MANUAL" && writes == 1)
        owner.acceptLatest(keepEdits: true)
        #expect(owner.inputs.targetVersion == "2.1" && owner.inputs.releaseType == "AFTER_APPROVAL" && owner.expected == remote.token && writes == 1)
        #expect(await owner.save(now: now)); #expect(!owner.dirty && writes == 2)
    }
    @Test func comparingRemovalAndNewSourcesDoesNotAdoptTheOldSource() async throws {
        let first = try plan(), replacement = try plan("3.0", source: "synthetic-new-source")
        var current: ReleasePlan? = first, writes = 0
        let owner = model(read: { current }, save: { _, _ in writes += 1; return replacement })
        await owner.load(); owner.inputs.targetVersion = "3.1"
        current = replacement; await owner.readLatest(); owner.acceptLatest(keepEdits: true)
        #expect(owner.inputs.sourceRevisionId == replacement.sourceRevisionId && owner.inputs.targetVersion == "3.1" && writes == 0)
        current = nil; await owner.readLatest(); #expect(owner.latestRead && owner.latest == nil && owner.latestInputs != nil)
        owner.acceptLatest(keepEdits: false)
        #expect(owner.plan == nil && owner.expected == "null" && !owner.dirty && owner.inputs.start == initial().start && writes == 0)
    }
    @Test func removalUsesCapturedTokenAndRetainsInputsOnConflict() async throws {
        let first = try plan(); var supplied = ""
        let owner = model(read: { first }, save: { _, _ in first }, remove: { supplied = $0; throw ReleaseFailure.conflict("Synthetic removed plan") })
        await owner.load(); owner.inputs.targetVersion = "2.1"
        #expect(!(await owner.remove())); #expect(supplied == first.token && owner.plan == first && owner.dirty && owner.needsComparison)
        owner.revert(); #expect(!owner.dirty && owner.needsComparison && !owner.ready)
    }
    @Test func retiredOwnerCannotStartQueuedWorkButAcknowledgesCompletedWrite() async throws {
        let saved = try plan(), gate = Gate(); var writes = 0
        let owner = model(read: { nil }, save: { _, _ in writes += 1; await gate.hold(); return saved })
        await owner.load(); owner.inputs.targetVersion = "2.0"
        let task = Task { await owner.save(now: now) }; try await gate.wait(); defer { gate.release() }
        owner.retire(); gate.release(); #expect(await task.value)
        #expect(writes == 1 && owner.plan == nil && !owner.active && !owner.busy)
        #expect(!(await owner.save(now: now))); #expect(!(await owner.remove())); #expect(writes == 1)
    }
    @Test func inputsInvalidateAnAlreadyReadComparison() async throws {
        let saved = try plan(), owner = model(read: { saved }, save: { _, _ in saved })
        await owner.load(); await owner.readLatest(); #expect(owner.latestRead)
        owner.inputs.targetVersion = "2.1"; #expect(!owner.latestRead && owner.latestInputs == nil)
        owner.acceptLatest(keepEdits: false); #expect(owner.inputs.targetVersion == "2.1")
    }
    @Test func mismatchedReceiptCannotBecomeASavedBaseline() async throws {
        let unexpected = try plan("9.0"), owner = model(read: { nil }, save: { _, _ in unexpected })
        await owner.load(); owner.inputs.targetVersion = "2.0"
        #expect(!(await owner.save(now: now))); #expect(owner.plan == nil && owner.dirty && owner.needsComparison && owner.expected == "null")
    }
    @Test func protectionUpdatesBeforeAnAwaitAndKeepsOtherOwners() async throws {
        let saved = try plan(), gate = Gate(); var policy = EditorProtectionPolicy()
        let owner = model(read: { await gate.hold(); return saved }, save: { _, _ in saved })
        owner.didChange = { policy.update(id: "synthetic-plan-owner", dirty: owner.dirty, busy: owner.busy) }
        policy.update(id: "synthetic-other-owner", dirty: true, busy: false)
        let task = Task { await owner.load() }; try await gate.wait(); defer { gate.release() }
        #expect(policy.decision == .wait); gate.release(); await task.value
        #expect(policy.decision == .confirmDiscard); owner.retire(); policy.remove(id: "synthetic-plan-owner")
        #expect(policy.decision == .confirmDiscard)
    }
    @Test func versionAndScheduledDateValidationMatchesStoredInputLimits() throws {
        for valid in ["1", "2.0", "10.20.30"] { try Releases.validateVersion(valid) }
        for invalid in ["٢.٠", "２.０", "2.0\n", "2.0.0.1", "-1", "1e2"] {
            #expect(throws: ReleaseFailure.self) { try Releases.validateVersion(invalid) }
        }
        for seconds in [Double.nan, .infinity, -.infinity, 253_402_300_800, 1e100] {
            #expect(throws: ReleaseFailure.self) { try Releases.settings(type: "SCHEDULED", date: Date(timeIntervalSince1970: seconds), now: now) }
        }
        for valid in ["2033-05-18T03:33:20Z", "2033-05-18T03:33:20.1Z", "2033-05-18T03:33:20.12Z", "2033-05-18T03:33:20.123Z"] { #expect(Releases.parsedDate(valid) != nil) }
        for invalid in ["2033-02-30T03:33:20Z", "2033-05-18T03:33:20.1234Z", "2033-05-18T03:33:20+01:00", "2033-05-18T03:33:20Z\n", "2033-13-18T03:33:20Z"] { #expect(Releases.parsedDate(invalid) == nil) }
    }
    @Test func scheduledReceiptsNormalizeMillisecondsWithoutLeavingFalseDirtyInputs() async throws {
        let date = Date(timeIntervalSince1970: 2_000_000_000.1234)
        let saved = try #require(ReleasePlan(.object([("accountId", .string(account)), ("appId", .string(app)), ("sourceRevisionId", .string("synthetic-source")),
            ("baseVersionId", .string("synthetic-version")), ("platform", .string("IOS")), ("targetVersion", .string("2.0")), ("releaseType", .string("SCHEDULED")),
            ("earliestReleaseDate", .string("2033-05-18T03:33:20.123Z")), ("updatedAt", .string("2027-01-15T08:00:00.000Z"))])))
        let owner = model(read: { nil }, save: { snapshot, _ in #expect(snapshot.date == date); return saved })
        await owner.load(); owner.inputs.targetVersion = " 2.0 "; owner.inputs.releaseType = "SCHEDULED"; owner.inputs.date = date
        #expect(await owner.save(now: now)); #expect(!owner.dirty && owner.inputs.targetVersion == "2.0" && owner.inputs.date == Releases.parsedDate(saved.earliestReleaseDate!))
    }
    @Test func editsMadeDuringRemovalRemainUnsavedAfterThePhysicalDelete() async throws {
        let saved = try plan(), gate = Gate()
        let owner = model(read: { saved }, save: { _, _ in saved }, remove: { _ in await gate.hold() })
        await owner.load(); let task = Task { await owner.remove() }; try await gate.wait(); defer { gate.release() }
        owner.inputs.targetVersion = "4.0"; gate.release(); #expect(await task.value)
        #expect(owner.plan == nil && owner.dirty && owner.inputs.targetVersion == "4.0" && owner.expected == "null")
    }
    @Test func sessionEditorsRejectConcurrentChangesAndMalformedPlans() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let configured = try #require(try await session.accounts().first)
        let first = ReleasePlanEditor(account: configured, appId: app, initial: initial(), session: session)
        let second = ReleasePlanEditor(account: configured, appId: app, initial: initial(), session: session)
        await first.load(); await second.load(); first.inputs.targetVersion = "2.0"; second.inputs.targetVersion = "3.0"
        #expect(await first.save()); #expect(!(await second.save())); #expect(second.needsComparison && second.expected == "null")
        let actual = try #require(try await session.releasePlan(accountId: configured.id, appId: app))
        await second.readLatest(); #expect(second.expected == "null" && second.inputs.targetVersion == "3.0")
        second.acceptLatest(keepEdits: true); #expect(second.expected == actual.token && second.inputs.sourceRevisionId == actual.sourceRevisionId)
        #expect(await second.save()); #expect(try await session.releasePlan(accountId: configured.id, appId: app)?.targetVersion == "3.0")
        let malformed = JSONText.object([("schemaVersion", .number(1)), ("plans", .array([.object([("accountId", .string(configured.id)), ("appId", .string(app))])]))]).data
        try await session.storeAccess { @Sendable store in
            try store.transaction { _ in [.put(namespace: "release_plans", key: "all", json: malformed)] }
        }
        await #expect(throws: ReleaseFailure.self) { try await session.releasePlan(accountId: configured.id, appId: app) }
        let unread = ReleasePlanEditor(account: configured, appId: app, initial: initial(), session: session)
        await unread.load(); #expect(!unread.loaded && !unread.ready && unread.expected == nil)
    }
}
