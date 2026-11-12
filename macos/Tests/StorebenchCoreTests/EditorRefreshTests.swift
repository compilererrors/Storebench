import Foundation
import Testing
@testable import StorebenchCore

@MainActor @Suite(.serialized) struct EditorRefreshTests {
    init() throws { _ = try TestIsolation.require() }
    final class Form {
        var value = "Synthetic saved text", baseline = "Synthetic saved text"
        var busy = false, saves = 0, discards = 0, reads = 0, failSave = false, failRead = false
        var state: EditorRefresh.State { .init(dirty: value != baseline, busy: busy, signature: value) }
    }
    private func register(_ form: Form, on owner: EditorRefresh, id: UUID = UUID(), scope: String = "text", generation: String = "synthetic-editor", priority: Int = 0) -> UUID {
        owner.register(id: id, scope: scope, generation: generation, priority: priority, state: { form.state }, save: {
            form.saves += 1
            guard !form.failSave else { return false }; form.baseline = form.value; return true
        }, discard: { form.discards += 1; form.value = form.baseline; return true }, refresh: { form.reads += 1; return !form.failRead })
        return id
    }
    @Test func refreshReadsEveryCardInItsScopeAndChecksTheSummaryLast() async {
        let owner = EditorRefresh(), first = Form(), second = Form(), other = Form()
        _ = register(first, on: owner, priority: -1); _ = register(second, on: owner); _ = register(other, on: owner, scope: "build")
        #expect(owner.begin(scope: "text") && owner.confirmation == nil)
        #expect(await owner.perform(.refresh, summary: { first.reads == 1 && second.reads == 1 }))
        #expect(first.reads == 1 && second.reads == 1 && other.reads == 0)
        #expect(first.saves == 0 && second.discards == 0 && !owner.busy && !owner.failed)
    }
    @Test(arguments: [EditorRefresh.Choice.save, .discard, .cancel])
    func unsavedInputsRequireTheExactSaveDiscardOrCancelChoice(_ choice: EditorRefresh.Choice) async throws {
        let owner = EditorRefresh(), form = Form(); form.value = "Synthetic edited wording"
        _ = register(form, on: owner)
        #expect(owner.begin(scope: "text")); let confirmation = try #require(owner.confirmation)
        #expect(confirmation.canSave && confirmation.canDiscard)
        #expect(!(await owner.perform(.refresh)) && form.reads == 0)
        let result = await owner.perform(choice)
        #expect(result == (choice != .cancel))
        #expect(form.saves == (choice == .save ? 1 : 0) && form.discards == (choice == .discard ? 1 : 0))
        #expect(form.reads == (choice == .cancel ? 0 : 1))
        #expect(form.value == (choice == .discard ? "Synthetic saved text" : "Synthetic edited wording"))
    }
    @Test func aChangedInputOrReplacementEditorCannotConsumeTheDiscardChoice() async {
        let owner = EditorRefresh(), form = Form(); form.value = "Synthetic first edit"
        let id = register(form, on: owner)
        #expect(owner.begin(scope: "text")); form.value = "Synthetic newer edit"
        #expect(!(await owner.perform(.discard)) && form.discards == 0 && form.reads == 0)
        #expect(owner.begin(scope: "text")); _ = register(form, on: owner, id: id, generation: "synthetic-replacement")
        #expect(!(await owner.perform(.discard)) && form.discards == 0 && form.value == "Synthetic newer edit")
    }
    @Test func newlyDirtyCardsAreNeverIncludedInAnOlderConfirmation() async {
        let owner = EditorRefresh(), first = Form(), added = Form(); first.value = "Synthetic first edit"; added.value = "Synthetic new form edit"
        _ = register(first, on: owner); #expect(owner.begin(scope: "text")); _ = register(added, on: owner)
        #expect(!(await owner.perform(.discard)))
        #expect(first.discards == 0 && added.discards == 0 && first.reads == 0)
    }
    @Test func aSaveFailureKeepsInputsAndDoesNotStartRemoteRefreshes() async {
        let owner = EditorRefresh(), form = Form(); form.value = "Synthetic retained edit"; form.failSave = true
        _ = register(form, on: owner); #expect(owner.begin(scope: "text"))
        #expect(!(await owner.perform(.save)) && owner.failed)
        #expect(form.value == "Synthetic retained edit" && form.reads == 0 && !owner.busy)
    }
    @Test func aDelayedSaveCannotRefreshOverNewerEdits() async throws {
        let owner = EditorRefresh(), form = Form(); form.value = "Synthetic first edit"
        var gate: CheckedContinuation<Void, Never>?
        owner.register(id: UUID(), scope: "text", generation: "synthetic-editor", state: { form.state }, save: {
            let saved = form.value; await withCheckedContinuation { gate = $0 }; form.baseline = saved; return true
        }, refresh: { form.reads += 1; return true })
        #expect(owner.begin(scope: "text")); let saving = Task { await owner.perform(.save) }
        let deadline = ContinuousClock.now + .seconds(3)
        while gate == nil, ContinuousClock.now < deadline { await Task.yield() }
        let release = try #require(gate); form.value = "Synthetic newer edit"; release.resume()
        #expect(!(await saving.value) && form.reads == 0 && form.state.dirty && !owner.busy)
    }
    @Test func aFailedReadDoesNotSkipTheOtherCardsOrTheChecklist() async {
        let owner = EditorRefresh(), first = Form(), second = Form(); first.failRead = true
        _ = register(first, on: owner); _ = register(second, on: owner)
        var summaries = 0; #expect(owner.begin(scope: "text"))
        #expect(!(await owner.perform(.refresh, summary: { summaries += 1; return true })))
        #expect(first.reads == 1 && second.reads == 1 && summaries == 1 && owner.failed)
    }
    @Test func cancelAndBusyOwnersNeverDiscardOrStartAnotherRead() async {
        let owner = EditorRefresh(), form = Form(); form.busy = true
        _ = register(form, on: owner); #expect(!owner.begin(scope: "text"))
        form.busy = false; #expect(owner.begin(scope: "text")); owner.cancel()
        #expect(!(await owner.perform(.refresh)) && form.reads == 0 && form.saves == 0)
        form.value = "Synthetic dirty text"
        owner.register(id: UUID(), scope: "unsupported", generation: "synthetic-unsupported", state: { form.state }, refresh: { true })
        #expect(owner.begin(scope: "unsupported") && owner.confirmation?.canSave == false && owner.confirmation?.canDiscard == false)
    }
    @Test func readingAnApprovedJobsProgressDoesNotCancelOrResumeIt() async {
        let owner = EditorRefresh(), form = Form(); form.busy = true
        owner.register(id: UUID(), scope: "sending", generation: "synthetic-owned-job",
            state: { .init(dirty: form.state.dirty, busy: form.busy, signature: form.value, refreshWhileBusy: true) },
            refresh: { form.reads += 1; return true })
        #expect(owner.begin(scope: "sending") && owner.confirmation == nil)
        #expect(await owner.perform(.refresh))
        #expect(form.busy && form.reads == 1 && form.saves == 0 && form.discards == 0)
        form.value = "Synthetic unsaved edit during the owned job"
        #expect(!owner.begin(scope: "sending"))
    }
}
