import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct MediaFileWorkTests {
    init() throws { _ = try TestIsolation.require() }
    private final class Gate: @unchecked Sendable {
        let lock = NSLock(), resume = DispatchSemaphore(value: 0)
        var started = 0, finished = false
        func work() throws {
            lock.withLock { started += 1 }
            guard resume.wait(timeout: .now() + 10) == .success else { throw Failure.timeout }
        }
    }
    private enum Failure: Error { case timeout }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func queuedVideoImportLeavesSessionReadsAvailable() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = await session.mediaFileWork, gate = Gate()
        let first = Task { try await queue.run { try gate.work() } }
        let second = Task { try await queue.run { try gate.work() } }
        defer { gate.resume.signal(); gate.resume.signal() }
        try await wait { gate.lock.withLock { gate.started == 2 } }
        let file = root.appendingPathComponent("synthetic-queued-video.mp4")
        try syntheticMovie().write(to: file)
        let video = Task {
            try await session.addPreview(accountId: "synthetic-account", appId: "1000000001", revisionId: "00000000-0000-4000-8000-000000000002", localizationId: "version-locale-1", type: "IPHONE_67", file: file)
            gate.lock.withLock { gate.finished = true }
        }
        try await wait { session.lifetime.activeCount == 1 }
        #expect(!(try await session.accounts()).isEmpty)
        #expect(!gate.lock.withLock { gate.finished })
        gate.resume.signal(); gate.resume.signal()
        try await first.value; try await second.value; try await video.value
        #expect(session.lifetime.activeCount == 0 && gate.lock.withLock { gate.finished })
    }

    @Test func cancellationWaitsForOwnedFileWorkToStop() async throws {
        let queue = MediaFileWork(limit: 1), gate = Gate()
        let work = Task { try await queue.run { try gate.work(); try Task.checkCancellation() } }
        defer { gate.resume.signal() }
        try await wait { gate.lock.withLock { gate.started == 1 } }
        work.cancel(); gate.resume.signal()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try await queue.run { 42 } == 42)
    }
}
