import Foundation
import Testing
@testable import StorebenchCore

@Suite struct EditorDepartureTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func backgroundReadsAndCleanWritesAllowNavigationWithoutReleasingTheirOwners() {
        var policy = EditorProtectionPolicy()
        policy.update(id: "synthetic-list-read", dirty: false, busy: true)
        #expect(policy.navigationDecision == .ready && policy.decision == .wait)
        var latest = policy; latest.update(id: "synthetic-background-save", dirty: false, busy: true)
        #expect(policy.allowsNavigation(after: latest, discardConfirmed: false))
        #expect(latest.isBusy(id: "synthetic-list-read"))
        #expect(!policy.allowsLeaving(after: latest, discardConfirmed: true))
    }

    @Test func dirtyBusyEditorsOfferDiscardButNewOwnersRequireTheirOwnConfirmation() {
        var policy = EditorProtectionPolicy()
        policy.update(id: "synthetic-draft", dirty: true, busy: true)
        #expect(policy.navigationDecision == .confirmDiscard)
        #expect(!policy.allowsNavigation(after: policy, discardConfirmed: false))
        #expect(policy.allowsNavigation(after: policy, discardConfirmed: true))
        var latest = policy; latest.update(id: "synthetic-new-draft", dirty: true, busy: false)
        #expect(!policy.allowsNavigation(after: latest, discardConfirmed: true))
        latest.remove(id: "synthetic-new-draft"); latest.update(id: "synthetic-draft", dirty: true, busy: false)
        #expect(policy.allowsNavigation(after: latest, discardConfirmed: true))
    }

    @Test @MainActor func savesFollowPlanBeforeListingAndOnlyRunEachDirtyOwnerOnce() async {
        let departure = EditorDeparture(); var order: [String] = []
        for id in ["synthetic-plan", "synthetic-listing", "synthetic-language"] { departure.policy.update(id: id, dirty: true, busy: false) }
        departure.register(id: "synthetic-plan", priority: -10) { order.append("plan"); return true }
        departure.register(id: "synthetic-listing", priority: -5) {
            order.append("listing"); departure.policy.update(id: "synthetic-language", dirty: false, busy: false); return true
        }
        departure.register(id: "synthetic-language") { order.append("language"); return true }
        #expect(departure.canSave)
        #expect(await departure.saveChanges(for: departure.begin()))
        #expect(order == ["plan", "listing"] && departure.policy.navigationDecision == .ready)
        #expect(!departure.canSave)
    }

    @Test @MainActor func unavailableOrFailedSavesKeepInputsAndNeverContinue() async {
        let departure = EditorDeparture()
        departure.policy.update(id: "synthetic-review", dirty: true, busy: false)
        #expect(!departure.canSave)
        departure.register(id: "synthetic-review") { false }
        #expect(departure.canSave)
        #expect(!(await departure.saveChanges(for: departure.begin())))
        #expect(departure.policy.dirtyIds == ["synthetic-review"])
        departure.policy.update(id: "synthetic-review", dirty: true, busy: true)
        #expect(!departure.canSave)
        departure.unregisterSave(id: "synthetic-review")
        #expect(departure.policy.dirtyIds == ["synthetic-review"])
    }

    @Test @MainActor func newDirtyOwnersAreNotSilentlyIncludedInAnApprovedSave() async {
        let departure = EditorDeparture()
        departure.policy.update(id: "synthetic-original", dirty: true, busy: false)
        departure.register(id: "synthetic-original") {
            departure.policy.update(id: "synthetic-new-owner", dirty: true, busy: false); return true
        }
        #expect(!(await departure.saveChanges(for: departure.begin())))
        #expect(departure.policy.dirtyIds == ["synthetic-new-owner"])
    }

    @MainActor private final class Gate {
        var continuation: CheckedContinuation<Bool, Never>?
        func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }
        func finish() { continuation?.resume(returning: true); continuation = nil }
    }

    @Test(arguments: [false, true]) @MainActor func aNewNavigationOrRetiredEditorInvalidatesDelayedSaveContinuation(retire: Bool) async {
        let departure = EditorDeparture(), gate = Gate()
        departure.policy.update(id: "synthetic-draft", dirty: true, busy: false)
        departure.register(id: "synthetic-draft") { await gate.wait() }
        let ticket = departure.begin()
        let result = Task { await departure.saveChanges(for: ticket) }
        while gate.continuation == nil { await Task.yield() }
        if retire { departure.remove(id: "synthetic-draft") } else { _ = departure.begin() }
        #expect(departure.closingPolicy.decision == .wait)
        if retire { #expect(departure.policy.navigationDecision == .ready) }
        gate.finish()
        #expect(!(await result.value))
        #expect(!departure.owns(ticket))
        #expect(departure.closingPolicy.decision == (retire ? .ready : .confirmDiscard))
    }

    @Test func lateAppReadsCannotReplaceANewerDestinationOrClearItsLoadingState() {
        var navigation = NavigationIntent()
        let first = navigation.begin(), second = navigation.begin()
        #expect(!navigation.owns(first) && navigation.owns(second))
        let overview = navigation.begin()
        #expect(!navigation.owns(first) && !navigation.owns(second) && navigation.owns(overview))
    }

    @Test @MainActor func anInFlightSaveCannotBeStartedTwiceByAnotherNavigation() async {
        let departure = EditorDeparture(), gate = Gate(); var saves = 0
        departure.policy.update(id: "synthetic-draft", dirty: true, busy: false)
        departure.register(id: "synthetic-draft") { saves += 1; return await gate.wait() }
        let ticket = departure.begin(), first = Task { await departure.saveChanges(for: ticket) }
        while gate.continuation == nil { await Task.yield() }
        #expect(!departure.canSave)
        let second = await departure.saveChanges(for: departure.begin())
        #expect(!second && saves == 1)
        gate.finish(); let oldResult = await first.value
        #expect(!oldResult && departure.policy.dirtyIds == ["synthetic-draft"])
    }

    @Test @MainActor func aReplacementEditorWithTheSameViewIdCannotBeClearedByTheEarlierSave() async {
        let departure = EditorDeparture(), gate = Gate()
        departure.policy.update(id: "synthetic-view", dirty: true, busy: false)
        departure.register(id: "synthetic-view", generation: "synthetic-owner-a") { await gate.wait() }
        let ticket = departure.begin(), first = Task { await departure.saveChanges(for: ticket) }
        while gate.continuation == nil { await Task.yield() }
        departure.register(id: "synthetic-view", generation: "synthetic-owner-b") { true }
        gate.finish(); let oldResult = await first.value
        #expect(!oldResult && departure.policy.dirtyIds == ["synthetic-view"])
        #expect(await departure.saveChanges(for: departure.begin()))
    }

    @Test @MainActor func aFailedSaveNamesTheItemMarkedInRed() async {
        let departure = EditorDeparture()
        departure.policy.update(id: "synthetic-plan", dirty: true, busy: false)
        departure.policy.update(id: "synthetic-media", dirty: true, busy: false)
        departure.register(id: "synthetic-plan", priority: -10) { true }
        departure.register(id: "synthetic-media", problem: { "Synthetic language · 2 screenshots not added. Choose Fix Images… or Discard." }) { false }
        #expect(!(await departure.saveChanges(for: departure.begin())))
        #expect(departure.failure == "Synthetic language · 2 screenshots not added. Choose Fix Images… or Discard.")
        #expect(departure.policy.dirtyIds == ["synthetic-media"])
        departure.register(id: "synthetic-media", problem: { nil }) { true }
        #expect(await departure.saveChanges(for: departure.begin()))
        #expect(departure.failure == nil)
    }
}
