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
    private func start(_ queue: AppleReadAdmission, _ requests: Requests, _ name: String, _ priority: AppleReadPriority, key: String? = nil, cost: AppleReadCost = .standard) -> Task<Void, Error> {
        Task { try await queue.run(priority, key: key, cost: cost) { await requests.hold(name) } }
    }
    private func oneSlot() -> AppleReadAdmission.Limits {
        var value = AppleReadAdmission.Limits(); value.active = 1; value.nextActive = 1; value.backgroundActive = 1
        return value
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

        let waiting = start(queue, requests, "cancelled", .background, cost: .small)
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

    @Test func smallReadsPassOrdinaryAndBulkReadsAtTheSameUrgencyWithFIFOForPeers() async throws {
        let queue = AppleReadAdmission(limits: oneSlot()), requests = Requests()
        let running = start(queue, requests, "running", .visible)
        try await until { await requests.isOpen("running") }
        let names = ["bulk", "ordinary", "small-first", "small-second"]
        let costs: [AppleReadCost] = [.bulk, .standard, .small, .small]
        var tasks: [Task<Void, Error>] = []
        for (index, name) in names.enumerated() {
            tasks.append(start(queue, requests, name, .visible, cost: costs[index]))
            let count = index + 1
            try await until { await queue.snapshot.waiting[.visible] == count }
        }
        await requests.finish("running"); try await running.value
        for name in ["small-first", "small-second", "ordinary", "bulk"] {
            try await until { await requests.isOpen(name) }
            await requests.finish(name)
        }
        for task in tasks { try await task.value }
        #expect(await requests.started == ["running", "small-first", "small-second", "ordinary", "bulk"])
        #expect(await queue.snapshot.active.isEmpty)
    }

    @Test func urgencyWinsOverRequestCost() async throws {
        let queue = AppleReadAdmission(limits: oneSlot()), requests = Requests()
        let running = start(queue, requests, "running", .visible)
        try await until { await requests.isOpen("running") }
        let background = start(queue, requests, "background-small", .background, cost: .small)
        try await until { await queue.snapshot.waiting[.background] == 1 }
        let next = start(queue, requests, "next-small", .next, cost: .small)
        try await until { await queue.snapshot.waiting[.next] == 1 }
        let visible = start(queue, requests, "visible-bulk", .visible, cost: .bulk)
        try await until { await queue.snapshot.waiting[.visible] == 1 }
        await requests.finish("running"); try await running.value
        for name in ["visible-bulk", "next-small", "background-small"] {
            try await until { await requests.isOpen(name) }
            await requests.finish(name)
        }
        try await visible.value; try await next.value; try await background.value
        #expect(await requests.started == ["running", "visible-bulk", "next-small", "background-small"])
    }

    @Test func aBulkReadCannotBeStarvedByNewerSmallReads() async throws {
        let queue = AppleReadAdmission(limits: oneSlot()), requests = Requests()
        let running = start(queue, requests, "running", .visible)
        try await until { await requests.isOpen("running") }
        let bulk = start(queue, requests, "bulk", .visible, cost: .bulk)
        try await until { await queue.snapshot.waiting[.visible] == 1 }
        let bound = AppleReadAdmission.maximumCostBypasses
        var small: [Task<Void, Error>] = []
        for index in 0..<(bound + 2) {
            small.append(start(queue, requests, "small-\(index)", .visible, cost: .small))
            let count = index + 2
            try await until { await queue.snapshot.waiting[.visible] == count }
        }
        await requests.finish("running"); try await running.value
        for index in 0..<bound {
            let name = "small-\(index)"
            try await until { await requests.isOpen(name) }
            await requests.finish(name); try await small[index].value
        }
        try await until { await requests.isOpen("bulk") }
        #expect(await !requests.isOpen("small-\(bound)"))
        await requests.finish("bulk"); try await bulk.value
        for index in bound..<(bound + 2) {
            let name = "small-\(index)"
            try await until { await requests.isOpen(name) }
            await requests.finish(name); try await small[index].value
        }
        #expect(await requests.started.firstIndex(of: "bulk") == bound + 1)
        let idle = await queue.snapshot
        #expect(idle.active.isEmpty && idle.waiting.isEmpty)
    }

    @Test func requestShapeChoosesSmallPagesBeforeBulkContinuations() async {
        #expect(AppStoreConnectClient.readCost("/v1/apps/1001") == .small)
        #expect(AppStoreConnectClient.readCost("/v2/inAppPurchases/1002") == .small)
        #expect(AppStoreConnectClient.readCost("/v1/builds?limit=1") == .small)
        #expect(AppStoreConnectClient.readCost("/v1/builds?limit=50") == .small)
        #expect(AppStoreConnectClient.readCost("/v1/builds?limit=200") == .standard)
        #expect(AppStoreConnectClient.readCost("/v1/builds?limit=0") == .standard)
        #expect(AppStoreConnectClient.readCost("/v1/builds?limit=1&limit=200") == .standard)
        #expect(AppStoreConnectClient.readCost("/v1/builds?limit=1&cursor=synthetic-next") == .bulk)
        #expect(AppStoreConnectClient.readCost("/v1/apps/1001?cursor=synthetic-next") == .bulk)
        #expect(AppleReadCost.current == nil)
        await AppleReadCost.$current.withValue(.bulk) {
            await Task { #expect(AppleReadCost.current == .bulk) }.value
        }
        #expect(AppleReadCost.current == nil)
    }
}
