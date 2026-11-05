import Foundation
import Testing
@testable import StorebenchCore

@Suite struct ShortcutActionsTests {
    init() throws { _ = try TestIsolation.require() }
    @MainActor private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func finish() { continuation?.resume(); continuation = nil }
    }
    @Test @MainActor func pendingActionsCannotRunTwiceAndFinishOnlyTheirOwnBusyState() async {
        let actions = ShortcutActions(), owner = UUID(), gate = Gate(); var calls = 0
        actions.register(.syncApp, owner: owner, enabled: true) { calls += 1; await gate.wait() }
        #expect(actions.perform(.syncApp) && !actions.perform(.syncApp))
        while gate.continuation == nil { await Task.yield() }
        #expect(calls == 1 && actions.busy(.syncApp) && !actions.enabled(.syncApp))
        gate.finish(); while actions.busy(.syncApp) { await Task.yield() }
        #expect(actions.enabled(.syncApp))
    }
    @Test @MainActor func aDisabledSpecificActionDoesNotFallBackToAnUnscopedHandler() async {
        let actions = ShortcutActions(), parent = UUID(), child = UUID(); var calls = 0
        actions.register(.syncApp, owner: parent, priority: 0, enabled: true) { calls += 1 }
        actions.register(.syncApp, owner: child, priority: 10, enabled: false) { calls += 100 }
        #expect(!actions.perform(.syncApp) && calls == 0)
        actions.remove(.syncApp, owner: child)
        #expect(actions.perform(.syncApp)); while actions.busy(.syncApp) { await Task.yield() }
        #expect(calls == 1)
    }
    @Test @MainActor func anEarlierOwnerCannotRemoveOrCompleteTheNewAppsAction() async {
        let actions = ShortcutActions(), old = UUID(), next = UUID(), gate = Gate(); var calls = 0
        actions.register(.syncApp, owner: old, enabled: true) { await gate.wait() }
        #expect(actions.perform(.syncApp)); while gate.continuation == nil { await Task.yield() }
        actions.remove(.syncApp, owner: old)
        actions.register(.syncApp, owner: next, enabled: true) { calls += 1 }
        actions.remove(.syncApp, owner: old)
        #expect(actions.enabled(.syncApp) && actions.perform(.syncApp))
        gate.finish(); while actions.busy(.syncApp) { await Task.yield() }
        #expect(calls == 1 && actions.enabled(.syncApp))
    }
    @Test @MainActor func differentWindowsAndAppAndAllSyncRemainIndependent() async {
        let first = ShortcutActions(), second = ShortcutActions(), gate = Gate(); var app = 0, all = 0, other = 0
        first.register(.syncApp, owner: UUID(), enabled: true) { app += 1; await gate.wait() }
        first.register(.syncAll, owner: UUID(), enabled: true) { all += 1 }
        second.register(.syncApp, owner: UUID(), enabled: true) { other += 1 }
        #expect(first.perform(.syncApp)); while gate.continuation == nil { await Task.yield() }
        #expect(first.perform(.syncAll) && second.perform(.syncApp))
        while first.busy(.syncAll) || second.busy(.syncApp) { await Task.yield() }
        #expect(app == 1 && all == 1 && other == 1)
        gate.finish(); while first.busy(.syncApp) { await Task.yield() }
    }
    @Test @MainActor func aRetiredActionWaitingForTheMainActorCannotRunOnTheNewView() async {
        let actions = ShortcutActions(), old = UUID(), next = UUID(); var oldCalls = 0, newCalls = 0
        actions.register(.refresh, owner: old, enabled: true) { oldCalls += 1 }
        #expect(actions.perform(.refresh))
        actions.remove(.refresh, owner: old)
        actions.register(.refresh, owner: next, enabled: true) { newCalls += 1 }
        #expect(actions.perform(.refresh))
        while actions.hasPendingActions { await Task.yield() }
        #expect(oldCalls == 0 && newCalls == 1)
    }
}
