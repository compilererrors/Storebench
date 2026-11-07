import Foundation
import Testing
@testable import StorebenchCore

@Suite @MainActor struct ReleaseBuildReaderTests {
    init() throws { _ = try TestIsolation.require() }
    private enum Failure: Error { case synthetic }
    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var entered = false
        func hold() async { await withCheckedContinuation { continuation = $0; entered = true } }
        func release() { continuation?.resume(); continuation = nil }
        func wait() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !entered {
                guard ContinuousClock.now < deadline else { throw Failure.synthetic }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
    private func page(_ id: String, complete: Bool = true) -> ReleaseBuildPage {
        ReleaseBuildPage(builds: [], attachedId: id, complete: complete)
    }

    @Test func aNewerReadWinsOverAnOlderFirstPage() async throws {
        let gate = Gate(); defer { gate.release() }
        var calls = 0, pages: [String] = [], failures = 0
        let reader = ReleaseBuildReader(scope: "synthetic-version") { _, _ in
            calls += 1
            if calls == 1 { await gate.hold(); return page("older", complete: false) }
            return page("newer")
        }
        let old = Task { await reader.load(received: { pages.append($0.attachedId!) }, failed: { _, _ in failures += 1 }) }
        try await gate.wait()
        await reader.load(received: { pages.append($0.attachedId!) }, failed: { _, _ in failures += 1 })
        gate.release(); await old.value
        #expect(pages == ["newer"] && calls == 2 && failures == 0)
    }

    @Test func anAlreadyCancelledRefreshDoesNotReplaceTheActiveRead() async throws {
        let gate = Gate(); defer { gate.release() }
        var calls = 0, pages: [String] = []
        let reader = ReleaseBuildReader(scope: "synthetic-version") { _, _ in
            calls += 1; await gate.hold(); return page("active")
        }
        let active = Task { await reader.load(received: { pages.append($0.attachedId!) }, failed: { _, _ in Issue.record("Unexpected synthetic read failure") }) }
        try await gate.wait()
        let cancelled = Task { await reader.load(received: { _ in Issue.record("A cancelled refresh delivered a page") }, failed: { _, _ in Issue.record("A cancelled refresh delivered an error") }) }
        cancelled.cancel(); await cancelled.value
        gate.release(); await active.value
        #expect(calls == 1 && pages == ["active"])
    }

    @Test func navigationRetiresTheOldScopeAndItsLateErrors() async throws {
        let gate = Gate(); defer { gate.release() }
        var oldCalls = 0, oldDeliveries = 0, newPages: [String] = []
        let old = ReleaseBuildReader(scope: "synthetic-version-1") { _, _ in
            oldCalls += 1; await gate.hold(); throw Failure.synthetic
        }
        let pending = Task { await old.load(received: { _ in oldDeliveries += 1 }, failed: { _, _ in oldDeliveries += 1 }) }
        try await gate.wait(); old.retire()
        let current = ReleaseBuildReader(scope: "synthetic-version-2") { _, _ in page("new-version") }
        await current.load(received: { newPages.append($0.attachedId!) }, failed: { _, _ in Issue.record("Unexpected synthetic read failure") })
        // An old compliance callback arriving after navigation cannot start another request.
        await old.load(received: { _ in oldDeliveries += 1 }, failed: { _, _ in oldDeliveries += 1 })
        gate.release(); await pending.value
        #expect(oldCalls == 1 && oldDeliveries == 0 && newPages == ["new-version"])
    }

    @Test func retirementDuringTheContinuationKeepsTheFirstPagePartial() async throws {
        let gate = Gate(); defer { gate.release() }
        var pages: [Bool] = [], failures = 0
        let reader = ReleaseBuildReader(scope: "synthetic-version") { all, _ in
            if all { await gate.hold(); return page("complete") }
            return page("partial", complete: false)
        }
        let pending = Task { await reader.load(received: { pages.append($0.complete) }, failed: { _, _ in failures += 1 }) }
        try await gate.wait(); reader.retire(); gate.release(); await pending.value
        #expect(pages == [false] && failures == 0)
    }

    @Test func aFailedContinuationNeverClaimsCompletenessAndAutomaticFailuresStayQuiet() async {
        var pages: [Bool] = [], failures: [Bool] = [], refreshed: [Bool] = [], modes: [Bool] = []
        let reader = ReleaseBuildReader(scope: "synthetic-version") { all, latest in
            refreshed.append(AppStoreReadCache.refreshedSince != nil); modes.append(latest)
            if all { throw Failure.synthetic }
            return page("partial", complete: false)
        }
        await reader.load(fresh: true, received: { pages.append($0.complete) }, failed: { _, shown in failures.append(shown) })
        #expect(pages == [false] && failures == [true] && refreshed == [true, true])
        await reader.load(latest: true, received: { pages.append($0.complete) }, failed: { _, shown in failures.append(shown) })
        #expect(pages == [false, false] && failures == [true] && modes == [false, false, true, true])
        let unavailable = ReleaseBuildReader(scope: "synthetic-unavailable") { _, _ in throw Failure.synthetic }
        await unavailable.load(received: { _ in Issue.record("An unavailable read delivered a page") }, failed: { _, shown in failures.append(shown) })
        #expect(failures == [true, false])
    }
}
