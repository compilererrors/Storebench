import AppKit
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

@MainActor @Suite(.serialized) struct EditorClosingTests {
    init() throws { _ = try TestIsolation.require() }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func globalQuitSavesEveryWindowAndPromptsOnlyOnce() async {
        let first = EditorProtection(), second = EditorProtection(); var saves = 0, prompts = 0
        for (id, owner) in [("synthetic-first", first), ("synthetic-second", second)] {
            owner.policy.update(id: id, dirty: true, busy: false)
            owner.registerSave(id: id) { saves += 1; return true }
            EditorWindows.register(owner)
        }
        defer { EditorWindows.unregister(first); EditorWindows.unregister(second) }
        var saveOffered = false
        let allowed = await EditorWindows.requestClosing(reason: .quit, choose: { _, canSave in prompts += 1; saveOffered = canSave; return .save })
        #expect(allowed && saveOffered)
        #expect(saves == 2 && prompts == 1 && first.policy.dirtyIds.isEmpty && second.policy.dirtyIds.isEmpty)
    }

    @Test func globalDiscardAndCancelLeaveRunningJobsOwned() async {
        let owner = EditorProtection(); var saves = 0
        owner.policy.update(id: "synthetic-editor", dirty: true, busy: true)
        owner.registerSave(id: "synthetic-editor") { saves += 1; return true }
        EditorWindows.register(owner); defer { EditorWindows.unregister(owner) }
        #expect(!(await EditorWindows.requestClosing(reason: .quit, choose: { _, _ in .cancel })))
        #expect(await EditorWindows.requestClosing(reason: .quit, choose: { _, _ in .discard }))
        #expect(saves == 0 && owner.policy.isBusy(id: "synthetic-editor") && owner.policy.dirtyIds == ["synthetic-editor"])
    }

    @MainActor private final class Gate {
        var continuation: CheckedContinuation<Bool, Never>?
        func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }
    }

    @Test func aNewDirtyWindowDuringSaveNeedsItsOwnConfirmation() async throws {
        let first = EditorProtection(), newWindow = EditorProtection(), gate = Gate()
        first.policy.update(id: "synthetic-first", dirty: true, busy: false)
        first.registerSave(id: "synthetic-first") { await gate.wait() }
        EditorWindows.register(first)
        defer { EditorWindows.unregister(first); EditorWindows.unregister(newWindow) }
        let closing = Task { await EditorWindows.requestClosing(reason: .quit, choose: { _, _ in .save }) }
        try await wait { gate.continuation != nil }
        newWindow.policy.update(id: "synthetic-new", dirty: true, busy: false)
        EditorWindows.register(newWindow)
        gate.continuation?.resume(returning: true); gate.continuation = nil
        #expect(!(await closing.value))
        #expect(newWindow.policy.dirtyIds == ["synthetic-new"])
    }

    @Test func editingAnAlreadySavedWindowStopsTheRemainingQuit() async throws {
        let first = EditorProtection(), second = EditorProtection(), gate = Gate()
        var saves = 0
        var savedOwner: (EditorProtection, String)?
        for (id, owner) in [("synthetic-first", first), ("synthetic-second", second)] {
            owner.policy.update(id: id, dirty: true, busy: false)
            owner.registerSave(id: id) {
                saves += 1
                if saves == 1 { savedOwner = (owner, id); return true }
                return await gate.wait()
            }
            EditorWindows.register(owner)
        }
        defer { EditorWindows.unregister(first); EditorWindows.unregister(second) }
        let closing = Task { await EditorWindows.requestClosing(reason: .quit, choose: { _, _ in .save }) }
        try await wait { gate.continuation != nil }
        let edited = try #require(savedOwner)
        edited.0.policy.update(id: edited.1, dirty: true, busy: false)
        gate.continuation?.resume(returning: true); gate.continuation = nil
        #expect(!(await closing.value))
        #expect(edited.0.policy.dirtyIds == [edited.1])
    }
}
