import Foundation
import Testing
@testable import StorebenchCore

@Suite struct AppleReadAdmissionTests {
    init() throws { _ = try TestIsolation.require() }
    private enum SyntheticFailure: Error { case timeout }

    /// Holds synthetic requests open until the test lets each one finish.
    private actor Requests {
        private var open: [String: CheckedContinuation<Void, Never>] = [:]
        private(set) var started: [String] = []
        func hold(_ name: String) async { started.append(name); await withCheckedContinuation { open[name] = $0 } }
        func finish(_ name: String) { open.removeValue(forKey: name)?.resume() }
        func isOpen(_ name: String) -> Bool { open[name] != nil }
    }
    private func until(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) { guard ContinuousClock.now < deadline else { throw SyntheticFailure.timeout }; try await Task.sleep(for: .milliseconds(5)) }
    }
    private func limits() -> AppleReadAdmission.Limits {
        var limits = AppleReadAdmission.Limits(); limits.active = 3; limits.nextActive = 2; limits.backgroundActive = 1; limits.nextWaiting = 2; limits.backgroundWaiting = 1
        return limits
    }
    private func start(_ queue: AppleReadAdmission, _ requests: Requests, _ name: String, _ priority: AppleReadPriority, key: String? = nil) -> Task<Void, Error> {
        Task { try await queue.run(priority, key: key) { await requests.hold(name) } }
    }

    @Test func backgroundWorkLeavesRoomForVisibleReadsAndFullQueuesDropSpeculativeReads() async throws {
        let queue = AppleReadAdmission(limits: limits()), requests = Requests()
        let first = start(queue, requests, "background-1", .background)
        try await until { await requests.isOpen("background-1") }
        let second = start(queue, requests, "background-2", .background)
        try await until { await queue.snapshot.waiting[.background] == 1 }
        // A third background read finds its waiting room full and is dropped, not queued.
        await #expect(throws: AppleReadAdmission.Failure.full) { try await queue.run(.background) { () } }
        let next = start(queue, requests, "next-1", .next)
        try await until { await requests.isOpen("next-1") }
        let nextWaiting = start(queue, requests, "next-2", .next)
        try await until { await queue.snapshot.waiting[.next] == 1 }
        // Next-step and background reads hold two of three slots; a visible read still starts at once.
        let visible = start(queue, requests, "visible-1", .visible)
        try await until { await requests.isOpen("visible-1") }
        let snapshot = await queue.snapshot
        #expect(snapshot.active == [.background: 1, .next: 1, .visible: 1] && snapshot.dropped == 1)

        // When a slot frees, the waiting next-step read goes before the waiting background read.
        await requests.finish("visible-1"); try await visible.value
        await requests.finish("next-1"); try await next.value
        try await until { await requests.isOpen("next-2") }
        #expect(await !requests.isOpen("background-2"))
        await requests.finish("background-1"); try await first.value
        try await until { await requests.isOpen("background-2") }
        await requests.finish("next-2"); await requests.finish("background-2")
        try await nextWaiting.value; try await second.value
        let finished = await queue.snapshot
        #expect(finished.active.isEmpty && finished.waiting.isEmpty)
    }

    @Test func aVisibleReaderRaisesTheSharedRequestItJoinsAndCancelledWaitersLeave() async throws {
        let queue = AppleReadAdmission(limits: limits()), requests = Requests()
        let running = start(queue, requests, "background-1", .background)
        try await until { await requests.isOpen("background-1") }
        let shared = start(queue, requests, "shared", .background, key: "synthetic-key")
        try await until { await queue.snapshot.waiting[.background] == 1 }
        // A visible screen joins the shared read: it starts although background slots are full.
        await queue.raise(key: "synthetic-key", to: .visible)
        try await until { await requests.isOpen("shared") }
        #expect(await queue.snapshot.active == [.background: 1, .visible: 1])
        // A raise that arrives before its request reaches the queue still applies.
        await queue.raise(key: "early-key", to: .visible)
        let early = start(queue, requests, "early", .background, key: "early-key")
        try await until { await requests.isOpen("early") }

        let waiting = start(queue, requests, "cancelled", .background)
        try await until { await queue.snapshot.waiting[.background] == 1 }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        try await until { await queue.snapshot.waiting.isEmpty }
        for name in ["background-1", "shared", "early"] { await requests.finish(name) }
        try await running.value; try await shared.value; try await early.value
        let started = await requests.started, idle = await queue.snapshot
        #expect(!started.contains("cancelled") && idle.active.isEmpty)
    }

    @Test func readsMadeAheadAreMarkedAndOtherReadsCountAsVisible() async {
        #expect(AppleReadPriority.current == .visible)
        await AppleReadPriority.$current.withValue(.background) {
            #expect(AppleReadPriority.current == .background)
            await Task { #expect(AppleReadPriority.current == .background) }.value
        }
        #expect(AppleReadPriority.allCases.sorted() == [.background, .next, .visible])
    }
}
