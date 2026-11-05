import Foundation

public enum SessionFailure: Error, Equatable {
    case closed, changed, revocation
    public var message: String {
        switch self {
        case .closed: "Storebench is signed out. Unlock saved data before continuing."
        case .changed: "Storage protection changed. Unlock Storebench again before continuing."
        case .revocation: "This session was closed, but other sessions could not be revoked. Unlock Storebench and retry signing out."
        }
    }
}

/// Tracks actual admitted work. Closing stops admission and waits for every exact lease;
/// elapsed time never cancels a lease or proves that its owner finished.
final class SessionLifetime: @unchecked Sendable {
    enum Phase: Sendable { case open, closing, closed }
    enum Kind: Sendable { case report, publishing, transfer, connection }
    final class Lease: @unchecked Sendable {
        let id = UUID()
        let owner: SessionLifetime
        init(_ owner: SessionLifetime) { self.owner = owner }
        func finish() { owner.finish(self) }
    }
    private let lock = NSLock()
    private var phase: Phase = .open
    private var leases: [UUID: Kind] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalFailure: SessionFailure?
    var status: Phase { lock.withLock { phase } }
    var activeCount: Int { lock.withLock { leases.count } }
    var closeFailure: SessionFailure? { lock.withLock { terminalFailure } }

    func require(_ lease: Lease? = SessionContext.lease) throws {
        try lock.withLock {
            guard phase == .open || (phase == .closing && lease?.owner === self && lease.map { leases[$0.id] != nil } == true) else { throw SessionFailure.closed }
        }
    }
    func admit(_ kind: Kind) throws -> Lease {
        try lock.withLock {
            guard phase == .open else { throw SessionFailure.closed }
            let lease = Lease(self); leases[lease.id] = kind; return lease
        }
    }
    private func finish(_ lease: Lease) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard lease.owner === self, leases.removeValue(forKey: lease.id) != nil, leases.isEmpty else { return [] }
            let ready = drainWaiters; drainWaiters = []; return ready
        }
        waiters.forEach { $0.resume() }
    }
    /// Only the first caller owns the close. Other callers follow its terminal result.
    func beginClosing() -> Bool {
        lock.withLock { guard phase == .open else { return false }; phase = .closing; return true }
    }
    func drained() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if leases.isEmpty { return true }; drainWaiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }
    func closed() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if phase == .closed { return true }; closeWaiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }
    func finishClosing(failure: SessionFailure?) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            precondition(phase == .closing && leases.isEmpty)
            phase = .closed; terminalFailure = failure
            let ready = closeWaiters; closeWaiters = []; return ready
        }
        waiters.forEach { $0.resume() }
    }
}

enum SessionContext {
    @TaskLocal static var lease: SessionLifetime.Lease?
}
